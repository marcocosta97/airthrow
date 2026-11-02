#if SWIFT_PACKAGE
@testable import AirThrowCore
#endif
import Foundation
import AVFoundation

private actor CancellationProbe {
    private var cancelled = false
    func markCancelled() { cancelled = true }
    func wasCancelled() -> Bool { cancelled }
}
private actor QualityLoads {
    private var count = 0
    func next() -> Int { count += 1; return count }
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
        var ignoredPlays = 0
        var plays = 0
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
    override func play() {
        lock.withLock {
            transport.plays += 1
            if transport.ignoredPlays > 0 { transport.ignoredPlays -= 1 }
            else { transport.rate = 1 }
        }
    }
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
    var playCount: Int { lock.withLock { transport.plays } }
    func ignoreNextPlays(_ count: Int) { lock.withLock { transport.ignoredPlays = count } }
    func disconnect() { lock.withLock { transport.external = false } }
    func setReplies(_ replies: [Reply]) { lock.withLock { transport.replies = replies } }
}

@main
struct ControllerChecks {
    @MainActor static func main() async throws {
        #if compiler(>=6.4)
        let endedNotification = AVPlayerItem.didPlayToEndTimeNotification
        #else
        let endedNotification = Notification.Name.AVPlayerItemDidPlayToEndTime
        #endif
        let base = CommandLine.arguments[1]
        let controller = PlaybackController(historyStore: MediaHistoryStore(defaults: nil), integratesWithSystemPlayback: false)
        defer { controller.shutdown() }
        let recentStore = MediaHistoryStore(defaults: nil)
        recentStore.record(URL(string: "https://fixture.invalid/list.m3u")!, title: "Channels", kind: .iptv)
        recentStore.record(URL(string: "https://fixture.invalid/catalog")!, title: "Catalog", kind: .xtream)
        recentStore.record(URL(string: "https://fixture.invalid/video.mp4")!, title: "Video", kind: .video)
        let recentController = PlaybackController(loadIPTVCatalog: { _ in
            try IPTVPlaylist.parse(Data("#EXTM3U\n#EXTINF:-1,Demo\nhttps://fixture.invalid/video.mp4\n".utf8))
        }, historyStore: recentStore, integratesWithSystemPlayback: false)
        precondition(recentController.recentPlaybackHistory.count == 1)
        recentController.clearHistory()
        precondition(recentController.recentPlaybackHistory.isEmpty && recentStore.entries.count == 2)
        precondition(recentController.iptvPlaylists.isEmpty && recentController.iptvPlaylistSources.count == 1)
        precondition(recentController.iptvPlaylistSources[0].title == "Channels")
        recentController.selectIPTVPlaylist(recentController.iptvPlaylistSources[0].id)
        let reopenDeadline = Date().addingTimeInterval(3)
        while recentController.iptvPlaylists.isEmpty, Date() < reopenDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(recentController.iptvCatalog?.channels.count == 1 && recentController.iptvPlaylistSources.count == 1)
        let savedAccount = recentController.xtreamPlaylists[0].id
        recentController.removeHistoryEntry(savedAccount)
        precondition(recentController.xtreamPlaylists.isEmpty && recentStore.entries.count == 1)
        print("PASS saved M3U sources remain visible without loaded catalogs; Xtream removal persists")
        recentController.shutdown()
        print("PASS clearing recent playback preserves saved IPTV and Xtream sources")
        let player = controller.player

        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "ControllerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        do {
            let diagnostics = PlaybackController(resolveSource: { ResolvedSource(url: $0, needsPreparation: true) },
                enableCompatibilityFallback: false, historyStore: MediaHistoryStore(defaults: nil), prepareSource: { _ in
                    PreparationTrace.current?.mark(.chunkMux)
                    do { _ = try await HelperProcess.run(executable: "/usr/bin/false", arguments: []) }
                    catch { throw PreparationFailure.failed }
                    throw PreparationFailure.failed
                }, integratesWithSystemPlayback: false)
            defer { diagnostics.shutdown() }
            try diagnostics.load(base + "/video.mp4")
            let deadline = Date().addingTimeInterval(5)
            while diagnostics.snapshot.state != .failed, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            let detail = diagnostics.snapshot.diagnostics?.preparation
            try check(detail?.stage == .chunkMux && detail?.helperExitCode == 1 && detail?.failureReason == .preparationFailed,
                      "Preparation failure lost its fixed phase or numeric helper exit code")
            try check(HelperProcess.failureKind(Data("private-prefix: moov atom not found; private-suffix".utf8)) == .missingMovieHeader,
                      "Helper error classification lost the fixed MP4 header signature")
            try check(HelperProcess.failureKind(Data("private-unmatched-description".utf8)) == .other,
                      "Unknown helper text escaped the fixed diagnostic categories")
            let recorder = PreparationDiagnosticRecorder()
            recorder.mark(.chunkValidation)
            recorder.failed(NSError(domain: NSURLErrorDomain, code: -1005,
                userInfo: [NSLocalizedDescriptionKey: "private-description-sentinel"]))
            let frozen = recorder.snapshot.phaseSeconds
            try await Task.sleep(for: .milliseconds(20))
            let encoded = try JSONEncoder().encode(recorder.snapshot)
            try check(recorder.snapshot.phaseSeconds == frozen && !String(decoding: encoded, as: UTF8.self).contains("private-description-sentinel"),
                      "Preparation diagnostics changed failure time or exposed arbitrary error text")
            diagnostics.stop()
            try check(diagnostics.snapshot.diagnostics?.preparation == nil, "Stop retained a stale preparation failure trace")
            print("PASS preparation diagnostics preserve phase and helper exit without descriptions; Stop clears the trace")
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
        }, prepareSource: nil, integratesWithSystemPlayback: false)
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
            }, prepareSource: nil, integratesWithSystemPlayback: false)
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

        let sendPlayer = HandoffPlayer()
        let autoplaySuite = "airthrow-autoplay-checks-" + UUID().uuidString
        let autoplayDefaults = UserDefaults(suiteName: autoplaySuite)!
        defer { autoplayDefaults.removePersistentDomain(forName: autoplaySuite) }
        let sendController = PlaybackController(player: sendPlayer, resolveSource: { url in
            let marker = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "v" })?.value ?? "video"
            if marker == "delayed" { try await Task.sleep(for: .milliseconds(600)) }
            if marker == "stale" {
                await Task.detached { try? await Task.sleep(for: .milliseconds(600)) }.value
            }
            if marker == "boundary" { try await Task.sleep(for: .seconds(13)) }
            return ResolvedSource(url: mediaURL, title: marker)
        }, playbackDefaults: autoplayDefaults, resolvePlaylist: { url in
            if url.query?.contains("PLtimeout") == true {
                try await Task.sleep(for: .seconds(20))
                return ResolvedPlaylist(title: "Slow queue", entries: [
                    PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=boundary"), title: "Boundary")
                ], truncated: false)
            }
            try await Task.sleep(for: .milliseconds(600))
            return ResolvedPlaylist(title: "Sent queue", entries: [
                PlaylistEntry(url: nil, title: "Unavailable", unavailableReason: "Unavailable"),
                PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=first"), title: "First"),
                PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=second"), title: "Second")
            ], truncated: false)
        }, prepareSource: nil, integratesWithSystemPlayback: false)
        defer { sendController.shutdown() }
        func waitForSend(_ state: PlaybackState, seconds: Double = 10) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                sendController.refresh()
                if sendController.snapshot.state == state { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            try check(false, "Shared-link handoff did not reach \(state): \(sendController.snapshot)")
        }
        func sendURL(_ marker: String) -> String { "https://www.youtube.com/watch?v=\(marker)" }
        sendPlayer.handoff(at: 4, replies: [.interrupted, .restored])
        try sendController.load(sendURL("first"), autoplay: true)
        try check(sendPlayer.rate == 0 && sendPlayer.isMuted, "Send resumed the old item while loading")
        try await waitForSend(.playing)
        try check(sendController.player === sendPlayer && sendPlayer.currentTime().seconds == 0
                  && sendPlayer.seekCount == 2 && !sendPlayer.isMuted,
                  "Send did not verify zero before playback on the shared route")
        print("PASS explicit send-and-play restores zero before playing on the existing player")

        try sendController.load(sendURL("normal"))
        try await waitForSend(.ready)
        try check(sendPlayer.rate == 0 && sendPlayer.isMuted, "Ordinary load unexpectedly autoplayed")
        sendPlayer.disconnect()
        sendController.refresh()
        try sendController.load(sendURL("no-route"), autoplay: true)
        try await waitForSend(.awaitingReceiver)
        try check(sendController.notice?.contains("press Play") == true, "Send without receiver gave no guide")
        sendController.pickerWillOpen()
        sendPlayer.handoff(at: 0, replies: [.restored])
        sendController.pickerDidClose()
        sendController.refresh()
        try await waitForSend(.ready)
        try check(sendPlayer.rate == 0 && sendPlayer.isMuted, "Receiver chosen after receipt triggered armed autoplay")
        print("PASS ordinary loads and sends without an active receiver remain paused")

        try sendController.load(sendURL("delayed"), autoplay: true)
        sendController.pause()
        try await waitForSend(.ready)
        try check(sendPlayer.rate == 0, "Pause during resolution did not cancel send-and-play")
        try sendController.load(sendURL("stale"), autoplay: true)
        // Let a resolver that ignores caller cancellation start before replacing it.
        try await Task.sleep(for: .milliseconds(100))
        try sendController.load(sendURL("latest"))
        try await waitForSend(.ready)
        try await Task.sleep(for: .milliseconds(700))
        sendController.refresh()
        try check(sendController.snapshot.title == "latest" && sendPlayer.rate == 0,
                  "Stale send resolution replaced or played the newer request")
        print("PASS Pause and a newer paused load cancel pending send-and-play")

        try sendController.load("https://www.youtube.com/playlist?list=PL12345678", autoplay: true)
        sendController.pause()
        try await waitForSend(.ready)
        try check(sendController.snapshot.queue?.currentIndex == 1 && sendPlayer.rate == 0,
                  "Pause during playlist extraction did not cancel first-item autoplay")
        print("PASS Pause during playlist extraction cancels the first item's play intent")

        try sendController.load(sendURL("delayed"), autoplay: true)
        sendPlayer.disconnect()
        sendController.refresh()
        try await Task.sleep(for: .milliseconds(200))
        sendPlayer.handoff(at: 3, replies: [.restored])
        sendController.refresh()
        try await waitForSend(.playing)
        try check(sendPlayer.currentTime().seconds == 0, "Transient route transition lost the requested starting position")
        print("PASS replacement tolerates a brief external route transition")

        try sendController.load("https://www.youtube.com/playlist?list=PLtimeout123456", autoplay: true)
        sendPlayer.disconnect()
        sendController.refresh()
        let timeoutDeadline = ContinuousClock.now.advanced(by: .seconds(32))
        while ContinuousClock.now < timeoutDeadline,
              sendController.notice?.contains("did not reconnect") != true {
            sendController.refresh()
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(sendController.notice?.contains("did not reconnect") == true,
                  "Pending send had no bounded receiver timeout: \(sendController.notice ?? "nil"), \(sendController.snapshot.state)")
        sendPlayer.handoff(at: 0, replies: [.restored])
        sendPlayer.pause() // Route restoration alone, without a simulated remote Play.
        sendController.refresh()
        try await waitForSend(.ready)
        try check(sendPlayer.rate == 0 && sendPlayer.isMuted, "Late reconnect revived expired send-and-play")
        print("PASS lost-route grace spans playlist resolution and item loading; late reconnect stays paused")

        try sendController.load("https://www.youtube.com/playlist?list=PL12345678", autoplay: true)
        try await waitForSend(.playing)
        try check(sendController.snapshot.queue?.currentIndex == 1 && sendController.snapshot.title == "first",
                  "Playlist send lost intent while skipping its unavailable leading item")
        try sendController.load(sendURL("delayed"), autoplay: true)
        sendController.stop()
        try await Task.sleep(for: .milliseconds(700))
        sendController.refresh()
        try check(sendController.snapshot.state == .idle && sendPlayer.currentItem == nil && sendPlayer.rate == 0,
                  "Stop allowed a pending send to complete")
        print("PASS playlist send propagates play intent and Stop cancels pending replacement")

        try check(!sendController.autoplayVideos, "Autoplay was enabled without opting in")
        sendController.setAutoplayVideos(true)
        let restoredPreference = PlaybackController(historyStore: MediaHistoryStore(defaults: nil),
            playbackDefaults: autoplayDefaults, integratesWithSystemPlayback: false)
        try check(restoredPreference.autoplayVideos, "Autoplay preference did not survive controller recreation")
        restoredPreference.shutdown()
        sendPlayer.handoff(at: 0, replies: [.restored])
        try sendController.load(sendURL("automatic"))
        try await waitForSend(.playing)
        sendController.pause()
        guard let rememberedVideo = sendController.history.first(where: { $0.kind == .video }) else {
            throw NSError(domain: "ControllerChecks", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Synthetic video was not remembered"])
        }
        try sendController.selectHistoryEntry(rememberedVideo.id)
        try await waitForSend(.playing)
        sendController.pause()
        try sendController.selectXtreamMedia(mediaURL, title: "Synthetic film")
        try await waitForSend(.playing)
        try sendController.load(sendURL("explicit-paused"), autoplay: false)
        try await waitForSend(.ready)
        try check(sendPlayer.rate == 0, "Autoplay preference overrode an explicit paused load")
        print("PASS autoplay persists and starts ordinary, History and Xtream selections; explicit pause wins")

        try sendController.load("https://www.youtube.com/playlist?list=PL12345678")
        try await waitForSend(.playing)
        sendController.pause()
        try sendController.next()
        try await waitForSend(.playing)
        try check(sendController.snapshot.queue?.currentIndex == 2, "Autoplay did not start the next queue item")
        sendController.pause()
        try sendController.previous()
        try await waitForSend(.playing)
        try check(sendController.snapshot.queue?.currentIndex == 1,
                  "Autoplay queue navigation failed to skip an unavailable item")
        print("PASS autoplay starts the first playable playlist item and manual queue navigation")

        sendController.stop()
        sendPlayer.disconnect()
        try sendController.load(sendURL("await-receiver"))
        try await waitForSend(.awaitingReceiver, seconds: 20)
        try check(sendPlayer.rate == 0 && sendPlayer.isMuted, "Autoplay played without a receiver")
        sendController.pickerWillOpen()
        sendPlayer.handoff(at: 0, replies: [.restored])
        sendController.pickerDidClose()
        try await waitForSend(.playing)
        sendController.stop()
        sendPlayer.disconnect()
        try sendController.load(sendURL("cancelled-auto"))
        try await waitForSend(.awaitingReceiver, seconds: 20)
        sendController.pause()
        sendController.pickerWillOpen()
        sendPlayer.handoff(at: 0, replies: [.restored])
        sendController.pickerDidClose()
        try await waitForSend(.ready)
        try check(sendPlayer.rate == 0, "Pause did not cancel autoplay while waiting for a receiver")
        try sendController.load(sendURL("delayed"))
        sendController.pause()
        try await waitForSend(.ready)
        try check(sendPlayer.rate == 0, "Pause during loading did not cancel preference autoplay")
        sendController.setAutoplayVideos(false)
        try sendController.selectXtreamMedia(mediaURL, title: "Paused synthetic film")
        try await waitForSend(.ready)
        try check(sendPlayer.rate == 0, "Disabling autoplay did not keep a paused selection paused")
        print("PASS autoplay waits for a receiver; Pause during waiting or loading and disabling the preference keep selections paused")

        let handoffPlayer = HandoffPlayer()
        let handoffController = PlaybackController(player: handoffPlayer, historyStore: MediaHistoryStore(defaults: nil),
                                                  prepareSource: nil, integratesWithSystemPlayback: false)
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
        NotificationCenter.default.post(name: endedNotification,
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
        let qualityPlayer = HandoffPlayer()
        let qualityLoads = QualityLoads()
        let qualityURL = URL(string: base + "/long-video.mp4")!
        let qualityController = PlaybackController(player: qualityPlayer, resolveCandidates: { _ in
            if await qualityLoads.next() == 4 { try await Task.sleep(for: .seconds(35)) }
            return [MediaCandidate(source: ResolvedSource(url: qualityURL), id: "low", height: 720),
                    MediaCandidate(source: ResolvedSource(url: qualityURL), id: "high", height: 1080)]
        }, allowVideoConversion: true, prepareSource: nil, integratesWithSystemPlayback: false)
        defer { qualityController.shutdown() }
        func waitForQuality(_ state: PlaybackState) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                qualityController.refresh()
                if qualityController.snapshot.state == state { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            try check(false, "Quality replacement did not reach \(state): \(qualityController.snapshot)")
        }
        try qualityController.load(sendURL("quality"))
        try await waitForQuality(.awaitingReceiver)
        let qualityDuration = qualityController.snapshot.duration!
        qualityPlayer.handoff(at: 4, replies: [.restored])
        qualityController.refresh()
        try qualityController.play()
        let qualityItem = qualityPlayer.currentItem
        let lowChoice = qualityController.snapshot.sources!.first(where: { $0.quality == "720p" })!.id
        try qualityController.applyVideoOptions(sourceID: lowChoice, enhancement: .original, output4K: false)
        try check(qualityController.snapshot.position == 4 && qualityPlayer.rate == 0,
                  "Quality reload lost its target or kept the old video playing")
        try check(PlaybackPolicy.activeSeekRange(qualityController.snapshot)?.end == qualityDuration,
                  "Quality reload collapsed the timeline: \(qualityController.snapshot), original duration \(qualityDuration)")
        try await waitForQuality(.playing)
        try check(qualityController.player === qualityPlayer && qualityPlayer.currentItem !== qualityItem
                  && qualityPlayer.currentTime().seconds == 4 && qualityPlayer.rate == 1,
                  "Quality replacement failed to preserve position and play intent")
        // Move farther along after the first replacement: the second must use
        // the current clock, rather than the previous reload's saved target.
        qualityPlayer.handoff(at: 6, replies: [.interrupted, .restored])
        qualityController.pause()
        let highChoice = qualityController.snapshot.sources!.first(where: { $0.quality == "1080p" })!.id
        try qualityController.applyVideoOptions(sourceID: highChoice, enhancement: .original, output4K: false)
        try await waitForQuality(.paused)
        try check(qualityPlayer.currentTime().seconds == 6 && qualityPlayer.rate == 0,
                  "Paused quality replacement reused an old target or autoplayed")
        print("PASS quality replacements preserve current position and play/pause on the persistent player")
        qualityPlayer.handoff(at: 40, replies: [.restored])
        try qualityController.play()
        let playsBeforeReplacement = qualityPlayer.playCount
        qualityPlayer.ignoreNextPlays(2)
        let delayedChoice = qualityController.snapshot.sources!.first(where: { $0.quality == "720p" })!.id
        try qualityController.applyVideoOptions(sourceID: delayedChoice, enhancement: .original, output4K: false)
        qualityPlayer.disconnect()
        try await Task.sleep(for: .seconds(32))
        qualityController.refresh()
        try check(qualityController.snapshot.position == 40 && qualityController.snapshot.duration == qualityDuration
                  && qualityController.notice?.contains("did not reconnect") != true,
                  "Slow replacement moved the timeline or expired playback intent during preparation")
        qualityPlayer.handoff(at: 40, replies: [.restored])
        try await waitForQuality(.playing)
        try check(qualityPlayer.currentTime().seconds == 40 && qualityPlayer.rate == 1,
                  "Slow quality switch required a manual Play or restarted the video")
        try check(qualityPlayer.playCount >= playsBeforeReplacement + 3,
                  "Replacement lost resume intent after the receiver ignored Play")
        print("PASS replacement beyond 30 seconds keeps the 40-second timeline and resumes automatically")
        print("PASS replacement retries ignored Play commands until playback is observed")
        qualityPlayer.ignoreNextPlays(99)
        let playsBeforePause = qualityPlayer.playCount
        let pauseChoice = qualityController.snapshot.sources!.first(where: { $0.quality == "1080p" })!.id
        try qualityController.applyVideoOptions(sourceID: pauseChoice, enhancement: .original, output4K: false)
        let pauseDeadline = Date().addingTimeInterval(10)
        while qualityPlayer.playCount == playsBeforePause, Date() < pauseDeadline {
            qualityController.refresh()
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(qualityPlayer.playCount > playsBeforePause, "Pause fixture did not enter resume confirmation")
        qualityController.pause()
        let pausedPlays = qualityPlayer.playCount
        try await Task.sleep(for: .seconds(2))
        try check(qualityPlayer.playCount == pausedPlays && qualityPlayer.rate == 0,
                  "Pause failed to cancel automatic resume retries")
        print("PASS Pause cancels replacement Play retries")
        qualityPlayer.ignoreNextPlays(0)
        try qualityController.play()
        qualityPlayer.setReplies([.restored])
        try qualityController.seek(30)
        try check(qualityController.snapshot.state == .playing && qualityController.snapshot.seekInProgress == true
                  && qualityController.snapshot.position == 30,
                  "Playing seek hid its progress or moved the requested timeline")
        let seekDeadline = Date().addingTimeInterval(10)
        while qualityController.pendingSeek != nil, Date() < seekDeadline {
            qualityController.refresh()
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(qualityController.snapshot.seekInProgress == nil && qualityPlayer.currentTime().seconds == 30
                  && qualityPlayer.rate == 1, "Seek did not clear its spinner and resume playback")
        qualityPlayer.setReplies([.unanswered, .restored])
        try qualityController.seek(32)
        try qualityController.seek(33)
        let supersededDeadline = Date().addingTimeInterval(10)
        while qualityController.pendingSeek != nil, Date() < supersededDeadline {
            qualityController.refresh()
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(qualityPlayer.currentTime().seconds == 33 && qualityController.snapshot.seekInProgress == nil,
                  "A superseded seek published a stale position or spinner")
        qualityPlayer.setReplies([.unanswered])
        try qualityController.seek(35)
        qualityController.pause()
        try check(qualityController.snapshot.seekInProgress == true && qualityPlayer.rate == 0,
                  "Pause hid unfinished seek work or resumed the old position")
        qualityController.stop()
        try await Task.sleep(for: .milliseconds(300))
        try check(qualityController.snapshot.seekInProgress == nil && qualityController.snapshot.state == .idle,
                  "Stop retained seek work")
        print("PASS seek progress stays visible on AirPlay, resumes play and handles supersession/Pause/Stop")
        let editorStore = MediaHistoryStore(defaults: nil)
        let editor = PlaybackController(loadIPTVCatalog: { url in
            guard url.host != "broken.invalid" else { throw URLError(.cannotConnectToHost) }
            return try IPTVPlaylist.parse(Data("#EXTM3U\n#EXTINF:-1,Demo\nhttps://fixture.invalid/video.mp4\n".utf8))
        }, historyStore: editorStore, integratesWithSystemPlayback: false)
        defer { editor.shutdown() }
        let draft = PlaylistConnectionDraft(kind: .m3u, name: "Original", address: "https://fixture.invalid/list.m3u")
        try await editor.savePlaylistConnection(draft, username: "", password: "", storage: .session)
        let playlistID = editor.iptvPlaylists[0].id
        let sourceID = editorStore.entries[0].id
        var edited = editor.playlistConnectionDraft(kind: .m3u, id: playlistID)
        edited.name = "Renamed"
        try await editor.savePlaylistConnection(edited, username: "", password: "", storage: .keep)
        try check(editor.iptvPlaylists[0].title == "Renamed" && editorStore.entries[0].title == "Renamed", "Editor renames the library and saved source together")
        edited.address = "https://broken.invalid/list.m3u"
        do {
            try await editor.savePlaylistConnection(edited, username: "", password: "", storage: .session)
            try check(false, "Failed connection replaced a working source")
        } catch is URLError {}
        try check(editorStore.entries.count == 1 && editorStore.entries[0].id == sourceID && editor.iptvPlaylists[0].source == URL(string: draft.address), "Failed edits preserve the working source")
        edited.address = "https://fixture.invalid/replacement.m3u"
        try await editor.savePlaylistConnection(edited, username: "", password: "", storage: .session)
        try check(editorStore.entries.count == 1 && editorStore.entries[0].id == sourceID && editor.iptvPlaylists.count == 1 && editor.iptvPlaylists[0].id == playlistID, "Successful edits preserve sidebar and source identity")
        print("PASS source editor renames, replaces and preserves a working source on failure")
        let local = PlaybackController(historyStore: MediaHistoryStore(defaults: nil), integratesWithSystemPlayback: false)
        defer { local.shutdown() }
        local.setLocalDebugPlayback(true, showWindow: false)
        try local.load(base + "/video.mp4")
        let localDeadline = Date().addingTimeInterval(15)
        while local.snapshot.state == .loading && Date() < localDeadline { try await Task.sleep(for: .milliseconds(50)) }
        try local.play()
        try await Task.sleep(for: .milliseconds(500))
        try check(local.player.rate > 0 && local.snapshot.localPlaybackActive == true && !local.snapshot.externalPlaybackActive,
                  "Local debug plays on the persistent player without reporting an AirPlay connection")
        try check(PlaybackPolicy.canControl(local.snapshot), "Local debug enables transport controls")
        local.pause()
        try check(local.player.rate == 0, "Local debug responds to Pause")
        local.setLocalDebugPlayback(false, showWindow: false)
        try check(local.snapshot.localPlaybackActive != true && local.player.currentItem == nil,
                  "Changing debug output unloads playback")
        print("27/27 controller checks passed (simulated handoff and local AVPlayer; no physical receiver)")
    }
}
