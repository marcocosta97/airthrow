import Foundation

/// A session-scoped relay: only the source and resources discovered in its HLS
/// playlists have routes. It never accepts a client-supplied upstream URL.
@MainActor
public final class HTTPMediaRelay {
    public let source: URL
    public private(set) var url: URL?
    private var credentials: HTTPLoginCredentials?
    private var server: MediaHTTPServer?
    private var routes: [String: URL] = [:]
    private var reverseRoutes: [URL: String] = [:]
    private var streams: [UUID: HTTPRelayStream] = [:]
    private var prefix = ""
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

    public static func start(source: URL, credentials: HTTPLoginCredentials? = nil, host: String? = nil) async throws -> HTTPMediaRelay {
        let source = try MediaInput.url(source.absoluteString)
        let relay = HTTPMediaRelay(source: source, credentials: credentials)
        let server = try await MediaHTTPServer.start(file: source, host: host, hls: source.pathExtension.lowercased() == "m3u8", relay: relay)
        relay.server = server; relay.url = server.url
        if let url = server.url {
            relay.prefix = url.deletingLastPathComponent().path + "/"
            relay.routes[url.path] = source
        }
        return relay
    }

    public func stop() {
        server?.stop(); server = nil
        for stream in Array(streams.values) { stream.cancel() }
        streams.removeAll(); routes.removeAll(); reverseRoutes.removeAll()
        credentials = nil
    }

    func serve(path: String, method: String, headers: [String: String],
               send: @escaping (Data, @escaping @MainActor @Sendable () -> Void) -> Void,
               finish: @escaping () -> Void) -> HTTPRelayStream? {
        guard server != nil, let upstream = routes[path] else { return nil }
        let id = UUID()
        let stream = HTTPRelayStream(url: upstream, method: method, headers: headers,
            credentials: credentials, rewrite: { [weak self] data, base in
                guard let self else { throw CancellationError() }
                return try self.rewrite(data, base: base)
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

    private func route(_ reference: String, base: URL) throws -> String {
        guard let target = URL(string: reference, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              target.host != nil, target.user == nil, target.password == nil, !reference.contains("{$"),
              !(base.scheme == "https" && target.scheme != "https"), !reference.isEmpty else {
            throw HTTPLoginFailure.invalidPlaylist
        }
        if let route = reverseRoutes[target] { return route }
        guard routes.count < 16_384 else { throw HTTPLoginFailure.invalidPlaylist }
        let ext = target.pathExtension.lowercased()
        let suffix = ["m3u8", "ts", "m4s", "mp4", "aac", "vtt", "key"].contains(ext) ? "." + ext : ""
        let route = prefix + UUID().uuidString + suffix
        routes[route] = target; reverseRoutes[target] = route
        return route
    }

    private func rewrite(_ data: Data, base: URL) throws -> Data {
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U") else { throw HTTPLoginFailure.invalidPlaylist }
        var output: [String] = []
        finishedDiagnostics.relayManifestResponses += 1
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if lines.contains("#EXT-X-ENDLIST") { finishedDiagnostics.relayManifestEndLists += 1 }
        if lines.contains("#EXT-X-PLAYLIST-TYPE:VOD") { finishedDiagnostics.relayManifestVODs += 1 }
        if let line = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") }),
           let sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)), sequence >= 0 {
            finishedDiagnostics.relayManifestSequence = sequence
        }
        // URI attributes carry keys, init fragments, alternate audio and subtitles.
        let pattern = try NSRegularExpression(pattern: #"\bURI="([^"]*)""#)
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { output.append(""); continue }
            if !line.hasPrefix("#") { output.append(try route(line, base: base)); continue }
            var rewritten = line
            for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let value = Range(match.range(at: 1), in: line),
                      let replacement = Range(match.range(at: 1), in: rewritten) else { throw HTTPLoginFailure.invalidPlaylist }
                rewritten.replaceSubrange(replacement, with: try route(String(line[value]), base: base))
            }
            // Variable substitution needs an evaluator and could otherwise send a
            // receiver straight to the origin. Refuse it instead of leaking a URL.
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
         rewrite: @escaping (Data, URL) throws -> Data,
         send: @escaping (Data, @escaping @MainActor @Sendable () -> Void) -> Void, finish: @escaping () -> Void) {
        self.method = method; self.rewrite = rewrite; self.send = send; self.finish = finish
        var request = URLRequest(url: url)
        // HLS HEAD needs rewritten length, so obtain its manifest with GET.
        let knownPlaylist = url.pathExtension.lowercased() == "m3u8"
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !knownPlaylist, method == "GET" {
            for name in ["range", "if-range"] { if let value = headers[name] { request.setValue(value, forHTTPHeaderField: name) } }
        }
        transfer = HTTPMediaTransfer(request: request, credentials: credentials)
        transfer.response = { [weak self] response in self?.received(response) ?? false }
        transfer.data = { [weak self] data in self?.received(data) }
        transfer.completed = { [weak self] error in self?.completed(error) }
    }

    func start() { transfer.start() }
    func cancel() {
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
        if !sentHeaders && data.starts(with: Data("#EXTM3U".utf8)) { playlist = true }
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
        for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
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
        if pendingBytes > 256 * 1024 { transfer.pause() }
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
            if self.pendingBytes < 128 * 1024 { self.transfer.resume() }
            self.drain()
        }
    }
}
