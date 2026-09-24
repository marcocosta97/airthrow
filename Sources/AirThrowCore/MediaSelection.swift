import Foundation

public enum MediaDelivery: Sendable {
    case hls, file, unknown
}

/// How much re-encoding the user permits when choosing among presentations.
/// A processing-cost preference, not a quality score or receiver guarantee.
public enum ConversionPolicy: String, Codable, Sendable {
    case avoidVideo = "avoid_video", allowVideo = "allow_video"
}

/// One complete presentation, including a paired audio track when preparation
/// is needed. Quality describes an available rendition, not observed playback.
public struct MediaCandidate: Sendable {
    /// Stable per presentation across re-resolution. Never derived from a URL
    /// or request headers, so it is safe to expose in status and preferences.
    public let id: String
    public let source: ResolvedSource
    public let height: Double?
    public let bitrate: Double?
    /// Frame rate when the adapter knows it, used to tell same-height
    /// presentations (for example 720p30 and 720p60) apart in the chooser.
    public let frameRate: Double?
    /// Language and/or codec of the chosen audio track when the adapter knows it.
    public let audioDescription: String?
    /// A reason this presentation can never be used, regardless of policy.
    public let unavailableReason: String?

    public init(source: ResolvedSource, id: String = "", height: Double? = nil, bitrate: Double? = nil,
                frameRate: Double? = nil, audioDescription: String? = nil, unavailableReason: String? = nil) {
        let usableHeight = height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let usableBitrate = bitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.source = source
        self.height = usableHeight
        self.bitrate = usableBitrate
        self.frameRate = frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.audioDescription = audioDescription
        self.unavailableReason = unavailableReason
        self.id = id.isEmpty
            ? MediaCandidate.fallbackID(source: source, height: usableHeight, bitrate: usableBitrate,
                                        audioDescription: audioDescription)
            : id
    }

    /// Whether this candidate can be used under a policy. A stored reason is
    /// absolute; otherwise `.avoidVideo` refuses only video re-encoding. Audio
    /// conversion and remuxing stay available under both policies.
    public func unavailableReason(for policy: ConversionPolicy) -> String? {
        if let unavailableReason { return unavailableReason }
        if policy == .avoidVideo, source.playbackPath == .videoConversion {
            return "Video conversion is off. This source needs video conversion."
        }
        return nil
    }

    /// Deterministic, URL-free identity for adapters that do not supply a
    /// provider format identifier. It hashes a complete metadata signature and
    /// excludes the title, ordering and URL: a refreshed expiring URL, or a
    /// reordered format list, must keep the same identity so an explicit choice
    /// survives re-resolution.
    static func fallbackID(source: ResolvedSource, height: Double?, bitrate: Double?,
                           audioDescription: String?) -> String {
        let delivery: String
        switch source.delivery {
        case .hls: delivery = "hls"
        case .file: delivery = "file"
        case .unknown: delivery = "unknown"
        }
        let encoded = signature(["source", delivery, source.playbackPath.rawValue,
                         stableNumber(height), stableNumber(bitrate), audioDescription ?? "",
                         source.needsPreparation ? "prep" : "raw",
                         source.needsDelivery ? "deliver" : "local",
                         source.videoKnownPresent ? "video" : "novideo",
                         source.audio != nil ? "paired" : "single"])
        return "cand-" + stableHash(encoded)
    }

    /// Unambiguous, order-preserving encoding of signature components. Every
    /// component is length-prefixed, so a value containing a delimiter cannot
    /// forge a component boundary and collide with a different presentation.
    static func signature(_ parts: [String]) -> String {
        parts.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// Exact, locale-independent number formatting for identity signatures.
    /// Distinct finite values (for example 59.94 and 60 fps) never collapse.
    /// Non-finite values encode as empty rather than trapping.
    static func stableNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return value == 0 ? "0" : String(value)
    }

    /// Deterministic 64-bit FNV-1a. Used only for opaque identities; the hashed
    /// inputs never contain a media URL, and the output is not reversible.
    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Keep only ASCII letters, digits, dash and underscore; collapse runs.
    static func sanitizedIdentifier(_ value: String) -> String {
        let mapped = value.map { character -> Character in
            (character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_"))
                ? character : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(80))
    }
}

/// Source-independent policy. Adapters discover presentations; this is the
/// only place that ranks them. No URLs or provider names influence priority.
public enum MediaSelector {
    public static func select(_ candidates: [MediaCandidate], policy: ConversionPolicy = .avoidVideo,
                              sourceID: String? = nil, preferQuality: Bool = false) throws -> ResolvedSource {
        // An explicit choice must resolve to exactly one presentation, or fail.
        // It never silently downgrades, nor guesses between duplicate identities.
        if let sourceID {
            let matches = candidates.filter { $0.id == sourceID }
            guard matches.count == 1, let match = matches.first else {
                throw ResolutionFailure.failed
            }
            guard match.unavailableReason(for: policy) == nil else {
                throw ResolutionFailure.preparationRequired
            }
            return match.source.withConversionPolicy(policy)
        }
        guard let best = candidates
            .filter({ $0.unavailableReason(for: policy) == nil })
            .max(by: { rankedBelow($0, $1, preferQuality: preferQuality) }) else { throw ResolutionFailure.preparationRequired }
        return best.source.withConversionPolicy(policy)
    }

