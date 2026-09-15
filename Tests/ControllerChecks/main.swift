import Foundation
import AVFoundation

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

        controller.stop()
        controller.pickerWillOpen()
        controller.pickerDidClose()
        try check(controller.snapshot.state == .idle && player.currentItem == nil && !controller.snapshot.externalPlaybackActive, "Empty picker interaction claimed a connected receiver or created media")
        try controller.load(base + "/video.mp4")
        try await waitFor(.connecting)
        try check(player.isMuted, "Deferred route negotiation was not muted")
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
        print("3/3 controller checks passed (no physical receiver)")
    }
}
