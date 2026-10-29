import Foundation
import AVFoundation

@main struct RemoteIndexChecks {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw AppFailure(.playbackFailed, message) }
        print("PASS \(message)")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let base = URL(string: CommandLine.arguments[1])!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func metrics() async throws -> [String: Int] {
            let (data, _) = try await session.data(from: base.appendingPathComponent("metrics"))
            return try JSONSerialization.jsonObject(with: data) as! [String: Int]
        }
        let relay = try await HTTPMediaRelay.start(source: base.appendingPathComponent("episode.mkv"), host: "127.0.0.1")
        defer { relay.stop() }
        let cache = try await PreparationInputCache.open(url: relay.url!, headers: [:])
        _ = try await cache.read(offset: 0, maximum: 64 * 1024)
        // Speculative block loads are still in flight while index requests arrive.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let offset = Int64(4 * 1024 * 1024 + index * 4096)
                    let bytes = try await cache.read(offset: offset, maximum: 128, requestEnd: offset + 127)
                    guard bytes.count == 128 else { throw PreparationFailure.failed }
                }
            }
            try await group.waitForAll()
        }
        await cache.stop()
        relay.stop()
        print("PASS Metadata and prefetch share the nested relay connection budget")
        do {
            let outer = try await HTTPMediaRelay.start(source: base.appendingPathComponent("gated.bin"), host: "127.0.0.1")
            defer { outer.stop() }
            let inner = try await HTTPMediaRelay.start(source: outer.url!, host: "127.0.0.1", readAheadBytes: 8 * 1024 * 1024)
            defer { inner.stop() }
            var initial = URLRequest(url: inner.url!)
            initial.setValue("bytes=0-2097151", forHTTPHeaderField: "Range")
            _ = try await session.data(for: initial)
            // Both speculative blocks stay blocked until the actual metadata
            // range reaches the origin. It must use the reserved transfer slot.
            try await Task.sleep(for: .milliseconds(50))
            var metadata = URLRequest(url: inner.url!)
            metadata.setValue("bytes=20971520-21102591", forHTTPHeaderField: "Range")
            metadata.setValue("1", forHTTPHeaderField: "X-AirThrow-Metadata")
            let began = ContinuousClock.now
            let (data, response) = try await session.data(for: metadata)
            try check((response as? HTTPURLResponse)?.statusCode == 206 && data == Data(repeating: 90, count: 128 * 1024),
                      "Large indexed metadata preserves its exact bytes and range")
            try check(began.duration(to: .now) < .seconds(1.5),
                      "A 128 KiB metadata range overtakes stalled speculative media blocks")
        }
        func avc(_ recovery: [UInt8], slice: UInt8 = 0xb8) -> Data {
            let units: [[UInt8]] = [[0x06] + recovery, [0x61, slice]]
            return units.reduce(into: Data()) { data, nal in
                data.append(contentsOf: [0, 0, 0, UInt8(nal.count)] + nal)
            }
        }
        try check(RemuxTimeline.isRefreshPoint(avc([6, 1, 0xc4, 0x80]), codec: "h264"), "Immediate exact AVC intra recovery accepted")
        for payload: [UInt8] in [[6, 1, 0x54, 0x80], [6, 1, 0x84, 0x80], [6, 1, 0xe4, 0x80], [6, 9, 0xc4], [5, 1, 0xc4, 0x80]] {
            try check(!RemuxTimeline.isRefreshPoint(avc(payload), codec: "h264"), "Delayed, approximate, broken or malformed AVC recovery rejected")
        }
        try check(!RemuxTimeline.isRefreshPoint(avc([6, 1, 0xc4, 0x80], slice: 0xc0), codec: "h264"), "Recovery SEI without intra slice rejected")
        let mixed = try await RemoteRemuxIndex.timeline(url: base.appendingPathComponent("mixed.mkv"), headers: [:],
            stream: 0, codec: "h264", videoTimeBase: "1/1000", audioTimeBase: "1/1000",
            sourceStart: 0, duration: 36, matroska: true, reorderDelay: true)
        try check(mixed.cuts.count == 6 && mixed.starts.last! >= 30,
                  "Valid mixed closed/open GOP video retains exact recovery points")
        for index in mixed.cuts.indices { try await mixed.remoteValidation?.validate(index: index) }
        print("PASS every published mixed-GOP interval remains valid")
        for name in ["episode.mkv", "bad-frame.mkv"] {
            let upstream = PreparationUpstream()
            defer { upstream.stop() }
            let source = try await upstream.localized(ResolvedSource(url: base.appendingPathComponent(name), needsPreparation: true))
            let before = try await metrics()
            let began = ContinuousClock.now
            let timeline = try await RemoteRemuxIndex.timeline(url: source.url, headers: [:],
                stream: 0, codec: "h264", videoTimeBase: "1/1000", audioTimeBase: "1/1000",
                sourceStart: 0, duration: 2400, matroska: true, reorderDelay: false)
            let elapsed = began.duration(to: .now).timeInterval
            let after = try await metrics()
            try check(timeline.cuts.count == 400, "Full 40-minute seek timeline is available at startup")
            try check(after["bytes"]! - before["bytes"]! < 1024 * 1024,
                      "Startup reads less than 1 MiB of the long source")
            try check(after["requests"]! - before["requests"]! < 40 && elapsed < 5,
                      "Startup is bounded despite remote latency: \(after["requests"]! - before["requests"]!) ranges in \(elapsed)s")
            guard let validation = timeline.remoteValidation else { throw PreparationFailure.failed }
            let initial = try await metrics()
            try await validation.validate(index: 0)
            let unchanged = try await metrics()
            try check(initial == unchanged, "Already verified startup cuts need no extra reads")
            do {
                try await validation.validate(index: 300)
                try check(name == "episode.mkv", "Valid distant cut is checked on demand")
            } catch RemuxIndexFailure.restartPoint {
                try check(name == "bad-frame.mkv", "Unsignalled non-IDR cut remains rejected")
            }
            let distant = try await metrics()
            try check(distant["requests"]! - unchanged["requests"]! < 20,
                      "Distant seek reads only its own boundary headers")
            if name == "episode.mkv" {
                try await validation.validate(index: 300)
                let repeated = try await metrics()
                try check(repeated == distant, "Validated distant cuts are reused on regeneration")
            }
            let cancelled = Task {
                try await Task.sleep(for: .milliseconds(30))
                try await validation.validate(index: 250)
            }
            cancelled.cancel()
            do { try await cancelled.value; try check(false, "Cancellation must propagate") }
            catch is CancellationError { print("PASS Index validation cancellation") }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        let began = ContinuousClock.now
        let media = try await MediaPreparer(environment: environment,
            preferences: PreparationPreferences(maximumBytes: 2 * 1024 * 1024, remuxCache: true))
            .prepare(ResolvedSource(url: base.appendingPathComponent("episode-av.mkv"), needsPreparation: true))
        defer { media.stop() }
        let preparedSeconds = began.duration(to: .now).timeInterval
        try check(media.usesBoundedCache && abs((media.sourceDuration ?? 0) - 2400) < 0.2,
                  "Full 40-minute source uses bounded on-demand remux")
        let player = AVPlayer(url: media.url)
        player.isMuted = true; player.allowsExternalPlayback = false
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        player.play()
        let deadline = Date().addingTimeInterval(12)
        while player.currentTime().seconds < 0.25, player.currentItem?.status != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let playingSeconds = began.duration(to: .now).timeInterval
        try check(player.currentItem?.status == .readyToPlay && player.currentTime().seconds >= 0.25,
                  "Cold native playback of the 40-minute source advances")
        try check(preparedSeconds < 8 && playingSeconds < 12,
                  "Long-source cold startup: prepared=\(preparedSeconds)s, native-playing=\(playingSeconds)s")
        player.pause()
        let seekBegan = ContinuousClock.now
        try await media.prepareSeek(at: 1800)
        let preparedSeekSeconds = seekBegan.duration(to: .now).timeInterval
        let sought = await player.seek(to: CMTime(seconds: 1800, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        let seekDeadline = Date().addingTimeInterval(12)
        while player.currentTime().seconds < 1800.25, player.currentItem?.status != .failed, Date() < seekDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let seekSeconds = seekBegan.duration(to: .now).timeInterval
        try check(sought && player.currentItem?.status == .readyToPlay && player.currentTime().seconds >= 1800.25 && seekSeconds < 12,
                  "Cold seek to minute 30: prepared=\(preparedSeekSeconds)s, native-playing=\(seekSeconds)s")
        player.pause(); player.replaceCurrentItem(with: nil)
        media.stop(); await media.waitForProducer()
    }
}
