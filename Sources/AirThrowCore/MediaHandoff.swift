import Foundation

/// A user-triggered media handoff. Only the page URL crosses into the app;
/// this entry point cannot inject headers, credentials, commands or file paths.
public struct MediaHandoff: Sendable {
    public let sourceURL: String
    public let autoplay: Bool

    public init(url: URL) throws {
        let failure = AppFailure(.invalidRequest, "Choose an HTTP or HTTPS video link to send to AirThrow.")
        let raw = url.absoluteString
        guard raw.utf8.count <= 65_536, Self.validEscapes(raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "airthrow",
              let action = components.host?.lowercased(), ["open", "play"].contains(action),
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "url", let target = items[0].value,
              target.utf8.count <= 16_384, Self.validEscapes(target),
              !target.contains("\\"),
              !target.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
              }) else {
            throw failure
        }
        do { _ = try MediaInput.url(target) }
        catch { throw failure }
        sourceURL = target
        autoplay = action == "play"
    }

    /// Encode the complete source once, preserving signed queries and fragments.
    public static func url(for sourceURL: String, autoplay: Bool = true) throws -> URL {
        var components = URLComponents()
        components.scheme = "airthrow"
        components.host = autoplay ? "play" : "open"
        components.queryItems = [URLQueryItem(name: "url", value: sourceURL)]
        guard let url = components.url else {
            throw AppFailure(.invalidRequest, "Choose an HTTP or HTTPS video link to send to AirThrow.")
        }
        _ = try MediaHandoff(url: url)
        return url
    }

    private static func validEscapes(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        func hex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }
}
