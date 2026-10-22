import Foundation

/// Account material that must not appear in process arguments or preferences.
/// Signed CDN query values are intentionally left in place: history already
/// persists those URLs verbatim.
enum MediaURLSecrets {
    private static let credentialQueries: Set<String> = ["username", "password"]
    private static let streamKinds: Set<String> = ["live", "movie", "series"]

    static func contains(_ url: URL) -> Bool {
        if url.user != nil || url.password != nil { return true }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        if parts.queryItems?.contains(where: { credentialQueries.contains($0.name.lowercased()) }) == true {
            return true
        }
        return credentialSpan(in: parts.percentEncodedPath) != nil
    }

    /// Removes account material and keeps a stable, playable-looking location.
    /// Query encoding of the remaining fields is preserved, including a literal plus.
    static func sanitized(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.user = nil
        parts.password = nil
        if let query = parts.percentEncodedQuery {
            let kept = query.split(separator: "&", omittingEmptySubsequences: false).filter { field in
                let name = field.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                return !credentialQueries.contains((name.removingPercentEncoding ?? name).lowercased())
            }
            parts.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        }
        if let span = credentialSpan(in: parts.percentEncodedPath) {
            var segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard segments.indices.contains(span.lowerBound) else { return parts.url ?? url }
            segments.removeSubrange(span)
            let path = segments.joined(separator: "/")
            parts.percentEncodedPath = path.isEmpty ? "/" : path
        }
        return parts.url ?? url
    }

    /// Username and password segments in an Xtream-style stream path, or in a
    /// three-segment `account/account/id` path whose last segment is a stream id.
    private static func credentialSpan(in percentEncodedPath: String) -> Range<Int>? {
        let segments = percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let decoded = segments.map { $0.removingPercentEncoding ?? $0 }
        if let kind = decoded.indices.first(where: { streamKinds.contains(decoded[$0].lowercased()) }),
           kind + 3 < decoded.count,
           !decoded[kind + 1].isEmpty, !decoded[kind + 2].isEmpty,
           isStreamID(decoded[kind + 3]) {
            return (kind + 1)..<(kind + 3)
        }
        let content = decoded.indices.filter { !decoded[$0].isEmpty }
        guard content.count == 3, isStreamID(decoded[content[2]]) else { return nil }
        return content[0]..<content[2]
    }

    private static func isStreamID(_ value: String) -> Bool {
        guard let dot = value.firstIndex(of: ".") else { return isDigits(value) }
        let identifier = value[..<dot]
        let ext = value[value.index(after: dot)...]
        guard isDigits(identifier), (1...12).contains(ext.utf8.count) else { return false }
        return ext.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }

    private static func isDigits(_ value: some StringProtocol) -> Bool {
        let bytes = Array(value.utf8)
        return (1...20).contains(bytes.count) && bytes.allSatisfy { (48...57).contains($0) }
    }
}
