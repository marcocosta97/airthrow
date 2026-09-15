import Foundation
import Darwin

@main
@MainActor
struct ResolverChecks {
    static func check(_ condition: Bool, _ message: String) throws {
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
                print("Resolved a combined source (\(result.url.scheme ?? "unknown") transport); URLs and headers withheld.")
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
        try check(try await absent.resolve(direct).url == direct, "Direct URL invoked a helper")
        try check(!SourceResolver.isWebsite(URL(string: "https://youtube.com.evil.example/watch?v=BaW_jenozKc")!), "Host suffix spoof accepted")
        for link in [page, URL(string: "https://youtu.be/BaW_jenozKc")!, URL(string: "https://youtube.com/shorts/BaW_jenozKc")!] {
            try check(try SourceResolver.videoPage(link).absoluteString == "https://www.youtube.com/watch?v=BaW_jenozKc", "Video link was not normalized")
        }
        try await expect(.unsupportedPage) { _ = try await absent.resolve(URL(string: "https://youtube.com/playlist?list=x")!) }
        try await expect(.unavailable) { _ = try await absent.resolve(page) }
        print("PASS direct bypass, exact hosts, video-only normalization and missing helpers")

        try check(try SourceResolver.select(raw).url.query == "signature=secret", "Lost signed URL in memory")
        let videoOnly = combined.merging(["acodec": "none", "height": 2160]) { _, b in b }
        let unknown = combined.filter { $0.key != "acodec" }
        let headers = combined.merging(["http_headers": ["Referer": "secret"]]) { _, b in b }
        let incompatible = combined.merging(["vcodec": "vp9", "acodec": "opus"]) { _, b in b }
        for format in [videoOnly, unknown, headers, incompatible] {
            try await expect(.preparationRequired) { _ = try SourceResolver.select(metadata([format])) }
        }
        let hls = combined.merging(["protocol": "m3u8_native", "height": 1080, "url": "https://cdn.example/index.m3u8"]) { _, b in b }
        try check(try SourceResolver.select(metadata([combined, videoOnly, hls])).url.path == "/index.m3u8", "Wrong combined format selected")
        try await expect(.protectedMedia) { _ = try SourceResolver.select(metadata([combined], extra: ["has_drm": true])) }
        for extra: [String: Any] in [["_type": "playlist", "entries": []], ["is_live": true], ["availability": "needs_auth"]] {
            try await expect(.unsupportedPage) { _ = try SourceResolver.select(metadata([combined], extra: extra)) }
        }
        try await expect(.failed) { _ = try SourceResolver.select(Data("broken JSON with secret URL".utf8)) }
        print("PASS combined/HLS selection; separate tracks, unknown codecs, custom headers, DRM and live/playlist restrictions")

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
