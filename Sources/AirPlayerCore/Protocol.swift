import Foundation

public enum Command: String, Codable, Sendable {
    case open, play, pause, stop, seek, previous, next, status, show
}

public struct Request: Codable, Sendable {
    public var version: Int = 1
    public let command: Command
    public var url: String?
    public var seconds: Double?
    public init(_ command: Command, url: String? = nil, seconds: Double? = nil) {
        self.command = command
        self.url = url
        self.seconds = seconds
    }
}

public enum FailureCode: String, Codable, Sendable {
    case invalidRequest = "invalid_request"
    case appUnavailable = "app_unavailable"
    case routeRequired = "route_required"
    case unsupportedOperation = "unsupported_operation"
    case playbackFailed = "playback_failed"
    public var exitCode: Int32 {
        switch self {
        case .invalidRequest: 2
        case .appUnavailable: 3
        case .routeRequired: 4
        case .unsupportedOperation: 5
        case .playbackFailed: 6
        }
    }
}

public struct AppFailure: Error, Codable, Sendable, LocalizedError {
    public let code: FailureCode
    public let message: String
    public var errorDescription: String? { message }
    public init(_ code: FailureCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum PlaybackState: String, Codable, Sendable {
    case idle, loading, connecting, awaitingReceiver = "awaiting_receiver"
    case ready, buffering, playing, paused, ended, failed
}

/// Processing cost, not a quality score or proof of receiver playback.
public enum PlaybackPath: String, Codable, Sendable {
    case direct, remux
    public var tier: Int { self == .direct ? 1 : 2 }
    public var label: String { self == .direct ? "Direct playback" : "Remuxed playback" }
    public var explanation: String {
        switch self {
        case .direct: "Tier 1: Plays the source directly, without preparing a file on this Mac."
        case .remux: "Tier 2: Copies audio and video into compatible media on this Mac without re-encoding. Preparation may continue during playback."
        }
    }
}

public struct SeekRange: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public func contains(_ value: Double) -> Bool {
        value.isFinite && value >= start && value <= end
    }
}

public enum AfterPlaybackBehavior: String, Codable, Sendable, CaseIterable {
    case keepConnected = "keep_connected"
    case unloadVideo = "unload_video"
}

public enum PlaybackWaitingReason: String, Codable, Sendable {
    case minimizingStalls = "minimizing_stalls"
    case evaluatingBufferingRate = "evaluating_buffering_rate"
    case noItem = "no_item"
    case other
}

/// Numeric and categorical playback observations only. Source URLs, request
/// headers and AVFoundation error text are deliberately excluded.
public struct PlaybackDiagnostics: Codable, Sendable, Equatable {
    public var itemStatus: String?
    public var playerStatus: String?
    public var timeControlStatus: String?
    public var videoConfirmed: Bool?
    public var waitingReason: PlaybackWaitingReason?
    public var bufferedRanges: [SeekRange] = []
    public var bufferEmpty: Bool?
    public var bufferFull: Bool?
    public var likelyToKeepUp: Bool?
    public var observedBitrate: Double?
    public var indicatedBitrate: Double?
    public var stalls: Int?
    public init() {}
}

public enum QueueItemState: String, Codable, Sendable {
    case pending, current, skipped
}

public struct QueueItemSnapshot: Codable, Sendable, Equatable {
    public let title: String
    public let state: QueueItemState
    public init(title: String, state: QueueItemState) {
        self.title = title
        self.state = state
    }
}

public struct PlaybackQueueSnapshot: Codable, Sendable, Equatable {
    public let title: String
    /// Zero-based index of the current entry.
    public let currentIndex: Int
    public let items: [QueueItemSnapshot]
    public let truncated: Bool
    public init(title: String, currentIndex: Int, items: [QueueItemSnapshot], truncated: Bool) {
        self.title = title
        self.currentIndex = currentIndex
        self.items = items
        self.truncated = truncated
    }
}

public enum MediaFailureReason: String, Codable, Sendable {
    case network, sourceUnavailable = "source_unavailable"
    case unreadableMedia = "unreadable_media", noVideo = "no_video"
    case protectedMedia = "protected_media", externalPlaybackUnsupported = "external_playback_unsupported"
    case loadFailed = "load_failed", playbackInterrupted = "playback_interrupted"

    case resolverUnavailable = "resolver_unavailable", resolutionFailed = "resolution_failed"
    case resolutionTimedOut = "resolution_timed_out", unsupportedWebsite = "unsupported_website"
    case preparationRequired = "preparation_required"
    case preparerUnavailable = "preparer_unavailable", preparationFailed = "preparation_failed"
    case preparationLimit = "preparation_limit", deliveryUnavailable = "delivery_unavailable"

