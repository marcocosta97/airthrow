import Foundation

public enum Command: String, Codable, Sendable {
    case open, play, pause, stop, seek, previous, next, status, show, sources, source, conversion
}

public struct Request: Codable, Sendable {
    public var version: Int = 1
    public let command: Command
    public var url: String?
    public var seconds: Double?
    public var sourceID: String?
    public var allowVideoConversion: Bool?
    /// An explicit open-and-play request; absent preserves paused loading.
    public var autoplay: Bool?
    public init(_ command: Command, url: String? = nil, seconds: Double? = nil, autoplay: Bool? = nil) {
        self.command = command
        self.url = url
        self.seconds = seconds
        self.autoplay = autoplay
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
    case direct, remux, audioConversion = "audio_conversion", videoConversion = "video_conversion"
    public var tier: Int {
        switch self { case .direct: 1; case .remux: 2; case .audioConversion: 3; case .videoConversion: 4 }
    }
    public var label: String {
        switch self {
        case .direct: "Direct playback"
        case .remux: "Remuxed playback"
        case .audioConversion: "Audio re-encoding"
        case .videoConversion: "Video re-encoding"
        }
    }
    public var explanation: String {
        switch self {
        case .direct: "Tier 1: Plays the source directly — the receiver fetches a remote URL, or this Mac serves a local file in place — with no prepared copy."
        case .remux: "Tier 2: Copies audio and video into compatible media on this Mac without re-encoding. Preparation may continue during playback."
        case .audioConversion: "Tier 3: Copies the video and re-encodes audio to AAC on this Mac. Preparation may continue during playback."
        case .videoConversion: "Tier 4: Re-encodes SDR video on this Mac. Automatic re-encoding is H.264 up to 1080p; an explicit enhancement may produce 1080p H.264 or 4K HEVC. Uses more processing and may take longer to start."
        }
    }
}

/// An explicit, per-item finite SDR processing choice. Original keeps the
/// source selection and conversion preference unchanged.
public enum VideoEnhancement: String, Codable, Sendable, CaseIterable {
    case original
    case upscale1080 = "upscale_1080"
    case cleanup1080 = "cleanup_1080"
    case upscale4K = "upscale_4k"
    case cleanup4K = "cleanup_4k"

