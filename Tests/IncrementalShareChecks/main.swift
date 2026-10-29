import Foundation
import AVFoundation

@main struct IncrementalShareChecks {
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: "IncrementalShareChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS \(message)")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let base = URL(string: CommandLine.arguments[1])!
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        var environment = ProcessInfo.processInfo.environment
        environment["AIRTHROW_MEDIA_HOST"] = "127.0.0.1"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func fetch(_ url: URL) async throws -> Data {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PreparationFailure.failed }
            return data
        }
        let fileIndex = try await RemoteRemuxIndex.timeline(url: output.appendingPathComponent("aac.mkv"), headers: [:],
            stream: 0, codec: "h264", videoTimeBase: "1/1000", audioTimeBase: "1/1000", sourceStart: 0,
            duration: 30, matroska: true, reorderDelay: true)
        try check(fileIndex.usesSyncPacketIntervals && fileIndex.starts.count >= 4, "Mounted-file reader uses container Cues without a full packet scan")
        try check(fileIndex.cuts.first?.followingKeyframe == fileIndex.cuts.first.map { $0.pts + 2000 },
                  "Subtitle cue times cannot replace the next video keyframe")
        try check(fileIndex.cuts[1].precedingKeyframe == fileIndex.cuts[1].pts - 2000,
                  "Reordered seek preroll retains the preceding video Cue, not a subtitle or the previous chunk")
        let unvalidated = try await PreparationInputCache.open(url: base.appendingPathComponent("mutable.bin"), headers: [:])
        let firstScope = UUID(), nextScope = UUID()
        let original = try await unvalidated.read(offset: 0, maximum: 16, scope: firstScope)
        _ = try await fetch(base.appendingPathComponent("_advance"))
        let fresh = try await unvalidated.read(offset: 0, maximum: 16, scope: nextScope)
        let sameResponse = try await unvalidated.read(offset: 0, maximum: 16, scope: firstScope)
        try check(original == Data(repeating: 65, count: 16) && fresh == Data(repeating: 66, count: 16)
                  && sameResponse == original, "Without validators, cached bytes never leak into a later HTTP response")
        let tailScope = UUID()
        let tailBefore = try JSONSerialization.jsonObject(with: await fetch(base.appendingPathComponent("_metrics"))) as! [String: Int]
        for offset in [unvalidated.size - 128 * 1024, unvalidated.size - 64 * 1024] {
            _ = try await unvalidated.read(offset: offset, maximum: 64 * 1024, scope: tailScope,
                                          requestEnd: unvalidated.size - 1, requestStart: 0)
        }
        let tailAfter = try JSONSerialization.jsonObject(with: await fetch(base.appendingPathComponent("_metrics"))) as! [String: Int]
        try check(tailAfter["mutable_reads"]! - tailBefore["mutable_reads"]! == 1,
                  "A media response tail uses one block fetch, not a request per 64 KiB")
        await unvalidated.release(scope: tailScope)
        await unvalidated.release(scope: firstScope); await unvalidated.release(scope: nextScope); await unvalidated.stop()
        let cases = CommandLine.arguments.contains("--surround-only") ? ["hevc-eac3", "hevc-legacy", "hevc4k-eac3"] : CommandLine.arguments.contains("--avc-only") ? ["avc-mixed"] : CommandLine.arguments.contains("--hevc-only") ? ["hevc-cra", "hevc-cra10", "hevc-legacy"]
            : ["large", "aac", "mp3", "flac", "ac3", "dts", "truehd", "ass", "legacy", "eac3", "hevc-cra", "hevc-cra10", "avc-mixed", "hevc-eac3", "hevc-legacy"]
        for codec in cases {
            print("CHECK \(codec)")
            let provider = WebDAVShareProvider(root: base, username: "fixture", password: "fixture")
            let source = try await provider.playbackURL(codec + ".mkv")
            let relay = try await HTTPMediaRelay.start(source: source, credentials: provider.playbackCredentials(codec + ".mkv"))
            defer { relay.stop() }
            let before = try JSONSerialization.jsonObject(with: await fetch(base.appendingPathComponent("_metrics"))) as! [String: Int]
            let preferences = PreparationPreferences(maximumBytes: (codec == "hevc4k-eac3" ? 128 : 2) * 1024 * 1024, windowSeconds: 12, remuxCache: true)
            let began = ContinuousClock.now
            let trace = PreparationDiagnosticRecorder()
            let media: PreparedMedia
            do {
                media = try await PreparationTrace.$current.withValue(trace) {
                    try await MediaPreparer(environment: environment, preferences: preferences)
                        .prepare(ResolvedSource(url: relay.url!, needsPreparation: true))
                }
            } catch {
                print("SAFE preparation diagnostic: " + String(decoding: try JSONEncoder().encode(trace.snapshot), as: UTF8.self))
                throw error
            }
            defer { media.stop() }
            if ["hevc-eac3", "hevc-legacy", "hevc4k-eac3"].contains(codec) {
                let layout = trace.snapshot
                try check(layout.fragmentTracks?.count == 2 && layout.fragmentTracks?.allSatisfy({ $0.samples > 0 }) == true
                          && layout.inspectionBytes == (layout.initializationBytes ?? 0) + (layout.segmentBytes ?? 0),
                          "Numeric fragment diagnostics match the generated video/audio tables and joined size")
            }
            let preparedSeconds = began.duration(to: .now).timeInterval
            print("TIMING \(codec): preparation=\(preparedSeconds)s")
            if codec == "avc-mixed" {
                // Measure native startup before pre-reading any distant chunks.
                let item = AVPlayerItem(url: media.url)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true; player.allowsExternalPlayback = false
                defer { player.pause(); player.replaceCurrentItem(with: nil) }
                player.play()
                let startupDeadline = Date().addingTimeInterval(12)
                while player.currentTime().seconds < 0.25, item.status != .failed, Date() < startupDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                let playingSeconds = began.duration(to: .now).timeInterval
                try check(item.status == .readyToPlay && player.currentTime().seconds >= 0.25,
                          "Cold native AVC playback advances before distant chunks are requested")
                try check(preparedSeconds < 8 && playingSeconds < 12,
                          "Cold startup budget: prepared=\(preparedSeconds)s, native-playing=\(playingSeconds)s")
                player.pause()
                let seekBegan = ContinuousClock.now
                try await media.prepareSeek(at: 32)
                let sought = await player.seek(to: CMTime(seconds: 32, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                let seekDeadline = Date().addingTimeInterval(12)
                while player.currentTime().seconds < 32.25, item.status != .failed, Date() < seekDeadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                let seekSeconds = seekBegan.duration(to: .now).timeInterval
                try check(sought && item.status == .readyToPlay && player.currentTime().seconds >= 32.25 && seekSeconds < 12,
                          "Cold distant seek through AVC recovery: \(seekSeconds)s")
                player.pause(); player.replaceCurrentItem(with: nil)
                let timings: [String: Double] = ["prepared_seconds": preparedSeconds, "native_playing_seconds": playingSeconds, "cold_seek_seconds": seekSeconds]
                try JSONEncoder().encode(timings).write(to: output.appendingPathComponent("avc-performance.json"))
            }
            if codec == "large" {
                let after = try JSONSerialization.jsonObject(with: await fetch(base.appendingPathComponent("_metrics"))) as! [String: Int]
                let read = after["sent"]! - before["sent"]!
                try check(read < 16 * 1024 * 1024, "130 MiB source starts after reading only \(read) bytes")
            }
            try check(media.usesBoundedCache, "\(codec): bounded cache despite embedded subtitles")
            let root = media.url.deletingLastPathComponent()
            let manifest = String(decoding: try await fetch(media.url), as: UTF8.self)
            try check(manifest.contains("TYPE=SUBTITLES") && manifest.contains("subtitle1.m3u8"), "\(codec): two selectable subtitle renditions")
            if codec != "hevc4k-eac3" {
                let digits = manifest.components(separatedBy: "BANDWIDTH=").dropFirst().first?
                    .prefix(while: { $0.isNumber })
                let bandwidth = digits.flatMap { Int($0) } ?? 0
                try check(bandwidth > 0 && bandwidth < 5_000_000,
                          "\(codec): low-bitrate media advertises its measured rate instead of 50 Mbit/s")
            }
            let video = String(decoding: try await fetch(root.appendingPathComponent("stream_0.m3u8")), as: UTF8.self)
            let segments = video.split(separator: "\n").filter { $0.hasPrefix("segment") }.map(String.init)
            try check(segments.count >= 4, "\(codec): complete VOD timeline before full preparation")
            let directory = output.appendingPathComponent(codec)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Seek to the middle first: the long cue began in the first cluster.
            for index in [2, segments.count - 1] + Array(0..<segments.count).filter({ $0 != 2 && $0 != segments.count - 1 }) {
                let initialization = String(format: "init%06d.mp4", index)
                let head = try await fetch(root.appendingPathComponent(initialization))
                let body = try await fetch(root.appendingPathComponent(segments[index]))
                try (head + body).write(to: directory.appendingPathComponent("chunk\(index).mp4"))
                let subtitle = try await fetch(root.appendingPathComponent(String(format: "subtitle0-segment%06d.vtt", index)))
                let text = String(decoding: subtitle, as: UTF8.self)
                if index == 2 { try check(text.contains("Crossing cue"), "\(codec): distant seek retains a cue crossing three chunks") }
                try check(text.contains("X-TIMESTAMP-MAP"), "\(codec): subtitle timestamp mapping \(index)")
                if ["ac3", "eac3", "hevc-eac3", "hevc-legacy", "hevc4k-eac3"].contains(codec) {
                    let audioHead = try await fetch(root.appendingPathComponent("audio0-" + initialization))
                    let audioBody = try await fetch(root.appendingPathComponent("audio0-" + segments[index]))
                    try (audioHead + audioBody).write(to: directory.appendingPathComponent("audio\(index).mp4"))
                }
            }
            let asset = AVURLAsset(url: media.url)
            let subtitles = try await asset.loadMediaSelectionGroup(for: .legible)
            try check(subtitles?.options.count == (["hevc-eac3", "hevc-legacy", "hevc4k-eac3"].contains(codec) ? 8 : 2), "\(codec): AVFoundation exposes subtitle tracks: \(subtitles?.options.count ?? 0)")
            if ["ac3", "eac3", "hevc-eac3", "hevc-legacy", "hevc4k-eac3"].contains(codec) {
                let audio = try await asset.loadMediaSelectionGroup(for: .audible)
                try check((audio?.options.count ?? 0) >= 2, "\(codec): AVFoundation exposes original and AAC audio")
            }
            if ["aac", "eac3", "hevc-cra", "hevc-cra10", "avc-mixed", "hevc-eac3", "hevc-legacy", "hevc4k-eac3"].contains(codec) {
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true; player.allowsExternalPlayback = false
                defer { player.pause(); player.replaceCurrentItem(with: nil) }
                let deadline = Date().addingTimeInterval(20)
                while item.status == .unknown && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
                try check(item.status == .readyToPlay,
                          "Native AVPlayer prepares the Dolby/subtitle HLS master: status=\(item.status.rawValue), error=\((item.error as NSError?)?.code ?? 0), logCodes=\(item.errorLog()?.events.map(\.errorStatusCode) ?? [])")
                if let subtitles { item.select(subtitles.options[0], in: subtitles) }
                player.play()
                let playingDeadline = Date().addingTimeInterval(15)
                while player.currentTime().seconds < 0.5 && Date() < playingDeadline { try await Task.sleep(for: .milliseconds(100)) }
                try check(player.currentTime().seconds >= 0.5, "Native AVPlayer advances with a selected subtitle track")
                player.pause()
                try await media.prepareSeek(at: codec == "avc-mixed" ? 32 : 18)
                let sought = await player.seek(to: CMTime(seconds: codec == "avc-mixed" ? 32 : 18, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                try await Task.sleep(for: .milliseconds(500))
                try check(abs(item.duration.seconds - media.sourceDuration!) < 0.2, "Native HLS duration matches the source")
                print("Native seek sample: codec=\(codec) duration=\(item.duration.seconds) time=\(player.currentTime().seconds) seekable=\(item.seekableTimeRanges.map { $0.timeRangeValue.duration.seconds })")
                try check(sought && abs(player.currentTime().seconds - (codec == "avc-mixed" ? 32 : 18)) < 0.2, "Native AVPlayer seeks through the bounded cache: completed=\(sought), time=\(player.currentTime().seconds), failure=\(String(describing: media.productionFailure)), status=\(item.status.rawValue)")
                do {
                    _ = await player.seek(to: CMTime(seconds: codec == "avc-mixed" ? 22 : 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    player.play()
                    let boundaryDeadline = Date().addingTimeInterval(15)
                    while player.currentTime().seconds < (codec == "avc-mixed" ? 27 : 9), item.status != .failed, Date() < boundaryDeadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try check(item.status == .readyToPlay && player.currentTime().seconds >= (codec == "avc-mixed" ? 27 : 9),
                              "Native playback crosses a continuous segment boundary: time=\(player.currentTime().seconds), status=\(item.status.rawValue), control=\(player.timeControlStatus.rawValue), waiting=\(String(describing: player.reasonForWaitingToPlay)), cache=\(String(describing: media.productionFailure)), loaded=\(item.loadedTimeRanges.map { $0.timeRangeValue.duration.seconds })")
                    player.pause()
                }
                player.replaceCurrentItem(with: nil)
            }
            try check(media.playbackPath == (["large", "aac", "ass", "legacy", "hevc-cra", "hevc-cra10", "avc-mixed"].contains(codec) ? .remux : .audioConversion), "\(codec): video remains stream copied")
            media.stop()
            await media.waitForProducer()
            try await provider.disconnect()
        }
        let unindexed = WebDAVShareProvider(root: base, username: "fixture", password: "fixture")
        let url = try await unindexed.playbackURL("unindexed.mkv")
        let relay = try await HTTPMediaRelay.start(source: url, credentials: unindexed.playbackCredentials("unindexed.mkv"))
        defer { relay.stop() }
        do {
            let media = try await MediaPreparer(environment: environment, preferences: PreparationPreferences(maximumBytes: 2 * 1024 * 1024, remuxCache: true))
                .prepare(ResolvedSource(url: relay.url!, needsPreparation: true))
            media.stop()
            try check(false, "Missing subtitle index must not silently trigger full preparation")
        } catch let error as AppFailure {
            try check(error.message.contains("subtitle"), "Missing subtitle index has an explicit error rather than full preparation")
        }
    }
}
