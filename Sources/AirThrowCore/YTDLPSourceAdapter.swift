import Foundation

/// Shared website discovery. The installed yt-dlp selects a default site or
/// generic extractor from the URL; candidate eligibility stays in the app.
public struct YTDLPSourceAdapter: SourceAdapter {
    public let id = "yt-dlp"
    public let hosts: [String] = []
    public let isFallback = true
    private let environment: [String: String]
    private let sessions: WebsiteSessions

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                sessions: WebsiteSessions = WebsiteSessions()) {
        self.environment = environment
        self.sessions = sessions
    }

    public func candidates(for url: URL) async throws -> [MediaCandidate] {
        try Task.checkCancellation()
        let finder = HelperExecutables(environment: environment)
        guard let helper = finder.executable("yt-dlp", override: "AIRTHROW_YTDLP") else {
            return DirectSourceAdapter.candidates(url)
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
        } catch ResolutionFailure.unsupportedPage {
            throw ResolutionFailure.failed
        }
    }
}
