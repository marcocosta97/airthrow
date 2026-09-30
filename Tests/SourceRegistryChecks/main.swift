import Foundation
import Darwin
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private struct CheckFailure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message: message) }
}
private func rejects(_ expected: SourceRegistryError = .invalidAdapter, _ action: () throws -> Void) throws {
    do { try action() }
    catch let failure as SourceRegistryError {
        try check(failure == expected, "Unexpected registry error: \(failure)")
        return
    }
    throw CheckFailure(message: "Invalid provider was accepted")
}

private struct FixtureAdapter: SourceAdapter {
    let id: String
    let hosts: [String]
    var isFallback = false
    var handlesDirectMediaURLs = false
    var choices: [MediaCandidate] = []
    func candidates(for url: URL) async throws -> [MediaCandidate] { choices }
}

@main
private struct SourceRegistryChecks {
    static func routingChecks() throws {
        let registry = try SourceRegistry.standard(environment: ["AIRTHROW_YTDLP": "/missing/helper"])
        try check(registry.providerIDs.contains("youtube") && registry.providerIDs.contains("yt-dlp"),
                  "Shipped registry lost an existing provider")
        let cases: [(String, String?)] = [
            ("https://www.youtube.com/watch?v=aqz-KE-bpKQ", "youtube"),
            ("https://youtu.be/aqz-KE-bpKQ", "youtube"),
            ("https://www.youtube.com/not-a-video.mp4", "youtube"),
            ("https://youtube.com.evil.example/watch?v=aqz-KE-bpKQ", "yt-dlp"),
            ("https://cdn.example/clip.MP4?signature=secret", nil),
            ("https://cdn.example/clip.m3u8", nil),
            ("https://video.example/watch", "yt-dlp"),
            ("https://cdn.example/extensionless", "yt-dlp"),
            ("https://x.com/example/status/123456789", "yt-dlp"),
            ("https://clips.twitch.tv/ExampleClip", "yt-dlp"),
            ("file:///tmp/clip.mp4", nil)
        ]
        for (raw, expected) in cases {
            let url = URL(string: raw)!
            try check(registry.adapter(for: url)?.id == expected, "Shipped routing changed: \(raw)")
            try check(SourceResolver.needsResolution(url) == (expected != nil), "Loading phase disagrees with registry")
        }
        print("PASS standard registry and YouTube/automatic website/direct/local routing")
    }

    static func registryChecks() async throws {
        let fallback = FixtureAdapter(id: "fallback", hosts: [], isFallback: true)
        let adapter = FixtureAdapter(id: "example", hosts: ["video.example"])
        for adapters in [[adapter, fallback], [fallback, adapter]] {
            let registry = try SourceRegistry(adapters: adapters)
            try check(registry.adapter(for: URL(string: "https://VIDEO.EXAMPLE/watch")!)?.id == "example", "Host matching was case sensitive")
            for raw in ["https://video.example.evil.test/watch", "https://sub.video.example/watch", "https://evil.test/video.example"] {
                try check(registry.adapter(for: URL(string: raw)!)?.id == "fallback", "Host match escaped its exact domain")
            }
            for raw in ["https://video.example/movie.mp4", "file:///tmp/movie", "ftp://video.example/watch"] {
                try check(registry.adapter(for: URL(string: raw)!) == nil, "Helper-free routing was lost")
            }
        }
        try rejects(.duplicateProvider) { _ = try SourceRegistry(adapters: [adapter, adapter]) }
        try rejects(.duplicateHost) {
            _ = try SourceRegistry(adapters: [adapter, FixtureAdapter(id: "other", hosts: ["video.example"])])
        }
        try rejects(.duplicateFallback) {
            _ = try SourceRegistry(adapters: [fallback, FixtureAdapter(id: "other", hosts: [], isFallback: true)])
        }
        try rejects { _ = try SourceRegistry(adapters: [FixtureAdapter(id: "bad", hosts: ["*.example"])]) }
        let intercept = FixtureAdapter(id: "intercept", hosts: ["video.example"], handlesDirectMediaURLs: true)
        try check(SourceRegistry(adapters: [intercept]).adapter(for: URL(string: "https://video.example/movie.mp4")!)?.id == "intercept",
                  "Custom adapter could not opt into URL normalization")
        let injected = SourceResolver(registry: try SourceRegistry(adapters: [intercept]))
        try check(injected.needsResolution(for: URL(string: "https://video.example/movie.mp4")!),
                  "Injected registry's loading state disagreed with discovery")
        try check(!injected.needsResolution(for: URL(string: "https://unregistered.example/watch")!),
                  "Injected registry unexpectedly used the shipped fallback")
        let many: [any SourceAdapter] = (0..<66).map {
            FixtureAdapter(id: "provider-\($0)", hosts: ["provider-\($0).example"])
        }
        try check(SourceRegistry(adapters: many).providerIDs.count == 66,
                  "Custom adapters were unexpectedly capped")

        let direct = MediaCandidate(source: ResolvedSource(url: URL(string: "https://cdn.example/direct.mp4")!, delivery: .file),
                                    id: "native", height: 720)
        let remux = MediaCandidate(source: ResolvedSource(url: URL(string: "https://cdn.example/remux.webm")!, needsPreparation: true),
                                   id: "remux", height: 1080)
        let custom = FixtureAdapter(id: "custom", hosts: ["custom.example"], choices: [remux, direct])
        let shipped = try SourceRegistry.standard(additionalAdapters: [custom])
        let resolver = SourceResolver(registry: shipped)
        let url = URL(string: "https://custom.example/watch")!
        let automatic = try await resolver.resolve(url)
        let selected = try await resolver.resolve(url, sourceID: "remux")
        let quality = try await resolver.resolve(url, preferQuality: true)
        try check(automatic.url == direct.source.url, "Custom discovery bypassed shared ranking")
        try check(selected.playbackPath == .remux, "Custom sources lost explicit selection")
        try check(quality.url == remux.source.url, "Custom sources lost quality policy")
        try rejects(.duplicateHost) {
            _ = try SourceRegistry.standard(additionalAdapters: [FixtureAdapter(id: "spoof", hosts: ["youtu.be"])])
        }
        print("PASS custom adapter registration, routing conflicts and shared candidate selection")
    }

