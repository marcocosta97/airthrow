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
        environment.removeValue(forKey: "AIRTHROW_PREPARATION_MODE")
        environment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("paced-ffmpeg").path
        let preparer = MediaPreparer(environment: environment, preferences: PreparationPreferences(retainAll: true))
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
        for choice in [VideoEnhancement.cleanup1080, .upscale4K] {
            let controller = PlaybackController(resolveSource: { _ in source },
                prepareSource: { try await preparer.prepare($0) })
            try controller.load("https://example.com/video")
            var deadline = Date().addingTimeInterval(20)
            while controller.snapshot.state == .loading, Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(controller.snapshot.state == .awaitingReceiver, "Original progressive fixture did not load")
            try controller.selectEnhancement(choice)
            deadline = Date().addingTimeInterval(20)
            while controller.snapshot.state == .loading, Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            try check(controller.snapshot.state == .awaitingReceiver && controller.snapshot.duration == 20
                      && !controller.snapshot.isLive && controller.snapshot.preparationInProgress == true
                      && controller.snapshot.videoEnhancement == choice
                      && controller.player.rate == 0 && controller.player.isMuted,
                      "Progressive \(choice.rawValue) native player: \(String(decoding: try JSONEncoder().encode(controller.snapshot), as: UTF8.self))")
            let endpoint = (controller.player.currentItem!.asset as! AVURLAsset).url
            let (playlist, _) = try await fetch(endpoint)
            try check(!String(decoding: playlist, as: UTF8.self).contains("#EXT-X-ENDLIST"),
                      "Native enhanced player readiness waited for completion")
            try check((controller.snapshot.position ?? 99) < 1 && (controller.snapshot.seekableRanges.last?.end ?? 0) < 20,
                      "Enhanced growing HLS started at the live edge or exposed unprepared seeks")
            do { try controller.seek(19); try check(false, "Enhanced seek escaped the prepared range") }
            catch let error as AppFailure { try check(error.code == .unsupportedOperation, "Enhanced seek failed incorrectly") }
            await controller.shutdownAndWait()
            do { _ = try await fetch(endpoint); try check(false, "Enhanced shutdown retained delivery") }
            catch is URLError {}
        }
        print("PASS progressive cleanup/4K native controller readiness, finite timeline, bounded seek and shutdown")

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
                  && MediaHTTPServer.isSegmentName("segment1000000.m4s")
                  && !MediaHTTPServer.isSegmentName("segment.ts")
                  && !MediaHTTPServer.isSegmentName("segment1x.ts")
                  && !MediaHTTPServer.isSegmentName("segment000000.m4s.tmp")
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
        let fallback = try await MediaPreparer(environment: fallbackEnvironment, preferences: PreparationPreferences(retainAll: true)).prepare(source)
        try check(fallback.url.pathExtension == "mp4", "Startup failure did not use complete-file fallback")
        fallback.stop()
        print("PASS complete-file fallback before handoff")

        // Every enhancement hands off a verified buffer while encoding continues.
        // 4K uses HEVC/fMP4; no whole-file wait and no special environment opt-in.
        for choice in [VideoEnhancement.upscale1080, .cleanup1080, .upscale4K, .cleanup4K] {
            let started = Date()
            let enhanced = try await preparer.prepare(source.withEnhancement(choice))
            try check(enhanced.isProducing && enhanced.url.pathExtension == "m3u8"
                      && enhanced.videoHeight == choice.targetHeight,
                      "\(choice.rawValue) waited for a complete file or lost its output resolution")
            let (playlist, _) = try await fetch(enhanced.url)
            let text = String(decoding: playlist, as: UTF8.self)
            try check(!text.contains("#EXT-X-ENDLIST"), "\(choice.rawValue) was complete before handoff")
            if choice.targetHeight == 2160 {
                try check(text.contains("#EXT-X-MAP:URI=\"init.mp4\"") && text.contains(".m4s"),
                          "HEVC was not packaged as fragmented MP4")
                let initURL = enhanced.url.deletingLastPathComponent().appendingPathComponent("init.mp4")
                let (initialization, response) = try await fetch(initURL)
                let (head, headResponse) = try await fetch(initURL, method: "HEAD")
                let (partial, partialResponse) = try await fetch(initURL, range: "bytes=0-99")
                try check(response.value(forHTTPHeaderField: "Content-Type") == "video/mp4"
                          && initialization.count > 100 && head.isEmpty
                          && headResponse.expectedContentLength == initialization.count
                          && partialResponse.statusCode == 206 && partial == initialization.prefix(100),
                          "fMP4 initialization delivery failed")
                let (_, hidden) = try await fetch(enhanced.url.deletingLastPathComponent()
                    .appendingPathComponent("inspection.mp4"))
                try check(hidden.statusCode == 404, "Private segment inspection was served")
            }
            let asset = AVURLAsset(url: enhanced.url)
            try check(try await asset.load(.isPlayable), "Progressive \(choice.rawValue) is not natively playable")
            let ready = Date().timeIntervalSince(started)
            await enhanced.waitForProducer()
            try check(enhanced.productionFailure == nil, "\(choice.rawValue) failed after handoff")
            let (complete, _) = try await fetch(enhanced.url)
            try check(String(decoding: complete, as: UTF8.self).contains("#EXT-X-ENDLIST"),
                      "\(choice.rawValue) never finalized its playlist")
            enhanced.stop()
            print("PASS progressive \(choice.rawValue), playable before completion, ready in \(String(format: "%.2f", ready))s")
        }
        let encoded = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/long-vp9.mkv")!,
            needsPreparation: true, conversionPolicy: .allowVideo))
        try check(encoded.isProducing && encoded.url.pathExtension == "m3u8"
                  && encoded.playbackPath == .videoConversion,
                  "Unsupported format conversion waited for a complete file")
        encoded.stop()
        await encoded.waitForProducer()
        let audioConverted = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/long-flac.mkv")!,
            needsPreparation: true))
        try check(audioConverted.isProducing && audioConverted.url.pathExtension == "m3u8"
                  && audioConverted.playbackPath == .audioConversion,
                  "Audio conversion waited for a complete file")
        audioConverted.stop()
        await audioConverted.waitForProducer()
        let copiedHEVC = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/hevc-sdr.mkv")!,
            needsPreparation: true))
        let (hevcPlaylist, _) = try await fetch(copiedHEVC.url)
        try check(copiedHEVC.playbackPath == .remux && String(decoding: hevcPlaylist, as: UTF8.self).contains(".m4s"),
                  "Copied HEVC used MPEG-TS")
        try check(try await AVURLAsset(url: copiedHEVC.url).load(.isPlayable), "Copied HEVC HLS is not playable")
        copiedHEVC.stop()
        await copiedHEVC.waitForProducer()
        print("PASS default progressive unsupported-video/audio conversion, cancellation and HEVC remux")

        // Slow finite processing can buffer during playback, but it must still
        // publish its startup buffer rather than convert the whole file first.
        var slowEnvironment = environment
        slowEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("below-realtime-ffmpeg").path
        let slowPrepared = try await MediaPreparer(environment: slowEnvironment, preferences: PreparationPreferences(retainAll: true)).prepare(source.withEnhancement(.cleanup1080))
        try check(slowPrepared.isProducing && slowPrepared.url.pathExtension == "m3u8",
                  "Below-realtime finite conversion fell back to a whole-file wait")
        slowPrepared.stop()
        await slowPrepared.waitForProducer()
        print("PASS below-realtime finite processing hands off its buffer and cancels cleanly")


        var hardwareFailureEnvironment = environment
        hardwareFailureEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("hardware-failure-ffmpeg").path
        let recovered = try await MediaPreparer(environment: hardwareFailureEnvironment, preferences: PreparationPreferences(retainAll: true)).prepare(
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

        try FileManager.default.removeItem(at: directory.appendingPathComponent("encoder-attempts.txt"))
        let recoveredHEVC = try await MediaPreparer(environment: hardwareFailureEnvironment, preferences: PreparationPreferences(retainAll: true)).prepare(
            ResolvedSource(url: URL(string: base + "/combined.mp4")!).withEnhancement(.upscale4K))
        try check(recoveredHEVC.url.pathExtension == "m3u8" && recoveredHEVC.videoHeight == 2160,
                  "HEVC hardware startup failure did not recover through software HLS")
        let hevcAttempts = try String(contentsOf: directory.appendingPathComponent("encoder-attempts.txt"), encoding: .utf8)
        try check(hevcAttempts.split(separator: "\n") == ["hardware-preflight", "hardware-job", "software-job"],
                  "HEVC hardware was retried before software fallback: \(hevcAttempts)")
        recoveredHEVC.stop()
        await recoveredHEVC.waitForProducer()
        print("PASS HEVC hardware startup failure switches directly to software fragmented MP4")

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
            try check(failure == .storageLimit, "Aggregate HLS limit used the wrong error")
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
            try check(failure == .storageLimit, "Source-size pre-check used the wrong error")
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
        let highRate = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/highfps.mkv")!,
            needsPreparation: true, conversionPolicy: .allowVideo))
        try check(highRate.playbackPath == .videoConversion
                  && (highRate.videoFrameRate ?? 0) > 0
                  && (highRate.videoFrameRate ?? 0) <= 60.5,
                  "Progressive conversion reported the 100 fps source instead of bounded output")
        highRate.stop()
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
        let failingPreparer = MediaPreparer(environment: failedEnvironment, preferences: PreparationPreferences(retainAll: true))
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
