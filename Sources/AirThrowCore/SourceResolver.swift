import Foundation
import AVFoundation

public enum ResolutionFailure: Error, Sendable {
    case unavailable, failed, timedOut, tooMuchOutput, unsupportedPage, preparationRequired, protectedMedia, signInRequired, liveUnsupported

    public var reason: MediaFailureReason {
        switch self {
        case .unavailable: .resolverUnavailable
        case .failed, .tooMuchOutput: .resolutionFailed
        case .timedOut: .resolutionTimedOut
        case .unsupportedPage: .unsupportedWebsite
        case .preparationRequired: .preparationRequired
        case .protectedMedia: .protectedMedia
        case .signInRequired: .signInRequired
        case .liveUnsupported: .liveUnsupported
        }
    }
}

public struct MediaTrack: Sendable {
    public let url: URL
    public let headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) { self.url = url; self.headers = headers }
}

/// Privacy-safe metadata for an alternate audio rendition in an HLS master.
/// The ID is derived only from its language and bounded display name.
public struct HLSAudioOption: Sendable, Equatable {
    public let id: String
    public let language: String?
    public let name: String
    public let isOriginal: Bool
    public let isDefault: Bool
    public init(language: String?, name: String, isOriginal: Bool, isDefault: Bool) {
        self.language = language
        self.name = name
        self.isOriginal = isOriginal
        self.isDefault = isDefault
        self.id = "hls-audio-" + MediaCandidate.stableHash(MediaCandidate.signature([language ?? "", name]))
    }
}

public struct ResolvedSource: Sendable {
    public let url: URL
    public let title: String?
    // Keep request metadata in memory. Never put URLs, headers, or helper output into status/logs.
    public let headers: [String: String]
    public let audio: MediaTrack?
    public let hlsAudioOptions: [HLSAudioOption]
    public let needsPreparation: Bool
    /// The source must be exposed through AirThrow's LAN server before AVPlayer
    /// can hand it to a receiver. This is independent of whether tracks are remuxed.
    public let needsDelivery: Bool
    public let delivery: MediaDelivery
    /// Positive video evidence from an inspected presentation, not its URL or extension.
    public let videoKnownPresent: Bool
    /// The source is an indefinite presentation; preparation must use a rolling playlist.
    public let isLive: Bool
    /// The conversion preference in force when this plan was chosen.
    public let conversionPolicy: ConversionPolicy
    public let enhancement: VideoEnhancement
    /// Per-load preparation hint, independent of presentation identity. Cached
    /// preparation warms this position without encoding all preceding chunks.
    public var preparationPosition: Double? = nil
    /// A concrete processing tier chosen by the selector. Nil means the tier is
    /// derived from `needsPreparation`; set it to request audio/video conversion.
    public let plannedPath: PlaybackPath?
    public var playbackPath: PlaybackPath { plannedPath ?? (needsPreparation ? .remux : .direct) }
    public var needsPreparationPipeline: Bool { needsPreparation || needsDelivery }
    public init(url: URL, title: String? = nil, headers: [String: String] = [:], audio: MediaTrack? = nil,
                hlsAudioOptions: [HLSAudioOption] = [],
                needsPreparation: Bool = false, needsDelivery: Bool = false, delivery: MediaDelivery = .unknown,
                videoKnownPresent: Bool = false, isLive: Bool = false,
                conversionPolicy: ConversionPolicy = .avoidVideo,
                plannedPath: PlaybackPath? = nil,
                enhancement: VideoEnhancement = .original) {
        self.url = url; self.title = title; self.headers = headers; self.audio = audio
        self.hlsAudioOptions = hlsAudioOptions
        self.needsPreparation = needsPreparation || audio != nil || (plannedPath.map { $0 != .direct } ?? false)
        self.needsDelivery = needsDelivery
        self.delivery = delivery
        self.videoKnownPresent = videoKnownPresent
        self.isLive = isLive
        self.conversionPolicy = conversionPolicy
        self.enhancement = enhancement
        self.plannedPath = plannedPath
    }

