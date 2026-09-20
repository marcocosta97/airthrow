import Foundation
import AVFoundation

public enum ResolutionFailure: Error, Sendable {
    case unavailable, failed, timedOut, tooMuchOutput, unsupportedPage, preparationRequired, protectedMedia

    public var reason: MediaFailureReason {
        switch self {
        case .unavailable: .resolverUnavailable
        case .failed, .tooMuchOutput: .resolutionFailed
        case .timedOut: .resolutionTimedOut
        case .unsupportedPage: .unsupportedWebsite
        case .preparationRequired: .preparationRequired
        case .protectedMedia: .protectedMedia
        }
    }
}

public struct MediaTrack: Sendable {
    public let url: URL
    public let headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) { self.url = url; self.headers = headers }
}

public struct ResolvedSource: Sendable {
    public let url: URL
    public let title: String?
    // Keep request metadata in memory. Never put URLs, headers, or helper output into status/logs.
    public let headers: [String: String]
    public let audio: MediaTrack?
    public let needsPreparation: Bool
    /// The source must be exposed through AirPlayer's LAN server before AVPlayer
    /// can hand it to a receiver. This is independent of whether tracks are remuxed.
    public let needsDelivery: Bool
    public let delivery: MediaDelivery
    /// Positive video evidence from an inspected presentation, not its URL or extension.
    public let videoKnownPresent: Bool
    public var playbackPath: PlaybackPath { needsPreparation ? .remux : .direct }
    public var needsPreparationPipeline: Bool { needsPreparation || needsDelivery }
    public init(url: URL, title: String? = nil, headers: [String: String] = [:], audio: MediaTrack? = nil,
                needsPreparation: Bool = false, needsDelivery: Bool = false, delivery: MediaDelivery = .unknown,
                videoKnownPresent: Bool = false) {
        self.url = url; self.title = title; self.headers = headers; self.audio = audio
        self.needsPreparation = needsPreparation || audio != nil
        self.needsDelivery = needsDelivery
        self.delivery = delivery
        self.videoKnownPresent = videoKnownPresent
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
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        youtube = YouTubeSourceAdapter(environment: environment)
    }

    public func candidates(for url: URL) async throws -> [MediaCandidate] {
        if url.isFileURL { return try LocalSourceAdapter.candidates(url) }
        if Self.isWebsite(url) { return try await youtube.candidates(url) }
        return DirectSourceAdapter.candidates(url)
    }

    public func resolve(_ url: URL) async throws -> ResolvedSource {
        let candidates = try await candidates(for: url)
        try Task.checkCancellation()
        return try MediaSelector.select(candidates)
    }

    public func resolvePlaylist(_ url: URL) async throws -> ResolvedPlaylist {
        try await youtube.resolvePlaylist(url)
    }
    public static func isWebsite(_ url: URL) -> Bool { YouTubeSourceAdapter.isWebsite(url) }
    public static func videoPage(_ url: URL) throws -> URL { try YouTubeSourceAdapter.videoPage(url) }
    public static func playlistPage(_ url: URL) -> URL? { YouTubeSourceAdapter.playlistPage(url) }
}

/// yt-dlp extraction and eligibility checks only; ranking belongs to MediaSelector.
struct YouTubeSourceAdapter: Sendable {
    public static let maximumPlaylistEntries = 100
    private let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public static func isWebsite(_ url: URL) -> Bool {
        ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be",
         "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(url.host?.lowercased() ?? "")
    }

