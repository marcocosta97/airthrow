import Foundation

public enum Command: String, Codable, Sendable {
    case open, play, pause, stop, seek, status, show
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

public struct SeekRange: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public func contains(_ value: Double) -> Bool {
        value.isFinite && value >= start && value <= end
    }
}

public enum MediaFailureReason: String, Codable, Sendable {
    case network, sourceUnavailable = "source_unavailable"
    case unreadableMedia = "unreadable_media", noVideo = "no_video"
    case protectedMedia = "protected_media", externalPlaybackUnsupported = "external_playback_unsupported"
    case loadFailed = "load_failed", playbackInterrupted = "playback_interrupted"

    public var message: String {
        switch self {
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
    /// nil means audio inspection was unavailable or no source is loaded.
    public var hasAudio: Bool?
    public var error: String?
    public var errorReason: MediaFailureReason?
    public init() {}
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
            throw AppFailure(.invalidRequest, "Enter a direct HTTP or HTTPS video URL without embedded credentials.")
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
}