    /// Copy the same presentation with a different conversion preference. The
    /// planned path and every delivery flag are preserved.
    public func withConversionPolicy(_ policy: ConversionPolicy) -> ResolvedSource {
        var result = ResolvedSource(url: url, title: title, headers: headers, audio: audio,
                       hlsAudioOptions: hlsAudioOptions,
                       needsPreparation: needsPreparation, needsDelivery: needsDelivery,
                       delivery: delivery, videoKnownPresent: videoKnownPresent, isLive: isLive,
                       conversionPolicy: policy, plannedPath: plannedPath, enhancement: enhancement)
        result.preparationPosition = preparationPosition
        return result
    }

    public func withEnhancement(_ choice: VideoEnhancement) -> ResolvedSource {
        var result = ResolvedSource(url: url, title: title, headers: headers, audio: audio,
                       hlsAudioOptions: hlsAudioOptions,
                       needsPreparation: needsPreparation || choice != .original,
                       needsDelivery: needsDelivery, delivery: delivery,
                       videoKnownPresent: videoKnownPresent, isLive: isLive,
                       conversionPolicy: conversionPolicy,
                       plannedPath: choice == .original ? plannedPath : .videoConversion,
                       enhancement: choice)
        result.preparationPosition = preparationPosition
        return result
    }
}

public struct PlaylistEntry: Sendable, Equatable {
    public let url: URL?
    public let title: String
    public let unavailableReason: String?
    public init(url: URL?, title: String, unavailableReason: String? = nil) {
        self.url = url
        self.title = title
        self.unavailableReason = unavailableReason
    }
}

public struct ResolvedPlaylist: Sendable, Equatable {
    public let title: String
    public let entries: [PlaylistEntry]
    public let truncated: Bool
    public init(title: String, entries: [PlaylistEntry], truncated: Bool) {
        self.title = title
        self.entries = entries
        self.truncated = truncated
    }
}

public struct SourceResolver: Sendable {
    public static let maximumPlaylistEntries = YouTubeSourceAdapter.maximumPlaylistEntries
    private let youtube: YouTubeSourceAdapter
    private let registry: Result<SourceRegistry, SourceRegistryError>
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                cookies: YouTubeCookies? = nil, sessions: WebsiteSessions? = nil,
                registry: SourceRegistry? = nil) {
        let youtubeCookies = cookies ?? sessions.map { $0.source(for: .youtube) }
        youtube = YouTubeSourceAdapter(environment: environment, cookies: youtubeCookies)
        if let registry { self.registry = .success(registry) }
        else {
            do { self.registry = .success(try SourceRegistry.standard(environment: environment, cookies: youtubeCookies,
                                                                      sessions: sessions)) }
            catch { self.registry = .failure((error as? SourceRegistryError) ?? .invalidAdapter) }
        }
    }

    public func candidates(for url: URL) async throws -> [MediaCandidate] {
        try Task.checkCancellation()
        if url.isFileURL { return try LocalSourceAdapter.candidates(url) }
        let sources: SourceRegistry
        do { sources = try registry.get() }
        catch {
            // Invalid custom adapter metadata must not prevent native file playback.
            if Self.isDirectMediaHint(url) { return DirectSourceAdapter.candidates(url) }
            throw ResolutionFailure.failed
        }
        if let adapter = sources.adapter(for: url) { return try await adapter.candidates(for: url) }
        return DirectSourceAdapter.candidates(url)
    }

    /// Backwards compatible: the default policy is `.avoidVideo` and no explicit
    /// source id, so existing callers keep automatic selection.
    public func resolve(_ url: URL, policy: ConversionPolicy = .avoidVideo,
                        sourceID: String? = nil, preferQuality: Bool = false) async throws -> ResolvedSource {
        let candidates = try await candidates(for: url)
        try Task.checkCancellation()
        return try MediaSelector.select(candidates, policy: policy, sourceID: sourceID, preferQuality: preferQuality)
    }

    public func resolvePlaylist(_ url: URL) async throws -> ResolvedPlaylist {
        try await youtube.resolvePlaylist(url)
    }
    public static func isWebsite(_ url: URL) -> Bool { YouTubeSourceAdapter.isWebsite(url) }
    public static func needsResolution(_ url: URL) -> Bool {
        SourceResolver().needsResolution(for: url)
    }
    /// Use this instance method when supplying a custom registry so loading
    /// and retry state follow the same dispatch as candidate discovery.
    public func needsResolution(for url: URL) -> Bool {
        guard !url.isFileURL else { return false }
        if let registry = try? registry.get() { return registry.adapter(for: url) != nil }
        return Self.isWebsite(url) || !Self.isDirectMediaHint(url)
    }
    public static func isDirectMediaHint(_ url: URL) -> Bool {
        let extensions: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mkv", "webm", "mpd",
            "ts", "m4s", "m2ts", "mpg", "mpeg", "vob", "flv", "avi", "m4a", "mp3",
            "aac", "flac", "ogg", "wav"]
        return extensions.contains(url.pathExtension.lowercased())
    }
    public static func videoPage(_ url: URL) throws -> URL { try YouTubeSourceAdapter.videoPage(url) }
    public static func playlistPage(_ url: URL) -> URL? { YouTubeSourceAdapter.playlistPage(url) }
}

