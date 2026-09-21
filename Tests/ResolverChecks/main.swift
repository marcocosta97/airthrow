import Foundation
import Darwin
import CommonCrypto

@main
@MainActor
struct ResolverChecks {
    nonisolated static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ResolverChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func expect(_ expected: ResolutionFailure, _ action: () async throws -> Void) async throws {
        do { try await action(); throw NSError(domain: "Expected failure", code: 1) }
        catch let error as ResolutionFailure { try check(error.reason == expected.reason, "Unexpected failure category") }
    }
    static func metadata(_ formats: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["_type": "video", "formats": formats].merging(extra) { _, rhs in rhs })
    }
    nonisolated static func littleEndian(_ value: UInt32) -> Data {
        var number = value.littleEndian
        return withUnsafeBytes(of: &number) { Data($0) }
    }
    nonisolated static func bigEndian(_ value: UInt32) -> Data {
        var number = value.bigEndian
        return withUnsafeBytes(of: &number) { Data($0) }
    }
    /// Build a minimal, valid `Cookies.binarycookies` file holding one YouTube
    /// cookie and one unrelated cookie so the scoping filter can be verified.
    nonisolated static func safariFixture() -> Data {
        func record(domain: String, name: String, value: String, secure: Bool) -> Data {
            let domainBytes = Data(domain.utf8) + Data([0])
            let nameBytes = Data(name.utf8) + Data([0])
            let pathBytes = Data("/".utf8) + Data([0])
            let valueBytes = Data(value.utf8) + Data([0])
            let header = 56
            let domainOffset = header
            let nameOffset = domainOffset + domainBytes.count
            let pathOffset = nameOffset + nameBytes.count
            let valueOffset = pathOffset + pathBytes.count
            let size = valueOffset + valueBytes.count
            var bytes = Data()
            bytes.append(contentsOf: littleEndian(UInt32(size)))
            bytes.append(contentsOf: littleEndian(0))
            bytes.append(contentsOf: littleEndian(secure ? 1 : 0))
            bytes.append(contentsOf: littleEndian(0))
            bytes.append(contentsOf: littleEndian(UInt32(domainOffset)))
            bytes.append(contentsOf: littleEndian(UInt32(nameOffset)))
            bytes.append(contentsOf: littleEndian(UInt32(pathOffset)))
            bytes.append(contentsOf: littleEndian(UInt32(valueOffset)))
            bytes.append(Data(repeating: 0, count: 8))
            var macTime = (1_704_067_200.0 - 978_307_200.0).bitPattern.littleEndian
            bytes.append(withUnsafeBytes(of: &macTime) { Data($0) })
            bytes.append(Data(repeating: 0, count: 8))
            bytes.append(domainBytes); bytes.append(nameBytes); bytes.append(pathBytes); bytes.append(valueBytes)
            return bytes
        }
        let records = [record(domain: ".youtube.com", name: "SID", value: "secret", secure: true),
                       record(domain: ".example.com", name: "OTHER", value: "x", secure: false)]
        var page = Data([0x00, 0x00, 0x01, 0x00])
        page.append(contentsOf: littleEndian(UInt32(records.count)))
        let offsetsStart = 8 + records.count * 4
        var offset = offsetsStart
        var offsets: [Int] = []
        for record in records { offsets.append(offset); offset += record.count }
        for value in offsets { page.append(contentsOf: littleEndian(UInt32(value))) }
        for record in records { page.append(record) }
        var file = Data("cook".utf8)
        file.append(contentsOf: bigEndian(1))
        file.append(contentsOf: bigEndian(UInt32(page.count)))
        file.append(page)
        return file
    }
    nonisolated static func aesEncrypt(_ data: Data, key: [UInt8]) -> Data {
        let iv = [UInt8](repeating: 0x20, count: 16)
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBufferPointer { keyBuffer in
            output.withUnsafeMutableBufferPointer { out in
                data.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), keyBuffer.baseAddress, key.count, iv,
                            input.baseAddress, data.count, out.baseAddress, out.count, &moved)
                }
            }
        }
        precondition(status == kCCSuccess, "fixture encryption failed")
        return Data(output.prefix(moved))
    }
    static func main() async throws {
        if CommandLine.arguments.count == 3 {
            do {
                let result: ResolvedSource
                if CommandLine.arguments[1] == "--metadata" {
                    result = try SourceResolver.select(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
                } else {
                    result = try await SourceResolver().resolve(MediaInput.url(CommandLine.arguments[2]))
                }
                print(result.needsPreparation ? "Selected separate tracks for preparation; URLs and headers withheld."
                    : "Resolved a native audio/video presentation; URLs and headers withheld.")
            } catch let error as ResolutionFailure {
                print("\(error.reason.rawValue): \(error.reason.message)")
                exit(1)
            }
            return
        }
        let page = URL(string: "https://www.youtube.com/watch?v=BaW_jenozKc&list=ignored")!
        let combined: [String: Any] = ["url": "https://media.example/video?signature=secret", "protocol": "https",
            "vcodec": "avc1.64001f", "acodec": "mp4a.40.2", "ext": "mp4", "height": 720]
        let raw = try metadata([combined])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("airplayer-resolver-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        func helper(_ name: String, _ body: String) throws -> String {
            let path = temp.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body).write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            return path.path
        }
        let absent = SourceResolver(environment: ["AIRPLAYER_YTDLP": "/missing/yt-dlp", "AIRPLAYER_DENO": "/missing/deno"])
        let localMP4 = temp.appendingPathComponent("local video.mp4")
        let localMKV = temp.appendingPathComponent("local.mkv")
        let localHLS = temp.appendingPathComponent("local.m3u8")
        for file in [localMP4, localMKV, localHLS] { try Data("fixture".utf8).write(to: file) }
        let directLocal = try await absent.resolve(localMP4)
        try check(directLocal.needsDelivery && !directLocal.needsPreparation
                  && directLocal.playbackPath == .direct && directLocal.title == "local video.mp4",
                  "Compatible local container did not select in-place delivery")
        let remuxLocal = try await absent.resolve(localMKV)
        try check(remuxLocal.needsDelivery && remuxLocal.needsPreparation && remuxLocal.playbackPath == .remux,
                  "Unsupported local container did not select remuxing")
        try await expect(.preparationRequired) { _ = try await absent.resolve(localHLS) }
        let direct = URL(string: "https://cdn.example/no-extension?x=1")!
        let unknownVideo = try await absent.resolve(direct)
        try check(!unknownVideo.videoKnownPresent, "A direct URL invented video evidence")
        let unknownHLS = DirectSourceAdapter.candidates(URL(string: "https://cdn.example/audio.m3u8")!).first!.source
        try check(!unknownHLS.videoKnownPresent, "An HLS extension invented video evidence")
        try check(try await absent.resolve(direct).url == direct, "Direct URL invoked a helper")
        try check(!SourceResolver.isWebsite(URL(string: "https://youtube.com.evil.example/watch?v=BaW_jenozKc")!), "Host suffix spoof accepted")
        for link in [page, URL(string: "https://youtu.be/BaW_jenozKc")!, URL(string: "https://youtube.com/shorts/BaW_jenozKc")!] {
            try check(try SourceResolver.videoPage(link).absoluteString == "https://www.youtube.com/watch?v=BaW_jenozKc", "Video link was not normalized")
        }
        let playlistPage = URL(string: "https://youtube.com/playlist?list=PL12345678&feature=share")!
        try check(SourceResolver.playlistPage(playlistPage)?.absoluteString == "https://www.youtube.com/playlist?list=PL12345678",
                  "Dedicated playlist was not normalized")
        try check(SourceResolver.playlistPage(page) == nil, "Watch URL with playlist context became a queue")
        try check(SourceResolver.playlistPage(URL(string: "https://youtube.com/playlist?list=RD12345678")!) == nil,
                  "YouTube Mix was accepted")
        try await expect(.unsupportedPage) { _ = try await absent.resolve(URL(string: "https://youtube.com/playlist?list=x")!) }
        try await expect(.unavailable) { _ = try await absent.resolve(page) }
        print("PASS local delivery selection, direct bypass, exact hosts, video-only normalization and missing helpers")

        try check(try SourceResolver.select(raw).url.query == "signature=secret", "Lost signed URL in memory")
        let titled = try SourceResolver.select(metadata([combined], extra: ["title": "  Example\nTitle  "]))
        try check(titled.title == "ExampleTitle", "Resolver title was not sanitized")
        try check(titled.videoKnownPresent, "Inspected combined video lost readiness evidence")
        let sixtyFPS = try SourceResolver.candidates(metadata([combined.merging(["fps": 60, "height": 720]) { _, b in b }])).first
        try check(sixtyFPS?.frameRate == 60 && sixtyFPS?.height == 720,
                  "Frame rate was not carried into the candidate")
        let directLow = combined.merging(["height": 360]) { _, b in b }
        let videoOnly720 = combined.merging(["acodec": "none", "height": 720]) { _, b in b }
        let audioOnly = ["url": "https://media.example/audio?signature=secret", "protocol": "https",
                         "vcodec": "none", "acodec": "mp4a.40.2", "ext": "m4a"]
        let preferenceCandidates = try SourceResolver.candidates(metadata([directLow, videoOnly720, audioOnly]))
        let defaultPick = try MediaSelector.select(preferenceCandidates, policy: .avoidVideo)
        try check(defaultPick.playbackPath == .direct, "Default selection did not prefer the direct source")
        let qualityPick = try MediaSelector.select(preferenceCandidates, policy: .avoidVideo, preferQuality: true)
        try check(qualityPick.playbackPath == .remux, "Prefer-quality selection did not choose the higher-resolution remux")
        let bestFallback = MediaSelector.bestRemuxFallback(from: preferenceCandidates, policy: .avoidVideo)
        try check(bestFallback?.playbackPath == .remux && bestFallback?.audio != nil,
                  "Best remux fallback did not choose the paired higher-resolution remux")
        let videoOnly = combined.merging(["acodec": "none", "height": 2160]) { _, b in b }
        let unknown = combined.filter { $0.key != "acodec" }
        let headers = combined.merging(["http_headers": ["Referer": "secret"]]) { _, b in b }
        let incompatible = combined.merging(["vcodec": "vp9", "acodec": "opus"]) { _, b in b }
        for format in [videoOnly, unknown, headers, incompatible] {
            try await expect(.preparationRequired) { _ = try SourceResolver.select(metadata([format])) }
        }
        let hls = combined.merging(["protocol": "m3u8_native", "height": 1080, "url": "https://cdn.example/index.m3u8"]) { _, b in b }
        try check(try SourceResolver.select(metadata([combined, videoOnly, hls])).url.path == "/index.m3u8", "Wrong combined format selected")
        let separateVideo = videoOnly.merging(["height": 720]) { _, rhs in rhs }
        let separateAudio = combined.merging(["vcodec": "none", "ext": "m4a", "url": "https://media.example/audio"]) { _, rhs in rhs }
        let split = try SourceResolver.select(metadata([separateVideo, separateAudio]))
        try check(split.needsPreparation && split.audio?.url.path == "/audio" && split.videoKnownPresent,
                  "Separate tracks or their inspected video evidence were not preserved for preparation")
        try check(try !SourceResolver.select(metadata([separateVideo, separateAudio, combined])).needsPreparation,
                  "Combined source did not retain priority over preparation")
        try await expect(.preparationRequired) { _ = try SourceResolver.select(metadata([videoOnly, separateAudio])) }
        try await expect(.preparationRequired) {
            _ = try SourceResolver.select(metadata([separateVideo, separateAudio], extra: ["http_headers": ["Cookie": "secret"]]))
        }
        try await expect(.protectedMedia) { _ = try SourceResolver.select(metadata([combined], extra: ["has_drm": true])) }
        for extra: [String: Any] in [["_type": "playlist", "entries": []], ["is_live": true], ["availability": "needs_auth"]] {
            try await expect(.unsupportedPage) { _ = try SourceResolver.select(metadata([combined], extra: extra)) }
        }
        try await expect(.failed) { _ = try SourceResolver.select(Data("broken JSON with secret URL".utf8)) }
        print("PASS combined/HLS selection; separate tracks, unknown codecs, custom headers, DRM and live/playlist restrictions")

        // Cost-aware selection, conversion policy, stable identity and audio metadata.
        let nativeCombined: [String: Any] = ["format_id": "native", "url": "https://media.example/direct?signature=secret",
            "protocol": "https", "vcodec": "avc1.64001f", "acodec": "mp4a.40.2", "ext": "mp4", "height": 720, "tbr": 1200]
        let highH264: [String: Any] = ["format_id": "v1080", "url": "https://media.example/1080", "protocol": "https",
            "vcodec": "avc1.640028", "acodec": "none", "ext": "mp4", "height": 1080, "tbr": 3000]
        let aacTrack: [String: Any] = ["format_id": "a128", "url": "https://media.example/audio-aac", "protocol": "https",
            "vcodec": "none", "acodec": "mp4a.40.2", "ext": "m4a", "abr": 128, "language": "English"]
        let opusTrack: [String: Any] = ["format_id": "o160", "url": "https://media.example/audio-opus", "protocol": "https",
            "vcodec": "none", "acodec": "opus", "ext": "webm", "abr": 160, "language": "Italian"]
        let tierData = try metadata([nativeCombined, highH264, aacTrack])
        let tierCandidates = try SourceResolver.candidates(tierData)
        let prepared = tierCandidates.first { $0.source.needsPreparation }
        try check(prepared?.source.playbackPath == .remux
                  && prepared?.source.audio?.url.absoluteString == "https://media.example/audio-aac",
                  "Higher-quality remux candidate was not preserved")
        let automatic = try SourceResolver.select(tierData)
        try check(automatic.url.absoluteString == "https://media.example/direct?signature=secret"
                  && !automatic.needsPreparation && automatic.playbackPath == .direct,
                  "Automatic selection did not prefer the lower tier")
        guard let preparedID = prepared?.id else { throw NSError(domain: "ResolverChecks", code: 1) }
        let explicit = try SourceResolver.select(tierData, sourceID: preparedID)
        try check(explicit.url.absoluteString == "https://media.example/1080" && explicit.needsPreparation
                  && explicit.audio?.url.absoluteString == "https://media.example/audio-aac"
                  && explicit.conversionPolicy == .avoidVideo,
                  "Explicit higher-quality remux choice did not override native")
        try await expect(.failed) { _ = try SourceResolver.select(tierData, sourceID: "stale-format-id") }
        let duplicateIDs = [MediaCandidate(source: automatic.withConversionPolicy(.avoidVideo), id: "duplicate"),
                            MediaCandidate(source: automatic.withConversionPolicy(.avoidVideo), id: "duplicate")]
        try await expect(.failed) { _ = try MediaSelector.select(duplicateIDs, sourceID: "duplicate") }

        let vp9Video: [String: Any] = ["format_id": "vp9", "url": "https://media.example/vp9", "protocol": "https",
            "vcodec": "vp9", "acodec": "none", "ext": "webm", "height": 720, "tbr": 1500]
        let vp9Data = try metadata([vp9Video, opusTrack])
        let blocked = try SourceResolver.candidates(vp9Data).first { $0.source.playbackPath == .videoConversion }
        try check(blocked?.unavailableReason(for: .avoidVideo) != nil
                  && blocked?.unavailableReason(for: .allowVideo) == nil,
                  "Video conversion was not gated by policy")
        try await expect(.preparationRequired) { _ = try SourceResolver.select(vp9Data) }
        try await expect(.preparationRequired) { _ = try SourceResolver.select(vp9Data, sourceID: blocked?.id) }
        let allowed = try SourceResolver.select(vp9Data, policy: .allowVideo)
        try check(allowed.playbackPath == .videoConversion && allowed.needsPreparation
                  && allowed.conversionPolicy == .allowVideo,
                  "Allowed video conversion was not selected")

        let h264OpusData = try metadata([highH264, opusTrack])
        let audioConverted = try SourceResolver.select(h264OpusData)
        try check(audioConverted.playbackPath == .audioConversion && audioConverted.needsPreparation,
                  "Audio-only conversion was not available under avoidVideo")
        try check(try SourceResolver.select(h264OpusData, policy: .allowVideo).playbackPath == .audioConversion,
                  "Audio conversion tier changed under allowVideo")

        let languageCandidates = try SourceResolver.candidates(metadata([highH264, aacTrack, opusTrack]))
        let descriptions = languageCandidates.compactMap(\.audioDescription)
        try check(descriptions.contains { $0.contains("English") } && descriptions.contains { $0.contains("Italian") }
                  && descriptions.contains { $0.contains("AAC") },
                  "Language or codec audio metadata was lost")
        try check(Set(languageCandidates.map(\.id)).count == languageCandidates.count,
                  "Language variants shared a candidate identity")
        try check(languageCandidates.allSatisfy { candidate in
            !candidate.id.contains("http") && !candidate.id.contains("example")
                && !candidate.id.contains("signature") && !candidate.id.contains("secret")
        }, "Candidate identifier exposed a URL or header")

        let hdrVideo: [String: Any] = ["format_id": "vp9hdr", "url": "https://media.example/hdr", "protocol": "https",
            "vcodec": "vp9", "acodec": "none", "ext": "webm", "height": 1080, "dynamic_range": "HDR10"]
        let hdrData = try metadata([hdrVideo, aacTrack])
        let hdrCandidate = try SourceResolver.candidates(hdrData).first { $0.source.playbackPath == .videoConversion }
        try check(hdrCandidate?.unavailableReason != nil
                  && hdrCandidate?.unavailableReason(for: .allowVideo) != nil,
                  "HDR candidate was not exposed as disabled")
        try await expect(.preparationRequired) { _ = try SourceResolver.select(hdrData, policy: .allowVideo) }
        try check(try SourceResolver.candidates(metadata([nativeCombined.merging(["http_headers": ["X-Token": "secret"]]) { _, rhs in rhs }])).isEmpty,
                  "Custom header format produced a candidate")

        let extreme = MediaCandidate(source: automatic, height: 1e300, bitrate: 1e300)
        try check(!extreme.id.isEmpty, "Extreme dimensions trapped or emptied the fallback identity")
        let planned = ResolvedSource(url: URL(string: "https://media.example/x")!, plannedPath: .audioConversion)
        try check(planned.needsPreparation && planned.playbackPath == .audioConversion && planned.needsPreparationPipeline,
                  "Planned non-direct path did not imply preparation")
        let unknownDirectSource = DirectSourceAdapter.candidates(direct).first!.source
        try check(unknownDirectSource.conversionPolicy == .avoidVideo && unknownDirectSource.plannedPath == nil
                  && unknownDirectSource.playbackPath == .direct,
                  "Unknown direct source lost its native default plan")
        try check(try await absent.resolve(direct, policy: .allowVideo).conversionPolicy == .allowVideo,
                  "Resolver did not forward the conversion policy")
        let fallbackPolicy = MediaSelector.remuxFallback(
            for: ResolvedSource(url: URL(string: "https://media.example/native")!).withConversionPolicy(.allowVideo),
            reason: .unreadableMedia)
        try check(fallbackPolicy?.playbackPath == .remux && fallbackPolicy?.conversionPolicy == .allowVideo,
                  "Remux fallback lost the conversion policy")

        // Review follow-up: order-independent identities, collision handling,
        // high-resolution conversion, bounded labels and candidate caps.
        let reorderedFormats: [[String: Any]] = [nativeCombined, highH264, aacTrack, opusTrack]
        let forwardIDs = Set(try SourceResolver.candidates(metadata(reorderedFormats)).map(\.id))
        let reverseIDs = Set(try SourceResolver.candidates(metadata(Array(reorderedFormats.reversed()))).map(\.id))
        try check(!forwardIDs.isEmpty && forwardIDs == reverseIDs,
                  "Candidate identities changed when formats were reordered")

        let copiedPresentation = nativeCombined.merging(["url": "https://media.example/copy-b"]) { _, rhs in rhs }
        let collisionData = try metadata([nativeCombined, copiedPresentation])
        let collisionCandidates = try SourceResolver.candidates(collisionData)
        try check(collisionCandidates.count == 2 && Set(collisionCandidates.map(\.id)).count == 1,
                  "An identity collision silently dropped or renamed a presentation")
        try await expect(.failed) {
            _ = try SourceResolver.select(collisionData, sourceID: collisionCandidates.first?.id)
        }

        let highResolution = highH264.merging(["height": 2160]) { _, rhs in rhs }
        let highResolutionData = try metadata([highResolution, aacTrack])
        try await expect(.preparationRequired) { _ = try SourceResolver.select(highResolutionData) }
        try check(try SourceResolver.select(highResolutionData, policy: .allowVideo).playbackPath == .videoConversion,
                  "High-resolution SDR H.264 was not convertible under allowVideo")
        let highFPS = highH264.merging(["fps": 120]) { _, rhs in rhs }
        try check(try SourceResolver.select(metadata([highFPS, aacTrack]), policy: .allowVideo).playbackPath == .videoConversion,
                  "High-frame-rate H.264 was not convertible under allowVideo")
        let beyondInput = highH264.merging(["height": 4320]) { _, rhs in rhs }
        let beyondData = try metadata([beyondInput, aacTrack])
        try check(try SourceResolver.candidates(beyondData).contains {
            $0.source.playbackPath == .videoConversion && $0.unavailableReason != nil
        }, "Above-bound input was not disabled")
        try await expect(.preparationRequired) { _ = try SourceResolver.select(beyondData, policy: .allowVideo) }

        let dirtyLanguage = "en\u{0007} <http://evil.example/x?token=secret>"
        let dirtyCandidates = try SourceResolver.candidates(
            metadata([highH264, aacTrack.merging(["language": dirtyLanguage]) { _, rhs in rhs }]))
        let dirtyDescription = dirtyCandidates.first { $0.source.needsPreparation }?.audioDescription
        try check(dirtyDescription?.contains("http") != true && dirtyDescription?.contains("://") != true
                  && dirtyDescription?.contains("/") != true
                  && dirtyDescription?.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } != true,
                  "Audio metadata leaked control characters or a URL-like value")
        let longLanguage = aacTrack.merging(["language": String(repeating: "a", count: 500)]) { _, rhs in rhs }
        let longDescription = try SourceResolver.candidates(metadata([highH264, longLanguage]))
            .compactMap(\.audioDescription).first
        try check((longDescription?.count ?? 0) <= 80 && longDescription?.isEmpty == false,
                  "Audio description was not bounded")

        let manyCombined = (0..<40).map { index in
            nativeCombined.merging(["format_id": "f\(index)", "height": 720 + Double(index)]) { _, rhs in rhs }
        }
        try check(try SourceResolver.candidates(metadata(manyCombined)).count <= 12,
                  "Combined candidates were not capped")
        print("PASS reordered-format identity, ambiguity rejection, high-resolution conversion, label bounds and option caps")

        // Cost-first caps: a flood of expensive high-resolution formats must not
        // hide a compatible H.264 remux, and the bounded set must not depend on
        // extractor order.
        let av1High: [String: Any] = ["format_id": "av1", "url": "https://media.example/av1", "protocol": "https",
            "vcodec": "av01.0.12M.08", "acodec": "opus", "ext": "webm", "width": 3840, "height": 2160, "tbr": 12000]
        let h264Remux: [String: Any] = ["format_id": "h264mkv", "url": "https://media.example/h264-remux", "protocol": "https",
            "vcodec": "avc1.640028", "acodec": "mp4a.40.2", "ext": "mkv", "width": 1920, "height": 1080, "tbr": 5000]
        let expensiveConversions = (0..<24).map { index in
            av1High.merging(["format_id": "av1\(index)", "url": "https://media.example/av1-\(index)"]) { _, rhs in rhs }
        }
        let capFormats = expensiveConversions + [h264Remux]
        let capData = try metadata(capFormats)
        let capReversed = try metadata(Array(capFormats.reversed()))
        try check(Set(try SourceResolver.candidates(capData).map(\.id))
                  == Set(try SourceResolver.candidates(capReversed).map(\.id)),
                  "Expensive-format cap depended on extractor order")
        let cappedRemux = try SourceResolver.select(capData)
        try check(cappedRemux.playbackPath == .remux && cappedRemux.url.path == "/h264-remux",
                  "High-resolution AV1/VP9 conversion formats displaced a compatible H.264 remux")

        let av1VideoOnly: [String: Any] = ["format_id": "av1v", "url": "https://media.example/av1v", "protocol": "https",
            "vcodec": "av01.0.12M.08", "acodec": "none", "ext": "webm", "width": 3840, "height": 2160, "tbr": 12000]
        let h264VideoOnly: [String: Any] = ["format_id": "h264v", "url": "https://media.example/h264v", "protocol": "https",
            "vcodec": "avc1.64001f", "acodec": "none", "ext": "mp4", "width": 1280, "height": 720, "tbr": 2500]
        let expensiveVideos = (0..<24).map { index in
            av1VideoOnly.merging(["format_id": "av1v\(index)", "url": "https://media.example/av1v-\(index)"]) { _, rhs in rhs }
        }
        let pairFormats = expensiveVideos + [h264VideoOnly, aacTrack]
        let pairData = try metadata(pairFormats)
        let pairCandidates = try SourceResolver.candidates(pairData)
        try check(pairCandidates.contains {
            $0.source.playbackPath == .remux && $0.source.url.path == "/h264v" && $0.source.audio != nil
        }, "High-resolution AV1/VP9 videos displaced a compatible H.264 remux pair")
        try check(Set(pairCandidates.map(\.id))
                  == Set(try SourceResolver.candidates(metadata(Array(pairFormats.reversed()))).map(\.id)),
                  "Paired-video cap depended on extractor order")
        let pairedSelection = try SourceResolver.select(pairData)
        try check(pairedSelection.playbackPath == .remux && pairedSelection.url.path == "/h264v",
                  "Automatic selection did not preserve the cheap H.264 remux pair")

        // Explicit identities survive expiring-URL rotation, while a genuine
        // duplicate identity is refused rather than silently overridden.
        let stableID = try SourceResolver.candidates(metadata([nativeCombined])).first!.id
        let rotatedNative = nativeCombined.merging(["url": "https://media.example/direct?signature=rotated"]) { _, rhs in rhs }
        let rotatedID = try SourceResolver.candidates(metadata([rotatedNative])).first!.id
        try check(stableID == rotatedID, "Candidate identity changed when only the URL rotated")
        let rotatedSelection = try SourceResolver.select(metadata([rotatedNative]), sourceID: rotatedID)
        try check(rotatedSelection.url.absoluteString == "https://media.example/direct?signature=rotated",
                  "Explicit identity did not survive URL rotation")
        let identical = try SourceResolver.candidates(metadata([nativeCombined, nativeCombined]))
        try check(identical.count == 1, "A byte-for-byte duplicate presentation was not deduplicated")
        let headerA = nativeCombined.merging(["http_headers": ["User-Agent": "agent-a"]]) { _, rhs in rhs }
        let headerB = nativeCombined.merging(["http_headers": ["User-Agent": "agent-b"]]) { _, rhs in rhs }
        let headerCandidates = try SourceResolver.candidates(metadata([headerA, headerB]))
        try check(headerCandidates.count == 2 && Set(headerCandidates.map(\.id)).count == 1,
                  "Different request headers silently collapsed into one presentation")
        try await expect(.failed) {
            _ = try SourceResolver.select(metadata([headerA, headerB]), sourceID: headerCandidates.first?.id)
        }
        let videoA = h264VideoOnly.merging(["url": "https://media.example/video-a"]) { _, rhs in rhs }
        let videoB = h264VideoOnly.merging(["url": "https://media.example/video-b"]) { _, rhs in rhs }
        let pairCollision = try SourceResolver.candidates(metadata([videoA, videoB, aacTrack]))
            .filter { $0.source.audio != nil }
        try check(pairCollision.count == 2 && Set(pairCollision.map(\.id)).count == 1,
                  "A paired identity collision was silently resolved")
        try await expect(.failed) {
            _ = try SourceResolver.select(metadata([videoA, videoB, aacTrack]), sourceID: pairCollision.first?.id)
        }
        let longLanguageA = aacTrack.merging(["language": String(repeating: "a", count: 40)]) { _, rhs in rhs }
        let longLanguageB = aacTrack.merging(["language": String(repeating: "a", count: 40) + "b"]) { _, rhs in rhs }
        let collapsedPairs = try SourceResolver.candidates(metadata([h264VideoOnly, longLanguageA, longLanguageB]))
            .filter { $0.source.audio != nil }
        try check(collapsedPairs.count == 1 && (collapsedPairs.first?.audioDescription?.count ?? 0) <= 80,
                  "Collapsed long language labels were not reduced to one bounded safe candidate")

        // Input and output bounds include width when an extractor reports it.
        let wideInput = highH264.merging(["width": 4096]) { _, rhs in rhs }
        let wideInputData = try metadata([wideInput, aacTrack])
        try check(try SourceResolver.candidates(wideInputData).contains {
            $0.source.playbackPath == .videoConversion && $0.unavailableReason != nil
        }, "Wider-than-4K input was not disabled")
        try await expect(.preparationRequired) { _ = try SourceResolver.select(wideInputData, policy: .allowVideo) }
        let wideOutput = highH264.merging(["width": 2560]) { _, rhs in rhs }
        try check(try SourceResolver.select(metadata([wideOutput, aacTrack]), policy: .allowVideo).playbackPath == .videoConversion,
                  "Wider-than-1080 SDR H.264 was not convertible under allowVideo")
        print("PASS cost-first caps preserve H.264 remux, bounded sets are order-independent, identities survive URL rotation, duplicates/headers are handled, and width bounds apply")

        let masterURL = URL(string: "https://media.example/master.m3u8?signature=secret")!
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Italian, default",URI="audio.m3u8?token=a,b",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.64002a,mp4a.40.2",RESOLUTION=1920x1080,AUDIO="audio"
        video.m3u8
        """
        let masterData = Data(master.utf8)
        let adaptiveVideo = separateVideo.merging(["protocol": "m3u8_native", "manifest_url": masterURL.absoluteString]) { _, rhs in rhs }
        let adaptiveData = try metadata([adaptiveVideo, separateVideo, separateAudio], extra: ["title": "HLS title"])
        try check(HLSMaster.hasAudioVideo(masterData, at: masterURL), "Alternate audio master was not recognized")
        let native = try await SourceResolver.selectWithHLS(adaptiveData) { url in
            try check(url == masterURL, "Fetched a leaf rendition instead of the master")
            return masterData
        }
        try check(native.url == masterURL && !native.needsPreparation && native.audio == nil && native.title == "HLS title",
                  "Validated master did not bypass complete-file preparation")
        try check(native.videoKnownPresent,
                  "Inspected HLS video evidence was lost before routed item readiness")
        let hlsOnly = try await SourceResolver.selectWithHLS(metadata([adaptiveVideo])) { _ in masterData }
        try check(hlsOnly.url == masterURL, "HLS required a progressive fallback to work")
        let invalidMasters = [
            master.replacingOccurrences(of: "GROUP-ID=\"audio\"", with: "GROUP-ID=\"other\""),
            master.replacingOccurrences(of: ",mp4a.40.2", with: ""),
            master.replacingOccurrences(of: "avc1.64002a", with: "vp09.00.40.08"),
            master.replacingOccurrences(of: "URI=\"audio.m3u8?token=a,b\"", with: "URI=\"file:///tmp/audio.m3u8\""),
            master.replacingOccurrences(of: "video.m3u8", with: "data:video/mp4,invalid"),
            master.replacingOccurrences(of: "CODECS=", with: "AUDIO=\"duplicate\",CODECS="),
            master + "\n#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"key\"",
            "#EXTM3U\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST",
            "<html>Access denied</html>",
            master.replacingOccurrences(of: "NAME=\"Italian, default\"", with: "NAME=\"unclosed")
        ]
        for invalid in invalidMasters {
            let data = Data(invalid.utf8)
            try check(!HLSMaster.hasAudioVideo(data, at: masterURL), "Invalid or silent master accepted")
            let result = try await SourceResolver.selectWithHLS(adaptiveData) { _ in data }
            try check(result.needsPreparation, "Invalid master removed the preparation fallback")
        }
        try check(!HLSMaster.hasAudioVideo(Data(repeating: 65, count: HLSMaster.maximumBytes + 1), at: masterURL),
                  "Oversized manifest was accepted")
        let mediaPlaylist = Data("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:8,\nvideo/segment0.ts\n#EXT-X-ENDLIST\n".utf8)
        let mediaReference = HLSVideoEvidence.reference(in: mediaPlaylist, at: masterURL)
        try check(mediaReference?.url.absoluteString == "https://media.example/video/segment0.ts"
                  && mediaReference?.isPlaylist == false, "Direct HLS media segment was not resolved")
        let failedMaster = try await SourceResolver.selectWithHLS(adaptiveData) { _ in throw URLError(.timedOut) }
        try check(failedMaster.needsPreparation, "Master network failure removed the fallback")
        do {
            _ = try await SourceResolver.selectWithHLS(adaptiveData) { _ in throw CancellationError() }
            try check(false, "Cancelled master fetch started preparation")
        } catch is CancellationError {}
        let discovered = try await YouTubeSourceAdapter.candidatesWithHLS(metadata([adaptiveVideo, combined, separateVideo, separateAudio])) { _ in masterData }
        try check(discovered.count == 3 && discovered.contains(where: { $0.source.needsPreparation }),
                  "Adapter discarded alternatives before shared selection")
        try check(try MediaSelector.select(discovered).url == masterURL, "Higher-quality native HLS was not considered alongside MP4")
        let lowMaster = Data(master.replacingOccurrences(of: "1920x1080", with: "640x360").utf8)
        let higherMP4 = try await SourceResolver.selectWithHLS(metadata([adaptiveVideo, combined])) { _ in lowMaster }
        try check(higherMP4.url.path == "/video", "Low-quality HLS displaced a higher-quality native MP4")
        let mixedCodecs = master + "\n#EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS=\"vp09.00.40.08,mp4a.40.2\",RESOLUTION=3840x2160,AUDIO=\"audio\"\nvp9.m3u8"
        try check(HLSMaster.quality(Data(mixedCodecs.utf8), at: masterURL)?.height == 1080,
                  "Ineligible variant inflated HLS candidate quality")
        let failedWithMP4 = try await SourceResolver.selectWithHLS(metadata([adaptiveVideo, combined])) { _ in throw URLError(.timedOut) }
        try check(failedWithMP4.url.path == "/video", "Failed inspection removed a native MP4 candidate")
        let customHeader = adaptiveVideo.merging(["http_headers": ["Cookie": "secret"]]) { _, rhs in rhs }
        let customFallback = try await SourceResolver.selectWithHLS(metadata([customHeader, separateVideo, separateAudio])) { _ in
            try check(false, "Custom headers were ignored for a master candidate")
            return masterData
        }
        try check(customFallback.needsPreparation, "Custom-header master selected")
        let manyMasters = (0..<8).map { index in
            adaptiveVideo.merging(["manifest_url": "https://media.example/master\(index).m3u8"]) { _, rhs in rhs }
        }
        let counter = ManifestCounter()
        _ = try await SourceResolver.selectWithHLS(metadata(manyMasters + [separateVideo, separateAudio])) { _ in
            await counter.increment()
            throw URLError(.timedOut)
        }
        try check(await counter.count == 2, "Too many master URLs fetched")
        let duplicateCounter = ManifestCounter()
        _ = try await SourceResolver.selectWithHLS(metadata([adaptiveVideo, adaptiveVideo, separateVideo, separateAudio])) { _ in
            await duplicateCounter.increment()
            return Data()
        }
        try check(await duplicateCounter.count == 1, "Master URLs were not deduplicated")
        let firstMasterID = try await YouTubeSourceAdapter.candidatesWithHLS(metadata([adaptiveVideo, combined])) { _ in masterData }
            .first { $0.source.delivery == .hls }?.id
        let reorderedMasterID = try await YouTubeSourceAdapter.candidatesWithHLS(metadata([combined, adaptiveVideo])) { _ in masterData }
            .first { $0.source.delivery == .hls }?.id
        try check(firstMasterID != nil && firstMasterID == reorderedMasterID,
                  "HLS master identity changed when formats were reordered")
        // Two masters with identical quality metadata but different URLs keep the
        // same opaque identity, are both retained, and refuse an ambiguous choice
        // instead of letting one silently override the other.
        let masterA = adaptiveVideo.merging(["manifest_url": "https://media.example/masterA.m3u8"]) { _, rhs in rhs }
        let masterB = adaptiveVideo.merging(["manifest_url": "https://media.example/masterB.m3u8"]) { _, rhs in rhs }
        let twinCandidates = try await YouTubeSourceAdapter.candidatesWithHLS(metadata([masterA, masterB])) { _ in masterData }
        let twinMasters = twinCandidates.filter { $0.source.delivery == .hls }
        try check(twinMasters.count == 2 && Set(twinMasters.map(\.id)).count == 1,
                  "Identical-quality masters silently collapsed or got distinct identities")
        try await expect(.failed) {
            _ = try MediaSelector.select(twinCandidates, sourceID: twinMasters.first?.id)
        }
        print("PASS alternate-audio HLS masters, selection priority, fallback, malformed input, size/attempt bounds, stable HLS ids, twin masters and cancellation")

        var playlistEntries: [[String: Any]] = [
            ["id": "BaW_jenozKc", "title": " First "],
            ["id": "jNQXAC9IVRw", "title": "Live", "is_live": true],
            ["id": "aqz-KE-bpKQ", "title": "Private", "availability": "private"]
        ]
        playlistEntries += (3...SourceResolver.maximumPlaylistEntries).map {
            ["id": String(format: "item%07d", $0), "title": "Item \($0)"]
        }
        let playlistData = try JSONSerialization.data(withJSONObject: [
            "_type": "playlist", "title": " Test Playlist ", "entries": playlistEntries
        ])
        let playlist = try SourceResolver.selectPlaylist(playlistData)
        try check(playlist.title == "Test Playlist" && playlist.entries.count == SourceResolver.maximumPlaylistEntries,
                  "Playlist title/order/limit was not preserved")
        try check(playlist.entries[0].url?.absoluteString == "https://www.youtube.com/watch?v=BaW_jenozKc",
                  "Playlist entry was not normalized")
        try check(playlist.entries[1].url == nil && playlist.entries[2].url == nil && playlist.truncated,
                  "Unsupported playlist entries or truncation were not recorded")
        let playlistHelper = try helper("playlist", "printf '%s\\n' \"$@\" > '\(temp.path)/playlist-args'\ncat <<'JSON'\n\(String(decoding: playlistData, as: UTF8.self))\nJSON\n")
        let playlistResolver = SourceResolver(environment: ["AIRPLAYER_YTDLP": playlistHelper, "AIRPLAYER_DENO": "/usr/bin/true"])
        _ = try await playlistResolver.resolvePlaylist(playlistPage)
        let playlistArgs = try String(contentsOf: temp.appendingPathComponent("playlist-args"), encoding: .utf8)
        try check(playlistArgs.contains("--flat-playlist") && playlistArgs.contains("--playlist-end"),
                  "Playlist helper was not bounded to flat metadata extraction")
        print("PASS dedicated playlist parsing, ordering, unavailable entries, Mix rejection and queue limit")

        try check(YouTubeCookies.fromEnvironment(["AIRPLAYER_YTDLP_COOKIES": "/tmp/x.txt"]) == .file(URL(fileURLWithPath: "/tmp/x.txt")),
                  "Cookie file override was not parsed")
        try check(YouTubeCookies.fromEnvironment(["AIRPLAYER_YTDLP_COOKIES_FROM_BROWSER": "Safari"]) == .browser("safari"),
                  "Browser override was not normalized")
        try check(YouTubeCookies.fromEnvironment(["AIRPLAYER_YTDLP_COOKIES_FROM_BROWSER": "not-a-browser"]) == .none,
                  "Unknown browser override was accepted")
        try check(YouTubeCookies.fromEnvironment(["AIRPLAYER_YTDLP_COOKIES": "/tmp/x.txt",
                                                  "AIRPLAYER_YTDLP_COOKIES_FROM_BROWSER": "chrome"]) == .file(URL(fileURLWithPath: "/tmp/x.txt")),
                  "File override did not take precedence")
        try check(YouTubeCookies.fromEnvironment([:]) == .none, "Missing overrides enabled cookies")
        for domain in [".youtube.com", "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", ".youtube-nocookie.com"] {
            try check(YouTubeCookieScope.includes(domain), "YouTube domain was rejected: \(domain)")
        }
        for domain in ["notyoutube.com", "google.com", "youtube.com.evil.example", "evil-youtube.com", ""] {
            try check(!YouTubeCookieScope.includes(domain), "Foreign domain was accepted: \(domain)")
        }
        let netscape = """
        # Netscape HTTP Cookie File
        #HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t0\tSID\tsecret
        .google.com\tTRUE\t/\tFALSE\t123\tGMAIL\tmail
        notyoutube.com\tTRUE\t/\tFALSE\t0\tEVIL\tx
        """
        let parsedNetscape = NetscapeCookies.parse(netscape)
        try check(parsedNetscape.count == 3, "Netscape file was not parsed")
        let scopedNetscape = NetscapeCookies.youtube(parsedNetscape)
        try check(scopedNetscape.count == 1 && scopedNetscape[0].name == "SID" && scopedNetscape[0].httpOnly,
                  "Netscape scope filter was not applied")
        let serialized = NetscapeCookies.serialize(scopedNetscape)
        try check(serialized.contains("#HttpOnly_.youtube.com") && serialized.contains("secret"),
                  "Netscape serialization lost HttpOnly or value")
        let parsedSafari = SafariCookies.parse(safariFixture())
        try check(parsedSafari?.count == 2, "Safari binary container was not parsed")
        let scopedSafari = NetscapeCookies.youtube(parsedSafari ?? [])
        try check(scopedSafari.count == 1 && scopedSafari[0].name == "SID" && scopedSafari[0].secure,
                  "Safari scope filter was not applied")
        guard let chromiumKey = ChromiumCookies.deriveKey(password: Array("test-password".utf8)) else {
            throw NSError(domain: "ResolverChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Key derivation failed"])
        }
        let v10 = Data("v10".utf8)
        try check(ChromiumCookies.decrypt(v10 + aesEncrypt(Data("hello".utf8), key: chromiumKey),
                                          key: chromiumKey, metaVersion: 0) == "hello",
                  "Chromium AES round trip failed")
        let hashed = Data(repeating: 0xAB, count: 32) + Data("value".utf8)
        try check(ChromiumCookies.decrypt(v10 + aesEncrypt(hashed, key: chromiumKey),
                                          key: chromiumKey, metaVersion: 24) == "value",
                  "Chromium meta v24 hash prefix was not stripped")
        let emptyHome = temp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        try check(YouTubeCookies.browser("whale").probe(home: emptyHome) == .notInstalled,
                  "A missing browser was not reported as not installed")
        try check(YouTubeCookies.browser("safari").probe(home: emptyHome) == .noSession,
                  "A missing Safari store was not reported as no session")
        try check(YouTubeCookies.installedBrowsers(home: emptyHome).contains("safari"),
                  "Safari was not offered as an installed browser")
        try check(!YouTubeCookies.installedBrowsers(home: emptyHome).contains("whale"),
                  "An uninstalled browser was offered")
        let probeFile = temp.appendingPathComponent("probe.txt")
        try ".youtube.com\tTRUE\t/\tTRUE\t0\tLOGIN_INFO\tx\n".write(to: probeFile, atomically: true, encoding: .utf8)
        try check(YouTubeCookies.file(probeFile).probe(home: emptyHome) == .loaded(1),
                  "Cookie file probe did not count YouTube cookies")
        let foreignFile = temp.appendingPathComponent("foreign.txt")
        try ".example.com\tTRUE\t/\tTRUE\t0\tX\ty\n".write(to: foreignFile, atomically: true, encoding: .utf8)
        try check(YouTubeCookies.file(foreignFile).probe(home: emptyHome) == .noSession,
                  "Cookie file probe accepted a foreign cookie")
        let anonymousFile = temp.appendingPathComponent("anonymous.txt")
        try ".youtube.com\tTRUE\t/\tTRUE\t0\tVISITOR_INFO1_LIVE\tx\n".write(to: anonymousFile, atomically: true, encoding: .utf8)
        try check(YouTubeCookies.file(anonymousFile).probe(home: emptyHome) == .noSession,
                  "Anonymous YouTube cookies were treated as a signed-in session")
        let psidFile = temp.appendingPathComponent("psid.txt")
        try ".youtube.com\tTRUE\t/\tTRUE\t0\t__Secure-3PSID\tx\n".write(to: psidFile, atomically: true, encoding: .utf8)
        try check(YouTubeCookies.file(psidFile).probe(home: emptyHome) == .noSession,
                  "PSID without LOGIN_INFO was treated as a signed-in session")
        try check(YouTubeCookies.file(temp.appendingPathComponent("missing.txt")).probe(home: emptyHome) == .unavailable,
                  "A missing cookie file was not reported")
        print("PASS cookie overrides, YouTube-only scoping, Netscape/Safari parsing, Chromium AES and status probing")

        let cookiesFile = temp.appendingPathComponent("cookies.txt")
        try """
        # Netscape HTTP Cookie File
        .youtube.com\tTRUE\t/\tTRUE\t0\tSID\tsecretvalue
        .google.com\tTRUE\t/\tTRUE\t0\tGMAIL\tgooglevalue
        """.write(to: cookiesFile, atomically: true, encoding: .utf8)
        let cookieHelper = try helper("cookied", """
        prev=""
        for a in "$@"; do
          if [ "$prev" = "--cookies" ]; then cp "$a" '\(temp.path)/materialized'; fi
          prev="$a"
        done
        printf '%s\\n' "$@" > '\(temp.path)/cookie-args'
        cat <<'JSON'
        \(String(decoding: raw, as: UTF8.self))
        JSON
        """)
        let cookieResolver = SourceResolver(environment: ["AIRPLAYER_YTDLP": cookieHelper, "AIRPLAYER_DENO": "/usr/bin/true"],
                                            cookies: .file(cookiesFile))
        _ = try await cookieResolver.resolve(page)
        let cookieArgs = try String(contentsOf: temp.appendingPathComponent("cookie-args"), encoding: .utf8)
        try check(cookieArgs.contains("--cookies"), "Cookie file was not passed to the helper")
        let materialized = try String(contentsOf: temp.appendingPathComponent("materialized"), encoding: .utf8)
        try check(materialized.contains(".youtube.com") && materialized.contains("\tSID\tsecretvalue"),
                  "YouTube cookie was not materialized")
        try check(!materialized.contains("google.com") && !materialized.contains("GMAIL"),
                  "A non-YouTube cookie reached the helper")
        let argumentLines = cookieArgs.split(separator: "\n").map(String.init)
        if let index = argumentLines.firstIndex(of: "--cookies"), index + 1 < argumentLines.count {
            try check(!FileManager.default.fileExists(atPath: argumentLines[index + 1]),
                      "The temporary cookie file outlived the helper")
        } else {
            try check(false, "Cookie path was not adjacent to its flag")
        }
        print("PASS cookie materialization, YouTube-only handoff and scratch cleanup")

        let good = try helper("good", "printf '%s\\n' \"$@\" > '\(temp.path)/args'\ncat <<'JSON'\n\(String(decoding: raw, as: UTF8.self))\nJSON\n")
        let resolver = SourceResolver(environment: ["AIRPLAYER_YTDLP": good, "AIRPLAYER_DENO": "/usr/bin/true"])
        _ = try await resolver.resolve(page)
        let args = try String(contentsOf: temp.appendingPathComponent("args"), encoding: .utf8)
        for flag in ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--simulate", "--dump-single-json", "--no-remote-components"] {
            try check(args.contains(flag), "Helper isolation flag missing")
        }
        try check(!args.contains("--cookies"), "Cookies were passed without a configured source")
        try check(!args.contains("list=ignored"), "Playlist context reached the helper")
        try check(YouTubeSourceAdapter.isSignInChallenge(Data("ERROR: [youtube] x: Sign in to confirm you’re not a bot.".utf8)),
                  "Sign-in challenge was not recognized")
        try check(!YouTubeSourceAdapter.isSignInChallenge(Data("ERROR: unable to download".utf8)),
                  "Unrelated helper output was treated as a sign-in challenge")
        let signInHelper = try helper("signin", "echo 'ERROR: [youtube] x: Sign in to confirm you’re not a bot.' >&2; exit 1\n")
        let signInResolver = SourceResolver(environment: ["AIRPLAYER_YTDLP": signInHelper, "AIRPLAYER_DENO": "/usr/bin/true"])
        try await expect(.signInRequired) { _ = try await signInResolver.resolve(page) }
        print("PASS sign-in challenge classification")
        let bad = try helper("bad", "echo 'secret signed URL' >&2; exit 1\n")
        try await expect(.failed) { _ = try await HelperProcess.run(executable: bad, arguments: []) }
        let noisy = try helper("noisy", "while :; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done\n")
        try await expect(.tooMuchOutput) { _ = try await HelperProcess.run(executable: noisy, arguments: [], outputLimit: 1000) }
        let sleeper = try helper("sleeper", "sleep 20 &\necho $! > '\(temp.path)/child'\nwait\n")
        try await expect(.timedOut) { _ = try await HelperProcess.run(executable: sleeper, arguments: [], timeout: .milliseconds(150)) }
        let task = Task { try await HelperProcess.run(executable: sleeper, arguments: []) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; try check(false, "Cancellation returned output") }
        catch is CancellationError {}
        let child = try String(contentsOf: temp.appendingPathComponent("child"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.sleep(for: .milliseconds(100))
        try check(kill(Int32(child)!, 0) == -1 && errno == ESRCH, "Helper descendant survived cancellation")
        print("PASS structured output, controlled flags, nonzero exit, output limit, timeout and process-group cancellation")
        print("All resolver checks passed (no physical receiver)")
    }
}

private actor ManifestCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

// Exercise the same adapter -> shared selector boundary with deterministic metadata.
private extension SourceResolver {
    static func candidates(_ data: Data) throws -> [MediaCandidate] {
        try YouTubeSourceAdapter.candidates(data)
    }
    static func select(_ data: Data, policy: ConversionPolicy = .avoidVideo,
                       sourceID: String? = nil) throws -> ResolvedSource {
        try MediaSelector.select(YouTubeSourceAdapter.candidates(data), policy: policy, sourceID: sourceID)
    }
    static func selectWithHLS(_ data: Data, fetch: @Sendable (URL) async throws -> Data) async throws -> ResolvedSource {
        try await MediaSelector.select(YouTubeSourceAdapter.candidatesWithHLS(data, fetch: fetch))
    }
    static func selectPlaylist(_ data: Data) throws -> ResolvedPlaylist {
        try YouTubeSourceAdapter.selectPlaylist(data)
    }
}
