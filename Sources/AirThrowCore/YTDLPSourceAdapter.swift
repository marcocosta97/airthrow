import Foundation

/// Shared website discovery. The installed yt-dlp selects a default site or
/// generic extractor from the URL; candidate eligibility stays in the app.
public struct YTDLPSourceAdapter: SourceAdapter {
    public let id = "yt-dlp"
    public let hosts: [String] = []
    public let isFallback = true
    private let environment: [String: String]
    private let sessions: WebsiteSessions
    private let nativeProbe: @Sendable (URL) async throws -> Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                sessions: WebsiteSessions = WebsiteSessions()) {
        self.environment = environment
        self.sessions = sessions
        self.nativeProbe = { try await NativeSourceProbe.hasPlayableVideo(at: $0) }
    }

    init(environment: [String: String], sessions: WebsiteSessions = WebsiteSessions(),
         nativeProbe: @escaping @Sendable (URL) async throws -> Bool) {
        self.environment = environment
        self.sessions = sessions
        self.nativeProbe = nativeProbe
    }

    public func candidates(for url: URL) async throws -> [MediaCandidate] {
        try Task.checkCancellation()
        let finder = HelperExecutables(environment: environment)
        guard let helper = finder.executable("yt-dlp", override: "AIRTHROW_YTDLP") else {
            return DirectSourceAdapter.candidates(url)
        }
        // Known website pages need extraction. Ambiguous links may already be
        // complete media, so give native inspection a short head start.
        if WebsiteService.service(for: url) == nil {
            let playable = try await nativeProbe(url)
            try Task.checkCancellation()
            if playable {
                // Probe evidence may vary between loads; the original direct
                // presentation must retain the same identity when it does.
                let direct = DirectSourceAdapter.candidates(url)[0]
                return [MediaCandidate(source: ResolvedSource(url: url, videoKnownPresent: true), id: direct.id)]
            }
        }
        var arguments = ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir",
                         "--no-remote-components", "--no-js-runtimes"]
        let scratch: CookieScratch
        if let service = WebsiteService.service(for: url) {
            scratch = sessions.source(for: service).materialize(for: service)
        } else { scratch = .empty }
        defer { scratch.cleanup() }
        if let path = scratch.path { arguments += ["--cookies", path] }
        if let deno = finder.executable("deno", override: "AIRTHROW_DENO") {
            arguments += ["--js-runtimes", "deno:\(deno)"]
        }
        arguments += ["--no-playlist", "--playlist-items", "1", "--simulate",
                      "--dump-single-json", "--no-warnings", "--socket-timeout", "10",
                      "--retries", "0", "--extractor-retries", "0", "--", url.absoluteString]
        let result: HelperProcess.Result
        do {
            result = try await HelperProcess.runCapturingStderr(executable: helper, arguments: arguments)
        } catch ResolutionFailure.unavailable {
            // An executable can disappear or fail to launch after discovery.
            try Task.checkCancellation()
            return DirectSourceAdapter.candidates(url)
        }
        try Task.checkCancellation()
        // An unrecognized page might be an extensionless direct media URL.
        // Give that input one native attempt, with no recursive extraction.
        guard result.succeeded, !result.output.isEmpty else {
            return DirectSourceAdapter.candidates(url)
        }
        do {
            let choices = try await ExtractedSourceAdapter.candidatesWithHLS(
                result.output, allowUnverifiedWholeSources: true,
                allowAuthenticated: scratch.path != nil)
            guard !choices.isEmpty else { throw ResolutionFailure.failed }
            return choices
        } catch ResolutionFailure.failed {
            // Successful extraction can still return incomplete metadata or no
            // eligible presentation for an extensionless media URL. Inspect the
            // original input through the normal native loading path, just as
            // when extraction fails. Do not reuse extracted URLs or headers,
            // or claim video evidence before AVPlayer verifies the input.
            try Task.checkCancellation()
            return DirectSourceAdapter.candidates(url)
        } catch ResolutionFailure.unsupportedPage {
            try Task.checkCancellation()
            return DirectSourceAdapter.candidates(url)
        }
    }
}
