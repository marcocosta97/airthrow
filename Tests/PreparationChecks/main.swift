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
    static func oddDimensions(_ url: URL) async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        let preparer = MediaPreparer(environment: environment)
        let source = ResolvedSource(url: url, needsPreparation: true)
        let player = AVPlayer()
        player.isMuted = true
        defer { player.replaceCurrentItem(with: nil) }
        for mode in [PreparationMode.completeFile, .progressiveHLS] {
            for enhancement in [VideoEnhancement.upscale1080, .cleanup1080, .upscale4K, .cleanup4K] {
                print("CHECK odd-width \(enhancement.rawValue), \(mode)")
                fflush(nil)
                let prepared = try await preparer.prepare(source.withConversionPolicy(.allowVideo).withEnhancement(enhancement), mode: mode)
                do {
                    try check(prepared.videoHeight == enhancement.targetHeight,
                              "Odd-width enhancement lost its output resolution")
                    try check(prepared.usesBoundedCache == (mode == .progressiveHLS),
                              "Odd-width enhancement did not use the requested preparation path")
                    let item = AVPlayerItem(url: prepared.url)
                    player.replaceCurrentItem(with: item)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                    while item.status != .failed, ContinuousClock.now < deadline,
                          item.status == .unknown || item.presentationSize.width == 0 {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try check(item.status == .readyToPlay, "Odd-width enhancement is not playable: \(String(describing: item.error))")
                    let size = item.presentationSize
                    try check(size.width >= 853 && size.height >= 480,
                              "Odd-width enhancement downscaled its source")
                    let types = item.tracks.compactMap { $0.assetTrack?.mediaType }
                    try check(types.contains(.video) && types.contains(.audio), "Odd-width enhancement lost video/audio")
                } catch {
                    player.replaceCurrentItem(with: nil)
                    prepared.stop(); await prepared.waitForProducer()
                    throw error
                }
                player.replaceCurrentItem(with: nil)
                prepared.stop(); await prepared.waitForProducer()
            }
        }
        print("PASS odd-width 853x480 upscale and cleanup at 1080p/4K, complete-file and bounded cache")
        fflush(nil)
    }
    static func run() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--odd-source" {
            try await oddDimensions(URL(string: CommandLine.arguments[2])!)
            return
        }
        if (3...4).contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--remote" {
            let input = try MediaInput.url(CommandLine.arguments[2])
            let policy: ConversionPolicy = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "allow-video"
                ? .allowVideo : .avoidVideo
            let source = try await SourceResolver().resolve(input, policy: policy)
            try check(source.needsPreparation && source.playbackPath == .remux,
                      "Remote container did not enter preparation")
            var environment = ProcessInfo.processInfo.environment
            environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
            let prepared = try await MediaPreparer(environment: environment, preferences: PreparationPreferences(retainAll: true)).prepare(source,
                onPlan: { print("Remote inspection selected \($0.label)") })
            defer { prepared.stop() }
            try check(prepared.videoHeight != nil, "Remote inspection lost video quality")
            await prepared.waitForProducer()
            try check(prepared.productionFailure == nil, "Remote production failed after initial readiness")
            let asset = AVURLAsset(url: prepared.url)
            try check(try await asset.load(.isPlayable), "Prepared remote source is not natively playable")
            print("PASS remote \(prepared.videoHeight!)p \(prepared.playbackPath.label) with playable native asset; receiver untested")
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--website" {
            do {
                let source = try await SourceResolver().resolve(MediaInput.url(CommandLine.arguments[2]))
                guard source.needsPreparation else { print("Direct source selected; preparation not needed"); return }
                let prepared = try await MediaPreparer(preferences: PreparationPreferences(retainAll: true)).prepare(source)
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
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        let preparer = MediaPreparer(environment: environment, preferences: PreparationPreferences(retainAll: true))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func fetch(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
            request.httpMethod = method
            request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let nativeStreamURL = URL(string: base + "/native-stream?signature=do-not-log")!
        let nativeStream = try await SourceResolver(environment: ["AIRTHROW_YTDLP": "/usr/bin/false"])
            .resolve(nativeStreamURL)
        try check(nativeStream.url == nativeStreamURL && nativeStream.videoKnownPresent && !nativeStream.needsPreparation,
                  "Extensionless HLS did not enter the native-first path")
        for choice in [VideoEnhancement.upscale1080, .cleanup1080] {
            let enhanced = try await preparer.prepare(nativeStream.withConversionPolicy(.allowVideo).withEnhancement(choice), mode: .completeFile)
            try check(enhanced.playbackPath == .videoConversion && enhanced.videoHeight == 1080,
                      "Native-first extensionless HLS enhancement did not produce 1080p video")
            let asset = AVURLAsset(url: enhanced.url)
            try check(try await asset.load(.isPlayable), "Enhanced native HLS output was not playable")
            try check(try await !asset.loadTracks(withMediaType: .video).isEmpty,
                      "Enhanced native HLS output lost its video")
            try check(try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                      "Enhanced native HLS output lost its audio")
            let (data, _) = try await fetch(enhanced.url)
            try data.write(to: directory.appendingPathComponent("native-hls-\(choice.rawValue).mp4"))
            enhanced.stop()
        }
        print("PASS native-first extensionless HLS upscale and cleanup output with playable video and audio")
        try await oddDimensions(URL(string: base + "/odd-width.mkv")!)
        let source = ResolvedSource(url: URL(string: base + "/combined.mkv")!)
        var prepared: PreparedMedia? = try await preparer.prepare(source, mode: .completeFile)
        let endpoint = prepared!.url
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("athrow-prepared-v1")
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

        // A finite text-subtitle input must keep both languages as native MP4
        // tracks, even if progressive delivery was requested for other media.
        let subtitleSource = ResolvedSource(url: URL(string: base + "/subtitles.mkv")!)
        let subtitleMedia = try await preparer.prepare(subtitleSource, mode: .progressiveHLS)
        try check(subtitleMedia.url.pathExtension == "mp4",
                  "Finite subtitle input was sent through MPEG-TS instead of native MP4")
        let (subtitleBytes, subtitleResponse) = try await fetch(subtitleMedia.url)
        try check(subtitleResponse.statusCode == 200 && subtitleBytes.count > 1000,
                  "Prepared file with subtitles was not delivered")
        try subtitleBytes.write(to: directory.appendingPathComponent("subtitle-remuxed.mp4"))
        let subtitleAsset = AVURLAsset(url: subtitleMedia.url)
        let subtitleGroup = try await subtitleAsset.loadMediaSelectionGroup(for: .legible)
        try check((subtitleGroup?.options.count ?? 0) >= 2 &&
                  subtitleGroup?.options.contains(where: { $0.locale?.identifier.hasPrefix("it") == true }) == true &&
                  subtitleGroup?.options.contains(where: { $0.locale?.identifier.hasPrefix("en") == true }) == true,
                  "Prepared file did not expose both native subtitle languages: \(subtitleGroup?.options.map { "\($0.displayName):\($0.locale?.identifier ?? "nil")" } ?? [])")
        subtitleMedia.stop()
        print("PASS finite remux retains two selectable text subtitle tracks")

        // Live MPEG-TS does not carry soft text tracks yet. A subtitle-bearing
        // source must still keep its video/audio playback path working.
        let liveSubtitleSource = ResolvedSource(url: URL(string: base + "/subtitles.mkv")!,
                                                isLive: true)
        let liveSubtitleMedia = try await preparer.prepare(liveSubtitleSource)
        try check(liveSubtitleMedia.url.pathExtension == "m3u8",
                  "Live subtitle source did not use HLS delivery")
        await liveSubtitleMedia.waitForProducer()
        try check(liveSubtitleMedia.productionFailure == nil,
                  "Live subtitle source failed to prepare video and audio")
        liveSubtitleMedia.stop()
        print("PASS live preparation retains video/audio with unsupported text subtitles")

        let liveHEVC = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/hevc-sdr.mkv")!, isLive: true))
        let (liveHEVCPlaylist, _) = try await fetch(liveHEVC.url)
        try check(String(decoding: liveHEVCPlaylist, as: UTF8.self).contains("#EXT-X-MAP:URI=\"init.mp4\"")
                  && liveHEVC.playbackPath == .remux, "Live HEVC did not use fragmented MP4")
        try check(try await AVURLAsset(url: liveHEVC.url).load(.isPlayable), "Live HEVC HLS is not playable")
        await liveHEVC.waitForProducer()
        try check(liveHEVC.productionFailure == nil, "Live HEVC producer failed")
        liveHEVC.stop()
        print("PASS live HEVC retains copied tracks in playable fragmented MP4")

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

        let mpegURL = directory.appendingPathComponent("synthetic.mpg")
        let mpegSource = try await SourceResolver().resolve(mpegURL, policy: .allowVideo)
        try check(mpegSource.needsPreparationPipeline, "MPEG-PS bypassed inspection")
        do {
            _ = try await preparer.prepare(mpegSource.withConversionPolicy(.avoidVideo))
            try check(false, "MPEG-2 video bypassed opt-in conversion")
        } catch let PreparationFailure.videoConversionRequired(height, _) {
            try check(height == 180, "MPEG fixture quality was not inspected")
        }
        let mpegConverted = try await preparer.prepare(mpegSource)
        try check(mpegConverted.playbackPath == .videoConversion && mpegConverted.videoHeight == 180,
                  "MPEG-PS conversion lost the source's path or quality")
        let mpegAsset = AVURLAsset(url: mpegConverted.url)
        try check(try await mpegAsset.load(.isPlayable), "Converted MPEG-PS is not playable")
        mpegConverted.stop()
        print("PASS synthetic MPEG-PS inspection, opt-in conversion and playable HLS")

        let split = ResolvedSource(url: URL(string: base + "/video.mp4")!,
            audio: MediaTrack(url: URL(string: base + "/audio.m4a")!), plannedPath: .remux)
        let joined = try await preparer.prepare(split, mode: .completeFile)
        let (joinedData, _) = try await fetch(joined.url)
        try joinedData.write(to: directory.appendingPathComponent("joined.mp4"))
        joined.stop()
        let multiple = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/multitrack.mkv")!), mode: .completeFile)
        try check(multiple.videoHeight != nil, "Inspected video resolution was not retained")
        multiple.stop()
        for ext in ["mkv", "webm", "mpg", "mpeg"] {
            let url = URL(string: "https://example.com/movie.\(ext)?token=private")!
            let source = try await SourceResolver().resolve(url)
            try check(source.needsPreparationPipeline && source.playbackPath == .remux,
                      "Remote \(ext) was incorrectly handed to native playback")
            try check(source.url == url, "Signed remote source URL changed")
        }
        for ext in ["mp4", "m3u8", "unknown"] {
            let source = try await SourceResolver().resolve(URL(string: "https://example.com/movie.\(ext)")!)
            try check(!source.needsPreparationPipeline && source.playbackPath == .direct,
                      "Native-first behavior changed for \(ext)")
        }
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
        do {
            _ = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/vp9-opus.mkv")!,
                                                          needsPreparation: true))
            try check(false, "Video conversion bypassed its preference")
        } catch let PreparationFailure.videoConversionRequired(height, _) {
            try check(height != nil, "Rejected conversion lost inspected quality")
        }
        let videoRecorder = PlanRecorder()
        let videoSource = ResolvedSource(url: URL(string: base + "/vp9-opus.mkv")!,
                                         needsPreparation: true, conversionPolicy: .allowVideo)
        let videoConverted = try await preparer.prepare(videoSource, mode: .completeFile,
                                                        onPlan: { await videoRecorder.record($0) })
        try check(videoConverted.playbackPath == .videoConversion,
                  "VP9/Opus source was not reported as video conversion")
        try check(videoConverted.videoHeight != nil, "Converted output resolution was not reported")
        try check(await videoRecorder.paths() == [.videoConversion],
                  "onPlan did not publish the video-conversion path before processing")
        let (videoConvertedData, _) = try await fetch(videoConverted.url)
        try videoConvertedData.write(to: directory.appendingPathComponent("video-converted.mp4"))
        videoConverted.stop()

        // Compatible 4K SDR video is copied through a remux. An explicitly
        // requested 1080p enhancement must not downscale it.
        let uhdSource = ResolvedSource(url: URL(string: base + "/uhd.mkv")!,
                                       needsPreparation: true, conversionPolicy: .allowVideo)
        let uhdConverted = try await preparer.prepare(uhdSource, mode: .completeFile)
        try check(uhdConverted.playbackPath == .remux && uhdConverted.videoHeight == 2160,
                  "Compatible 4K source was not remuxed at native resolution")
        let (uhdData, _) = try await fetch(uhdConverted.url)
        try uhdData.write(to: directory.appendingPathComponent("uhd-converted.mp4"))
        uhdConverted.stop()
        let hevcCopy = try await preparer.prepare(
            ResolvedSource(url: URL(string: base + "/hevc-sdr.mkv")!, needsPreparation: true), mode: .completeFile)
        try check(hevcCopy.playbackPath == .remux && hevcCopy.videoHeight == 180,
                  "Compatible SDR HEVC was not remuxed")
        let (hevcData, _) = try await fetch(hevcCopy.url)
        try hevcData.write(to: directory.appendingPathComponent("hevc-remuxed.mp4"))
        hevcCopy.stop()
        do {
            _ = try await preparer.prepare(uhdSource.withConversionPolicy(.allowVideo).withEnhancement(.upscale1080))
            try check(false, "Explicit 1080p preparation downscaled a 4K source")
        } catch PreparationFailure.conversionWouldDownscale {}
        for choice in [VideoEnhancement.upscale1080, .cleanup1080, .upscale4K, .cleanup4K] {
            print("Checking enhancement \(choice.rawValue)")
            let enhanced = try await preparer.prepare(source.withConversionPolicy(.allowVideo).withEnhancement(choice), mode: .completeFile)
            try check(enhanced.playbackPath == .videoConversion
                      && enhanced.videoHeight == choice.targetHeight,
                      "Enhancement did not produce its selected output height")
            let (data, _) = try await fetch(enhanced.url)
            try data.write(to: directory.appendingPathComponent("\(choice.rawValue).mp4"))
            enhanced.stop()
        }
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
        try await expect(.preparationRequired) {
            _ = try await preparer.prepare(ResolvedSource(url: URL(string: base + "/hdr.mkv")!)
                .withConversionPolicy(.allowVideo).withEnhancement(.upscale4K))
        }

        // A helper that refuses the hardware preflight still converts in software;
        // one that refuses every H.264 preflight fails before any conversion.
        var softwareEnvironment = environment
        softwareEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("software-ffmpeg").path
        let softwareSource = ResolvedSource(url: URL(string: base + "/vp9-opus.mkv")!,
                                            needsPreparation: true, conversionPolicy: .allowVideo)
        let softwareConverted = try await MediaPreparer(environment: softwareEnvironment, preferences: PreparationPreferences(retainAll: true))
            .prepare(softwareSource, mode: .completeFile)
        try check(softwareConverted.playbackPath == .videoConversion, "Software fallback did not convert")
        let (softwareData, _) = try await fetch(softwareConverted.url)
        try softwareData.write(to: directory.appendingPathComponent("software-converted.mp4"))
        softwareConverted.stop()
        let software4K = try await MediaPreparer(environment: softwareEnvironment, preferences: PreparationPreferences(retainAll: true))
            .prepare(source.withConversionPolicy(.allowVideo).withEnhancement(.upscale4K), mode: .completeFile)
        try check(software4K.videoHeight == 2160, "4K software fallback did not upscale")
        let (software4KData, _) = try await fetch(software4K.url)
        try software4KData.write(to: directory.appendingPathComponent("software-4k.mp4"))
        software4K.stop()
        var noEncoderEnvironment = environment
        noEncoderEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("no-encoder-ffmpeg").path
        try await expect(.preparationFailed) {
            _ = try await MediaPreparer(environment: noEncoderEnvironment, preferences: PreparationPreferences(retainAll: true))
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
        try await expect(.preparationStorageLimit) { _ = try await shortLimit.prepare(source) }
        var missingEnvironment = environment
        missingEnvironment["AIRTHROW_FFMPEG"] = "/missing/ffmpeg"
        let missingHelper = MediaPreparer(environment: missingEnvironment, preferences: PreparationPreferences(retainAll: true))
        try await expect(.preparerUnavailable) { _ = try await missingHelper.prepare(source) }
        print("PASS size limit and missing helpers")

        // A slow helper verifies cancellation while a workspace is live, rather than during inspection.
        let slow = directory.appendingPathComponent("slow-ffmpeg")
        try "#!/bin/sh\nsleep 20 &\nwait\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slow.path)
        var slowEnvironment = environment
        slowEnvironment["AIRTHROW_FFMPEG"] = slow.path
        let slowPreparer = MediaPreparer(environment: slowEnvironment, preferences: PreparationPreferences(retainAll: true))
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

        let controlledPreparer = MediaPreparer(environment: environment, preferences: PreparationPreferences(retainAll: true))
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