    public var message: String {
        switch self {
        case .resolverUnavailable: "Website playback needs yt-dlp and Deno. Install them with Homebrew, then load the link again."
        case .resolutionFailed: "Could not find a playable video. The page may require sign-in, be unavailable, or need an updated yt-dlp installation."
        case .resolutionTimedOut: "Finding the video timed out. Check the connection and try again."
        case .unsupportedWebsite: "Choose a public, on-demand YouTube video or dedicated public playlist. Live streams, Mixes and sign-in are not supported."
        case .preparationRequired: "This source needs conversion or a delivery method that is not supported yet. Try an H.264/AAC video."
        case .preparerUnavailable: "Preparing this video needs FFmpeg and ffprobe. Install FFmpeg with Homebrew, then load the link again."
        case .preparationFailed: "Could not prepare the video. Check the source, connection and available disk space, then load it again."
        case .preparationLimit: "Preparation exceeded a size, duration or time limit, or there is insufficient disk space. Try a shorter video."
        case .deliveryUnavailable: "Could not serve the prepared video. Connect the Mac and receiver to the same local network, then load it again."
        case .network: "Could not reach the media. Check the connection and try loading it again."
        case .sourceUnavailable: "The media is unavailable or requires access. Try a fresh direct video URL."
        case .unreadableMedia: "The media could not be read or decoded. Its format may be unsupported or its data damaged. Try another source."
        case .noVideo: "This source has no video track. Choose a video source."
        case .protectedMedia: "This source is protected. Protected-media playback is not supported by this app."
        case .externalPlaybackUnsupported: "This source cannot play on the external video route. Try another source."
        case .loadFailed: "Could not load the video. Check the source and try again."
        case .playbackInterrupted: "Playback was interrupted. Check the source and receiver, then load the video again."
        }
    }
}

public struct PlaybackSnapshot: Codable, Sendable, Equatable {
    public var state: PlaybackState = .idle
    public var externalPlaybackActive = false
    public var position: Double?
    public var duration: Double?
    public var seekableRanges: [SeekRange] = []
    public var title = "No video loaded"
    public var isLive = false
    /// Seconds behind the current live edge. Present only for live media.
    public var liveOffset: Double?
    /// nil means audio inspection was unavailable or no source is loaded.
    public var hasAudio: Bool?
    public var error: String?
    public var errorReason: MediaFailureReason?
    /// Additive protocol-v1 field; playback state remains loading during extraction.
    public var loadingPhase: String?
    /// Selected processing path, not evidence that playback has started.
    public var playbackPath: PlaybackPath?
    /// Additive, privacy-safe observations for troubleshooting and future policy.
    public var diagnostics: PlaybackDiagnostics?
    /// Present while a playlist owns the shared playback session.
    public var queue: PlaybackQueueSnapshot?
    public init() {}
}

public enum QueuePolicy {
    public static func shouldAdvanceAfterEnd(hasPlayed: Bool, externalPlaybackActive: Bool,
                                             isProbing: Bool, hasNext: Bool) -> Bool {
        hasPlayed && externalPlaybackActive && !isProbing && hasNext
    }
}

public enum LivePolicy {
    /// A finite AVPlayer duration is authoritative for on-demand media. Some
    /// finite HLS presentations still expose a recommended live offset.
    public static func isLive(sourceDuration: Double?, itemDurationIndefinite: Bool) -> Bool {
        sourceDuration == nil && itemDurationIndefinite
    }
}

public struct Response: Codable, Sendable {
    public let ok: Bool
    public let pending: Bool
    public let message: String
    public let status: PlaybackSnapshot?
    public let error: AppFailure?
    public init(message: String, pending: Bool = false, status: PlaybackSnapshot? = nil) {
        ok = true; self.pending = pending; self.message = message
        self.status = status; error = nil
    }
    public init(error: AppFailure, status: PlaybackSnapshot? = nil) {
        ok = false; pending = false; message = error.message
        self.error = error; self.status = status
    }
}

public enum MediaInput {
    public static func url(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = URL(string: value) else {
            throw AppFailure(.invalidRequest, "Enter an HTTP or HTTPS video URL without embedded credentials.")
        }
        return url
    }

    public static func validateSeek(_ seconds: Double, ranges: [SeekRange]) throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw AppFailure(.invalidRequest, "Seek position must be a finite, nonnegative number of seconds.")
        }
        guard !ranges.isEmpty else {
            throw AppFailure(.unsupportedOperation, "This video does not currently support seeking.")
        }
        guard ranges.contains(where: { $0.contains(seconds) }) else {
            throw AppFailure(.unsupportedOperation, "That position is outside the available video timeline.")
        }
    }
}

/// A pure policy shared by observations and tests. Requested actions never masquerade as observed playback.
public enum PlaybackPolicy {
    public static func state(hasItem: Bool, failed: Bool, ready: Bool, connecting: Bool,
                             external: Bool, ended: Bool, playing: Bool, waiting: Bool,
                             hasPlayed: Bool) -> PlaybackState {
        if !hasItem { return .idle }
        if failed { return .failed }
        if connecting { return .connecting }
        if !ready { return .loading }
        if !external { return .awaitingReceiver }
        if ended { return .ended }
        if waiting { return .buffering }
        if playing { return .playing }
        return hasPlayed ? .paused : .ready
    }

    public static func isPlaying(_ snapshot: PlaybackSnapshot) -> Bool {
        [.playing, .buffering].contains(snapshot.state)
    }

