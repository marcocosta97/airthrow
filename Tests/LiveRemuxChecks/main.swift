import Foundation
import AVFoundation

@main
@MainActor
struct LiveRemuxChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "LiveRemuxChecks", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async {
        do { try await run() }
        catch { print("FAIL live remux checks: \(error)"); exit(1) }
    }

    static func run() async throws {
        let base = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        environment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("paced-ffmpeg").path
        let source = ResolvedSource(url: URL(string: base + "/video.m3u8")!,
            audio: MediaTrack(url: URL(string: base + "/audio.m3u8")!),
            delivery: .hls, videoKnownPresent: true, isLive: true, plannedPath: .remux)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await session.data(from: url)
            return (data, response as! HTTPURLResponse)
        }
        let started = Date()
        let prepared = try await MediaPreparer(environment: environment).prepare(source)
        defer { prepared.stop() }
        try check(prepared.isProducing && prepared.sourceDuration == nil && prepared.playbackPath == .remux,
                  "Live remux waited for the source to end or lost its live identity")
        let (first, firstResponse) = try await fetch(prepared.url)
        let firstText = String(decoding: first, as: UTF8.self)
        try check(firstResponse.statusCode == 200 && firstText.contains("#EXT-X-MEDIA-SEQUENCE:")
                  && !firstText.contains("#EXT-X-PLAYLIST-TYPE:EVENT")
                  && !firstText.contains("#EXT-X-ENDLIST"), "Initial playlist was not sliding live HLS")
        let asset = AVURLAsset(url: prepared.url)
        try check(try await asset.load(.isPlayable), "Live remux was not natively playable")
        let firstSegment = firstText.split(separator: "\n").first { !$0.hasPrefix("#") }!
        let segmentURL = prepared.url.deletingLastPathComponent().appendingPathComponent(String(firstSegment))
        let (segment, segmentResponse) = try await fetch(segmentURL)
        try check(segmentResponse.statusCode == 200 && segment.count > 1000,
                  "Live segment was unavailable after playlist publication")
        try segment.write(to: directory.appendingPathComponent("live-segment.ts"))
        try await Task.sleep(for: .seconds(5))
        let (later, _) = try await fetch(prepared.url)
        let laterText = String(decoding: later, as: UTF8.self)
        func sequence(_ text: String) -> Int {
            let line = text.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") } ?? ""
            return Int(line.split(separator: ":").last ?? "") ?? -1
        }
        try check(sequence(laterText) > sequence(firstText), "Live playlist did not slide")
        try check(laterText.split(separator: "\n").filter { !$0.hasPrefix("#") }.count <= 6,
                  "Live playlist exceeded its bounded window")
        await prepared.waitForProducer()
        try check(prepared.productionFailure == nil, "Natural live source end was reported as a failure")
        let (final, _) = try await fetch(prepared.url)
        try check(String(decoding: final, as: UTF8.self).contains("#EXT-X-ENDLIST"),
                  "Ended live source never finalized its playlist")
        prepared.stop()
        do { _ = try await fetch(prepared.url); try check(false, "Stopped live server remained open") }
        catch is URLError {}
        print("PASS live HLS remux startup, native readability, sliding bounded playlist, natural end and stop (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)")

        var failingEnvironment = environment
        failingEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("failing-ffmpeg").path
        let failing = try await MediaPreparer(environment: failingEnvironment).prepare(source)
        try check(failing.isProducing, "Failing producer ended before live handoff")
        await failing.waitForProducer()
        try check(failing.productionFailure == .failed, "Post-handoff live producer failure was hidden")
        failing.stop()
        print("PASS post-handoff live producer failure is surfaced")

        let preparer = MediaPreparer(environment: environment)
        let controller = PlaybackController(resolveSource: { _ in source },
                                            prepareSource: { try await preparer.prepare($0) })
        try controller.load("https://example.com/live")
        let deadline = Date().addingTimeInterval(6)
        while ![.awaitingReceiver, .failed].contains(controller.snapshot.state), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try check(controller.snapshot.state == .awaitingReceiver && controller.snapshot.isLive
                  && controller.snapshot.duration == nil && controller.player.rate == 0,
                  "Live remux did not load paused with a live timeline: \(controller.snapshot.state)")
        controller.stop()
        print("PASS controller live timeline, paused readiness and Stop cleanup")

        func saveSegment(_ prepared: PreparedMedia, as name: String) async throws {
            let (playlist, response) = try await fetch(prepared.url)
            let text = String(decoding: playlist, as: UTF8.self)
            guard let segment = text.split(separator: "\n").first(where: { !$0.hasPrefix("#") }) else {
                throw NSError(domain: "LiveRemuxChecks", code: 2)
            }
            let (bytes, segmentResponse) = try await fetch(prepared.url.deletingLastPathComponent()
                .appendingPathComponent(String(segment)))
            try check(response.statusCode == 200 && segmentResponse.statusCode == 200 && bytes.count > 1000,
                      "Converted live segment was unavailable")
            try bytes.write(to: directory.appendingPathComponent(name))
        }

        let audioSource = ResolvedSource(url: URL(string: base + "/video.m3u8")!,
            audio: MediaTrack(url: URL(string: base + "/audio-opus.webm")!),
            delivery: .hls, videoKnownPresent: true, isLive: true, plannedPath: .audioConversion)
        let audioConverted = try await MediaPreparer(environment: environment).prepare(audioSource)
        try check(audioConverted.isProducing && audioConverted.playbackPath == .audioConversion,
                  "Live audio conversion did not hand off while producing")
        try await saveSegment(audioConverted, as: "live-audio-converted.ts")
        audioConverted.stop()
        await audioConverted.waitForProducer()
        print("PASS live audio conversion starts before source completion")

        var softwareEnvironment = environment
        softwareEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("software-ffmpeg").path
        let videoSource = ResolvedSource(url: URL(string: base + "/video-vp9.webm")!,
            audio: MediaTrack(url: URL(string: base + "/audio.m3u8")!),
            delivery: .hls, videoKnownPresent: true, isLive: true,
            conversionPolicy: .allowVideo, plannedPath: .videoConversion)
        do {
            _ = try await MediaPreparer(environment: softwareEnvironment).prepare(
                videoSource.withConversionPolicy(.avoidVideo))
            try check(false, "Live video conversion ignored the opt-in policy")
        } catch PreparationFailure.videoConversionRequired {}
        let videoConverted = try await MediaPreparer(environment: softwareEnvironment).prepare(videoSource)
        try check(videoConverted.isProducing && videoConverted.playbackPath == .videoConversion,
                  "Live video conversion did not hand off while producing")
        try await saveSegment(videoConverted, as: "live-video-converted.ts")
        videoConverted.stop()
        await videoConverted.waitForProducer()
        print("PASS opt-in live video conversion verifies its first segment")

        var slowEnvironment = environment
        slowEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("slow-ffmpeg").path
        let slowStarted = Date()
        do {
            _ = try await MediaPreparer(environment: slowEnvironment).prepare(videoSource)
            try check(false, "Slow live encoder reached player handoff")
        } catch let failure as PreparationFailure {
            try check(failure == .failed && Date().timeIntervalSince(slowStarted) < 25,
                      "Slow live encoder was not rejected promptly")
        }
        print("PASS live video conversion rejects insufficient sustained speed")
    }
}
