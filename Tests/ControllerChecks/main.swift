import Foundation
import AVFoundation

private actor CancellationProbe {
    private var cancelled = false
    func markCancelled() { cancelled = true }
    func wasCancelled() -> Bool { cancelled }
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
        // muted negotiation quickly instead of pinning "Connecting to AirPlay…".
        controller.stop()
        try controller.load(base + "/video.mp4")
        try await waitFor(.awaitingReceiver)
        controller.pickerWillOpen()
        try await waitFor(.connecting)
        controller.pickerDidClose()
        try await waitFor(.awaitingReceiver, seconds: 6)
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
        try check(player.isMuted && player.rate == 0, "Deferred route negotiation started visible playback")
        try await waitFor(.awaitingReceiver, seconds: 16)
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
        print("5/5 controller checks passed (no physical receiver)")
    }
}
