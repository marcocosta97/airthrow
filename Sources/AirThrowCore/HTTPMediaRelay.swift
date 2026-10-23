import Foundation
import Darwin

/// A playlist or redirect may name another host. Loopback, link-local, and
/// private addresses are accepted only when the original source is already in
/// that same class, so a public stream cannot be pointed at the local network.
enum RelayAddress {
    enum Kind { case loopback, linkLocal, privateNetwork, publicHost }

    static func allows(_ target: URL, from source: URL) -> Bool {
        guard let targetHost = target.host, let sourceHost = source.host else { return false }
        let destination = kind(targetHost)
        if destination == .publicHost { return true }
        return destination == kind(sourceHost)
    }

    static func kind(_ host: String) -> Kind {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        if name.hasPrefix("[") && name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name == "localhost" { return .loopback }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            let raw = UInt32(bigEndian: v4.s_addr)
            let a = UInt8((raw >> 24) & 0xff)
            let b = UInt8((raw >> 16) & 0xff)
            if a == 0 || a == 127 { return .loopback }
            if a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(Int(b))) { return .privateNetwork }
            if a == 169 && b == 254 { return .linkLocal }
            return .publicHost
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0.prefix(16)) }
            if bytes.count == 16 {
                if bytes.allSatisfy({ $0 == 0 }) || (bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1) { return .loopback }
                if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                    return kind("\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])")
                }
                if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return .linkLocal }
                if (bytes[0] & 0xfe) == 0xfc { return .privateNetwork }
            }
        }
        return .publicHost
    }
}

/// Routes discovered from HLS playlists. A live playlist is remembered for a few
/// refreshes so a receiver can still fetch a segment that just left the window,
/// then those routes are dropped instead of growing until the table is full.
struct RelayRoutes {
    static let maximum = 16_384
    static let rememberedPlaylists = 4
    private(set) var paths: [String: URL] = [:]
    private var reverse: [URL: String] = [:]
    private var history: [String: [Set<URL>]] = [:]
    private var entryPath: String?
    var prefix = ""
    var count: Int { paths.count }

    mutating func setEntry(path: String, source: URL, prefix: String) {
        self.prefix = prefix
        entryPath = path
        paths[path] = source
    }

    func upstream(_ path: String) -> URL? { paths[path] }

    func resolve(_ reference: String, base: URL) throws -> URL {
        guard let target = URL(string: reference, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              target.host != nil, target.user == nil, target.password == nil, !reference.contains("{$"),
              !(base.scheme == "https" && target.scheme != "https"), !reference.isEmpty else {
            throw HTTPLoginFailure.invalidPlaylist
        }
        guard let entryPath, let source = paths[entryPath], RelayAddress.allows(target, from: source) else {
            throw HTTPLoginFailure.invalidPlaylist
        }
        return target
    }

    /// Record the URLs this playlist refresh advertises, then drop routes that
    /// no longer appear in any playlist's recent refreshes.
    mutating func replacePlaylist(at path: String, with references: Set<URL>) {
        var sets = history[path] ?? []
        sets.append(references)
        if sets.count > Self.rememberedPlaylists { sets.removeFirst(sets.count - Self.rememberedPlaylists) }
        history[path] = sets
        prune()
    }

    mutating func route(_ target: URL) throws -> String {
        if let existing = reverse[target] { return existing }
        guard paths.count < Self.maximum else { throw HTTPLoginFailure.invalidPlaylist }
        let ext = target.pathExtension.lowercased()
        let suffix = ["m3u8", "ts", "m4s", "mp4", "aac", "vtt", "key"].contains(ext) ? "." + ext : ""
        let route = prefix + UUID().uuidString + suffix
        paths[route] = target
        reverse[target] = route
        return route
    }

    private mutating func prune() {
        func liveTargets() -> Set<URL> {
            var live = Set(history.values.flatMap { $0.flatMap { $0 } })
            if let entryPath, let source = paths[entryPath] { live.insert(source) }
            return live
        }
        func dropStale(_ live: Set<URL>) {
            for (path, target) in paths where path != entryPath && !live.contains(target) {
                paths.removeValue(forKey: path)
                if reverse[target] == path { reverse.removeValue(forKey: target) }
            }
        }
        dropStale(liveTargets())
        history = history.filter { paths[$0.key] != nil }
        dropStale(liveTargets())
    }
}

/// A session-scoped relay: only the source and resources discovered in its HLS
/// playlists have routes. It never accepts a client-supplied upstream URL.
@MainActor
public final class HTTPMediaRelay {
    public let source: URL
    public private(set) var url: URL?
    private var credentials: HTTPLoginCredentials?
    private var variant: HLSVariantSelection?
    private var sourceHeaders: [String: String] = [:]
    private var readAheadBytes = 256 * 1024
    private var preparationCache: PreparationInputCache?
    private var server: MediaHTTPServer?
    private var routes = RelayRoutes()
    private var streams: [UUID: HTTPRelayStream] = [:]
    private var finishedDiagnostics = LivePipelineDiagnostics()
    public var diagnostics: LivePipelineDiagnostics {
        var result = finishedDiagnostics
        result.relayActiveStreams = streams.count
        for stream in streams.values {
            result.relayReceivedBytes += stream.receivedBytes
            result.relayPeakBufferBytes = max(result.relayPeakBufferBytes, stream.peakBufferBytes)
        }
        return result
    }

