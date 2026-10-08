import Foundation
import AVFoundation
import MediaPlayer
import Combine
#if SWIFT_PACKAGE
import AirThrowCore
#endif

@MainActor
final class PlaybackController: ObservableObject {
    private struct LoadPreferences {
        let conversion: ConversionPolicy
        let preferQuality: Bool
        /// Captured with the load so a delayed resolution uses the enhancement
        /// chosen when the user asked for it, not a later UI change.
        let enhancement: VideoEnhancement
        let enhancementOutput4K: Bool
        /// Keeps Automatic's current presentation while its processing preset
        /// changes, without turning it into an explicit source choice in status.
        let pinnedSourceID: String?
        let subtitle: SubtitlePreference?
        var resumePosition: Double? = nil
        var resumeDuration: Double? = nil
    }
    private enum SubtitlePreference {
        case off
        case track(language: String?, name: String)
    }
    private struct QueueState {
        let title: String
        let entries: [PlaylistEntry]
        let truncated: Bool
        var currentIndex: Int
        var skipped: Set<Int> = []
    }

    let player: AVPlayer
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
    private var probeRestoreTask: Task<Void, Never>?
    private var probeRestoreSeekID: UUID?
    private var probeRestoreSeekFinished: Bool?
    private var generation = UUID()
    private var seekID: UUID?
    private var seekPreparationTask: Task<Void, Never>?
    private var seekTimeoutTask: Task<Void, Never>?
    private var seekPlayWhenReady = false
    private var seekPreparationReady = false
    private var seekNativeFinished: Bool?
    private var probeID = UUID()
    private var loadPreferences: LoadPreferences?
    private var loading = false
    private var resolving = false
    private var preparing = false
    private var selectedSource: ResolvedSource?
    private var selectedQuality: String?
    /// Per-item enhancement preference captured for the current item. Reset to
    /// `.original` for every new item; a source-quality change keeps it.
    private var videoEnhancement: VideoEnhancement = .original
    @Published private(set) var enhancementOutput4K = false
    private var inspectedSourceHeight: (url: URL, height: Double)?
    func sourceHeight(for sourceID: String? = nil) -> Double? {
        let source: ResolvedSource?
        let height: Double?
        if let sourceID {
            if sourceID == "automatic" {
                source = try? MediaSelector.select(sourceCandidates, policy: effectiveConversionPolicy,
                                                    preferQuality: preferQuality)
                height = source.flatMap { Self.candidatesHeight(for: $0, in: sourceCandidates) }
            } else if let index = sourceCandidates.indices.first(where: { sourceOptionID($0) == sourceID }) {
                source = sourceCandidates[index].source
                height = sourceCandidates[index].height
            } else { return nil }
        } else {
            source = selectedSource
            height = source.flatMap { Self.candidatesHeight(for: $0, in: sourceCandidates) }
        }
        return height ?? (inspectedSourceHeight?.url == source?.url ? inspectedSourceHeight?.height : nil)
    }
    func canUpscale(output4K: Bool, sourceID: String? = nil) -> Bool {
        guard let height = sourceHeight(for: sourceID) else { return true }
        return height < (output4K ? 2160 : 1080)
    }
    var requires4KOutput: Bool {
        (sourceHeight() ?? 0) > 1080
    }
    func requires4KOutput(for sourceID: String?) -> Bool {
        (sourceHeight(for: sourceID) ?? 0) > 1080
    }
    private var originalSourceURL: URL?
    private var sourceCandidates: [MediaCandidate] = []
    private var sourceChoice: String?
    private var selectedNativeAudioID: String?
    private var nativeAudioGroup: AVMediaSelectionGroup?
    private var nativeSubtitleGroup: AVMediaSelectionGroup?
    private var subtitlePreference: SubtitlePreference?
    private var changingSource = false
    private var sourceOptionsGeneration = UUID()
    private var actualPlaybackPath: PlaybackPath?
    @Published private(set) var allowVideoConversion: Bool
    @Published private(set) var preferQuality: Bool
    private var preparedMedia: PreparedMedia?
    private var retiredPreparedMedia: PreparedMedia?
    private let prepareSource: (@Sendable (ResolvedSource) async throws -> PreparedMedia)?
    private var websiteURL: URL?
    private var retriedResolution = false
    private let resolveCandidates: @Sendable (URL) async throws -> [MediaCandidate]
    private let resolvePlaylist: @Sendable (URL) async throws -> ResolvedPlaylist
    private let afterPlaybackBehavior: @MainActor () -> AfterPlaybackBehavior
    private var ended = false
    private var hasPlayed = false
    private var probing = false
    private var probeRestoring = false
    private var probeRestoreFailed = false
    private var hasOpenedPicker = false
    private var pickerIsOpen = false
    private var probeWhenReady = false
    // The requested item is separate from the paused item retained in AVPlayer
    // while its replacement loads. Routing belongs to the long-lived player.
    private var mediaItem: AVPlayerItem?
    @Published private(set) var showReceiverWaitingScreen: Bool
    private let waitingScreenURL: () -> URL?
    private lazy var waitingScreen = ReceiverWaitingScreen(player: player, mediaURL: waitingScreenURL,
        changed: { [weak self] in self?.refresh() },
        failed: { [weak self] in self?.notice = "The TV waiting screen could not be opened. You can still load a video." })
    private var probePosition: Double = 0
    private var wasExternal = false
    private var failure: String?
    private var failureReason: MediaFailureReason?
    private var hasAudio: Bool?
    private var hasVideo = false
    private var title = "No video loaded"
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var activity: NSObjectProtocol?
    // AVPlayer can briefly report paused during an active AirPlay session.
    // Keep idle sleep prevention tied to the requested session, not that sample.
    private var playbackRequested = false
    private var queue: QueueState?
    private var queueDirection = 1
    private var queueAttemptsRemaining = 0
    private var playWhenReady = false
    private var pendingAutoplaySeek = false
    private var autoplayRouteTask: Task<Void, Never>?
    private var autoplayRouteDeadline: ContinuousClock.Instant?
    private var replacementPlayTask: Task<Void, Never>?
    private var pendingInitialSeek = false
    private var pendingResumePosition: Double?
    // A receiver chosen in the system picker sets the active route before the
    // picker reports that it finished presenting. Allow a bounded window for
    // the selected route to become active before ending a muted negotiation.
    private static let pickerDismissalGrace: Double = 12
    private static let pickerOpenProbeTimeout: Double = 30
    private static let routeProbeTimeout: Double = 12

    init(player: AVPlayer = AVPlayer(),
         showReceiverWaitingScreen: Bool? = nil,
         waitingScreenURL: @escaping () -> URL? = { Bundle.main.url(forResource: "WaitingScreen", withExtension: nil) },
         resolveSource: (@Sendable (URL) async throws -> ResolvedSource)? = nil,
         resolveCandidates: (@Sendable (URL) async throws -> [MediaCandidate])? = nil,
         allowVideoConversion: Bool? = nil,
         preferQuality: Bool? = nil,
         resolvePlaylist: @escaping @Sendable (URL) async throws -> ResolvedPlaylist = {
        try await SourceResolver(sessions: WebsiteCookiePreference.current()).resolvePlaylist($0)
    }, prepareSource: (@Sendable (ResolvedSource) async throws -> PreparedMedia)? = {
        try await MediaPreparer(preferences: .current()).prepare($0)
    }, afterPlaybackBehavior: @escaping @MainActor () -> AfterPlaybackBehavior = {
        guard let raw = UserDefaults.standard.string(forKey: "afterPlaybackBehavior") else { return .keepConnected }
        return AfterPlaybackBehavior(rawValue: raw) ?? .keepConnected
    }) {
        self.player = player
        self.showReceiverWaitingScreen = showReceiverWaitingScreen ?? UserDefaults.standard.bool(forKey: "showReceiverWaitingScreen")
        self.waitingScreenURL = waitingScreenURL
        if let resolveCandidates { self.resolveCandidates = resolveCandidates }
        else if let resolveSource {
            self.resolveCandidates = { [MediaCandidate(source: try await resolveSource($0))] }
        } else { self.resolveCandidates = { try await SourceResolver(sessions: WebsiteCookiePreference.current()).candidates(for: $0) } }
        self.allowVideoConversion = allowVideoConversion ?? (ConversionPolicy.current() == .allowVideo)
        self.preferQuality = preferQuality ?? UserDefaults.standard.bool(forKey: "preferHigherQuality")
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
        updateNowPlaying()
    }

    func load(_ input: String, autoplay: Bool = false) throws {
        let url = try MediaInput.source(input)
        // Picker intent is not an active route. Never arm an incoming request
        // to start later merely because a receiver may subsequently connect.
        let shouldPlay = autoplay && player.isExternalPlaybackActive
        if SourceResolver.playlistPage(url) != nil {
            startPlaylistLoad(url, autoplay: shouldPlay)
        } else {
            startLoad(url, autoplay: shouldPlay)
        }
        if autoplay && !shouldPlay {
            notice = "Video will load paused. Choose a receiver using AirPlay, then press Play."
        }
    }

    private var conversionPolicy: ConversionPolicy { allowVideoConversion ? .allowVideo : .avoidVideo }

    private var effectiveConversionPolicy: ConversionPolicy { conversionPolicy }

