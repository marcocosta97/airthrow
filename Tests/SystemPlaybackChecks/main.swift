import Foundation
import AVFoundation
import MediaPlayer

/// Exercise MediaPlayer's background request contract without mutating artwork.
private struct ArtworkRequest: @unchecked Sendable {
    let artwork: MPMediaItemArtwork
}

/// Reports a simulated route while native items supply tracks and seek ranges.
/// Transport never starts local audio or video playback.
private final class RemotePlayer: AVPlayer, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var position = 0.0
    nonisolated(unsafe) private var playing = false
    nonisolated(unsafe) private var routed = true
    var external: Bool {
        get { lock.withLock { routed } }
        set { lock.withLock { routed = newValue } }
    }
    override var isExternalPlaybackActive: Bool { external }
    override var rate: Float {
        get { lock.withLock { playing ? 1 : 0 } }
        set { lock.withLock { playing = newValue > 0 } }
    }
    override var timeControlStatus: AVPlayer.TimeControlStatus { rate > 0 ? .playing : .paused }
    override func currentTime() -> CMTime { CMTime(seconds: lock.withLock { position }, preferredTimescale: 600) }
    override func play() { rate = 1 }
    override func pause() { rate = 0 }
    override func preroll(atRate rate: Float, completionHandler: (@Sendable (Bool) -> Void)? = nil) { completionHandler?(true) }
    override func cancelPendingPrerolls() {}
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        lock.withLock { position = time.seconds }
        completionHandler?(true)
    }
}

/// A real decoder/clock for local HLS; only the route flag is simulated.
/// The controller cannot unmute this verification player.
private final class MutedLivePlayer: AVPlayer, @unchecked Sendable {
    override var isExternalPlaybackActive: Bool { true }
    override var isMuted: Bool {
        get { true }
        set { super.isMuted = true }
    }
    override func play() { super.isMuted = true; super.play() }
}

