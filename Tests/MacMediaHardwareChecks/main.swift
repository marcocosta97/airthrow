import Foundation
import AVFoundation

/// Headless checks over generated local files only. Never loads app preferences.
@main
struct MacMediaHardwareChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        environment["AIRTHROW_FFMPEG"] = root.appendingPathComponent("fixture-ffmpeg").path
        let cases: [(String, String, VideoEnhancement, PlaybackPath)] = [
            ("remux", "input.mkv", .original, .remux),
            ("audio", "flac.mkv", .original, .audioConversion),
            ("h264", "input.mkv", .upscale1080, .videoConversion),
            ("hevc", "input.mkv", .upscale4K, .videoConversion),
            ("cleanup", "input.mkv", .cleanup1080, .videoConversion),
            ("lanczos", "input.mkv", .upscale1080, .videoConversion),
            ("no-scale", "input.mkv", .upscale1080, .videoConversion),
            ("failed-frames", "input.mkv", .upscale1080, .videoConversion),
            ("software", "input.mkv", .upscale1080, .videoConversion),
            ("non-wide", "non-wide.mkv", .upscale1080, .videoConversion),
            ("hevc-input", "hevc-input.mkv", .upscale1080, .videoConversion),
            ("separate", "input.mkv", .upscale1080, .videoConversion),
            ("full-range", "full-range.mkv", .upscale1080, .videoConversion),
            ("high-rate", "high-rate.mkv", .original, .videoConversion),
            ("progressive", "input.mkv", .upscale1080, .videoConversion),
            ("cached", "input.mkv", .upscale4K, .videoConversion)
        ]
        for (name, file, enhancement, path) in cases {
            try Data(name.utf8).write(to: root.appendingPathComponent("current-case"))
            let preparer = MediaPreparer(environment: environment,
                preferences: PreparationPreferences(retainAll: name != "cached"))
            let source = ResolvedSource(url: root.appendingPathComponent(file),
                audio: name == "separate" ? MediaTrack(url: root.appendingPathComponent("flac.mkv")) : nil,
                needsPreparation: true)
                .withConversionPolicy(.allowVideo).withEnhancement(enhancement, upscaler: name == "lanczos" ? .lanczos : .automatic)
            let progressive = name == "progressive" || name == "cached"
            let prepared = try await preparer.prepare(source, mode: progressive ? .progressiveHLS : .completeFile)
            do {
                guard prepared.playbackPath == path else { throw PreparationFailure.failed }
                guard try await AVURLAsset(url: prepared.url).load(.isPlayable) else { throw PreparationFailure.failed }
                let (data, response) = try await URLSession.shared.data(from: prepared.url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PreparationFailure.delivery }
                if !progressive { try data.write(to: root.appendingPathComponent(name + ".mp4")) }
                else {
                    guard prepared.videoHeight == enhancement.targetHeight,
                          prepared.usesBoundedCache == (name == "cached") else { throw PreparationFailure.failed }
                }
                prepared.stop(); await prepared.waitForProducer()
            } catch {
                prepared.stop(); await prepared.waitForProducer(); throw error
            }
        }
        print("PASS actual MediaPreparer remux, audio-only conversion, H.264/HEVC enhancement and cleanup")
    }
}