    /// Dedicated playlist pages opt into queue playback. A watch URL carrying
    /// `list=` remains a single-video request.
    public static func playlistPage(_ url: URL) -> URL? {
        guard isWebsite(url), url.host?.lowercased() != "youtu.be", url.path == "/playlist",
              let list = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "list" })?.value,
              (10...200).contains(list.count),
              list.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              !list.hasPrefix("RD") else { return nil }
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
        } else if parts.count == 2, ["shorts", "embed"].contains(parts[0]) { id = parts[1] }
        else { id = nil }
        guard isWebsite(url), let id, id.count == 11,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw ResolutionFailure.unsupportedPage
        }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    func candidates(_ url: URL) async throws -> [MediaCandidate] {
        let page = try Self.videoPage(url)
        let finder = HelperExecutables(environment: environment)
        guard let helper = finder.executable("yt-dlp", override: "AIRPLAYER_YTDLP"),
              let deno = finder.executable("deno", override: "AIRPLAYER_DENO") else {
            throw ResolutionFailure.unavailable
        }
        let arguments = ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--no-remote-components",
                         "--no-js-runtimes", "--js-runtimes", "deno:\(deno)",
                         "--no-playlist", "--playlist-items", "1", "--simulate", "--dump-single-json",
                         "--no-warnings", "--socket-timeout", "10",
                         "--retries", "0", "--extractor-retries", "0", "--", page.absoluteString]
        let data = try await HelperProcess.run(executable: helper, arguments: arguments)
        return try await Self.candidatesWithHLS(data)
    }

    /// yt-dlp flattens alternate-audio HLS into video-only and audio-only
    /// formats. Their shared master URL can still be a complete presentation.
    static func candidatesWithHLS(_ data: Data,
        fetch: @Sendable (URL) async throws -> Data = HLSMaster.fetch) async throws -> [MediaCandidate] {
        let info = try validatedInfo(data)
        var candidates = try candidates(data)

        var seen = Set<URL>()
        for format in info.formats ?? [] {
            let headers = (info.http_headers ?? [:]).merging(format.http_headers ?? [:]) { _, rhs in rhs }
            guard format.has_drm != true,
                  ["m3u8", "m3u8_native"].contains(format.protocol ?? ""),
                  format.vcodec == "h264" || format.vcodec?.hasPrefix("avc1") == true,
                  let raw = format.manifest_url, let master = try? MediaInput.url(raw),
                  headers.keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) }),
                  seen.insert(master).inserted else { continue }
            // Bound the total extra work even when an extractor reports many masters.
            if seen.count > 2 { break }
            try Task.checkCancellation()
            do {
                let manifest = try await fetch(master)
                try Task.checkCancellation()
                if let quality = HLSMaster.quality(manifest, at: master) {
                    candidates.append(MediaCandidate(
                        source: ResolvedSource(url: master, title: cleanTitle(info.title), delivery: .hls,
                                               videoKnownPresent: true),
                        height: quality.height, bitrate: quality.bitrate))
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                // Expired/unavailable/malformed masters must not remove the
                // existing compatible MP4 fallback or expose network error text.
            }
        }
        try Task.checkCancellation()
        return candidates
    }

    public func resolvePlaylist(_ url: URL) async throws -> ResolvedPlaylist {
        guard let page = Self.playlistPage(url) else { throw ResolutionFailure.unsupportedPage }
        let finder = HelperExecutables(environment: environment)
        guard let helper = finder.executable("yt-dlp", override: "AIRPLAYER_YTDLP"),
              let deno = finder.executable("deno", override: "AIRPLAYER_DENO") else {
            throw ResolutionFailure.unavailable
        }
        let arguments = ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--no-remote-components",
                         "--no-js-runtimes", "--js-runtimes", "deno:\(deno)",
                         "--flat-playlist", "--playlist-end", String(Self.maximumPlaylistEntries + 1),
                         "--simulate", "--dump-single-json", "--no-warnings", "--socket-timeout", "10",
                         "--retries", "0", "--extractor-retries", "0", "--", page.absoluteString]
        let data = try await HelperProcess.run(executable: helper, arguments: arguments)
        return try Self.selectPlaylist(data)
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
            let title = cleanTitle(entry.title) ?? "Playlist item \(offset + 1)"
            let live = entry.is_live == true || (entry.live_status != nil && entry.live_status != "not_live" && entry.live_status != "was_live")
            let unavailable = entry.availability.map { !["public", "unlisted"].contains($0) } ?? false
            let id = entry.id ?? entry.url
            let validID = id.map { value in
                value.count == 11 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            } ?? false
            if live { return PlaylistEntry(url: nil, title: title, unavailableReason: "Live playlist entries are not supported.") }
            if unavailable || !validID { return PlaylistEntry(url: nil, title: title, unavailableReason: "This playlist entry is unavailable.") }
            return PlaylistEntry(url: URL(string: "https://www.youtube.com/watch?v=\(id!)"), title: title)
        }
        guard entries.contains(where: { $0.url != nil }) else { throw ResolutionFailure.unsupportedPage }
        return ResolvedPlaylist(title: cleanTitle(info.title) ?? "YouTube playlist", entries: entries, truncated: truncated)
    }

    // yt-dlp reports these defaults even for public URLs that need no custom headers.
    // All other headers require a future Mac-side delivery path. No private AVURLAsset options.
    private static let defaultHeaders: Set<String> = ["user-agent", "accept", "accept-language", "sec-fetch-mode"]

    private static func validatedInfo(_ data: Data) throws -> Info {
        let info: Info
        do { info = try JSONDecoder().decode(Info.self, from: data) }
        catch { throw ResolutionFailure.failed }
        guard info._type == nil || info._type == "video", info.entries == nil,
              info.is_live != true, info.live_status == nil || info.live_status == "not_live" || info.live_status == "was_live",
              info.availability == nil || info.availability == "public" || info.availability == "unlisted" else {
            throw ResolutionFailure.unsupportedPage
        }
        guard info.has_drm != true else { throw ResolutionFailure.protectedMedia }
        return info
    }

    static func candidates(_ data: Data) throws -> [MediaCandidate] {
        let info = try validatedInfo(data)
        guard let formats = info.formats, !formats.isEmpty else { throw ResolutionFailure.failed }
        let title = cleanTitle(info.title)
        var candidates: [MediaCandidate] = []
        for format in formats {
            guard format.has_drm != true,
                  let video = format.vcodec?.lowercased(), video == "h264" || video.hasPrefix("avc1"),
                  let audio = format.acodec?.lowercased(), audio == "aac" || audio.hasPrefix("mp4a"),
                  format.ext == "mp4",
                  ["https", "http", "m3u8_native", "m3u8"].contains(format.protocol ?? ""),
                  let rawURL = format.url, let url = try? MediaInput.url(rawURL),
                  format.fragments == nil else { continue }
            let headers = (info.http_headers ?? [:]).merging(format.http_headers ?? [:]) { _, value in value }
            guard headers.keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) }) else { continue }
            candidates.append(MediaCandidate(source: ResolvedSource(url: url, title: title, headers: headers,
                delivery: ["m3u8", "m3u8_native"].contains(format.protocol ?? "") ? .hls : .file,
                videoKnownPresent: true),
                height: format.height, bitrate: format.tbr))
        }
        // Keep separate progressive MP4/M4A presentations alongside native ones.
        // Actual codecs/profile, duration and stream indices are verified by ffprobe before copying.
        let eligible = formats.filter {
            $0.has_drm != true && $0.fragments == nil && ["https", "http"].contains($0.protocol ?? "")
                && ["mp4", "m4a"].contains($0.ext ?? "")
                && (try? MediaInput.url($0.url ?? "")) != nil
                && ($0.http_headers ?? [:]).keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) })
        }
        guard (info.http_headers ?? [:]).keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) }),
              let audio = eligible.filter({
                  $0.vcodec == "none" && ($0.acodec == "aac" || $0.acodec?.hasPrefix("mp4a") == true)
              }).max(by: { ($0.tbr ?? 0) < ($1.tbr ?? 0) }),
              let rawAudio = audio.url, let audioURL = try? MediaInput.url(rawAudio) else {
            return candidates
        }
        for video in eligible where (video.vcodec == "h264" || video.vcodec?.hasPrefix("avc1") == true)
            && video.acodec == "none" && (video.height ?? .infinity) <= 1080 {
            guard let videoURL = try? MediaInput.url(video.url ?? "") else { continue }
            candidates.append(MediaCandidate(source: ResolvedSource(url: videoURL, title: title,
                headers: (info.http_headers ?? [:]).merging(video.http_headers ?? [:]) { _, rhs in rhs },
                audio: MediaTrack(url: audioURL, headers: (info.http_headers ?? [:]).merging(audio.http_headers ?? [:]) { _, rhs in rhs }),
                delivery: .file, videoKnownPresent: true), height: video.height, bitrate: video.tbr))
        }
        return candidates
    }

    private static func cleanTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let title = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(200))
    }

    private struct Info: Decodable {
        let _type: String?
        let entries: [Ignored]?
        let formats: [Format]?
        let has_drm: Bool?
        let is_live: Bool?
        let live_status: String?
        let availability: String?
        let http_headers: [String: String]?
        let title: String?
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
    private struct Ignored: Decodable {}
    private struct Format: Decodable {
        let url: String?
        let manifest_url: String?
        let vcodec: String?
        let acodec: String?
        let ext: String?
        let `protocol`: String?
        let has_drm: Bool?
        let height: Double?
        let tbr: Double?
        let http_headers: [String: String]?
        let fragments: [Ignored]?
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
