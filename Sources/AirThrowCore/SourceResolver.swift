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

/// Privacy-safe metadata for an alternate audio rendition in an HLS master.
/// The ID is derived only from its language and bounded display name.
public struct HLSAudioOption: Sendable, Equatable {
    public let id: String
    public let language: String?
    public let name: String
    public let isOriginal: Bool
    public let isDefault: Bool
    public init(language: String?, name: String, isOriginal: Bool, isDefault: Bool) {
        self.language = language
        self.name = name
        self.isOriginal = isOriginal
        self.isDefault = isDefault
        self.id = "hls-audio-" + MediaCandidate.stableHash(MediaCandidate.signature([language ?? "", name]))
    }
}

public struct ResolvedSource: Sendable {
    public let url: URL
    public let title: String?
    // Keep request metadata in memory. Never put URLs, headers, or helper output into status/logs.
    public let headers: [String: String]
    public let audio: MediaTrack?
    public let hlsAudioOptions: [HLSAudioOption]
    public let needsPreparation: Bool
    /// The source must be exposed through AirThrow's LAN server before AVPlayer
    /// can hand it to a receiver. This is independent of whether tracks are remuxed.
    public let needsDelivery: Bool
    public let delivery: MediaDelivery
    /// Positive video evidence from an inspected presentation, not its URL or extension.
    public let videoKnownPresent: Bool
    /// The source is an indefinite presentation; preparation must use a rolling playlist.
    public let isLive: Bool
    /// The conversion preference in force when this plan was chosen.
    public let conversionPolicy: ConversionPolicy
    public let enhancement: VideoEnhancement
    /// Per-load preparation hint, independent of presentation identity. Cached
    /// preparation warms this position without encoding all preceding chunks.
    public var preparationPosition: Double? = nil
    /// A concrete processing tier chosen by the selector. Nil means the tier is
    /// derived from `needsPreparation`; set it to request audio/video conversion.
    public let plannedPath: PlaybackPath?
    public var playbackPath: PlaybackPath { plannedPath ?? (needsPreparation ? .remux : .direct) }
    public var needsPreparationPipeline: Bool { needsPreparation || needsDelivery }
    public init(url: URL, title: String? = nil, headers: [String: String] = [:], audio: MediaTrack? = nil,
                hlsAudioOptions: [HLSAudioOption] = [],
                needsPreparation: Bool = false, needsDelivery: Bool = false, delivery: MediaDelivery = .unknown,
                videoKnownPresent: Bool = false, isLive: Bool = false,
                conversionPolicy: ConversionPolicy = .avoidVideo,
                plannedPath: PlaybackPath? = nil,
                enhancement: VideoEnhancement = .original) {
        self.url = url; self.title = title; self.headers = headers; self.audio = audio
        self.hlsAudioOptions = hlsAudioOptions
        self.needsPreparation = needsPreparation || audio != nil || (plannedPath.map { $0 != .direct } ?? false)
        self.needsDelivery = needsDelivery
        self.delivery = delivery
        self.videoKnownPresent = videoKnownPresent
        self.isLive = isLive
        self.conversionPolicy = conversionPolicy
        self.enhancement = enhancement
        self.plannedPath = plannedPath
    }

    /// Copy the same presentation with a different conversion preference. The
    /// planned path and every delivery flag are preserved.
    public func withConversionPolicy(_ policy: ConversionPolicy) -> ResolvedSource {
        var result = ResolvedSource(url: url, title: title, headers: headers, audio: audio,
                       hlsAudioOptions: hlsAudioOptions,
                       needsPreparation: needsPreparation, needsDelivery: needsDelivery,
                       delivery: delivery, videoKnownPresent: videoKnownPresent, isLive: isLive,
                       conversionPolicy: policy, plannedPath: plannedPath, enhancement: enhancement)
        result.preparationPosition = preparationPosition
        return result
    }

