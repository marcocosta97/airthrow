import Foundation

/// Builds an M3U catalog download from Xtream server details.
public enum XtreamPlaylist {
    public enum StreamFormat: String, CaseIterable, Sendable {
        case hls = "m3u8", transportStream = "ts"
    }

    public static func url(server: String, username: String, password: String,
                           format: StreamFormat = .hls) throws -> URL {
        let address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let qualified = address.contains("://") ? address : "https://" + address
        guard !address.isEmpty,
              let serverURL = try? MediaInput.url(qualified),
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              !serverURL.lastPathComponent.lowercased().hasSuffix(".php") else {
            throw AppFailure(.invalidRequest, "Enter the server address, including its port if needed, without a playlist URL or query parameters.")
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty,
              [username, password].allSatisfy({ value in
                  value.utf8.count <= 4096 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
              }) else {
            throw AppFailure(.invalidRequest, "Enter a username and password without line breaks.")
        }
        // Encode '+' as well as query delimiters: providers commonly decode
        // query values as application/x-www-form-urlencoded.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let user = username.addingPercentEncoding(withAllowedCharacters: unreserved),
              let pass = password.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw AppFailure(.invalidRequest, "Check the username and password, then try again.")
        }
        components.percentEncodedPath = serverURL.appendingPathComponent("get.php").path(percentEncoded: true)
        components.percentEncodedQuery = "username=\(user)&password=\(pass)&type=m3u_plus&output=\(format.rawValue)"
        guard let url = components.url else { throw AppFailure(.invalidRequest, "Check the server address, then try again.") }
        return try MediaInput.url(url.absoluteString)
    }
}

public struct IPTVChannel: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let number: Int
    public let name: String
    public let category: String?
    public let url: URL
}

public struct IPTVCatalog: Sendable, Equatable {
    public let id = UUID()
    public let title: String
    public let channels: [IPTVChannel]
    public let skippedEntries: Int
    public let truncated: Bool
    public var categories: [String] {
        Array(Set(channels.compactMap(\.category))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public func channels(category: String? = nil, search: String = "") -> [IPTVChannel] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        return channels.filter { channel in
            (category == nil || (category == "" ? channel.category == nil : channel.category == category))
                && terms.allSatisfy { term in
                    channel.name.localizedStandardContains(term) || (channel.category?.localizedStandardContains(term) ?? false)
                }
        }
    }
}

public enum IPTVCatalogFailure: Error, Sendable {
    case tooLarge, invalid, empty, hlsPlaylist, accessRequired, unavailable, timedOut, connectionBlocked
    case httpStatus(Int)
    public var message: String {
        switch self {
        case .tooLarge: "This playlist exceeds the 8 MiB import limit. Choose a smaller playlist."
        case .invalid: "Could not read this M3U playlist. Choose an M3U file or a direct playlist URL."
        case .empty: "This playlist has no supported channels. Use HTTP or HTTPS streams without embedded credentials or custom request headers."
        case .hlsPlaylist: "This is an HLS video playlist, not a channel catalog. Load its URL in the video source field."
        case .accessRequired: "The playlist server requires access. Use a playlist file or an accessible playlist URL."
        case .unavailable: "Could not import the playlist. Check the file or connection, then try again."
        case .timedOut: "The playlist server took too long to respond. Try again; the server may be waking up."
        case .connectionBlocked: "macOS blocked the playlist connection. Use HTTPS or reopen the latest AirThrow build, then try again."
        case .httpStatus(let status): "The playlist server returned HTTP \(status). Check the address or try again."
        }
    }

    public static func message(for error: Error) -> String {
        if let failure = error as? IPTVCatalogFailure { return failure.message }
        let failure = error as NSError
        if failure.domain == NSURLErrorDomain {
            if failure.code == URLError.timedOut.rawValue { return timedOut.message }
            if failure.code == URLError.appTransportSecurityRequiresSecureConnection.rawValue { return connectionBlocked.message }
        }
        return unavailable.message
    }
}

/// M3U channel catalogs are distinct from HLS stream manifests and playback queues.
public enum IPTVPlaylist {
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumChannels = 10_000

    /// Detect explicit catalog intent without changing the original request URL.
    public static func isCatalogSource(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "m3u" || (url.isFileURL && ext == "m3u8") { return true }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let types = items.filter { $0.name == "type" }
        guard types.count == 1, let type = types.first?.value else { return false }
        return type == "m3u" || type == "m3u_plus"
    }

