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
        ResolvedSource(url: url, title: title, headers: headers, audio: audio,
                       hlsAudioOptions: hlsAudioOptions,
                       needsPreparation: needsPreparation, needsDelivery: needsDelivery,
                       delivery: delivery, videoKnownPresent: videoKnownPresent, isLive: isLive,
                       conversionPolicy: policy, plannedPath: plannedPath, enhancement: enhancement)
    }

    public func withEnhancement(_ choice: VideoEnhancement) -> ResolvedSource {
        ResolvedSource(url: url, title: title, headers: headers, audio: audio,
                       hlsAudioOptions: hlsAudioOptions,
                       needsPreparation: needsPreparation || choice != .original,
                       needsDelivery: needsDelivery, delivery: delivery,
                       videoKnownPresent: videoKnownPresent, isLive: isLive,
                       conversionPolicy: choice == .original ? conversionPolicy : .allowVideo,
                       plannedPath: choice == .original ? plannedPath : .videoConversion,
                       enhancement: choice)
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
    private let web: WebSourceAdapter
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                cookies: YouTubeCookies? = nil) {
        youtube = YouTubeSourceAdapter(environment: environment, cookies: cookies)
        web = WebSourceAdapter(environment: environment)
    }

    public func candidates(for url: URL) async throws -> [MediaCandidate] {
        if url.isFileURL { return try LocalSourceAdapter.candidates(url) }
        if Self.isWebsite(url) { return try await youtube.candidates(url) }
        if Self.isDirectMediaHint(url) { return DirectSourceAdapter.candidates(url) }
        return try await web.candidates(url)
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
        !url.isFileURL && (isWebsite(url) || !isDirectMediaHint(url))
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

/// YouTube URL, playlist, and cookie handling. Metadata eligibility is shared
/// with the generic web adapter; ranking belongs to MediaSelector.
struct YouTubeSourceAdapter: Sendable {
    public static let maximumPlaylistEntries = 100
    private let environment: [String: String]
    private let cookies: YouTubeCookies
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                cookies: YouTubeCookies? = nil) {
        self.environment = environment
        self.cookies = cookies ?? YouTubeCookies.fromEnvironment(environment)
    }

    public static func isWebsite(_ url: URL) -> Bool {
        ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be",
         "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(url.host?.lowercased() ?? "")
    }

    /// Dedicated playlist pages opt into queue playback. A Mix (`list=RD...`) is
    /// an algorithmic radio queue and is accepted from either its dedicated page
    /// or the watch URL YouTube shares it as. A watch URL carrying any other
    /// `list=` remains a single-video request.
    public static func playlistPage(_ url: URL) -> URL? {
        guard isWebsite(url), url.host?.lowercased() != "youtu.be",
              url.path == "/playlist" || url.path == "/watch",
              let list = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "list" })?.value,
              (10...200).contains(list.count),
              list.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              url.path != "/watch" || list.hasPrefix("RD") else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/playlist")!
        components.queryItems = [URLQueryItem(name: "list", value: list)]
        return components.url
    }

    /// Normalize video links, dropping playlist context and preventing playlist/channel extraction.
    public static func videoPage(_ url: URL) throws -> URL {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let parts = url.path.split(separator: "/").map(String.init)
        let id: String?
        if url.host?.lowercased() == "youtu.be", parts.count == 1 { id = parts[0] }
        else if url.path == "/watch" {
            id = components?.queryItems?.first(where: { $0.name == "v" })?.value
        } else if parts.count == 2, ["shorts", "embed", "live"].contains(parts[0]) { id = parts[1] }
        else { id = nil }
        guard isWebsite(url), let id, id.count == 11,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw ResolutionFailure.unsupportedPage
        }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    /// Recognize YouTube's sign-in/bot challenge from bounded stderr. The text
    /// is never surfaced; it only selects a clearer failure reason.
    static func isSignInChallenge(_ stderr: Data) -> Bool {
        guard let text = String(data: stderr, encoding: .utf8)?.lowercased() else { return false }
        return text.contains("sign in to confirm") || text.contains("not a bot")
    }

    func candidates(_ url: URL) async throws -> [MediaCandidate] {
        let page = try Self.videoPage(url)
        let finder = HelperExecutables(environment: environment)
        guard let helper = finder.executable("yt-dlp", override: "AIRTHROW_YTDLP"),
              let deno = finder.executable("deno", override: "AIRTHROW_DENO") else {
            throw ResolutionFailure.unavailable
        }
        let scratch = cookies.materialize()
        defer { scratch.cleanup() }
        var arguments = ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--no-remote-components",
                         "--no-js-runtimes", "--js-runtimes", "deno:\(deno)",
                         "--no-playlist", "--playlist-items", "1", "--simulate", "--dump-single-json",
                         "--no-warnings", "--socket-timeout", "10",
                         "--retries", "0", "--extractor-retries", "0"]
        if let path = scratch.path { arguments.append(contentsOf: ["--cookies", path]) }
        arguments.append(contentsOf: ["--", page.absoluteString])
        let result = try await HelperProcess.runCapturingStderr(executable: helper, arguments: arguments)
        guard result.succeeded else {
            throw Self.isSignInChallenge(result.stderr) ? ResolutionFailure.signInRequired : ResolutionFailure.failed
        }
        return try await ExtractedSourceAdapter.candidatesWithHLS(result.output)
    }

    public func resolvePlaylist(_ url: URL) async throws -> ResolvedPlaylist {
        guard let page = Self.playlistPage(url) else { throw ResolutionFailure.unsupportedPage }
        let finder = HelperExecutables(environment: environment)
        guard let helper = finder.executable("yt-dlp", override: "AIRTHROW_YTDLP"),
              let deno = finder.executable("deno", override: "AIRTHROW_DENO") else {
            throw ResolutionFailure.unavailable
        }
        let scratch = cookies.materialize()
        defer { scratch.cleanup() }
        var arguments = ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--no-remote-components",
                         "--no-js-runtimes", "--js-runtimes", "deno:\(deno)",
                         "--flat-playlist", "--playlist-end", String(Self.maximumPlaylistEntries + 1),
                         "--simulate", "--dump-single-json", "--no-warnings", "--socket-timeout", "10",
                         "--retries", "0", "--extractor-retries", "0"]
        if let path = scratch.path { arguments.append(contentsOf: ["--cookies", path]) }
        arguments.append(contentsOf: ["--", page.absoluteString])
        let result = try await HelperProcess.runCapturingStderr(executable: helper, arguments: arguments)
        guard result.succeeded else {
            throw Self.isSignInChallenge(result.stderr) ? ResolutionFailure.signInRequired : ResolutionFailure.failed
        }
        return try Self.selectPlaylist(result.output)
    }

    static func selectPlaylist(_ data: Data) throws -> ResolvedPlaylist {
        let info: PlaylistInfo
        do { info = try JSONDecoder().decode(PlaylistInfo.self, from: data) }
        catch { throw ResolutionFailure.failed }
        guard info._type == "playlist", let rawEntries = info.entries, !rawEntries.isEmpty else {
            throw ResolutionFailure.unsupportedPage
        }
        let truncated = rawEntries.count > maximumPlaylistEntries
        let entries = rawEntries.prefix(maximumPlaylistEntries).enumerated().map { offset, entry in
            guard let entry else {
                return PlaylistEntry(url: nil, title: "Playlist item \(offset + 1)",
                                     unavailableReason: "This playlist entry is unavailable.")
            }
            let title = ExtractedSourceAdapter.cleanTitle(entry.title) ?? "Playlist item \(offset + 1)"
            // A live entry is playable through the native HLS path; only a
            // not-yet-started premiere has no stream to load.
            let upcoming = entry.live_status == "is_upcoming"
            let unavailable = entry.availability.map { !["public", "unlisted"].contains($0) } ?? false
            let id = entry.id ?? entry.url
            let validID = id.map { value in
                value.count == 11 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            } ?? false
            if upcoming { return PlaylistEntry(url: nil, title: title, unavailableReason: "This playlist entry has not started yet.") }
            if unavailable || !validID { return PlaylistEntry(url: nil, title: title, unavailableReason: "This playlist entry is unavailable.") }
            return PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=\(id!)"), title: title)
        }
        guard entries.contains(where: { $0.url != nil }) else { throw ResolutionFailure.unsupportedPage }
        return ResolvedPlaylist(title: ExtractedSourceAdapter.cleanTitle(info.title) ?? "YouTube playlist", entries: entries, truncated: truncated)
    }

    private struct PlaylistInfo: Decodable {
        let _type: String?
        let title: String?
        let entries: [PlaylistInfoEntry?]?
    }
    private struct PlaylistInfoEntry: Decodable {
        let id: String?
        let url: String?
        let title: String?
        let availability: String?
        let is_live: Bool?
        let live_status: String?
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
            return try await !asset.loadTracks(withMediaType: .video).isEmpty
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