    public var label: String {
        switch self {
        case .original: "Original"
        case .upscale1080: "Upscale to 1080p"
        case .cleanup1080: "Clean up & upscale to 1080p"
        case .upscale4K: "Upscale to 4K"
        case .cleanup4K: "Clean up & upscale to 4K"
        }
    }
    public var targetHeight: Int? {
        switch self {
        case .original: nil
        case .upscale1080, .cleanup1080: 1080
        case .upscale4K, .cleanup4K: 2160
        }
    }
    public var cleansUp: Bool { self == .cleanup1080 || self == .cleanup4K }
}

public struct SeekRange: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public func contains(_ value: Double) -> Bool {
        value.isFinite && value >= start && value <= end
    }
    public static func merged(_ ranges: [Self], within bounds: Self? = nil) -> [Self] {
        let valid = ranges.compactMap { range -> Self? in
            guard range.start.isFinite, range.end.isFinite, range.end > range.start else { return nil }
            let start = max(range.start, bounds?.start ?? range.start)
            let end = min(range.end, bounds?.end ?? range.end)
            return end > start ? Self(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var result: [Self] = []
        for range in valid {
            if let last = result.last, range.start <= last.end + 0.001 {
                result[result.count - 1] = Self(start: last.start, end: max(last.end, range.end))
            } else { result.append(range) }
        }
        return result
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
public struct StreamingVideoCharacteristics: Codable, Sendable, Equatable {
    public enum Container: String, Codable, Sendable { case mpegts }
    public enum Codec: String, Codable, Sendable { case h264, hevc, mpeg2video }
    public enum Delivery: String, Codable, Sendable { case hls, transportStream }
    public enum Chroma: String, Codable, Sendable { case yuv420, yuv422, yuv444 }
    public enum Profile: String, Codable, Sendable { case main, main10, mainStillPicture }
    public enum Transfer: String, Codable, Sendable {
        case bt709, smpte2084, aribSTD_B67 = "arib-std-b67"
    }
    public let container: Container
    public let codec: Codec
    public let width: Int?
    public let height: Int?
    public let bitDepth: Int?
    public let transfer: Transfer?
    public let delivery: Delivery?
    public let chroma: Chroma?
    public let profile: Profile?
    public let level: Int?
    public let isLive: Bool?
    /// Apple HLS requires fMP4 for HEVC. Native playback can otherwise report
    /// playing with audible audio while the receiver displays no video.
    public var requiresHLSRemux: Bool { delivery == .hls && container == .mpegts && codec == .hevc }
    public init(codec: Codec, width: Int?, height: Int?, bitDepth: Int?, transfer: Transfer?,
         delivery: Delivery? = nil, chroma: Chroma? = nil, profile: Profile? = nil, level: Int? = nil,
         isLive: Bool? = nil) {
        container = .mpegts
        self.codec = codec
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.transfer = transfer
        self.delivery = delivery
        self.chroma = chroma
        self.profile = profile
        self.level = level
        self.isLive = isLive
    }
}

public struct MediaErrorCode: Codable, Sendable, Equatable {
    public enum Domain: String, Codable, Sendable { case avFoundation, urlLoading, coreMedia, osStatus, other }
    public let domain: Domain
    public let code: Int
    public init(domain: Domain, code: Int) { self.domain = domain; self.code = code }
}

/// Numeric extractor inventory, including formats that are not playable.
public struct SourceDiscoverySummary: Codable, Sendable, Equatable {
    public let formatCount: Int
    public let maximumAdvertisedVideoHeight: Int?
    public init(formatCount: Int, maximumAdvertisedVideoHeight: Int?) {
        self.formatCount = formatCount; self.maximumAdvertisedVideoHeight = maximumAdvertisedVideoHeight
    }
}

/// Advertised HLS attributes only; never includes rendition URLs or names.
public struct HLSVariantSummary: Codable, Sendable, Equatable {
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let peakBitrate: Double?
    public let averageBitrate: Double?
    public let videoCodecs: [UInt32]
    public init(width: Int?, height: Int?, frameRate: Double?, peakBitrate: Double?, averageBitrate: Double?, videoCodecs: [UInt32]) {
        self.width = width; self.height = height; self.frameRate = frameRate
        self.peakBitrate = peakBitrate; self.averageBitrate = averageBitrate; self.videoCodecs = videoCodecs
    }
}

public struct PlaybackDiagnostics: Codable, Sendable, Equatable {
    public enum SampleInspectionStatus: String, Codable, Sendable { case pending, unavailable, complete }
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
    /// Numeric format identifiers and encoded dimensions, when local tracks are available.
    public var videoCodecTypes: [UInt32]?
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var sampledVideo: StreamingVideoCharacteristics?
    public var sourceDiscovery: SourceDiscoverySummary?
    public var hlsVariantCount: Int?
    public var hlsVariants: [HLSVariantSummary]?
    public var sampleInspectionStatus: SampleInspectionStatus?
    public var livePipeline: LivePipelineDiagnostics?
    /// Only numeric errors: log URIs, addresses and provider text are never exposed.
    public var errorStatusCodes: [Int]?
    public var itemErrorCode: Int?
    public var assetErrorCode: Int?
    public var failureErrors: [MediaErrorCode]?
    public init() {}
}

public struct LivePipelineDiagnostics: Codable, Sendable, Equatable {
    public var producerActive: Bool?
    public var producerFailure: MediaFailureReason?
    public var inputIsTransportStream: Bool?
    public var playlistComplete: Bool?
    public var playlistSegments: Int?
    public var playlistSequence: Int?
    public var playlistSeconds: Double?
    public var relayReceivedBytes: Int64 = 0
    public var relayPeakBufferBytes: Int = 0
    public var relayActiveStreams: Int = 0
    public var relayFinishedStreams: Int = 0
    public var relayLastErrorCode: Int?
    public var relayBufferLimitClosures: Int = 0
    public var relayEOFClosures: Int = 0
    public var relayManifestResponses: Int = 0
    public var relayManifestEndLists: Int = 0
    public var relayManifestVODs: Int = 0
    public var relayManifestSequence: Int?
    public var relayHTTPFailures: Int = 0
    public var relayLastHTTPStatus: Int?
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
    case signInRequired = "sign_in_required"
    case httpAuthenticationRequired = "http_authentication_required"
    case liveUnsupported = "live_unsupported"
    case preparationRequired = "preparation_required"
    case preparerUnavailable = "preparer_unavailable", preparationFailed = "preparation_failed"
    case preparationLimit = "preparation_limit", deliveryUnavailable = "delivery_unavailable"
    case preparationStorageLimit = "preparation_storage_limit"
    case preparationDiskSpace = "preparation_disk_space", preparationStalled = "preparation_stalled"

    public var message: String {
        switch self {
        case .resolverUnavailable: "YouTube playback needs yt-dlp and Deno. Install them with Homebrew, then load the link again."
        case .resolutionFailed: "Could not find a playable video. The page may require sign-in, be unavailable, or need an updated yt-dlp installation."
        case .resolutionTimedOut: "Finding the video timed out. Check the connection and try again."
        case .unsupportedWebsite: "Choose a public YouTube video, playlist, Mix or live stream. Sign-in and not-yet-started premieres are not supported."
        case .httpAuthenticationRequired: "This server requires a username and password. Load the link again to sign in."
        case .signInRequired: "YouTube asked for sign-in verification. Add or refresh cookies in Settings → YouTube access, then load again. A cookies file is a snapshot and can expire; a browser source stays current."
        case .liveUnsupported: "This live stream has no supported presentation. Protected media, unsafe tracks and some delivery methods are unsupported."
        case .preparationRequired: "This source cannot use the current preparation settings. Allow video re-encoding for supported SDR sources, or choose Original for a compatible HDR10/HLG/Dolby Vision source. Re-encoding HDR, protected media and some delivery methods are unsupported."
        case .preparerUnavailable: "Preparing this video needs FFmpeg and ffprobe. Install FFmpeg with Homebrew, then load the link again."
        case .preparationFailed: "Could not prepare the video. Check the source, connection and available disk space, then load it again."
        case .preparationLimit: "Preparation exceeded a size, duration or time limit, or there is insufficient disk space. Try a smaller or lower-bitrate source."
        case .preparationStorageLimit: "Preparing this video reached the configured space limit. Increase Maximum preparation space in Settings → Prepared video storage, or choose a lower output resolution, then load again."
        case .preparationDiskSpace: "There is not enough free disk space to prepare this video. Free some space on the Mac, then load again."
        case .preparationStalled: "Preparing this part of the video timed out. Check the source connection or choose a lower output resolution, then load again."
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
    /// True for the optional receiver interstitial; it is not user media.
    public var receiverWaiting: Bool?
    public var position: Double?
    public var duration: Double?
    public var seekableRanges: [SeekRange] = []
    /// Verified video currently available on this Mac. nil uses native player
    /// buffering; an empty array explicitly means no prepared chunks are ready.
    public var preparedRanges: [SeekRange]?
    public var title = "No video loaded"
    public var isLive = false
    /// Seconds behind the current live edge. Present only for live media.
    public var liveOffset: Double?
    /// Native live playback has a deliberate delay for buffering/network conditions.
    public var recommendedLiveOffset: Double?
    /// Smallest observed live-edge advance. Manifest updates move this edge in
    /// chunks even when the playhead advances continuously.
    public var liveEdgeUpdateInterval: Double?
    /// nil means audio inspection was unavailable or no source is loaded.
    public var hasAudio: Bool?
    public var error: String?
    public var errorReason: MediaFailureReason?
    /// Additive protocol-v1 field; playback state remains loading during extraction.
    public var loadingPhase: String?
    /// Finite prepared media is playable while the producer continues ahead.
    public var preparationInProgress: Bool?
    /// Media seconds prepared per wall-clock second, including fetch and validation.
    public var preparationSpeed: Double?
    /// Explicit seek work can be pending while AirPlay still reports playing.
    public var seekInProgress: Bool?
    /// Selected processing path, not evidence that playback has started.
    public var playbackPath: PlaybackPath?
    /// Quality label of the selected presentation (for example "720p60"),
    /// when the adapter knows it. Never contains URLs or provider identifiers.
    public var quality: String?
    /// Presentation size reported by AVPlayerItem, not proof of receiver output.
    public var reportedVideoWidth: Int?
    public var reportedVideoHeight: Int?
    /// Additive, privacy-safe observations for troubleshooting and future policy.
    public var diagnostics: PlaybackDiagnostics?
    /// Present while a playlist owns the shared playback session.
    public var queue: PlaybackQueueSnapshot?
    /// Session-scoped opaque choices. Never contains source URLs or headers.
    public var sources: [SourceOptionSnapshot]?
    /// nil means automatic selection; explicit IDs expire when the item changes.
    public var selectedSourceID: String?
    /// Audio choices for the current video presentation, including native HLS renditions.
    public var audioOptions: [AudioOptionSnapshot]?
    public var selectedAudioID: String?
    /// Native subtitle/caption choices on the installed player item. An Off
    /// choice is present only when the media selection group allows it.
    public var subtitleOptions: [SubtitleOptionSnapshot]?
    public var selectedSubtitleID: String?
    public var allowVideoConversion: Bool?
    /// Per-item request, absent when no item is loaded.
    public var videoEnhancement: VideoEnhancement?
    public init() {}
}

public struct AudioOptionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let unavailableReason: String?
    public init(id: String, label: String, unavailableReason: String? = nil) {
        self.id = id; self.label = label; self.unavailableReason = unavailableReason
    }
}

public struct SubtitleOptionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public init(id: String, label: String) {
        self.id = id; self.label = label
    }
}

public struct SourceOptionSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let bitrate: Double?
    public let isAdaptive: Bool?
    /// Session-scoped identity shared by presentations with the same video stream.
    public let videoGroupID: String?
    public let quality: String
    public let audio: String?
    public let playbackPath: PlaybackPath
    public let unavailableReason: String?
    public init(id: String, quality: String, audio: String?, playbackPath: PlaybackPath,
                unavailableReason: String?, videoGroupID: String? = nil, bitrate: Double? = nil, isAdaptive: Bool? = nil) {
        self.id = id; self.videoGroupID = videoGroupID; self.quality = quality
        self.bitrate = bitrate; self.isAdaptive = isAdaptive; self.audio = audio
        self.playbackPath = playbackPath; self.unavailableReason = unavailableReason
    }
}

public enum QueuePolicy {
    public static func shouldAdvanceAfterEnd(hasPlayed: Bool, externalPlaybackActive: Bool,
                                             isProbing: Bool, hasNext: Bool) -> Bool {
        hasPlayed && externalPlaybackActive && !isProbing && hasNext
    }
}

public enum LivePolicy {
    public static func edgeUpdateInterval(previous: PlaybackSnapshot, current: PlaybackSnapshot) -> Double? {
        guard previous.isLive, current.isLive,
              let oldEdge = previous.seekableRanges.last?.end,
              let newEdge = current.seekableRanges.last?.end,
              oldEdge.isFinite, newEdge.isFinite, newEdge >= oldEdge else { return nil }
        let known = previous.liveEdgeUpdateInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let advance = newEdge - oldEdge
        guard advance > 0 else { return known }
        return min(known ?? advance, advance)
    }

    /// Use the actual seekable window, independently of delivery or encoding.
    public static func supportsTimeShift(_ snapshot: PlaybackSnapshot) -> Bool {
        guard snapshot.isLive, let range = snapshot.seekableRanges.last,
              range.start.isFinite, range.end.isFinite, range.end > range.start else { return false }
        return true
    }

    /// A finite AVPlayer duration is authoritative for on-demand media. Some
    /// finite HLS presentations still expose a recommended live offset.
    public static func isLive(sourceDuration: Double?, itemDurationIndefinite: Bool) -> Bool {
        sourceDuration == nil && itemDurationIndefinite
    }

    public static func delay(_ snapshot: PlaybackSnapshot, position: Double? = nil) -> Double? {
        guard snapshot.isLive else { return nil }
        let offset: Double?
        if let position, let edge = snapshot.seekableRanges.last?.end {
            offset = max(0, edge - position)
        } else { offset = snapshot.liveOffset }
        guard let offset, offset.isFinite else { return nil }
        let target = snapshot.recommendedLiveOffset.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        return max(0, offset - target)
    }

    public static func isAtLive(_ snapshot: PlaybackSnapshot) -> Bool {
        let cadence = snapshot.liveEdgeUpdateInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        let tolerance = snapshot.state == .paused ? 3 : max(3, cadence)
        return delay(snapshot).map { $0 <= tolerance } ?? false
    }

    /// Pin the displayed knob at Live without seeking the player on every
    /// manifest update. Explicit drags and pending seeks keep their real target.
    public static func timelinePosition(_ snapshot: PlaybackSnapshot, requested: Double? = nil) -> Double {
        let range = PlaybackPolicy.activeSeekRange(snapshot)
        if snapshot.isLive, !supportsTimeShift(snapshot) { return range?.end ?? 1 }
        let position = requested ?? (isAtLive(snapshot) ? range?.end : snapshot.position) ?? 0
        return min(max(position, range?.start ?? 0), range?.end ?? 1)
    }

    public static func positionLabel(_ snapshot: PlaybackSnapshot, position: Double? = nil) -> String {
        if snapshot.isLive, !supportsTimeShift(snapshot) { return "Live" }
        if position == nil, isAtLive(snapshot) { return "Live" }
        let offset = delay(snapshot, position: position) ?? 0
        return offset > 3 ? "−\(PlaybackFormat.time(offset))" : "Live"
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
    /// Accepts the existing HTTP(S) inputs plus a local POSIX path or file URL.
    /// Local files have their own validator so the network URL rules stay strict.
    public static func source(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppFailure(.invalidRequest, "Enter an HTTP or HTTPS video URL, or choose a readable local video file.")
        }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") {
            return try localFile(value)
        }
        if let scheme = URLComponents(string: value)?.scheme?.lowercased() {
            if ["http", "https"].contains(scheme) { return try url(value) }
            if scheme == "file" { return try localFile(value) }
            throw AppFailure(.invalidRequest, "Enter an HTTP or HTTPS video URL, or choose a readable local video file.")
        }
        return try localFile(value)
    }

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

    public static func localFile(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppFailure(.invalidRequest, "Choose a readable local video file.")
        }
        let file: URL
        if URLComponents(string: value)?.scheme?.lowercased() == "file" {
            guard let components = URLComponents(string: value),
                  components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil,
                  components.host == nil || components.host?.isEmpty == true || components.host == "localhost",
                  let parsed = components.url, parsed.isFileURL, !parsed.path.isEmpty else {
                throw AppFailure(.invalidRequest, "Choose a local file URL without a remote host, query, or fragment.")
            }
            file = parsed
        } else {
            let expanded = (value as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                file = URL(fileURLWithPath: expanded)
            } else {
                let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                file = URL(fileURLWithPath: expanded, relativeTo: base)
            }
        }
        return try localFile(file)
    }

    public static func localFile(_ input: URL) throws -> URL {
        guard input.isFileURL else { throw AppFailure(.invalidRequest, "Choose a readable local video file.") }
        // Resolve a user-selected symlink once. The server later opens the
        // resulting regular file with O_NOFOLLOW for each request.
        let file = input.standardizedFileURL.resolvingSymlinksInPath()
        // A dropped link may percent-encode control characters that a typed path
        // cannot contain. Keep both forms equivalent after resolution.
        guard !file.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppFailure(.invalidRequest, "Choose a readable local video file.")
        }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch { throw AppFailure(.invalidRequest, "The local video file does not exist or cannot be accessed.") }
        // No size cap applies to in-place delivery: the receiver-compatible file
        // is streamed from its original location and never occupies the prepared
        // media budget. Remuxing still enforces the preparation size limits.
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: file.path),
              let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes > 0 else {
            throw AppFailure(.invalidRequest, "Choose a readable, non-empty local video file.")
        }
        return file
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
    /// Preserve user intent across every replacement, including a zero-rate
    /// buffering item and recovery while the same receiver remains selected.
    public static func shouldAutoplayReplacement(pendingPlay: Bool, playbackRequested: Bool,
                                                 external: Bool, playing: Bool, recoveringReceiver: Bool) -> Bool {
        pendingPlay || (external && (playing || playbackRequested || recoveringReceiver))
    }
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
    /// window. Use the newest range for live controls. For on-demand media a
    /// known finite duration gives a stable full-length timeline; the seekable
    /// range appears late and grows while buffering, which would otherwise make
    /// the position thumb jump around (or pin to the end while it is empty).
    public static func activeSeekRange(_ snapshot: PlaybackSnapshot) -> SeekRange? {
        if snapshot.isLive { return snapshot.seekableRanges.last }
        if let duration = snapshot.duration, duration.isFinite, duration > 0 {
            return SeekRange(start: 0, end: duration)
        }
        return snapshot.seekableRanges.first
    }

