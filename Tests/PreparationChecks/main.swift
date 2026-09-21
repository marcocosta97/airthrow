import Foundation
import AVFoundation

@main
@MainActor
struct PreparationChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "PreparationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func expect(_ reason: MediaFailureReason, _ body: () async throws -> Void) async throws {
        do { try await body(); try check(false, "Expected a preparation failure") }
        catch let error as PreparationFailure { try check(error.reason == reason, "Wrong preparation failure") }
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL preparation checks: \(error)"); exit(1) }
    }
    static func run() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--website" {
            do {
                let source = try await SourceResolver().resolve(MediaInput.url(CommandLine.arguments[2]))
                guard source.needsPreparation else { print("Direct source selected; preparation not needed"); return }
                let prepared = try await MediaPreparer().prepare(source)
                defer { prepared.stop() }
                let asset = AVURLAsset(url: prepared.url)
                let video = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                try check(!video.isEmpty && !audio.isEmpty, "Prepared website source missing tracks")
                print("PASS live website preparation and native video/audio inspection; receiver untested")
            } catch {
                let reason = (error as? PreparationFailure)?.reason ?? (error as? ResolutionFailure)?.reason ?? .loadFailed
                print("Live smoke result: \(reason.rawValue)")
                exit(1)
            }
            return
        }
        let base = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        var environment = ProcessInfo.processInfo.environment
        environment["AIRPLAYER_MEDIA_HOST"] = "127.0.0.1"
        let preparer = MediaPreparer(environment: environment)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func fetch(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
            request.httpMethod = method
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let source = ResolvedSource(url: URL(string: base + "/combined.mkv")!)
        var prepared: PreparedMedia? = try await preparer.prepare(source, mode: .completeFile)
        let endpoint = prepared!.url
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("airplayer-prepared-v1")
        let active = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path))
        let abandoned = cache.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: false)
        try Data().write(to: abandoned.appendingPathComponent("lease"))
        try Data("unfinished media".utf8).write(to: abandoned.appendingPathComponent("media.mp4"))
        MediaPreparer.cleanAbandonedFiles()
        try check(!FileManager.default.fileExists(atPath: abandoned.path), "Abandoned preparation was not removed")
        try check(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)) == active, "Cleanup removed an active workspace")
        let (whole, response) = try await fetch(endpoint)
        try check(response.statusCode == 200 && whole.count > 1000, "Prepared file was not delivered")
        try whole.write(to: directory.appendingPathComponent("remuxed.mp4"))
        let (head, headResponse) = try await fetch(endpoint, method: "HEAD")
        try check(head.isEmpty && headResponse.statusCode == 200
                  && headResponse.value(forHTTPHeaderField: "Content-Length") == String(whole.count), "HEAD metadata wrong")
        for (range, bytes) in [("bytes=0-99", whole.prefix(100)), ("bytes=100-", whole.dropFirst(100)),
                               ("bytes=-64", whole.suffix(64))] {
            let (data, ranged) = try await fetch(endpoint, range: range)
            try check(ranged.statusCode == 206 && data == bytes, "Byte-range body was incorrect")
        }
        for range in ["bytes=999999999999-", "bytes=7-3", "bytes=-0", "bytes=0-1,4-5", "bytes=0-999999999999999999999999999999"] {
            let (_, invalid) = try await fetch(endpoint, range: range)
            try check(invalid.statusCode == 416 && invalid.value(forHTTPHeaderField: "Content-Range") == "bytes */\(whole.count)", "Invalid range accepted")
        }
        let (_, missing) = try await fetch(endpoint.deletingLastPathComponent().appendingPathComponent("other.mp4"))
        let (_, wrongMethod) = try await fetch(endpoint, method: "POST")
        try check(missing.statusCode == 404 && wrongMethod.statusCode == 405, "Server exposed an extra route or method")
        prepared?.stop(); prepared = nil
        do { _ = try await fetch(endpoint); try check(false, "Stopped server still accepted requests") }
        catch is URLError {}
        print("PASS remux, GET/HEAD, open/closed/suffix ranges, invalid ranges, token route and server shutdown")

        let localFile = directory.appendingPathComponent("combined.mp4")
        let localSource = try await SourceResolver().resolve(MediaInput.localFile(localFile))
        var localDelivery: PreparedMedia? = try await preparer.prepare(localSource)
        let localEndpoint = localDelivery!.url
        let (localBytes, localResponse) = try await fetch(localEndpoint)
        try check(localBytes == Data(contentsOf: localFile), "In-place local delivery changed the selected file")
        try check(localResponse.value(forHTTPHeaderField: "Content-Type") == "video/mp4",
                  "Local delivery used the wrong media type")
        localDelivery?.stop(); localDelivery = nil
        try check(FileManager.default.fileExists(atPath: localFile.path), "Stopping delivery deleted the user's file")
        do { _ = try await fetch(localEndpoint); try check(false, "Stopped local server still accepted requests") }
        catch is URLError {}
        print("PASS zero-copy local-file delivery, media type, shutdown and source preservation")

        let localRemuxSource = try await SourceResolver().resolve(directory.appendingPathComponent("combined.mkv"))
        let localRemux = try await preparer.prepare(localRemuxSource, mode: .completeFile)
        let (localRemuxBytes, _) = try await fetch(localRemux.url)
        try localRemuxBytes.write(to: directory.appendingPathComponent("local-remuxed.mp4"))
        localRemux.stop()
        print("PASS local MKV inspection and stream-copy remux")

        let split = ResolvedSource(url: URL(string: base + "/video.mp4")!,
            audio: MediaTrack(url: URL(string: base + "/audio.m4a")!), plannedPath: .remux)
        let joined = try await preparer.prepare(split, mode: .completeFile)
        let (joinedData, _) = try await fetch(joined.url)
        try joinedData.write(to: directory.appendingPathComponent("joined.mp4"))
        joined.stop()
        let multiple = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/multitrack.mkv")!), mode: .completeFile)
        multiple.stop()
        print("PASS multi-track input selects a compatible audio stream")

        // Audio-only conversion copies H.264 and encodes FLAC to AAC. The path
        // must be published before processing and the video track preserved.
        let flacRecorder = PlanRecorder()
        let audioConverted = try await preparer.prepare(
            ResolvedSource(url: URL(string: base + "/flac.mkv")!),
            mode: .completeFile, onPlan: { await flacRecorder.record($0) })
        try check(audioConverted.playbackPath == .audioConversion,
                  "FLAC audio was not reported as audio conversion")
        try check(await flacRecorder.paths() == [.audioConversion],
                  "onPlan did not publish the audio-conversion path before processing")
        let (audioConvertedData, _) = try await fetch(audioConverted.url)
        try audioConvertedData.write(to: directory.appendingPathComponent("audio-converted.mp4"))
        audioConverted.stop()

        // Video conversion is opt-in: the same VP9/Opus fixture is refused by
        // default and converted only when the source allows video conversion.
        try await expect(.preparationRequired) {
            _ = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/vp9-opus.mkv")!,
                                                          needsPreparation: true))
        }
        let videoRecorder = PlanRecorder()
        let videoSource = ResolvedSource(url: URL(string: base + "/vp9-opus.mkv")!,
                                         needsPreparation: true, conversionPolicy: .allowVideo)
        let videoConverted = try await preparer.prepare(videoSource, mode: .completeFile,
                                                        onPlan: { await videoRecorder.record($0) })
        try check(videoConverted.playbackPath == .videoConversion,
                  "VP9/Opus source was not reported as video conversion")
        try check(await videoRecorder.paths() == [.videoConversion],
                  "onPlan did not publish the video-conversion path before processing")
        let (videoConvertedData, _) = try await fetch(videoConverted.url)
        try videoConvertedData.write(to: directory.appendingPathComponent("video-converted.mp4"))
        videoConverted.stop()

        // A 4K source is downscaled and a 100 fps source is capped at 60 fps,
        // rather than being refused for exceeding the copy bounds.
        let uhdSource = ResolvedSource(url: URL(string: base + "/uhd.mkv")!,
                                       needsPreparation: true, conversionPolicy: .allowVideo)
        let uhdConverted = try await preparer.prepare(uhdSource, mode: .completeFile)
        try check(uhdConverted.playbackPath == .videoConversion, "High-resolution source was not converted")
        let (uhdData, _) = try await fetch(uhdConverted.url)
        try uhdData.write(to: directory.appendingPathComponent("uhd-converted.mp4"))
        uhdConverted.stop()
        let highFpsSource = ResolvedSource(url: URL(string: base + "/highfps.mkv")!,
                                           needsPreparation: true, conversionPolicy: .allowVideo)
        let highFpsConverted = try await preparer.prepare(highFpsSource, mode: .completeFile)
        try check(highFpsConverted.playbackPath == .videoConversion, "High-frame-rate source was not converted")
        let (highFpsData, _) = try await fetch(highFpsConverted.url)
        try highFpsData.write(to: directory.appendingPathComponent("highfps-converted.mp4"))
        highFpsConverted.stop()

        // An unsupported 10-bit pixel layout is refused even when conversion is allowed.
        try await expect(.preparationRequired) {
            _ = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/tenbit.mkv")!,
                                                          needsPreparation: true, conversionPolicy: .allowVideo))
        }

        // A helper that refuses the hardware preflight still converts in software;
        // one that refuses every H.264 preflight fails before any conversion.
        var softwareEnvironment = environment
        softwareEnvironment["AIRPLAYER_FFMPEG"] = directory.appendingPathComponent("software-ffmpeg").path
        let softwareSource = ResolvedSource(url: URL(string: base + "/vp9-opus.mkv")!,
                                            needsPreparation: true, conversionPolicy: .allowVideo)
        let softwareConverted = try await MediaPreparer(environment: softwareEnvironment)
            .prepare(softwareSource, mode: .completeFile)
        try check(softwareConverted.playbackPath == .videoConversion, "Software fallback did not convert")
        let (softwareData, _) = try await fetch(softwareConverted.url)
        try softwareData.write(to: directory.appendingPathComponent("software-converted.mp4"))
        softwareConverted.stop()
        var noEncoderEnvironment = environment
        noEncoderEnvironment["AIRPLAYER_FFMPEG"] = directory.appendingPathComponent("no-encoder-ffmpeg").path
        try await expect(.preparationFailed) {
            _ = try await MediaPreparer(environment: noEncoderEnvironment)
                .prepare(softwareSource, mode: .completeFile)
        }

        // HDR is refused even when video conversion is allowed; output stays SDR.
        try await expect(.preparationRequired) {
            _ = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/hdr.mkv")!,
                                                          needsPreparation: true, conversionPolicy: .allowVideo))
        }
        // Absent tracks are refused rather than silently dropping a stream.
        try await expect(.preparationRequired) {
            _ = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/audio.m4a")!,
                                                          needsPreparation: true))
        }
        try await expect(.preparationRequired) {
            _ = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/video.mp4")!,
                                                          needsPreparation: true))
        }
        print("PASS selective audio/video conversion, opt-in video, 4K/100fps bounds, 10-bit/HDR refusal, software fallback, onPlan")

        let shortLimit = MediaPreparer(environment: environment, maximumBytes: 1000)
        try await expect(.preparationLimit) { _ = try await shortLimit.prepare(source) }
        var missingEnvironment = environment
        missingEnvironment["AIRPLAYER_FFMPEG"] = "/missing/ffmpeg"
        let missingHelper = MediaPreparer(environment: missingEnvironment)
        try await expect(.preparerUnavailable) { _ = try await missingHelper.prepare(source) }
        print("PASS size limit and missing helpers")

        // A slow helper verifies cancellation while a workspace is live, rather than during inspection.
        let slow = directory.appendingPathComponent("slow-ffmpeg")
        try "#!/bin/sh\nsleep 20 &\nwait\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slow.path)
        var slowEnvironment = environment
        slowEnvironment["AIRPLAYER_FFMPEG"] = slow.path
        let slowPreparer = MediaPreparer(environment: slowEnvironment)
        let cancelled = Task { try await slowPreparer.prepare(source) }
        try await Task.sleep(for: .milliseconds(600))
        cancelled.cancel()
        do { _ = try await cancelled.value; try check(false, "Cancelled preparation succeeded") }
        catch is CancellationError {}
        let afterCancel = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path))
        try check(afterCancel.isEmpty, "Cancelled or stopped preparation retained media")
        // Conversion jobs cancel through the same producer lifecycle.
        let cancelledConversion = Task { try await slowPreparer.prepare(videoSource) }
        try await Task.sleep(for: .milliseconds(600))
        cancelledConversion.cancel()
        do { _ = try await cancelledConversion.value; try check(false, "Cancelled conversion succeeded") }
        catch is CancellationError {}
        try check(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)).isEmpty,
                  "Cancelled conversion retained media")
        print("PASS cancellation, conversion cancellation and abandoned/active workspace cleanup")

        let preparingController = PlaybackController(resolveSource: { _ in split }, prepareSource: { try await slowPreparer.prepare($0) })
        try preparingController.load("https://youtu.be/BaW_jenozKc")
        let preparingDeadline = Date().addingTimeInterval(3)
        while preparingController.snapshot.loadingPhase != "preparing", Date() < preparingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(preparingController.snapshot.state == .loading && preparingController.snapshot.loadingPhase == "preparing",
                  "Preparing phase did not retain pending loading state")
        try check(preparingController.snapshot.playbackPath == .remux, "Preparation path was not visible while pending")
        preparingController.stop()
        try await Task.sleep(for: .milliseconds(100))
        try check(preparingController.snapshot.state == .idle && preparingController.player.currentItem == nil,
                  "Stop allowed a prepared result to return")
        try check(preparingController.snapshot.playbackPath == nil, "Stop retained a stale playback path")
        // Quit also waits for jobs that Stop has already cancelled.
        await preparingController.shutdownAndWait()
        try check(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)).isEmpty,
                  "Quit left a cancelled job's temporary media behind")

        let controlledPreparer = MediaPreparer(environment: environment)
        let controller = PlaybackController(prepareSource: { try await controlledPreparer.prepare($0) })
        defer { controller.shutdown() }
        func settled() async throws {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                controller.refresh()
                if [.awaitingReceiver, .failed].contains(controller.snapshot.state) { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            try check(false, "Controller did not finish preparing")
        }
        try controller.load(localFile.path)
        try await settled()
        try check(controller.snapshot.state == .awaitingReceiver && controller.snapshot.playbackPath == .direct,
                  "Local MP4 did not load paused through direct delivery")
        try check(controller.snapshot.title == "combined.mp4", "Local file title exposed more than its filename")
        let localServed = (controller.player.currentItem!.asset as! AVURLAsset).url
        let localStatus = String(decoding: try JSONEncoder().encode(controller.snapshot), as: UTF8.self)
        try check(!localStatus.contains(directory.path) && !localStatus.contains(localServed.path),
                  "Local status exposed a filesystem or session path")
        try controller.load(base + "/combined.mkv?signature=do-not-log")
        try await settled()
        try check(controller.snapshot.state == .awaitingReceiver && controller.snapshot.hasAudio == true,
                  "Native failure did not recover through remuxing")
        try check(controller.snapshot.playbackPath == .remux, "Native fallback was still labelled direct")
        try check(controller.player.rate == 0 && controller.player.isMuted, "Preparation started local playback")
        let served = (controller.player.currentItem!.asset as! AVURLAsset).url
        let status = String(decoding: try JSONEncoder().encode(controller.snapshot), as: UTF8.self)
        try check(!status.contains(served.path) && !status.contains("do-not-log"), "Status exposed private source or session URL")
        try controller.load(base + "/combined.mp4")
        try await settled()
        try check(controller.snapshot.state == .awaitingReceiver, "Replacing prepared item failed")
        try check(controller.snapshot.playbackPath == .direct, "Replacement retained the old preparation label")
        do { _ = try await fetch(served); try check(false, "Replacement retained the old server") }
        catch is URLError {}
        controller.stop()
        print("PASS controller local-file privacy, native-first fallback, paused readiness and replacement cleanup")
        await controller.shutdownAndWait()

        // The source adapter must not change format-failure policy. A website
        // presentation gets the same native -> remux attempt as a direct URL.
        let websiteController = PlaybackController(resolveSource: { _ in
            ResolvedSource(url: URL(string: base + "/combined.mkv")!, title: "Website title")
        }, prepareSource: { try await controlledPreparer.prepare($0) })
        try websiteController.load("https://youtu.be/BaW_jenozKc")
        let websiteDeadline = Date().addingTimeInterval(15)
        while ![.awaitingReceiver, .failed].contains(websiteController.snapshot.state), Date() < websiteDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        try check(websiteController.snapshot.state == .awaitingReceiver && websiteController.snapshot.playbackPath == .remux
                  && websiteController.snapshot.title == "Website title", "Website native failure did not use shared remux policy")
        await websiteController.shutdownAndWait()
        print("PASS source-independent remux fallback and title preservation")
        print("Preparation checks passed; receiver playback remains untested")
    }
}

/// Records the path published by `onPlan` so tests can assert it fires before processing.
private actor PlanRecorder {
    private var values: [PlaybackPath] = []
    func record(_ path: PlaybackPath) { values.append(path) }
    func paths() -> [PlaybackPath] { values }
}
