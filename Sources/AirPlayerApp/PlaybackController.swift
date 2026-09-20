import Foundation
import AVFoundation
import MediaPlayer
import Combine
#if SWIFT_PACKAGE
import AirPlayerCore
#endif

@MainActor
final class PlaybackController: ObservableObject {
    private struct QueueState {
        let title: String
        let entries: [PlaylistEntry]
        let truncated: Bool
        var currentIndex: Int
        var skipped: Set<Int> = []
    }

    let player = AVPlayer()
    @Published private(set) var snapshot = PlaybackSnapshot()
    @Published private(set) var notice: String?
    @Published private(set) var pendingSeek: Double?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var drainingLoads: [UUID: Task<Void, Never>] = [:]
    private var loadingAsset: AVURLAsset?
    private var timeoutTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var generation = UUID()
    private var loading = false
    private var resolving = false
    private var preparing = false
    private var selectedSource: ResolvedSource?
    private var preparedMedia: PreparedMedia?
    private let prepareSource: (@Sendable (ResolvedSource) async throws -> PreparedMedia)?
    private var websiteURL: URL?
    private var retriedResolution = false
    private let resolveSource: @Sendable (URL) async throws -> ResolvedSource
    private let resolvePlaylist: @Sendable (URL) async throws -> ResolvedPlaylist
    private let afterPlaybackBehavior: @MainActor () -> AfterPlaybackBehavior
    private var ended = false
    private var hasPlayed = false
    private var probing = false
    private var probePrerollFinished = false
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
    private var queue: QueueState?
    private var queueDirection = 1
    private var queueAttemptsRemaining = 0
    private var playWhenReady = false

    init(resolveSource: @escaping @Sendable (URL) async throws -> ResolvedSource = {
        try await SourceResolver().resolve($0)
    }, resolvePlaylist: @escaping @Sendable (URL) async throws -> ResolvedPlaylist = {
        try await SourceResolver().resolvePlaylist($0)
    }, prepareSource: (@Sendable (ResolvedSource) async throws -> PreparedMedia)? = {
        try await MediaPreparer().prepare($0)
    }, afterPlaybackBehavior: @escaping @MainActor () -> AfterPlaybackBehavior = {
        guard let raw = UserDefaults.standard.string(forKey: "afterPlaybackBehavior") else { return .keepConnected }
        return AfterPlaybackBehavior(rawValue: raw) ?? .keepConnected
    }) {
        self.resolveSource = resolveSource
        self.resolvePlaylist = resolvePlaylist
        self.prepareSource = prepareSource
        self.afterPlaybackBehavior = afterPlaybackBehavior
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
        let url = try MediaInput.url(input)
        if SourceResolver.playlistPage(url) != nil {
            startPlaylistLoad(url)
        } else {
            startLoad(url)
        }
    }

    private func startPlaylistLoad(_ url: URL) {
        let retryRoute = hasOpenedPicker || player.isExternalPlaybackActive
        resetItem(keepPlayerItem: true)
        probeWhenReady = retryRoute
        let id = generation
        loading = true
        resolving = true
        title = "YouTube playlist"
        notice = nil
        refresh()
        let resolver = resolvePlaylist
        loadTask = Task { [weak self] in
            defer { self?.drainingLoads.removeValue(forKey: id) }
            do {
                let playlist = try await resolver(url)
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.loadTask = nil
                self.queue = QueueState(title: playlist.title, entries: playlist.entries,
                                        truncated: playlist.truncated, currentIndex: 0)
                self.notice = playlist.truncated
                    ? "This playlist was limited to the first \(SourceResolver.maximumPlaylistEntries) items."
                    : nil
                self.loadQueueItem(at: 0, direction: 1, autoplay: false)
            } catch {
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.fail((error as? ResolutionFailure)?.reason ?? .resolutionFailed)
            }
        }
        drainingLoads[id] = loadTask
    }

