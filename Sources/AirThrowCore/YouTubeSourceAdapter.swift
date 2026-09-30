import Foundation

/// YouTube URL, playlist, and cookie handling. Metadata eligibility is shared
/// with the generic web adapter; ranking belongs to MediaSelector.
struct YouTubeSourceAdapter: SourceAdapter {
    public static let maximumPlaylistEntries = 100
    var id: String { "youtube" }
    var hosts: [String] { Self.supportedHosts }
    var handlesDirectMediaURLs: Bool { true }
    private static let supportedHosts = ["youtube.com", "www.youtube.com", "m.youtube.com",
        "music.youtube.com", "youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com"]
    private let environment: [String: String]
    private let cookies: YouTubeCookies
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                cookies: YouTubeCookies? = nil) {
        self.environment = environment
        self.cookies = cookies ?? YouTubeCookies.fromEnvironment(environment)
    }

    public static func isWebsite(_ url: URL) -> Bool {
        supportedHosts.contains(url.host?.lowercased() ?? "")
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

    func candidates(for url: URL) async throws -> [MediaCandidate] {
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
        return try await ExtractedSourceAdapter.candidatesWithHLS(result.output,
                                                                  allowAuthenticated: scratch.path != nil)
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