    public static func isBusy(_ snapshot: PlaybackSnapshot) -> Bool {
        [.loading, .connecting].contains(snapshot.state)
    }

    public static func canControl(_ snapshot: PlaybackSnapshot) -> Bool {
        snapshot.externalPlaybackActive && !isBusy(snapshot)
            && ![.idle, .failed].contains(snapshot.state)
    }

    /// Live playlists can expose older, discontinuous ranges before the current
    /// window. Use the newest range for live controls and the first for finite media.
    public static func activeSeekRange(_ snapshot: PlaybackSnapshot) -> SeekRange? {
        snapshot.isLive ? snapshot.seekableRanges.last : snapshot.seekableRanges.first
    }

    public static func canSeek(_ snapshot: PlaybackSnapshot) -> Bool {
        canControl(snapshot) && activeSeekRange(snapshot) != nil
    }

    public static func stateLabel(_ snapshot: PlaybackSnapshot) -> String {
        switch snapshot.state {
        case .idle: "Ready for your next video"
        case .loading:
            switch snapshot.loadingPhase {
            case "resolving": "Finding video…"
            case "preparing": "Preparing video…"
            default: "Loading video…"
            }
        case .connecting: "Connecting to AirPlay…"
        case .awaitingReceiver: "Ready to connect"
        case .ready: "Ready to play"
        case .buffering: "Buffering…"
        case .playing: "Playing on AirPlay"
        case .paused: "Paused"
        case .ended: "Video ended"
        case .failed: "Unable to play video"
        }
    }
}

public enum PlaybackFormat {
    /// Unknown or invalid values use a stable placeholder in every control surface.
    public static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—:—" }
        let value = Int(seconds)
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
        }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

public enum MenuCommand: String, Sendable {
    case previous, skipBackward, togglePlayback, stop, skipForward, next
    case showController, quit
}

public struct MenuPlaylistControls: Equatable, Sendable {
    public let canPrevious: Bool
    public let canNext: Bool
    public init(canPrevious: Bool, canNext: Bool) {
        self.canPrevious = canPrevious
        self.canNext = canNext
    }
}

public struct MenuControlState: Equatable, Sendable {
    public let isPlaying: Bool
    public let canToggle: Bool
    public let canStop: Bool
    public let canSeek: Bool
    public let playlist: MenuPlaylistControls?
    public init(isPlaying: Bool, canToggle: Bool, canStop: Bool, canSeek: Bool,
                playlist: MenuPlaylistControls?) {
        self.isPlaying = isPlaying
        self.canToggle = canToggle
        self.canStop = canStop
        self.canSeek = canSeek
        self.playlist = playlist
    }
}

/// One row of the status-item menu. AppKit renders these values but does not
/// independently decide control availability.
public enum MenuElement: Equatable, Sendable {
    case card(title: String, status: String)
    case separator
    case controls(MenuControlState)
    case command(MenuCommand)
}

/// Pure menu state derived from the same observed snapshot used by the window and CLI.
public enum MenuModel {
    public static let skipInterval: Double = 10

    public static func controlCommands(for controls: MenuControlState) -> [MenuCommand] {
        var commands: [MenuCommand] = []
        if controls.playlist != nil { commands.append(.previous) }
        commands += [.skipBackward, .togglePlayback, .stop, .skipForward]
        if controls.playlist != nil { commands.append(.next) }
        return commands
    }

    public static func elements(for snapshot: PlaybackSnapshot) -> [MenuElement] {
        let playlist = snapshot.queue.map {
            MenuPlaylistControls(
                canPrevious: !PlaybackPolicy.isBusy(snapshot) && $0.currentIndex > 0,
                canNext: !PlaybackPolicy.isBusy(snapshot) && $0.currentIndex + 1 < $0.items.count
            )
        }
        let controls = MenuControlState(
            isPlaying: PlaybackPolicy.isPlaying(snapshot),
            canToggle: PlaybackPolicy.canControl(snapshot),
            canStop: snapshot.state != .idle,
            canSeek: PlaybackPolicy.canSeek(snapshot),
            playlist: playlist
        )
        return [
            .card(title: snapshot.title, status: statusText(snapshot)),
            .separator,
            .controls(controls),
            .separator,
            .command(.showController),
            .command(.quit)
        ]
    }

    private static func statusText(_ snapshot: PlaybackSnapshot) -> String {
        let state = PlaybackPolicy.stateLabel(snapshot)
        guard snapshot.externalPlaybackActive else {
            return snapshot.state == .idle || snapshot.state == .awaitingReceiver
                ? "AirPlay not connected"
                : "\(state) · AirPlay not connected"
        }
        if snapshot.isLive {
            let position = (snapshot.liveOffset ?? 0) > 3
                ? "−\(PlaybackFormat.time(snapshot.liveOffset))"
                : "Live"
            return "\(state) · \(position)"
        }
        guard snapshot.position != nil || snapshot.duration != nil else {
            return "\(state) · AirPlay connected"
        }
        let position = PlaybackFormat.time(snapshot.position)
        guard let duration = snapshot.duration else { return "\(state) · \(position)" }
        return "\(state) · \(position) / \(PlaybackFormat.time(duration))"
    }
}
