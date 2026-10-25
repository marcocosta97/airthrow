import Foundation
import AVFoundation
import MediaPlayer

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
        func wait(_ predicate: @MainActor () -> Bool, seconds: Double = 12) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            try check(false, "Timed out waiting for the synthetic media operation")
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
        let audio = languages.entries.filter { $0.option.languageOptionType == .audible }
        let subtitles = languages.entries.filter { $0.option.languageOptionType == .legible }
        try check(audio.count >= 2 && subtitles.count >= 2 && languages.groups.count == 2,
                  "Native groups were not published: \(audio.count) audio, \(subtitles.count) subtitles")
        let item = player.currentItem!
        try check(controller.selectRemoteLanguage(audio[1].option, enabled: true) == .success,
                  "Remote audio selection failed")
        try await wait { item.currentMediaSelection.selectedMediaOption(in: audio[1].group) == audio[1].native }
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
        try check(controller.nowPlayingLanguages.groups.isEmpty
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
        print("3/3 system playback groups passed; physical AirPlay receiver untested")
    }
}
