import Foundation
import AVFoundation

@main
@MainActor
struct RemuxCacheChecks {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "RemuxCacheChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async {
        do { try await run() }
        catch { print("FAIL remux cache: \(error)"); exit(1) }
    }
    static func run() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        environment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("copy-only-ffmpeg").path
        environment.removeValue(forKey: "AIRTHROW_PREPARATION_MODE")
        let preferences = PreparationPreferences(maximumBytes: 512 * 1024, windowSeconds: 12, remuxCache: true)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let defaults = UserDefaults(suiteName: "AirThrow.RemuxChecks.\(UUID().uuidString)")!
        try check(!PreparationPreferences.current(defaults).remuxCache, "Experimental remux was enabled by default")
        defaults.set(true, forKey: PreparationPreferences.remuxCacheKey)
        try check(PreparationPreferences.current(defaults).remuxCache, "Remux preference did not persist")
        defaults.removeObject(forKey: PreparationPreferences.remuxCacheKey)
        let base = CommandLine.arguments.count > 2 && CommandLine.arguments[2].hasPrefix("http") ? URL(string: CommandLine.arguments[2]) : nil
        var cases = ["remux-h264.mkv", "remux-hevc.mkv", "remux-variable.mp4"]
        if CommandLine.arguments.contains("--remote-only") { cases = [] }
        if base != nil { cases += ["remote-remux-h264.mkv", "remote-remux-hevc.mkv", "remote-remux-variable.mp4", "remote-remux-tail.mp4", "remote-remux-video.mp4", "remote-remux-large.mp4", "remote-remux-offset-video.mp4"] }
        if CommandLine.arguments.contains("--fallback-only") { cases = [] }
        for name in cases {
            let remote = name.hasPrefix("remote-")
            let sourceName = remote ? String(name.dropFirst(7)) : name
            let file = directory.appendingPathComponent(sourceName)
            let headers = ["User-Agent": "AirThrow-RemuxChecks"]
            let input = remote ? base!.appendingPathComponent(sourceName).appending(queryItems: [URLQueryItem(name: "token", value: "signed-fixture")]) : file
            let audioName = sourceName == "remux-offset-video.mp4" ? "remux-offset-audio.m4a" : "remux-audio.m4a"
            let audio = ["remux-video.mp4", "remux-offset-video.mp4"].contains(sourceName)
                ? MediaTrack(url: base!.appendingPathComponent(audioName), headers: headers) : nil
            print("Checking \(name)")
            try check((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).int64Value > preferences.maximumBytes,
                      "Fixture must exceed the cache budget")
            let media = try await MediaPreparer(environment: environment, preferences: preferences)
                .prepare(ResolvedSource(url: input, headers: remote ? headers : [:], audio: audio, needsPreparation: true))
            defer { media.stop() }
            if sourceName == "remux-large.mp4" {
                let (metrics, _) = try await session.data(from: base!.appendingPathComponent("_metrics"))
                let data = try JSONSerialization.jsonObject(with: metrics) as! [String: [String: Any]]
                let sent = (data[sourceName]?["sent"] as? NSNumber)?.intValue ?? Int.max
                try check(sent < 16 * 1024 * 1024, "Remote startup downloaded the whole large source: \(sent) bytes")
                print("PASS remote startup reads indexes and requested video only: \(sent) bytes for a >128 MB source")
            }
            try check(media.usesBoundedCache && media.playbackPath == .remux && !media.isProducing,
                      "Compatible remux did not use idle copy cache: \(name)")
            let root = media.url.deletingLastPathComponent()
            let (manifestData, _) = try await session.data(from: media.url)
            let manifest = String(decoding: manifestData, as: UTF8.self)
            try check(manifest.contains("#EXT-X-ENDLIST"), "Remux timeline was live")
            let segments = manifest.split(separator: "\n").filter { $0.hasPrefix("segment") }.map(String.init)
            try check(segments.count >= 3, "Fixture did not exercise multiple copy intervals")
            let output = directory.appendingPathComponent(name + "-cached", isDirectory: true)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Request a distant interval first, then every interval out of order.
            // Store joined fragments for independent packet-hash verification.
            for index in ([segments.count - 1] + Array(0..<segments.count - 1)) {
                media.updatePlaybackPosition(Double(index) * 6)
                let initialization = String(format: "init%06d.mp4", index)
                let (initData, ir) = try await session.data(from: root.appendingPathComponent(initialization))
                let (segment, sr) = try await session.data(from: root.appendingPathComponent(segments[index]))
                try check((ir as! HTTPURLResponse).statusCode == 200 && (sr as! HTTPURLResponse).statusCode == 200,
                          "Remux requested interval failed: \(name) / \(index)")
                try (initData + segment).write(to: output.appendingPathComponent("\(index).mp4"))
            }
            if name == "remux-h264.mkv" || name == "remote-remux-h264.mkv" {
                let (first, _) = try await session.data(from: root.appendingPathComponent(segments[0]))
                media.updatePlaybackPosition(media.sourceDuration! - 1)
                try await Task.sleep(for: .seconds(16))
                media.updatePlaybackPosition(media.sourceDuration! - 1)
                let (regenerated, response) = try await session.data(from: root.appendingPathComponent(segments[0]))
                try check((response as! HTTPURLResponse).statusCode == 200 && regenerated == first,
                          "Eviction changed remux payload on regeneration")
            }
            let player = AVPlayer(url: media.url)
            let item = player.currentItem!
            var deadline = Date().addingTimeInterval(20)
            while item.status == .unknown, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            try check(item.status == .readyToPlay && abs(item.duration.seconds - media.sourceDuration!) < 0.2,
                      "Native remux duration/readiness: \(String(describing: item.error))")
            let moved = await player.seek(to: CMTime(seconds: 15, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try check(moved && abs(player.currentTime().seconds - 15) < 0.2, "Native remux distant seek failed")
            _ = await player.seek(to: CMTime(seconds: 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            deadline = Date().addingTimeInterval(20)
            while player.currentTime().seconds < 10, item.status != .failed, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(item.status == .readyToPlay && player.currentTime().seconds >= 10,
                      "Native remux boundary playback stalled: \(String(describing: item.error))")
            player.pause(); player.replaceCurrentItem(with: nil)
            media.stop(); await media.waitForProducer()
            print("PASS \(name): copy-only cache beyond input budget, demand seek, eviction/regeneration, native playback")
        }
        if let base {
            let headers = ["User-Agent": "AirThrow-RemuxChecks"]
            for prefix in ["no-range-", "bad-range-"] {
                let media = try await MediaPreparer(environment: environment,
                    preferences: PreparationPreferences(maximumBytes: 16 * 1024 * 1024, remuxCache: true))
                    .prepare(ResolvedSource(url: base.appendingPathComponent(prefix + "remux-variable.mp4"), headers: headers, needsPreparation: true))
                try check(!media.usesBoundedCache && media.playbackPath == .remux, "Broken/absent ranges lost sequential fallback")
                media.stop(); await media.waitForProducer()
            }
            let task = Task { try await MediaPreparer(environment: environment, preferences: preferences)
                .prepare(ResolvedSource(url: base.appendingPathComponent("delay-index-remux-variable.mp4"), headers: headers, needsPreparation: true)) }
            let deadline = Date().addingTimeInterval(10)
            var waiting = false
            while !waiting, Date() < deadline {
                let (metrics, _) = try await session.data(from: base.appendingPathComponent("_metrics"))
                let data = try JSONSerialization.jsonObject(with: metrics) as! [String: [String: Any]]
                waiting = data["delay-index-remux-variable.mp4"]?["waiting"] as? Bool ?? false
                if !waiting { try await Task.sleep(for: .milliseconds(50)) }
            }
            try check(waiting, "Remote cancellation fixture did not start indexing")
            let stopped = Date(); task.cancel()
            do { _ = try await task.value; try check(false, "Cancelled remote index started playback") }
            catch is CancellationError { }
            try check(Date().timeIntervalSince(stopped) < 2, "Remote index did not cancel its HTTP request promptly")
            print("PASS remote byte-range fallback and index cancellation")
        }
        print("Checking remote fallback")
        let fileServer = try await MediaHTTPServer.start(file: directory.appendingPathComponent("remux-h264.mkv"), host: "127.0.0.1")
        let remote = try await MediaPreparer(environment: environment,
            preferences: PreparationPreferences(maximumBytes: 16 * 1024 * 1024, remuxCache: true))
            .prepare(ResolvedSource(url: fileServer.url!, needsPreparation: true))
        try check(remote.usesBoundedCache && remote.playbackPath == .remux, "Remote remux did not use indexed preparation")
        remote.stop(); await remote.waitForProducer(); fileServer.stop()
        // A compatible direct file still bypasses all preparation/cache work.
        let direct = try await MediaPreparer(environment: environment, preferences: preferences)
            .prepare(ResolvedSource(url: directory.appendingPathComponent("remux-variable.mp4")))
        try check(!direct.usesBoundedCache && direct.playbackPath == .direct, "Remux option changed direct delivery")
        direct.stop(); await direct.waitForProducer()
        for name in ["remux-mp3.mkv", "remux-subtitles.mkv", "remux-open-gop.mkv"] {
            print("Checking fallback: \(name)")
            var fallbackEnvironment = environment
            if name == "remux-mp3.mkv" { fallbackEnvironment.removeValue(forKey: "AIRTHROW_FFMPEG") }
            let media = try await MediaPreparer(environment: fallbackEnvironment,
                preferences: PreparationPreferences(maximumBytes: 16 * 1024 * 1024, remuxCache: true))
                .prepare(ResolvedSource(url: directory.appendingPathComponent(name), needsPreparation: true))
            try check(!media.usesBoundedCache, "Unsupported copy layout did not preserve sequential preparation: \(name)")
            media.stop(); await media.waitForProducer()
        }
        print("PASS direct/remote, non-AAC, subtitle and non-IDR alternatives")

        // Defaults, explicit complete-file, keep-all, non-AAC, subtitles, remote
        // and non-IDR sources preserve the existing preparation path.
        let sequential = PreparationPreferences(maximumBytes: 16 * 1024 * 1024)
        let file = directory.appendingPathComponent("remux-h264.mkv")
        for (name, prefs, mode) in [
            ("off", sequential, nil as PreparationMode?),
            ("keep-all", PreparationPreferences(maximumBytes: sequential.maximumBytes, retainAll: true, remuxCache: true), nil),
            ("complete", PreparationPreferences(maximumBytes: sequential.maximumBytes, remuxCache: true), .completeFile)
        ] {
            let media = try await MediaPreparer(environment: environment, preferences: prefs)
                .prepare(ResolvedSource(url: file, needsPreparation: true), mode: mode)
            try check(!media.usesBoundedCache && media.playbackPath == .remux, "Remux fallback changed: \(name)")
            media.stop(); await media.waitForProducer()
        }
        let fallbackEnvironment = environment.merging(["AIRTHROW_FFPROBE": directory.appendingPathComponent("no-index-ffprobe").path]) { _, new in new }
        let fallback = try await MediaPreparer(environment: fallbackEnvironment,
            preferences: PreparationPreferences(maximumBytes: sequential.maximumBytes, remuxCache: true))
            .prepare(ResolvedSource(url: file, needsPreparation: true))
        try check(!fallback.usesBoundedCache, "Failed packet index did not fall back to sequential copy")
        fallback.stop(); await fallback.waitForProducer()
        var startupEnvironment = environment
        startupEnvironment["AIRTHROW_FFMPEG"] = directory.appendingPathComponent("no-chunk-ffmpeg").path
        let startupFallback = try await MediaPreparer(environment: startupEnvironment,
            preferences: PreparationPreferences(maximumBytes: sequential.maximumBytes, remuxCache: true))
            .prepare(ResolvedSource(url: file, needsPreparation: true))
        try check(!startupFallback.usesBoundedCache && startupFallback.playbackPath == .remux,
                  "Failed first copy chunk did not retain sequential delivery")
        startupFallback.stop(); await startupFallback.waitForProducer()
        do {
            _ = try await MediaPreparer(environment: environment,
                preferences: PreparationPreferences(maximumBytes: 1000, remuxCache: true))
                .prepare(ResolvedSource(url: file, needsPreparation: true))
            try check(false, "Remux chunk exceeded its output budget")
        } catch let failure as PreparationFailure {
            try check(failure == .storageLimit, "Remux quota lost its specific recovery")
        }
        // Index cancellation propagates immediately; it never starts a fallback producer.
        var cancelEnvironment = environment
        cancelEnvironment["AIRTHROW_FFPROBE"] = directory.appendingPathComponent("waiting-index-ffprobe").path
        let marker = directory.appendingPathComponent("index-started")
        try? FileManager.default.removeItem(at: marker)
        let task = Task { try await MediaPreparer(environment: cancelEnvironment, preferences: preferences)
            .prepare(ResolvedSource(url: file, needsPreparation: true)) }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(FileManager.default.fileExists(atPath: marker.path), "Index cancellation fixture did not start")
        let cancelledAt = Date(); task.cancel()
        do { _ = try await task.value; try check(false, "Cancelled index started playback") }
        catch is CancellationError { }
        try check(Date().timeIntervalSince(cancelledAt) < 2, "Remux indexing ignored cancellation")
        print("PASS off-by-default preference, keep-all/complete-file alternatives, index/first-chunk fallback, quota and cancellation")
    }
}