    /// Controls that require the installed item still wait for loading. Source
    /// and enhancement changes can cancel an in-flight load once discovery has
    /// supplied candidates; generation guards discard its late results.
    private var loadInProgress: Bool { loading || resolving || preparing }

    func setVideoConversionAllowed(_ allowed: Bool) {
        allowVideoConversion = allowed
        UserDefaults.standard.set(allowed, forKey: ConversionPolicy.preferenceKey)
        if !allowed, let url = originalSourceURL,
           videoEnhancement != .original || preparedMedia?.playbackPath == .videoConversion
            || selectedSource?.playbackPath == .videoConversion || loadInProgress {
            // Enabling the restriction also cancels an active or pending encode.
            startLoad(url, preservingQueue: queue != nil, titleOverride: title,
                      sourceChoice: sourceChoice, changingSource: true, enhancement: .original,
                      enhancementOutput4K: enhancementOutput4K)
            return
        }
        refresh()
    }

    func setShowReceiverWaitingScreen(_ enabled: Bool) {
        showReceiverWaitingScreen = enabled
        UserDefaults.standard.set(enabled, forKey: "showReceiverWaitingScreen")
        if !enabled { waitingScreen.stop() }
        refresh()
    }

    func setPreferQuality(_ enabled: Bool) {
        preferQuality = enabled
        UserDefaults.standard.set(enabled, forKey: "preferHigherQuality")
        refresh()
    }

    /// Choices reload freshly resolved URLs and preserve position, play intent and player/queue.
    /// An ID from an earlier source can never choose a different current item.
    func selectSource(_ optionID: String) throws {
        guard let url = originalSourceURL, !sourceCandidates.isEmpty else {
            throw AppFailure(.unsupportedOperation, "Wait for source discovery to finish.")
        }
        let candidateID: String?
        if optionID == "automatic" { candidateID = nil }
        else {
            guard let index = sourceCandidates.indices.first(where: { sourceOptionID($0) == optionID }) else {
                throw AppFailure(.invalidRequest, "This source choice has expired. List sources again.")
            }
            let candidate = sourceCandidates[index]
            guard sourceCandidates.filter({ $0.id == candidate.id }).count == 1 else {
                throw AppFailure(.unsupportedOperation, "This source cannot be identified uniquely. Choose Automatic.")
            }
            if let reason = candidate.unavailableReason(for: effectiveConversionPolicy) {
                throw AppFailure(.unsupportedOperation, reason)
            }
            candidateID = candidate.id
        }
        startLoad(url, preservingQueue: queue != nil, titleOverride: title, sourceChoice: candidateID,
                  changingSource: true, enhancement: videoEnhancement,
                  enhancementOutput4K: enhancementOutput4K)
    }

    /// A video choice keeps the current language if the new paired video offers it.
    func selectVideo(_ optionID: String) throws {
        guard optionID != "automatic",
              let index = sourceCandidates.indices.first(where: { sourceOptionID($0) == optionID }) else {
            try selectSource(optionID)
            return
        }
        let picked = sourceCandidates[index]
        guard picked.source.audio != nil, let language = preferredAudioLanguage else {
            try selectSource(optionID)
            return
        }
        let matching = sourceCandidates.indices.first { candidateIndex in
            let candidate = sourceCandidates[candidateIndex]
            return candidate.source.url == picked.source.url
                && candidate.source.headers == picked.source.headers
                && candidate.source.playbackPath == picked.source.playbackPath
                && candidate.audioDescription?.components(separatedBy: " · ").first == language
                && candidate.unavailableReason(for: effectiveConversionPolicy) == nil
        }
        try selectSource(sourceOptionID(matching ?? index))
    }

    private var preferredAudioLanguage: String? {
        if let selectedNativeAudioID {
            return selectedSource?.hlsAudioOptions.first(where: { $0.id == selectedNativeAudioID })?.language
        }
        guard let selectedSource else { return nil }
        return sourceCandidates.first {
            $0.source.url == selectedSource.url && $0.source.audio?.url == selectedSource.audio?.url
        }?.audioDescription?.components(separatedBy: " · ").first
    }

    /// Native HLS audio changes on the installed item. A paired-file audio
    /// choice uses the existing source reload so its tracks remain in sync.
    func selectAudio(_ optionID: String) throws {
        guard !loadInProgress, let selectedSource else {
            throw AppFailure(.unsupportedOperation, "Wait for the video to finish loading.")
        }
        guard let choice = audioChoices.first(where: { $0.snapshot.id == optionID }) else {
            throw AppFailure(.invalidRequest, "This audio choice has expired. Open Audio again.")
        }
        switch choice.kind {
        case .native(let index):
            guard let item = mediaItem, let group = nativeAudioGroup,
                  selectedSource.hlsAudioOptions.indices.contains(index),
                  let option = Self.matchAudio(selectedSource.hlsAudioOptions[index], in: group) else {
                throw AppFailure(.unsupportedOperation, "This audio track is unavailable in the direct stream.")
            }
            player.appliesMediaSelectionCriteriaAutomatically = false
            item.select(option, in: group)
            selectedNativeAudioID = selectedSource.hlsAudioOptions[index].id
            refresh()
        case .candidate(let index):
            try selectSource(sourceOptionID(index))
        }
    }

    /// Select an AVFoundation legible option on the installed item. The
    /// receiver keeps its native subtitle rendering and can change this group
    /// independently; no video conversion or local overlay is involved.
    func selectSubtitle(_ optionID: String) throws {
        guard !loadInProgress, let item = mediaItem, let group = nativeSubtitleGroup else {
            throw AppFailure(.unsupportedOperation, "Wait for the video and subtitle tracks to finish loading.")
        }
        let prefix = "\(sourceOptionsGeneration.uuidString)-subtitle-"
        if optionID == prefix + "off" {
            guard group.allowsEmptySelection else {
                throw AppFailure(.unsupportedOperation, "This subtitle track cannot be turned off.")
            }
            item.select(nil, in: group)
            subtitlePreference = .off
        } else {
            guard optionID.hasPrefix(prefix), let index = Int(optionID.dropFirst(prefix.count)),
                  group.options.indices.contains(index) else {
                throw AppFailure(.invalidRequest, "This subtitle choice has expired. Open Subtitles again.")
            }
            let option = group.options[index]
            item.select(option, in: group)
            subtitlePreference = .track(language: option.locale?.identifier, name: option.displayName)
        }
        refresh()
    }

    /// The popover's resolution control. On Original it only selects the
    /// resolution for the next enhancement. On an active preset it prepares the
    /// matching output and reloads at the current position through the existing item path.
    func setEnhancementOutput4K(_ enabled: Bool) throws {
        guard originalSourceURL != nil, selectedSource != nil else {
            throw AppFailure(.unsupportedOperation, "Wait for source discovery to finish.")
        }
        guard !snapshot.isLive, selectedSource?.isLive != true else {
            throw AppFailure(.unsupportedOperation, "Enhancement is available for on-demand video, not live streams.")
        }
        guard enabled != enhancementOutput4K else { return }
        guard enabled || !requires4KOutput else {
            throw AppFailure(.unsupportedOperation, "This source is above 1080p. Choose 4K to avoid downscaling.")
        }
        switch videoEnhancement {
        case .original:
            enhancementOutput4K = enabled
        case .upscale1080, .upscale4K:
            try selectEnhancement(enabled ? .upscale4K : .upscale1080)
        case .cleanup1080, .cleanup4K:
            try selectEnhancement(enabled ? .cleanup4K : .cleanup1080)
        }
    }

    /// Apply the popover's staged video and enhancement choices in one load.
    /// A nil source ID keeps the current presentation, including its language.
    /// Enhancement cases encode their output resolution; output4K only chooses
    /// the next enhancement's resolution when requesting Original.
    func applyVideoOptions(sourceID: String?, enhancement: VideoEnhancement, output4K: Bool) throws {
        try requireEnhancementAllowed(enhancement)
        guard let url = originalSourceURL, selectedSource != nil else {
            throw AppFailure(.unsupportedOperation, "Wait for source discovery to finish.")
        }
        let target4K = enhancement.targetHeight.map { $0 == 2160 }
            ?? (output4K || requires4KOutput(for: sourceID))
        if sourceID == nil {
            if enhancement != videoEnhancement { try selectEnhancement(enhancement) }
            enhancementOutput4K = target4K
            refresh()
            return
        }
        let candidateID: String?
        if sourceID == "automatic" { candidateID = nil }
        else {
            guard let index = sourceCandidates.indices.first(where: { sourceOptionID($0) == sourceID }) else {
                throw AppFailure(.invalidRequest, "This source choice has expired. Open Video options again.")
            }
            let picked = sourceCandidates[index]
            let policy = conversionPolicy
            let matching = picked.source.audio == nil ? nil : sourceCandidates.first { candidate in
                candidate.source.url == picked.source.url && candidate.source.headers == picked.source.headers
                    && candidate.source.playbackPath == picked.source.playbackPath
                    && preferredAudioLanguage != nil
                    && candidate.audioDescription?.components(separatedBy: " · ").first == preferredAudioLanguage
                    && candidate.unavailableReason(for: policy) == nil
            }
            let candidate = matching ?? picked
            guard sourceCandidates.filter({ $0.id == candidate.id }).count == 1 else {
                throw AppFailure(.unsupportedOperation, "This source cannot be identified uniquely. Choose Automatic.")
            }
            if let reason = candidate.unavailableReason(for: policy) {
                throw AppFailure(.unsupportedOperation, reason)
            }
            guard enhancement.targetHeight != 1080 || (candidate.height ?? 0) <= 1080 else {
                throw AppFailure(.unsupportedOperation, "This source is above 1080p. Choose 4K to avoid downscaling.")
            }
            candidateID = candidate.id
        }
        guard enhancement == .original || !snapshot.isLive else {
            throw AppFailure(.unsupportedOperation, "Enhancement is available for on-demand video, not live streams.")
        }
        startLoad(url, preservingQueue: queue != nil, titleOverride: title, sourceChoice: candidateID,
                  changingSource: true, enhancement: enhancement,
                  enhancementOutput4K: target4K)
    }

