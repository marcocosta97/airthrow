import Foundation
import AVFoundation
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// Expose only fixed messages/codes. NSError descriptions and userInfo can contain signed URLs.
enum MediaDiagnostics {
    static func hlsVariants(_ variants: [AVAssetVariant]) -> [HLSVariantSummary] {
        func positive(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        func dimension(_ value: CGFloat?) -> Int? {
            guard let value, value.isFinite, (1...16384).contains(value) else { return nil }
            return Int(value.rounded())
        }
        return variants.prefix(128).map { variant in
            let video = variant.videoAttributes
            return HLSVariantSummary(width: dimension(video?.presentationSize.width),
                height: dimension(video?.presentationSize.height), frameRate: positive(video?.nominalFrameRate),
                peakBitrate: positive(variant.peakBitRate), averageBitrate: positive(variant.averageBitRate),
                videoCodecs: video?.codecTypes ?? [])
        }
    }

    static func numericErrors(for error: Error?) -> [MediaErrorCode] {
        var current = error as NSError?
        var result: [MediaErrorCode] = []
        for _ in 0..<8 {
            guard let error = current else { break }
            let domain: MediaErrorCode.Domain
            switch error.domain {
            case AVFoundationErrorDomain: domain = .avFoundation
            case NSURLErrorDomain: domain = .urlLoading
            case "CoreMediaErrorDomain": domain = .coreMedia
            case NSOSStatusErrorDomain: domain = .osStatus
            default: domain = .other
            }
            result.append(MediaErrorCode(domain: domain, code: error.code))
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    static func reason(for error: Error?, fallback: MediaFailureReason) -> MediaFailureReason {
        var current = error as NSError?
        var inferred: MediaFailureReason?
        // Bound traversal even if a provider supplies a malformed underlying-error chain.
        for _ in 0..<8 {
            guard let cause = current else { break }
            if cause.domain == NSURLErrorDomain {
                switch URLError.Code(rawValue: cause.code) {
                case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                     .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
                     .serverCertificateHasBadDate, .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                    return .network
                case .userAuthenticationRequired, .noPermissionsToReadFile, .fileDoesNotExist,
                     .resourceUnavailable:
                    return .sourceUnavailable
                default: break
                }
            } else if cause.domain == AVFoundationErrorDomain {
                switch AVError.Code(rawValue: cause.code) {
                case .fileFormatNotRecognized, .fileFailedToParse, .decoderNotFound,
                     .decodeFailed, .invalidSourceMedia, .undecodableMediaData, .formatUnsupported:
                    inferred = inferred ?? .unreadableMedia
                case .contentIsProtected:
                    inferred = inferred ?? .protectedMedia
                case .contentIsNotAuthorized, .contentIsUnavailable:
                    inferred = inferred ?? .sourceUnavailable
                case .externalPlaybackNotSupportedForAsset, .noCompatibleAlternatesForExternalDisplay:
                    inferred = inferred ?? .externalPlaybackUnsupported
                case .airPlayControllerRequiresInternet, .airPlayReceiverRequiresInternet:
                    inferred = inferred ?? .network
                default: break
                }
            }
            current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return inferred ?? fallback
    }
}