    private init(source: URL, credentials: HTTPLoginCredentials?) {
        self.source = source; self.credentials = credentials
    }

    public static func start(source: URL, credentials: HTTPLoginCredentials? = nil, host: String? = nil, variant: HLSVariantSelection? = nil,
                             sourceHeaders: [String: String] = [:], readAheadBytes: Int = 256 * 1024) async throws -> HTTPMediaRelay {
        let source = try MediaInput.url(source.absoluteString)
        let relay = HTTPMediaRelay(source: source, credentials: credentials)
        guard sourceHeaders.count <= 8, sourceHeaders.allSatisfy({ key, value in
            ["user-agent", "accept", "accept-language", "sec-fetch-mode"].contains(key.lowercased())
                && value.utf8.count <= 4096 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }) else { throw PreparationFailure.unsupported }
        relay.variant = variant
        relay.sourceHeaders = sourceHeaders
        relay.readAheadBytes = min(8 * 1024 * 1024, max(256 * 1024, readAheadBytes))
        if credentials == nil, readAheadBytes > 256 * 1024, source.pathExtension.lowercased() != "m3u8" {
            do { relay.preparationCache = try await PreparationInputCache.open(url: source, headers: sourceHeaders) }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() } // No ranges/validator: preserve bounded streaming.
        }
        let server = try await MediaHTTPServer.start(file: source, host: host, hls: source.pathExtension.lowercased() == "m3u8", relay: relay)
        relay.server = server; relay.url = server.url
        if let url = server.url {
            relay.routes.setEntry(path: url.path, source: source,
                                  prefix: url.deletingLastPathComponent().path + "/")
        }
        return relay
    }

    public func stop() {
        if let cache = preparationCache { Task { await cache.stop() } }; preparationCache = nil
        server?.stop(); server = nil
        for stream in Array(streams.values) { stream.cancel() }
        streams.removeAll(); routes = RelayRoutes()
        credentials = nil
    }

