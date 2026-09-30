import Foundation
import Darwin
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private struct CheckFailure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message: message) }
}
private func rejects(_ expected: SourceRegistryError = .invalidManifest, _ action: () throws -> Void) throws {
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
    static func json(_ changes: [String: Any] = [:]) throws -> Data {
        let base: [String: Any] = ["schemaVersion": 1, "id": "example-video", "name": "Example Video",
                                  "hosts": ["video.example", "www.video.example"],
                                  "extractors": ["example:video"]]
        return try JSONSerialization.data(withJSONObject: base.merging(changes) { _, new in new })
    }

    static func bundledChecks() throws {
        let registry = try SourceRegistry.bundled(environment: ["AIRTHROW_YTDLP": "/missing/helper"])
        try check(registry.providerIDs.contains("youtube") && registry.providerIDs.contains("generic-web"),
                  "Shipped registry lost an existing provider")
        let cases: [(String, String?)] = [
            ("https://www.youtube.com/watch?v=aqz-KE-bpKQ", "youtube"),
            ("https://youtu.be/aqz-KE-bpKQ", "youtube"),
            ("https://www.youtube.com/not-a-video.mp4", "youtube"),
            ("https://youtube.com.evil.example/watch?v=aqz-KE-bpKQ", "generic-web"),
            ("https://cdn.example/clip.MP4?signature=secret", nil),
            ("https://cdn.example/clip.m3u8", nil),
            ("https://video.example/watch", "generic-web"),
            ("https://cdn.example/extensionless", "generic-web"),
            ("file:///tmp/clip.mp4", nil)
        ]
        for (raw, expected) in cases {
            let url = URL(string: raw)!
            try check(registry.adapter(for: url)?.id == expected, "Shipped routing changed: \(raw)")
            try check(SourceResolver.needsResolution(url) == (expected != nil), "Loading phase disagrees with registry")
        }
        print("PASS bundled manifests and existing YouTube/generic/direct/local routing")
    }

    static func manifestChecks(directory: URL) throws {
        let decoded = try JSONDecoder().decode(YTDLPSourceManifest.self, from: json())
        try check(decoded.id == "example-video" && !decoded.fallback, "Manifest defaults were lost")
        let bad: [[String: Any]] = [
            ["schemaVersion": 2], ["schemaVersion": "1"], ["id": "Bad ID"], ["id": "-bad"],
            ["id": String(repeating: "a", count: 65)], ["name": ""], ["name": "Video\nSecret"],
            ["hosts": []], ["hosts": ["*.example.com"]], ["hosts": ["https://example.com"]],
            ["hosts": ["example.com/path"]], ["hosts": ["example.com:443"]], ["hosts": ["Example.com"]],
            ["hosts": ["example..com"]], ["hosts": ["-bad.example"]], ["hosts": ["bad-.example"]],
            ["hosts": ["example.com."]], ["hosts": ["example.com", "example.com"]],
            ["hosts": Array(repeating: "example.com", count: 33)],
            ["extractors": []], ["extractors": ["all"]], ["extractors": ["default"]], ["extractors": ["end"]],
            ["extractors": ["generic"]], ["extractors": ["example.*"]], ["extractors": ["example,other"]],
            ["extractors": ["--cookies"]], ["extractors": ["Example", "example"]],
            ["cookies": "secret"], ["headers": ["Referer": "secret"]], ["arguments": ["--exec", "secret"]],
            ["fallback": true], ["hosts": [], "fallback": true, "extractors": ["example"]]
        ]
        for changes in bad {
            // Decoding failures are intentionally mapped to one fixed manifest error.
            do {
                _ = try JSONDecoder().decode(YTDLPSourceManifest.self, from: json(changes))
                throw CheckFailure(message: "Malformed manifest was accepted: \(changes.keys.sorted())")
            } catch is SourceRegistryError { }
              catch is DecodingError { }
        }
        let fallback = try YTDLPSourceManifest(id: "generic-test", name: "Generic", hosts: [],
                                              extractors: ["generic"], fallback: true)
        try check(fallback.fallback, "Generic fallback was rejected")
        let a = directory.appendingPathComponent("a.json")
        let z = directory.appendingPathComponent("z.json")
        try json().write(to: z)
        try json(["id": "another-video", "hosts": ["another.example"]]).write(to: a)
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let loaded = try YTDLPSourceManifest.load(from: directory)
        try check(loaded.map(\.id) == ["another-video", "example-video"], "Manifest file discovery was not deterministic")
        try Data(repeating: 0x20, count: 65 * 1024).write(to: a)
        try rejects { _ = try YTDLPSourceManifest.load(from: directory) }
        try Data("{bad json".utf8).write(to: a)
        try rejects { _ = try YTDLPSourceManifest.load(from: directory) }
        try FileManager.default.removeItem(at: a)
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: z)
        try rejects { _ = try YTDLPSourceManifest.load(from: directory) }
        try FileManager.default.removeItem(at: a)
        try FileManager.default.removeItem(at: z)
        try rejects(.unavailableManifests) { _ = try YTDLPSourceManifest.load(from: directory) }
        for offset in 0..<65 { try json().write(to: directory.appendingPathComponent("\(offset).json")) }
        try rejects { _ = try YTDLPSourceManifest.load(from: directory) }
        print("PASS manifest schema, access restrictions, bounded loading and malformed-file rejection")
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
                  "Custom adapter count was incorrectly limited by the manifest file cap")

        let direct = MediaCandidate(source: ResolvedSource(url: URL(string: "https://cdn.example/direct.mp4")!, delivery: .file),
                                    id: "native", height: 720)
        let remux = MediaCandidate(source: ResolvedSource(url: URL(string: "https://cdn.example/remux.webm")!, needsPreparation: true),
                                   id: "remux", height: 1080)
        let custom = FixtureAdapter(id: "custom", hosts: ["custom.example"], choices: [remux, direct])
        let shipped = try SourceRegistry.bundled(additionalAdapters: [custom])
        let resolver = SourceResolver(registry: shipped)
        let url = URL(string: "https://custom.example/watch")!
        let automatic = try await resolver.resolve(url)
        let selected = try await resolver.resolve(url, sourceID: "remux")
        let quality = try await resolver.resolve(url, preferQuality: true)
        try check(automatic.url == direct.source.url, "Custom discovery bypassed shared ranking")
        try check(selected.playbackPath == .remux, "Custom sources lost explicit selection")
        try check(quality.url == remux.source.url, "Custom sources lost quality policy")
        try rejects(.duplicateHost) {
            _ = try SourceRegistry.bundled(additionalAdapters: [FixtureAdapter(id: "spoof", hosts: ["youtu.be"])])
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
        let manifest = try JSONDecoder().decode(YTDLPSourceManifest.self, from: json())
        let environment = ["AIRTHROW_YTDLP": helper.path, "AIRTHROW_DENO": "/missing/deno",
                           "AIRTHROW_YTDLP_COOKIES": "/private/credentials"]
        let adapter = YTDLPSourceAdapter(manifest: manifest, environment: environment)
        let registry = try SourceRegistry(adapters: [adapter])
        let resolver = SourceResolver(registry: registry)
        let url = URL(string: "https://video.example/watch?id=signed-value")!
        let resolved = try await resolver.resolve(url)
        try check(resolved.playbackPath == .direct && resolved.videoKnownPresent, "Manifest-backed source did not produce playable metadata")
        let args = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
        let index = args.firstIndex(of: "--use-extractors")!
        try check(args[index + 1] == "^example:video$", "Extractor names were not restricted to exact matches")
        try check(args.suffix(2) == ["--", url.absoluteString], "Original URL was changed or parsed as an option")
        for flag in ["--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-cache-dir", "--no-playlist"] {
            try check(args.contains(flag), "Manifest extraction lost shared helper restriction")
        }
        try check(!args.contains("--cookies") && !args.contains("--cookies-from-browser"), "Manifest source imported YouTube credentials")
        try FileManager.default.removeItem(at: arguments)
        let directURL = URL(string: "https://video.example/movie.mp4")!
        let direct = try await resolver.resolve(directURL)
        try check(direct.url == directURL, "Recognizable media stopped bypassing helper")
        try check(!FileManager.default.fileExists(atPath: arguments.path), "Direct media invoked the manifest extractor")

        let missing = YTDLPSourceAdapter(manifest: manifest, environment: ["AIRTHROW_YTDLP": "/missing/helper"])
        do {
            _ = try await SourceResolver(registry: SourceRegistry(adapters: [missing])).resolve(url)
            throw CheckFailure(message: "Known website became an HTML native candidate when helper was missing")
        } catch ResolutionFailure.unavailable { }
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: helper)
        do {
            _ = try await resolver.resolve(url)
            throw CheckFailure(message: "Rejected known website became an HTML native candidate")
        } catch ResolutionFailure.failed { }
        print("PASS manifest extractor execution, exact allowlist, cookie isolation and known-site errors")
    }

    static func main() async {
        do {
            try bundledChecks()
            if let index = CommandLine.arguments.firstIndex(of: "--resolve-manifest") {
                guard CommandLine.arguments.count == index + 3,
                      let url = URL(string: CommandLine.arguments[index + 1]) else {
                    throw CheckFailure(message: "Expected a fixture URL and provider ID")
                }
                let registry = try SourceRegistry.bundled()
                try check(registry.adapter(for: url)?.id == CommandLine.arguments[index + 2],
                          "Added manifest was not automatically registered")
                let source = try await SourceResolver(registry: registry).resolve(url)
                try check(source.videoKnownPresent && source.playbackPath == .direct,
                          "Added manifest did not resolve through the shared pipeline")
                print("PASS added manifest discovery and extraction without resolver changes")
                return
            }
            if CommandLine.arguments.contains("--bundled-only") { return }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("athrow-registry-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let manifests = root.appendingPathComponent("manifests")
            try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: false)
            try manifestChecks(directory: manifests)
            try await registryChecks()
            try await extractedChecks(directory: root)
            print("All source registry checks passed; receiver playback untested.")
        } catch {
            FileHandle.standardError.write(Data("Source registry checks failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