/// Inspect ambiguous links without creating another player or changing the route.
/// A deadline cancels AVFoundation loading as well as the inspection task.
enum NativeSourceProbe {
    static func hasPlayableVideo(at url: URL, timeout: Duration = .seconds(3)) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            let result = try await withThrowingTaskGroup(of: Bool.self) { group in
                defer { group.cancelAll(); asset.cancelLoading() }
                group.addTask {
                    do {
                        guard try await asset.load(.isPlayable),
                              try await !asset.load(.hasProtectedContent) else { return false }
                        let tracks = try await asset.loadTracks(withMediaType: .video)
                        if !tracks.isEmpty { return true }
                        // HLS may omit AVAsset tracks even though its presentation has video.
                        let video = await HLSVideoEvidence.hasVideo(at: url)
                        try Task.checkCancellation()
                        return video
                    } catch {
                        try Task.checkCancellation()
                        return false
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    asset.cancelLoading()
                    return false
                }
                return try await group.next() ?? false
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            asset.cancelLoading()
        }
    }
}

/// Conservative recognition of a native HLS presentation, not a playlist
/// rewriter. AVPlayer owns rendition selection, fetching and synchronization.
enum HLSMaster {
    static let maximumBytes = 1024 * 1024

    static func fetch(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= maximumBytes else { throw ResolutionFailure.failed }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw ResolutionFailure.tooMuchOutput }
            data.append(byte)
        }
        return data
    }

    static func hasAudioVideo(_ data: Data, at base: URL) -> Bool {
        quality(data, at: base) != nil
    }

    static func audioOptions(_ data: Data, at base: URL) -> [HLSAudioOption] {
        guard quality(data, at: base) != nil,
              let text = String(data: data, encoding: .utf8) else { return [] }
        var options: [HLSAudioOption] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-MEDIA:") {
            guard options.count < 16,
                  let attrs = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count))),
                  attrs["TYPE"] == "AUDIO", attrs["GROUP-ID"]?.isEmpty == false,
                  let uri = attrs["URI"], validURI(uri, at: base),
                  let name = safeAudioLabel(attrs["NAME"], limit: 80) else { continue }
            let language = safeAudioLanguage(attrs["LANGUAGE"])
            let key = MediaCandidate.signature([language ?? "", name])
            guard seen.insert(key).inserted else { continue }
            options.append(HLSAudioOption(language: language, name: name,
                                          isOriginal: name.range(of: "original", options: .caseInsensitive) != nil,
                                          isDefault: attrs["DEFAULT"] == "YES"))
        }
        return options
    }

    private static func safeAudioLabel(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= limit,
              !value.contains("://"), !value.contains("/"), !value.contains("?"), !value.contains("@"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func safeAudioLanguage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 32,
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return raw
    }

    struct Quality {
        let height: Double?
        let bitrate: Double
    }

    static func quality(_ data: Data, at base: URL) -> Quality? {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U",
              !lines.contains(where: { $0.hasPrefix("#EXT-X-SESSION-KEY:") }) else { return nil }
        var audioGroups = Set<String>()
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            guard let attrs = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count))),
                  attrs["TYPE"] == "AUDIO", let group = attrs["GROUP-ID"], !group.isEmpty,
                  let uri = attrs["URI"], validURI(uri, at: base) else { continue }
            audioGroups.insert(group)
        }
        var best: Quality?
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            guard let attrs = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count))),
                  let codecs = attrs["CODECS"]?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }),
                  codecs.count == 2, codecs.contains(where: { $0.hasPrefix("avc1.") }),
                  codecs.contains(where: { ["mp4a.40.2", "mp4a.40.5", "mp4a.40.29"].contains($0) }),
                  attrs["VIDEO-RANGE"] == nil || attrs["VIDEO-RANGE"] == "SDR",
                  let bandwidth = attrs["BANDWIDTH"].flatMap(Int.init), bandwidth > 0,
                  index + 1 < lines.count, validURI(lines[index + 1], at: base) else { continue }
            // With no AUDIO attribute the advertised audio is muxed in the variant.
            if let group = attrs["AUDIO"], !audioGroups.contains(group) { continue }
            let dimensions = attrs["RESOLUTION"]?.split(separator: "x").compactMap(Double.init)
            let height = dimensions.flatMap { values -> Double? in
                guard values.count == 2, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
                return values[1]
            }
            let quality = Quality(height: height, bitrate: Double(bandwidth) / 1000)
            if best == nil || (quality.height ?? 0, quality.bitrate) > (best!.height ?? 0, best!.bitrate) {
                best = quality
            }
        }
        return best
    }

    private static func validURI(_ value: String, at base: URL) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("#"),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value, relativeTo: base)?.absoluteURL else { return false }
        return (try? MediaInput.url(url.absoluteString)) != nil
    }

    // Attribute lists contain commas inside quoted CODECS and URI values.
    // Reject duplicate keys and unbalanced quotes rather than guessing.
    private static func attributes(_ text: String) -> [String: String]? {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for char in text {
            if char == "\"" { quoted.toggle() }
            if char == ",", !quoted { fields.append(current); current = "" }
            else { current.append(char) }
        }
        guard !quoted else { return nil }
        fields.append(current)
        var result: [String: String] = [:]
        for field in fields {
            guard let split = field.firstIndex(of: "=") else { return nil }
            let key = String(field[..<split]).trimmingCharacters(in: .whitespaces)
            var value = String(field[field.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty, result[key] == nil else { return nil }
            if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard !value.contains("\"") else { return nil }
            result[key] = value
        }
        return result
    }
}

/// Direct media playlists often omit codec metadata. Inspect one referenced
/// presentation or segment so routed AVPlayer items can retain positive video
/// evidence even when AirPlay no longer exposes their local tracks.
public enum HLSVideoEvidence {
    public static func hasVideo(at url: URL) async -> Bool {
        await hasVideo(at: url, depth: 0)
    }

    private static func hasVideo(at url: URL, depth: Int) async -> Bool {
        guard depth <= 2 else { return false }
        do {
            let data = try await HLSMaster.fetch(url)
            if HLSMaster.hasAudioVideo(data, at: url) { return true }
            guard let reference = reference(in: data, at: url) else { return false }
            if reference.isPlaylist { return await hasVideo(at: reference.url, depth: depth + 1) }
            let asset = AVURLAsset(url: reference.url)
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await !asset.loadTracks(withMediaType: .video).isEmpty
            } onCancel: {
                asset.cancelLoading()
            }
        } catch { return false }
    }

    static func reference(in data: Data, at base: URL) -> (url: URL, isPlaylist: Bool)? {
        guard data.count <= HLSMaster.maximumBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U",
              !lines.contains(where: { $0.hasPrefix("#EXT-X-KEY:") || $0.hasPrefix("#EXT-X-SESSION-KEY:") }) else {
            return nil
        }
        var expectsVariant = false
        var expectsSegment = false
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") { expectsVariant = true; continue }
            if line.hasPrefix("#EXTINF:") { expectsSegment = true; continue }
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let url = URL(string: line, relativeTo: base)?.absoluteURL,
                  (try? MediaInput.url(url.absoluteString)) != nil else { continue }
            if expectsVariant { return (url, true) }
            if expectsSegment { return (url, false) }
        }
        return nil
    }
}
