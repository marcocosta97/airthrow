import Foundation
import AVFoundation
import MediaPlayer
import Combine
#if SWIFT_PACKAGE
import AirThrowCore
#endif

struct HTTPLoginRequest: Identifiable {
    let id = UUID()
    let challenge: HTTPLoginChallenge
    let retry: Bool
    var submitting = false
    var username = ""
}

enum InspectorPage { case history, channels, playlist, xtream }

private final class ShutdownResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func finish() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

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
    @Published private(set) var httpLoginRequest: HTTPLoginRequest?
    @Published private(set) var iptvCatalog: IPTVCatalog?
    @Published private(set) var xtreamLibrary: XtreamLibrary?
    @Published private(set) var saveXtreamCatalogs: Bool
    private let xtreamCatalogStore: XtreamCatalogStore
    private let xtreamCatalogDefaults: UserDefaults
    private var catalogPersistenceTask: Task<Void, Never>?
    @Published private(set) var iptvImporting = false
    @Published private(set) var iptvImportError: String?
    /// Sign-in started from the Xtream sheet. Failures stay in the sheet
    /// instead of the playback footer, and the sheet stays up until this ends.
    @Published private(set) var xtreamSigningIn = false
    @Published private(set) var xtreamSignInError: String?
    @Published private(set) var selectedIPTVChannelID: UUID?
    @Published private(set) var history: [MediaHistoryEntry] = []
    @Published var inspectorPage: InspectorPage = .history
    @Published private(set) var sourceInput: String?
    private let historyStore: MediaHistoryStore
    private var pendingHistoryURL: URL?
    private var iptvSourceURL: URL?
    private var iptvImportTask: Task<Void, Never>?
    private var iptvImportID = UUID()
    private let loadIPTVCatalog: @Sendable (URL) async throws -> IPTVCatalog
    private var httpLoginContinuation: CheckedContinuation<HTTPLoginCredentials, Error>?
    private var authenticatedMedia: HTTPMediaRelay?
    private var variantMediaRelay: HTTPMediaRelay?
    private var retiredVariantMediaRelay: HTTPMediaRelay?
    private var retiredAuthenticatedMedia: HTTPMediaRelay?
    private let checkHTTPAuthentication: (@MainActor @Sendable (URL, HTTPLoginCredentials?) async throws -> HTTPLoginChallenge?)?
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?
    private var sampledVideo: StreamingVideoCharacteristics?
    private var hlsVariants: [HLSVariantSummary]?
    private var hlsVariantCount: Int?
    private var sampleInspectionStatus: PlaybackDiagnostics.SampleInspectionStatus?
    private var preparationInputRelay: HTTPMediaRelay?
    private var lastLivePipeline: LivePipelineDiagnostics?
    private var lastFailureDiagnostics: PlaybackDiagnostics?
    private var diagnosticsCache: PlaybackDiagnostics?
    private var diagnosticsCacheItem: ObjectIdentifier?
    private var diagnosticsCacheStatus: AVPlayerItem.Status?
    private var diagnosticsCacheTime: ContinuousClock.Instant?
    private var cachedSourceOptions: [SourceOptionSnapshot]?
    private var cachedSourceOptionsToken = ""
    private var loadingLiveChannel = false
    private var assetErrorCode: Int?
    private var assetFailureErrors: [MediaErrorCode]?
    private var inspectFirstLiveInput: Bool
    private let enableCompatibilityFallback: Bool
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
                source = try? MediaSelector.select(sourceCandidates, policy: conversionPolicy,
                                                    preferQuality: preferQuality)
                height = source.flatMap { Self.candidatesHeight(for: $0, in: sourceCandidates) }
            } else if let index = candidateIndex(forOptionID: sourceID) {
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
    var requires4KOutput: Bool { requires4KOutput(for: nil) }
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
    private let inspectVideoEvidence: @Sendable (URL) async -> Bool
    private let inspectStreamingVideo: @Sendable (URL) async -> StreamingVideoCharacteristics?
    private let makePlayerItem: @MainActor (AVURLAsset) -> AVPlayerItem
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
    /// Hides the failed-item message without changing the failed playback state.
    private var playbackErrorDismissed = false
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
    private var replacingReceiverItem = false
    private var keepReceiverOnFailure = false
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
         inspectVideoEvidence: @escaping @Sendable (URL) async -> Bool = { await HLSVideoEvidence.hasVideo(at: $0) },
         inspectStreamingVideo: @escaping @Sendable (URL) async -> StreamingVideoCharacteristics? = { await HLSVideoEvidence.inspectTransportVideo(at: $0) },
         inspectFirstLiveInput: Bool = false,
         enableCompatibilityFallback: Bool = true,
         makePlayerItem: @escaping @MainActor (AVURLAsset) -> AVPlayerItem = { AVPlayerItem(asset: $0) },
         checkHTTPAuthentication: (@MainActor @Sendable (URL, HTTPLoginCredentials?) async throws -> HTTPLoginChallenge?)? = nil,
         loadIPTVCatalog: @escaping @Sendable (URL) async throws -> IPTVCatalog = { try await IPTVCatalogLoader.load($0) },
         historyStore: MediaHistoryStore? = nil,
         allowVideoConversion: Bool? = nil,
         preferQuality: Bool? = nil,
         xtreamCatalogStore: XtreamCatalogStore = .shared,
         xtreamCatalogDefaults: UserDefaults = .standard,
         resolvePlaylist: @escaping @Sendable (URL) async throws -> ResolvedPlaylist = {
        try await SourceResolver(sessions: WebsiteCookiePreference.current()).resolvePlaylist($0)
    }, prepareSource: (@Sendable (ResolvedSource) async throws -> PreparedMedia)? = {
        try await MediaPreparer(preferences: .current()).prepare($0)
    }, afterPlaybackBehavior: @escaping @MainActor () -> AfterPlaybackBehavior = {
        guard let raw = UserDefaults.standard.string(forKey: "afterPlaybackBehavior") else { return .keepConnected }
        return AfterPlaybackBehavior(rawValue: raw) ?? .keepConnected
    }) {
        self.player = player
        self.inspectVideoEvidence = inspectVideoEvidence
        self.inspectStreamingVideo = inspectStreamingVideo
        self.inspectFirstLiveInput = inspectFirstLiveInput
        self.enableCompatibilityFallback = enableCompatibilityFallback
        #if DEBUG
        self.inspectFirstLiveInput = inspectFirstLiveInput
            || ProcessInfo.processInfo.environment["AIRTHROW_DIAGNOSE_FIRST_LIVE_INPUT"] == "1"
        #endif
        self.makePlayerItem = makePlayerItem
        self.xtreamCatalogStore = xtreamCatalogStore
        self.xtreamCatalogDefaults = xtreamCatalogDefaults
        self.saveXtreamCatalogs = xtreamCatalogDefaults.bool(forKey: XtreamCatalogStore.preferenceKey)
        self.historyStore = historyStore ?? MediaHistoryStore(defaults: resolveSource == nil && resolveCandidates == nil ? .standard : nil)
        self.history = self.historyStore.entries
        self.loadIPTVCatalog = loadIPTVCatalog
        // Injected resolvers in offline checks keep their original contract.
        if let checkHTTPAuthentication { self.checkHTTPAuthentication = checkHTTPAuthentication }
        else if resolveCandidates == nil && resolveSource == nil {
            self.checkHTTPAuthentication = { try await HTTPAuthentication.challenge(for: $0, credentials: $1) }
        } else { self.checkHTTPAuthentication = nil }
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
            refreshOnChange(of: player, \.isExternalPlaybackActive),
            refreshOnChange(of: player, \.timeControlStatus),
            refreshOnChange(of: player, \.rate)
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        installRemoteCommands()
        updateNowPlaying()
    }

    /// A nil generation refreshes for the player's whole lifetime; otherwise only while that load is current.
    private func refreshOnChange<Object: NSObject, Value>(of object: Object, _ keyPath: KeyPath<Object, Value>,
                                                          generation id: UUID? = nil) -> NSKeyValueObservation {
        object.observe(keyPath, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, id == nil || self.generation == id else { return }
                self.refresh()
            }
        }
    }

    func load(_ input: String, autoplay: Bool = false) throws {
        let url = try MediaInput.source(input)
        sourceInput = input
        loadSource(url, autoplay: autoplay)
    }

    private func loadSource(_ url: URL, autoplay: Bool = false) {
        cancelIPTVImport()
        inspectorPage = .history
        if IPTVPlaylist.isCatalogSource(url) {
            importIPTV(url: url, hlsAutoplay: autoplay && player.isExternalPlaybackActive)
            return
        }
        // Picker intent is not an active route. Never arm an incoming request
        // to start later merely because a receiver may subsequently connect.
        let shouldPlay = autoplay && player.isExternalPlaybackActive
        if SourceResolver.playlistPage(url) != nil {
            startPlaylistLoad(url, autoplay: shouldPlay)
        } else {
            let preferences = SourceResolver.youtubeStartSeconds(url).map { seconds in
                LoadPreferences(conversion: conversionPolicy, preferQuality: preferQuality,
                                enhancement: .original, enhancementOutput4K: enhancementOutput4K,
                                pinnedSourceID: nil, subtitle: nil, resumePosition: seconds)
            }
            startLoad(url, autoplay: shouldPlay, preferences: preferences, recordHistory: true)
        }
        if autoplay && !shouldPlay {
            notice = "Video will load paused. Choose a receiver using AirPlay, then press Play."
        }
    }

    func importIPTV(_ input: String) throws {
        sourceInput = input
        importIPTV(url: try MediaInput.source(input))
    }

    func selectHistoryEntry(_ id: UUID) throws {
        guard let entry = history.first(where: { $0.id == id }) else { return }
        let source = try historyStore.source(for: entry)
        // History loads its stored source internally; it is not a new draft
        // for the editable field, particularly for credential-bearing sources.
        sourceInput = ""
        if entry.kind == .xtream {
            if let library = xtreamLibrary, library.source == source {
                cancelIPTVImport()
                historyStore.markOpened(id); history = historyStore.entries
                inspectorPage = .xtream
                if library.listing.items.isEmpty && !library.loading { library.browse(library.section, categoryID: library.categoryID) }
            } else { try connectXtream(source, historyEntryID: id) }
        } else if entry.kind == .iptv {
            if iptvSourceURL == source, iptvCatalog != nil {
                cancelIPTVImport()
                historyStore.markOpened(id); history = historyStore.entries
                inspectorPage = .channels
            } else { importIPTV(url: source) }
        } else { loadSource(source) }
    }

    func removeHistoryEntry(_ id: UUID) {
        historyStore.remove(id); publishHistoryChange()
    }
    func toggleHistoryPin(_ id: UUID) { historyStore.togglePin(id); history = historyStore.entries }
    func clearHistory() {
        historyStore.clear(); publishHistoryChange()
    }
    private func recordHistory(_ url: URL, title: String, kind: MediaHistoryEntry.Kind) {
        historyStore.record(url, title: title, kind: kind); publishHistoryChange()
    }
    /// For operations that can write or delete Keychain credentials.
    private func publishHistoryChange() {
        history = historyStore.entries
        if let error = historyStore.credentialError { notice = error }
    }

    func connectXtream(_ source: URL, historyEntryID: UUID? = nil, reportInSheet: Bool = false) throws {
        let account = try XtreamAccount(source: source)
        cancelIPTVImport()
        let id = iptvImportID
        iptvImporting = true; iptvImportError = nil
        if reportInSheet { xtreamSigningIn = true; xtreamSignInError = nil }
        // Leave playback and the previous working catalog mounted while signing in.
        iptvImportTask = Task { [weak self] in
            do {
                let client = XtreamClient(account: account)
                let info = try await client.authenticate()
                guard !Task.isCancelled, let self, self.iptvImportID == id else { return }
                self.xtreamLibrary?.cancelLoading(); self.xtreamLibrary?.back()
                let library = XtreamLibrary(client: client, accountInfo: info, catalogStore: self.xtreamCatalogStore)
                self.xtreamLibrary = library
                if let historyEntryID {
                    self.historyStore.markOpened(historyEntryID); self.history = self.historyStore.entries
                } else {
                    self.recordHistory(account.source, title: account.server.host ?? "Xtream", kind: .xtream)
                }
                self.inspectorPage = .xtream
                self.iptvImporting = false; self.iptvImportTask = nil
                self.xtreamSigningIn = false
                library.browse(.live)
            } catch {
                guard !Task.isCancelled, let self, self.iptvImportID == id else { return }
                self.iptvImporting = false; self.iptvImportTask = nil
                self.xtreamSigningIn = false
                let message = XtreamFailure.message(for: error)
                if reportInSheet { self.xtreamSignInError = message }
                else { self.iptvImportError = message }
            }
        }
    }

    func clearXtreamSignInError() { xtreamSignInError = nil }

    func setSaveXtreamCatalogs(_ enabled: Bool) {
        saveXtreamCatalogs = enabled
        xtreamCatalogDefaults.set(enabled, forKey: XtreamCatalogStore.preferenceKey)
        let previous = catalogPersistenceTask, store = xtreamCatalogStore
        catalogPersistenceTask = Task { [weak self] in
            await previous?.value
            await store.setEnabled(enabled)
            if enabled, let self, self.saveXtreamCatalogs { await self.xtreamLibrary?.persistCatalogs() }
        }
    }

    func selectXtreamMedia(_ url: URL, title: String, isLive: Bool = false) throws {
        let url = try MediaInput.url(url.absoluteString)
        let autoplay = replacementAutoplay
        startLoad(url, autoplay: autoplay, titleOverride: title, liveChannel: isLive)
        selectedIPTVChannelID = nil
    }

    private func importIPTV(url: URL, hlsAutoplay: Bool? = nil) {
        cancelIPTVImport()
        let id = iptvImportID
        let mediaGeneration = generation
        iptvImporting = true; iptvImportError = nil
        let loader = loadIPTVCatalog
        iptvImportTask = Task { [weak self] in
            do {
                let catalog = try await loader(url)
                guard !Task.isCancelled, let self, self.iptvImportID == id else { return }
                self.iptvCatalog = catalog
                self.iptvSourceURL = url
                self.recordHistory(url, title: catalog.title, kind: .iptv)
                self.inspectorPage = .channels
                self.selectedIPTVChannelID = nil
                self.iptvImporting = false; self.iptvImportTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.iptvImportID == id else { return }
                self.iptvImporting = false; self.iptvImportTask = nil
                if let hlsAutoplay, case IPTVCatalogFailure.hlsPlaylist = error {
                    guard self.generation == mediaGeneration else { return }
                    self.startLoad(url, autoplay: hlsAutoplay, recordHistory: true)
                    return
                }
                self.iptvImportError = IPTVCatalogFailure.message(for: error)
            }
        }
    }

    func cancelIPTVImport() {
        iptvImportID = UUID()
        iptvImportTask?.cancel(); iptvImportTask = nil
        iptvImporting = false; iptvImportError = nil
        xtreamSigningIn = false
        xtreamSignInError = nil
    }
    func clearIPTVImportError() { iptvImportError = nil }

    func selectIPTVChannel(_ id: UUID) throws {
        guard let channel = iptvCatalog?.channels.first(where: { $0.id == id }) else {
            throw AppFailure(.invalidRequest, "This channel is no longer available. Choose a channel from the current playlist.")
        }
        let autoplay = replacementAutoplay
        startLoad(channel.url, autoplay: autoplay, titleOverride: channel.name, liveChannel: true)
        selectedIPTVChannelID = id
    }

    private var replacementAutoplay: Bool {
        PlaybackPolicy.shouldAutoplayReplacement(pendingPlay: playWhenReady, playbackRequested: playbackRequested,
            external: player.isExternalPlaybackActive, playing: player.rate > 0,
            recoveringReceiver: failure != nil && keepReceiverOnFailure)
    }

    private var conversionPolicy: ConversionPolicy { allowVideoConversion ? .allowVideo : .avoidVideo }


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
            guard let index = candidateIndex(forOptionID: optionID) else {
                throw AppFailure(.invalidRequest, "This source choice has expired. List sources again.")
            }
            candidateID = try loadableCandidateID(sourceCandidates[index])
        }
        startLoad(url, preservingQueue: queue != nil, titleOverride: title, sourceChoice: candidateID,
                  changingSource: true, enhancement: videoEnhancement,
                  enhancementOutput4K: enhancementOutput4K)
    }

    /// A video choice keeps the current language if the new paired video offers it.
    func selectVideo(_ optionID: String) throws {
        guard optionID != "automatic", let index = candidateIndex(forOptionID: optionID) else {
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
            return candidate.sharesVideo(with: picked) && candidate.audioLanguage == language
                && candidate.unavailableReason(for: conversionPolicy) == nil
        }
        try selectSource(sourceOptionID(matching ?? index))
    }

    private var preferredAudioLanguage: String? {
        if let selectedNativeAudioID {
            return selectedSource?.hlsAudioOptions.first(where: { $0.id == selectedNativeAudioID })?.language
        }
        return selectedSource.flatMap { Self.candidate(presenting: $0, in: sourceCandidates) }?.audioLanguage
    }

    private func candidateIndex(forOptionID optionID: String?) -> Int? {
        sourceCandidates.indices.first { sourceOptionID($0) == optionID }
    }

    /// The identity to pin for an explicit choice, or the reason it cannot load.
    private func loadableCandidateID(_ candidate: MediaCandidate) throws -> String {
        guard hasUniqueID(candidate) else {
            throw AppFailure(.unsupportedOperation, "This source cannot be identified uniquely. Choose Automatic.")
        }
        if let reason = candidate.unavailableReason(for: conversionPolicy) {
            throw AppFailure(.unsupportedOperation, reason)
        }
        return candidate.id
    }

    private func hasUniqueID(_ candidate: MediaCandidate) -> Bool {
        sourceCandidates.filter { $0.id == candidate.id }.count == 1
    }

    private static func candidate(presenting source: ResolvedSource, in candidates: [MediaCandidate]) -> MediaCandidate? {
        candidates.first { $0.source.url == source.url && $0.source.audio?.url == source.audio?.url }
    }

    private func requireDiscoveredSource() throws -> URL {
        guard let url = originalSourceURL, selectedSource != nil else {
            throw AppFailure(.unsupportedOperation, "Wait for source discovery to finish.")
        }
        return url
    }

    private func requireOnDemand() throws {
        guard !snapshot.isLive, selectedSource?.isLive != true else {
            throw AppFailure(.unsupportedOperation, "Enhancement is available for on-demand video, not live streams.")
        }
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
        _ = try requireDiscoveredSource()
        try requireOnDemand()
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
        let url = try requireDiscoveredSource()
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
            guard let index = candidateIndex(forOptionID: sourceID) else {
                throw AppFailure(.invalidRequest, "This source choice has expired. Open Video options again.")
            }
            let picked = sourceCandidates[index]
            let language = preferredAudioLanguage
            let matching = picked.source.audio == nil || language == nil ? nil : sourceCandidates.first { candidate in
                candidate.sharesVideo(with: picked) && candidate.audioLanguage == language
                    && candidate.unavailableReason(for: conversionPolicy) == nil
            }
            let candidate = matching ?? picked
            candidateID = try loadableCandidateID(candidate)
            guard enhancement.targetHeight != 1080 || (candidate.height ?? 0) <= 1080 else {
                throw AppFailure(.unsupportedOperation, "This source is above 1080p. Choose 4K to avoid downscaling.")
            }
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
        let url = try requireDiscoveredSource()
        try requireOnDemand()
        guard enhancement != videoEnhancement else { return }
        guard enhancement.targetHeight != 1080 || !requires4KOutput else {
            throw AppFailure(.unsupportedOperation, "This source is above 1080p. Choose 4K to avoid downscaling.")
        }
        let pinnedSourceID = sourceChoice == nil
            ? selectedSource.flatMap { Self.candidate(presenting: $0, in: sourceCandidates) }?.id : nil
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
        guard let current = Self.candidate(presenting: selectedSource, in: sourceCandidates),
              current.source.audio != nil else { return [] }
        return sourceCandidates.enumerated().compactMap { index, candidate in
            guard candidate.sharesVideo(with: current), let label = candidate.audioDescription else { return nil }
            return AudioChoice(snapshot: AudioOptionSnapshot(
                id: "\(sourceOptionsGeneration.uuidString)-audio-candidate-\(index)",
                label: label,
                unavailableReason: candidate.unavailableReason(for: conversionPolicy)),
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
        if let variant = source.hlsVariant { return qualityLabel(height: variant.height, frameRate: variant.frameRate) }
        return candidate(presenting: source, in: candidates).flatMap(qualityLabel)
    }

    private static func candidatesHeight(for source: ResolvedSource, in candidates: [MediaCandidate]) -> Double? {
        if let variant = source.hlsVariant { return Double(variant.height) }
        return candidate(presenting: source, in: candidates)?.height
    }

    private var sourceOptions: [SourceOptionSnapshot]? {
        guard !sourceCandidates.isEmpty else { cachedSourceOptions = nil; cachedSourceOptionsToken = ""; return nil }
        let token = "\(sourceOptionsGeneration.uuidString)|\(conversionPolicy)|\(sourceCandidates.count)|"
            + sourceCandidates.map(\.id).joined(separator: ",")
        if token == cachedSourceOptionsToken { return cachedSourceOptions }
        let built = sourceCandidates.enumerated().map { index, candidate in
            let videoIndex = sourceCandidates.firstIndex { $0.sharesVideo(with: candidate) } ?? index
            let quality: String
            if let base = Self.qualityLabel(candidate) {
                quality = base + (candidate.source.delivery == .hls && candidate.source.hlsVariant == nil ? " maximum (adaptive)" : "")
            } else { quality = "Quality unknown" }
            return SourceOptionSnapshot(id: sourceOptionID(index), quality: quality,
                audio: candidate.audioDescription, playbackPath: candidate.source.playbackPath,
                unavailableReason: !hasUniqueID(candidate)
                    ? "This source cannot be identified uniquely. Choose Automatic."
                    : candidate.unavailableReason(for: conversionPolicy),
                videoGroupID: "\(sourceOptionsGeneration.uuidString)-video-\(videoIndex)",
                bitrate: candidate.bitrate, isAdaptive: candidate.source.delivery == .hls && candidate.source.hlsVariant == nil)
        }
        cachedSourceOptionsToken = token
        cachedSourceOptions = built
        return built
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
                if playlist.entries.contains(where: { $0.url != nil }) {
                    self.recordHistory(url, title: playlist.title, kind: .playlist)
                }
                self.inspectorPage = .playlist
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
                           preferences: LoadPreferences? = nil, recordHistory: Bool = false,
                           liveChannel: Bool? = nil) {
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
        let receiverReplacement = player.currentItem != nil && (player.isExternalPlaybackActive || playWhenReady)
        let canInspectBeforePlayback = player.currentItem == nil || waitingScreen.ownsCurrentItem
        let retainReceiver = keepReceiverOnFailure || player.isExternalPlaybackActive || waitingScreen.isActive
        let retainedInspection = changingSource || retry || fallback != nil ? inspectedSourceHeight : nil
        let retainedVideoSample = fallback != nil ? sampledVideo : nil
        let retainedSampleStatus = fallback != nil ? sampleInspectionStatus : nil
        let retainedLiveChannel = liveChannel ?? ((changingSource || retry || fallback != nil) && loadingLiveChannel)
        let retainedAutoplayDeadline = autoplay && (preservingQueue || retry || fallback != nil)
            ? autoplayRouteDeadline : nil
        let retainedChannel = changingSource || retry || fallback != nil ? selectedIPTVChannelID : nil
        let retainedHistoryURL = changingSource || retry || fallback != nil ? pendingHistoryURL : nil
        let retainedAuthentication = originalSourceURL == url && (changingSource || retry || fallback != nil)
            ? authenticatedMedia : nil
        if retainedAuthentication != nil { authenticatedMedia = nil }
        resetItem(keepPlayerItem: true, preserveQueue: preservingQueue)
        replacingReceiverItem = receiverReplacement
        keepReceiverOnFailure = retainReceiver
        loadingLiveChannel = retainedLiveChannel
        pendingHistoryURL = recordHistory ? url : retainedHistoryURL
        authenticatedMedia = retainedAuthentication
        selectedIPTVChannelID = retainedChannel
        hasPlayed = previouslyPlayed
        inspectedSourceHeight = retainedInspection
        sampledVideo = retainedVideoSample
        sampleInspectionStatus = retainedSampleStatus
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
                if let fallback {
                    source = fallback.withConversionPolicy(fallback.playbackPath == .remux ? fallback.conversionPolicy : policy)
                }
                else {
                    guard let self else { return }
                    let resolvedURL = try await self.authenticatedURL(for: url, generation: id)
                    try Task.checkCancellation()
                    guard self.generation == id else { return }
                    let candidates = try await resolver(resolvedURL)
                    guard !Task.isCancelled, self.generation == id else { return }
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
                if self.loadingLiveChannel { source = source.withLivePresentation() }
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
                if let variant = source.hlsVariant {
                    let relay = try await HTTPMediaRelay.start(source: source.url, variant: variant)
                    guard !Task.isCancelled, self.generation == id else { relay.stop(); return }
                    self.variantMediaRelay = relay
                }
                // Inspect before mounting an unknown streaming item, not while it is
                // playing. Unknown metadata stays native; only a positively
                // identified HEVC-in-TS HLS presentation changes its plan.
                // Helpers receive a local sample, never the protected origin.
                let checkCompatibility = self.enableCompatibilityFallback && self.prepareSource != nil
                    && MediaSelector.shouldInspectCompatibility(of: source)
                if (checkCompatibility || (self.inspectFirstLiveInput && canInspectBeforePlayback && source.isLive)),
                   fallback == nil, source.playbackPath == .direct,
                   !source.needsPreparationPipeline, !source.url.isFileURL {
                    self.inspectFirstLiveInput = false
                    self.sampleInspectionStatus = .pending
                    self.refresh()
                    let sample = await self.inspectStreamingVideo(self.variantMediaRelay?.url ?? source.url)
                    guard !Task.isCancelled, self.generation == id else { return }
                    self.sampledVideo = sample
                    self.sampleInspectionStatus = sample == nil ? .unavailable : .complete
                    if sample?.isLive == true { source = source.withLivePresentation() }
                    if checkCompatibility, let remux = MediaSelector.remuxFallback(for: source, sampledVideo: sample) {
                        source = remux
                        self.notice = "Preparing a compatible stream for AirPlay."
                    }
                }
                self.selectedSource = source
                // Works for the remux fallback too: it reuses the original
                // candidates, so the fallback keeps the source's quality label.
                self.selectedQuality = Self.qualityLabel(for: source, in: self.sourceCandidates)
                if let sourceTitle = source.title, self.selectedIPTVChannelID == nil { self.title = sourceTitle }
                self.resolving = false
                var playbackURL = self.variantMediaRelay?.url ?? source.url
                if source.needsPreparationPipeline {
                    guard let prepareSource = self.prepareSource else { throw PreparationFailure.unsupported }
                    self.preparing = true
                    self.timeoutTask?.cancel()
                    self.refresh()
                    var preparationInput = self.variantMediaRelay?.url.map { source.withPreparationInput($0) } ?? source
                    // Keep protected origins out of helper arguments. The
                    // app owns upstream requests; helpers see an opaque loopback route.
                    if self.variantMediaRelay == nil, source.plannedPath == .remux, source.videoKnownPresent,
                       !source.url.isFileURL, source.headers.isEmpty, source.audio == nil {
                        let relay = try await HTTPMediaRelay.start(source: source.url, host: "127.0.0.1")
                        guard !Task.isCancelled, self.generation == id, let local = relay.url else {
                            relay.stop(); return
                        }
                        self.preparationInputRelay = relay
                        preparationInput = source.withPreparationInput(local)
                    }
                    let prepared = try await prepareSource(preparationInput)
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
                if ProcessInfo.processInfo.environment["AIRTHROW_DIAGNOSE_HLS_VARIANTS"] == "1",
                   source.playbackPath == .direct, source.delivery == .hls {
                    // Ask the installed asset for advertised attributes; never
                    // access a variant URL or export manifest/provider text.
                    let variants = try? await asset.load(.variants)
                    guard !Task.isCancelled, self.generation == id else { return }
                    self.hlsVariantCount = variants?.count
                    self.hlsVariants = variants.map(MediaDiagnostics.hlsVariants)
                }
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
                if !videoConfirmed, !self.loadingLiveChannel, !source.isLive {
                    // Streaming assets can hide their tracks after an AirPlay
                    // handoff. Inspect the presentation itself without relying
                    // on a file extension, provider, or previously loaded item.
                    videoConfirmed = await self.inspectVideoEvidence(playbackURL)
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
                let item = self.makePlayerItem(asset)
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
                    self.refreshOnChange(of: item, \.status, generation: id),
                    self.refreshOnChange(of: item, \.tracks, generation: id),
                    self.refreshOnChange(of: item, \.presentationSize, generation: id),
                    self.refreshOnChange(of: item, \.seekableTimeRanges, generation: id)
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
                    let errorCode = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?.code
                    let errors = MediaDiagnostics.numericErrors(for: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
                    let reason = MediaDiagnostics.reason(
                        for: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError,
                        fallback: .playbackInterrupted)
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.fail(reason, errorCode: errorCode, errors: errors)
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
                if let failure = error as? HTTPLoginFailure {
                    self.fail(.httpAuthenticationRequired, message: failure.message, advancingQueue: false)
                    return
                }
                // Keep a validator's specific message instead of flattening it to
                // the generic load failure, e.g. a local file removed after input
                // validation.
                if let appFailure = error as? AppFailure {
                    self.fail(.loadFailed, message: appFailure.message)
                    return
                }
                let reason = (error as? PreparationFailure)?.reason ?? (error as? ResolutionFailure)?.reason
                    ?? MediaDiagnostics.reason(for: error, fallback: .loadFailed)
                self.assetErrorCode = (error as NSError).code
                self.assetFailureErrors = MediaDiagnostics.numericErrors(for: error)
                self.fail(reason)
            }
        }
        drainingLoads[id] = loadTask
        if !resolving { scheduleLoadTimeout(id: id) }
    }

    func submitHTTPLogin(id: UUID, username: String, password: String) {
        guard let request = httpLoginRequest, request.id == id, !username.isEmpty, httpLoginContinuation != nil else { return }
        let continuation = httpLoginContinuation
        httpLoginContinuation = nil
        var pending = request; pending.submitting = true; pending.username = username; httpLoginRequest = pending
        continuation?.resume(returning: HTTPLoginCredentials(challenge: request.challenge, username: username, password: password))
    }

    func cancelHTTPLogin(id: UUID) {
        guard httpLoginRequest?.id == id else { return }
        stop()
    }

    private func clearHTTPLogin() {
        let continuation = httpLoginContinuation
        httpLoginContinuation = nil; httpLoginRequest = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func authenticatedURL(for url: URL, generation id: UUID) async throws -> URL {
        if let authenticatedMedia, authenticatedMedia.source == url, let relayURL = authenticatedMedia.url { return relayURL }
        guard !url.isFileURL,
              WebsiteService.service(for: url) == nil || SourceResolver.isDirectMediaHint(url),
              let checkHTTPAuthentication else { return url }
        var challenge: HTTPLoginChallenge?
        do { challenge = try await checkHTTPAuthentication(url, nil) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as HTTPLoginFailure { throw failure }
        catch { return url } // Native loading still diagnoses ordinary network failures.
        var retry = false
        while let required = challenge {
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            timeoutTask?.cancel()
            let credentials = try await withCheckedThrowingContinuation { continuation in
                httpLoginContinuation = continuation
                httpLoginRequest = HTTPLoginRequest(challenge: required, retry: retry, username: httpLoginRequest?.username ?? "")
                refresh()
            }
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            scheduleLoadTimeout(id: id)
            challenge = try await checkHTTPAuthentication(url, credentials)
            if challenge == nil {
                let relay = try await HTTPMediaRelay.start(source: url, credentials: credentials)
                guard !Task.isCancelled, generation == id else { relay.stop(); throw CancellationError() }
                httpLoginRequest = nil
                authenticatedMedia = relay
                guard let relayURL = relay.url else { relay.stop(); throw HTTPLoginFailure.unavailable }
                return relayURL
            }
            retry = true
        }
        return url
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
        let autoplay = replacementAutoplay
        loadQueueItem(at: queue.currentIndex - 1, direction: -1, autoplay: autoplay)
    }

    func next() throws {
        guard let queue, queue.currentIndex + 1 < queue.entries.count else {
            throw AppFailure(.unsupportedOperation, "There is no next playlist item.")
        }
        let autoplay = replacementAutoplay
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
        if !skippedTitles.isEmpty { notice = InterfaceCopy.skippedPlaylistItems(skippedTitles.count) }
        startLoad(url, preservingQueue: true, autoplay: autoplay, titleOverride: queue.entries[index].title)
    }

    func seek(_ seconds: Double) throws {
        guard !snapshot.isLive || LivePolicy.supportsTimeShift(snapshot) else {
            throw AppFailure(.unsupportedOperation, "This live stream does not currently offer a rewind window.")
        }
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
        guard let target = PlaybackPolicy.skipTarget(snapshot, by: seconds, position: pendingSeek) else {
            throw AppFailure(.unsupportedOperation, "The requested position is outside the currently seekable window.")
        }
        try seek(target)
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
        drain(prepared)
    }

    private func stopRetiredPreparedMedia() {
        guard let retired = retiredPreparedMedia else { return }
        retiredPreparedMedia = nil
        drain(retired)
    }

    /// Stops a delivery and keeps its producer tracked until it has exited.
    private func drain(_ prepared: PreparedMedia) {
        prepared.stop()
        let id = UUID()
        drainingLoads[id] = Task { [weak self] in
            await prepared.waitForProducer()
            self?.drainingLoads.removeValue(forKey: id)
        }
    }

    /// Deliveries kept alive only while AVPlayer still retains the replaced item.
    private var hasRetiredDelivery: Bool {
        retiredPreparedMedia != nil || retiredAuthenticatedMedia != nil || retiredVariantMediaRelay != nil
    }

    private func releaseRetiredDelivery() {
        stopRetiredPreparedMedia()
        retiredAuthenticatedMedia?.stop(); retiredAuthenticatedMedia = nil
        retiredVariantMediaRelay?.stop(); retiredVariantMediaRelay = nil
    }

    private func detachItemObservers() {
        itemObservations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
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

    private func resetItem(keepPlayerItem: Bool = false, preserveQueue: Bool = false) {
        pendingHistoryURL = nil
        waitingScreen.stop(keepingItemForReplacement: keepPlayerItem)
        clearHTTPLogin()
        selectedIPTVChannelID = nil
        if let relay = variantMediaRelay {
            if keepPlayerItem, mediaItem != nil, player.currentItem === mediaItem {
                retiredVariantMediaRelay?.stop(); retiredVariantMediaRelay = relay
            } else { relay.stop() }
            variantMediaRelay = nil
        }
        if let authenticatedMedia {
            if keepPlayerItem, mediaItem != nil, player.currentItem === mediaItem {
                retiredAuthenticatedMedia?.stop(); retiredAuthenticatedMedia = authenticatedMedia
            } else { authenticatedMedia.stop() }
            self.authenticatedMedia = nil
        }
        let installedPrepared = preparedMedia != nil && mediaItem != nil && player.currentItem === mediaItem
        generation = UUID()
        loadTask?.cancel(); loadTask = nil
        sampledVideo = nil
        sampleInspectionStatus = nil
        hlsVariants = nil; hlsVariantCount = nil
        preparationInputRelay?.stop(); preparationInputRelay = nil
        lastLivePipeline = nil
        lastFailureDiagnostics = nil
        loadingLiveChannel = false
        assetErrorCode = nil
        assetFailureErrors = nil
        loadingAsset?.cancelLoading(); loadingAsset = nil
        timeoutTask?.cancel(); timeoutTask = nil
        cancelProbe(restorePosition: false)
        player.isMuted = true
        player.pause()
        detachItemObservers()
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
            releaseRetiredDelivery()
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
        ended = false; hasPlayed = false; failure = nil; failureReason = nil; playbackErrorDismissed = false
        playWhenReady = false
        pendingAutoplaySeek = false
        replacementPlayTask?.cancel(); replacementPlayTask = nil
        replacingReceiverItem = false
        keepReceiverOnFailure = false
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

    private func fail(_ reason: MediaFailureReason, message: String? = nil, advancingQueue: Bool = true,
                      errorCode: Int? = nil, errors: [MediaErrorCode]? = nil) {
        // A producer failure may cancel an in-flight asset load. Preserve the
        // original diagnosis when that cancellation subsequently reports back.
        guard failure == nil else { return }
        // A stale signed source may fail during initial loading. Resolve once more,
        // still paused. Never restart established playback or retry indefinitely.
        if reason == .sourceUnavailable, let websiteURL, !retriedResolution, !hasPlayed {
            startLoad(websiteURL, retry: true, preservingQueue: queue != nil,
                      autoplay: replacementAutoplay, titleOverride: queue.map { $0.entries[$0.currentIndex].title },
                      sourceChoice: sourceChoice, changingSource: changingSource, preferences: loadPreferences)
            return
        }
        if enableCompatibilityFallback, prepareSource != nil, let selectedSource,
           let remuxFallback = MediaSelector.remuxFallback(for: selectedSource, reason: reason, hasPlayed: hasPlayed) {
            // Prefer the best available remux presentation over remuxing the
            // failed native URL, so a fallback is not stuck at the low-quality
            // direct stream.
            let fallback = sourceChoice == nil && !selectedSource.isLive
                ? (MediaSelector.bestRemuxFallback(from: sourceCandidates, policy: .avoidVideo)
                   ?? remuxFallback)
                : remuxFallback
            startLoad(originalSourceURL ?? selectedSource.url, retry: retriedResolution, fallback: fallback,
                      preservingQueue: queue != nil, autoplay: replacementAutoplay,
                      titleOverride: title, sourceChoice: sourceChoice, changingSource: changingSource,
                      preferences: loadPreferences)
            notice = "Preparing a compatible stream for AirPlay."
            return
        }
        if advancingQueue, reason != .signInRequired, !changingSource, sourceChoice == nil,
           var queue, queueAttemptsRemaining > 1 {
            queue.skipped.insert(queue.currentIndex)
            let failedTitle = queue.entries[queue.currentIndex].title
            let nextIndex = queue.currentIndex + queueDirection
            self.queue = queue
            notice = "Skipped “\(failedTitle)” because it could not be played."
            loadQueueItem(at: nextIndex, direction: queueDirection, autoplay: replacementAutoplay,
                          attemptsRemaining: queueAttemptsRemaining - 1)
            return
        }
        let restoreWaitingScreen = showReceiverWaitingScreen && keepReceiverOnFailure
        captureLivePipeline()
        var terminalDiagnostics = snapshot.diagnostics ?? PlaybackDiagnostics()
        terminalDiagnostics.livePipeline = lastLivePipeline
        terminalDiagnostics.sampledVideo = sampledVideo
        terminalDiagnostics.sampleInspectionStatus = sampleInspectionStatus
        terminalDiagnostics.assetErrorCode = assetErrorCode
        terminalDiagnostics.itemErrorCode = (mediaItem?.error as NSError?)?.code ?? errorCode
        terminalDiagnostics.failureErrors = errors ?? assetFailureErrors ?? MediaDiagnostics.numericErrors(for: mediaItem?.error)
        terminalDiagnostics.errorStatusCodes = mediaItem?.errorLog()?.events.suffix(8).map(\.errorStatusCode)
        lastFailureDiagnostics = terminalDiagnostics
        resolving = false
        preparing = false
        cancelProbe(restorePosition: false)
        loading = false
        clearHTTPLogin()
        authenticatedMedia?.stop(); authenticatedMedia = nil
        variantMediaRelay?.stop(); variantMediaRelay = nil
        failureReason = reason
        failure = message ?? reason.message
        playbackErrorDismissed = false
        loadTask?.cancel(); loadTask = nil
        sampledVideo = nil
        sampleInspectionStatus = nil
        preparationInputRelay?.stop(); preparationInputRelay = nil
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
        if !restoreWaitingScreen { player.replaceCurrentItem(with: nil) }
        releaseRetiredDelivery()
        loadingAsset?.cancelLoading(); loadingAsset = nil
        mediaItem = nil
        detachItemObservers()
        stopPreparedMedia()
        if restoreWaitingScreen { waitingScreen.start() }
        refresh()
    }

    private func finite(_ number: Double) -> Double? { number.isFinite && number >= 0 ? number : nil }

    private func seekRanges(_ ranges: [NSValue]) -> [SeekRange] {
        ranges.compactMap {
            let range = $0.timeRangeValue
            guard let start = finite(range.start.seconds),
                  let end = finite(CMTimeRangeGetEnd(range).seconds), end > start else { return nil }
            return SeekRange(start: start, end: end)
        }
    }

    private func metadataTitle(from asset: AVURLAsset) async -> String? {
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        let candidates = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
        guard let first = candidates.first,
              let value = try? await first.load(.stringValue) else { return nil }
        let cleaned = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(200))
    }

    private func captureLivePipeline() {
        guard preparedMedia != nil || preparationInputRelay != nil else { return }
        var result = preparedMedia?.liveDiagnostics ?? LivePipelineDiagnostics()
        if let relay = preparationInputRelay?.diagnostics {
            result.relayActiveStreams = relay.relayActiveStreams
            result.relayFinishedStreams = relay.relayFinishedStreams
            result.relayReceivedBytes = relay.relayReceivedBytes
            result.relayPeakBufferBytes = relay.relayPeakBufferBytes
            result.relayLastErrorCode = relay.relayLastErrorCode
            result.relayBufferLimitClosures = relay.relayBufferLimitClosures
            result.relayEOFClosures = relay.relayEOFClosures
            result.relayManifestResponses = relay.relayManifestResponses
            result.relayManifestEndLists = relay.relayManifestEndLists
            result.relayManifestVODs = relay.relayManifestVODs
            result.relayManifestSequence = relay.relayManifestSequence
            result.relayHTTPFailures = relay.relayHTTPFailures
            result.relayLastHTTPStatus = relay.relayLastHTTPStatus
        }
        lastLivePipeline = result
    }

    func refresh() {
        captureLivePipeline()
        waitingScreen.reconcile()
        if waitingScreen.isActive {
            var next = PlaybackSnapshot()
            next.receiverWaiting = true
            next.externalPlaybackActive = player.isExternalPlaybackActive
            next.state = next.externalPlaybackActive ? .idle : .connecting
            next.title = "Ready to play"
            if let failure {
                next.state = .failed
                next.title = title
                next.error = playbackErrorDismissed ? nil : failure
                next.errorReason = failureReason
            }
            next.allowVideoConversion = allowVideoConversion
            if let lastFailureDiagnostics {
                next.diagnostics = lastFailureDiagnostics
            } else if let lastLivePipeline {
                var diagnostics = PlaybackDiagnostics()
                diagnostics.livePipeline = lastLivePipeline
                next.diagnostics = diagnostics
            }
            wasExternal = next.externalPlaybackActive
            if snapshot != next { snapshot = next; updateNowPlaying() }
            updateSleepActivity()
            return
        }
        // Receiver-side controls must not resume a retained old item or a new
        // item whose video tracks are still being confirmed.
        if (mediaItem == nil || loading || failure != nil) && player.currentItem != nil {
            player.isMuted = true
            // A zero-rate item can still be waiting for initial buffering.
            // Reissuing Pause in that state interrupts the AirPlay handoff;
            // stop actual playback without cancelling each buffering attempt.
            if player.rate != 0 { player.pause() }
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
            if let source = selectedSource, !source.isLive, preparedMedia == nil,
               LivePolicy.isLive(sourceDuration: nil, itemDurationIndefinite: item.duration.isIndefinite) {
                selectedSource = source.withLivePresentation()
            }
            // Streaming assets may expose no AVAsset tracks. Inspect the ready
            // player item's tracks and size before concluding that video/audio is absent.
            let types = item.tracks.compactMap { $0.assetTrack?.mediaType }
            let completeTrackInfo = !types.isEmpty && types.count == item.tracks.count
            hasVideo = hasVideo || types.contains(.video)
                || (item.presentationSize.width > 0 && item.presentationSize.height > 0)
            if types.contains(.audio) { hasAudio = true }
            // A streaming item's tracks may arrive after readiness or change.
            // Their temporary lack of audio is not evidence of a silent source.
            // AirPlay can own the presentation and expose neither local tracks
            // nor a local size. A ready routed item must be allowed to start;
            // failed supplemental inspection is unknown, not proof of no video.
            // Still reject an item whose complete tracks show audio only.
            if hasVideo || (external && !completeTrackInfo) {
                loading = false
                timeoutTask?.cancel()
                if let url = pendingHistoryURL {
                    pendingHistoryURL = nil
                    recordHistory(url, title: title, kind: .video)
                }
            } else if completeTrackInfo {
                // Set the failure here without recursively entering refresh().
                fail(.noVideo)
                return
            }
            // Without a route, incomplete track information keeps loading until
            // video evidence arrives or the bounded load timeout expires.
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
        if hasRetiredDelivery, !loading, item?.status == .readyToPlay, !probing && !probeRestoring && !probeWhenReady {
            releaseRetiredDelivery()
        }
        if playWhenReady, pendingResumePosition == nil, !loading, item?.status == .readyToPlay, !probeRestoring && !probeRestoreFailed {
            if external && !probing {
                playbackRequested = true
                probeWhenReady = false
                hasPlayed = true
                if replacingReceiverItem || changingSource || selectedIPTVChannelID != nil || replacementPlayTask != nil {
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
        next.error = playbackErrorDismissed ? nil : failure
        next.errorReason = failureReason
        next.loadingPhase = httpLoginRequest != nil ? "authentication" : resolving ? "resolving" : (preparing ? "preparing" : nil)
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
        if let size = item?.presentationSize, size.width.isFinite, size.height.isFinite,
           (1...16384).contains(size.width), (1...16384).contains(size.height) {
            next.reportedVideoWidth = Int(size.width.rounded()); next.reportedVideoHeight = Int(size.height.rounded())
        }
        next.seekableRanges = seekRanges(item?.seekableTimeRanges ?? [])
        next.isLive = item?.status == .readyToPlay && (selectedSource?.isLive == true || LivePolicy.isLive(
            sourceDuration: preparedMedia?.sourceDuration,
            itemDurationIndefinite: item?.duration.isIndefinite == true))
        if next.isLive, let position = next.position, let edge = next.seekableRanges.last?.end {
            next.liveOffset = max(0, edge - position)
            next.recommendedLiveOffset = item.flatMap { finite($0.recommendedTimeOffsetFromLive.seconds) }
        }
        next.liveEdgeUpdateInterval = LivePolicy.edgeUpdateInterval(previous: snapshot, current: next)
        if let item {
            next.diagnostics = playbackDiagnostics(for: item)
        } else if let lastFailureDiagnostics {
            next.diagnostics = lastFailureDiagnostics
        } else if let lastLivePipeline {
            var diagnostics = PlaybackDiagnostics()
            diagnostics.livePipeline = lastLivePipeline
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
            let previous = snapshot
            snapshot = next
            if Self.shouldRefreshNowPlaying(previous, next) { updateNowPlaying() }
        }
        updateSleepActivity()
    }

    /// Codec descriptions and player logs stay valid for several seconds. Buffer
    /// and transport fields are still read on every tick.
    private func playbackDiagnostics(for item: AVPlayerItem) -> PlaybackDiagnostics {
        let now = ContinuousClock.now
        let reuse = diagnosticsCacheItem == ObjectIdentifier(item) && diagnosticsCacheStatus == item.status
            && diagnosticsCacheTime.map { now < $0.advanced(by: .seconds(5)) } == true
        var diagnostics = reuse ? (diagnosticsCache ?? PlaybackDiagnostics()) : PlaybackDiagnostics()
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
        diagnostics.sampledVideo = sampledVideo
        diagnostics.sourceDiscovery = sourceCandidates.compactMap(\.discovery).first
        diagnostics.hlsVariantCount = hlsVariantCount
        diagnostics.hlsVariants = hlsVariants
        diagnostics.sampleInspectionStatus = sampleInspectionStatus
        diagnostics.livePipeline = lastLivePipeline
        diagnostics.waitingReason = waitingReason(player.reasonForWaitingToPlay)
        diagnostics.bufferedRanges = seekRanges(item.loadedTimeRanges)
        diagnostics.bufferEmpty = item.isPlaybackBufferEmpty
        diagnostics.bufferFull = item.isPlaybackBufferFull
        diagnostics.likelyToKeepUp = item.isPlaybackLikelyToKeepUp
        diagnostics.itemErrorCode = (item.error as NSError?)?.code
        if !reuse {
            let videoFormats = item.tracks.compactMap(\.assetTrack)
                .filter { $0.mediaType == .video }
                .flatMap { $0.formatDescriptions as? [CMFormatDescription] ?? [] }
            if !videoFormats.isEmpty {
                diagnostics.videoCodecTypes = Array(Set(videoFormats.map(CMFormatDescriptionGetMediaSubType))).sorted()
                diagnostics.videoWidth = videoFormats.map { Int(CMVideoFormatDescriptionGetDimensions($0).width) }.max()
                diagnostics.videoHeight = videoFormats.map { Int(CMVideoFormatDescriptionGetDimensions($0).height) }.max()
            }
            if let errors = item.errorLog()?.events, !errors.isEmpty {
                diagnostics.errorStatusCodes = errors.suffix(8).map(\.errorStatusCode)
            }
            if let event = item.accessLog()?.events.last {
                diagnostics.observedBitrate = finite(event.observedBitrate)
                diagnostics.indicatedBitrate = finite(event.indicatedBitrate)
                diagnostics.stalls = event.numberOfStalls
            }
            diagnosticsCache = diagnostics
            diagnosticsCacheItem = ObjectIdentifier(item)
            diagnosticsCacheStatus = item.status
            diagnosticsCacheTime = now
        }
        return diagnostics
    }

    /// The system advances elapsed time from the last rate. Rewriting Now Playing
    /// on every playhead tick fights that clock.
    private static func shouldRefreshNowPlaying(_ previous: PlaybackSnapshot, _ next: PlaybackSnapshot) -> Bool {
        var stable = previous
        stable.position = next.position
        stable.liveOffset = next.liveOffset
        stable.diagnostics = next.diagnostics
        stable.preparedRanges = next.preparedRanges
        stable.preparationSpeed = next.preparationSpeed
        stable.preparationInProgress = next.preparationInProgress
        return stable != next
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

    /// Runs a user action and shows its failure as a notice.
    func perform(_ action: () throws -> Void) {
        do { try action() } catch { displayError(error) }
    }

    func togglePlayback() throws {
        if PlaybackPolicy.isPlaying(snapshot) { pause() } else { try play() }
    }

    func clearNotice() { notice = nil }

    /// Removes the visible failure text. Playback stays failed until the next load.
    func dismissPlaybackError() {
        guard failure != nil, !playbackErrorDismissed else { return }
        playbackErrorDismissed = true
        refresh()
    }

    /// Quit waits for cancelled jobs to reap their helpers and release temporary files.
    /// The wait is bounded so a stuck helper cannot keep the process open.
    func shutdownAndWait() async {
        shutdown()
        let pending = Array(drainingLoads.values)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ShutdownResume(continuation)
            Task {
                for job in pending { await job.value }
                once.finish()
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                once.finish()
            }
        }
    }

    func shutdown() {
        cancelIPTVImport()
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
                    if PlaybackPolicy.isPlaying(self.snapshot) { self.pause() } else { try self.play() }
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

private extension MediaCandidate {
    /// The same video stream, possibly paired with a different audio track.
    func sharesVideo(with other: MediaCandidate) -> Bool {
        source.url == other.source.url && source.headers == other.source.headers
            && source.playbackPath == other.source.playbackPath
    }
    var audioLanguage: String? { audioDescription?.components(separatedBy: " · ").first }
}
