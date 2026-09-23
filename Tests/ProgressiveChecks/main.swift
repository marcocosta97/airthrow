import Foundation
import AVFoundation

@main
@MainActor
struct ProgressiveChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ProgressiveChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async {
        do { try await run() }
        catch { print("FAIL progressive checks: \(error)"); exit(1) }
    }
    static func run() async throws {
        let base = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        environment["AIRTHROW_PREPARATION_MODE"] = "progressive-hls"
        environment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("paced-ffmpeg").path
        let preparer = MediaPreparer(environment: environment)
        let source = ResolvedSource(url: URL(string: base + "/long.mp4")!, needsPreparation: true)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("athrow-prepared-v1")
        MediaPreparer.cleanAbandonedFiles()
        let originalWorkspaces = Set((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func fetch(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
            request.httpMethod = method
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let started = Date()
        let prepared = try await preparer.prepare(source)
        defer { prepared.stop() }
        let readySeconds = Date().timeIntervalSince(started)
        try check(prepared.isProducing && prepared.url.pathExtension == "m3u8", "Preparation waited for the entire source")
        try check(prepared.sourceDuration == 20, "Finite duration missing")
        let (initial, response) = try await fetch(prepared.url)
        let initialText = String(decoding: initial, as: UTF8.self)
        try check(response.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl"
                  && initialText.contains("#EXT-X-PLAYLIST-TYPE:EVENT") && !initialText.contains("#EXT-X-ENDLIST"),
                  "Initial playlist was not a growing EVENT")
        let segmentNames = initialText.split(separator: "\n").filter { !$0.hasPrefix("#") }
        try check(segmentNames.count >= 3, "Insufficient startup buffer")
        let segment = prepared.url.deletingLastPathComponent().appendingPathComponent(String(segmentNames[0]))
        let (bytes, segmentResponse) = try await fetch(segment)
        let (head, headResponse) = try await fetch(segment, method: "HEAD")
        let (partial, partialResponse) = try await fetch(segment, range: "bytes=0-99")
        try check(segmentResponse.value(forHTTPHeaderField: "Content-Type") == "video/mp2t"
                  && bytes.count > 1000 && head.isEmpty && headResponse.expectedContentLength == bytes.count
                  && partial == bytes.prefix(100) && partialResponse.statusCode == 206, "Segment HTTP delivery failed")
        for name in ["lease", "media.m3u8.tmp", "segment000003.ts.tmp", "segment999999.ts", "other.ts", "%2e%2e/lease"] {
            let (_, denied) = try await fetch(URL(string: name, relativeTo: prepared.url)!.absoluteURL)
            try check(denied.statusCode == 404, "Unexpected HLS resource exposed")
        }
        try check(MediaHTTPServer.isSegmentName("segment1000000.ts")
                  && !MediaHTTPServer.isSegmentName("segment.ts")
                  && !MediaHTTPServer.isSegmentName("segment1x.ts")
                  && !MediaHTTPServer.isSegmentName("other.ts"),
                  "Segment-name validation rejected a widened index or accepted a non-segment")
        // Fetch repeatedly across atomic playlist replacements; Content-Length must always match.
        for _ in 0..<25 {
            let (body, response) = try await fetch(prepared.url)
            try check(body.count == response.expectedContentLength, "Playlist changed between stat and read")
            try await Task.sleep(for: .milliseconds(40))
        }
        await prepared.waitForProducer()
        try check(prepared.productionFailure == nil, "Producer failed after readiness")
        let (final, _) = try await fetch(prepared.url)
        let finalText = String(decoding: final, as: UTF8.self)
        try check(finalText.contains("#EXT-X-ENDLIST") && final.count > initial.count, "Finite HLS did not complete")
        let saved = directory.appendingPathComponent("hls")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        try final.write(to: saved.appendingPathComponent("media.m3u8"))
        for name in finalText.split(separator: "\n") where !name.hasPrefix("#") {
            let (data, _) = try await fetch(prepared.url.deletingLastPathComponent().appendingPathComponent(String(name)))
            try data.write(to: saved.appendingPathComponent(String(name)))
        }
        prepared.stop()
        do { _ = try await fetch(prepared.url); try check(false, "Stopped HLS server remained open") }
        catch is URLError {}
        print("PASS progressive readiness, atomic playlist/segment delivery, finite ENDLIST; observed readiness: \(String(format: "%.2f", readySeconds))s")

        var fallbackEnvironment = environment
        fallbackEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("fallback-ffmpeg").path
        let fallback = try await MediaPreparer(environment: fallbackEnvironment).prepare(source)
        try check(fallback.url.pathExtension == "mp4", "Startup failure did not use complete-file fallback")
        fallback.stop()
        print("PASS complete-file fallback before handoff")

        var hardwareFailureEnvironment = environment
        hardwareFailureEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("hardware-failure-ffmpeg").path
        let recovered = try await MediaPreparer(environment: hardwareFailureEnvironment).prepare(
            ResolvedSource(url: URL(string: base + "/vp9-opus.mkv")!, needsPreparation: true,
                           conversionPolicy: .allowVideo))
        try check(recovered.url.pathExtension == "m3u8" && recovered.playbackPath == .videoConversion,
                  "Failed hardware job did not recover through software HLS")
        let attempts = try String(contentsOf: directory.appendingPathComponent("encoder-attempts.txt"), encoding: .utf8)
        try check(attempts.split(separator: "\n") == ["hardware-preflight", "hardware-job", "software-job"],
                  "Hardware was retried before software fallback: \(attempts)")
        recovered.stop()
        await recovered.waitForProducer()
        print("PASS hardware startup failure switches directly to software without a second hardware job")

        let timedPreparer = MediaPreparer(environment: environment, maximumBytes: 2 * 1024 * 1024 * 1024,
                                          startupTimeout: .milliseconds(200))
        let timedFallback = try await timedPreparer.prepare(ResolvedSource(url: URL(string: base + "/combined.mp4")!))
        try check(timedFallback.url.pathExtension == "mp4", "Startup deadline did not use complete-file fallback")
        timedFallback.stop()
        var limitedEnvironment = environment
        limitedEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("oversized-ffmpeg").path
        do {
            _ = try await MediaPreparer(environment: limitedEnvironment, maximumBytes: 2 * 1024 * 1024).prepare(source)
            try check(false, "Unfinished HLS segment escaped aggregate size limit")
        } catch let failure as PreparationFailure {
            try check(failure == .limit, "Aggregate HLS limit used the wrong error")
        }
        // MPEG-TS overhead means a source just under the cap must be rejected
        // before download instead of overflowing mid-remux.
        let (_, sizeResponse) = try await fetch(URL(string: base + "/long.mp4")!, method: "HEAD")
        let sourceBytes = sizeResponse.expectedContentLength
        do {
            _ = try await MediaPreparer(environment: environment,
                                        maximumBytes: sourceBytes + sourceBytes / 16).prepare(source)
            try check(false, "Source-size pre-check ignored MPEG-TS overhead")
        } catch let failure as PreparationFailure {
            try check(failure == .limit, "Source-size pre-check used the wrong error")
        }
        let split = ResolvedSource(url: URL(string: base + "/video.mp4")!,
                                   audio: MediaTrack(url: URL(string: base + "/audio.m4a")!))
        let joined = try await preparer.prepare(split)
        try check(joined.url.pathExtension == "m3u8" && !joined.isProducing, "Short split source did not complete as HLS")
        let (joinedBytes, _) = try await fetch(joined.url.deletingLastPathComponent().appendingPathComponent("segment000000.ts"))
        try joinedBytes.write(to: directory.appendingPathComponent("joined.ts"))
        joined.stop()
        // Progressive delivery also serves converted tracks, not only copies.
        let converting = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/vp9-opus.mkv")!,
            needsPreparation: true, conversionPolicy: .allowVideo))
        try check(converting.playbackPath == .videoConversion && converting.url.pathExtension == "m3u8",
                  "Progressive HLS did not serve the video-conversion tier")
        let (conversionPlaylist, conversionResponse) = try await fetch(converting.url)
        try check(conversionResponse.statusCode == 200
                  && String(decoding: conversionPlaylist, as: UTF8.self).hasPrefix("#EXTM3U"),
                  "Converted HLS playlist was not served")
        let (convertedSegment, _) = try await fetch(converting.url.deletingLastPathComponent()
            .appendingPathComponent("segment000000.ts"))
        try convertedSegment.write(to: directory.appendingPathComponent("converted.ts"))
        converting.stop()
        print("PASS startup deadline, unfinished-segment and source-size headroom limits, short separate-track and validated opt-in converted HLS")

        // Native readiness must stay paused and finite while the producer is active.
        let controller = PlaybackController(resolveSource: { url in
            url.host == "example.com" ? source : ResolvedSource(url: url)
        }, prepareSource: { try await preparer.prepare($0) })
        try controller.load("https://example.com/video")
        let deadline = Date().addingTimeInterval(15)
        while ![.awaitingReceiver, .failed].contains(controller.snapshot.state), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try check(controller.snapshot.state == .awaitingReceiver && controller.snapshot.duration == 20
                  && !controller.snapshot.isLive && controller.snapshot.liveOffset == nil,
                  "Growing finite HLS status=\(controller.player.currentItem?.status.rawValue ?? -1), tracks=\(controller.player.currentItem?.tracks.count ?? -1), size=\(controller.player.currentItem?.presentationSize ?? .zero): \(String(decoding: try JSONEncoder().encode(controller.snapshot), as: UTF8.self))")
        try check(controller.player.rate == 0 && controller.player.isMuted, "HLS started local playback")
        try check((controller.snapshot.position ?? 99) < 1, "Finite HLS started at the live edge")
        try check((controller.snapshot.seekableRanges.last?.end ?? 0) < 20, "Unprepared media was seekable")
        do { try controller.seek(19); try check(false, "Seek beyond preparation was accepted") }
        catch let error as AppFailure { try check(error.code == .unsupportedOperation, "Seek failed for the wrong reason") }
        let endpoint = (controller.player.currentItem!.asset as! AVURLAsset).url
        let (readyPlaylist, _) = try await fetch(endpoint)
        try check(!String(decoding: readyPlaylist, as: UTF8.self).contains("#EXT-X-ENDLIST"),
                  "Native readiness waited for complete preparation")
        try controller.load(base + "/combined.mp4")
        let replacementDeadline = Date().addingTimeInterval(10)
        while controller.snapshot.state == .loading, Date() < replacementDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try check(controller.snapshot.state == .awaitingReceiver && controller.snapshot.playbackPath == .direct,
                  "Replacement did not preserve the new direct session")
        controller.stop()
        await controller.shutdownAndWait()
        do { _ = try await fetch(endpoint); try check(false, "Stop retained HLS delivery") }
        catch is URLError {}
        print("PASS paused native HLS readiness, finite timeline, bounded seek and replacement/Stop/quit cleanup")

        var failedEnvironment = environment
        failedEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("failing-ffmpeg").path
        let failingPreparer = MediaPreparer(environment: failedEnvironment)
        let failingController = PlaybackController(resolveSource: { _ in source }, prepareSource: { try await failingPreparer.prepare($0) })
        try failingController.load("https://example.com/video")
        var sawHLSItem = false
        let failureDeadline = Date().addingTimeInterval(15)
        while failingController.snapshot.state != .failed, Date() < failureDeadline {
            sawHLSItem = sawHLSItem || (failingController.player.currentItem?.asset as? AVURLAsset)?.url.pathExtension == "m3u8"
            try await Task.sleep(for: .milliseconds(30))
        }
        try check(sawHLSItem, "Failure test never reached HLS handoff")
        try check(failingController.snapshot.errorReason == .preparationFailed
                  && failingController.player.currentItem == nil && failingController.player.isMuted,
                  "Post-handoff failure did not terminate playback")
        await failingController.shutdownAndWait()
        try check(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)) == originalWorkspaces,
                  "Producer cancellation/failure left session files behind")
        print("PASS producer failure after handoff without restarting playback")

        // A producer failure after handoff must end the item, not skip the queue.
        let playlistSource = ResolvedSource(url: URL(string: base + "/long.mp4")!, needsPreparation: true)
        let playlist = ResolvedPlaylist(title: "Queue", entries: [
            PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=aaaaaaaaaaa")!, title: "One"),
            PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=bbbbbbbbbbb")!, title: "Two")
        ], truncated: false)
        let queueController = PlaybackController(resolveSource: { _ in playlistSource },
            resolvePlaylist: { _ in playlist },
            prepareSource: { try await failingPreparer.prepare($0) })
        try queueController.load("https://www.youtube.com/playlist?list=testplaylist")
        let queueDeadline = Date().addingTimeInterval(15)
        while queueController.snapshot.state != .failed, Date() < queueDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        try check(queueController.snapshot.errorReason == .preparationFailed
                  && queueController.snapshot.queue?.currentIndex == 0,
                  "Post-handoff failure advanced the playlist")
        await queueController.shutdownAndWait()
        print("PASS producer failure after handoff does not advance a playlist")
    }
}
