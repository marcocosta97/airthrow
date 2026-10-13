import Foundation
import AVFoundation

struct CheckFailure: Error { let message: String }
@MainActor private final class DeferredRelaySink {
    var completion: (@MainActor @Sendable () -> Void)?
    var delivered = 0
    var largestWrite = 0
    var closed = false
    func send(_ data: Data, completion: @escaping @MainActor @Sendable () -> Void) {
        delivered += data.count
        largestWrite = max(largestWrite, data.count)
        self.completion = completion
    }
    func drain() {
        while let callback = completion { completion = nil; callback() }
    }
}
@main
struct HTTPAuthenticationChecks {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        func source(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }
        var count = 0
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw CheckFailure(message: name) }
            count += 1; print("PASS \(name)")
        }
        func fetch(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url); request.httpMethod = method
            request.timeoutInterval = 10
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let burstSink = DeferredRelaySink()
        let burst = HTTPRelayStream(url: source("/public/burst.ts"), method: "GET", headers: [:], credentials: nil,
            rewrite: { data, _ in data }, send: { data, completion in burstSink.send(data, completion: completion) },
            finish: { burstSink.closed = true })
        let payload = Data(repeating: 0x47, count: 4 * 1024 * 1024)
        try check(burst.received(HTTPURLResponse(url: source("/public/burst.ts"), statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/mp2t", "Content-Length": String(payload.count)])!),
                  "Synthetic relay accepts transport response")
        burst.received(payload)
        try check(!burst.bufferLimitReached && !burstSink.closed && burst.peakBufferBytes > 2 * 1024 * 1024,
                  "A multi-MiB callback under backpressure does not truncate the stream")
        burstSink.drain()
        try check(burstSink.delivered >= payload.count && burstSink.largestWrite <= HTTPRelayStream.sendChunkBytes,
                  "Large ingress drains fully through bounded network writes")
        burst.received(Data(repeating: 0x47, count: HTTPRelayStream.maximumPendingBytes + 1024 * 1024))
        try check(burst.bufferLimitReached && burstSink.closed && burst.peakBufferBytes <= HTTPRelayStream.maximumPendingBytes,
                  "A stalled client retains a strict bounded queue")
        burst.cancel()
        let cancellation = Task { try await HTTPAuthentication.challenge(for: source("/public/delayed.mp4")) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = ContinuousClock.now
        cancellation.cancel()
        do { _ = try await cancellation.value; throw CheckFailure(message: "Cancelled authentication probe returned successfully") }
        catch is CheckFailure { throw CheckFailure(message: "Cancelled authentication probe returned successfully") }
        catch { try check(ContinuousClock.now - cancelledAt < .seconds(1), "Cancellation ends authentication probe promptly") }
        do { _ = try await HTTPAuthentication.challenge(for: source("/denied/video.mp4")); throw CheckFailure(message: "Unadvertised 401 accepted") }
        catch HTTPLoginFailure.accessDenied { try check(true, "401 without authentication header reports denied access") }
        do { _ = try await HTTPAuthentication.challenge(for: source("/bearer/video.mp4")); throw CheckFailure(message: "Bearer 401 accepted") }
        catch HTTPLoginFailure.unsupported { try check(true, "Unsupported advertised authentication is distinct from expired-link denial") }
        let denied = PlaybackController(showReceiverWaitingScreen: false)
        try denied.load(source("/denied/video.mp4?token=expired").absoluteString)
        for _ in 0..<200 {
            if denied.snapshot.state == .failed { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try check(denied.snapshot.state == .failed && denied.httpLoginRequest == nil && denied.snapshot.error == HTTPLoginFailure.accessDenied.message,
                  "Unadvertised 401 preserves actionable expired-link message without login sheet")
        denied.shutdown()
        let basicURL = source("/basic/video.mp4?token=a%2Bb%26c")
        let required = try await HTTPAuthentication.challenge(for: basicURL)
        try check(required?.method == NSURLAuthenticationMethodHTTPBasic && required?.realm == "fixture", "Basic challenge")
        let basic = HTTPLoginCredentials(challenge: required!, username: "fixture-user", password: "fixture-pass")
        let wrong = HTTPLoginCredentials(challenge: required!, username: "fixture-user", password: "wrong")
        try check(try await HTTPAuthentication.challenge(for: basicURL, credentials: wrong) != nil, "Wrong password remains a challenge")
        try check(try await HTTPAuthentication.challenge(for: basicURL, credentials: basic) == nil, "Basic credentials verified")
        let relay = try await HTTPMediaRelay.start(source: basicURL, credentials: basic, host: "127.0.0.1")
        defer { relay.stop() }
        let direct = relay.url!
        let (bytes, response) = try await fetch(direct, range: "bytes=10-29")
        try check(response.statusCode == 206 && bytes.count == 20 && response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 10-29/") == true, "Byte range and signed query preserved")
        let technical = relay.diagnostics
        let encodedDiagnostics = String(decoding: try JSONEncoder().encode(technical), as: UTF8.self)
        try check(technical.relayReceivedBytes >= 20 && technical.relayPeakBufferBytes > 0
                  && !encodedDiagnostics.contains("fixture-user") && !encodedDiagnostics.contains("127.0.0.1")
                  && !encodedDiagnostics.contains("token"), "Relay counters expose only technical values")
        let (_, head) = try await fetch(direct, method: "HEAD")
        try check(head.statusCode == 200 && Int(head.value(forHTTPHeaderField: "Content-Length") ?? "0")! > 100, "HEAD length")
        let (_, missing) = try await fetch(direct.deletingLastPathComponent().appendingPathComponent("unregistered"))
        try check(missing.statusCode == 404, "Unregistered relay routes refused")
        let asset = AVURLAsset(url: direct)
        let playable = try await asset.load(.isPlayable)
        let video = try await asset.loadTracks(withMediaType: .video)
        try check(playable && !video.isEmpty, "Native MP4 reads through relay")
        let digestURL = source("/digest/video.mp4")
        let digestChallenge = try await HTTPAuthentication.challenge(for: digestURL)
        try check(digestChallenge?.method == NSURLAuthenticationMethodHTTPDigest, "Digest challenge")
        let digest = HTTPLoginCredentials(challenge: digestChallenge!, username: "fixture-user", password: "fixture-pass")
        let wrongDigest = HTTPLoginCredentials(challenge: digestChallenge!, username: "fixture-user", password: "wrong")
        try check(try await HTTPAuthentication.challenge(for: digestURL, credentials: wrongDigest) != nil, "Wrong Digest password stays bounded")
        try check(try await HTTPAuthentication.challenge(for: digestURL, credentials: digest) == nil, "Digest credentials verified")
        let digestRelay = try await HTTPMediaRelay.start(source: digestURL, credentials: digest, host: "127.0.0.1")
        let (digestBytes, digestResponse) = try await fetch(digestRelay.url!, range: "bytes=0-31")
        try check(digestBytes.count == 32 && digestResponse.statusCode == 206, "Digest media delivery")
        digestRelay.stop()
        let hlsRelay = try await HTTPMediaRelay.start(source: source("/basic/master.m3u8"), credentials: basic, host: "127.0.0.1")
        defer { hlsRelay.stop() }
        let (masterBytes, _) = try await fetch(hlsRelay.url!)
        let master = String(decoding: masterBytes, as: UTF8.self)
        let childLine = master.split(separator: "\n").first { !$0.hasPrefix("#") }!
        let child = URL(string: String(childLine), relativeTo: hlsRelay.url!)!.absoluteURL
        let (manifestBytes, _) = try await fetch(child)
        let manifest = String(decoding: manifestBytes, as: UTF8.self)
        let segmentLine = manifest.split(separator: "\n").first { !$0.hasPrefix("#") }!
        let segment = URL(string: String(segmentLine), relativeTo: child)!.absoluteURL
        let (segmentBytes, segmentResponse) = try await fetch(segment)
        try check(!master.contains("/basic/") && !manifest.contains("/basic/") && segmentResponse.statusCode == 200 && !segmentBytes.isEmpty, "HLS variants and segments rewritten")
        let (_, manifestHead) = try await fetch(child, method: "HEAD")
        try check(manifestHead.value(forHTTPHeaderField: "Content-Length") == String(manifestBytes.count), "Rewritten HLS HEAD length")
        let hlsCounters = hlsRelay.diagnostics
        try check(hlsCounters.relayManifestResponses >= 3 && hlsCounters.relayManifestEndLists >= 2
                  && hlsCounters.relayManifestVODs >= 2 && hlsCounters.relayManifestSequence == 0,
                  "Manifest diagnostics distinguish finite input using only counts and sequence")
        let hlsAsset = AVURLAsset(url: hlsRelay.url!)
        let hlsPlayable = try await hlsAsset.load(.isPlayable)
        let hlsVideo = try await hlsAsset.loadTracks(withMediaType: .video)
        let hlsEvidence = await HLSVideoEvidence.hasVideo(at: hlsRelay.url!)
        try check(hlsPlayable && (!hlsVideo.isEmpty || hlsEvidence), "Native HLS reads protected segments")
        let qualityData = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=320x180,CODECS=\"avc1.64000c,mp4a.40.2\"\nstream.m3u8\n".utf8)
        let qualityRelay = try await HTTPMediaRelay.start(source: source("/basic/qualities.m3u8"), credentials: basic, host: "127.0.0.1",
                                                        variant: HLSRenditions.variants(qualityData)[0])
        let (fixedData, _) = try await fetch(qualityRelay.url!)
        let fixedMaster = String(decoding: fixedData, as: UTF8.self)
        try check(fixedMaster.components(separatedBy: "#EXT-X-STREAM-INF:").count == 2
                  && fixedMaster.contains("320x180") && !fixedMaster.contains("640x360")
                  && fixedMaster.contains("#EXT-X-MEDIA:") && !fixedMaster.contains("/basic/"), "Manual quality retains one rendition and rewrites its audio group")
        let fixedAsset = AVURLAsset(url: qualityRelay.url!)
        let fixedVariants = try await fixedAsset.load(.variants)
        try check(fixedVariants.count == 1 && fixedVariants[0].videoAttributes?.presentationSize.height == 180,
                  "AVFoundation sees only the requested quality through the authenticated relay")
        qualityRelay.stop()
        let attributes = try await HTTPMediaRelay.start(source: source("/basic/attributes.m3u8"), credentials: basic, host: "127.0.0.1")
        let (attributeBytes, _) = try await fetch(attributes.url!)
        let attributeText = String(decoding: attributeBytes, as: UTF8.self)
        try check(!attributeText.contains("/basic/") && attributeText.components(separatedBy: "URI=\"").count == 4, "Key, map and alternate-audio URI attributes rewritten")
        let pattern = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        var attributeResources = true
        for match in pattern.matches(in: attributeText, range: NSRange(attributeText.startIndex..., in: attributeText)) {
            let reference = String(attributeText[Range(match.range(at: 1), in: attributeText)!])
            let (body, response) = try await fetch(URL(string: reference, relativeTo: attributes.url!)!.absoluteURL)
            attributeResources = attributeResources && response.statusCode == 200 && !body.isEmpty
        }
        try check(attributeResources, "Key, init fragment and alternate audio fetch with authentication")
        attributes.stop()
        let slow = try await HTTPMediaRelay.start(source: source("/basic/slow.mp4"), credentials: basic, host: "127.0.0.1")
        let streamingSession = URLSession(configuration: .ephemeral)
        let clock = ContinuousClock.now
        let (stream, streamResponse) = try await streamingSession.bytes(from: slow.url!)
        var receivedBytes = 0
        for try await _ in stream {
            receivedBytes += 1
            if receivedBytes == 1024 { break }
        }
        try check((streamResponse as? HTTPURLResponse)?.statusCode == 200 && ContinuousClock.now - clock < .seconds(3), "Relay delivers first bytes without downloading whole video")
        streamingSession.invalidateAndCancel(); slow.stop()
        let redirect = try await HTTPMediaRelay.start(source: source("/basic/redirect.mp4"), credentials: basic, host: "127.0.0.1")
        let (_, redirected) = try await fetch(redirect.url!)
        try check(redirected.statusCode == 200, "Cross-origin public redirect without credentials")
        redirect.stop()
        let realm = try await HTTPMediaRelay.start(source: source("/other/video.mp4"), credentials: basic, host: "127.0.0.1")
        let (_, realmResponse) = try await fetch(realm.url!)
        try check(realmResponse.statusCode == 502, "Credentials refused for another realm")
        realm.stop()
        let unsafe = try await HTTPMediaRelay.start(source: source("/basic/unsafe.m3u8"), credentials: basic, host: "127.0.0.1")
        let (_, unsafeResponse) = try await fetch(unsafe.url!)
        try check(unsafeResponse.statusCode == 502, "Non-HTTP HLS references refused")
        unsafe.stop()
        let oversized = try await HTTPMediaRelay.start(source: source("/basic/oversized.m3u8"), credentials: basic, host: "127.0.0.1")
        let (_, oversizedResponse) = try await fetch(oversized.url!)
        try check(oversizedResponse.statusCode == 502, "Playlist buffer is bounded")
        oversized.stop()
        // Existing FFmpeg preparation receives only the relay URL, no credentials.
        let mkvRelay = try await HTTPMediaRelay.start(source: source("/basic/video.mkv"), credentials: basic, host: "127.0.0.1")
        let candidates = try await SourceResolver().candidates(for: mkvRelay.url!)
        let selected = try MediaSelector.select(candidates)
        let prepared = try await MediaPreparer(environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "", "AIRTHROW_MEDIA_HOST": "127.0.0.1"], preferences: PreparationPreferences(remuxCache: false)).prepare(selected)
        let preparedAsset = AVURLAsset(url: prepared.url)
        try check(try await preparedAsset.load(.isPlayable), "Authenticated MKV remux through existing pipeline")
        prepared.stop(); await prepared.waitForProducer(); mkvRelay.stop()
        let enhancedSource = ResolvedSource(url: direct).withConversionPolicy(.allowVideo).withEnhancement(.cleanup1080)
        let enhanced = try await MediaPreparer(environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "", "AIRTHROW_MEDIA_HOST": "127.0.0.1"]).prepare(enhancedSource)
        try check(enhanced.playbackPath == .videoConversion, "Authenticated video enhancement through existing pipeline")
        enhanced.stop(); await enhanced.waitForProducer()
        let audioRelay = try await HTTPMediaRelay.start(source: source("/basic/audio.mkv"), credentials: basic, host: "127.0.0.1")
        let audioCandidates = try await SourceResolver().candidates(for: audioRelay.url!)
        let audioPrepared = try await MediaPreparer(environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "", "AIRTHROW_MEDIA_HOST": "127.0.0.1"]).prepare(try MediaSelector.select(audioCandidates))
        try check(audioPrepared.playbackPath == .audioConversion, "Authenticated audio conversion through existing pipeline")
        audioPrepared.stop(); await audioPrepared.waitForProducer(); audioRelay.stop()

        let controller = PlaybackController(showReceiverWaitingScreen: false)
        try controller.load(basicURL.absoluteString)
        try await wait { controller.httpLoginRequest != nil }
        let stale = controller.httpLoginRequest!.id
        try check(controller.snapshot.loadingPhase == "authentication", "Controller exposes login without credentials in status")
        controller.submitHTTPLogin(id: stale, username: "fixture-user", password: "wrong")
        try await wait { controller.httpLoginRequest?.retry == true }
        let request = controller.httpLoginRequest!
        controller.submitHTTPLogin(id: request.id, username: "fixture-user", password: "fixture-pass")
        try await wait { controller.snapshot.state != .loading }
        try check(controller.snapshot.state != .failed && controller.httpLoginRequest == nil, "Controller login and playback readiness")
        let persistent = controller.player
        try controller.selectSource("automatic")
        try await wait { controller.snapshot.state != .loading }
        try check(controller.player === persistent && controller.httpLoginRequest == nil && controller.snapshot.state != .failed, "Source change reuses authenticated session and player")
        let hlsController = PlaybackController(showReceiverWaitingScreen: false, resolveCandidates: { url in
            try await HLSRenditions.expand(DirectSourceAdapter.candidates(url))
        }, checkHTTPAuthentication: { try await HTTPAuthentication.challenge(for: $0, credentials: $1) })
        try hlsController.load(source("/basic/controller-qualities.m3u8").absoluteString)
        try await wait { hlsController.httpLoginRequest != nil }
        hlsController.submitHTTPLogin(id: hlsController.httpLoginRequest!.id, username: "fixture-user", password: "fixture-pass")
        try await wait { hlsController.snapshot.state != .loading }
        let manualChoice = hlsController.snapshot.sources?.first { $0.isAdaptive == false && $0.quality == "180p" }?.id
        try check(manualChoice != nil && hlsController.snapshot.state != .failed, "Authenticated direct HLS exposes manual qualities")
        let hlsPlayer = hlsController.player
        try hlsController.selectSource(manualChoice!)
        try await wait { hlsController.snapshot.state != .loading }
        try check(hlsController.player === hlsPlayer && hlsController.httpLoginRequest == nil
                  && hlsController.snapshot.state != .failed && hlsController.snapshot.quality == "180p",
                  "Manual HLS selection reuses player/authentication and reports the chosen quality")
        try hlsController.selectSource("automatic")
        try await wait { hlsController.snapshot.state != .loading }
        try check(hlsController.snapshot.selectedSourceID == nil && hlsController.snapshot.state != .failed,
                  "Automatic restores adaptive HLS after a manual selection")
        hlsController.shutdown()
        controller.stop()
        try controller.load(basicURL.absoluteString)
        try await wait { controller.httpLoginRequest != nil }
        let cancelled = controller.httpLoginRequest!.id
        controller.cancelHTTPLogin(id: cancelled)
        controller.submitHTTPLogin(id: cancelled, username: "fixture-user", password: "fixture-pass")
        try await Task.sleep(for: .milliseconds(100))
        try check(controller.snapshot.state == .idle && controller.httpLoginRequest == nil && controller.player.currentItem == nil, "Cancel and late submission cannot restart playback")
        try controller.load(basicURL.absoluteString)
        try await wait { controller.httpLoginRequest != nil }
        let superseded = controller.httpLoginRequest!.id
        try controller.load(source("/public/video.mp4").absoluteString)
        controller.submitHTTPLogin(id: superseded, username: "fixture-user", password: "fixture-pass")
        try await wait { controller.snapshot.state != .loading }
        try check(controller.httpLoginRequest == nil && controller.snapshot.state != .failed, "New source supersedes pending login")
        let encoded = String(decoding: try JSONEncoder().encode(controller.snapshot), as: UTF8.self)
        try check(!encoded.contains("fixture-pass") && !encoded.contains("fixture-user") && !encoded.contains("token="), "Snapshot excludes credentials and signed URL")
        controller.stop()
        relay.stop()
        do { _ = try await fetch(direct); throw CheckFailure(message: "Stopped relay still listening") }
        catch is CheckFailure { throw CheckFailure(message: "Stopped relay still listening") }
        catch { try check(true, "Stop closes delivery listener") }
        print("HTTP authentication checks: \(count) passed; physical receiver untested.")
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(40)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CheckFailure(message: "Controller wait timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
