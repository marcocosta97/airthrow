import Foundation

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
    public init(url: URL, title: String? = nil, headers: [String: String] = [:], audio: MediaTrack? = nil, needsPreparation: Bool = false) {
        self.url = url; self.title = title; self.headers = headers; self.audio = audio
        self.needsPreparation = needsPreparation || audio != nil
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

    func executable(_ name: String, override: String) -> String? {
        let fm = FileManager.default
        if let path = environment[override] {
            return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? path : nil
        }
        let paths = ["/opt/homebrew/bin", "/usr/local/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.filter { $0.hasPrefix("/") }.map { "\($0)/\(name)" }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    public func resolve(_ url: URL) async throws -> ResolvedSource {
        guard Self.isWebsite(url) else { return ResolvedSource(url: url) }
        let page = try Self.videoPage(url)
        guard let helper = executable("yt-dlp", override: "AIRPLAYER_YTDLP"),
              let deno = executable("deno", override: "AIRPLAYER_DENO") else {
            throw ResolutionFailure.unavailable
        }
        let arguments = ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--no-remote-components",
                         "--no-js-runtimes", "--js-runtimes", "deno:\(deno)",
                         "--no-playlist", "--playlist-items", "1", "--simulate", "--dump-single-json",
                         "--no-warnings", "--socket-timeout", "10",
                         "--retries", "0", "--extractor-retries", "0", "--", page.absoluteString]
        let data = try await HelperProcess.run(executable: helper, arguments: arguments)
        return try await Self.selectWithHLS(data)
    }

    /// yt-dlp flattens alternate-audio HLS into video-only and audio-only
    /// formats. Their shared master URL can still be a complete presentation.
    static func selectWithHLS(_ data: Data,
        fetch: @Sendable (URL) async throws -> Data = HLSMaster.fetch) async throws -> ResolvedSource {
        let info = try validatedInfo(data)
        let fallback: ResolvedSource?
        do { fallback = try select(data) }
        catch ResolutionFailure.preparationRequired { fallback = nil }
        if let fallback, !fallback.needsPreparation { return fallback }

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
                if HLSMaster.hasAudioVideo(manifest, at: master) {
                    return ResolvedSource(url: master, title: cleanTitle(info.title))
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                // Expired/unavailable/malformed masters must not remove the
                // existing compatible MP4 fallback or expose network error text.
            }
        }
        try Task.checkCancellation()
        guard let fallback else { throw ResolutionFailure.preparationRequired }
        return fallback
    }

    public func resolvePlaylist(_ url: URL) async throws -> ResolvedPlaylist {
        guard let page = Self.playlistPage(url) else { throw ResolutionFailure.unsupportedPage }
        guard let helper = executable("yt-dlp", override: "AIRPLAYER_YTDLP"),
              let deno = executable("deno", override: "AIRPLAYER_DENO") else {
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

    static func select(_ data: Data) throws -> ResolvedSource {
        let info = try validatedInfo(data)
        guard let formats = info.formats, !formats.isEmpty else { throw ResolutionFailure.failed }
        let title = cleanTitle(info.title)
        var candidates: [(Format, ResolvedSource)] = []
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
            candidates.append((format, ResolvedSource(url: url, title: title, headers: headers)))
        }
        // Prefer the highest available combined H.264/AAC source. Never silently drop audio.
        let selected = candidates.max { lhs, rhs in
            if (lhs.0.height ?? 0) != (rhs.0.height ?? 0) { return (lhs.0.height ?? 0) < (rhs.0.height ?? 0) }
            return (lhs.0.tbr ?? 0) < (rhs.0.tbr ?? 0)
        }
        if let selected { return selected.1 }
        // Fall back to separate progressive MP4/M4A tracks, never to a silent video.
        // Actual codecs/profile, duration and stream indices are verified by ffprobe before copying.
        let eligible = formats.filter {
            $0.has_drm != true && $0.fragments == nil && ["https", "http"].contains($0.protocol ?? "")
                && ["mp4", "m4a"].contains($0.ext ?? "")
                && (try? MediaInput.url($0.url ?? "")) != nil
                && ($0.http_headers ?? [:]).keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) })
        }
        guard (info.http_headers ?? [:]).keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) }),
              let video = eligible.filter({
                  ($0.vcodec == "h264" || $0.vcodec?.hasPrefix("avc1") == true) && $0.acodec == "none"
                      && ($0.height ?? .infinity) <= 1080
              }).max(by: { ($0.height ?? 0, $0.tbr ?? 0) < ($1.height ?? 0, $1.tbr ?? 0) }),
              let audio = eligible.filter({
                  $0.vcodec == "none" && ($0.acodec == "aac" || $0.acodec?.hasPrefix("mp4a") == true)
              }).max(by: { ($0.tbr ?? 0) < ($1.tbr ?? 0) }),
              let rawVideo = video.url, let videoURL = try? MediaInput.url(rawVideo),
              let rawAudio = audio.url, let audioURL = try? MediaInput.url(rawAudio) else {
            throw ResolutionFailure.preparationRequired
        }
        return ResolvedSource(url: videoURL, title: title,
            headers: (info.http_headers ?? [:]).merging(video.http_headers ?? [:]) { _, rhs in rhs },
            audio: MediaTrack(url: audioURL, headers: (info.http_headers ?? [:]).merging(audio.http_headers ?? [:]) { _, rhs in rhs }))
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
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U",
              !lines.contains(where: { $0.hasPrefix("#EXT-X-SESSION-KEY:") }) else { return false }
        var audioGroups = Set<String>()
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            guard let attrs = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count))),
                  attrs["TYPE"] == "AUDIO", let group = attrs["GROUP-ID"], !group.isEmpty,
                  let uri = attrs["URI"], validURI(uri, at: base) else { continue }
            audioGroups.insert(group)
        }
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
            return true
        }
        return false
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
