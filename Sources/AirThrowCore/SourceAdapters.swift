import Foundation

extension SourceRegistry {
    /// The installed yt-dlp chooses its own extractor for ordinary websites.
    /// Register custom adapters only where discovery requires app-specific work.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment,
                                cookies: YouTubeCookies? = nil,
                                sessions: WebsiteSessions? = nil,
                                additionalAdapters: [any SourceAdapter] = []) throws -> SourceRegistry {
        let youtubeCookies = cookies ?? sessions.map { $0.source(for: .youtube) }
        return try SourceRegistry(adapters: customAdapters(environment: environment, cookies: youtubeCookies)
                           + [YTDLPSourceAdapter(environment: environment, sessions: sessions ?? WebsiteSessions())] + additionalAdapters)
    }

    private static func customAdapters(environment: [String: String],
                                       cookies: YouTubeCookies?) -> [any SourceAdapter] {
        [YouTubeSourceAdapter(environment: environment, cookies: cookies)]
    }
}
