import Foundation

private final class DAVAuthentication: NSObject, URLSessionTaskDelegate, Sendable {
    let root: URL
    let username: String
    let password: String
    init(root: URL, username: String, password: String) { self.root = root; self.username = username; self.password = password }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let s = challenge.protectionSpace
        if s.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil); return }
        let port = root.port ?? (root.scheme == "https" ? 443 : 80)
        guard !s.isProxy(), s.host.lowercased() == root.host?.lowercased(), s.port == port, s.protocol == root.scheme,
              [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(s.authenticationMethod),
              challenge.previousFailureCount == 0, !username.isEmpty else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .none))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, (try? SharePath.relative(url, root: root)) != nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}

public actor WebDAVShareProvider: ShareProvider {
    private let root: URL
    private let session: URLSession
    private let username: String
    private let password: String
    public init(root: URL, username: String = "", password: String = "") {
        self.root = root; self.username = username; self.password = password
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: DAVAuthentication(root: root, username: username, password: password), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func disconnect() { session.invalidateAndCancel() }
    private func request(_ path: String, method: String = "GET") throws -> URLRequest {
        var r = URLRequest(url: try SharePath.url(root: root, path: path)); r.httpMethod = method; return r
    }
    private func response(_ request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShareError.invalidResponse }
        guard http.statusCode != 401 && http.statusCode != 403 else { throw ShareError.accessDenied }
        if request.value(forHTTPHeaderField: "Range") != nil, http.statusCode == 200 { throw ShareError.noRanges }
        guard (200..<300).contains(http.statusCode) else { throw ShareError.unavailable }
        guard http.expectedContentLength <= Int64(maximumBytes) else { throw ShareError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw ShareError.tooLarge }; data.append(byte)
        }
        return (data, http)
    }
    public func list(_ path: String) async throws -> [ShareEntry] {
        var r = try request(path, method: "PROPFIND"); r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("""
        <?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
        """.utf8)
        let (data, http) = try await response(r, maximumBytes: 16 * 1024 * 1024)
        guard http.statusCode == 207 else { throw ShareError.invalidResponse }
        return try Self.decode(data, root: root, directory: path)
    }
    public static func decode(_ data: Data, root: URL, directory: String) throws -> [ShareEntry] {
        let decoder = DAVListing(root: root, directory: try SharePath.validate(directory))
        let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = decoder
        guard parser.parse(), !decoder.invalid else { throw ShareError.invalidResponse }
        return decoder.entries
    }
    public func read(_ path: String, maximumBytes: Int) async throws -> Data { try await response(request(path), maximumBytes: maximumBytes).0 }
    public func playbackURL(_ path: String) async throws -> URL {
        var r = try request(path); r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, http) = try await response(r, maximumBytes: 1)
        guard http.statusCode == 206, http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-0/") == true else { throw ShareError.noRanges }
        return try SharePath.url(root: root, path: path)
    }
    @MainActor public func playbackCredentials(_ path: String) async throws -> HTTPLoginCredentials? {
        let url = try SharePath.url(root: root, path: path)
        guard let challenge = try await HTTPAuthentication.challenge(for: url) else { return nil }
        guard !username.isEmpty else { throw ShareError.accessDenied }
        return HTTPLoginCredentials(challenge: challenge, username: username, password: password)
    }
    public func download(_ path: String, to destination: URL, maximumBytes: Int64, progress: @Sendable (Int64) async -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request(path))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ShareError.unavailable }
        guard http.expectedContentLength <= maximumBytes else { throw ShareError.tooLarge }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ShareError.storage }
        let handle = try FileHandle(forWritingTo: destination); defer { try? handle.close() }
        var buffer = Data(); var total: Int64 = 0
        for try await byte in bytes {
            try Task.checkCancellation(); total += 1
            guard total <= maximumBytes else { throw ShareError.tooLarge }
            buffer.append(byte)
            if buffer.count == 256 * 1024 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true); await progress(total) }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        await progress(total)
    }
}

private final class DAVListing: NSObject, XMLParserDelegate {
    let root: URL; let directory: String
    var entries: [ShareEntry] = []; var invalid = false
    var text = ""; var href = ""; var properties: [String: String] = [:]; var pending: [String: String] = [:]
    var collection = false; var pendingCollection = false; var inPropstat = false
    init(root: URL, directory: String) { self.root = root; self.directory = directory }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if name == "response" { href = ""; properties = [:]; collection = false }
        if name == "propstat" { pending = [:]; pendingCollection = false; inPropstat = true }
        if name == "collection", namespaceURI == "DAV:" { pendingCollection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard namespaceURI == "DAV:" else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "href" { href = value }
        if ["getcontentlength", "getlastmodified", "status"].contains(name) { pending[name] = value }
        if name == "propstat" {
            if pending["status"]?.contains(" 200 ") == true { properties.merge(pending) { _, new in new }; collection = collection || pendingCollection }
            inPropstat = false
        }
        if name == "response" {
            guard !properties.isEmpty, let url = URL(string: href, relativeTo: root)?.absoluteURL,
                  let path = try? SharePath.relative(url, root: root), path != directory else { return }
            let parent = (path as NSString).deletingLastPathComponent
            guard parent == directory else { return }
            let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            entries.append(ShareEntry(path: path, name: url.lastPathComponent, isDirectory: collection,
                                      size: properties["getcontentlength"].flatMap(Int64.init), modified: properties["getlastmodified"].flatMap { date.date(from: $0) }))
            if entries.count > 100_000 { invalid = true; parser.abortParsing() }
        }
    }
}
