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

public struct ResolvedSource: Sendable {
    public let url: URL
    // Keep request metadata in memory. Never put URLs, headers, or helper output into status/logs.
    public let headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) { self.url = url; self.headers = headers }
}

public struct SourceResolver: Sendable {
    private let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public static func isWebsite(_ url: URL) -> Bool {
        ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be",
         "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(url.host?.lowercased() ?? "")
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
        return try Self.select(try await HelperProcess.run(executable: helper, arguments: arguments))
    }

    // yt-dlp reports these defaults even for public URLs that need no custom headers.
    // All other headers require a future Mac-side delivery path. No private AVURLAsset options.
    private static let defaultHeaders: Set<String> = ["user-agent", "accept", "accept-language", "sec-fetch-mode"]

    static func select(_ data: Data) throws -> ResolvedSource {
        let info: Info
        do { info = try JSONDecoder().decode(Info.self, from: data) }
        catch { throw ResolutionFailure.failed }
        guard info._type == nil || info._type == "video", info.entries == nil,
              info.is_live != true, info.live_status == nil || info.live_status == "not_live" || info.live_status == "was_live",
              info.availability == nil || info.availability == "public" || info.availability == "unlisted" else {
            throw ResolutionFailure.unsupportedPage
        }
        guard info.has_drm != true else { throw ResolutionFailure.protectedMedia }
        guard let formats = info.formats, !formats.isEmpty else { throw ResolutionFailure.failed }
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
            candidates.append((format, ResolvedSource(url: url, headers: headers)))
        }
        // Prefer the highest available combined H.264/AAC source. Never silently drop audio.
        let selected = candidates.max { lhs, rhs in
            if (lhs.0.height ?? 0) != (rhs.0.height ?? 0) { return (lhs.0.height ?? 0) < (rhs.0.height ?? 0) }
            return (lhs.0.tbr ?? 0) < (rhs.0.tbr ?? 0)
        }
        guard let selected else { throw ResolutionFailure.preparationRequired }
        return selected.1
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
    }
    private struct Ignored: Decodable {}
    private struct Format: Decodable {
        let url: String?
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