@main
struct SystemPlaybackChecks {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL system playback checks: \(error)"); exit(1) }
    }

    @MainActor static func run() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        func url(_ path: String) -> URL { base.appendingPathComponent(path) }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "SystemPlaybackChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ operation: String = "synthetic media operation", seconds: Double = 12,
                  _ predicate: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            try check(false, "Timed out waiting for \(operation)")
        }
        let defaults = UserDefaults(suiteName: "SystemPlaybackChecks-\(UUID().uuidString)")!
        let player = RemotePlayer()
        let controller = PlaybackController(player: player, showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0) }, historyStore: MediaHistoryStore(defaults: nil),
            xtreamCatalogDefaults: defaults, prepareSource: nil, integratesWithSystemPlayback: false)
        defer { controller.shutdown() }
        try controller.load(url("tracks.mp4").absoluteString)
        try await wait { controller.refresh(); return controller.snapshot.state == .ready && !controller.snapshot.seekableRanges.isEmpty }
        try controller.seek(2)
        try await wait { controller.refresh(); return controller.pendingSeek == nil }
        try check(controller.performRemoteSkip(interval: 3.5, forward: true) == .success, "Remote forward skip failed")
        try check(controller.performRemoteSkip(interval: 1.25, forward: false) == .success, "Rapid reverse skip failed")
        try await wait { controller.refresh(); return controller.pendingSeek == nil }
        try check(abs(player.currentTime().seconds - 4.25) < 0.01 && player.rate == 0,
                  "Remote skips ignored the event interval, pending target or pause intent")
        for interval in [Double.nan, .infinity, -.infinity, 0, -1, 100] {
            try check(controller.performRemoteSkip(interval: interval, forward: true) == .commandFailed,
                      "Invalid or unseekable remote interval was accepted")
        }
        try controller.play()
        try check(controller.performRemoteSkip(interval: 0.5, forward: true) == .success, "Playing skip failed")
        try await wait { controller.refresh(); return controller.pendingSeek == nil }
        try check(player.rate == 1, "Remote skip lost play intent")
        controller.pause()
        player.external = false
        controller.refresh()
        try check(controller.performRemoteSkip(interval: 1, forward: true) == .commandFailed, "Skip bypassed route requirements")
        player.external = true
        controller.refresh()
        print("PASS remote skip intervals, rapid requests, invalid ranges, route and play/pause intent")

        let languages = controller.nowPlayingLanguages
        let item = player.currentItem!
        let audio = languages.selectableEntries(in: item).filter { $0.option.languageOptionType == .audible }
        try check(audio.count >= 2 && languages.groups(in: item).count == 2, "Native groups were not published")
        try check(controller.selectRemoteLanguage(audio[1].option, enabled: true) == .success,
                  "Remote audio selection failed")
        try await wait { item.currentMediaSelection.selectedMediaOption(in: audio[1].group) == audio[1].native }
        let subtitles = languages.selectableEntries(in: item).filter { $0.option.languageOptionType == .legible }
        try check(subtitles.count >= 2, "Authored subtitle alternatives were lost after changing audio")
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            let available = item.selectableMediaSelectionOptions(in: subtitles[0].group)
            let inactive = languages.entries.filter { $0.group === subtitles[0].group && !available.contains($0.native) }
            for entry in inactive {
                try check(controller.selectRemoteLanguage(entry.option, enabled: true) == .commandFailed,
                          "A subtitle dependent on inactive audio was accepted")
                let index = entry.group.options.firstIndex(of: entry.native)!
                try check(controller.snapshot.subtitleOptions?.contains { $0.id.hasSuffix("-\(index)") } != true,
                          "The app offered a subtitle that cannot produce text")
            }
            let published = languages.groups(in: item).flatMap(\.languageOptions).compactMap(\.identifier)
            try check(inactive.allSatisfy { !published.contains($0.option.identifier ?? "") },
                      "Now Playing published unavailable generated subtitles")
        }
        #endif
        try check(controller.selectRemoteLanguage(subtitles[1].option, enabled: true) == .success,
                  "Remote subtitle selection failed")
        try await wait { controller.refresh(); return item.currentMediaSelection.selectedMediaOption(in: subtitles[1].group) == subtitles[1].native }
        try check(controller.nowPlayingLanguages.current(in: item).contains { $0.identifier == subtitles[1].option.identifier },
                  "Current language metadata did not follow selection")
        let subtitleIndex = subtitles[1].group.options.firstIndex(of: subtitles[1].native)!
        try check(controller.snapshot.selectedSubtitleID?.hasSuffix("-\(subtitleIndex)") == true,
                  "Remote subtitle selection did not synchronize the app")
        try check(controller.selectRemoteLanguage(subtitles[0].option, enabled: false) == .commandFailed,
                  "An old disable command turned off a newer selection")
        try check(controller.selectRemoteLanguage(subtitles[1].option, enabled: false) == .success,
                  "Remote subtitles could not be disabled")
        try check(!controller.nowPlayingLanguages.current(in: item).contains { $0.languageOptionType == .legible },
                  "Disabled subtitles remained in current language metadata")
        if !audio[1].group.allowsEmptySelection {
            try check(controller.selectRemoteLanguage(audio[1].option, enabled: false) == .commandFailed,
                      "A required audio group was disabled")
        }
        let oldOption = audio[1].option
        try controller.load(url("tracks.mp4").absoluteString)
        try await wait { controller.refresh(); return controller.snapshot.state == .ready }
        try check(controller.selectRemoteLanguage(oldOption, enabled: true) == .commandFailed,
                  "A language command for the old item changed its replacement")
        controller.stop()
        try check(controller.nowPlayingLanguages.entries.isEmpty
                  && controller.selectRemoteLanguage(oldOption, enabled: true) == .commandFailed,
                  "Stop retained actionable language options")
        print("PASS native remote languages, selection feedback, Off, required groups, stale commands and Stop")

        let artwork = NowPlayingArtworkLoader()
        defer { artwork.cancel() }
        var updates = 0
        artwork.load(url: url("video.mp4"), allowVideoFrame: true) { updates += 1 }
        try await wait { artwork.artwork != nil }
        try check(updates == 1 && artwork.artwork!.bounds.width <= 640 && artwork.artwork!.bounds.height <= 640,
                  "Static video artwork was not bounded or published exactly once")
        let poster = artwork.artwork!
        let request = ArtworkRequest(artwork: poster)
        let backgroundImageSize = await Task.detached {
            request.artwork.image(at: CGSize(width: 320, height: 180))?.size
        }.value
        try check(backgroundImageSize == poster.bounds.size,
                  "Now Playing artwork could not be requested from a background queue")
        artwork.load(url: url("artwork.mp4"), allowVideoFrame: false) { updates += 1 }
        try await wait { artwork.artwork != nil }
        try check(artwork.artwork!.bounds.size == CGSize(width: 64, height: 64), "Embedded artwork was not preferred")
        artwork.load(url: url("slow.mp4"), allowVideoFrame: true) { updates += 100 }
        artwork.load(url: url("video.mp4"), allowVideoFrame: true) { updates += 1 }
        try await wait { artwork.artwork != nil }
        try await Task.sleep(for: .milliseconds(2300))
        try check(updates == 3, "A replaced artwork request published a stale result")
        artwork.cancel()
        try check(artwork.artwork == nil, "Stop retained the previous artwork")
        let timed = NowPlayingArtworkLoader(timeout: .milliseconds(100))
        timed.load(url: url("slow.mp4"), allowVideoFrame: true) { updates += 100 }
        try await Task.sleep(for: .milliseconds(2300))
        try check(timed.artwork == nil && updates == 3, "Artwork timeout published late metadata")
        timed.cancel()
        print("PASS embedded artwork, bounded video poster, replacement cancellation, clearing and deadline")

        let livePlayer = MutedLivePlayer()
        let live = PlaybackController(player: livePlayer, showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0, delivery: .hls, isLive: true) },
            enableCompatibilityFallback: false, historyStore: MediaHistoryStore(defaults: nil),
            xtreamCatalogDefaults: defaults, prepareSource: nil, integratesWithSystemPlayback: false)
        defer { live.shutdown() }
        try live.load(url("live.m3u8").absoluteString)
        try await wait("live item readiness") { live.refresh(); return live.snapshot.state == .ready }
        try live.play()
        try await wait("live seekable window") { live.refresh(); return (live.snapshot.seekableRanges.last?.end ?? 0) > 20 }
        let liveItem = livePlayer.currentItem!
        try check(live.snapshot.isLive && live.snapshot.followsLive == true && liveItem.automaticallyPreservesTimeOffsetFromLive,
                  "New live media did not preserve its native offset")
        let window = live.snapshot.seekableRanges.last!
        let middle = (window.start + window.end) / 2
        try live.seek(middle)
        try await wait("live rewind completion") { live.refresh(); return live.pendingSeek == nil }
        try check(live.snapshot.followsLive == false && !liveItem.automaticallyPreservesTimeOffsetFromLive,
                  "A voluntary rewind retained automatic live recovery")
        try live.goLive()
        try await wait("Go Live completion") { live.refresh(); return live.pendingSeek == nil }
        try check(live.snapshot.followsLive == true && liveItem.automaticallyPreservesTimeOffsetFromLive,
                  "Go Live did not restore automatic offset recovery")
        let recommended = liveItem.recommendedTimeOffsetFromLive.seconds
        if recommended.isFinite && recommended >= 0 {
            try check(abs(liveItem.configuredTimeOffsetFromLive.seconds - recommended) < 0.01,
                      "Native live offset ignored the recommended value")
        }
        // A short EVENT fixture may recommend an offset as long as its window,
        // so Go Live can land at its start. Wait for an actual backward target.
        try await wait("live clock advancement") {
            live.refresh()
            return livePlayer.currentTime().seconds > window.start + 3
        }
        let beforeReceiverSeek = livePlayer.currentTime().seconds
        let receiverSeekFinished = await livePlayer.seek(to: CMTime(seconds: window.start + 1, preferredTimescale: 600),
                                                       toleranceBefore: .zero, toleranceAfter: .zero)
        try check(receiverSeekFinished && livePlayer.currentTime().seconds < beforeReceiverSeek - 1,
                  "Synthetic receiver seek did not rewind the native clock")
        try await wait("receiver rewind policy") { live.refresh(); return live.snapshot.followsLive == false }
        try live.goLive()
        try await wait("second Go Live completion") { live.refresh(); return live.pendingSeek == nil }
        live.pause()
        try check(live.snapshot.followsLive == false && !liveItem.automaticallyPreservesTimeOffsetFromLive,
                  "Pause retained automatic live recovery")
        live.stop()
        try check(live.snapshot.followsLive == nil && !liveItem.automaticallyPreservesTimeOffsetFromLive,
                  "Stop retained the retired item's live recovery policy")
        print("PASS native live offset, voluntary and receiver rewinds, Go Live, Pause and Stop")

        if #available(macOS 15, *) {
            let native = AVPlayer()
            native.allowsExternalPlayback = false
            native.isMuted = true
            let metricItem = AVPlayerItem(url: url("live.m3u8"))
            let metrics = NativePlaybackMetricsObserver()
            var metricUpdates = 0
            metrics.start(item: metricItem) { metricUpdates += 1 }
            defer { metrics.cancel(); native.pause(); native.replaceCurrentItem(with: nil) }
            native.replaceCurrentItem(with: metricItem)
            native.play()
            try await wait("native startup metric") { metrics.values?.startupSeconds != nil }
            await native.seek(to: CMTime(seconds: 30, preferredTimescale: 600))
            try await wait("native seek completion metric") { (metrics.values?.completedSeeks ?? 0) > 0 }
            try check(metrics.values?.lastSeekSeconds?.isFinite == true && metrics.values?.lastSeekWasBuffered != nil,
                      "Native seek completion did not supply numeric metrics")
            let data = try JSONEncoder().encode(metrics.values!)
            let text = String(decoding: data, as: UTF8.self)
            try check(!text.contains("http") && !text.contains("sessionID") && !text.contains("127.0.0.1"),
                      "Native metric status exposed resource identifiers")
            metrics.cancel()
            let count = metricUpdates
            await native.seek(to: .zero)
            try await Task.sleep(for: .milliseconds(200))
            try check(metricUpdates == count, "Retired metric subscription kept publishing")
            print("PASS real muted HLS AVPlayer startup/seek metrics, URL-free encoding and cancellation")
            print("5/5 system playback groups passed; physical AirPlay receiver untested")
        } else {
            print("4/4 system playback groups passed; native metrics require macOS 15; physical AirPlay receiver untested")
        }
    }
}