    public func withEnhancement(_ choice: VideoEnhancement) -> ResolvedSource {
        var result = ResolvedSource(url: url, title: title, headers: headers, audio: audio,
                       hlsAudioOptions: hlsAudioOptions,
                       needsPreparation: needsPreparation || choice != .original,
                       needsDelivery: needsDelivery, delivery: delivery,
                       videoKnownPresent: videoKnownPresent, isLive: isLive,
                       conversionPolicy: conversionPolicy,
                       plannedPath: choice == .original ? plannedPath : .videoConversion,
                       enhancement: choice)
        result.preparationPosition = preparationPosition
        return result
    }

    public func withTransportRemux(isLive: Bool) -> ResolvedSource {
        var result = ResolvedSource(url: url, title: title, headers: headers, audio: audio, hlsAudioOptions: hlsAudioOptions,
            needsPreparation: true, needsDelivery: needsDelivery, delivery: delivery, videoKnownPresent: true, isLive: isLive,
            conversionPolicy: conversionPolicy, plannedPath: .remux, enhancement: enhancement)
        result.preparationPosition = preparationPosition
        return result
    }

    /// A catalog's Live section identifies an indefinite presentation even
    /// before native inspection exposes the moving seek window.
    public func withLivePresentation() -> ResolvedSource {
        var result = ResolvedSource(url: url, title: title, headers: headers, audio: audio,
            hlsAudioOptions: hlsAudioOptions, needsPreparation: needsPreparation,
            needsDelivery: needsDelivery, delivery: delivery, videoKnownPresent: videoKnownPresent,
            isLive: true, conversionPolicy: conversionPolicy, plannedPath: plannedPath, enhancement: enhancement)
        result.preparationPosition = preparationPosition
        return result
    }

    public func withPreparationInput(_ url: URL) -> ResolvedSource {
        var result = ResolvedSource(url: url, title: title, headers: headers, audio: audio, hlsAudioOptions: hlsAudioOptions,
            needsPreparation: needsPreparation, needsDelivery: needsDelivery, delivery: delivery,
            videoKnownPresent: videoKnownPresent, isLive: isLive, conversionPolicy: conversionPolicy,
            plannedPath: plannedPath, enhancement: enhancement)
        result.preparationPosition = preparationPosition
        return result
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
    private let registry: Result<SourceRegistry, SourceRegistryError>
    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                cookies: YouTubeCookies? = nil, sessions: WebsiteSessions? = nil,
                registry: SourceRegistry? = nil) {
        let youtubeCookies = cookies ?? sessions.map { $0.source(for: .youtube) }
        youtube = YouTubeSourceAdapter(environment: environment, cookies: youtubeCookies)
        if let registry { self.registry = .success(registry) }
        else {
            do { self.registry = .success(try SourceRegistry.standard(environment: environment, cookies: youtubeCookies,
                                                                      sessions: sessions)) }
            catch { self.registry = .failure((error as? SourceRegistryError) ?? .invalidAdapter) }
        }
    }

    public func candidates(for url: URL) async throws -> [MediaCandidate] {
        try Task.checkCancellation()
        if url.isFileURL { return try LocalSourceAdapter.candidates(url) }
        let sources: SourceRegistry
        do { sources = try registry.get() }
        catch {
            // Invalid custom adapter metadata must not prevent native file playback.
            if Self.isDirectMediaHint(url) { return DirectSourceAdapter.candidates(url) }
            throw ResolutionFailure.failed
        }
        if let adapter = sources.adapter(for: url) { return try await adapter.candidates(for: url) }
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
    public static func needsResolution(_ url: URL) -> Bool {
        SourceResolver().needsResolution(for: url)
    }
    /// Use this instance method when supplying a custom registry so loading
    /// and retry state follow the same dispatch as candidate discovery.
    public func needsResolution(for url: URL) -> Bool {
        guard !url.isFileURL else { return false }
        if let registry = try? registry.get() { return registry.adapter(for: url) != nil }
        return Self.isWebsite(url) || !Self.isDirectMediaHint(url)
    }
    public static func isDirectMediaHint(_ url: URL) -> Bool {
        let extensions: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mkv", "webm", "mpd",
            "ts", "m4s", "m2ts", "mpg", "mpeg", "vob", "flv", "avi", "m4a", "mp3",
            "aac", "flac", "ogg", "wav"]
        return extensions.contains(url.pathExtension.lowercased())
    }
    public static func videoPage(_ url: URL) throws -> URL { try YouTubeSourceAdapter.videoPage(url) }
    public static func playlistPage(_ url: URL) -> URL? { YouTubeSourceAdapter.playlistPage(url) }
}

