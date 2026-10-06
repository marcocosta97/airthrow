import Foundation
import AVFoundation

/// A provider that deliberately completes after cancellation, modeling a
/// resource acquisition that has already passed its final cancellation check.
@MainActor
private final class LateResourceProvider {
    var pending: CheckedContinuation<URL, Never>?
    var pins = 0
    var releases = 0
    func load() async -> URL {
        pins += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func complete(_ url: URL) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: url)
    }
    func release(_ url: URL) { pins -= 1; releases += 1 }
}

@main
@MainActor
struct CacheChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "CacheChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL cache checks: \(error)"); exit(1) }
    }
    static func run() async throws {
        let base = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("cache-jobs.txt"))
        let sourceFile = directory.appendingPathComponent("cache-source.mpg")
        let originalSize = (try FileManager.default.attributesOfItem(atPath: sourceFile.path)[.size] as! NSNumber).int64Value
        let budget: Int64 = 16 * 1024 * 1024
        try check(originalSize > budget, "Large-source fixture is not larger than its cache budget")
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        environment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("cache-ffmpeg").path
        environment.removeValue(forKey: "AIRTHROW_PREPARATION_MODE")
        let preferences = PreparationPreferences(maximumBytes: budget, windowSeconds: 12)
        let preparer = MediaPreparer(environment: environment, preferences: preferences)
        let source = ResolvedSource(url: sourceFile, needsPreparation: true, conversionPolicy: .allowVideo)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("athrow-prepared-v1")
        MediaPreparer.cleanAbandonedFiles()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        let prepared = try await preparer.prepare(source)
        defer { prepared.stop() }
        try check(prepared.usesBoundedCache && prepared.sourceDuration! > 119 && !prepared.isProducing,
                  "Large input did not use idle finite cached preparation")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        try await lateResourceRelease(directory: directory, session: session)
        func fetch(_ name: String? = nil, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            let url = name.map { prepared.url.deletingLastPathComponent().appendingPathComponent($0) } ?? prepared.url
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.httpMethod = method; request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        }
        let (manifest, response) = try await fetch()
        let text = String(decoding: manifest, as: UTF8.self)
        try check(response.statusCode == 200 && text.contains("#EXT-X-PLAYLIST-TYPE:VOD")
                  && text.contains("#EXT-X-ENDLIST") && text.contains("segment000019.ts"), "VOD timeline is incomplete")
        let (first, _) = try await fetch("segment000000.ts")
        let (head, headResponse) = try await fetch("segment000000.ts", method: "HEAD")
        let (range, rangeResponse) = try await fetch("segment000000.ts", range: "bytes=0-99")
        try check(first.count > 1000 && head.isEmpty && headResponse.expectedContentLength == first.count
                  && rangeResponse.statusCode == 206 && range == first.prefix(100), "Cached HTTP ranges/HEAD failed")
        let workspaces = Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).subtracting(before)
        try check(workspaces.count == 1, "Cached producer leaked a workspace")
        let workspace = root.appendingPathComponent(workspaces.first!)
        func chunks() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: workspace.path).filter { $0.hasPrefix("chunk") }.sorted() }
        try check(try chunks() == ["chunk0"], "Paused preparation converted the whole input")
        prepared.updatePlaybackPosition(60)
        let far = try await fetch("segment000010.ts")
        try check(far.1.statusCode == 200 && far.0.count > 1000
                  && (try chunks()) == ["chunk0", "chunk10"], "Distant seek: HTTP \(far.1.statusCode), chunks \(try chunks())")
        let repeated = try await withThrowingTaskGroup(of: Int.self) { group in
            let url = prepared.url.deletingLastPathComponent().appendingPathComponent("segment000015.ts")
            for _ in 0..<6 { group.addTask {
                let (data, _) = try await session.data(from: url)
                return data.count
            } }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values
        }
        try check(Set(repeated).count == 1, "Concurrent requests produced inconsistent files")
        let log = directory.appendingPathComponent("cache-jobs.txt")
        let attempts = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        try check(attempts.count == 3, "Concurrent requests did not coalesce: \(attempts)")
        prepared.updatePlaybackPosition(90)
        try await Task.sleep(for: .seconds(16))
        prepared.updatePlaybackPosition(90)
        try check(try chunks() == ["chunk15"], "Old chunks did not leave the playback window")
        let regenerated = try await fetch("segment000000.ts")
        try check(regenerated.1.statusCode == 200 && regenerated.0.count > 1000,
                  "Evicted chunk could not be regenerated")
        try check(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 4,
                  "Backward seek did not regenerate exactly one chunk")
        for name in ["segment999999.ts", "segment000000.m4s", "init000000.mp4", "segment000000.ts.tmp", "chunk0/part.m3u8", "lease"] {
            let (_, denied) = try await fetch(name)
            try check(denied.statusCode == 404, "Private/invalid cached route was served: \(name)")
        }
        print("PASS large input beyond budget, finite VOD, demand-only generation, concurrent requests, eviction and regeneration")

        // AVPlayer must keep the full finite timeline and seek beyond the cache.
        let player = AVPlayer()
        let item = AVPlayerItem(url: prepared.url)
        player.replaceCurrentItem(with: item)
        var deadline = Date().addingTimeInterval(30)
        while item.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(item.status == .readyToPlay && abs(item.duration.seconds - prepared.sourceDuration!) < 0.2,
                  "Native player did not expose the finite VOD duration: \(String(describing: item.error))")
        let moved = await player.seek(to: CMTime(seconds: 108, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try check(moved && abs(player.currentTime().seconds - 108) < 0.2, "Native distant seek failed")
        // Exercise discontinuity playback with a real local player; no mock route.
        _ = await player.seek(to: CMTime(seconds: 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        deadline = Date().addingTimeInterval(20)
        while player.currentTime().seconds < 13, item.status != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(item.status == .readyToPlay && player.currentTime().seconds >= 13,
                  "Native playback stalled at an independently encoded chunk boundary: \(String(describing: item.error))")
        _ = await player.seek(to: CMTime(seconds: 118, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        deadline = Date().addingTimeInterval(15)
        while player.currentTime().seconds < 119.8, item.status != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(item.status == .readyToPlay && player.currentTime().seconds >= 119.8,
                  "The final fractional-duration chunk did not play")
        player.pause(); player.replaceCurrentItem(with: nil)
        prepared.cancelProduction()
        let retainedResponse = try await fetch("segment000019.ts")
        try check(retainedResponse.1.statusCode == 200, "Handoff cancellation disabled already-prepared delivery")
        prepared.stop(); await prepared.waitForProducer()
        try await Task.sleep(for: .milliseconds(100))
        try check(!FileManager.default.fileExists(atPath: workspace.path), "Stop retained the cache workspace")
        print("PASS local AVPlayer finite duration, distant seek and playback across chunk boundaries")

        for enhancement in [VideoEnhancement.upscale1080, .cleanup1080, .upscale4K, .cleanup4K] {
            let short = ResolvedSource(url: URL(string: base + "/combined.mp4")!, needsPreparation: true).withEnhancement(enhancement)
            let enhanced = try await MediaPreparer(environment: environment).prepare(short)
            try check(enhanced.usesBoundedCache && enhanced.videoHeight == enhancement.targetHeight,
                      "Cached \(enhancement.rawValue) output quality is incorrect")
            let native = AVPlayerItem(url: enhanced.url)
            player.replaceCurrentItem(with: native)
            deadline = Date().addingTimeInterval(30)
            while native.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            try check(native.status == .readyToPlay && abs(native.duration.seconds - 2) < 0.2,
                      "Cached \(enhancement.rawValue) is not natively playable: \(String(describing: native.error))")
            player.replaceCurrentItem(with: nil)
            enhanced.stop(); await enhanced.waitForProducer()
        }
        print("PASS all four cached enhancement presets and native H.264/HEVC readiness")

        let noRange = ResolvedSource(url: URL(string: base + "/no-range-vp9.mkv")!, needsPreparation: true, conversionPolicy: .allowVideo)
        let sequential = try await MediaPreparer(environment: environment).prepare(noRange)
        try check(!sequential.usesBoundedCache, "A server without byte ranges entered restartable preparation")
        sequential.stop(); await sequential.waitForProducer()
        let hlsSource = ResolvedSource(url: URL(string: base + "/native-stream")!, needsPreparation: true).withEnhancement(.upscale1080)
        let hls = try await MediaPreparer(environment: environment).prepare(hlsSource)
        try check(!hls.usesBoundedCache, "An HLS input entered file-based restartable preparation")
        hls.stop(); await hls.waitForProducer()
        print("PASS sequential fallback for sources without random access and HLS inputs")

        let longHEVC = ResolvedSource(url: URL(string: base + "/long.mp4")!, needsPreparation: true).withEnhancement(.upscale4K)
        let hevc = try await MediaPreparer(environment: environment).prepare(longHEVC)
        let hevcItem = AVPlayerItem(url: hevc.url)
        player.replaceCurrentItem(with: hevcItem)
        deadline = Date().addingTimeInterval(30)
        while hevcItem.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(hevcItem.status == .readyToPlay, "Multi-chunk HEVC did not open")
        _ = await player.seek(to: CMTime(seconds: 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        deadline = Date().addingTimeInterval(20)
        while player.currentTime().seconds < 9, hevcItem.status != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(hevcItem.status == .readyToPlay && player.currentTime().seconds >= 9,
                  "HEVC stalled at a fragment initialization/discontinuity boundary: \(String(describing: hevcItem.error))")
        let hevcMoved = await player.seek(to: CMTime(seconds: 18, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try check(hevcMoved && abs(player.currentTime().seconds - 18) < 0.2, "HEVC distant seek failed")
        player.pause(); player.replaceCurrentItem(with: nil)
        hevc.stop(); await hevc.waitForProducer()
        print("PASS local HEVC playback across initialization/discontinuity boundaries and distant seek")

        var pacedEnvironment = environment
        pacedEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("paced-ffmpeg").path
        let cancellable = try await MediaPreparer(environment: pacedEnvironment).prepare(source)
        let cancelledURL = cancellable.url.deletingLastPathComponent().appendingPathComponent("segment000010.ts")
        let waiting = Task { try await session.data(from: cancelledURL) }
        try await Task.sleep(for: .milliseconds(300))
        let stoppedAt = Date()
        cancellable.stop(); await cancellable.waitForProducer()
        try check(Date().timeIntervalSince(stoppedAt) < 2, "Stop waited for a requested chunk to finish encoding")
        _ = try? await waiting.value
        try check(cancellable.productionFailure == nil, "Requested-chunk cancellation became a playback error")
        print("PASS Stop cancels an in-flight requested chunk without a terminal failure")

        let controller = PlaybackController(resolveSource: { _ in source }, allowVideoConversion: true,
                                            prepareSource: { try await preparer.prepare($0) })
        try controller.load("https://example.com/cache-fixture")
        deadline = Date().addingTimeInterval(30)
        while controller.snapshot.state == .loading, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(controller.snapshot.state == .awaitingReceiver && !controller.snapshot.isLive
                  && controller.snapshot.duration! > 119 && controller.player.rate == 0
                  && controller.player.isMuted && (controller.snapshot.seekableRanges.last?.end ?? 0) > 119,
                  "Shared controller cached state: \(String(decoding: try JSONEncoder().encode(controller.snapshot), as: UTF8.self))")
        await controller.shutdownAndWait()
        print("PASS shared controller keeps cached media paused with a full finite seek range")

        do {
            _ = try await MediaPreparer(environment: environment,
                preferences: PreparationPreferences(maximumBytes: 1000)).prepare(source)
            try check(false, "Tiny cache escaped its budget")
        } catch let failure as PreparationFailure {
            try check(failure == .storageLimit, "Cache-budget failure lost its specific recovery")
        }
        let defaults = UserDefaults(suiteName: "AirThrow.CacheChecks.\(UUID().uuidString)")!
        defaults.set(8, forKey: PreparationPreferences.maximumGiBKey)
        defaults.set(120, forKey: PreparationPreferences.windowSecondsKey)
        defaults.set(true, forKey: PreparationPreferences.retainAllKey)
        let saved = PreparationPreferences.current(defaults)
        try check(saved.maximumBytes == 8 * 1024 * 1024 * 1024 && saved.windowSeconds == 120 && saved.retainAll,
                  "Preparation preferences were not read")
        for key in [PreparationPreferences.maximumGiBKey, PreparationPreferences.windowSecondsKey, PreparationPreferences.retainAllKey] {
            defaults.removeObject(forKey: key)
        }
        print("PASS configurable preparation preferences and distinct storage-limit failure")
        try await Task.sleep(for: .milliseconds(100))
        try check(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == before,
                  "Cached shutdown or startup failure retained a workspace")
    }

    static func lateResourceRelease(directory: URL, session: URLSession) async throws {
        let manifest = directory.appendingPathComponent("late-release.m3u8")
        try Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8).write(to: manifest)
        defer { try? FileManager.default.removeItem(at: manifest) }
        let provider = LateResourceProvider()
        let server = try await MediaHTTPServer.start(file: manifest, host: "127.0.0.1", hls: true,
                                                    loadResource: { _ in await provider.load() },
                                                    releaseResource: { provider.release($0) })
        defer { server.stop(); provider.complete(manifest) }
        let url = server.url!.deletingLastPathComponent().appendingPathComponent("segment000000.ts")
        let request = Task { try await session.data(from: url) }
        defer { request.cancel() }
        var deadline = Date().addingTimeInterval(5)
        while provider.pending == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(provider.pending != nil && provider.pins == 1, "HTTP resource provider did not acquire a pin")
        server.stop()
        provider.complete(manifest)
        deadline = Date().addingTimeInterval(5)
        while provider.releases == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        _ = try? await request.value
        try check(provider.pins == 0 && provider.releases == 1,
                  "Stop did not release a late HTTP resource exactly once")
        server.stop()
        try check(provider.releases == 1, "Repeated Stop released the resource twice")
        print("PASS Stop releases a resource completed after cancellation exactly once")
    }
}
