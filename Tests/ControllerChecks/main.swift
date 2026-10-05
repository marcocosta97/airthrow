import Foundation
import AVFoundation

private actor CancellationProbe {
    private var cancelled = false
    func markCancelled() { cancelled = true }
    func wasCancelled() -> Bool { cancelled }
}

/// Exercise transport replies that occur during an AirPlay handoff, while a
/// real AVPlayerItem still supplies readiness and video/seekable metadata.
private final class HandoffPlayer: AVPlayer, @unchecked Sendable {
    enum Reply { case interrupted, unanswered, stalePosition, restored }
    private struct Transport {
        var external = false
        var position = 0.0
        var rate: Float = 0
        var replies: [Reply] = []
        var seeks = 0
    }
    private let lock = NSLock()
    nonisolated(unsafe) private var transport = Transport() // All access is protected by lock.

    override var isExternalPlaybackActive: Bool { lock.withLock { transport.external } }
    override var rate: Float {
        get { lock.withLock { transport.rate } }
        set { lock.withLock { transport.rate = newValue } }
    }
    override var timeControlStatus: AVPlayer.TimeControlStatus { rate == 0 ? .paused : .playing }
    override func currentTime() -> CMTime {
        CMTime(seconds: lock.withLock { transport.position }, preferredTimescale: 600)
    }
    override func play() { rate = 1 }
    override func pause() { rate = 0 }
    override func preroll(atRate rate: Float, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        completionHandler?(true)
    }
    override func cancelPendingPrerolls() {}
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
                       completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        let reply = lock.withLock {
            transport.seeks += 1
            let reply = transport.replies.isEmpty ? Reply.restored : transport.replies.removeFirst()
            if case .restored = reply { transport.position = time.seconds }
            return reply
        }
        switch reply {
        case .interrupted: completionHandler?(false)
        case .unanswered: break
        case .stalePosition: completionHandler?(true)
        case .restored: completionHandler?(true)
        }
    }
    func handoff(at position: Double, replies: [Reply]) {
        lock.withLock {
            transport.external = true
            transport.position = position
            transport.rate = 1
            transport.replies = replies
            transport.seeks = 0
        }
    }
    var seekCount: Int { lock.withLock { transport.seeks } }
    func disconnect() { lock.withLock { transport.external = false } }
    func setReplies(_ replies: [Reply]) { lock.withLock { transport.replies = replies } }
}

