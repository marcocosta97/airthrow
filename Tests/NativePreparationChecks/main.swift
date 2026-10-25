import AirThrowCore
import AVFoundation
import Foundation

@main @MainActor struct NativePreparationChecks {
    nonisolated static func check(_ value: Bool, _ message: String) throws {
        if !value { throw AppFailure(.playbackFailed, message) }
    }
    static func main() async {
        do { try await run() } catch { print("FAIL native preparation: \(error)"); exit(1) }
    }
    static func run() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let base = URL(string: CommandLine.arguments[2])!
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func get(_ url: URL, range: String? = nil, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
            request.httpMethod = method
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        // Coalesced overlapping readers and distant seeks share bounded range data.
        let relay = try await HTTPMediaRelay.start(source: base.appendingPathComponent("bytes.bin"), host: "127.0.0.1", readAheadBytes: 8 * 1024 * 1024)
        do {
            let url = relay.url!
            let head = try await get(url, method: "HEAD")
            try check(head.0.isEmpty && head.1.expectedContentLength == 4 * 1024 * 1024, "Cached HEAD length")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for start in [0, 0, 100, 2_000_000, 3_000_000, 700_000, 1_000_000, 0] {
                    group.addTask {
                        let (data, response) = try await get(url, range: "bytes=\(start)-\(start + 65535)")
                        try check(response.statusCode == 206 && data == Data((start..<start + 65536).map { UInt8($0 % 251) }), "Range corruption or concurrent reader cancellation")
                    }
                }
                try await group.waitForAll()
            }
            let invalid = try await get(url, range: "bytes=9000000-")
            try check(invalid.1.statusCode == 416, "Invalid cache range")
            let suffix = try await get(url, range: "bytes=-32")
            let tailStart = 4_194_304 - 32
            let expectedTail = Data((tailStart..<4_194_304).map { UInt8($0 % 251) })
            try check(suffix.0 == expectedTail, "Suffix range")
            print("PASS shared range cache: concurrent consumers, seeks, suffix, HEAD, invalid range")
        } catch { relay.stop(); throw error }
        relay.stop()
        for name in ["uncached.bin", "changed.bin"] {
            let testRelay = try await HTTPMediaRelay.start(source: base.appendingPathComponent(name), host: "127.0.0.1", readAheadBytes: 8 * 1024 * 1024)
            do {
                let response = try await get(testRelay.url!, range: "bytes=0-65535")
                try check(response.1.statusCode == (name == "changed.bin" ? 502 : 206), "Changed source or streaming fallback")
                if name == "uncached.bin" { try check(response.0 == Data((0..<65536).map { UInt8($0 % 251) }), "Streaming fallback bytes") }
            } catch { testRelay.stop(); throw error }
            testRelay.stop()
        }
        print("PASS validator change rejection and no-validator streaming fallback")
        guard #available(macOS 26, *) else { return }
        for (name, enhancement, backend, remote, cached) in [
            ("cleanup", VideoEnhancement.cleanup1080, VideoUpscaler.lowLatency, false, false),
            ("cleanup", .cleanup1080, .standard, false, true),
            ("cleanup", .cleanup1080, .lowLatency, true, false),
            ("cleanup-fractional", .cleanup1080, .lowLatency, false, false),
            ("ai", .upscale1080, .lowLatency, false, false),
            ("ai", .upscale1080, .lowLatency, true, true),
            ("remux", .original, .automatic, true, false),
            ("audio", .original, .automatic, true, false),
            ("convert", .original, .automatic, true, false)
        ] {
            let ext = ["remux", "audio", "convert"].contains(name) ? "mkv" : "mp4"
            let input = remote ? base.appendingPathComponent("\(name).\(ext)") : folder.appendingPathComponent("\(name).\(ext)")
            let source = ResolvedSource(url: input, needsDelivery: true, delivery: .file, conversionPolicy: .allowVideo)
                .withEnhancement(enhancement, upscaler: backend)
            let began = Date()
            let prepared = try await MediaPreparer(environment: environment, preferences: PreparationPreferences(noiseReduction: name == "cleanup" && !remote && !cached ? .automatic : .gpu))
                .prepare(source, mode: cached ? .progressiveHLS : .completeFile)
            do {
                try check(prepared.usesBoundedCache == cached, "Native output cache policy")
                let label = "\(name)-\(remote ? "remote" : "local")-\(cached ? "cached" : "complete")"
                if cached {
                    let (manifest, _) = try await get(prepared.url)
                    let names = String(decoding: manifest, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }
                    for (index, name) in names.enumerated() {
                        prepared.updatePlaybackPosition(Double(index) * 6)
                        let (data, response) = try await get(URL(string: String(name), relativeTo: prepared.url)!)
                        try check(response.statusCode == 200, "Native chunk request")
                        try data.write(to: folder.appendingPathComponent("\(label)-\(index).ts"))
                    }
                } else {
                    let (data, response) = try await get(prepared.url)
                    try check(response.statusCode == 200, "Native output response")
                    try data.write(to: folder.appendingPathComponent("\(label).mp4"))
                }
                if name.hasPrefix("cleanup") || name == "ai" {
                    let stats = prepared.nativeProcessingDiagnostics!
                    try check(stats.frames > 0 && stats.hardwareDecodedFrames == stats.frames, "Hardware decoder was bypassed")
                    try check(stats.prefetchedClipsDuringProcessing > 0, "Input fetch did not overlap native processing")
                    if name.hasPrefix("cleanup") { try check(stats.metalPasses > 0, "Cleanup did not execute Metal kernels") }
                    print("METRICS \(label) \(String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)) elapsed=\(Date().timeIntervalSince(began))")
                }
                print("PASS \(label) path=\(prepared.playbackPath)")
            } catch { prepared.stop(); await prepared.waitForProducer(); throw error }
            prepared.stop(); await prepared.waitForProducer()
        }
        let source = ResolvedSource(url: folder.appendingPathComponent("cleanup.mp4"), delivery: .file, conversionPolicy: .allowVideo)
            .withEnhancement(.upscale1080, upscaler: .lowLatency)
        do {
            let result = try await MediaPreparer(environment: environment).prepare(source, mode: .completeFile)
            result.stop(); await result.waitForProducer(); throw AppFailure(.playbackFailed, "AI 1x was accepted")
        } catch let error as AppFailure { try check(error.code == .unsupportedOperation, "AI 1x rejection") }
        let cancelled = Task { try await MediaPreparer(environment: environment).prepare(source.withEnhancement(.cleanup1080), mode: .completeFile) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw AppFailure(.playbackFailed, "Cancellation ignored") } catch is CancellationError { }
        let inFlight = Task { try await MediaPreparer(environment: environment)
            .prepare(source.withEnhancement(.cleanup1080), mode: .completeFile) }
        try await Task.sleep(for: .milliseconds(250))
        inFlight.cancel()
        do {
            let result = try await inFlight.value
            result.stop(); await result.waitForProducer()
            throw AppFailure(.playbackFailed, "In-flight cancellation ignored")
        } catch is CancellationError { }
        print("PASS AI 1x rejection, immediate and in-flight cancellation")
    }
}