    static func extractedChecks(directory: URL) async throws {
        let metadata: [String: Any] = ["_type": "video", "formats": [
            ["format_id": "combined", "url": "https://cdn.example/movie.mp4", "protocol": "https",
             "vcodec": "avc1.640028", "acodec": "mp4a.40.2", "ext": "mp4", "height": 1080]
        ]]
        let data = try JSONSerialization.data(withJSONObject: metadata)
        let output = directory.appendingPathComponent("result.json")
        let arguments = directory.appendingPathComponent("arguments.txt")
        let helper = directory.appendingPathComponent("yt-dlp-fixture")
        try data.write(to: output)
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(arguments.path)'\ncat '\(output.path)'\n"
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let environment = ["AIRTHROW_YTDLP": helper.path, "AIRTHROW_DENO": "/missing/deno",
                           "AIRTHROW_YTDLP_COOKIES": "/private/credentials"]
        let resolver = SourceResolver(environment: environment,
                                      cookies: .file(directory.appendingPathComponent("unused-cookies")))
        let url = URL(string: "https://video.example/watch?id=signed-value")!
        let resolved = try await resolver.resolve(url)
        try check(resolved.playbackPath == .direct && resolved.videoKnownPresent, "Automatic website extraction did not produce playable metadata")
        let args = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        try check(!args.contains("--use-extractors") && !args.contains("--ies"),
                  "Automatic extractor selection was restricted by the app")
        try check(args.suffix(2) == ["--", url.absoluteString], "Original URL was changed or parsed as an option")
        for flag in ["--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-cache-dir", "--no-playlist"] {
            try check(args.contains(flag), "Website extraction lost shared helper restriction")
        }
        try check(!args.contains("--cookies") && !args.contains("--cookies-from-browser"), "Website extraction imported YouTube credentials")
        try FileManager.default.removeItem(at: arguments)
        let directURL = URL(string: "https://video.example/movie.mp4")!
        let direct = try await resolver.resolve(directURL)
        try check(direct.url == directURL, "Recognizable media stopped bypassing helper")
        try check(!FileManager.default.fileExists(atPath: arguments.path), "Direct media invoked the website extractor")

        let absent = SourceResolver(environment: ["AIRTHROW_YTDLP": "/missing/helper"])
        let native = try await absent.resolve(url)
        try check(native.url == url && !native.videoKnownPresent,
                  "Missing helper lost the one native attempt")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: helper)
        let extensionless = URL(string: "https://cdn.example/extensionless")!
        let rejected = try await resolver.resolve(extensionless)
        try check(rejected.url == extensionless, "Rejected extraction lost extensionless native fallback")
        print("PASS automatic extractor arguments, shared metadata parsing, cookie isolation and native fallback")
    }

    static func main() async {
        do {
            try routingChecks()
            if CommandLine.arguments.contains("--routing-only") { return }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("athrow-registry-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await registryChecks()
            try await extractedChecks(directory: root)
            print("All source registry checks passed; receiver playback untested.")
        } catch {
            FileHandle.standardError.write(Data("Source registry checks failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