    /// A per-item enhancement: prepare this item's video on the Mac (upscale or
    /// clean up) and reload at the current position, keeping play/pause, receiver and queue. The current
    /// source choice is preserved when it still resolves; a stale identity fails
    /// closed. A new choice may replace an in-flight load after source discovery.
    /// `.original` restores the untouched source.
    private func requireEnhancementAllowed(_ enhancement: VideoEnhancement) throws {
        guard enhancement == .original || allowVideoConversion else {
            throw AppFailure(.unsupportedOperation, "Turn off Avoid video re-encoding in Settings to use Upscale or Clean up & upscale.")
        }
    }

    func selectEnhancement(_ enhancement: VideoEnhancement) throws {
        try requireEnhancementAllowed(enhancement)
        guard let url = originalSourceURL, selectedSource != nil else {
            throw AppFailure(.unsupportedOperation, "Wait for source discovery to finish.")
        }
        guard !snapshot.isLive, selectedSource?.isLive != true else {
            throw AppFailure(.unsupportedOperation, "Enhancement is available for on-demand video, not live streams.")
        }
        guard enhancement != videoEnhancement else { return }
        guard enhancement.targetHeight != 1080 || !requires4KOutput else {
            throw AppFailure(.unsupportedOperation, "This source is above 1080p. Choose 4K to avoid downscaling.")
        }
        let pinnedSourceID: String?
        if sourceChoice == nil, let selectedSource {
            pinnedSourceID = sourceCandidates.first(where: {
                $0.source.url == selectedSource.url && $0.source.audio?.url == selectedSource.audio?.url
            })?.id
        } else { pinnedSourceID = nil }
        // A direct input is already the presentation being enhanced. Reuse its
        // unmodified plan rather than rediscovering it and pinning an identity
        // whose probe/extractor metadata may change. Website pages still resolve
        // again so expiring extracted URLs and explicit choices are revalidated.
        let directSource = selectedSource.flatMap { selected -> ResolvedSource? in
            guard selected.url == url, selected.audio == nil else { return nil }
            return sourceCandidates.first(where: {
                $0.source.url == selected.url && $0.source.headers == selected.headers && $0.source.audio == nil
            })?.source
        }
        startLoad(url, fallback: directSource, preservingQueue: queue != nil, titleOverride: title, sourceChoice: sourceChoice,
                  changingSource: true, enhancement: enhancement,
                  enhancementOutput4K: enhancement.targetHeight.map { $0 == 2160 } ?? enhancementOutput4K,
                  pinnedSourceID: pinnedSourceID)
    }

    private func sourceOptionID(_ index: Int) -> String { "\(sourceOptionsGeneration.uuidString)-\(index)" }

    private enum AudioChoiceKind { case native(Int), candidate(Int) }
    private struct AudioChoice {
        let snapshot: AudioOptionSnapshot
        let kind: AudioChoiceKind
    }

    private var audioChoices: [AudioChoice] {
        guard let selectedSource else { return [] }
        if selectedSource.delivery == .hls && selectedSource.playbackPath == .direct {
            return selectedSource.hlsAudioOptions.enumerated().map { index, option in
                AudioChoice(snapshot: AudioOptionSnapshot(
                    id: "\(sourceOptionsGeneration.uuidString)-audio-native-\(index)",
                    label: option.name), kind: .native(index))
            }
        }
        guard let current = sourceCandidates.first(where: {
            $0.source.url == selectedSource.url && $0.source.audio?.url == selectedSource.audio?.url
        }), current.source.audio != nil else { return [] }
        return sourceCandidates.enumerated().compactMap { index, candidate in
            guard candidate.source.url == current.source.url,
                  candidate.source.headers == current.source.headers,
                  candidate.source.playbackPath == current.source.playbackPath,
                  let label = candidate.audioDescription else { return nil }
            return AudioChoice(snapshot: AudioOptionSnapshot(
                id: "\(sourceOptionsGeneration.uuidString)-audio-candidate-\(index)",
                label: label,
                unavailableReason: candidate.unavailableReason(for: effectiveConversionPolicy)),
                kind: .candidate(index))
        }
    }

    private static func matchAudio(_ choice: HLSAudioOption, in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        let matches = group.options.filter { option in
            guard let language = choice.language, let locale = option.locale else { return false }
            let wanted = language.lowercased().replacingOccurrences(of: "_", with: "-")
            let available = locale.identifier.lowercased().replacingOccurrences(of: "_", with: "-")
            return available == wanted || available.split(separator: "-").first == wanted.split(separator: "-").first
        }
        if matches.count == 1 { return matches[0] }
        return (matches.isEmpty ? group.options : matches).first {
            $0.displayName.localizedCaseInsensitiveCompare(choice.name) == .orderedSame
        }
    }

    /// Short quality label for a candidate, e.g. "720p60". Frame rate only
    /// appears above 30 so ordinary presentations stay "720p".
    private static func qualityLabel(_ candidate: MediaCandidate) -> String? {
        guard let height = candidate.height else { return nil }
        return qualityLabel(height: Int(min(height, 100_000)), frameRate: candidate.frameRate)
    }

    private static func qualityLabel(height: Int?, frameRate: Double?) -> String? {
        guard let height, height > 0 else { return nil }
        var label = "\(height)p"
        if let frameRate, frameRate.isFinite, frameRate > 30 { label += "\(Int(frameRate))" }
        return label
    }

    /// Match the selected source back to its candidate to recover its quality.
    private static func qualityLabel(for source: ResolvedSource, in candidates: [MediaCandidate]) -> String? {
        guard let candidate = candidates.first(where: {
            $0.source.url == source.url && $0.source.audio?.url == source.audio?.url
        }) else { return nil }
        return qualityLabel(candidate)
    }

    private static func candidatesHeight(for source: ResolvedSource, in candidates: [MediaCandidate]) -> Double? {
        candidates.first {
            $0.source.url == source.url && $0.source.audio?.url == source.audio?.url
        }?.height
    }

    private var sourceOptions: [SourceOptionSnapshot]? {
        guard !sourceCandidates.isEmpty else { return nil }
        return sourceCandidates.enumerated().map { index, candidate in
            let videoIndex = sourceCandidates.firstIndex {
                $0.source.url == candidate.source.url &&
                $0.source.headers == candidate.source.headers &&
                $0.source.playbackPath == candidate.source.playbackPath
            } ?? index
            let quality: String
            if let base = Self.qualityLabel(candidate) {
                quality = base + (candidate.source.delivery == .hls ? " maximum (adaptive)" : "")
            } else { quality = "Quality unknown" }
            return SourceOptionSnapshot(id: sourceOptionID(index), quality: quality,
                audio: candidate.audioDescription, playbackPath: candidate.source.playbackPath,
                unavailableReason: sourceCandidates.filter({ $0.id == candidate.id }).count > 1
                    ? "This source cannot be identified uniquely. Choose Automatic."
                    : candidate.unavailableReason(for: effectiveConversionPolicy),
                videoGroupID: "\(sourceOptionsGeneration.uuidString)-video-\(videoIndex)")
        }
    }

