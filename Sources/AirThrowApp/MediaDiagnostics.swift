import Foundation
import AVFoundation
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// Expose only fixed messages/codes. NSError descriptions and userInfo can contain signed URLs.
enum MediaDiagnostics {
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