    public static func canSeek(_ snapshot: PlaybackSnapshot) -> Bool {
        canControl(snapshot) && !snapshot.seekableRanges.isEmpty && activeSeekRange(snapshot) != nil
            && (!snapshot.isLive || LivePolicy.supportsTimeShift(snapshot))
    }

    public static func skipTarget(_ snapshot: PlaybackSnapshot, by seconds: Double, position: Double? = nil) -> Double? {
        guard canSeek(snapshot), seconds.isFinite,
              let position = position ?? snapshot.position, position.isFinite else { return nil }
        let target = position + seconds
        let ranges = snapshot.isLive ? Array(snapshot.seekableRanges.suffix(1)) : snapshot.seekableRanges
        return ranges.contains { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.contains(target) } ? target : nil
    }

    public static func canSkip(_ snapshot: PlaybackSnapshot, by seconds: Double, position: Double? = nil) -> Bool {
        skipTarget(snapshot, by: seconds, position: position) != nil
    }

    public static func readyRanges(_ snapshot: PlaybackSnapshot) -> [SeekRange] {
        if snapshot.isLive, !LivePolicy.supportsTimeShift(snapshot) { return [] }
        guard ![.idle, .loading, .failed].contains(snapshot.state),
              let bounds = activeSeekRange(snapshot) else { return [] }
        return SeekRange.merged(snapshot.preparedRanges ?? snapshot.diagnostics?.bufferedRanges ?? [], within: bounds)
    }

