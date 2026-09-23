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

public struct ResolvedSource: Sendable {
    public let url: URL
    public let title: String?
    // Keep request metadata in memory. Never put URLs, headers, or helper output into status/logs.
    public let headers: [String: String]
    public let audio: MediaTrack?
    public let needsPreparation: Bool
    /// The source must be exposed through AirThrow's LAN server before AVPlayer
    /// can hand it to a receiver. This is independent of whether tracks are remuxed.
    public let needsDelivery: Bool
    public let delivery: MediaDelivery
    /// Positive video evidence from an inspected presentation, not its URL or extension.
    public let videoKnownPresent: Bool
    /// The conversion preference in force when this plan was chosen.
    public let conversionPolicy: ConversionPolicy
    /// A concrete processing tier chosen by the selector. Nil means the tier is
    /// derived from `needsPreparation`; set it to request audio/video conversion.
    public let plannedPath: PlaybackPath?
    public var playbackPath: PlaybackPath { plannedPath ?? (needsPreparation ? .remux : .direct) }
    public var needsPreparationPipeline: Bool { needsPreparation || needsDelivery }
    public init(url: URL, title: String? = nil, headers: [String: String] = [:], audio: MediaTrack? = nil,
                needsPreparation: Bool = false, needsDelivery: Bool = false, delivery: MediaDelivery = .unknown,
                videoKnownPresent: Bool = false, conversionPolicy: ConversionPolicy = .avoidVideo,
                plannedPath: PlaybackPath? = nil) {
        self.url = url; self.title = title; self.headers = headers; self.audio = audio
        self.needsPreparation = needsPreparation || audio != nil || (plannedPath.map { $0 != .direct } ?? false)
        self.needsDelivery = needsDelivery
        self.delivery = delivery
        self.videoKnownPresent = videoKnownPresent
        self.conversionPolicy = conversionPolicy
        self.plannedPath = plannedPath
    }

    /// Copy the same presentation with a different conversion preference. The
    /// planned path and every delivery flag are preserved.
    public func withConversionPolicy(_ policy: ConversionPolicy) -> ResolvedSource {
        ResolvedSource(url: url, title: title, headers: headers, audio: audio,
                       needsPreparation: needsPreparation, needsDelivery: needsDelivery,
                       delivery: delivery, videoKnownPresent: videoKnownPresent,
                       conversionPolicy: policy, plannedPath: plannedPath)
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
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                cookies: YouTubeCookies? = nil) {
        youtube = YouTubeSourceAdapter(environment: environment, cookies: cookies)
    }

