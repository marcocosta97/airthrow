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
    }
}