    func serve(path: String, method: String, headers: [String: String],
               send: @escaping (Data, @escaping @MainActor @Sendable () -> Void) -> Void,
               finish: @escaping () -> Void) -> HTTPRelayStream? {
        guard server != nil, let upstream = routes.upstream(path) else { return nil }
        let id = UUID()
        let stream = HTTPRelayStream(url: upstream, method: method, headers: headers,
            credentials: credentials, origin: source, sourceHeaders: sourceHeaders, readAheadBytes: readAheadBytes,
            preparationCache: upstream == source ? preparationCache : nil, rewrite: { [weak self] data, base in
                guard let self else { throw CancellationError() }
                return try self.rewrite(data, base: base, routePath: path)
            }, send: send, finish: { [weak self] in
                if let self, let stream = self.streams.removeValue(forKey: id) {
                    self.finishedDiagnostics.relayFinishedStreams += 1
                    self.finishedDiagnostics.relayReceivedBytes += stream.receivedBytes
                    self.finishedDiagnostics.relayPeakBufferBytes = max(self.finishedDiagnostics.relayPeakBufferBytes, stream.peakBufferBytes)
                    if let error = stream.errorCode { self.finishedDiagnostics.relayLastErrorCode = error }
                    if stream.bufferLimitReached { self.finishedDiagnostics.relayBufferLimitClosures += 1 }
                    if stream.upstreamEnded { self.finishedDiagnostics.relayEOFClosures += 1 }
                    if let status = stream.httpStatusCode, status >= 400 {
                        self.finishedDiagnostics.relayHTTPFailures += 1
                        self.finishedDiagnostics.relayLastHTTPStatus = status
                    }
                }
                finish()
            })
        streams[id] = stream
        stream.start()
        return stream
    }

    private func rewrite(_ data: Data, base: URL, routePath: String) throws -> Data {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw HTTPLoginFailure.invalidPlaylist
        }
        let filtered: Data
        if let variant, text.contains("#EXT-X-STREAM-INF:") {
            filtered = try HLSRenditions.selecting(variant, in: data)
        } else { filtered = data }
        guard let text = String(data: filtered, encoding: .utf8) else { throw HTTPLoginFailure.invalidPlaylist }
        let lines = PlaylistText.lines(in: text)
        guard lines.first == "#EXTM3U" else { throw HTTPLoginFailure.invalidPlaylist }
        var output: [String] = []
        finishedDiagnostics.relayManifestResponses += 1
        if lines.contains("#EXT-X-ENDLIST") { finishedDiagnostics.relayManifestEndLists += 1 }
        if lines.contains("#EXT-X-PLAYLIST-TYPE:VOD") { finishedDiagnostics.relayManifestVODs += 1 }
        if let line = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }),
           let sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)), sequence >= 0 {
            finishedDiagnostics.relayManifestSequence = sequence
        }
        // URI attributes carry keys, init fragments, alternate audio and subtitles.
        let pattern = try NSRegularExpression(pattern: #"\bURI="([^"]*)""#)
        var references: [URL] = []
        for line in lines where !line.isEmpty {
            if !line.hasPrefix("#") {
                references.append(try routes.resolve(line, base: base))
                continue
            }
            for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let value = Range(match.range(at: 1), in: line) else { throw HTTPLoginFailure.invalidPlaylist }
                references.append(try routes.resolve(String(line[value]), base: base))
            }
            guard !line.contains("{$") else { throw HTTPLoginFailure.invalidPlaylist }
        }
        routes.replacePlaylist(at: routePath, with: Set(references))
        for line in lines {
            if line.isEmpty { output.append(""); continue }
            if !line.hasPrefix("#") {
                output.append(try routes.route(routes.resolve(line, base: base)))
                continue
            }
            var rewritten = line
            for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let value = Range(match.range(at: 1), in: line),
                      let replacement = Range(match.range(at: 1), in: rewritten) else { throw HTTPLoginFailure.invalidPlaylist }
                let target = try routes.resolve(String(line[value]), base: base)
                rewritten.replaceSubrange(replacement, with: try routes.route(target))
            }
            guard !rewritten.contains("{$") else { throw HTTPLoginFailure.invalidPlaylist }
            output.append(rewritten)
        }
        return Data(output.joined(separator: "\n").utf8)
    }
}

