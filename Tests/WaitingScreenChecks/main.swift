import AVFoundation
import Foundation

private final class RoutePlayer: AVPlayer, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var external = false
    nonisolated(unsafe) private var emptyReplacements = 0
    override var isExternalPlaybackActive: Bool { lock.withLock { external } }
    func setExternal(_ active: Bool) { lock.withLock { external = active } }
    var emptyReplacementCount: Int { lock.withLock { emptyReplacements } }
    override func replaceCurrentItem(with item: AVPlayerItem?) {
        if item == nil { lock.withLock { emptyReplacements += 1 } }
        super.replaceCurrentItem(with: item)
    }
}

@main
struct WaitingScreenChecks {
    @MainActor static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "WaitingScreenChecks", code: 1,
                                                 userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(seconds: Double = 10, _ condition: @MainActor () -> Bool) async throws {
            let end = Date().addingTimeInterval(seconds)
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
        // Supply a local rendering clock without opening or presenting video.
        let renderingClock = AVPlayerLayer(player: player)
        defer { withExtendedLifetime(renderingClock) {} }
        let controller = PlaybackController(player: player, showReceiverWaitingScreen: true,
                                            waitingScreenURL: { file }, resolveSource: { url in
            if url.lastPathComponent == "timeout.mp4" {
                try await Task.sleep(for: .seconds(45))
            }
            if url.lastPathComponent == "failed.mp4" { throw URLError(.cannotConnectToHost) }
            return ResolvedSource(url: url)
        }, prepareSource: nil)
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
        try controller.load("http://127.0.0.1:1/timeout.mp4")
        try await wait(seconds: 40) {
            controller.refresh()
            return controller.snapshot.receiverWaiting == true && player.currentItem?.status == .readyToPlay
        }
        try check(controller.snapshot.state == .failed && controller.snapshot.error?.contains("Loading timed out") == true,
                  "Waiting screen hides the failed source diagnosis")
        try check(controller.player === player && controller.snapshot.externalPlaybackActive && player.currentItem != nil,
                  "Loading timeout dropped the receiver instead of restoring its waiting screen")
        print("PASS loading timeout restores waiting media on the same player and preserves the error")
        let beforeRecovery = player.emptyReplacementCount
        try controller.load("http://127.0.0.1:1/failed.mp4")
        try await wait {
            controller.refresh()
            return controller.snapshot.receiverWaiting == true && player.currentItem?.status == .readyToPlay
        }
        try check(player.emptyReplacementCount == beforeRecovery,
                  "Recovery cleared the retained waiting item before replacing it")
        print("PASS failure before installing user media preserves the retained waiting item until replacement")
        try controller.selectXtreamMedia(replacement.url!, title: "Recovery channel", isLive: true)
        do {
            try await wait {
                controller.refresh()
                return controller.snapshot.state == .playing
            }
        } catch {
            print("Recovery state: \(controller.snapshot.state.rawValue), rate: \(player.rate), item: \(player.currentItem?.status.rawValue ?? -1), waiting: \(controller.snapshot.receiverWaiting == true)")
            throw error
        }
        try check(controller.snapshot.receiverWaiting != true && player.emptyReplacementCount == beforeRecovery
                  && controller.player === player,
                  "Channel selection after failure did not replace waiting media and resume without Stop")
        print("PASS channel selection recovers from failed waiting state without Stop or clearing the receiver")
        controller.stop()
        try check(player.currentItem == nil, "Stop retained media")
        try await Task.sleep(for: .milliseconds(300))
        try check(player.currentItem == nil && controller.snapshot.receiverWaiting != true,
                  "Stopped timeout recovery restarted the waiting screen")
        print("10/10 waiting-screen checks passed")
    }
}
