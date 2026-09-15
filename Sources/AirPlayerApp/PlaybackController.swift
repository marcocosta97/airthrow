import Foundation
import AVFoundation
import MediaPlayer
import Combine
#if SWIFT_PACKAGE
import AirPlayerCore
#endif

@MainActor
final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var snapshot = PlaybackSnapshot()
    @Published private(set) var notice: String?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var generation = UUID()
    private var loading = false
    private var resolving = false
    private var websiteURL: URL?
    private var retriedResolution = false
    private let resolveSource: @Sendable (URL) async throws -> ResolvedSource
    private var ended = false
    private var hasPlayed = false
    private var probing = false
    private var hasOpenedPicker = false
    private var pickerIsOpen = false
    private var probeWhenReady = false
    // The requested item is separate from the paused item retained in AVPlayer
    // while its replacement loads. Routing belongs to the long-lived player.
    private var mediaItem: AVPlayerItem?
    private var probePosition: Double = 0
    private var wasExternal = false
    private var failure: String?
    private var failureReason: MediaFailureReason?
    private var hasAudio: Bool?
    private var hasVideo = false
    private var title = "No video loaded"
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var activity: NSObjectProtocol?

    init(resolveSource: @escaping @Sendable (URL) async throws -> ResolvedSource = {
        try await SourceResolver().resolve($0)
    }) {
        self.resolveSource = resolveSource
        player.allowsExternalPlayback = true
        player.isMuted = true
        observations = [
            player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            },
            player.observe(\.rate, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        installRemoteCommands()
    }

    func load(_ input: String) throws {
        startLoad(try MediaInput.url(input))
    }

    private func startLoad(_ url: URL, retry: Bool = false) {
        let retryRoute = hasOpenedPicker || player.isExternalPlaybackActive
        resetItem(keepPlayerItem: true)
        probeWhenReady = retryRoute
        let id = generation
        loading = true
        resolving = SourceResolver.isWebsite(url)
        websiteURL = resolving ? url : nil
        retriedResolution = retry
        title = url.host ?? "Video"
        notice = nil
        refresh()
        let resolver = resolveSource
        loadTask = Task { [weak self] in
            do {
                let source = try await resolver(url)
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.resolving = false
                self.scheduleLoadTimeout(id: id)
                self.refresh()
                let asset = AVURLAsset(url: source.url)
                let playable = try await asset.load(.isPlayable)
                let video = try await asset.loadTracks(withMediaType: .video)
                // HLS may expose alternate audio as media-selection options.
                // An inspection error is unknown, not proof of a silent source.
                let audio = try? await asset.loadTracks(withMediaType: .audio)
                var detectedAudio: Bool?
                if let audio {
                    if !audio.isEmpty {
                        detectedAudio = true
                    } else {
                        do {
                            let group = try await asset.loadMediaSelectionGroup(for: .audible)
                            // Empty AVAsset tracks/options are inconclusive for HLS.
                            detectedAudio = group?.options.isEmpty == false ? true : (video.isEmpty ? nil : false)
                        } catch { detectedAudio = nil }
                    }
                }
                guard !Task.isCancelled, self.generation == id else { return }
                guard playable else {
                    self.fail(.unreadableMedia)
                    return
                }
                self.hasVideo = !video.isEmpty
                self.hasAudio = detectedAudio
                let item = AVPlayerItem(asset: asset)
                self.itemObservations = [
                    item.observe(\.status, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor in
                            guard let self, self.generation == id else { return }
                            self.refresh()
                        }
                    },
                    item.observe(\.tracks, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor in
                            guard let self, self.generation == id else { return }
                            self.refresh()
                        }
                    },
                    item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor in
                            guard let self, self.generation == id else { return }
                            self.refresh()
                        }
                    },
                    item.observe(\.seekableTimeRanges, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor in
                            guard let self, self.generation == id else { return }
                            self.refresh()
                        }
                    }
                ]
                self.notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        if self.probing {
                            // A short clip may end while the receiver picker is open.
                            // Keep the muted negotiation alive until its bounded timeout.
                            self.player.seek(to: .zero) { [weak self] finished in
                                Task { @MainActor in
                                    guard finished, let self, self.generation == id, self.probing else { return }
                                    self.player.play()
                                }
                            }
                            return
                        }
                        self.ended = true
                        self.player.pause()
                        self.refresh()
                    }
                })
                self.notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
                    let reason = MediaDiagnostics.reason(
                        for: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError,
                        fallback: .playbackInterrupted)
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.fail(reason)
                    }
                })
                self.mediaItem = item
                self.player.replaceCurrentItem(with: item)
                self.refresh()
            } catch {
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.fail((error as? ResolutionFailure)?.reason
                    ?? MediaDiagnostics.reason(for: error, fallback: .loadFailed))
            }
        }
        if !resolving { scheduleLoadTimeout(id: id) }
    }

    private func scheduleLoadTimeout(id: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.generation == id, self.loading else { return }
            self.loadTask?.cancel()
            self.fail(.loadFailed, message: "Loading timed out. Check the source and connection, then try again.")
        }
    }

    func play() throws {
        guard failure == nil, let item = mediaItem else {
            throw AppFailure(.playbackFailed, failure ?? "Load a video first.")
        }
        guard item.status == .readyToPlay, !loading else {
            throw AppFailure(.unsupportedOperation, "The video is still loading.")
        }
        guard player.isExternalPlaybackActive else {
            throw AppFailure(.routeRequired, "Choose a video receiver using the AirPlay button, then press Play.")
        }
        cancelProbe(restorePosition: true)
        notice = nil
        if ended {
            guard let start = snapshot.seekableRanges.first?.start else {
                throw AppFailure(.unsupportedOperation, "Load the video again to replay it.")
            }
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            ended = false
        }
        hasPlayed = true
        player.isMuted = false
        player.play()
        refresh()
    }

    func pause() {
        cancelProbe(restorePosition: true)
        player.pause()
        refresh()
    }

    func stop() {
        resetItem()
        title = "No video loaded"
        notice = nil
        refresh()
    }

    func seek(_ seconds: Double) throws {
        try MediaInput.validateSeek(seconds, ranges: snapshot.seekableRanges)
        guard !probing else { throw AppFailure(.unsupportedOperation, "Wait for the receiver connection to finish.") }
        guard player.isExternalPlaybackActive else {
            throw AppFailure(.routeRequired, "Choose a video receiver first.")
        }
        ended = false
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The picker is usable without media. Remember the interaction so a later
    /// ready item can establish the route without reopening the picker. Opening
    /// the picker is not evidence that the user selected a receiver.
    func pickerWillOpen() {
        hasOpenedPicker = true
        pickerIsOpen = true
        probeWhenReady = true
        refresh()
    }

    private func beginProbeIfReady() {
        guard probeWhenReady, mediaItem?.status == .readyToPlay, !loading else { return }
        probeWhenReady = false
        guard !player.isExternalPlaybackActive,
              failure == nil, !probing else { return }
        probePosition = finite(player.currentTime().seconds) ?? 0
        probing = true
        player.isMuted = true
        player.play()
        scheduleProbeTimeout(seconds: pickerIsOpen ? 30 : 12)
    }

    func pickerDidClose() {
        pickerIsOpen = false
        guard probing else { return }
        scheduleProbeTimeout(seconds: 12)
    }

    private func scheduleProbeTimeout(seconds: Double) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.probing else { return }
            self.cancelProbe(restorePosition: true)
            self.notice = "No video receiver connected. Use AirPlay to choose a TV, then try again."
            self.refresh()
        }
    }

    private func cancelProbe(restorePosition: Bool) {
        probeTask?.cancel()
        probeTask = nil
        guard probing else { return }
        probing = false
        player.pause()
        if restorePosition, player.currentItem?.status == .readyToPlay {
            player.seek(to: CMTime(seconds: probePosition, preferredTimescale: 600))
        }
    }

    private func resetItem(keepPlayerItem: Bool = false) {
        generation = UUID()
        loadTask?.cancel(); loadTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        cancelProbe(restorePosition: false)
        player.isMuted = true
        player.pause()
        itemObservations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        mediaItem = nil
        probeWhenReady = false
        // Avoid a nil item between URLs: swap directly on the same player.
        if !keepPlayerItem { player.replaceCurrentItem(with: nil) }
        loading = false; resolving = false; websiteURL = nil; retriedResolution = false
        ended = false; hasPlayed = false; failure = nil; failureReason = nil
        hasAudio = nil
        hasVideo = false
        wasExternal = player.isExternalPlaybackActive
    }

    private func fail(_ reason: MediaFailureReason, message: String? = nil) {
        // A stale signed source may fail during initial loading. Resolve once more,
        // still paused. Never restart established playback or retry indefinitely.
        if reason == .sourceUnavailable, let websiteURL, !retriedResolution, !hasPlayed {
            startLoad(websiteURL, retry: true)
            return
        }
        resolving = false
        cancelProbe(restorePosition: false)
        loading = false
        failureReason = reason
        failure = message ?? reason.message
        player.isMuted = true
        player.pause()
        timeoutTask?.cancel()
        refresh()
    }

    private func finite(_ number: Double) -> Double? { number.isFinite && number >= 0 ? number : nil }

    func refresh() {
        // Receiver-side controls must not resume a retained old item or a new
        // item whose video tracks are still being confirmed.
        if (mediaItem == nil || loading || failure != nil) && player.currentItem != nil {
            player.isMuted = true
            player.pause()
        }
        let external = player.isExternalPlaybackActive
        if wasExternal && !external {
            player.isMuted = true
            player.pause()
            if mediaItem != nil && failure == nil && !probeWhenReady {
                notice = "AirPlay disconnected. Choose a receiver to continue."
            }
        }
        wasExternal = external
        if probing && external {
            cancelProbe(restorePosition: true)
            notice = "Connected. Press Play when you’re ready."
        }
        if !external && !probing {
            player.isMuted = true
            if player.rate != 0 { player.pause() }
        }
        let item = mediaItem
        if item?.status == .failed && failure == nil {
            fail(MediaDiagnostics.reason(for: item?.error,
                fallback: hasPlayed ? .playbackInterrupted : .loadFailed))
            return
        }
        if let item, item.status == .readyToPlay, failure == nil {
            // Streaming assets may expose no AVAsset tracks. Inspect the ready
            // player item's tracks and size before concluding that video/audio is absent.
            let types = item.tracks.compactMap { $0.assetTrack?.mediaType }
            let completeTrackInfo = !types.isEmpty && types.count == item.tracks.count
            hasVideo = hasVideo || types.contains(.video)
                || (item.presentationSize.width > 0 && item.presentationSize.height > 0)
            if types.contains(.audio) { hasAudio = true }
            // A streaming item's tracks may arrive after readiness or change.
            // Their temporary lack of audio is not evidence of a silent source.
            if hasVideo {
                loading = false
                timeoutTask?.cancel()
            } else if completeTrackInfo {
                // Set the failure here without recursively entering refresh().
                failureReason = .noVideo
                failure = MediaFailureReason.noVideo.message
                loading = false
                timeoutTask?.cancel()
                player.isMuted = true
                player.pause()
            }
            // With incomplete track information, stay loading until observation
            // supplies video evidence or the existing bounded load timeout expires.
        }
        beginProbeIfReady()
        if external && !probing && player.rate > 0 {
            hasPlayed = true
            player.isMuted = false
            notice = nil
        }
        var next = PlaybackSnapshot()
        next.title = title
        next.externalPlaybackActive = external
        next.error = failure
        next.errorReason = failureReason
        next.loadingPhase = resolving ? "resolving" : nil
        next.hasAudio = hasAudio
        next.duration = item.flatMap { finite($0.duration.seconds) }
        next.position = item == nil ? nil : finite(player.currentTime().seconds)
        next.seekableRanges = (item?.seekableTimeRanges ?? []).compactMap {
            let range = $0.timeRangeValue
            guard let start = finite(range.start.seconds), let end = finite(CMTimeRangeGetEnd(range).seconds), end > start else { return nil }
            return SeekRange(start: start, end: end)
        }
        next.isLive = item?.status == .readyToPlay && item?.duration.isIndefinite == true
        next.state = PlaybackPolicy.state(hasItem: item != nil || loading || failure != nil,
            failed: failure != nil, ready: item?.status == .readyToPlay && !loading,
            connecting: probing, external: external, ended: ended,
            playing: player.timeControlStatus == .playing, waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            hasPlayed: hasPlayed)
        if snapshot != next { snapshot = next }
        updateNowPlaying()
    }

    func displayError(_ error: Error) {
        notice = (error as? AppFailure)?.message ?? "The action could not be completed. Please try again."
    }

    func clearNotice() { notice = nil }

    func shutdown() {
        stop()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        observations.removeAll()
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
        remoteTargets.removeAll()
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand, command: .play)
        register(center.pauseCommand, command: .pause)
        register(center.stopCommand, command: .stop)
        let target = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Self.onMain {
                guard let self else { return .commandFailed }
                do {
                    if self.player.rate > 0 { self.pause() } else { try self.play() }
                    return .success
                } catch { return .commandFailed }
            }
        }
        remoteTargets.append((center.togglePlayPauseCommand, target))
        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            return Self.onMain {
                guard let self else { return .commandFailed }
                do { try self.seek(seconds); return .success } catch { return .commandFailed }
            }
        }
        remoteTargets.append((center.changePlaybackPositionCommand, seekTarget))
    }

    private func register(_ remote: MPRemoteCommand, command: Command) {
        let target = remote.addTarget { [weak self] _ in
            Self.onMain {
                guard let self else { return .commandFailed }
                do {
                    switch command {
                    case .play: try self.play()
                    case .pause: self.pause()
                    case .stop: self.stop()
                    default: return .commandFailed
                    }
                    return .success
                } catch { return .commandFailed }
            }
        }
        remoteTargets.append((remote, target))
    }

    nonisolated private static func onMain(_ action: @MainActor @Sendable () -> MPRemoteCommandHandlerStatus) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread { return MainActor.assumeIsolated { action() } }
        return DispatchQueue.main.sync { action() }
    }

    private func updateNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        let hasItem = mediaItem != nil && failure == nil
        center.playCommand.isEnabled = hasItem && !loading && snapshot.externalPlaybackActive && !probing
        center.pauseCommand.isEnabled = hasItem
        center.stopCommand.isEnabled = hasItem || loading
        center.togglePlayPauseCommand.isEnabled = center.playCommand.isEnabled
        center.changePlaybackPositionCommand.isEnabled = center.playCommand.isEnabled && !snapshot.seekableRanges.isEmpty
        let info = MPNowPlayingInfoCenter.default()
        if hasItem {
            var metadata: [String: Any] = [MPMediaItemPropertyTitle: title,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
                MPNowPlayingInfoPropertyPlaybackRate: probing ? 0 : player.rate,
                MPNowPlayingInfoPropertyIsLiveStream: snapshot.isLive]
            if let position = snapshot.position { metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
            if let duration = snapshot.duration { metadata[MPMediaItemPropertyPlaybackDuration] = duration }
            info.nowPlayingInfo = metadata
            info.playbackState = snapshot.state == .playing ? .playing : .paused
        } else { info.nowPlayingInfo = nil; info.playbackState = .stopped }
        let needsActivity = snapshot.state == .playing || snapshot.state == .buffering
        if needsActivity && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "AirPlay video playback")
        } else if !needsActivity, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