    /// Lower processing tiers win first; quality, HLS adaptation and bitrate
    /// break ties within a tier. Returns true when `left` ranks below `right`.
    /// With `preferQuality`, known resolution and frame rate win before the
    /// processing tier, so a higher-quality remux beats a lower-quality direct
    /// source. Unavailable (policy-excluded) presentations are filtered first.
    static func rankedBelow(_ left: MediaCandidate, _ right: MediaCandidate,
                            preferQuality: Bool = false) -> Bool {
        if preferQuality {
            if left.height != right.height { return (left.height ?? 0) < (right.height ?? 0) }
            if left.frameRate != right.frameRate { return (left.frameRate ?? 0) < (right.frameRate ?? 0) }
        }
        let leftTier = left.source.playbackPath.tier
        let rightTier = right.source.playbackPath.tier
        if leftTier != rightTier { return leftTier > rightTier }
        if left.height != right.height { return (left.height ?? 0) < (right.height ?? 0) }
        // At equal known quality, retain HLS adaptation and alternate media.
        if (left.source.delivery == .hls) != (right.source.delivery == .hls) {
            return right.source.delivery == .hls
        }
        return (left.bitrate ?? 0) < (right.bitrate ?? 0)
    }

    /// A native format failure may justify inspection/remuxing. Network, DRM,
    /// audio-only and already-prepared failures must not start another job.
    public static func remuxFallback(for source: ResolvedSource, reason: MediaFailureReason) -> ResolvedSource? {
        guard reason == .unreadableMedia, !source.needsPreparation, source.delivery != .hls else { return nil }
        return ResolvedSource(url: source.url, title: source.title, headers: source.headers,
                              audio: source.audio, needsPreparation: true, needsDelivery: source.needsDelivery,
                              delivery: source.delivery, videoKnownPresent: source.videoKnownPresent,
                              isLive: source.isLive, conversionPolicy: source.conversionPolicy)
    }

    /// When a native presentation fails and the source must be remuxed, prefer
    /// the best available remux presentation over remuxing the failed native
    /// URL. A fallback should still yield the highest quality the extractor
    /// offered rather than the low-resolution direct stream.
    public static func bestRemuxFallback(from candidates: [MediaCandidate],
                                         policy: ConversionPolicy) -> ResolvedSource? {
        guard let best = candidates
            .filter({ $0.source.playbackPath == .remux && $0.unavailableReason(for: policy) == nil })
            .max(by: { rankedBelow($0, $1, preferQuality: true) }) else { return nil }
        return best.source.withConversionPolicy(policy)
    }
}

enum LocalSourceAdapter {
    static func candidates(_ input: URL) throws -> [MediaCandidate] {
        let url = try MediaInput.localFile(input)
        let ext = url.pathExtension.lowercased()
        guard ext != "m3u8" else { throw ResolutionFailure.preparationRequired }
        // MP4/MOV and unknown containers get one native attempt through the LAN
        // server. Containers AVPlayer normally cannot read go straight to the
        // existing stream-copy inspection/remux path.
        let needsRemux = ["mkv", "webm", "mpg", "mpeg", "vob"].contains(ext)
        return [MediaCandidate(source: ResolvedSource(
            url: url, title: url.lastPathComponent, needsPreparation: needsRemux,
            needsDelivery: true, delivery: .file))]
    }
}

enum DirectSourceAdapter {
    static func candidates(_ url: URL) -> [MediaCandidate] {
        // Like local Matroska/WebM, these containers need inspection and a
        // compatible delivery format before handing a URL to AVPlayer. Keep
        // the native attempt for unknown/extensionless URLs: an extension is
        // only a routing hint, not proof of the contained codecs.
        let ext = url.pathExtension.lowercased()
        let needsPreparation = ["mkv", "webm", "mpg", "mpeg", "vob"].contains(ext)
        let delivery: MediaDelivery = ext == "m3u8" ? .hls : (needsPreparation ? .file : .unknown)
        return [MediaCandidate(source: ResolvedSource(url: url, needsPreparation: needsPreparation,
                                                       delivery: delivery))]
    }
}