/// Stream in bounded chunks, suspending the upstream while the receiver catches
/// up. HLS manifests are buffered separately, with a one-MiB ceiling.
@MainActor
final class HTTPRelayStream {
    static let sendChunkBytes = 64 * 1024
    // URLSession can deliver several MiB in a single callback even after
    // suspension. Keep headroom for those callbacks, then drain in small writes.
    static let maximumPendingBytes = 16 * 1024 * 1024
    private(set) var receivedBytes: Int64 = 0
    private(set) var peakBufferBytes = 0
    private(set) var errorCode: Int?
    private(set) var bufferLimitReached = false
    private(set) var upstreamEnded = false
    private(set) var httpStatusCode: Int?
    private let transfer: HTTPMediaTransfer
    private let method: String
    private let readAheadBytes: Int
    private let preparationCache: PreparationInputCache?
    private let requestedHeaders: [String: String]
    private let upstreamURL: URL
    private var cachedTransfer: Task<Void, Never>?
    private let rewrite: (Data, URL) throws -> Data
    private let send: (Data, @escaping @MainActor @Sendable () -> Void) -> Void
    private var finish: (() -> Void)?
    private var response: HTTPURLResponse?
    private var playlist = false
    private var manifest = Data()
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var sending = false
    private var ended = false
    private var sentHeaders = false
    private var chunked = false

    init(url: URL, method: String, headers: [String: String], credentials: HTTPLoginCredentials?,
         origin: URL? = nil, sourceHeaders: [String: String] = [:], readAheadBytes: Int = 256 * 1024, preparationCache: PreparationInputCache? = nil, rewrite: @escaping (Data, URL) throws -> Data,
         send: @escaping (Data, @escaping @MainActor @Sendable () -> Void) -> Void, finish: @escaping () -> Void) {
        self.method = method; self.rewrite = rewrite; self.send = send; self.finish = finish
        self.readAheadBytes = min(8 * 1024 * 1024, max(256 * 1024, readAheadBytes))
        self.preparationCache = preparationCache; self.requestedHeaders = headers; self.upstreamURL = url
        var request = URLRequest(url: url)
        // HLS HEAD needs rewritten length, so obtain its manifest with GET.
        let knownPlaylist = url.pathExtension.lowercased() == "m3u8"
        request.httpMethod = "GET"
        for (name, value) in sourceHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !knownPlaylist, method == "GET" {
            for name in ["range", "if-range"] { if let value = headers[name] { request.setValue(value, forHTTPHeaderField: name) } }
        }
        transfer = HTTPMediaTransfer(request: request, credentials: credentials, origin: origin ?? url)
        transfer.response = { [weak self] response in self?.received(response) ?? false }
        transfer.data = { [weak self] data in self?.received(data) }
        transfer.completed = { [weak self] error in self?.completed(error) }
    }

    func start() {
        guard let cache = preparationCache else { transfer.start(); return }
        cachedTransfer = Task { [weak self] in
            guard let self else { return }
            do {
                let size = cache.size
                var range = requestedHeaders["range"]
                if let check = requestedHeaders["if-range"], check != cache.validator { range = nil }
                let span = range.flatMap { MediaHTTPServer.byteRange($0, size: size) }
                if range != nil && span == nil {
                    enqueue(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(size)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); ended = true; drain(); return
                }
                let start = span?.0 ?? 0, end = span?.1 ?? size - 1
                var fields = ["Content-Type": cache.mime, "Content-Length": String(end - start + 1), "Accept-Ranges": "bytes"]
                fields[cache.validatorHeader] = cache.validator
                if span != nil { fields["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
                guard let response = HTTPURLResponse(url: upstreamURL, statusCode: span == nil ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: fields) else { throw PreparationFailure.failed }
                _ = received(response)
                if method == "HEAD" { return }
                var offset = start
                while offset <= end {
                    try Task.checkCancellation()
                    guard finish != nil else { return }
                    while pendingBytes > readAheadBytes / 2 {
                        try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(2))
                    }
                    let data = try await cache.read(offset: offset, maximum: Int(min(64 * 1024, end - offset + 1)))
                    received(data); offset += Int64(data.count)
                }
                completed(nil)
            } catch { if !Task.isCancelled { self.completed(error) } }
        }
    }
    func cancel() {
        cachedTransfer?.cancel(); cachedTransfer = nil
        transfer.cancel(); pending.removeAll(); manifest.removeAll()
        let callback = finish; finish = nil; callback?()
    }

    func received(_ response: HTTPURLResponse) -> Bool {
        httpStatusCode = response.statusCode
        guard [200, 206, 416].contains(response.statusCode) else {
            reject(response.statusCode == 404 ? "404 Not Found" : "502 Bad Gateway"); return false
        }
        self.response = response
        playlist = response.url?.pathExtension.lowercased() == "m3u8"
            || (response.mimeType?.lowercased().contains("mpegurl") ?? false)
        if !playlist, let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            reject("502 Bad Gateway"); return false
        }
        if method == "HEAD", !playlist { enqueue(header(response)); ended = true; return false }
        if response.statusCode == 416 { enqueue(header(response)); ended = true; return false }
        return true
    }

