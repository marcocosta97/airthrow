import Foundation
import AVFoundation
import CoreVideo
import QuartzCore

/// Headless comparison harness: decoded buffers only, no windows or local video presentation.
@main struct SharePerformanceChecks {
    @MainActor static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        guard base.host == "127.0.0.1" else { throw PreparationFailure.unsupported }
        let name = CommandLine.arguments[2]
        let target = Double(CommandLine.arguments[3])!
        let space = URLProtectionSpace(host: base.host!, port: base.port!, protocol: "http", realm: "fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let credentials = HTTPLoginCredentials(challenge: HTTPLoginChallenge(space)!, username: "fixture", password: "fixture")
        let relay = try await HTTPMediaRelay.start(source: base.appendingPathComponent(name), credentials: credentials, host: "127.0.0.1")
        defer { relay.stop() }
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        let began = ContinuousClock.now
        let media = try await MediaPreparer(environment: environment,
            preferences: PreparationPreferences(maximumBytes: 128 * 1024 * 1024, remuxCache: true))
            .prepare(ResolvedSource(url: relay.url!, needsPreparation: true))
        defer { media.stop() }
        let prepared = began.duration(to: .now).timeInterval
        let item = AVPlayerItem(url: media.url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true; player.allowsExternalPlayback = false
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        func frame(atLeast seconds: Double) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while ContinuousClock.now < deadline, item.status != .failed {
                let time = output.itemTime(forHostTime: CACurrentMediaTime())
                var display = CMTime.invalid
                if output.hasNewPixelBuffer(forItemTime: time),
                   output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &display) != nil,
                   display.seconds >= seconds - 0.25 { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            FileHandle.standardError.write(Data("No video buffer: clock=\(player.currentTime().seconds), mapped=\(output.itemTime(forHostTime: CACurrentMediaTime()).seconds), status=\(item.status.rawValue), target=\(seconds)\n".utf8))
            throw PreparationFailure.stalled
        }
        player.play()
        try await frame(atLeast: 0)
        let startup = began.duration(to: .now).timeInterval
        player.pause()
        let seekBegan = ContinuousClock.now
        // Match the controller: native seek and target preparation run together.
        let prepareSeek = Task { @MainActor in
            try await media.prepareSeek(at: target)
            return seekBegan.duration(to: .now).timeInterval
        }
        guard await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                                toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
        else { throw PreparationFailure.failed }
        let seekPrepared = try await prepareSeek.value
        player.play()
        try await frame(atLeast: target)
        let seek = seekBegan.duration(to: .now).timeInterval
        player.pause(); player.replaceCurrentItem(with: nil)
        media.stop(); await media.waitForProducer()
        let result: [String: Double] = ["prepared_seconds": prepared, "first_frame_seconds": startup,
            "seek_prepared_seconds": seekPrepared, "seek_first_frame_seconds": seek]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