/// Inspect ambiguous links without creating another player or changing the route.
/// A deadline cancels AVFoundation loading as well as the inspection task.
enum NativeSourceProbe {
    static func hasPlayableVideo(at url: URL, timeout: Duration = .seconds(3)) async throws -> Bool {
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            let result = try await withThrowingTaskGroup(of: Bool.self) { group in
                defer { group.cancelAll(); asset.cancelLoading() }
                group.addTask {
                    do {
                        guard try await asset.load(.isPlayable),
                              try await !asset.load(.hasProtectedContent) else { return false }
                        let tracks = try await asset.loadTracks(withMediaType: .video)
                        if !tracks.isEmpty { return true }
                        // HLS may omit AVAsset tracks even though its presentation has video.
                        let video = await HLSVideoEvidence.hasVideo(at: url)
                        try Task.checkCancellation()
                        return video
                    } catch {
                        try Task.checkCancellation()
                        return false
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    asset.cancelLoading()
                    return false
                }
                return try await group.next() ?? false
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            asset.cancelLoading()
        }
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

    static func audioOptions(_ data: Data, at base: URL) -> [HLSAudioOption] {
        guard quality(data, at: base) != nil,
              let text = String(data: data, encoding: .utf8) else { return [] }
        var options: [HLSAudioOption] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-MEDIA:") {
            guard options.count < 16,
                  let attrs = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count))),
                  attrs["TYPE"] == "AUDIO", attrs["GROUP-ID"]?.isEmpty == false,
                  let uri = attrs["URI"], validURI(uri, at: base),
                  let name = safeAudioLabel(attrs["NAME"], limit: 80) else { continue }
            let language = safeAudioLanguage(attrs["LANGUAGE"])
            let key = MediaCandidate.signature([language ?? "", name])
            guard seen.insert(key).inserted else { continue }
            options.append(HLSAudioOption(language: language, name: name,
                                          isOriginal: name.range(of: "original", options: .caseInsensitive) != nil,
                                          isDefault: attrs["DEFAULT"] == "YES"))
        }
        return options
    }

    private static func safeAudioLabel(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= limit,
              !value.contains("://"), !value.contains("/"), !value.contains("?"), !value.contains("@"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func safeAudioLanguage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.count <= 32,
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return raw
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
    /// Supplemental inspection never exports manifest text, source addresses,
    /// metadata tags or helper errors. The helper receives only a local sample.
    public static func inspectTransportVideo(at url: URL) async -> StreamingVideoCharacteristics? {
        let work = Task { await transportCharacteristics(at: url, depth: 0) }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { work.cancel() }
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    private static func transportCharacteristics(at url: URL, depth: Int, isLive: Bool? = nil) async -> StreamingVideoCharacteristics? {
        guard depth <= 2, !Task.isCancelled else { return nil }
        do {
            guard let fetched = try await sampledBytes(at: url) else { return nil }
            if !isTransport(fetched.data) {
                guard let reference = reference(in: fetched.data, at: fetched.base) else { return nil }
                return await transportCharacteristics(at: reference.url, depth: depth + 1,
                    isLive: livePresentation(in: fetched.data) ?? isLive)
            }
            let sample = fetched.data
            guard let executable = HelperExecutables(environment: ProcessInfo.processInfo.environment)
                    .executable("ffprobe", override: "AIRTHROW_FFPROBE") else { return nil }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let local = directory.appendingPathComponent("sample.ts")
            try sample.write(to: local, options: .atomic)
            let output = try await HelperProcess.run(executable: executable, arguments: [
                "-v", "error", "-protocol_whitelist", "file", "-f", "mpegts", "-select_streams", "v:0",
                "-show_entries", "stream=codec_name,width,height,pix_fmt,color_transfer,profile,level", "-of", "json", local.path
            ], timeout: .seconds(4), outputLimit: 16 * 1024)
            return decodeTransportCharacteristics(output, delivery: depth == 0 ? .transportStream : .hls, isLive: isLive)
        } catch { return nil }
    }

    static func livePresentation(in data: Data) -> Bool? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U", lines.contains(where: { $0.hasPrefix("#EXT-X-TARGETDURATION:") }) else { return nil }
        return !lines.contains("#EXT-X-ENDLIST") && !lines.contains("#EXT-X-PLAYLIST-TYPE:VOD")
    }

    static func decodeTransportCharacteristics(_ data: Data, delivery: StreamingVideoCharacteristics.Delivery? = nil,
                                               isLive: Bool? = nil) -> StreamingVideoCharacteristics? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]], let video = streams.first,
              let name = video["codec_name"] as? String,
              let codec = StreamingVideoCharacteristics.Codec(rawValue: name) else { return nil }
        func dimension(_ key: String) -> Int? {
            guard let value = video[key] as? Int, (1...16384).contains(value) else { return nil }
            return value
        }
        let depth: Int? = switch video["pix_fmt"] as? String {
        case "yuv420p", "yuv422p", "yuv444p": 8
        case "yuv420p10le", "yuv422p10le", "yuv444p10le": 10
        case "yuv420p12le", "yuv422p12le", "yuv444p12le": 12
        default: nil
        }
        let transfer = (video["color_transfer"] as? String).flatMap(StreamingVideoCharacteristics.Transfer.init(rawValue:))
        let chroma: StreamingVideoCharacteristics.Chroma? = switch video["pix_fmt"] as? String {
        case "yuv420p", "yuv420p10le", "yuv420p12le": .yuv420
        case "yuv422p", "yuv422p10le", "yuv422p12le": .yuv422
        case "yuv444p", "yuv444p10le", "yuv444p12le": .yuv444
        default: nil
        }
        let profile: StreamingVideoCharacteristics.Profile? = switch (codec, video["profile"] as? String) {
        case (.hevc, "Main"): .main
        case (.hevc, "Main 10"): .main10
        case (.hevc, "Main Still Picture"): .mainStillPicture
        default: nil
        }
        let level = (video["level"] as? Int).flatMap { (1...255).contains($0) ? $0 : nil }
        return StreamingVideoCharacteristics(codec: codec, width: dimension("width"), height: dimension("height"),
                                             bitDepth: depth, transfer: transfer, delivery: delivery,
                                             chroma: chroma, profile: profile, level: level, isLive: isLive)
    }

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
            if await videoTracks(at: reference.url) { return true }
            // Some live origins ignore byte ranges: AVFoundation rejects their
            // standalone TS URL even though HLS playback works. Inspect a small
            // local TS sample instead, without changing the playback URL/path.
            return try await sampledTransportVideo(at: reference.url)
        } catch { return false }
    }

    private static func videoTracks(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let timeout = Task {
            try await Task.sleep(for: .seconds(6))
            asset.cancelLoading()
        }
        defer { timeout.cancel(); asset.cancelLoading() }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await !asset.loadTracks(withMediaType: .video).isEmpty
            } onCancel: { asset.cancelLoading() }
        } catch { return false }
    }

    private static func sampledTransportVideo(at url: URL) async throws -> Bool {
        guard let sample = try await transportSample(at: url) else { return false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("sample.ts")
        try sample.write(to: local)
        return await videoTracks(at: local)
    }

    private static func transportSample(at url: URL) async throws -> Data? {
        guard let sample = try await sampledBytes(at: url)?.data, isTransport(sample) else { return nil }
        return sample
    }

    private static func isTransport(_ sample: Data) -> Bool {
        sample.count >= 3 * 188 && sample[0] == 0x47 && sample[188] == 0x47 && sample[376] == 0x47
    }

    private static func sampledBytes(at url: URL) async throws -> (data: Data, base: URL)? {
        try Task.checkCancellation()
        let maximumBytes = 256 * 1024
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(maximumBytes - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
              http.statusCode != 206 || http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-") == true else {
            return nil
        }
        var sample = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            sample.append(byte)
            if sample.count == maximumBytes { break }
        }
        return (sample, response.url ?? url)
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