@main
struct ControllerChecks {
    @MainActor static func main() async throws {
        let base = CommandLine.arguments[1]
        let controller = PlaybackController()
        defer { controller.shutdown() }
        let player = controller.player

        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "ControllerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func waitFor(_ state: PlaybackState, seconds: Double = 10) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                controller.refresh()
                if controller.snapshot.state == state { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "ControllerChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(state): \(controller.snapshot)"])
        }

        try controller.load(base + "/video.mp4")
        try await waitFor(.awaitingReceiver)
        let firstItem = player.currentItem
        try check(firstItem != nil, "Initial item missing")
        try controller.load(base + "/audio.mp4")
        try check(controller.player === player && player.currentItem === firstItem, "Load discarded the player or cleared the old item before replacement")
        try check(player.rate == 0 && player.isMuted, "Old media was not paused and muted")
        try check(controller.snapshot.state == .loading && controller.snapshot.duration == nil && controller.snapshot.seekableRanges.isEmpty, "Loading exposed the previous item's timeline")
        try await waitFor(.awaitingReceiver)
        try check(player.currentItem !== firstItem && controller.snapshot.hasAudio == true, "New item did not replace the old item")
        print("PASS URL replacement keeps player and directly swaps paused items")

        // Dismissing the system picker without choosing a receiver must end the
        // muted negotiation after the route-selection grace period.
        controller.stop()
        try controller.load(base + "/video.mp4")
        try await waitFor(.awaitingReceiver)
        controller.pickerWillOpen()
        try await waitFor(.connecting)
        controller.pickerDidClose()
        try await waitFor(.awaitingReceiver, seconds: 36)
        try await Task.sleep(for: .milliseconds(200))
        try check(player.rate == 0 && player.isMuted && controller.snapshot.state == .awaitingReceiver,
                   "Dismissed picker left the controller negotiating")
        try check(controller.notice?.contains("receiver") == true, "Dismissed picker gave no feedback")
        print("PASS dismissed receiver picker stops negotiation with feedback")

        controller.stop()
        controller.pickerWillOpen()
        controller.pickerDidClose()
        try check(controller.snapshot.state == .idle && player.currentItem == nil && !controller.snapshot.externalPlaybackActive, "Empty picker interaction claimed a connected receiver or created media")
        try controller.load(base + "/video.mp4")
        try await waitFor(.connecting)
        try check(player.isMuted && controller.snapshot.position == 0,
                  "Deferred route negotiation exposed audible playback or its temporary position")
        try await waitFor(.awaitingReceiver, seconds: 36)
        try await Task.sleep(for: .milliseconds(200))
        try check(player.rate == 0 && player.isMuted && player.currentTime().seconds < 0.1, "Cancelled picker negotiation did not stop and restore position")
        print("PASS receiver-first workflow defers muted negotiation and times out safely")

        let retained = player.currentItem
        try controller.load(base + "/slow.mp4")
        controller.pickerWillOpen()
        controller.pickerDidClose()
        try check(player.currentItem === retained && player.rate == 0 && controller.snapshot.state == .loading, "Picker resumed the retained old item during loading")
        try controller.load(base + "/audio.mp4")
        try await waitFor(.connecting)
        try check(controller.snapshot.hasAudio == true && controller.player === player, "New URL or receiver intent lost during loading")
        controller.stop()
        try await Task.sleep(for: .milliseconds(200))
        try check(player.currentItem == nil && controller.snapshot.state == .idle && player.rate == 0, "Stop did not cancel pending negotiation")
        print("PASS picker during loading, newer URL, and Stop preserve session boundaries")

        let mediaURL = URL(string: base + "/audio.mp4")!
        let queueController = PlaybackController(resolveSource: { url in
            ResolvedSource(url: mediaURL, title: URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value)
        }, resolvePlaylist: { _ in
            ResolvedPlaylist(title: "Test queue", entries: [
                PlaylistEntry(url: nil, title: "Unavailable", unavailableReason: "Unavailable"),
                PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=BaW_jenozKc"), title: "First"),
                PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw"), title: "Second")
            ], truncated: false)
        }, prepareSource: nil)
        defer { queueController.shutdown() }
        func waitForQueue(_ index: Int, seconds: Double = 10) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                queueController.refresh()
                if queueController.snapshot.queue?.currentIndex == index,
                   queueController.snapshot.state == .awaitingReceiver { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "ControllerChecks", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for queue item \(index): \(queueController.snapshot)"])
        }
        try queueController.load("https://www.youtube.com/playlist?list=PL12345678")
        try await waitForQueue(1)
        try check(queueController.player.rate == 0 && queueController.player.isMuted,
                  "First playable queue item did not stay paused")
        try check(queueController.snapshot.queue?.items[0].state == .skipped,
                  "Unavailable leading item was not skipped")
        try queueController.next()
        try await waitForQueue(2)
        try check(queueController.snapshot.title == "jNQXAC9IVRw", "Next did not resolve near playback time")
        try queueController.previous()
        try await waitForQueue(1)
        queueController.stop()
        try check(queueController.snapshot.queue == nil && queueController.player.currentItem == nil,
                  "Stop did not clear the queue and player item")
        print("PASS playlist loads paused, skips unavailable entries, navigates lazily and clears on Stop")

        let cancellation = CancellationProbe()
        let replacementController = PlaybackController(resolveSource: { _ in ResolvedSource(url: mediaURL) },
            resolvePlaylist: { _ in
                do { try await Task.sleep(for: .seconds(5)) }
                catch { await cancellation.markCancelled(); throw error }
                return ResolvedPlaylist(title: "Stale", entries: [
                    PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=BaW_jenozKc"), title: "Stale")
                ], truncated: false)
            }, prepareSource: nil)
        defer { replacementController.shutdown() }
        try replacementController.load("https://www.youtube.com/playlist?list=PL12345678")
        try replacementController.load(base + "/audio.mp4")
        let replacementDeadline = Date().addingTimeInterval(10)
        while Date() < replacementDeadline, replacementController.snapshot.state != .awaitingReceiver {
            replacementController.refresh()
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(100))
        try check(await cancellation.wasCancelled(), "URL replacement did not cancel playlist extraction")
        try check(replacementController.snapshot.state == .awaitingReceiver && replacementController.snapshot.queue == nil,
                  "Stale playlist extraction replaced the newer source")
        print("PASS URL replacement cancels playlist extraction and rejects stale queue results")

        let handoffPlayer = HandoffPlayer()
        let handoffController = PlaybackController(player: handoffPlayer, prepareSource: nil)
        defer { handoffController.shutdown() }
        func waitForHandoff(_ state: PlaybackState, seconds: Double = 12) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                handoffController.refresh()
                if handoffController.snapshot.state == state { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            try check(false, "Handoff did not reach \(state): \(handoffController.snapshot)")
        }
        try handoffController.load(base + "/video.mp4")
        try await waitForHandoff(.awaitingReceiver)
        handoffController.pickerWillOpen()
        try await waitForHandoff(.connecting)
        handoffPlayer.handoff(at: 3, replies: [.interrupted, .unanswered, .stalePosition, .restored])
        handoffController.pickerDidClose()
        handoffController.refresh()
        try check(handoffController.snapshot.state == .connecting && handoffController.snapshot.position == 0,
                  "Handoff exposed the muted probe's advanced position")
        try check(handoffPlayer.rate == 0 && handoffPlayer.isMuted,
                  "Handoff resumed or unmuted playback while rewinding")
        handoffController.pause()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime,
                                        object: handoffPlayer.currentItem)
        try await Task.sleep(for: .milliseconds(50))
        do { try handoffController.play(); try check(false, "Play raced the handoff rewind") }
        catch let error as AppFailure { try check(error.code == .unsupportedOperation, "Unexpected Play error") }
        do { try handoffController.seek(0); try check(false, "Seek raced the handoff rewind") }
        catch let error as AppFailure { try check(error.code == .unsupportedOperation, "Unexpected seek error") }
        try await waitForHandoff(.ready)
        try check(handoffPlayer.seekCount == 4 && handoffPlayer.currentTime().seconds == 0,
                  "Interrupted, unanswered, or stale-position seek was not retried")
        try check(handoffPlayer.rate == 0 && handoffPlayer.isMuted,
                  "Recovered handoff started playback before Play")
        try handoffController.play()
        try check(handoffPlayer.rate == 1 && !handoffPlayer.isMuted,
                  "Play needed a manual rewind after automatic recovery")
        print("PASS route handoff retries seeks, verifies zero, and survives Pause/late end notifications")

        // Reconnecting a played item must retain the user's position.
        handoffPlayer.handoff(at: 4, replies: [.restored])
        handoffPlayer.disconnect()
        handoffController.refresh()
        handoffController.pickerWillOpen()
        handoffPlayer.handoff(at: 7, replies: [.interrupted, .restored])
        handoffController.pickerDidClose()
        try await waitForHandoff(.paused)
        try check(handoffPlayer.currentTime().seconds == 4 && handoffPlayer.rate == 0,
                  "Reconnection discarded the previously played position")
        print("PASS reconnecting a played item restores its position without autoplay")

        handoffPlayer.disconnect()
        handoffController.refresh()
        handoffController.pickerWillOpen()
        handoffPlayer.handoff(at: 6, replies: Array(repeating: .interrupted, count: 100))
        handoffController.pickerDidClose()
        try await waitForHandoff(.paused, seconds: 24)
        try check(handoffController.notice?.contains("Press Play to retry") == true,
                  "Exhausted rewind requested a manual seek")
        handoffPlayer.setReplies([.restored])
        try handoffController.play()
        try check(handoffController.snapshot.state == .connecting && handoffPlayer.rate == 0,
                  "Play started before retrying the failed rewind")
        try await waitForHandoff(.playing)
        try check(handoffPlayer.currentTime().seconds == 4,
                  "Play did not recover the original position after the retry timeout")
        print("PASS Play retries an exhausted handoff rewind before starting")

        handoffPlayer.disconnect()
        handoffController.refresh()
        handoffController.pickerWillOpen()
        handoffPlayer.handoff(at: 6, replies: [.unanswered])
        handoffController.pickerDidClose()
        try await Task.sleep(for: .milliseconds(100))
        handoffController.stop()
        try await Task.sleep(for: .milliseconds(500))
        try check(handoffController.snapshot.state == .idle && handoffPlayer.currentItem == nil && handoffPlayer.rate == 0,
                  "Stopped handoff completed into the unloaded session")
        print("PASS Stop cancels a pending handoff rewind")
        print("10/10 controller checks passed (simulated handoff; no physical receiver)")
    }
}
