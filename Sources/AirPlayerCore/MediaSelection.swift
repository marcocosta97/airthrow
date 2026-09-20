import Foundation

public enum MediaDelivery: Sendable {
    case hls, file, unknown
}

/// One complete presentation, including a paired audio track when preparation
/// is needed. Quality describes an available rendition, not observed playback.
public struct MediaCandidate: Sendable {
    public let source: ResolvedSource
    public let height: Double?
    public let bitrate: Double?
    public init(source: ResolvedSource, height: Double? = nil, bitrate: Double? = nil) {
        self.source = source
        self.height = height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.bitrate = bitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}

/// Source-independent policy. Adapters discover presentations; this is the
/// only place that ranks them. No URLs or provider names influence priority.
public enum MediaSelector {
    public static func select(_ candidates: [MediaCandidate]) throws -> ResolvedSource {
        guard let best = candidates.max(by: { left, right in
            if left.source.needsPreparation != right.source.needsPreparation {
                return left.source.needsPreparation
            }
            if left.height != right.height { return (left.height ?? 0) < (right.height ?? 0) }
            // At equal known quality, retain HLS adaptation and alternate media.
            if (left.source.delivery == .hls) != (right.source.delivery == .hls) {
                return right.source.delivery == .hls
            }
            return (left.bitrate ?? 0) < (right.bitrate ?? 0)
        }) else { throw ResolutionFailure.preparationRequired }
        return best.source
    }

    /// A native format failure may justify inspection/remuxing. Network, DRM,
    /// audio-only and already-prepared failures must not start another job.
    public static func remuxFallback(for source: ResolvedSource, reason: MediaFailureReason) -> ResolvedSource? {
        guard reason == .unreadableMedia, !source.needsPreparation, source.delivery != .hls else { return nil }
        return ResolvedSource(url: source.url, title: source.title, headers: source.headers,
                              audio: source.audio, needsPreparation: true, needsDelivery: source.needsDelivery,
                              delivery: source.delivery)
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
        let needsRemux = ["mkv", "webm"].contains(ext)
        return [MediaCandidate(source: ResolvedSource(
            url: url, title: url.lastPathComponent, needsPreparation: needsRemux,
            needsDelivery: true, delivery: .file))]
    }
}

enum DirectSourceAdapter {
    static func candidates(_ url: URL) -> [MediaCandidate] {
        // Unknown/extensionless URLs retain the native attempt. A URL alone
        // cannot tell us which other presentations a publisher might offer.
        let delivery: MediaDelivery = url.pathExtension.lowercased() == "m3u8" ? .hls : .unknown
        return [MediaCandidate(source: ResolvedSource(url: url, delivery: delivery))]
    }
}
