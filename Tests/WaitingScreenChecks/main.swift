import AVFoundation
import Foundation

private final class RoutePlayer: AVPlayer, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var external = false
    override var isExternalPlaybackActive: Bool { lock.withLock { external } }
    func setExternal(_ active: Bool) { lock.withLock { external = active } }
}

@main
struct WaitingScreenChecks {
    @MainActor static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "WaitingScreenChecks", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: @MainActor () -> Bool) async throws {
            let end = Date().addingTimeInterval(10)
            while !condition() && Date() < end { try await Task.sleep(for: .milliseconds(50)) }
            try check(condition(), "Timed out waiting for state")
        }
        let stream = try WaitingScreenStream(assets: file, automaticallyAdvance: false)
        let directory = stream.directory
        for latest in 5...85 { try stream.publish(latest: latest) }
        let index = try String(contentsOf: stream.playlist, encoding: .utf8)
        try check(index.contains("#EXT-X-MEDIA-SEQUENCE:80") &&
                  index.contains("#EXT-X-DISCONTINUITY-SEQUENCE:3") &&
                  index.contains("#EXT-X-DISCONTINUITY\n") && !index.contains("ENDLIST"),
                  "Live playlist lost its sequence, discontinuity, or became finite")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try check(files.count <= 19, "Live stream accumulates files indefinitely")
        stream.stop()
        try check(!FileManager.default.fileExists(atPath: directory.path), "Stream files leaked after Stop")
        print("PASS live playlist cycles indefinitely with bounded files and cleans up")

        let disabled = PlaybackController(showReceiverWaitingScreen: false, waitingScreenURL: { file })
        disabled.pickerWillOpen()
        try check(disabled.player.currentItem == nil, "Disabled option installed media")
        disabled.shutdown()
        print("PASS disabled by default behavior")

        let player = RoutePlayer()
        let controller = PlaybackController(player: player, showReceiverWaitingScreen: true,
                                            waitingScreenURL: { file }, prepareSource: nil)
        defer { controller.shutdown() }
        controller.pickerWillOpen()
        controller.stop()
        try await Task.sleep(for: .milliseconds(300))
        try check(player.currentItem == nil && controller.snapshot.receiverWaiting != true,
                  "Cancelled startup revived waiting media")
        print("PASS Stop cancels pending preparation")

        controller.pickerWillOpen()
        try await wait { player.currentItem?.status == .readyToPlay && player.rate > 0 }
        controller.refresh()
        try check(controller.snapshot.receiverWaiting == true && controller.snapshot.state == .connecting,
                  "Waiting screen missing connecting state")
        try check(player.isMuted && controller.snapshot.duration == nil && controller.snapshot.position == nil,
                  "Waiting screen exposed a user timeline or audio")
        try check(!PlaybackPolicy.canControl(controller.snapshot), "Waiting screen enabled user Play")
        print("PASS waiting media starts muted without user playback controls")

        player.setExternal(true)
        controller.refresh()
        try check(controller.snapshot.externalPlaybackActive && controller.snapshot.receiverWaiting == true,
                  "Waiting screen did not report active route")
        if ProcessInfo.processInfo.environment["AIRTHROW_WAITING_LONG_CHECK"] == "1" {
            // A mocked external route has no rendering clock. Use a separate real
            // local player to exercise HLS timing while the helper serves its stream.
            let url = (player.currentItem!.asset as! AVURLAsset).url
            let clockPlayer = AVPlayer(url: url)
            let layer = AVPlayerLayer(player: clockPlayer)
            clockPlayer.isMuted = true
            clockPlayer.play()
            defer { clockPlayer.pause(); layer.player = nil }
            try await wait { clockPlayer.timeControlStatus == .playing }
            let start = clockPlayer.currentTime().seconds
            for step in 1...25 {
                try await Task.sleep(for: .seconds(5))
                let line = "LIVE t=\(step * 5) start=\(start) current=\(clockPlayer.currentTime().seconds) state=\(clockPlayer.timeControlStatus.rawValue) error=\(String(describing: clockPlayer.currentItem?.error))\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            controller.refresh()
            try check(clockPlayer.currentItem?.error == nil && clockPlayer.timeControlStatus == .playing &&
                      clockPlayer.currentTime().seconds - start > 115 && controller.snapshot.receiverWaiting == true,
                      "Live stream stalled across its asset-cycle discontinuity")
            print("PASS live playback crosses a full asset cycle without ending or stalling")
        }
        player.setExternal(false)
        controller.refresh()
        try check(player.currentItem == nil && controller.snapshot.state == .idle,
                  "Route loss did not remove waiting screen")
        for _ in 0..<3 { controller.refresh() }
        try check(player.currentItem == nil, "Waiting screen restarted after route loss")
        print("PASS remote route loss returns idle without reopening")

        controller.pickerWillOpen()
        try await wait { player.currentItem?.status == .readyToPlay }
        player.setExternal(true)
        controller.refresh()
        let waitingItem = player.currentItem
        let replacementStream = try WaitingScreenStream(assets: file)
        let replacement = try await MediaHTTPServer.start(file: replacementStream.playlist, host: "127.0.0.1", hls: true)
        defer { replacement.stop(); replacementStream.stop() }
        try controller.load(replacement.url!.absoluteString)
        try await wait { controller.refresh(); return controller.snapshot.state == .ready }
        try check(controller.player === player && player.currentItem !== waitingItem,
                  "User media did not replace waiting item on the persistent player")
        try check(controller.snapshot.receiverWaiting != true && player.rate == 0,
                  "Replacement autoplays or retains waiting state")
        print("PASS load replaces waiting screen on same player, paused")
        controller.stop()
        try check(player.currentItem == nil, "Stop retained media")
        print("7/7 waiting-screen checks passed")
    }
}