    func received(_ data: Data) {
        guard !ended, let response else { return }
        receivedBytes += Int64(data.count)
        if !sentHeaders && PlaylistText.startsAsPlaylist(data) { playlist = true }
        if playlist {
            guard manifest.count + data.count <= 1_048_576 else { reject("502 Bad Gateway"); return }
            manifest.append(data)
        } else {
            if !sentHeaders { enqueue(header(response)); sentHeaders = true }
            for offset in stride(from: 0, to: data.count, by: Self.sendChunkBytes) {
                guard finish != nil else { return }
                let payload = data.subdata(in: offset..<min(offset + Self.sendChunkBytes, data.count))
                if chunked {
                    var chunk = Data("\(String(payload.count, radix: 16))\r\n".utf8)
                    chunk.append(payload); chunk.append(Data("\r\n".utf8)); enqueue(chunk)
                } else { enqueue(payload) }
            }
        }
    }

    private func completed(_ error: Error?) {
        guard !ended else { drain(); return }
        if error != nil {
            errorCode = (error as NSError?)?.code
            if sentHeaders { cancel() } else { reject("502 Bad Gateway") }
            return
        }
        upstreamEnded = true
        if playlist, let response, let base = response.url {
            do {
                let body = try rewrite(manifest, base)
                enqueue(Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8))
                if method == "GET" { enqueue(body) }
            } catch { reject("502 Bad Gateway"); return }
        } else if !sentHeaders, let response { enqueue(header(response)) }
        if chunked { enqueue(Data("0\r\n\r\n".utf8)) }
        ended = true; drain()
    }

    private func header(_ response: HTTPURLResponse) -> Data {
        let code = response.statusCode == 206 ? "206 Partial Content" : response.statusCode == 416 ? "416 Range Not Satisfiable" : "200 OK"
        var text = "HTTP/1.1 \(code)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"] {
            if let value = response.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") { text += "\(name): \(value)\r\n" }
        }
        chunked = response.value(forHTTPHeaderField: "Content-Length") == nil && method == "GET" && response.statusCode != 416
        if chunked { text += "Transfer-Encoding: chunked\r\n" }
        return Data((text + "\r\n").utf8)
    }

    private func reject(_ code: String) {
        transfer.cancel()
        if sentHeaders { cancel(); return }
        pending.removeAll(); pendingBytes = 0
        enqueue(Data("HTTP/1.1 \(code)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        ended = true; drain()
    }

    private func enqueue(_ data: Data) {
        guard data.count <= Self.maximumPendingBytes - pendingBytes else {
            bufferLimitReached = true; cancel(); return
        }
        pending.append(data); pendingBytes += data.count
        peakBufferBytes = max(peakBufferBytes, pendingBytes)
        if pendingBytes > readAheadBytes { transfer.pause() }
        drain()
    }

    private func drain() {
        guard finish != nil, !sending else { return }
        guard !pending.isEmpty else { if ended { cancel() }; return }
        sending = true
        let data = pending.removeFirst()
        send(data) { [weak self] in
            guard let self else { return }
            self.sending = false; self.pendingBytes -= data.count
            if self.pendingBytes < self.readAheadBytes / 2 { self.transfer.resume() }
            self.drain()
        }
    }
}
