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
    private static let started = ContinuousClock().now
    @MainActor private final class SeekOutcome { var finished: Bool? }
    @MainActor private final class PreparedHolder {
        var value: PreparedMedia?
        func store(_ value: PreparedMedia) { self.value = value }
    }
    @MainActor private final class CacheProducer {
        var started: [Int] = []
        var finished: [Int] = []
        var active = 0
        var maximumActive = 0
        let bytes: Int
        init(bytes: Int = 1024) { self.bytes = bytes }
        func produce(_ index: Int, directory: URL) async throws -> (height: Int?, frameRate: Double?) {
            started.append(index); active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(50))
            try Data(repeating: 0, count: bytes).write(to: directory.appendingPathComponent(String(format: "segment%06d.ts", index)))
            finished.append(index)
            return (180, 24)
        }
    }

    static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(condition(), message)
    }

    static func schedulingChecks() async throws {
        var measured = PreparationPacing()
        measured.record(mediaSeconds: 6, elapsedSeconds: 3, bytes: 8000)
        try check(measured.canBuildSurplus && measured.secondsPerMediaSecond == 0.5 && measured.speed == 2,
                  "Faster-than-playback production could not build surplus")
        for _ in 0..<8 { measured.record(mediaSeconds: 6, elapsedSeconds: 9, bytes: 16000) }
        try check(!measured.canBuildSurplus && measured.largestChunkBytes == 16000,
                  "Pacing did not adapt to sustained slower production or larger chunks")
        for _ in 0..<8 { measured.record(mediaSeconds: 6, elapsedSeconds: 1, bytes: 4000) }
        try check(measured.canBuildSurplus, "Pacing did not recover when production sped up")
        report("PASS measured production ratio adapts to slowdown and recovery")
        do {
            let workspace = try PreparationWorkspace()
            let producer = CacheProducer()
            let cache = try CachedHLS(workspace: workspace, duration: 600, fragmented: false,
                                     preferences: PreparationPreferences()) { index, _, _, directory in
                try await producer.produce(index, directory: directory)
            }
            defer { cache.stop() }
            try await cache.warmUp()
            cache.updatePosition(0, playing: true)
            try await waitUntil("Seek fixture did not start speculation", { producer.started.contains(1) })
            try await cache.prepareSeek(at: 300)
            try check(producer.finished.contains(50) && !producer.started.contains(where: { (2..<50).contains($0) })
                      && cache.readyRanges.contains(SeekRange(start: 300, end: 306)),
                      "Five-minute seek prepared intervening chunks or failed to prioritize its target")
            try await cache.prepareSeek(at: 305)
            try check(cache.readyRanges.contains(SeekRange(start: 300, end: 312)) && producer.maximumActive == 1,
                      "Seek near a chunk end lacked a continuous buffer or overlapped encoders")
            let abandoned = Task { try await cache.prepareSeek(at: 540) }
            try await waitUntil("Cancellation fixture did not start seek encoding", { producer.started.contains(90) })
            abandoned.cancel()
            do { try await abandoned.value; try check(false, "Cancelled seek preparation completed") }
            catch is CancellationError {}
            try check(producer.active == 0, "Cancelled seek left its encoder running")
            report("PASS five-minute seek prioritizes target, skips earlier chunks and cancels obsolete work")
        }
        do {
            let workspace = try PreparationWorkspace()
            let producer = CacheProducer()
            let cache = try CachedHLS(workspace: workspace, duration: 600, fragmented: false,
                                     preferences: PreparationPreferences()) { index, _, _, directory in
                try await producer.produce(index, directory: directory)
            }
            defer { cache.stop() }
            try await cache.warmUp(at: 40)
            try check(producer.started == [0, 6, 7]
                      && cache.readyRanges == [SeekRange(start: 0, end: 6), SeekRange(start: 36, end: 48)],
                      "Replacement warmed intervening chunks instead of the saved-position chunk")
            report("PASS replacement warms bootstrap and at least six continuous seconds at 40 seconds")
        }
        let workspace = try PreparationWorkspace()
        let producer = CacheProducer()
        let cache = try CachedHLS(workspace: workspace, duration: 600, fragmented: false,
                                 preferences: PreparationPreferences()) { index, _, _, directory in
            try await producer.produce(index, directory: directory)
        }
        defer { cache.stop() }
        try await cache.warmUp()
        try check(cache.readyRanges == [SeekRange(start: 0, end: 6)], "Warm-up advertised unprepared chunks")
        cache.updatePosition(0, playing: true)
        // No further time observer callbacks: buffering can stop the playback clock.
        try await waitUntil("Playing cache did not start preparation", { producer.started.contains(1) })
        let requested = try await cache.resource("segment000070.ts")
        cache.release(requested)
        try check(cache.readyRanges.contains(SeekRange(start: 420, end: 426)), "Distant ready chunk was not reported separately")
        try check(producer.started.firstIndex(of: 70)! <= 3,
                  "HTTP demand waited behind an entire speculative window")
        try await waitUntil("Fast preparation stopped at the fixed 45-second window", { producer.finished.contains(10) })
        try check(cache.pacing.canBuildSurplus, "Fetch and processing timing was not measured")
        try check(producer.maximumActive == 1, "Look-ahead ran multiple encoders concurrently")
        cache.updatePosition(0)
        await cache.waitForJobs()
        let pausedAttempts = producer.started.count
        try await Task.sleep(for: .milliseconds(150))
        try check(producer.started.count == pausedAttempts && producer.active == 0,
                  "Paused cache continued speculative production")
        cache.updatePosition(300, playing: true)
        try await waitUntil("Resume did not refill at the new position", { producer.started.contains(50) })
        cache.updatePosition(300)
        await cache.waitForJobs()
        try check(producer.active == 0, "Pause left an unrequested encoder running")
        let attempts = producer.started.count
        try await Task.sleep(for: .milliseconds(150))
        try check(producer.started.count == attempts, "Cancellation restarted speculative production")
        cache.stop(); await cache.waitForJobs()
        report("PASS adaptive look-ahead beyond 45s without clock updates, demand priority, serialized production and pause cancellation")

        let limitedWorkspace = try PreparationWorkspace()
        let limitedProducer = CacheProducer(bytes: 8000)
        let limited = try CachedHLS(workspace: limitedWorkspace, duration: 120, fragmented: false,
                                   preferences: PreparationPreferences(maximumBytes: 48 * 1024)) { index, _, _, directory in
            try await limitedProducer.produce(index, directory: directory)
        }
        defer { limited.stop() }
        try await limited.warmUp()
        limited.updatePosition(0, playing: true)
        try await waitUntil("Budget fixture did not fill", { limitedProducer.finished.count >= 2 })
        try await Task.sleep(for: .milliseconds(250))
        let limitedAttempts = limitedProducer.started.count
        try await Task.sleep(for: .milliseconds(250))
        try check(limitedProducer.started.count == limitedAttempts && limitedAttempts < 8,
                  "Space pressure caused continuous eviction and re-encoding of the look-ahead")
        try check(limitedProducer.active == 0, "Budget-limited speculation did not stop")
        let next = limitedWorkspace.directory.appendingPathComponent("chunk1/segment000001.ts")
        let demandedResource = try await limited.resource("segment000010.ts")
        limited.release(demandedResource)
        try check(limitedProducer.finished.contains(10), "Prefetch space reserve blocked HTTP demand")
        try check(FileManager.default.fileExists(atPath: next.path), "Distant demand evicted the next playback chunk")
        limited.stop(); await limited.waitForJobs()
        report("PASS space pressure stops speculation while HTTP demand can still generate chunks")

        let failingWorkspace = try PreparationWorkspace()
        let failingProducer = CacheProducer()
        let failing = try CachedHLS(workspace: failingWorkspace, duration: 120, fragmented: false,
                                   preferences: PreparationPreferences()) { index, _, _, directory in
            if index == 2 { throw PreparationFailure.failed }
            return try await failingProducer.produce(index, directory: directory)
        }
        defer { failing.stop() }
        var failures = 0
        failing.onFailure = { _ in failures += 1 }
        try await failing.warmUp()
        failing.updatePosition(0, playing: true)
        try await waitUntil("Speculative failure was not reported", { failures > 0 })
        try await Task.sleep(for: .milliseconds(150))
        try check(failures == 1 && failingProducer.started == [0, 1], "Failure restarted speculative production")
        let retained = try await failing.resource("segment000000.ts")
        failing.release(retained)
        failing.stop(); await failing.waitForJobs()
        report("PASS producer failure is reported once and stops look-ahead without removing retained delivery")
    }

    static func report(_ message: String) {
        print("[\(started.duration(to: ContinuousClock().now))] \(message)")
        fflush(nil)
    }

    /// Poll the callback rather than awaiting AVPlayer's async seek indefinitely.
    /// A late callback only updates this seek's state and cannot resume twice.
    static func seek(_ player: AVPlayer, to seconds: Double, label: String,
                     timeout: Duration = .seconds(30),
                     issueSeek: ((CMTime, @escaping @Sendable (Bool) -> Void) -> Void)? = nil) async throws {
        report("CHECK seek: \(label), target \(seconds)s")
        player.pause()
        let outcome = SeekOutcome()
        let completion: @Sendable (Bool) -> Void = { finished in
            Task { @MainActor in outcome.finished = finished }
        }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        if let issueSeek { issueSeek(target, completion) }
        else { player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: completion) }
        defer { if outcome.finished == nil { player.currentItem?.cancelPendingSeeks() } }
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while outcome.finished == nil, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let error = player.currentItem?.error as NSError?
        let diagnostic = "item status \(player.currentItem?.status.rawValue ?? -1), position \(player.currentTime().seconds), error \(error?.domain ?? "none")/\(error?.code ?? 0)"
        try check(outcome.finished != nil, "\(label) did not complete within \(timeout): \(diagnostic)")
        try check(outcome.finished == true, "\(label) was interrupted: \(diagnostic)")
        try check(abs(player.currentTime().seconds - seconds) < 0.2, "\(label) ended at the wrong position: \(diagnostic)")
    }

    static func seekTimeoutCheck() async throws {
        var lateCompletion: (@Sendable (Bool) -> Void)?
        let start = ContinuousClock().now
        do {
            try await seek(AVPlayer(), to: 108, label: "Unanswered seek fixture", timeout: .milliseconds(100),
                           issueSeek: { _, completion in lateCompletion = completion })
            try check(false, "An unanswered seek escaped its deadline")
        } catch let error as NSError {
            try check(error.domain == "CacheChecks" && error.localizedDescription.contains("did not complete within"),
                      "An unanswered seek lost its timeout diagnostic: \(error)")
        }
        lateCompletion?(true)
        await Task.yield()
        try check(start.duration(to: ContinuousClock().now) < .seconds(2), "Seek timeout waited for its callback")
        report("PASS unanswered seek times out and tolerates a late completion")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "CacheChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async {
        do { try await run() }
        catch { report("FAIL cache checks: \(error)"); exit(1) }
    }
    static func run() async throws {
        try await schedulingChecks()
        if CommandLine.arguments.contains("--scheduling-only") { return }
        if CommandLine.arguments.contains("--resume-only") {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            var environment = ProcessInfo.processInfo.environment
            environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
            environment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("cache-ffmpeg").path
            environment.removeValue(forKey: "AIRTHROW_PREPARATION_MODE")
            var source = ResolvedSource(url: directory.appendingPathComponent("cache-source.mpg"),
                                        needsPreparation: true, conversionPolicy: .allowVideo)
            source.preparationPosition = 40
            let prepared = try await MediaPreparer(environment: environment,
                preferences: PreparationPreferences(maximumBytes: 16 * 1024 * 1024)).prepare(source)
            defer { prepared.stop() }
            try check(prepared.usesBoundedCache
                      && prepared.readyRanges == [SeekRange(start: 0, end: 6), SeekRange(start: 36, end: 48)],
                      "Real preparation failed to warm the replacement's target before handoff")
            report("PASS real encoding warms bootstrap and six-second resume buffer before handoff")
            try await prepared.prepareSeek(at: 108)
            try check(prepared.readyRanges?.contains(SeekRange(start: 108, end: 114)) == true
                      && prepared.readyRanges?.contains(where: { $0.start > 48 && $0.start < 108 }) == false,
                      "Real seek preparation encoded intervening media instead of its target")
            report("PASS real seek encoding prepares its target without processing intervening media")
            return
        }
        if CommandLine.arguments.contains("--network-continuity-only") {
            try await networkContinuity(base: CommandLine.arguments[1],
                                        directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        try await seekTimeoutCheck()
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
        report("CHECK Initial cache preparation")
        let prepared = try await preparer.prepare(source)
        defer { prepared.stop() }
        try check(prepared.usesBoundedCache && prepared.sourceDuration! > 119 && !prepared.isProducing,
                  "Large input did not use idle finite cached preparation")
        try check(prepared.readyRanges == [SeekRange(start: 0, end: 6)], "Prepared media advertised its whole VOD as ready")
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
        report("CHECK Cached manifest, HEAD and byte ranges")
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
        report("CHECK Demand generation for a distant chunk")
        prepared.updatePlaybackPosition(60)
        let far = try await fetch("segment000010.ts")
        try check(far.1.statusCode == 200 && far.0.count > 1000
                  && (try chunks()) == ["chunk0", "chunk10"], "Distant seek: HTTP \(far.1.statusCode), chunks \(try chunks())")
        report("CHECK Concurrent requests for one chunk")
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
        report("CHECK Cache eviction and regeneration")
        let future = try await fetch("segment000019.ts")
        try check(future.1.statusCode == 200, "Future surplus fixture did not prepare")
        prepared.updatePlaybackPosition(90)
        try await Task.sleep(for: .seconds(16))
        prepared.updatePlaybackPosition(90)
        try check(try chunks() == ["chunk15", "chunk19"], "Played chunks were not evicted or future surplus was discarded")
        let regenerated = try await fetch("segment000000.ts")
        try check(regenerated.1.statusCode == 200 && regenerated.0.count > 1000,
                  "Evicted chunk could not be regenerated")
        try check(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count == 5,
                  "Backward seek did not regenerate exactly one chunk")
        for name in ["segment999999.ts", "segment000000.m4s", "init000000.mp4", "segment000000.ts.tmp", "chunk0/part.m3u8", "lease"] {
            let (_, denied) = try await fetch(name)
            try check(denied.statusCode == 404, "Private/invalid cached route was served: \(name)")
        }
        report("PASS large input beyond budget, finite VOD, demand-only generation, concurrent requests, eviction and regeneration")

        // AVPlayer must keep the full finite timeline and seek beyond the cache.
        report("CHECK Native VOD readiness")
        let player = AVPlayer()
        let item = AVPlayerItem(url: prepared.url)
        player.replaceCurrentItem(with: item)
        var deadline = Date().addingTimeInterval(30)
        while item.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(item.status == .readyToPlay && abs(item.duration.seconds - prepared.sourceDuration!) < 0.2,
                  "Native player did not expose the finite VOD duration: \(String(describing: item.error))")
        try await seek(player, to: 108, label: "Native distant seek")
        // Exercise discontinuity playback with a real local player; no mock route.
        try await seek(player, to: 4, label: "Native chunk-boundary rewind")
        report("CHECK Native playback across chunk boundaries")
        player.play()
        deadline = Date().addingTimeInterval(20)
        while player.currentTime().seconds < 13, item.status != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(item.status == .readyToPlay && player.currentTime().seconds >= 13,
                  "Native playback stalled at an independently encoded chunk boundary: \(String(describing: item.error))")
        try await seek(player, to: 118, label: "Native final-chunk seek")
        report("CHECK Native playback through the final chunk")
        player.play()
        deadline = Date().addingTimeInterval(15)
        while player.currentTime().seconds < 119.8, item.status != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(item.status == .readyToPlay && player.currentTime().seconds >= 119.8,
                  "The final fractional-duration chunk did not play")
        player.pause(); player.replaceCurrentItem(with: nil)
        prepared.cancelProduction()
        report("CHECK Prepared delivery after handoff cancellation")
        let retainedResponse = try await fetch("segment000019.ts")
        try check(retainedResponse.1.statusCode == 200, "Handoff cancellation disabled already-prepared delivery")
        prepared.stop(); await prepared.waitForProducer()
        try await Task.sleep(for: .milliseconds(100))
        try check(!FileManager.default.fileExists(atPath: workspace.path), "Stop retained the cache workspace")
        report("PASS local AVPlayer finite duration, distant seek and playback across chunk boundaries")

        for enhancement in [VideoEnhancement.upscale1080, .cleanup1080, .upscale4K, .cleanup4K] {
            report("CHECK Cached enhancement preparation: \(enhancement.rawValue)")
            let short = ResolvedSource(url: URL(string: base + "/combined.mp4")!, needsPreparation: true).withConversionPolicy(.allowVideo).withEnhancement(enhancement)
            let enhanced = try await MediaPreparer(environment: environment).prepare(short)
            try check(enhanced.usesBoundedCache && enhanced.videoHeight == enhancement.targetHeight,
                      "Cached \(enhancement.rawValue) output quality is incorrect")
            report("CHECK Cached enhancement native readiness: \(enhancement.rawValue)")
            let native = AVPlayerItem(url: enhanced.url)
            player.replaceCurrentItem(with: native)
            deadline = Date().addingTimeInterval(30)
            while native.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            try check(native.status == .readyToPlay && abs(native.duration.seconds - 2) < 0.2,
                      "Cached \(enhancement.rawValue) is not natively playable: \(String(describing: native.error))")
            player.replaceCurrentItem(with: nil)
            report("CHECK Cached enhancement shutdown: \(enhancement.rawValue)")
            enhanced.stop(); await enhanced.waitForProducer()
        }
        report("PASS all four cached enhancement presets and native H.264/HEVC readiness")

        report("CHECK Sequential fallback without byte ranges")
        let noRange = ResolvedSource(url: URL(string: base + "/no-range-vp9.mkv")!, needsPreparation: true, conversionPolicy: .allowVideo)
        let sequential = try await MediaPreparer(environment: environment).prepare(noRange)
        try check(!sequential.usesBoundedCache, "A server without byte ranges entered restartable preparation")
        sequential.stop(); await sequential.waitForProducer()
        report("CHECK Sequential fallback for HLS input")
        let hlsSource = ResolvedSource(url: URL(string: base + "/native-stream")!, needsPreparation: true).withConversionPolicy(.allowVideo).withEnhancement(.upscale1080)
        let hls = try await MediaPreparer(environment: environment).prepare(hlsSource)
        try check(!hls.usesBoundedCache, "An HLS input entered file-based restartable preparation")
        hls.stop(); await hls.waitForProducer()
        report("PASS sequential fallback for sources without random access and HLS inputs")

        report("CHECK Multi-chunk HEVC preparation")
        let longHEVC = ResolvedSource(url: URL(string: base + "/long.mp4")!, needsPreparation: true).withConversionPolicy(.allowVideo).withEnhancement(.upscale4K)
        let hevc = try await MediaPreparer(environment: environment).prepare(longHEVC)
        report("CHECK Multi-chunk HEVC native readiness")
        let hevcItem = AVPlayerItem(url: hevc.url)
        player.replaceCurrentItem(with: hevcItem)
        deadline = Date().addingTimeInterval(30)
        while hevcItem.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(hevcItem.status == .readyToPlay, "Multi-chunk HEVC did not open")
        try await seek(player, to: 4, label: "HEVC chunk-boundary rewind")
        report("CHECK HEVC playback across fragment boundaries")
        player.play()
        deadline = Date().addingTimeInterval(20)
        while player.currentTime().seconds < 9, hevcItem.status != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try check(hevcItem.status == .readyToPlay && player.currentTime().seconds >= 9,
                  "HEVC stalled at a fragment initialization/discontinuity boundary: \(String(describing: hevcItem.error))")
        try await seek(player, to: 18, label: "HEVC distant seek")
        player.pause(); player.replaceCurrentItem(with: nil)
        report("CHECK HEVC shutdown")
        hevc.stop(); await hevc.waitForProducer()
        report("PASS local HEVC playback across initialization/discontinuity boundaries and distant seek")

        var pacedEnvironment = environment
        pacedEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("paced-ffmpeg").path
        report("CHECK Requested-chunk cancellation preparation")
        let cancellable = try await MediaPreparer(environment: pacedEnvironment).prepare(source)
        let cancelledURL = cancellable.url.deletingLastPathComponent().appendingPathComponent("segment000010.ts")
        let waiting = Task { try await session.data(from: cancelledURL) }
        try await Task.sleep(for: .milliseconds(300))
        let stoppedAt = Date()
        report("CHECK Stop during requested-chunk encoding")
        cancellable.stop(); await cancellable.waitForProducer()
        try check(Date().timeIntervalSince(stoppedAt) < 2, "Stop waited for a requested chunk to finish encoding")
        _ = try? await waiting.value
        try check(cancellable.productionFailure == nil, "Requested-chunk cancellation became a playback error")
        report("PASS Stop cancels an in-flight requested chunk without a terminal failure")

        report("CHECK Shared controller paused readiness")
        let holder = PreparedHolder()
        let controller = PlaybackController(resolveSource: { _ in source }, allowVideoConversion: true,
                                            prepareSource: {
                                                let media = try await preparer.prepare($0)
                                                await holder.store(media)
                                                return media
                                            })
        try controller.load("https://example.com/cache-fixture")
        deadline = Date().addingTimeInterval(30)
        while controller.snapshot.state == .loading, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(controller.snapshot.state == .awaitingReceiver && !controller.snapshot.isLive
                  && controller.snapshot.duration! > 119 && controller.player.rate == 0
                  && controller.player.isMuted && (controller.snapshot.seekableRanges.last?.end ?? 0) > 119,
                  "Shared controller cached state: \(String(decoding: try JSONEncoder().encode(controller.snapshot), as: UTF8.self))")
        guard let controllerMedia = holder.value else { throw PreparationFailure.failed }
        let distantURL = controllerMedia.url.deletingLastPathComponent().appendingPathComponent("segment000019.ts")
        _ = try await session.data(from: distantURL)
        try await waitUntil("Paused controller did not publish ready progress", {
            controller.snapshot.preparedRanges?.contains(where: { $0.start <= 114 && $0.end > 119 }) == true
        })
        try check(controller.player.rate == 0, "Progress updates started paused playback")
        report("CHECK Shared controller shutdown")
        await controller.shutdownAndWait()
        try check(controller.snapshot.preparedRanges == nil, "Shutdown left stale ready ranges")
        report("PASS shared controller keeps cached media paused with a full finite seek range")

        report("CHECK Cache-budget rejection")
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
        report("PASS configurable preparation preferences and distinct storage-limit failure")
        try await Task.sleep(for: .milliseconds(100))
        try check(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == before,
                  "Cached shutdown or startup failure retained a workspace")
    }

    static func lateResourceRelease(directory: URL, session: URLSession) async throws {
        let manifest = directory.appendingPathComponent("late-release.m3u8")
        try Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8).write(to: manifest)
        defer { try? FileManager.default.removeItem(at: manifest) }
        report("CHECK Release a resource completed after server Stop")
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
        report("PASS Stop releases a resource completed after cancellation exactly once")
    }

    static func networkContinuity(base: String, directory: URL) async throws {
        let input = directory.appendingPathComponent("cache-network.mp4")
        let size = (try FileManager.default.attributesOfItem(atPath: input.path)[.size] as! NSNumber).int64Value
        try check(size > 500 * 1024 * 1024, "Network fixture is smaller than 500 MiB")
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        environment.removeValue(forKey: "AIRTHROW_PREPARATION_MODE")
        let source = ResolvedSource(url: URL(string: base + "/cache-network.mp4")!, needsPreparation: true)
            .withConversionPolicy(.allowVideo).withEnhancement(.cleanup1080)
        report("CHECK Clean up and upscale delayed 600 MiB remote input")
        let prepared = try await MediaPreparer(environment: environment).prepare(source)
        defer { prepared.stop() }
        try check(prepared.usesBoundedCache, "Delayed remote enhancement did not use bounded preparation")
        let player = AVPlayer()
        let item = AVPlayerItem(url: prepared.url)
        player.isMuted = true
        player.replaceCurrentItem(with: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try await waitUntil("Remote cached item did not become ready", { item.status != .unknown })
        try check(item.status == .readyToPlay, "Remote cached item failed: \(String(describing: item.error))")
        prepared.updatePlaybackPosition(0, playing: true)
        player.play()
        let clock = ContinuousClock()
        let playbackStart = clock.now
        let deadline = playbackStart.advanced(by: .seconds(55))
        var began: ContinuousClock.Instant?
        var lostTime = 0.0
        while player.currentTime().seconds < 40, item.status != .failed, clock.now < deadline {
            let position = player.currentTime().seconds
            prepared.updatePlaybackPosition(position, playing: true)
            if position > 0.1, began == nil { began = clock.now }
            if let began {
                let elapsed = began.duration(to: clock.now).components
                lostTime = max(lostTime, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18 - position)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let position = player.currentTime().seconds
        player.pause(); player.replaceCurrentItem(with: nil)
        prepared.stop(); await prepared.waitForProducer()
        try check(item.status != .failed && position >= 40 && prepared.productionFailure == nil,
                  "Remote enhancement stalled before 40s: position \(position), error \(String(describing: item.error))")
        try check(lostTime < 2, "Remote enhancement lost \(lostTime)s to buffering after playback began")
        let (metrics, _) = try await URLSession.shared.data(from: URL(string: base + "/cache-network-metrics")!)
        let stats = try JSONDecoder().decode([String: Int].self, from: metrics)
        try check(stats["bytes", default: 0] < 200 * 1024 * 1024, "Preparation downloaded the sparse source instead of seeking")
        report("PASS delayed remote cleanup playback beyond 30s: position \(position)s, maximum lost time \(lostTime)s, HTTP \(stats)")
    }
}