    public static func stateLabel(_ snapshot: PlaybackSnapshot) -> String {
        switch snapshot.state {
        case .idle: "Ready for your next video"
        case .loading:
            switch snapshot.loadingPhase {
            case "authentication": "Sign in to server"
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
    public let canSkipBackward: Bool
    public let canSkipForward: Bool
    public let playlist: MenuPlaylistControls?
    public init(isPlaying: Bool, canToggle: Bool, canStop: Bool, canSeek: Bool,
                playlist: MenuPlaylistControls?, canSkipBackward: Bool? = nil, canSkipForward: Bool? = nil) {
        self.isPlaying = isPlaying
        self.canToggle = canToggle
        self.canStop = canStop
        self.canSeek = canSeek
        self.canSkipBackward = canSkipBackward ?? canSeek
        self.canSkipForward = canSkipForward ?? canSeek
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
            canStop: snapshot.state != .idle || snapshot.receiverWaiting == true,
            canSeek: PlaybackPolicy.canSeek(snapshot),
            playlist: playlist,
            canSkipBackward: PlaybackPolicy.canSkip(snapshot, by: -skipInterval),
            canSkipForward: PlaybackPolicy.canSkip(snapshot, by: skipInterval)
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
            let position = LivePolicy.positionLabel(snapshot)
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

/// Downloads a bounded body in the session's chunks. Callers used to pull
/// `URLSession.AsyncBytes` one byte at a time, which also checked cancellation
/// once per byte.
enum ChunkedBody {
    struct Overflow: Error {}

    static func fetch(_ request: URLRequest, maximum: Int, allowPartial: Bool = false,
                      timeout: TimeInterval = 60, resourceTimeout: TimeInterval = 90,
                      redirect: (@Sendable (HTTPURLResponse, URLRequest) -> URLRequest?)? = nil,
                      challenge: (@Sendable (URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))? = nil) async throws -> (Data, HTTPURLResponse) {
        let collector = Collector(maximum: maximum, allowPartial: allowPartial, redirect: redirect, challenge: challenge)
        return try await collector.run(request, timeout: timeout, resourceTimeout: resourceTimeout)
    }

    private final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maximum: Int
        private let allowPartial: Bool
        private let redirect: (@Sendable (HTTPURLResponse, URLRequest) -> URLRequest?)?
        private let challenge: (@Sendable (URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?
        private let lock = NSLock()
        private var body = Data()
        private var response: HTTPURLResponse?
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var overflow = false
        private var task: URLSessionDataTask?

        init(maximum: Int, allowPartial: Bool,
             redirect: (@Sendable (HTTPURLResponse, URLRequest) -> URLRequest?)?,
             challenge: (@Sendable (URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?) {
            self.maximum = maximum
            self.allowPartial = allowPartial
            self.redirect = redirect
            self.challenge = challenge
        }

        func run(_ request: URLRequest, timeout: TimeInterval, resourceTimeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.httpShouldSetCookies = false
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = resourceTimeout
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            self.task = task
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    self.continuation = continuation
                    lock.unlock()
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        private func finish(_ result: Result<(Data, HTTPURLResponse), Error>, session: URLSession) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            session.finishTasksAndInvalidate()
            continuation?.resume(with: result)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
            if http.expectedContentLength > Int64(maximum), !allowPartial {
                lock.lock(); overflow = true; lock.unlock()
                completionHandler(.cancel)
                return
            }
            lock.lock(); self.response = http; lock.unlock()
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            let room = maximum - body.count
            if data.count <= room {
                body.append(data)
            } else if allowPartial, room > 0 {
                body.append(data.prefix(room))
                overflow = true
            } else {
                overflow = true
            }
            let stop = overflow
            lock.unlock()
            if stop { task?.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            if let redirect { completionHandler(redirect(response, request)) }
            else { completionHandler(request) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let challengePolicy = self.challenge { let decision = challengePolicy(challenge); completionHandler(decision.0, decision.1) }
            else { completionHandler(.performDefaultHandling, nil) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let response = self.response
            let body = self.body
            let overflow = self.overflow
            lock.unlock()
            if overflow, !allowPartial {
                finish(.failure(Overflow()), session: session)
            } else if let response, error == nil || (allowPartial && overflow) {
                finish(.success((body, response)), session: session)
            } else if let error = error as? URLError, error.code == .cancelled {
                finish(.failure(CancellationError()), session: session)
            } else {
                finish(.failure(error ?? URLError(.badServerResponse)), session: session)
            }
        }
    }
}