    private func startLoad(_ url: URL, retry: Bool = false, fallback: ResolvedSource? = nil,
                           preservingQueue: Bool = false, autoplay: Bool = false,
                           titleOverride: String? = nil) {
        let retryRoute = hasOpenedPicker || player.isExternalPlaybackActive
        resetItem(keepPlayerItem: true, preserveQueue: preservingQueue)
        probeWhenReady = retryRoute
        let id = generation
        loading = true
        resolving = fallback == nil && SourceResolver.isWebsite(url)
        websiteURL = SourceResolver.isWebsite(url) ? url : nil
        retriedResolution = retry
        title = titleOverride ?? url.host ?? "Video"
        playWhenReady = autoplay
        if !preservingQueue { notice = nil }
        refresh()
        let resolver = resolveSource
        loadTask = Task { [weak self] in
            defer { self?.drainingLoads.removeValue(forKey: id) }
            do {
                let source: ResolvedSource
                if let fallback { source = fallback }
                else { source = try await resolver(url) }
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.selectedSource = source
                if let sourceTitle = source.title { self.title = sourceTitle }
                self.resolving = false
                var playbackURL = source.url
                if source.needsPreparation {
                    guard let prepareSource = self.prepareSource else { throw PreparationFailure.unsupported }
                    self.preparing = true
                    self.timeoutTask?.cancel()
                    self.refresh()
                    let prepared = try await prepareSource(source)
                    guard !Task.isCancelled, self.generation == id else {
                        prepared.stop(); await prepared.waitForProducer(); return
                    }
                    self.preparedMedia = prepared
                    if let failure = prepared.productionFailure { throw failure }
                    prepared.onFailure = { [weak self] failure in
                        guard let self, self.generation == id else { return }
                        // The prepared URL already reached this session. A later
                        // producer failure ends it rather than advancing a queue.
                        self.fail(failure.reason, advancingQueue: false)
                    }
                    playbackURL = prepared.url
                    self.preparing = false
                }
                self.scheduleLoadTimeout(id: id)
                self.refresh()
                let asset = AVURLAsset(url: playbackURL)
                self.loadingAsset = asset
                let playable = try await asset.load(.isPlayable)
                let video = try await asset.loadTracks(withMediaType: .video)
                // HLS may expose alternate audio as media-selection options.
                // An inspection error is unknown, not proof of a silent source.
                let audio = try? await asset.loadTracks(withMediaType: .audio)
                let metadataTitle = await self.metadataTitle(from: asset)
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
                guard !Task.isCancelled, self.generation == id, self.failure == nil else { return }
                guard playable else {
                    self.fail(.unreadableMedia)
                    return
                }
                // A routed HLS item can become ready without exposing local
                // video tracks or a presentation size. Preserve the inspected
                // master's video evidence so queue handoff does not wait forever.
                self.hasVideo = source.videoKnownPresent || !video.isEmpty
                self.hasAudio = detectedAudio
                if source.title == nil, let metadataTitle { self.title = metadataTitle }
                let item = AVPlayerItem(asset: asset)
                // EVENT is finite here, but AVPlayer initially treats its growing
                // playlist as live. Keep fetching updates while Load stays paused.
                if self.preparedMedia?.sourceDuration != nil {
                    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                }
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
                        let hasNext = self.queue.map { $0.currentIndex + 1 < $0.entries.count } ?? false
                        if QueuePolicy.shouldAdvanceAfterEnd(hasPlayed: self.hasPlayed,
                            externalPlaybackActive: self.player.isExternalPlaybackActive,
                            isProbing: self.probing, hasNext: hasNext) {
                            self.loadQueueItem(at: (self.queue?.currentIndex ?? -1) + 1,
                                               direction: 1, autoplay: true)
                        } else if self.queue != nil {
                            self.ended = true
                            self.player.pause()
                            if !hasNext { self.notice = "End of playlist." }
                            self.refresh()
                        } else if self.afterPlaybackBehavior() == .unloadVideo {
                            self.stop()
                            self.notice = "Playback finished. The video was unloaded."
                        } else {
                            self.ended = true
                            self.player.pause()
                            self.refresh()
                        }
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
                self.fail((error as? PreparationFailure)?.reason ?? (error as? ResolutionFailure)?.reason
                    ?? MediaDiagnostics.reason(for: error, fallback: .loadFailed))
            }
        }
        drainingLoads[id] = loadTask
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
        playWhenReady = false
        probeWhenReady = false
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

    func previous() throws {
        guard let queue, queue.currentIndex > 0 else {
            throw AppFailure(.unsupportedOperation, "There is no previous playlist item.")
        }
        let autoplay = hasPlayed && player.rate > 0 && player.isExternalPlaybackActive
        loadQueueItem(at: queue.currentIndex - 1, direction: -1, autoplay: autoplay)
    }

    func next() throws {
        guard let queue, queue.currentIndex + 1 < queue.entries.count else {
            throw AppFailure(.unsupportedOperation, "There is no next playlist item.")
        }
        let autoplay = hasPlayed && player.rate > 0 && player.isExternalPlaybackActive
        loadQueueItem(at: queue.currentIndex + 1, direction: 1, autoplay: autoplay)
    }

    private func loadQueueItem(at requestedIndex: Int, direction: Int, autoplay: Bool,
                               attemptsRemaining: Int? = nil) {
        guard var queue else { return }
        var attempts = attemptsRemaining ?? queue.entries.count
        var index = requestedIndex
        var skippedTitles: [String] = []
        while attempts > 0, queue.entries.indices.contains(index), queue.entries[index].url == nil {
            queue.skipped.insert(index)
            skippedTitles.append(queue.entries[index].title)
            index += direction
            attempts -= 1
        }
        guard attempts > 0, queue.entries.indices.contains(index), let url = queue.entries[index].url else {
            self.queue = queue
            resetItem(preserveQueue: true)
            title = queue.title
            notice = skippedTitles.isEmpty ? "No more playable playlist items." : "Skipped unavailable items. No more playable playlist items."
            refresh()
            return
        }
        queue.currentIndex = index
        self.queue = queue
        queueDirection = direction
        queueAttemptsRemaining = attempts
        if !skippedTitles.isEmpty { notice = "Skipped \(skippedTitles.count) unavailable playlist item\(skippedTitles.count == 1 ? "" : "s")." }
        startLoad(url, preservingQueue: true, autoplay: autoplay, titleOverride: queue.entries[index].title)
    }

    func seek(_ seconds: Double) throws {
        try MediaInput.validateSeek(seconds, ranges: snapshot.seekableRanges)
        guard !probing else { throw AppFailure(.unsupportedOperation, "Wait for the receiver connection to finish.") }
        guard player.isExternalPlaybackActive else {
            throw AppFailure(.routeRequired, "Choose a video receiver first.")
        }
        ended = false
        pendingSeek = seconds
        let id = generation
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.pendingSeek = nil
                self.refresh()
            }
        }
        refresh()
    }

    func goLive() throws {
        guard snapshot.isLive, let range = snapshot.seekableRanges.last else {
            throw AppFailure(.unsupportedOperation, "This video is not a live stream.")
        }
        let preferred = finite(mediaItem?.recommendedTimeOffsetFromLive.seconds ?? .nan) ?? 0
        try seek(max(range.start, range.end - preferred))
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
        guard probeWhenReady, mediaItem?.status == .readyToPlay, !loading, !playWhenReady else { return }
        if failure != nil {
            probeWhenReady = false
            return
        }
        guard !probing else { return }
        probeWhenReady = false
        probePosition = finite(player.currentTime().seconds) ?? 0
        probing = true
        probePrerollFinished = false
        player.isMuted = true
        let id = generation
        player.preroll(atRate: 1) { [weak self] finished in
            Task { @MainActor in
                guard finished, let self, self.generation == id, self.probing else { return }
                self.probePrerollFinished = true
                self.finishProbeIfReady()
            }
        }
        scheduleProbeTimeout(seconds: pickerIsOpen ? 30 : 12)
    }

    private func finishProbeIfReady() {
        guard probing, probePrerollFinished, player.isExternalPlaybackActive else { return }
        cancelProbe(restorePosition: true)
        notice = "Connected. Press Play when you’re ready."
        refresh()
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
        player.cancelPendingPrerolls()
        probePrerollFinished = false
        guard probing else { return }
        probing = false
        player.pause()
        if restorePosition, player.currentItem?.status == .readyToPlay {
            player.seek(to: CMTime(seconds: probePosition, preferredTimescale: 600))
        }
    }

    private func stopPreparedMedia() {
        guard let prepared = preparedMedia else { return }
        preparedMedia = nil
        prepared.stop()
        let id = UUID()
        drainingLoads[id] = Task { [weak self] in
            await prepared.waitForProducer()
            self?.drainingLoads.removeValue(forKey: id)
        }
    }

    private func resetItem(keepPlayerItem: Bool = false, preserveQueue: Bool = false) {
        generation = UUID()
        loadTask?.cancel(); loadTask = nil
        loadingAsset?.cancelLoading(); loadingAsset = nil
        timeoutTask?.cancel(); timeoutTask = nil
        cancelProbe(restorePosition: false)
        player.isMuted = true
        player.pause()
        itemObservations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        mediaItem = nil
        pendingSeek = nil
        probeWhenReady = false
        pickerIsOpen = false
        // Direct sources can retain the old paused item. Prepared media must be
        // detached before closing its server and deleting its file.
        if !keepPlayerItem || preparedMedia != nil { player.replaceCurrentItem(with: nil) }
        stopPreparedMedia()
        loading = false; resolving = false; preparing = false; websiteURL = nil; retriedResolution = false
        selectedSource = nil
        ended = false; hasPlayed = false; failure = nil; failureReason = nil
        playWhenReady = false
        hasAudio = nil
        hasVideo = false
        wasExternal = player.isExternalPlaybackActive
        if !preserveQueue {
            queue = nil
            queueAttemptsRemaining = 0
        }
    }

    private func fail(_ reason: MediaFailureReason, message: String? = nil, advancingQueue: Bool = true) {
        // A producer failure may cancel an in-flight asset load. Preserve the
        // original diagnosis when that cancellation subsequently reports back.
        guard failure == nil else { return }
        // A stale signed source may fail during initial loading. Resolve once more,
        // still paused. Never restart established playback or retry indefinitely.
        if reason == .sourceUnavailable, let websiteURL, !retriedResolution, !hasPlayed {
            startLoad(websiteURL, retry: true, preservingQueue: queue != nil,
                      autoplay: playWhenReady, titleOverride: queue.map { $0.entries[$0.currentIndex].title })
            return
        }
        if !hasPlayed, prepareSource != nil, let selectedSource,
           let fallback = MediaSelector.remuxFallback(for: selectedSource, reason: reason) {
            startLoad(websiteURL ?? selectedSource.url, retry: retriedResolution, fallback: fallback,
                      preservingQueue: queue != nil, autoplay: playWhenReady,
                      titleOverride: title)
            return
        }
        if advancingQueue, var queue, queueAttemptsRemaining > 1 {
            queue.skipped.insert(queue.currentIndex)
            let failedTitle = queue.entries[queue.currentIndex].title
            let nextIndex = queue.currentIndex + queueDirection
            self.queue = queue
            notice = "Skipped “\(failedTitle)” because it could not be played."
            loadQueueItem(at: nextIndex, direction: queueDirection, autoplay: playWhenReady,
                          attemptsRemaining: queueAttemptsRemaining - 1)
            return
        }
        resolving = false
        preparing = false
        cancelProbe(restorePosition: false)
        loading = false
        failureReason = reason
        failure = message ?? reason.message
        player.isMuted = true
        player.pause()
        timeoutTask?.cancel()
        player.replaceCurrentItem(with: nil)
        loadingAsset?.cancelLoading(); loadingAsset = nil
        mediaItem = nil
        itemObservations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        stopPreparedMedia()
        refresh()
    }

    private func finite(_ number: Double) -> Double? { number.isFinite && number >= 0 ? number : nil }

    private func metadataTitle(from asset: AVURLAsset) async -> String? {
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        let candidates = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
        guard let first = candidates.first,
              let value = try? await first.load(.stringValue) else { return nil }
        let cleaned = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(200))
    }

    func refresh() {
        // Receiver-side controls must not resume a retained old item or a new
        // item whose video tracks are still being confirmed.
        if (mediaItem == nil || loading || failure != nil) && player.currentItem != nil {
            player.isMuted = true
            // Repeated pause requests while an already-paused EVENT item loads
            // can interrupt AVPlayer's initial buffering before it becomes ready.
            if player.rate != 0 || player.timeControlStatus != .paused { player.pause() }
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
        if probing && external { finishProbeIfReady() }
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
                fail(.noVideo)
                return
            }
            // With incomplete track information, stay loading until observation
            // supplies video evidence or the existing bounded load timeout expires.
        }
        beginProbeIfReady()
        if playWhenReady, !loading, item?.status == .readyToPlay {
            playWhenReady = false
            if external && !probing {
                probeWhenReady = false
                hasPlayed = true
                player.isMuted = false
                player.play()
            } else {
                notice = "Next playlist item is ready. Choose a receiver, then press Play."
            }
        }
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
        next.loadingPhase = resolving ? "resolving" : (preparing ? "preparing" : nil)
        next.playbackPath = failure == nil ? selectedSource?.playbackPath : nil
        next.hasAudio = hasAudio
        if let queue {
            next.queue = PlaybackQueueSnapshot(title: queue.title, currentIndex: queue.currentIndex,
                items: queue.entries.indices.map { index in
                    QueueItemSnapshot(title: queue.entries[index].title,
                        state: index == queue.currentIndex ? .current : (queue.skipped.contains(index) ? .skipped : .pending))
                }, truncated: queue.truncated)
        }
        next.duration = preparedMedia?.sourceDuration ?? item.flatMap { finite($0.duration.seconds) }
        next.position = item == nil ? nil : finite(player.currentTime().seconds)
        next.seekableRanges = (item?.seekableTimeRanges ?? []).compactMap {
            let range = $0.timeRangeValue
            guard let start = finite(range.start.seconds), let end = finite(CMTimeRangeGetEnd(range).seconds), end > start else { return nil }
            return SeekRange(start: start, end: end)
        }
        next.isLive = item?.status == .readyToPlay && LivePolicy.isLive(
            sourceDuration: preparedMedia?.sourceDuration,
            itemDurationIndefinite: item?.duration.isIndefinite == true)
        if next.isLive, let position = next.position, let edge = next.seekableRanges.last?.end {
            next.liveOffset = max(0, edge - position)
        }
        if let item {
            var diagnostics = PlaybackDiagnostics()
            diagnostics.itemStatus = switch item.status {
            case .unknown: "unknown"
            case .readyToPlay: "ready"
            case .failed: "failed"
            @unknown default: "other"
            }
            diagnostics.playerStatus = switch player.status {
            case .unknown: "unknown"
            case .readyToPlay: "ready"
            case .failed: "failed"
            @unknown default: "other"
            }
            diagnostics.timeControlStatus = switch player.timeControlStatus {
            case .paused: "paused"
            case .waitingToPlayAtSpecifiedRate: "waiting"
            case .playing: "playing"
            @unknown default: "other"
            }
            diagnostics.videoConfirmed = hasVideo
            diagnostics.waitingReason = waitingReason(player.reasonForWaitingToPlay)
            diagnostics.bufferedRanges = item.loadedTimeRanges.compactMap {
                let range = $0.timeRangeValue
                guard let start = finite(range.start.seconds),
                      let end = finite(CMTimeRangeGetEnd(range).seconds), end > start else { return nil }
                return SeekRange(start: start, end: end)
            }
            diagnostics.bufferEmpty = item.isPlaybackBufferEmpty
            diagnostics.bufferFull = item.isPlaybackBufferFull
            diagnostics.likelyToKeepUp = item.isPlaybackLikelyToKeepUp
            if let event = item.accessLog()?.events.last {
                diagnostics.observedBitrate = finite(event.observedBitrate)
                diagnostics.indicatedBitrate = finite(event.indicatedBitrate)
                diagnostics.stalls = event.numberOfStalls
            }
            next.diagnostics = diagnostics
        }
        next.state = PlaybackPolicy.state(hasItem: item != nil || loading || failure != nil,
            failed: failure != nil, ready: item?.status == .readyToPlay && !loading,
            connecting: probing, external: external, ended: ended,
            playing: player.timeControlStatus == .playing, waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            hasPlayed: hasPlayed)
        if snapshot != next { snapshot = next }
        updateNowPlaying()
    }

    private func waitingReason(_ reason: AVPlayer.WaitingReason?) -> PlaybackWaitingReason? {
        switch reason {
        case .toMinimizeStalls: .minimizingStalls
        case .evaluatingBufferingRate: .evaluatingBufferingRate
        case .noItemToPlay: .noItem
        case .some: .other
        case nil: nil
        }
    }

    func displayError(_ error: Error) {
        notice = (error as? AppFailure)?.message ?? "The action could not be completed. Please try again."
    }

    func clearNotice() { notice = nil }

    /// Quit waits for cancelled jobs to reap their helpers and release temporary files.
    func shutdownAndWait() async {
        shutdown()
        let pending = Array(drainingLoads.values)
        for job in pending { await job.value }
    }

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
        register(center.previousTrackCommand, command: .previous)
        register(center.nextTrackCommand, command: .next)
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
                    case .previous: try self.previous()
                    case .next: try self.next()
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
        center.previousTrackCommand.isEnabled = queue.map { $0.currentIndex > 0 } ?? false
        center.nextTrackCommand.isEnabled = queue.map { $0.currentIndex + 1 < $0.entries.count } ?? false
        let info = MPNowPlayingInfoCenter.default()
        if hasItem {
            var metadata: [String: Any] = [MPMediaItemPropertyTitle: title,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
                MPNowPlayingInfoPropertyPlaybackRate: probing ? 0 : player.rate,
                MPNowPlayingInfoPropertyIsLiveStream: snapshot.isLive]
            if let position = snapshot.position { metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
            if let duration = snapshot.duration { metadata[MPMediaItemPropertyPlaybackDuration] = duration }
            if let queue {
                metadata[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queue.currentIndex
                metadata[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.entries.count
            }
            info.nowPlayingInfo = metadata
            info.playbackState = snapshot.state == .playing ? .playing : .paused
        } else { info.nowPlayingInfo = nil; info.playbackState = .stopped }
        let needsActivity = preparing || snapshot.state == .playing || snapshot.state == .buffering
        if needsActivity && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Preparing or playing AirPlay video")
        } else if !needsActivity, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
