import Foundation
import Darwin

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
        let direct = URL(string: "https://cdn.example/no-extension?x=1")!
        let unknownVideo = try await absent.resolve(direct)
        try check(!unknownVideo.videoKnownPresent, "A direct URL invented video evidence")
        let unknownHLS = try await absent.resolve(URL(string: "https://cdn.example/audio.m3u8")!)
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
        print("PASS direct bypass, exact hosts, video-only normalization and missing helpers")

        try check(try SourceResolver.select(raw).url.query == "signature=secret", "Lost signed URL in memory")
        let titled = try SourceResolver.select(metadata([combined], extra: ["title": "  Example\nTitle  "]))
        try check(titled.title == "ExampleTitle", "Resolver title was not sanitized")
        try check(titled.videoKnownPresent, "Inspected combined video lost readiness evidence")
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
        print("PASS alternate-audio HLS masters, selection priority, fallback, malformed input, size/attempt bounds and cancellation")

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

        let good = try helper("good", "printf '%s\\n' \"$@\" > '\(temp.path)/args'\ncat <<'JSON'\n\(String(decoding: raw, as: UTF8.self))\nJSON\n")
        let resolver = SourceResolver(environment: ["AIRPLAYER_YTDLP": good, "AIRPLAYER_DENO": "/usr/bin/true"])
        _ = try await resolver.resolve(page)
        let args = try String(contentsOf: temp.appendingPathComponent("args"), encoding: .utf8)
        for flag in ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--simulate", "--dump-single-json", "--no-remote-components"] {
            try check(args.contains(flag), "Helper isolation flag missing")
        }
        try check(!args.contains("list=ignored"), "Playlist context reached the helper")
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
    static func select(_ data: Data) throws -> ResolvedSource {
        try MediaSelector.select(YouTubeSourceAdapter.candidates(data))
    }
    static func selectWithHLS(_ data: Data, fetch: @Sendable (URL) async throws -> Data) async throws -> ResolvedSource {
        try await MediaSelector.select(YouTubeSourceAdapter.candidatesWithHLS(data, fetch: fetch))
    }
    static func selectPlaylist(_ data: Data) throws -> ResolvedPlaylist {
        try YouTubeSourceAdapter.selectPlaylist(data)
    }
}
