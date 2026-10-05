import Foundation
import AVFoundation

struct MediaCase: Codable {
    let name: String
    let path: String?
    let container: String
    let videoCodec: String
    let audioCodec: String
    let expectedState: String?
    let expectedAudio: Bool?
    let skipped: String?
}

struct MediaResult: Encodable {
    let source: MediaCase
    let loadState: String
    let hasAudio: Bool?
    let errorReason: String?
    // Readiness is not proof that samples decode or play on an AirPlay receiver.
    let receiverPicture = "untested"
    let receiverSound = "untested"
    let receiverSeeking = "untested"
    let receiverRemote = "untested"
}

@main
struct MediaChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "MediaChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected server URL and fixture manifest"])
        }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "MediaChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let secret = "https://example.com/private?signature=do-not-log"
        func av(_ code: AVError.Code, underlying: NSError? = nil) -> NSError {
            var info: [String: Any] = [NSLocalizedDescriptionKey: secret]
            if let underlying { info[NSUnderlyingErrorKey] = underlying }
            return NSError(domain: AVFoundationErrorDomain, code: code.rawValue, userInfo: info)
        }
        let network = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
                              userInfo: [NSURLErrorFailingURLStringErrorKey: secret])
        let examples: [(NSError?, MediaFailureReason)] = [
            (av(.unknown, underlying: network), .network),
            (av(.fileFailedToParse, underlying: network), .network),
            (av(.fileFormatNotRecognized), .unreadableMedia),
            (av(.decoderNotFound), .unreadableMedia),
            (av(.externalPlaybackNotSupportedForAsset), .externalPlaybackUnsupported),
            (av(.contentIsProtected), .protectedMedia),
            (av(.contentIsUnavailable), .sourceUnavailable),
            (av(.decoderTemporarilyUnavailable), .loadFailed),
            (av(.serverIncorrectlyConfigured), .loadFailed),
            (nil, .loadFailed)
        ]
        for (error, expected) in examples {
            let reason = MediaDiagnostics.reason(for: error, fallback: .loadFailed)
            try check(reason == expected, "Incorrect classification: \(expected)")
            try check(!reason.message.contains(secret), "Diagnostic leaked source data")
        }
        try check(MediaDiagnostics.reason(for: nil, fallback: .playbackInterrupted) == .playbackInterrupted,
                  "Unknown playback failure was attributed to a codec")
        // Optional diagnostics preserve decoding of existing protocol-v1 snapshots.
        let old = Data(#"{"state":"idle","externalPlaybackActive":false,"seekableRanges":[],"title":"No video loaded","isLive":false}"#.utf8)
        try check(try JSONDecoder().decode(PlaybackSnapshot.self, from: old).errorReason == nil,
                  "Legacy status no longer decodes")

        let base = CommandLine.arguments[1]
        let cases = try JSONDecoder().decode([MediaCase].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        // Exercise the real bounded HTTP reader, including a response with no
        // Content-Length, so a chunked/unbounded body cannot bypass the limit.
        for path in ["oversized-master", "oversized-stream", "missing-master"] {
            do {
                _ = try await HLSMaster.fetch(URL(string: base + "/" + path)!)
                try check(false, "Invalid manifest response was accepted")
            } catch is ResolutionFailure {}
        }
        let cancelledFetch = Task { try await HLSMaster.fetch(URL(string: base + "/slow.mp4")!) }
        try await Task.sleep(for: .milliseconds(100))
        cancelledFetch.cancel()
        do {
            _ = try await cancelledFetch.value
            try check(false, "Cancelled manifest fetch returned data")
        } catch is CancellationError {} catch let error as URLError {
            try check(error.code == .cancelled, "Manifest cancellation returned wrong error")
        }
        if cases.contains(where: { $0.name == "HLS alternate audio" }) {
            let url = URL(string: base + "/alternate-audio.m3u8")!
            let data = try await HLSMaster.fetch(url)
            try check(HLSMaster.hasAudioVideo(data, at: url), "Local alternate-audio master was not recognized")
            let options = HLSMaster.audioOptions(data, at: url)
            try check(options.count == 2 && options[1].isOriginal && options[1].language == "it",
                      "Local master did not expose the Italian original and English dub")
            let audioController = PlaybackController(resolveCandidates: { _ in [
                MediaCandidate(source: ResolvedSource(url: url, hlsAudioOptions: options,
                                                      delivery: .hls, videoKnownPresent: true),
                               height: 180)
            ] }, prepareSource: nil)
            try audioController.load(url.absoluteString)
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline && audioController.snapshot.state != .awaitingReceiver {
                if audioController.snapshot.state == .failed { break }
                try await Task.sleep(for: .milliseconds(50))
                audioController.refresh()
            }
            try check(audioController.snapshot.state == .awaitingReceiver,
                      "Direct alternate-audio item did not become ready")
            let italianID = audioController.snapshot.audioOptions?.first(where: { $0.label.contains("Italiano") })?.id
            let englishID = audioController.snapshot.audioOptions?.first(where: { $0.label.contains("English") })?.id
            try check(italianID != nil && englishID != nil && audioController.snapshot.selectedAudioID == italianID,
                      "Direct HLS did not select the original Italian track by default")
            let directItem = audioController.player.currentItem!
            let group = try await directItem.asset.loadMediaSelectionGroup(for: .audible)
            try check(group?.options.count == 2,
                      "AVPlayer did not expose both direct HLS audio tracks")
            try check(group.flatMap { directItem.currentMediaSelection.selectedMediaOption(in: $0) }?.locale?.identifier.hasPrefix("it") == true,
                      "AVPlayer selected the English dub instead of Italian original")
            try audioController.selectAudio(englishID!)
            try check(audioController.player.currentItem === directItem && audioController.player.rate == 0,
                      "Direct audio switch replaced the player item or started playback")
            try check(group.flatMap { directItem.currentMediaSelection.selectedMediaOption(in: $0) }?.locale?.identifier.hasPrefix("en") == true,
                      "Direct audio switch did not select the English track")
            await audioController.shutdownAndWait()
        }
        if cases.contains(where: { $0.name == "MP4 selectable subtitles" && $0.path != nil }) {
            let url = URL(string: base + "/direct-subtitles.mp4")!
            let subtitleController = PlaybackController(prepareSource: nil)
            try subtitleController.load(url.absoluteString)
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline && subtitleController.snapshot.state != .awaitingReceiver {
                if subtitleController.snapshot.state == .failed { break }
                try await Task.sleep(for: .milliseconds(50))
                subtitleController.refresh()
            }
            try check(subtitleController.snapshot.state == .awaitingReceiver,
                      "Direct subtitle item did not become ready")
            let options = subtitleController.snapshot.subtitleOptions ?? []
            try check(options.count >= 2 && options.contains(where: { $0.label == "Off" }),
                      "Direct MP4 did not expose native subtitle tracks and Off")
            let item = subtitleController.player.currentItem!
            let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
            try check((group?.options.count ?? 0) >= 2 &&
                      group?.options.contains(where: { $0.locale?.identifier.hasPrefix("it") == true }) == true &&
                      group?.options.contains(where: { $0.locale?.identifier.hasPrefix("en") == true }) == true,
                      "AVPlayer did not expose both MP4 subtitle languages")
            guard let italian = options.first(where: { $0.label.localizedCaseInsensitiveContains("Italian") })
                ?? options.first(where: { $0.label != "Off" }) else {
                throw NSError(domain: "MediaChecks", code: 3)
            }
            try subtitleController.selectSubtitle(italian.id)
            try check(subtitleController.player.currentItem === item && subtitleController.player.rate == 0,
                      "Subtitle selection replaced the player item or started playback")
            try check(subtitleController.snapshot.selectedSubtitleID == italian.id,
                      "Selected native subtitle did not appear in status")
            if let off = options.first(where: { $0.label == "Off" }) {
                try subtitleController.selectSubtitle(off.id)
                try check(subtitleController.snapshot.selectedSubtitleID == off.id,
                          "Turning subtitles off did not update status")
            }
            await subtitleController.shutdownAndWait()
        }
        if cases.contains(where: { $0.name == "HLS selectable subtitles" && $0.path != nil }) {
            let url = URL(string: base + "/alternate-subtitles.m3u8")!
            let controller = PlaybackController(resolveCandidates: { _ in [
                MediaCandidate(source: ResolvedSource(url: url, delivery: .hls,
                                                      videoKnownPresent: true), height: 180)
            ] }, prepareSource: nil)
            try controller.load(url.absoluteString)
            let deadline = Date().addingTimeInterval(25)
            while Date() < deadline && controller.snapshot.state != .awaitingReceiver {
                if controller.snapshot.state == .failed { break }
                try await Task.sleep(for: .milliseconds(50))
                controller.refresh()
            }
            try check(controller.snapshot.state == .awaitingReceiver,
                      "Direct HLS subtitle item did not become ready")
            let options = controller.snapshot.subtitleOptions ?? []
            try check(options.contains(where: { $0.label == "Italian" }) &&
                      options.contains(where: { $0.label == "English" }),
                      "Direct HLS WebVTT alternatives were unavailable: \(options.map(\.label))")
            let item = controller.player.currentItem!
            let selected = options.first(where: { $0.label == "Italian" })!
            try controller.selectSubtitle(selected.id)
            try check(controller.snapshot.selectedSubtitleID == selected.id && controller.player.currentItem === item,
                      "HLS subtitle switch replaced the player item")
            try controller.selectSource("automatic")
            let reloadDeadline = Date().addingTimeInterval(25)
            while Date() < reloadDeadline && controller.snapshot.state != .awaitingReceiver {
                if controller.snapshot.state == .failed { break }
                try await Task.sleep(for: .milliseconds(50))
                controller.refresh()
            }
            try check(controller.snapshot.state == .awaitingReceiver,
                      "HLS source reload after subtitle selection did not become ready")
            let replacement = controller.player.currentItem!
            let replacementGroup = try await replacement.asset.loadMediaSelectionGroup(for: .legible)
            try check(replacementGroup.flatMap {
                replacement.currentMediaSelection.selectedMediaOption(in: $0)
            }?.locale?.identifier.hasPrefix("it") == true,
                      "Source reload did not retain the selected subtitle language")
            await controller.shutdownAndWait()
        }
        let controller = PlaybackController(prepareSource: nil)
        defer { controller.shutdown() }
        func settled(states: [PlaybackState] = [.awaitingReceiver, .failed], audio: Bool? = nil) async throws -> PlaybackSnapshot {
            let deadline = Date().addingTimeInterval(35)
            while Date() < deadline {
                controller.refresh()
                if let audio, controller.snapshot.hasAudio != nil {
                    try check(controller.snapshot.hasAudio == audio, "Audio discovery reported incorrect presence")
                }
                if states.contains(controller.snapshot.state),
                   audio == nil || controller.snapshot.hasAudio == audio || controller.snapshot.state == .failed {
                    return controller.snapshot
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "MediaChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Media load did not settle"])
        }
        var results: [MediaResult] = []
        for source in cases {
            guard let path = source.path else {
                results.append(MediaResult(source: source, loadState: "skipped", hasAudio: nil, errorReason: nil))
                continue
            }
            try controller.load(base + "/" + path + "?signature=do-not-log")
            let status = try await settled(audio: source.expectedAudio)
            if let expected = source.expectedState {
                try check(status.state.rawValue == expected, "\(source.name): expected \(expected), got \(status.state.rawValue)")
            }
            if status.state == .awaitingReceiver, let expected = source.expectedAudio {
                try check(status.hasAudio == expected, "\(source.name): wrong audio detection")
            }
            try check(controller.player.rate == 0 && controller.player.isMuted, "Inspection started local playback")
            let encoded = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
            try check(!encoded.contains("do-not-log"), "Status leaked a signed query")
            if source.name == "HLS video only" {
                try check(status.hasAudio != true, "Silent HLS incorrectly reported an audio track")
            }
            if source.name == "Audio only" || source.name == "HLS audio only" { try check(status.errorReason == .noVideo, "Audio-only source was not distinguished") }
            results.append(MediaResult(source: source, loadState: status.state.rawValue,
                hasAudio: status.hasAudio, errorReason: status.errorReason?.rawValue))
            controller.stop()
            try check(controller.snapshot.errorReason == nil && controller.snapshot.error == nil, "Stop retained failure details")
        }

        // Repeated replacements cover the observed race between readiness and HLS track discovery.
        if let path = cases.first(where: { $0.name == "HLS with audio" })?.path {
            try controller.load(base + "/video.mp4")
            _ = try await settled(audio: false)
            try controller.load(base + "/hls-no-extension")
            let switched = try await settled(audio: true)
            try check(switched.state == .awaitingReceiver && controller.player.rate == 0,
                      "MP4 to extensionless HLS replacement failed or started playback")
            for index in 0..<8 {
                let source = index.isMultiple(of: 2) ? path : "hls-no-extension"
                try controller.load(base + "/" + source)
                let status = try await settled(audio: true)
                try check(status.state == .awaitingReceiver && controller.player.rate == 0,
                          "Repeated HLS replacement failed or started playback")
            }
            controller.stop()
        }

        // Exercise the notification path, redaction, failure retention, and recovery on a real item.
        try controller.load(base + "/video.mp4")
        try check(try await settled().state == .awaitingReceiver, "Could not load notification fixture")
        let oldItem = controller.player.currentItem!
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: av(.unknown, underlying: network)])
        try await Task.sleep(for: .milliseconds(100))
        controller.refresh()
        try check(controller.snapshot.state == .failed && controller.snapshot.errorReason == .network,
                  "Playback error notification lost its underlying network reason")
        try check(controller.player.isMuted && controller.player.rate == 0, "Failed playback was not stopped")
        try check(controller.player.currentItem == nil, "Failed item remained attached to the player")
        try controller.load(base + "/video.mp4")
        try check(controller.snapshot.errorReason == nil, "Replacement retained old diagnostic")
        try check(try await settled().state == .awaitingReceiver, "Failed load did not recover")
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: av(.decodeFailed)])
        try await Task.sleep(for: .milliseconds(100))
        try check(controller.snapshot.errorReason == nil, "Stale item changed new session diagnostics")
        controller.stop()
        try controller.load(base + "/slow.mp4")
        controller.stop()
        try await Task.sleep(for: .milliseconds(500))
        try check(controller.snapshot.state == .idle && controller.snapshot.errorReason == nil, "Cancelled load published a failure")

        if let videoHLS = cases.first(where: { $0.name == "HLS with audio" })?.path,
           let audioHLS = cases.first(where: { $0.name == "HLS audio only" })?.path {
            controller.pickerWillOpen()
            controller.pickerDidClose()
            try controller.load(base + "/" + audioHLS)
            let audioStatus = try await settled()
            try check(audioStatus.errorReason == .noVideo && controller.player.rate == 0 && controller.player.isMuted,
                      "Receiver-first audio-only HLS started playback")
            try controller.load(base + "/" + videoHLS)
            let videoStatus = try await settled(states: [.connecting, .failed], audio: true)
            try check(videoStatus.state == .connecting && videoStatus.hasAudio == true && controller.player.isMuted,
                      "Receiver-first HLS did not defer negotiation until video/audio discovery")
            controller.stop()
        }

        // The resolver is injected so lifecycle and expiry tests never depend on a live website.
        controller.shutdown()
        func waitForResolved(_ target: PlaybackController) async throws {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline {
                target.refresh()
                if [.awaitingReceiver, .failed].contains(target.snapshot.state) { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            try check(false, "Resolved load did not settle")
        }
        if cases.contains(where: { $0.name == "HLS without URL extension" && $0.path != nil }) {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("athrow-native-fallback-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let helper = scratch.appendingPathComponent("yt-dlp")
            let callsFile = scratch.appendingPathComponent("calls")
            try "#!/bin/sh\necho call >> '\(callsFile.path)'\nprintf '%s' '{\"_type\":\"video\",\"formats\":[]}'\n"
                .write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let environment = ["AIRTHROW_YTDLP": helper.path, "AIRTHROW_DENO": "/missing/deno"]
            let nativeResolver = SourceResolver(environment: environment)
            let direct = try await nativeResolver.resolve(URL(string: base + "/hls-no-extension?signature=do-not-log")!)
            try check(direct.videoKnownPresent && !direct.needsPreparation,
                      "Native probe did not recognize extensionless HLS")
            try check(!FileManager.default.fileExists(atPath: callsFile.path),
                      "Playable extensionless HLS invoked yt-dlp")
            let start = ContinuousClock.now
            let slowURL = URL(string: base + "/slow.mp4")!
            try check(try await !NativeSourceProbe.hasPlayableVideo(at: slowURL, timeout: .milliseconds(100)),
                      "Native probe ignored its deadline")
            try check(start.duration(to: .now) < .seconds(1), "Native probe did not promptly cancel timed-out loading")
            let cancellationStart = ContinuousClock.now
            let probe = Task { try await NativeSourceProbe.hasPlayableVideo(at: slowURL) }
            try await Task.sleep(for: .milliseconds(50))
            probe.cancel()
            do { _ = try await probe.value; try check(false, "Cancelled native inspection returned a result") }
            catch is CancellationError {}
            try check(cancellationStart.duration(to: .now) < .seconds(1), "Native inspection ignored cancellation")
            // Force inconclusive native inspection to retain the previous
            // successful-but-unusable extraction regression coverage.
            let adapter = YTDLPSourceAdapter(environment: environment, nativeProbe: { _ in false })
            let resolver = SourceResolver(environment: environment, registry: try SourceRegistry(adapters: [adapter]))
            let nativeFallback = PlaybackController(resolveCandidates: { try await resolver.candidates(for: $0) }, prepareSource: nil)
            try nativeFallback.load(base + "/hls-no-extension?signature=do-not-log")
            try await waitForResolved(nativeFallback)
            try check(nativeFallback.snapshot.state == .awaitingReceiver,
                      "Successful but unusable extraction blocked extensionless HLS loading")
            try check(nativeFallback.player.rate == 0 && nativeFallback.player.isMuted,
                      "Native fallback started playback")
            let calls = try String(contentsOf: callsFile, encoding: .utf8).split(separator: "\n")
            try check(calls.count == 1, "Native fallback recursively invoked extraction")
            try nativeFallback.load(base + "/missing-media?signature=do-not-log")
            try await waitForResolved(nativeFallback)
            try check(nativeFallback.snapshot.state == .failed,
                      "Native fallback accepted an input with no playable video")
            await nativeFallback.shutdownAndWait()
        }
        let page = "https://www.youtube.com/watch?v=BaW_jenozKc"
        let targetURL = URL(string: base + "/audio.mp4?signature=do-not-log")!
        let genericPage = "https://video.example/watch?id=do-not-log"
        for (input, failures) in [(page, 1), (page, 3), (genericPage, 1), (genericPage, 3)] {
            let fixture = ResolverFixture(url: targetURL, failures: failures)
            let resolved = PlaybackController(resolveSource: { try await fixture.resolve($0) })
            try resolved.load(input)
            try check(resolved.snapshot.state == .loading && resolved.snapshot.loadingPhase == "resolving",
                      "Resolution did not publish its pending phase")
            try await waitForResolved(resolved)
            let calls = await fixture.calls
            try check(calls == 2, "Unavailable website source did not have exactly one retry")
            try check(resolved.snapshot.state == (failures == 1 ? .awaitingReceiver : .failed), "Retry result incorrect")
            try check(resolved.player.rate == 0 && resolved.player.isMuted, "Resolution/retry started playback")
            let json = String(decoding: try JSONEncoder().encode(resolved.snapshot), as: UTF8.self)
            try check(!json.contains("do-not-log"), "Resolved URL leaked into status")
            resolved.shutdown()
        }
        for input in [page, genericPage] {
            let delayed = ResolverFixture(url: targetURL, failures: 0, delay: true)
            let replaced = PlaybackController(resolveSource: { try await delayed.resolve($0) })
            try replaced.load(input)
            try await Task.sleep(for: .milliseconds(50))
            replaced.stop()
            try await Task.sleep(for: .milliseconds(100))
            try check(replaced.snapshot.state == .idle && replaced.player.currentItem == nil, "Stopped extraction published a stale item")
            try replaced.load(input)
            try await Task.sleep(for: .milliseconds(50))
            try replaced.load(base + "/video.mp4")
            try await waitForResolved(replaced)
            try check(replaced.snapshot.state == .awaitingReceiver && replaced.snapshot.hasAudio == false,
                      "Stale extraction replaced the newer direct source")
            replaced.shutdown()
        }

        let releaseAfterEnd = PlaybackController(resolveSource: { _ in
            ResolvedSource(url: targetURL, title: "Resolved fixture title")
        }, prepareSource: nil, afterPlaybackBehavior: { .unloadVideo })
        try releaseAfterEnd.load(page)
        try await waitForResolved(releaseAfterEnd)
        try check(releaseAfterEnd.snapshot.title == "Resolved fixture title", "Resolved media title was not published")
        let finishedItem = releaseAfterEnd.player.currentItem!
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: finishedItem)
        try await Task.sleep(for: .milliseconds(100))
        try check(releaseAfterEnd.snapshot.state == .idle && releaseAfterEnd.player.currentItem == nil,
                  "Release-after-playback retained the finished item")
        try check(releaseAfterEnd.notice?.contains("unloaded") == true,
                  "Release-after-playback did not explain the completed action")
        releaseAfterEnd.shutdown()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(results), as: UTF8.self))
        FileHandle.standardError.write(Data("PASS diagnostics, privacy, protocol compatibility, notification lifecycle, native media loads, resolver retry, titles and end behavior\n".utf8))
    }
}

private actor ResolverFixture {
    let url: URL
    let failures: Int
    let delay: Bool
    var calls = 0
    init(url: URL, failures: Int, delay: Bool = false) { self.url = url; self.failures = failures; self.delay = delay }
    func resolve(_ input: URL) async throws -> ResolvedSource {
        guard SourceResolver.needsResolution(input) else { return ResolvedSource(url: input) }
        calls += 1
        // Deliberately return even when cancelled to verify the controller's generation guard.
        if delay { try? await Task.sleep(for: .seconds(2)) }
        if calls <= failures {
            throw NSError(domain: AVFoundationErrorDomain, code: AVError.contentIsUnavailable.rawValue)
        }
        return ResolvedSource(url: url)
    }
}