    private func startPlaylistLoad(_ url: URL, autoplay: Bool = false) {
        let retryRoute = hasOpenedPicker || player.isExternalPlaybackActive
        resetItem(keepPlayerItem: true)
        probeWhenReady = retryRoute
        let id = generation
        loading = true
        resolving = true
        playWhenReady = autoplay
        playbackRequested = autoplay
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
                self.notice = self.notice ?? (playlist.truncated
                    ? "This playlist was limited to the first \(SourceResolver.maximumPlaylistEntries) items."
                    : nil)
                self.loadQueueItem(at: 0, direction: 1, autoplay: self.playWhenReady)
            } catch {
                guard let self, !Task.isCancelled, self.generation == id else { return }
                self.fail((error as? ResolutionFailure)?.reason ?? .resolutionFailed)
            }
        }
        drainingLoads[id] = loadTask
    }

    private func startLoad(_ url: URL, retry: Bool = false, fallback: ResolvedSource? = nil,
                           preservingQueue: Bool = false, autoplay: Bool = false,
                           titleOverride: String? = nil, sourceChoice: String? = nil,
                           changingSource: Bool = false, enhancement: VideoEnhancement? = nil,
                           enhancementOutput4K: Bool? = nil,
                           pinnedSourceID: String? = nil,
                           preferences: LoadPreferences? = nil) {
        let resumedPosition = changingSource && !snapshot.isLive
            ? (pendingResumePosition ?? pendingSeek
                ?? ((!loadInProgress && !probing && !probeRestoring)
                    ? finite(player.currentTime().seconds) : snapshot.position)) : nil
        let shouldResumePlaying = changingSource && (playWhenReady || playbackRequested)
        let previouslyPlayed = changingSource && hasPlayed
        let autoplay = autoplay || shouldResumePlaying
        var preferences = preferences ?? LoadPreferences(conversion: conversionPolicy, preferQuality: preferQuality,
                                                         enhancement: enhancement ?? .original,
                                                         enhancementOutput4K: enhancementOutput4K ?? false,
                                                         pinnedSourceID: pinnedSourceID,
                                                         subtitle: changingSource || retry || fallback != nil
                                                            ? subtitlePreference : nil)
        if changingSource {
            preferences.resumePosition = resumedPosition
            preferences.resumeDuration = snapshot.duration ?? loadPreferences?.resumeDuration
        }
        let retryRoute = hasOpenedPicker || player.isExternalPlaybackActive
        let retainedCandidates = fallback == nil ? [] : sourceCandidates
        let retainedInspection = changingSource || retry || fallback != nil ? inspectedSourceHeight : nil
        let retainedAutoplayDeadline = autoplay && (preservingQueue || retry || fallback != nil)
            ? autoplayRouteDeadline : nil
        resetItem(keepPlayerItem: true, preserveQueue: preservingQueue)
        hasPlayed = previouslyPlayed
        inspectedSourceHeight = retainedInspection
        autoplayRouteDeadline = retainedAutoplayDeadline
        loadPreferences = preferences
        pendingResumePosition = preferences.resumePosition
        subtitlePreference = preferences.subtitle
        videoEnhancement = preferences.enhancement
        self.enhancementOutput4K = preferences.enhancementOutput4K
        originalSourceURL = url
        self.sourceChoice = sourceChoice
        self.changingSource = changingSource
        sourceCandidates = retainedCandidates
        probeWhenReady = retryRoute
        let id = generation
        loading = true
        resolving = fallback == nil && SourceResolver.needsResolution(url)
        websiteURL = SourceResolver.needsResolution(url) ? url : nil
        retriedResolution = retry
        title = titleOverride ?? (url.isFileURL ? url.lastPathComponent : (url.host ?? "Video"))
        playWhenReady = autoplay
        pendingAutoplaySeek = autoplay && preferences.resumePosition == nil
        playbackRequested = autoplay
        if !preservingQueue { notice = nil }
        refresh()
        let resolver = resolveCandidates
        let policy = preferences.conversion
        loadTask = Task { [weak self] in
            defer { self?.drainingLoads.removeValue(forKey: id) }
            do {
                var source: ResolvedSource
                if let fallback { source = fallback.withConversionPolicy(policy) }
                else {
                    let candidates = try await resolver(url)
                    guard let self, !Task.isCancelled, self.generation == id else { return }
                    self.sourceCandidates = candidates
                    self.resolving = false
                    self.refresh()
                    if let sourceChoice {
                        // The choice was validated against the presented options.
                        // Re-resolution can change that set, so revalidate the
                        // identity against the freshly resolved candidates before
                        // asking the selector to resolve it: a vanished candidate
                        // keeps its existing recovery message, while a newly
                        // duplicated identity must be refused as ambiguous.
                        let matches = candidates.filter { $0.id == sourceChoice }
                        guard !matches.isEmpty else {
                            throw AppFailure(.unsupportedOperation, "This source is no longer available. Choose Automatic or another source.")
                        }
                        guard matches.count == 1 else {
                            throw AppFailure(.unsupportedOperation, "This source cannot be identified uniquely. Choose Automatic.")
                        }
                    }
                    source = try MediaSelector.select(candidates, policy: policy,
                                                      sourceID: sourceChoice ?? preferences.pinnedSourceID,
                                                      preferQuality: preferences.preferQuality)
                }
                // An explicit enhancement prepares this item's video on the Mac;
                // the source choice above is preserved and only the plan changes.
                guard let self, !Task.isCancelled, self.generation == id else { return }
                var appliedEnhancement = preferences.enhancement
                let sourceHeight = Self.candidatesHeight(for: source, in: self.sourceCandidates)
                if (sourceHeight ?? 0) > 1080 {
                    if appliedEnhancement == .upscale1080 { appliedEnhancement = .upscale4K }
                    if appliedEnhancement == .cleanup1080 { appliedEnhancement = .cleanup4K }
                }
                if appliedEnhancement != .original { source = source.withEnhancement(appliedEnhancement) }
                self.videoEnhancement = appliedEnhancement
                if (sourceHeight ?? 0) > 1080 { self.enhancementOutput4K = true }
                source.preparationPosition = preferences.resumePosition
                self.selectedSource = source
                // Works for the remux fallback too: it reuses the original
                // candidates, so the fallback keeps the source's quality label.
                self.selectedQuality = Self.qualityLabel(for: source, in: self.sourceCandidates)
                if let sourceTitle = source.title { self.title = sourceTitle }
                self.resolving = false
                var playbackURL = source.url
                if source.needsPreparationPipeline {
                    guard let prepareSource = self.prepareSource else { throw PreparationFailure.unsupported }
                    self.preparing = true
                    self.timeoutTask?.cancel()
                    self.refresh()
                    let prepared = try await prepareSource(source)
                    guard !Task.isCancelled, self.generation == id else {
                        prepared.stop(); await prepared.waitForProducer(); return
                    }
                    self.preparedMedia = prepared
                    self.actualPlaybackPath = prepared.playbackPath
                    self.selectedQuality = Self.qualityLabel(height: prepared.videoHeight,
                                                              frameRate: prepared.videoFrameRate)
                        ?? self.selectedQuality
                    if let failure = prepared.productionFailure { throw failure }
                    prepared.onFailure = { [weak self] failure in
                        guard let self, self.generation == id else { return }
                        // The prepared URL already reached this session. A later
                        // producer failure ends it rather than advancing a queue.
                        self.fail(failure.reason, advancingQueue: false)
                    }
                    prepared.onReadyRangesChanged = { [weak self, weak prepared] in
                        guard let self, self.generation == id, self.preparedMedia === prepared else { return }
                        self.refresh()
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
                let audibleGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
                let legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
                let metadataTitle = await self.metadataTitle(from: asset)
                var detectedAudio: Bool?
                if let audio {
                    if !audio.isEmpty {
                        detectedAudio = true
                    } else {
                        // Empty AVAsset tracks/options are inconclusive for HLS.
                        detectedAudio = audibleGroup?.options.isEmpty == false ? true : (video.isEmpty ? nil : false)
                    }
                }
                guard !Task.isCancelled, self.generation == id, self.failure == nil else { return }
                guard playable else {
                    self.fail(.unreadableMedia)
                    return
                }
                var videoConfirmed = source.needsPreparation || source.videoKnownPresent || !video.isEmpty
                if !videoConfirmed {
                    // Streaming assets can hide their tracks after an AirPlay
                    // handoff. Inspect the presentation itself without relying
                    // on a file extension, provider, or previously loaded item.
                    videoConfirmed = await HLSVideoEvidence.hasVideo(at: playbackURL)
                }
                guard !Task.isCancelled, self.generation == id, self.failure == nil else { return }
                // A routed HLS item can become ready without exposing local
                // video tracks or a presentation size. Preserve inspected
                // presentation evidence so queue handoff does not wait forever.
                // Preparation returns only after ffprobe has selected a supported
                // video stream. Once routed, AVPlayer may expose no local tracks,
                // so retain that evidence just as we do for inspected native HLS.
                self.hasVideo = videoConfirmed
                self.hasAudio = detectedAudio
                if source.title == nil, let metadataTitle { self.title = metadataTitle }
                let item = AVPlayerItem(asset: asset)
                self.nativeAudioGroup = nil
                self.selectedNativeAudioID = nil
                self.nativeSubtitleGroup = legibleGroup?.options.isEmpty == false ? legibleGroup : nil
                if source.delivery == .hls, source.playbackPath == .direct,
                   let group = audibleGroup, !source.hlsAudioOptions.isEmpty {
                    self.nativeAudioGroup = group
                    // YouTube can mark both the original and a dub DEFAULT=NO.
                    // Prefer the explicitly identified original over the Mac's
                    // system language, then the manifest's default if present.
                    let preferred = source.hlsAudioOptions.first(where: { $0.isOriginal })
                        ?? source.hlsAudioOptions.first(where: { $0.isDefault })
                    if let preferred, let option = Self.matchAudio(preferred, in: group) {
                        self.player.appliesMediaSelectionCriteriaAutomatically = false
                        item.select(option, in: group)
                        self.selectedNativeAudioID = preferred.id
                    } else {
                        self.player.appliesMediaSelectionCriteriaAutomatically = true
                    }
                } else {
                    self.player.appliesMediaSelectionCriteriaAutomatically = true
                }
                if let group = self.nativeSubtitleGroup, let preference = self.subtitlePreference {
                    switch preference {
                    case .off:
                        if group.allowsEmptySelection { item.select(nil, in: group) }
                    case .track(let language, let name):
                        let matching = group.options.first { option in
                            option.locale?.identifier == language && option.displayName == name
                        } ?? group.options.first { option in
                            option.locale?.identifier == language && language != nil
                        }
                        if let matching { item.select(matching, in: group) }
                    }
                }
                // Keep local HLS updates flowing while Load stays paused.
                if self.preparedMedia?.url.pathExtension == "m3u8" {
                    item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                }
                // A growing EVENT playlist can open at its live edge; seek the
                // prepared item back to the start once it is ready.
                self.pendingInitialSeek = self.preparedMedia?.sourceDuration != nil
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
                            let negotiationID = self.probeID
                            self.player.seek(to: .zero) { [weak self] finished in
                                Task { @MainActor in
                                    guard finished, let self, self.generation == id,
                                          self.probeID == negotiationID, self.probing else { return }
                                    self.player.play()
                                }
                            }
                            return
                        }
                        // A delayed probe-end notification must not unload or
                        // advance the queue while the handoff is being rewound.
                        if self.probeRestoring || self.probeRestoreFailed || self.pendingSeek != nil {
                            self.player.pause()
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
                            self.playbackRequested = false
                            self.player.pause()
                            if !hasNext { self.notice = "End of playlist." }
                            self.refresh()
                        } else if self.afterPlaybackBehavior() == .unloadVideo {
                            self.stop()
                            self.notice = "Playback finished. The video was unloaded."
                        } else {
                            self.ended = true
                            self.playbackRequested = false
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
                self.notifications.append(NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        if item.status == .readyToPlay, self.mediaItem === item,
                           let group = self.nativeSubtitleGroup {
                            if let option = item.currentMediaSelection.selectedMediaOption(in: group) {
                                self.subtitlePreference = .track(language: option.locale?.identifier,
                                                                 name: option.displayName)
                            } else if group.allowsEmptySelection {
                                self.subtitlePreference = .off
                            }
                        }
                        self.refresh()
                    }
                })
                self.mediaItem = item
                self.player.replaceCurrentItem(with: item)
                self.refresh()
            } catch {
                guard let self, !Task.isCancelled, self.generation == id else { return }
                if case let PreparationFailure.videoConversionRequired(height, frameRate) = error {
                    self.selectedQuality = Self.qualityLabel(height: height, frameRate: frameRate)
                    self.fail(.preparationRequired,
                              message: "This source needs video re-encoding. Turn off Avoid video re-encoding in Settings, then reload.")
                    return
                }
                if case PreparationFailure.conversionWouldDownscale = error {
                    self.fail(.preparationRequired,
                              message: "This output would downscale the source. Choose 4K or Original.")
                    return
                }
                // Keep a validator's specific message instead of flattening it to
                // the generic load failure, e.g. a local file removed after input
                // validation.
                if let appFailure = error as? AppFailure {
                    self.fail(.loadFailed, message: appFailure.message)
                    return
                }
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
        guard !probing && !probeRestoring else {
            throw AppFailure(.unsupportedOperation, "Wait for the receiver connection to finish.")
        }
        guard pendingResumePosition == nil || probeRestoreFailed else {
            throw AppFailure(.unsupportedOperation, "Wait for the playback position to be restored.")
        }
        guard player.isExternalPlaybackActive else {
            throw AppFailure(.routeRequired, "Choose a video receiver using the AirPlay button, then press Play.")
        }
        if pendingSeek != nil {
            seekPlayWhenReady = true
            playbackRequested = true
            refresh()
            return
        }
        if probeRestoreFailed {
            // A slow route handoff can exhaust the automatic retry window.
            // Play retries the rewind and starts only after it is confirmed.
            playWhenReady = true
            restoreProbePosition()
            refresh()
            return
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
        playbackRequested = true
        player.isMuted = false
        player.play()
        refresh()
    }

    func pause() {
        if waitingScreen.isActive { stop(); return }
        playWhenReady = false
        seekPlayWhenReady = false
        replacementPlayTask?.cancel(); replacementPlayTask = nil
        pendingAutoplaySeek = false
        autoplayRouteTask?.cancel(); autoplayRouteTask = nil
        autoplayRouteDeadline = nil
        playbackRequested = false
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
        guard !loadInProgress, failure == nil, mediaItem?.status == .readyToPlay else {
            throw AppFailure(.unsupportedOperation, "Wait for a video to finish loading before seeking.")
        }
        guard !probing && !probeRestoring else {
            throw AppFailure(.unsupportedOperation, "Wait for the receiver connection to finish.")
        }
        guard player.isExternalPlaybackActive else {
            throw AppFailure(.routeRequired, "Choose a video receiver first.")
        }
        ended = false
        seekPreparationTask?.cancel()
        seekTimeoutTask?.cancel()
        seekPlayWhenReady = pendingSeek != nil ? seekPlayWhenReady : (playbackRequested || player.rate > 0)
        replacementPlayTask?.cancel(); replacementPlayTask = nil
        playWhenReady = false
        pendingSeek = seconds
        seekPreparationReady = false
        seekNativeFinished = nil
        let id = generation
        let requestID = UUID()
        seekID = requestID
        notice = nil
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        seekTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.generation == id, self.seekID == requestID else { return }
            self.seekPreparationTask?.cancel(); self.seekPreparationTask = nil
            self.seekID = nil; self.pendingSeek = nil; self.seekPlayWhenReady = false
            self.playbackRequested = false
            self.player.currentItem?.cancelPendingSeeks()
            self.notice = "The seek has not completed. Try the position again or press Play."
            self.refresh()
        }
        let prepared = preparedMedia
        seekPreparationTask = Task { [weak self] in
            do {
                try await prepared?.prepareSeek(at: seconds)
                try Task.checkCancellation()
                guard let self, self.generation == id, self.seekID == requestID else { return }
                self.seekPreparationTask = nil
                self.seekPreparationReady = true
                self.finishRequestedSeek(generation: id, request: requestID)
            } catch {
                guard let self, !Task.isCancelled, self.generation == id, self.seekID == requestID else { return }
                self.seekTimeoutTask?.cancel(); self.seekTimeoutTask = nil
                self.seekPreparationTask = nil; self.seekID = nil; self.pendingSeek = nil
                self.seekPlayWhenReady = false
                self.playbackRequested = false
                self.notice = "Could not prepare the requested position. Try the seek again."
                self.refresh()
            }
        }
        issueRequestedSeek(seconds, generation: id, request: requestID)
        refresh()
    }

    private func issueRequestedSeek(_ seconds: Double, generation id: UUID, request requestID: UUID) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == id, self.seekID == requestID else { return }
                self.seekNativeFinished = finished
                self.finishRequestedSeek(generation: id, request: requestID)
            }
        }
    }

    private func finishRequestedSeek(generation id: UUID, request requestID: UUID) {
        guard generation == id, seekID == requestID, let finished = seekNativeFinished,
              !finished || seekPreparationReady else { return }
        let resume = seekPlayWhenReady
        cancelSeekWork()
        if finished {
            probeRestoreFailed = false
            if resume {
                playWhenReady = true
                playbackRequested = true
                beginReplacementPlayback()
            }
        } else {
            playbackRequested = false
            notice = "The seek was interrupted. Try the position again."
        }
        refresh()
    }

    private func cancelSeekWork() {
        seekPreparationTask?.cancel(); seekPreparationTask = nil
        seekTimeoutTask?.cancel(); seekTimeoutTask = nil
        pendingSeek = nil; seekID = nil; seekPlayWhenReady = false
        seekPreparationReady = false; seekNativeFinished = nil
    }

    /// Accumulate rapid skips from the latest request, within prepared/seekable media.
    func skip(by seconds: Double) throws {
        guard seconds.isFinite else { throw AppFailure(.invalidRequest, "Use a finite seek interval.") }
        let range = snapshot.isLive ? snapshot.seekableRanges.last : snapshot.seekableRanges.first
        guard let range else {
            throw AppFailure(.unsupportedOperation, "This video does not currently support seeking.")
        }
        let position = pendingSeek ?? snapshot.position ?? range.start
        try seek(min(max(position + seconds, range.start), range.end))
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
        if showReceiverWaitingScreen && mediaItem == nil && !loadInProgress && failure == nil {
            waitingScreen.start()
        }
        hasOpenedPicker = true
        pickerIsOpen = true
        probeWhenReady = !player.isExternalPlaybackActive
        // Reopening during a negotiation restarts the picker window so a
        // receiver chosen in this presentation is not cancelled by the previous
        // dismissal's shorter deadline.
        if probing { scheduleProbeTimeout(seconds: Self.pickerOpenProbeTimeout) }
        refresh()
    }

    private func beginProbeIfReady() {
        guard probeWhenReady, mediaItem?.status == .readyToPlay, !loading, !probeRestoring,
              pendingResumePosition == nil else { return }
        if failure != nil {
            probeWhenReady = false
            return
        }
        guard !probing else { return }
        probeWhenReady = false
        // Opening the picker on an active route must not pause or rewind playback.
        guard !player.isExternalPlaybackActive else { return }
        if !probeRestoreFailed {
            let finiteAutoplay = pendingAutoplaySeek && selectedSource?.isLive != true
                && (preparedMedia?.sourceDuration != nil || finite(mediaItem?.duration.seconds ?? .nan) != nil)
            probePosition = finiteAutoplay ? 0 : (finite(player.currentTime().seconds) ?? 0)
        }
        probing = true
        probeID = UUID()
        let negotiationID = probeID
        player.isMuted = true
        let id = generation
        player.preroll(atRate: 1) { [weak self] finished in
            Task { @MainActor in
                guard finished, let self, self.generation == id,
                      self.probeID == negotiationID, self.probing else { return }
                if self.player.isExternalPlaybackActive {
                    self.finishProbeIfReady()
                } else {
                    // Preroll only buffers; a muted playback request is needed
                    // to negotiate the selected AirPlay video route.
                    self.player.play()
                }
            }
        }
        scheduleProbeTimeout(seconds: pickerIsOpen ? Self.pickerOpenProbeTimeout : Self.routeProbeTimeout)
    }

    private func finishProbeIfReady() {
        guard probing, player.isExternalPlaybackActive else { return }
        cancelProbe(restorePosition: true)
        refresh()
    }

    func pickerDidClose() {
        pickerIsOpen = false
        guard probing else { return }
        if player.isExternalPlaybackActive {
            finishProbeIfReady()
        } else {
            // The user returned without an active route. Stop the muted
            // negotiation promptly and surface feedback rather than leaving the
            // controller on "Connecting to AirPlay…" until the route timeout.
            scheduleProbeTimeout(seconds: Self.pickerDismissalGrace)
        }
    }

    private func scheduleProbeTimeout(seconds: Double) {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.probing else { return }
            self.cancelProbe(restorePosition: true)
            // A picker opening without a chosen route must not trigger another
            // negotiation on every later source or enhancement change.
            self.hasOpenedPicker = false
            self.notice = "No video receiver connected. Use AirPlay to choose a TV, then try again."
            self.refresh()
        }
    }

    private func cancelProbe(restorePosition: Bool) {
        // A receiver-side Pause can arrive while the seek is in flight. Do not
        // invalidate that rewind and expose Play before it actually completes.
        if probeRestoring && restorePosition {
            player.pause()
            return
        }
        probeID = UUID()
        probeTask?.cancel()
        probeTask = nil
        probeRestoreTask?.cancel()
        probeRestoreTask = nil
        probeRestoreSeekID = nil
        probeRestoreSeekFinished = nil
        probeRestoring = false
        player.cancelPendingPrerolls()
        guard probing else { return }
        probing = false
        player.pause()
        if restorePosition, player.currentItem?.status == .readyToPlay {
            restoreProbePosition()
        }
    }

    private func restoreProbePosition() {
        probeRestoreTask?.cancel()
        probeRestoring = true
        probeRestoreFailed = false
        player.isMuted = true
        player.pause()
        let id = generation
        let restoreID = probeID
        let position = CMTime(seconds: probePosition, preferredTimescale: 600)
        probeRestoreTask = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(self?.changingSource == true ? 60 : 20))
            while !Task.isCancelled, clock.now < deadline {
                guard let self, self.generation == id, self.probeID == restoreID,
                      self.probeRestoring else { return }
                let requestID = UUID()
                self.probeRestoreSeekID = requestID
                self.probeRestoreSeekFinished = nil
                self.player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                    Task { @MainActor in
                        guard let self, self.generation == id, self.probeID == restoreID,
                              self.probeRestoring, self.probeRestoreSeekID == requestID else { return }
                        self.probeRestoreSeekFinished = finished
                    }
                }
                // External playback becomes active before the receiver is
                // necessarily ready for transport commands. Retry interrupted
                // or unanswered seeks, and verify the actual paused clock.
                let attemptDeadline = min(deadline, clock.now.advanced(by: .seconds(3)))
                repeat {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard self.generation == id, self.probeID == restoreID,
                          self.probeRestoring else { return }
                    if self.player.rate != 0 || self.player.timeControlStatus != .paused {
                        self.player.pause()
                    }
                    if self.probeRestoreSeekFinished == true,
                       let actual = self.finite(self.player.currentTime().seconds),
                       abs(actual - position.seconds) < 0.1,
                       self.player.rate == 0, self.player.timeControlStatus == .paused {
                        self.probeRestoring = false
                        self.pendingResumePosition = nil
                        self.loadPreferences?.resumePosition = nil
                        if abs(position.seconds) < 0.1 { self.pendingAutoplaySeek = false }
                        self.probeRestoreSeekID = nil
                        self.probeRestoreTask = nil
                        if self.player.isExternalPlaybackActive {
                            self.notice = "Connected. Press Play when you’re ready."
                        }
                        self.refresh()
                        return
                    }
                    if self.probeRestoreSeekFinished == false { break }
                } while clock.now < attemptDeadline
            }
            guard !Task.isCancelled, let self, self.generation == id,
                  self.probeID == restoreID, self.probeRestoring else { return }
            self.probeRestoring = false
            self.probeRestoreSeekID = nil
            self.probeRestoreTask = nil
            self.probeRestoreFailed = true
            self.playWhenReady = false
            self.notice = "Could not restore the playback position yet. Press Play to retry."
            self.refresh()
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

    /// A ready AirPlay route may ignore Play during item replacement. Keep
    /// intent until playback is observed, retrying paused replies only.
    private func beginReplacementPlayback() {
        guard replacementPlayTask == nil else { return }
        let id = generation
        player.isMuted = false
        player.play()
        replacementPlayTask = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(30))
            var playingSince: ContinuousClock.Instant?
            var retryAt = clock.now.advanced(by: .seconds(1))
            defer {
                if let self, self.generation == id { self.replacementPlayTask = nil }
            }
            while !Task.isCancelled, clock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.generation == id, self.playWhenReady,
                      self.failure == nil else { return }
                if self.player.isExternalPlaybackActive, self.player.timeControlStatus == .playing {
                    if let since = playingSince, since.duration(to: clock.now) >= .seconds(1) {
                        self.playWhenReady = false
                        self.refresh()
                        return
                    }
                    if playingSince == nil { playingSince = clock.now }
                } else {
                    playingSince = nil
                    if self.player.isExternalPlaybackActive, self.player.timeControlStatus == .paused,
                       clock.now >= retryAt {
                        self.player.isMuted = false
                        self.player.play()
                        retryAt = clock.now.advanced(by: .seconds(1))
                    }
                }
                self.refresh()
            }
            guard !Task.isCancelled, let self, self.generation == id, self.playWhenReady else { return }
            self.playWhenReady = false
            self.playbackRequested = false
            self.player.pause()
            self.notice = "The receiver has not resumed playback. Press Play to retry."
            self.refresh()
        }
    }

    private func stopRetiredPreparedMedia() {
        guard let retired = retiredPreparedMedia else { return }
        retiredPreparedMedia = nil
        retired.stop()
        let id = UUID()
        drainingLoads[id] = Task { [weak self] in
            await retired.waitForProducer()
            self?.drainingLoads.removeValue(forKey: id)
        }
    }

    private func resetItem(keepPlayerItem: Bool = false, preserveQueue: Bool = false) {
        waitingScreen.stop(keepingItemForReplacement: keepPlayerItem)
        let installedPrepared = preparedMedia != nil && mediaItem != nil && player.currentItem === mediaItem
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
        cancelSeekWork()
        loadPreferences = nil
        probeWhenReady = false
        pickerIsOpen = false
        // Keep the previous delivery URL valid while AVPlayer retains its item.
        // Cancel any expensive conversion immediately; release the server only
        // after the replacement item is installed (or loading fails/stops).
        if keepPlayerItem, installedPrepared, let prepared = preparedMedia {
            stopRetiredPreparedMedia()
            prepared.onFailure = nil
            prepared.cancelProduction()
            retiredPreparedMedia = prepared
            preparedMedia = nil
        } else if keepPlayerItem {
            stopPreparedMedia()
        } else {
            player.replaceCurrentItem(with: nil)
            stopPreparedMedia()
            stopRetiredPreparedMedia()
        }
        loading = false; resolving = false; preparing = false; websiteURL = nil; retriedResolution = false
        selectedSource = nil
        inspectedSourceHeight = nil
        selectedQuality = nil
        videoEnhancement = .original
        enhancementOutput4K = false
        originalSourceURL = nil
        sourceCandidates = []
        sourceChoice = nil
        selectedNativeAudioID = nil
        nativeAudioGroup = nil
        nativeSubtitleGroup = nil
        subtitlePreference = nil
        changingSource = false
        sourceOptionsGeneration = UUID()
        actualPlaybackPath = nil
        ended = false; hasPlayed = false; failure = nil; failureReason = nil
        playWhenReady = false
        pendingAutoplaySeek = false
        replacementPlayTask?.cancel(); replacementPlayTask = nil
        autoplayRouteTask?.cancel(); autoplayRouteTask = nil
        autoplayRouteDeadline = nil
        playbackRequested = false
        pendingInitialSeek = false
        pendingResumePosition = nil
        probeRestoreFailed = false
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
                      autoplay: playWhenReady, titleOverride: queue.map { $0.entries[$0.currentIndex].title },
                      sourceChoice: sourceChoice, changingSource: changingSource, preferences: loadPreferences)
            return
        }
        if !hasPlayed, prepareSource != nil, let selectedSource,
           let remuxFallback = MediaSelector.remuxFallback(for: selectedSource, reason: reason) {
            // Prefer the best available remux presentation over remuxing the
            // failed native URL, so a fallback is not stuck at the low-quality
            // direct stream.
            let fallback = sourceChoice == nil
                ? (MediaSelector.bestRemuxFallback(from: sourceCandidates, policy: selectedSource.conversionPolicy)
                   ?? remuxFallback)
                : remuxFallback
            startLoad(originalSourceURL ?? selectedSource.url, retry: retriedResolution, fallback: fallback,
                      preservingQueue: queue != nil, autoplay: playWhenReady,
                      titleOverride: title, sourceChoice: sourceChoice, changingSource: changingSource,
                      preferences: loadPreferences)
            return
        }
        if advancingQueue, reason != .signInRequired, !changingSource, sourceChoice == nil,
           var queue, queueAttemptsRemaining > 1 {
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
        loadTask?.cancel(); loadTask = nil
        cancelSeekWork()
        playWhenReady = false
        playbackRequested = false
        replacementPlayTask?.cancel(); replacementPlayTask = nil
        player.isMuted = true
        autoplayRouteTask?.cancel(); autoplayRouteTask = nil
        autoplayRouteDeadline = nil
        pendingAutoplaySeek = false
        player.pause()
        timeoutTask?.cancel()
        player.replaceCurrentItem(with: nil)
        stopRetiredPreparedMedia()
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
        waitingScreen.reconcile()
        if waitingScreen.isActive {
            var next = PlaybackSnapshot()
            next.receiverWaiting = true
            next.externalPlaybackActive = player.isExternalPlaybackActive
            next.state = next.externalPlaybackActive ? .idle : .connecting
            next.title = "Ready to play"
            next.allowVideoConversion = allowVideoConversion
            wasExternal = next.externalPlaybackActive
            if snapshot != next { snapshot = next; updateNowPlaying() }
            updateSleepActivity()
            return
        }
        // Receiver-side controls must not resume a retained old item or a new
        // item whose video tracks are still being confirmed.
        if (mediaItem == nil || loading || failure != nil) && player.currentItem != nil {
            player.isMuted = true
            // Repeated pause requests while an already-paused EVENT item loads
            // can interrupt AVPlayer's initial buffering before it becomes ready.
            if player.rate != 0 || player.timeControlStatus != .paused { player.pause() }
        }
        let external = player.isExternalPlaybackActive
        if external {
            autoplayRouteTask?.cancel(); autoplayRouteTask = nil
            autoplayRouteDeadline = nil
        } else if playWhenReady, autoplayRouteTask == nil,
                  !changingSource || (!loadInProgress && pendingResumePosition == nil && !probeRestoring) {
            // AVPlayer can briefly drop its external flag while replacing an
            // item. Preserve the explicit request for a bounded handoff grace,
            // then require another user action if the receiver does not return.
            // A quality switch starts that grace after preparation and seek
            // restoration, so encoding time cannot consume its play intent.
            let id = generation
            let deadline = autoplayRouteDeadline ?? ContinuousClock.now.advanced(by: .seconds(30))
            autoplayRouteDeadline = deadline
            autoplayRouteTask = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                guard let self, self.generation == id, self.playWhenReady,
                      !self.player.isExternalPlaybackActive else { return }
                self.pause()
                self.notice = "The receiver did not reconnect. Choose a receiver using AirPlay, then press Play."
                self.refresh()
            }
        }
        if wasExternal && !external {
            playbackRequested = false
            player.isMuted = true
            player.pause()
            if !loading && !playWhenReady { pendingAutoplaySeek = false }
            cancelSeekWork()
            if mediaItem != nil && failure == nil && !loading && !probeWhenReady {
                notice = "AirPlay disconnected. Choose a receiver to continue."
            }
        }
        wasExternal = external
        if probing && external { finishProbeIfReady() }
        if probeRestoring || (probeRestoreFailed && !probing) {
            player.isMuted = true
            if player.rate != 0 || player.timeControlStatus != .paused { player.pause() }
        }
        if !external && !probing {
            player.isMuted = true
            if player.rate != 0 { player.pause() }
        }
        let item = mediaItem
        if pendingSeek == nil, let position = finite(player.currentTime().seconds) {
            preparedMedia?.updatePlaybackPosition(pendingResumePosition ?? position,
                playing: playbackRequested && !probing && !probeRestoring)
        }
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
        if let target = pendingResumePosition, let item, item.status == .readyToPlay, !loading,
           !probeRestoring, !probeRestoreFailed, !probing {
            pendingInitialSeek = false
            pendingAutoplaySeek = false
            let duration = preparedMedia?.sourceDuration ?? finite(item.duration.seconds)
            let position = min(target, duration.map { max(0, $0 - 0.1) } ?? target)
            // Sequential EVENT output must publish the target before it can be sought.
            if preparedMedia?.usesBoundedCache != false
                || preparedMedia?.readyRanges?.contains(where: { $0.contains(position) }) == true {
                probePosition = position
                pendingResumePosition = position
                restoreProbePosition()
            }
        }
        // A growing EVENT playlist can open at its live edge; return a prepared
        // item to the beginning before any negotiation or playback.
        if pendingInitialSeek, let item, item.status == .readyToPlay, !loading {
            pendingInitialSeek = false
            if pendingResumePosition == nil, !pendingAutoplaySeek, (finite(player.currentTime().seconds) ?? 0) > 0.5 { player.seek(to: .zero) }
        }
        beginProbeIfReady()
        // A replacement on an already active route still needs a confirmed
        // finite starting position before an explicit send-and-play can run.
        if playWhenReady, pendingAutoplaySeek, !loading, item?.status == .readyToPlay,
           !probing, !probeRestoring, !probeRestoreFailed {
            pendingAutoplaySeek = false
            if selectedSource?.isLive != true,
               preparedMedia?.sourceDuration != nil || finite(item?.duration.seconds ?? .nan) != nil {
                probePosition = 0
                restoreProbePosition()
            }
        }
        if retiredPreparedMedia != nil, !loading, item?.status == .readyToPlay,
           !probing && !probeRestoring && !probeWhenReady {
            stopRetiredPreparedMedia()
        }
        if playWhenReady, pendingResumePosition == nil, !loading, item?.status == .readyToPlay, !probeRestoring && !probeRestoreFailed {
            if external && !probing {
                playbackRequested = true
                probeWhenReady = false
                hasPlayed = true
                if changingSource || replacementPlayTask != nil {
                    beginReplacementPlayback()
                } else {
                    playWhenReady = false
                    player.isMuted = false
                    player.play()
                }
            } else if !probing {
                notice = "Video is ready. Waiting for the receiver…"
            }
        }
        if external && !probing && !probeRestoring && !probeRestoreFailed && player.rate > 0 {
            hasPlayed = true
            player.isMuted = false
            notice = nil
        }
        // Inspect the original presentation only: an enhanced item's 2160p
        // output must not become the source resolution for future choices.
        if preparedMedia == nil, videoEnhancement == .original,
           let source = selectedSource, let height = item.map({ Double($0.presentationSize.height) }),
           height.isFinite, height > 0 {
            inspectedSourceHeight = (source.url, height)
            if Self.candidatesHeight(for: source, in: sourceCandidates) == nil {
                selectedQuality = Self.qualityLabel(height: Int(min(height.rounded(), 100_000)), frameRate: nil)
            }
            if height > 1080 && !enhancementOutput4K { enhancementOutput4K = true }
        }
        var next = PlaybackSnapshot()
        next.seekInProgress = pendingSeek != nil ? true : nil
        next.title = title
        next.externalPlaybackActive = external
        next.error = failure
        next.errorReason = failureReason
        next.loadingPhase = resolving ? "resolving" : (preparing ? "preparing" : nil)
        next.preparationInProgress = preparedMedia?.sourceDuration != nil && preparedMedia?.isProducing == true && !loading ? true : nil
        next.preparationSpeed = !loading && failure == nil ? preparedMedia?.preparationSpeed : nil
        next.playbackPath = failure == nil
            ? (actualPlaybackPath ?? (preparing ? selectedSource?.plannedPath : selectedSource?.playbackPath)) : nil
        next.quality = selectedQuality
        next.sources = sourceOptions
        let choices = audioChoices
        next.audioOptions = choices.count > 1 ? choices.map(\.snapshot) : nil
        if let group = nativeSubtitleGroup, let item = mediaItem {
            let prefix = "\(sourceOptionsGeneration.uuidString)-subtitle-"
            var options: [SubtitleOptionSnapshot] = []
            if group.allowsEmptySelection {
                options.append(SubtitleOptionSnapshot(id: prefix + "off", label: "Off"))
            }
            options += group.options.enumerated().map { index, option in
                let name = option.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = name.isEmpty || name.count > 80 || name.contains("://")
                    ? "Subtitle \(index + 1)" : name
                return SubtitleOptionSnapshot(id: prefix + String(index), label: label)
            }
            next.subtitleOptions = options
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let index = group.options.firstIndex(of: selected) {
                next.selectedSubtitleID = prefix + String(index)
            } else if group.allowsEmptySelection {
                next.selectedSubtitleID = prefix + "off"
            }
        }
        if let selectedNativeAudioID,
           let index = selectedSource?.hlsAudioOptions.firstIndex(where: { $0.id == selectedNativeAudioID }) {
            next.selectedAudioID = "\(sourceOptionsGeneration.uuidString)-audio-native-\(index)"
        } else if let selectedSource,
                  let index = sourceCandidates.firstIndex(where: {
                      $0.source.url == selectedSource.url && $0.source.audio?.url == selectedSource.audio?.url
                  }), sourceCandidates[index].source.audio != nil {
            next.selectedAudioID = "\(sourceOptionsGeneration.uuidString)-audio-candidate-\(index)"
        }
        if let sourceChoice, let index = sourceCandidates.firstIndex(where: { $0.id == sourceChoice }) {
            next.selectedSourceID = sourceOptionID(index)
        }
        next.allowVideoConversion = allowVideoConversion
        // The per-item enhancement is gated by the shared conversion preference.
        // Reported only while an item is loaded (or attempted) so an idle
        // controller does not claim an enhancement.
        next.videoEnhancement = (mediaItem == nil && !loading && failure == nil) ? nil : videoEnhancement
        next.hasAudio = hasAudio
        if let queue {
            next.queue = PlaybackQueueSnapshot(title: queue.title, currentIndex: queue.currentIndex,
                items: queue.entries.indices.map { index in
                    QueueItemSnapshot(title: queue.entries[index].title,
                        state: index == queue.currentIndex ? .current : (queue.skipped.contains(index) ? .skipped : .pending))
                }, truncated: queue.truncated)
        }
        next.duration = preparedMedia?.sourceDuration ?? item.flatMap { finite($0.duration.seconds) }
            ?? (pendingResumePosition != nil ? loadPreferences?.resumeDuration : nil)
        next.preparedRanges = loading || failure != nil ? nil : preparedMedia?.readyRanges
        // Keep the requested position visible while a quality replacement loads.
        // A new video hides the retained old item's clock; probes keep it stable.
        next.position = pendingSeek ?? pendingResumePosition ?? ((item == nil || loading || resolving || preparing) ? nil
            : ((probing || probeRestoring) ? probePosition : finite(player.currentTime().seconds)))
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
            connecting: probing || probeRestoring, external: external, ended: ended,
            playing: player.timeControlStatus == .playing, waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            hasPlayed: hasPlayed)
        if pendingResumePosition != nil, !probeRestoreFailed, failure == nil {
            next.state = playWhenReady && external ? .buffering : .loading
            if next.loadingPhase == nil { next.loadingPhase = "restoring" }
        }
        if replacementPlayTask != nil, playWhenReady, external, failure == nil,
           player.timeControlStatus != .playing { next.state = .buffering }
        if pendingSeek != nil, seekPlayWhenReady, external, failure == nil { next.state = .playing }
        if snapshot != next {
            snapshot = next
            updateNowPlaying()
        }
        updateSleepActivity()
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
        center.playCommand.isEnabled = hasItem && !loading && snapshot.externalPlaybackActive && !probing && !probeRestoring
        center.pauseCommand.isEnabled = hasItem
        center.stopCommand.isEnabled = hasItem || loading || waitingScreen.isActive
        center.togglePlayPauseCommand.isEnabled = center.playCommand.isEnabled
        center.changePlaybackPositionCommand.isEnabled = center.playCommand.isEnabled && !snapshot.seekableRanges.isEmpty
        center.previousTrackCommand.isEnabled = queue.map { $0.currentIndex > 0 } ?? false
        center.nextTrackCommand.isEnabled = queue.map { $0.currentIndex + 1 < $0.entries.count } ?? false
        let info = MPNowPlayingInfoCenter.default()
        if hasItem {
            var metadata: [String: Any] = [MPMediaItemPropertyTitle: title,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
                MPNowPlayingInfoPropertyPlaybackRate: (probing || probeRestoring) ? 0 : player.rate,
                MPNowPlayingInfoPropertyIsLiveStream: snapshot.isLive]
            if let position = snapshot.position { metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
            if let duration = snapshot.duration { metadata[MPMediaItemPropertyPlaybackDuration] = duration }
            if let queue {
                metadata[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queue.currentIndex
                metadata[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.entries.count
            }
            info.nowPlayingInfo = metadata
            info.playbackState = snapshot.state == .playing ? .playing : .paused
        } else if waitingScreen.isActive {
            info.nowPlayingInfo = [MPMediaItemPropertyTitle: "AirThrow — Ready to play",
                                  MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue]
            info.playbackState = .playing
        } else { info.nowPlayingInfo = nil; info.playbackState = .stopped }
    }

    private func updateSleepActivity() {
        // Loading and route negotiation may need the Mac even before playback.
        // Once Play is requested, transient AVPlayer pauses must not permit idle
        // sleep; prepared and local media also depend on this Mac's HTTP server.
        let needsActivity = loading || resolving || preparing || probing || probeRestoring
            || pendingSeek != nil || playbackRequested || waitingScreen.isActive
        if needsActivity && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Preparing or playing AirPlay video")
        } else if !needsActivity, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

/// Bridges the Settings cookie choice to the resolver. An `AIRTHROW_*`
/// environment override wins over the saved preference so power users and the
/// CLI can force a source without touching the UI.
enum YouTubeCookiePreference {
    static let modeKey = "youtubeCookiesMode"
    static let browserKey = "youtubeCookiesBrowser"
    static let filePathKey = "youtubeCookiesFilePath"
    static let defaultBrowser = "safari"
    static var browsers: [String] { YouTubeCookies.supportedBrowsers }

    static func installedBrowsers(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        YouTubeCookies.installedBrowsers(home: home)
    }

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                        defaults: UserDefaults = .standard) -> YouTubeCookies {
        let override = YouTubeCookies.fromEnvironment(environment)
        if override != .none { return override }
        return fromDefaults(defaults)
    }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> YouTubeCookies {
        switch defaults.string(forKey: modeKey) {
        case "browser":
            let browser = (defaults.string(forKey: browserKey) ?? defaultBrowser).lowercased()
            guard browsers.contains(browser) else { return .none }
            return .browser(browser)
        case "file":
            guard let path = defaults.string(forKey: filePathKey), path.hasPrefix("/") else { return .none }
            return .file(URL(fileURLWithPath: path))
        default:
            return .none
        }
    }
}


/// One cookie source with a browser-only service filter. File sources are
/// automatically scoped to the loaded website; cookie contents stay out of defaults.
enum WebsiteCookiePreference {
    static let modeKey = "websiteCookiesMode"
    static let browserKey = "websiteCookiesBrowser"
    static let filePathKey = "websiteCookiesFilePath"
    static let servicesKey = "websiteCookiesServices"
    static let defaultBrowser = YouTubeCookiePreference.defaultBrowser
    static let allServices = WebsiteService.allCases.map(\.rawValue).joined(separator: ",")

    // Keys from the earlier per-service settings, used only for migration.
    static func key(_ service: WebsiteService, _ field: String) -> String {
        if service == .youtube {
            switch field {
            case "mode": return YouTubeCookiePreference.modeKey
            case "browser": return YouTubeCookiePreference.browserKey
            case "filePath": return YouTubeCookiePreference.filePathKey
            default: break
            }
        }
        return "websiteSession.\(service.rawValue).\(field)"
    }

    static func prepare(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: modeKey) == nil else { return }
        let enabled = WebsiteService.allCases.filter { service in
            if defaults.object(forKey: key(service, "enabled")) != nil {
                return defaults.bool(forKey: key(service, "enabled"))
            }
            return service == .youtube && YouTubeCookiePreference.fromDefaults(defaults) != .none
        }
        // Prefer the existing YouTube choice, otherwise the first enabled site.
        if let service = enabled.first {
            defaults.set(defaults.string(forKey: key(service, "mode")) ?? "browser", forKey: modeKey)
            defaults.set(defaults.string(forKey: key(service, "browser")) ?? defaultBrowser, forKey: browserKey)
            defaults.set(defaults.string(forKey: key(service, "filePath")) ?? "", forKey: filePathKey)
            defaults.set(enabled.map(\.rawValue).joined(separator: ","), forKey: servicesKey)
        } else if defaults.object(forKey: servicesKey) == nil {
            defaults.set(allServices, forKey: servicesKey)
        }
    }

    static func selectedServices(_ value: String) -> Set<WebsiteService> {
        Set(value.split(separator: ",").compactMap { WebsiteService(rawValue: String($0)) })
    }

    static func configuredSource(defaults: UserDefaults = .standard) -> YouTubeCookies {
        prepare(defaults)
        switch defaults.string(forKey: modeKey) {
        case "browser":
            let browser = (defaults.string(forKey: browserKey) ?? defaultBrowser).lowercased()
            return YouTubeCookies.supportedBrowsers.contains(browser) ? .browser(browser) : .none
        case "file":
            guard let path = defaults.string(forKey: filePathKey), path.hasPrefix("/") else { return .none }
            return .file(URL(fileURLWithPath: path))
        default: return .none
        }
    }

    static func source(_ service: WebsiteService, defaults: UserDefaults = .standard) -> YouTubeCookies {
        let source = configuredSource(defaults: defaults)
        if case .browser = source {
            guard selectedServices(defaults.string(forKey: servicesKey) ?? allServices).contains(service) else { return .none }
        }
        return source
    }

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                        defaults: UserDefaults = .standard) -> WebsiteSessions {
        var sources: [WebsiteService: YouTubeCookies] = [:]
        for service in WebsiteService.allCases { sources[service] = source(service, defaults: defaults) }
        let override = YouTubeCookies.fromEnvironment(environment)
        let mode = defaults.string(forKey: modeKey)
        let legacyDisabled = defaults.object(forKey: key(.youtube, "enabled")) != nil
            && !defaults.bool(forKey: key(.youtube, "enabled"))
        let allowsOverride = mode == "file" || (mode == "browser" && source(.youtube, defaults: defaults) != .none)
            || (mode == nil && !legacyDisabled)
        if override != .none, allowsOverride { sources[.youtube] = override }
        return WebsiteSessions(sources: sources)
    }
}
