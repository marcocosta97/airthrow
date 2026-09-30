import Foundation

/// Manifest-backed website discovery. Helper execution, candidate eligibility,
/// and request access remain shared rather than configurable per website.
public struct YTDLPSourceAdapter: SourceAdapter {
    public let manifest: YTDLPSourceManifest
    public var id: String { manifest.id }
    public var hosts: [String] { manifest.hosts }
    public var isFallback: Bool { manifest.fallback }
    private let environment: [String: String]

    public init(manifest: YTDLPSourceManifest,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.manifest = manifest
        self.environment = environment
    }

    public func candidates(for url: URL) async throws -> [MediaCandidate] {
        try Task.checkCancellation()
        let finder = HelperExecutables(environment: environment)
        guard let helper = finder.executable("yt-dlp", override: "AIRTHROW_YTDLP") else {
            guard isFallback else { throw ResolutionFailure.unavailable }
            return DirectSourceAdapter.candidates(url)
        }
        // yt-dlp interprets this option as patterns. Manifests contain literal
        // names, so anchor each one to avoid enabling similarly named extractors.
        let extractors = manifest.extractors.map { "^\($0)$" }.joined(separator: ",")
        var arguments = ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir",
                         "--no-remote-components", "--use-extractors", extractors,
                         "--no-js-runtimes"]
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
            guard isFallback else { throw ResolutionFailure.unavailable }
            return DirectSourceAdapter.candidates(url)
        }
        try Task.checkCancellation()
        // An unrecognized page might be an extensionless direct media URL.
        // Give that input one native attempt, with no recursive extraction.
        guard result.succeeded, !result.output.isEmpty else {
            guard isFallback else { throw ResolutionFailure.failed }
            return DirectSourceAdapter.candidates(url)
        }
        do {
            let choices = try await ExtractedSourceAdapter.candidatesWithHLS(
                result.output, allowUnverifiedWholeSources: true)
            guard !choices.isEmpty else { throw ResolutionFailure.failed }
            return choices
        } catch ResolutionFailure.unsupportedPage {
            throw ResolutionFailure.failed
        }
    }
}