    public func candidates(for url: URL) async throws -> [MediaCandidate] {
        if url.isFileURL { return try LocalSourceAdapter.candidates(url) }
        if Self.isWebsite(url) { return try await youtube.candidates(url) }
        return DirectSourceAdapter.candidates(url)
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
    public static func videoPage(_ url: URL) throws -> URL { try YouTubeSourceAdapter.videoPage(url) }
    public static func playlistPage(_ url: URL) -> URL? { YouTubeSourceAdapter.playlistPage(url) }
}

/// yt-dlp extraction and eligibility checks only; ranking belongs to MediaSelector.
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
        return try await Self.candidatesWithHLS(result.output)
    }

    /// yt-dlp flattens alternate-audio HLS into video-only and audio-only
    /// formats. Their shared master URL can still be a complete presentation.
    static func candidatesWithHLS(_ data: Data,
        fetch: @Sendable (URL) async throws -> Data = HLSMaster.fetch) async throws -> [MediaCandidate] {
        let info = try validatedInfo(data)
        var candidates = try candidates(data)

        // A master is a repeat only when its URL and headers both match, so two
        // masters that share a format signature but differ in request headers are
        // both inspected and left for the selector to disambiguate.
        var seen = Set<String>()
        for format in info.formats ?? [] {
            let headers = (info.http_headers ?? [:]).merging(format.http_headers ?? [:]) { _, rhs in rhs }
            guard format.has_drm != true,
                  ["m3u8", "m3u8_native"].contains(format.protocol ?? ""),
                  format.vcodec == "h264" || format.vcodec?.hasPrefix("avc1") == true,
                  let raw = format.manifest_url, let master = try? MediaInput.url(raw),
                  headers.keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) }),
                  seen.insert(MediaCandidate.signature([master.absoluteString,
                                                        headerSignature(headers)])).inserted else { continue }
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
                        id: formatIdentifier(format, role: "hls"),
                        height: quality.height, bitrate: quality.bitrate,
                        audioDescription: audioDescription(format)))
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                // Expired/unavailable/malformed masters must not remove the
                // existing compatible MP4 fallback or expose network error text.
            }
        }
        try Task.checkCancellation()
        // Live media has no finite duration and can never be prepared. When no
        // native presentation was found, refuse it here instead of letting the
        // selector offer a preparation path that cannot succeed.
        if info.isIndefiniteLive, !candidates.contains(where: { !$0.source.needsPreparation }) {
            throw ResolutionFailure.liveUnsupported
        }
        return candidates
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
            let title = cleanTitle(entry.title) ?? "Playlist item \(offset + 1)"
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
              info.live_status != "is_upcoming",
              info.availability == nil || info.availability == "public" || info.availability == "unlisted" else {
            throw ResolutionFailure.unsupportedPage
        }
        guard info.has_drm != true else { throw ResolutionFailure.protectedMedia }
        return info
    }

    /// Bound extra work: YouTube can report dozens of overlapping formats.
    private static let maximumPairedVideos = 8
    private static let maximumAudioLanguages = 4
    private static let maximumDirectCombined = 12
    private static let maximumConversionCombined = 12
    private static let maximumCandidates = 40

    static func candidates(_ data: Data) throws -> [MediaCandidate] {
        let info = try validatedInfo(data)
        guard let formats = info.formats, !formats.isEmpty else { throw ResolutionFailure.failed }
        let title = cleanTitle(info.title)
        let infoHeaders = info.http_headers ?? [:]
        let live = info.isIndefiniteLive
        // Info-level custom request headers would apply to every presentation.
        guard infoHeaders.keys.allSatisfy({ defaultHeaders.contains($0.lowercased()) }) else { return [] }

        func wholePresentation(_ format: Format) -> (url: URL, headers: [String: String])? {
            guard let url = format.url.flatMap({ try? MediaInput.url($0) }) else { return nil }
            return (url, infoHeaders.merging(format.http_headers ?? [:]) { _, rhs in rhs })
        }

        // Each category is ordered by the shared cost-first policy before its
        // bound is applied, so a bounded candidate set never depends on the
        // order in which an extractor reports formats.
        let direct = formats
            .filter(isDirectCombined)
            .compactMap { format -> MediaCandidate? in
                guard let whole = wholePresentation(format) else { return nil }
                return MediaCandidate(
                    source: ResolvedSource(url: whole.url, title: title, headers: whole.headers,
                                           delivery: isHLSContainer(format) ? .hls : .file,
                                           videoKnownPresent: true),
                    id: formatIdentifier(format, role: "direct"),
                    height: format.height, bitrate: format.tbr,
                    frameRate: format.fps,
                    audioDescription: audioDescription(format))
            }
            .sorted(by: costFirst)
            .prefix(maximumDirectCombined)

        // Whole presentations that need remuxing or conversion. Because this set
        // is capped, a flood of high-resolution AV1/VP9 video-conversion formats
        // must not displace a cheaper H.264 remux. Live media is indefinite and
        // cannot be prepared, so these plans are skipped entirely.
        let conversions = formats
            .filter { !live && !isDirectCombined($0) && isConversionCombined($0) }
            .compactMap { format -> MediaCandidate? in
                guard let whole = wholePresentation(format) else { return nil }
                return MediaCandidate(
                    source: ResolvedSource(url: whole.url, title: title, headers: whole.headers,
                                           needsPreparation: true, delivery: .file,
                                           videoKnownPresent: true, plannedPath: combinedPlan(format)),
                    id: formatIdentifier(format, role: "convert"),
                    height: format.height, bitrate: format.tbr,
                    frameRate: format.fps,
                    audioDescription: audioDescription(format),
                    unavailableReason: preparationLimitReason(format))
            }
            .sorted(by: costFirst)
            .prefix(maximumConversionCombined)

        // Separate video and audio presentations combined into one plan. Actual
        // codecs/profile and stream indices are re-verified by ffprobe. Videos
        // rank by plan cost before resolution so a compatible H.264 remux
        // survives a flood of high-resolution AV1/VP9 conversion videos. Live
        // media is indefinite and cannot be prepared, so paired tracks are
        // skipped just like whole-presentation conversions.
        var pairs: [MediaCandidate] = []
        if !live {
            let videos = formats
                .filter(isSimpleVideoOnly)
                .sorted(by: videoCostFirst)
                .prefix(maximumPairedVideos)
            var audioByLanguage: [String: [Format]] = [:]
            for format in formats where isSimpleAudioOnly(format) {
                audioByLanguage[languageKey(format.language), default: []].append(format)
            }
            let languages = audioByLanguage.keys.sorted { left, right in
                languagePriority(left, right, tracks: audioByLanguage)
            }.prefix(maximumAudioLanguages)
            for video in videos {
                guard let videoURL = try? MediaInput.url(video.url ?? "") else { continue }
                let videoHeaders = infoHeaders.merging(video.http_headers ?? [:]) { _, rhs in rhs }
                for key in languages {
                    guard let audio = preferredAudio(audioByLanguage[key] ?? []),
                          let audioURL = try? MediaInput.url(audio.url ?? "") else { continue }
                    let audioHeaders = infoHeaders.merging(audio.http_headers ?? [:]) { _, rhs in rhs }
                    pairs.append(MediaCandidate(
                        source: ResolvedSource(url: videoURL, title: title, headers: videoHeaders,
                                               audio: MediaTrack(url: audioURL, headers: audioHeaders),
                                               needsPreparation: true, delivery: .file, videoKnownPresent: true,
                                               plannedPath: pairedPlan(video, audio: audio)),
                        id: pairIdentifier(video, audio),
                        height: video.height, bitrate: video.tbr,
                        frameRate: video.fps,
                        audioDescription: audioDescription(audio),
                        unavailableReason: preparationLimitReason(video)))
                }
            }
        }

        // Assemble cost-first across every category within the total bound. Only
        // a byte-for-byte repeat of the same presentation, including both header
        // sets, is dropped. A genuine identity collision between different
        // presentations is preserved so the selector refuses an ambiguous
        // explicit choice instead of silently overriding one of them.
        var presentations = Set<String>()
        var result: [MediaCandidate] = []
        for candidate in (Array(direct) + Array(conversions) + pairs).sorted(by: costFirst) {
            guard result.count < maximumCandidates else { break }
            guard presentations.insert(sourceKey(candidate)).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    /// Lower processing tiers rank first, then resolution and bitrate. The
    /// identifier breaks exact ties, so both per-category caps and the total
    /// bound retain the same presentations regardless of extractor order.
    private static func costFirst(_ left: MediaCandidate, _ right: MediaCandidate) -> Bool {
        if (left.unavailableReason == nil) != (right.unavailableReason == nil) {
            return left.unavailableReason == nil
        }
        if MediaSelector.rankedBelow(right, left) { return true }
        if MediaSelector.rankedBelow(left, right) { return false }
        return left.id < right.id
    }

    /// Videos that need a video encode rank below cheaper plans before the
    /// paired-video bound is applied; resolution only breaks ties in a tier.
    private static func videoCostFirst(_ left: Format, _ right: Format) -> Bool {
        if (preparationLimitReason(left) == nil) != (preparationLimitReason(right) == nil) {
            return preparationLimitReason(left) == nil
        }
        let leftTier = needsVideoConversion(left) ? 4 : 2
        let rightTier = needsVideoConversion(right) ? 4 : 2
        if leftTier != rightTier { return leftTier < rightTier }
        if (left.height ?? 0) != (right.height ?? 0) { return (left.height ?? 0) > (right.height ?? 0) }
        if (left.tbr ?? 0) != (right.tbr ?? 0) { return (left.tbr ?? 0) > (right.tbr ?? 0) }
        return formatSignature(left) < formatSignature(right)
    }

    /// Prefer a language that already offers AAC (a remux plan) over one that
    /// would force an audio encode, then order by the cleaned language key.
    private static func languagePriority(_ left: String, _ right: String,
                                         tracks: [String: [Format]]) -> Bool {
        let leftAAC = (tracks[left] ?? []).contains { isAAC(audioCodec($0)) }
        let rightAAC = (tracks[right] ?? []).contains { isAAC(audioCodec($0)) }
        if leftAAC != rightAAC { return leftAAC }
        return left < right
    }

    /// Identical-source key: identity, URLs and both header sets must all match
    /// before a presentation is treated as a repeat. Different headers never
    /// collapse into one candidate.
    private static func sourceKey(_ candidate: MediaCandidate) -> String {
        MediaCandidate.signature([
            candidate.id,
            candidate.source.url.absoluteString,
            candidate.source.audio?.url.absoluteString ?? "",
            headerSignature(candidate.source.headers),
            headerSignature(candidate.source.audio?.headers ?? [:])
        ])
    }

    private static func headerSignature(_ headers: [String: String]) -> String {
        MediaCandidate.signature(headers.sorted { lhs, rhs in
            let leftKey = lhs.key.lowercased(), rightKey = rhs.key.lowercased()
            if leftKey != rightKey { return leftKey < rightKey }
            return lhs.key < rhs.key
        }.flatMap { [$0.key.lowercased(), $0.value] })
    }

    private static func videoCodec(_ format: Format) -> String? {
        guard let codec = format.vcodec?.lowercased(), !codec.isEmpty, codec != "none" else { return nil }
        return codec
    }

    private static func audioCodec(_ format: Format) -> String? {
        guard let codec = format.acodec?.lowercased(), !codec.isEmpty, codec != "none" else { return nil }
        return codec
    }

    private static func isH264(_ format: Format) -> Bool {
        guard let codec = videoCodec(format) else { return false }
        return codec == "h264" || codec.hasPrefix("avc1")
    }

    private static func isAAC(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return codec == "aac" || codec.hasPrefix("mp4a")
    }

    private static func isHLSContainer(_ format: Format) -> Bool {
        ["m3u8", "m3u8_native"].contains(format.protocol ?? "")
    }

    private static func isSimpleHTTP(_ format: Format) -> Bool {
        ["https", "http"].contains(format.protocol ?? "")
    }

    private static func isDemuxable(_ format: Format) -> Bool {
        ["mp4", "m4a", "webm", "mkv"].contains(format.ext ?? "")
    }

    private static func headersAreDefault(_ format: Format) -> Bool {
        (format.http_headers ?? [:]).keys.allSatisfy { defaultHeaders.contains($0.lowercased()) }
    }

    /// HDR video cannot be prepared without tone mapping, so it is exposed as a
    /// disabled candidate rather than silently dropped. Prefer the video-specific
    /// fields; a free-form note may mention Dolby audio on an SDR stream.
    private static func isHDR(_ format: Format) -> Bool {
        let videoRange = [format.dynamic_range, format.video_range].compactMap { $0?.lowercased() }
        if videoRange.contains(where: { $0.contains("hdr") || $0.contains("dolby") || $0.contains("hlg") }) {
            return true
        }
        guard let note = format.format_note?.lowercased() else { return false }
        return note.contains("hdr") || note.contains("dolby vision")
    }

    /// A preparation candidate is disabled only when no supported conversion can
    /// rescue it. Resolution and frame rate above the output profile are handled
    /// by downscaling under `.allowVideo`, not rejected here. The input bound is
    /// deliberately conservative until the preparer states its own limits.
    private static func preparationLimitReason(_ format: Format) -> String? {
        if isHDR(format) { return "HDR video is not supported." }
        if let width = format.width, width > 3840 {
            return "Video wider than 4K is not supported for preparation."
        }
        if let height = format.height, height > 2160 {
            return "Video above 4K is not supported for preparation."
        }
        if let fps = format.fps, fps > 120 {
            return "Video above 120 fps is not supported for preparation."
        }
        return nil
    }

    private static func isDirectCombined(_ format: Format) -> Bool {
        format.has_drm != true && format.fragments == nil
            && format.ext == "mp4" && (isSimpleHTTP(format) || isHLSContainer(format))
            && isH264(format) && isAAC(audioCodec(format))
            && format.url.flatMap { try? MediaInput.url($0) } != nil
            && headersAreDefault(format)
    }

    private static func isConversionCombined(_ format: Format) -> Bool {
        format.has_drm != true && format.fragments == nil
            && isDemuxable(format) && isSimpleHTTP(format)
            && videoCodec(format) != nil && audioCodec(format) != nil
            && format.url.flatMap { try? MediaInput.url($0) } != nil
            && headersAreDefault(format)
    }

    private static func isSimpleVideoOnly(_ format: Format) -> Bool {
        format.has_drm != true && format.fragments == nil
            && isDemuxable(format) && isSimpleHTTP(format)
            && videoCodec(format) != nil && audioCodec(format) == nil
            && format.url.flatMap { try? MediaInput.url($0) } != nil
            && headersAreDefault(format)
    }

    private static func isSimpleAudioOnly(_ format: Format) -> Bool {
        format.has_drm != true && format.fragments == nil
            && isDemuxable(format) && isSimpleHTTP(format)
            && videoCodec(format) == nil && audioCodec(format) != nil
            && format.url.flatMap { try? MediaInput.url($0) } != nil
            && headersAreDefault(format)
    }

    /// Any known-compatible video that exceeds the preparation output profile
    /// (codec, resolution or frame rate) still needs a video encode, which
    /// `.allowVideo` permits as a downscale. Direct native candidates keep their
    /// existing latitude because they never pass through preparation.
    private static func needsVideoConversion(_ video: Format) -> Bool {
        if !isH264(video) { return true }
        if let width = video.width, width > 1920 { return true }
        if let height = video.height, height > 1080 { return true }
        if let fps = video.fps, fps > 60 { return true }
        return false
    }

    private static func combinedPlan(_ format: Format) -> PlaybackPath {
        if needsVideoConversion(format) { return .videoConversion }
        return isAAC(audioCodec(format)) ? .remux : .audioConversion
    }

    private static func pairedPlan(_ video: Format, audio: Format) -> PlaybackPath {
        if needsVideoConversion(video) { return .videoConversion }
        return isAAC(audioCodec(audio)) ? .remux : .audioConversion
    }

    private static func audioBitrate(_ format: Format) -> Double {
        format.abr ?? format.tbr ?? 0
    }

    /// AAC first so receivers avoid an audio encode; otherwise the best track.
    private static func preferredAudio(_ formats: [Format]) -> Format? {
        let aac = formats.filter { isAAC(audioCodec($0)) }
        let pool = aac.isEmpty ? formats : aac
        return pool.max {
            if audioBitrate($0) != audioBitrate($1) { return audioBitrate($0) < audioBitrate($1) }
            return formatSignature($0) < formatSignature($1)
        }
    }

    private static let maximumLanguageLength = 32
    private static let maximumAudioDescriptionLength = 80

    /// Clean a status-visible label: drop control characters, bound its length,
    /// and refuse URL-like values so request detail never reaches status.
    private static func cleanLabel(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let withoutControl = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(withoutControl)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("http") || lowered.contains("/")
            || lowered.contains("?") || lowered.contains("@") {
            return nil
        }
        return String(trimmed.prefix(maxLength))
    }

    private static func languageKey(_ value: String?) -> String {
        cleanLabel(value, maxLength: maximumLanguageLength) ?? ""
    }

    /// A complete, order-independent metadata signature. It never contains a
    /// media URL, so hashing it yields a stable identity across re-resolution and
    /// format reordering. Distinct presentations that share a signature are kept
    /// and left for the selector to reject as ambiguous.
    private static func formatSignature(_ format: Format) -> String {
        MediaCandidate.signature([
            format.format_id ?? "", videoCodec(format) ?? "", audioCodec(format) ?? "", format.ext ?? "",
            format.protocol ?? "", MediaCandidate.stableNumber(format.width),
            MediaCandidate.stableNumber(format.height), MediaCandidate.stableNumber(format.fps),
            MediaCandidate.stableNumber(format.tbr), MediaCandidate.stableNumber(format.abr),
            format.audio_channels.map { String($0) } ?? "", languageKey(format.language),
            format.dynamic_range ?? "", format.video_range ?? "", format.format_note ?? ""])
    }

    private static func formatIdentifier(_ format: Format, role: String) -> String {
        "\(role)-" + MediaCandidate.stableHash(formatSignature(format))
    }

    private static func pairIdentifier(_ video: Format, _ audio: Format) -> String {
        "pair-" + MediaCandidate.stableHash(
            MediaCandidate.signature([formatSignature(video), formatSignature(audio)]))
    }

    private static func audioDescription(_ format: Format) -> String? {
        var parts: [String] = []
        if let language = cleanLabel(format.language, maxLength: maximumLanguageLength) { parts.append(language) }
        if let codec = audioCodec(format) { parts.append(displayName(for: codec)) }
        if let channels = format.audio_channels, channels > 0 {
            parts.append(channels == 1 ? "mono" : channels == 2 ? "stereo" : "\(min(channels, 32))ch")
        }
        guard !parts.isEmpty else { return nil }
        return cleanLabel(parts.joined(separator: " · "), maxLength: maximumAudioDescriptionLength)
    }

    private static func displayName(for codec: String) -> String {
        if isAAC(codec) { return "AAC" }
        if codec.hasPrefix("opus") { return "Opus" }
        if codec.hasPrefix("flac") { return "FLAC" }
        if codec.hasPrefix("vorbis") { return "Vorbis" }
        if codec.hasPrefix("mp3") { return "MP3" }
        if codec.hasPrefix("eac3") || codec.hasPrefix("ec-3") { return "E-AC-3" }
        if codec.hasPrefix("ac3") || codec.hasPrefix("ac-3") { return "AC-3" }
        let cleaned = MediaCandidate.sanitizedIdentifier(codec).uppercased()
        return String(cleaned.prefix(12))
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
        /// A currently-live presentation has no finite duration and cannot be
        /// prepared; only native delivery is eligible. `was_live` replays are
        /// finite and are prepared like any on-demand source.
        var isIndefiniteLive: Bool {
            is_live == true || live_status == "is_live" || live_status == "post_live"
        }
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
        let format_id: String?
        let format_note: String?
        let url: String?
        let manifest_url: String?
        let vcodec: String?
        let acodec: String?
        let ext: String?
        let `protocol`: String?
        let has_drm: Bool?
        let width: Double?
        let height: Double?
        let fps: Double?
        let tbr: Double?
        let abr: Double?
        let audio_channels: Int?
        let language: String?
        let dynamic_range: String?
        let video_range: String?
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
