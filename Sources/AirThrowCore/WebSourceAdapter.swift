import Foundation

/// Best-effort extraction for an ambiguous non-YouTube URL. The generic yt-dlp
/// extractor is deliberately the only enabled extractor; it receives no cookies
/// or app-specific request headers.
struct WebSourceAdapter: Sendable {
    private let environment: [String: String]

    init(environment: [String: String]) { self.environment = environment }

    func candidates(_ url: URL) async throws -> [MediaCandidate] {
        let finder = HelperExecutables(environment: environment)
        guard let helper = finder.executable("yt-dlp", override: "AIRTHROW_YTDLP") else {
            return DirectSourceAdapter.candidates(url)
        }
        var arguments = ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir",
                         "--no-remote-components", "--use-extractors", "generic",
                         "--no-js-runtimes"]
        if let deno = finder.executable("deno", override: "AIRTHROW_DENO") {
            arguments += ["--js-runtimes", "deno:\(deno)"]
        }
        arguments += ["--no-playlist", "--playlist-items", "1", "--simulate",
                      "--dump-single-json", "--no-warnings", "--socket-timeout", "10",
                      "--retries", "0", "--extractor-retries", "0", "--", url.absoluteString]
        let result = try await HelperProcess.runCapturingStderr(executable: helper, arguments: arguments)
        // An unrecognized page might be an extensionless direct media URL.
        // Give that input one native attempt, with no recursive extraction.
        guard result.succeeded, !result.output.isEmpty else {
            return DirectSourceAdapter.candidates(url)
        }
        do {
            let choices = try await ExtractedSourceAdapter.candidatesWithHLS(result.output)
            guard !choices.isEmpty else { throw ResolutionFailure.failed }
            return choices
        } catch ResolutionFailure.unsupportedPage {
            throw ResolutionFailure.failed
        }
    }
}