    public static func parse(_ data: Data, baseURL: URL? = nil, title: String = "Channels") throws -> IPTVCatalog {
        guard data.count <= maximumBytes else { throw IPTVCatalogFailure.tooLarge }
        guard var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252) else { throw IPTVCatalogFailure.invalid }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let lines = text.components(separatedBy: .newlines)
        let first = lines.lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard first.hasPrefix("#EXTM3U") || first.hasPrefix("http://") || first.hasPrefix("https://") else {
            throw IPTVCatalogFailure.invalid
        }
        guard !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#EXT-X-") }) else {
            throw IPTVCatalogFailure.hlsPlaylist
        }
        var name: String?, category: String?, inheritedCategory: String?
        var unsupported = false
        var catalogTitle = label(title) ?? "Channels"
        var channels: [IPTVChannel] = []
        var skipped = 0, truncated = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTINF:") {
                if name != nil { skipped += 1 }
                name = ""; category = nil; unsupported = false
                guard line.utf8.count <= 16_384 else { unsupported = true; continue }
                var quoted = false
                let comma = line.indices.first { index in
                    if line[index] == "\"" { quoted.toggle() }
                    return line[index] == "," && !quoted
                }
                guard let comma, !quoted else { unsupported = true; continue }
                let attributes = String(line[..<comma])
                name = label(String(line[line.index(after: comma)...])) ?? attribute("tvg-name", in: attributes) ?? ""
                category = attribute("group-title", in: attributes)
            } else if line.hasPrefix("#EXTGRP:") {
                inheritedCategory = label(String(line.dropFirst(8)))
            } else if line.hasPrefix("#PLAYLIST:") {
                catalogTitle = label(String(line.dropFirst(10))) ?? catalogTitle
            } else if line.hasPrefix("#EXTHTTP:") || line.hasPrefix("#KODIPROP:")
                || line.lowercased().hasPrefix("#extvlcopt:http-") || line.lowercased().hasPrefix("#extvlcopt:input-slave=") {
                unsupported = true
            } else if !line.hasPrefix("#") {
                defer { name = nil; category = nil; unsupported = false }
                guard !unsupported, line.utf8.count <= 16_384, !line.contains("|"),
                      !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      let resolved = URL(string: line, relativeTo: baseURL)?.absoluteURL,
                      let url = try? MediaInput.url(resolved.absoluteString) else { skipped += 1; continue }
                guard channels.count < maximumChannels else { truncated = true; break }
                channels.append(IPTVChannel(number: channels.count + 1, name: name.flatMap(label) ?? "Channel \(channels.count + 1)",
                                            category: category ?? inheritedCategory, url: url))
            }
        }
        if name != nil { skipped += 1 }
        guard !channels.isEmpty else { throw IPTVCatalogFailure.empty }
        return IPTVCatalog(title: catalogTitle, channels: channels, skippedEntries: skipped, truncated: truncated)
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: "(?:^|\\s)" + key + #"="([^"]*)""#, options: .caseInsensitive),
              let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return label(String(line[range]))
    }
    private static func label(_ value: String) -> String? {
        let text = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }
}

public enum IPTVCatalogLoader {
    public static func load(_ source: URL) async throws -> IPTVCatalog {
        try Task.checkCancellation()
        if source.isFileURL {
            let file = try MediaInput.localFile(source)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: IPTVPlaylist.maximumBytes + 1) ?? Data()
            try Task.checkCancellation()
            return try IPTVPlaylist.parse(data, title: file.deletingPathExtension().lastPathComponent)
        }
        let source = try MediaInput.url(source.absoluteString)
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config, delegate: CatalogRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(from: source) }
        catch let error as URLError where error.code == .userAuthenticationRequired || error.code == .userCancelledAuthentication {
            throw IPTVCatalogFailure.accessRequired
        }
        guard let response = response as? HTTPURLResponse else { throw IPTVCatalogFailure.unavailable }
        guard response.statusCode != 401 && response.statusCode != 403 else { throw IPTVCatalogFailure.accessRequired }
        guard response.statusCode == 200 else { throw IPTVCatalogFailure.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= IPTVPlaylist.maximumBytes else { throw IPTVCatalogFailure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < IPTVPlaylist.maximumBytes else { throw IPTVCatalogFailure.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try IPTVPlaylist.parse(data, baseURL: response.url, title: "Channels")
    }
}

private final class CatalogRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, (try? MediaInput.url(url.absoluteString)) != nil,
              !(response.url?.scheme == "https" && url.scheme != "https") else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
