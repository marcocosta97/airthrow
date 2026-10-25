import Foundation

public struct XtreamAccount: Sendable, Equatable {
    public let source: URL
    public let server: URL
    public let username: String
    public let password: String
    public let format: XtreamPlaylist.StreamFormat

    public init(source: URL) throws {
        guard let parts = URLComponents(url: source, resolvingAgainstBaseURL: false),
              ["get.php", "player_api.php"].contains(source.lastPathComponent),
              let items = parts.queryItems,
              items.filter({ $0.name == "username" }).count == 1,
              items.filter({ $0.name == "password" }).count == 1,
              let user = items.first(where: { $0.name == "username" })?.value,
              let pass = items.first(where: { $0.name == "password" })?.value else {
            throw XtreamFailure.invalidAccount
        }
        var base = parts
        base.query = nil; base.fragment = nil
        base.percentEncodedPath = source.deletingLastPathComponent().path(percentEncoded: true)
        guard let server = base.url else { throw XtreamFailure.invalidAccount }
        let format = items.first(where: { $0.name == "output" })?.value == "ts"
            ? XtreamPlaylist.StreamFormat.transportStream : .hls
        self.source = try XtreamPlaylist.url(server: server.absoluteString, username: user, password: pass, format: format)
        self.server = server; self.username = user; self.password = pass; self.format = format
    }

    public func apiURL(action: String? = nil, parameters: [URLQueryItem] = []) throws -> URL {
        var parts = URLComponents(url: source, resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath = server.appendingPathComponent("player_api.php").path(percentEncoded: true)
        parts.queryItems = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
            + (action.map { [URLQueryItem(name: "action", value: $0)] } ?? []) + parameters
        // URLComponents leaves literal '+' in queries, but PHP decodes it as a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw XtreamFailure.invalidAccount }
        return url
    }

    public func streamURL(kind: XtreamSection, id: String, extension ext: String) throws -> URL {
        guard XtreamParsing.validID(id), !ext.isEmpty,
              ext.utf8.count <= 12, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            throw XtreamFailure.invalidResponse
        }
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let segments = [kind.streamPath, username, password, id + "." + ext]
        let path = segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        parts.percentEncodedPath = server.path(percentEncoded: true).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.percentEncodedPath = "/" + ([parts.percentEncodedPath, path].filter { !$0.isEmpty }.joined(separator: "/"))
        guard let url = parts.url else { throw XtreamFailure.invalidResponse }
        return try MediaInput.url(url.absoluteString)
    }
}

public enum XtreamSection: String, CaseIterable, Sendable { case live = "Live", movies = "Films", series = "Series" }

extension XtreamSection {
    var categoriesAction: String {
        switch self { case .live: "get_live_categories"; case .movies: "get_vod_categories"; case .series: "get_series_categories" }
    }
    var listingAction: String {
        switch self { case .live: "get_live_streams"; case .movies: "get_vod_streams"; case .series: "get_series" }
    }
    var listingIDKey: String { self == .series ? "series_id" : "stream_id" }
    var streamPath: String {
        switch self { case .live: "live"; case .movies: "movie"; case .series: "series" }
    }
}
public struct XtreamAccountInfo: Sendable, Equatable {
    public let status: String
    public let expires: Date?
    public let activeConnections: Int?
    public let maximumConnections: Int?
    public let allowedFormats: [String]
    public let timeZoneIdentifier: String?
}
public struct XtreamCategory: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let name: String
}
public struct XtreamItem: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let categoryID: String?
    public let container: String
    public let summary: String?
    public let year: String?
    public let rating: String?
}
public struct XtreamListing: Sendable, Codable {
    public let items: [XtreamItem]
    public let skipped: Int
    public let truncated: Bool
    public init(items: [XtreamItem], skipped: Int, truncated: Bool) {
        self.items = items; self.skipped = skipped; self.truncated = truncated
    }
    public static let empty = XtreamListing(items: [], skipped: 0, truncated: false)
    /// Answers a category request from an all-titles listing.
    public func filtered(toCategory categoryID: String) -> XtreamListing {
        XtreamListing(items: items.filter { $0.categoryID == categoryID }, skipped: 0, truncated: false)
    }
}
public struct XtreamEpisode: Identifiable, Sendable, Equatable {
    public let id: String
    public let season: Int
    public let number: Int
    public let title: String
    public let container: String
    public let summary: String?
    public let duration: String?
}
public struct XtreamDetails: Sendable {
    public let summary: String?
    public let genre: String?
    public let cast: String?
    public let director: String?
    public let duration: String?
    public let rating: String?
    public let year: String?
    public let episodes: [XtreamEpisode]
    public let skippedEpisodes: Int
}
public struct XtreamProgramme: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String?
    public let start: Date
    public let end: Date
}
public enum XtreamFailure: Error, Sendable {
    case catalogTooLarge, invalidAccount, rejectedAccount, inactiveAccount, invalidResponse, tooLarge, unsupportedLiveFormat, httpStatus(Int)
    public var message: String {
        switch self {
        case .invalidAccount: "Check the Xtream server address, username and password."
        case .rejectedAccount: "The Xtream server rejected the username or password."
        case .inactiveAccount: "This Xtream account is inactive or expired. Check it with your provider."
        case .invalidResponse: "The server returned an invalid Xtream API response. Try again or import its M3U playlist."
        case .catalogTooLarge: "This catalog is too large to load at once. Select a category to load a smaller catalog."
        case .tooLarge: "This Xtream response exceeds the 64 MiB limit. Select a category to load a smaller catalog."
        case .unsupportedLiveFormat: "This account does not allow HLS or MPEG-TS live streams. Check its playback formats with your provider."
        case .httpStatus(let status): "The Xtream server returned HTTP \(status). Try again or check the server address."
        }
    }
    public static func message(for error: Error) -> String {
        (error as? XtreamFailure)?.message ?? IPTVCatalogFailure.message(for: error)
    }
}

enum XtreamParsing {
    static func text(_ value: Any?) -> String? {
        let raw: String?
        if let value = value as? String { raw = value }
        else if let value = value as? NSNumber { raw = value.stringValue }
        else { raw = nil }
        guard let raw else { return nil }
        let clean = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }.prefix(4096))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
    static func id(_ value: Any?) -> String? {
        guard let value = text(value), validID(value) else { return nil }; return value
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
    static func integer(_ value: Any?) -> Int? { text(value).flatMap(Int.init) }
    static func rows(_ value: Any) throws -> [[String: Any]] {
        if let rows = value as? [Any] { return rows.map { $0 as? [String: Any] ?? [:] } }
        if let dictionary = value as? [String: Any], dictionary.isEmpty { return [] }
        throw XtreamFailure.invalidResponse
    }
}
