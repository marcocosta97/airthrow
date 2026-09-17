import Foundation
import Network
import SystemConfiguration
import Darwin

/// Session media under an unguessable path; no proxy or directory routes.
@MainActor
public final class MediaHTTPServer {
    public private(set) var url: URL?
    private let listener: NWListener
    private let host: String
    private let file: URL
    private let hls: Bool
    private let prefix = "/\(UUID().uuidString)/"
    private var path: String { prefix + (hls ? "media.m3u8" : "media.mp4") }
    private var ready: CheckedContinuation<Void, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var stopped = false

    // Mutable client state is used exclusively on the main queue, like the listener callbacks.
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var request = Data()
        var file: FileHandle?
        var remaining: Int64 = 0
        var timeout: Task<Void, Never>?
        init(_ connection: NWConnection) { self.connection = connection }
        deinit { try? file?.close(); timeout?.cancel() }
    }

    public static func start(file: URL, host: String? = nil, hls: Bool = false) async throws -> MediaHTTPServer {
        let server = try MediaHTTPServer(file: file, host: host ?? localAddress(), hls: hls)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                server.ready = continuation
                server.listener.stateUpdateHandler = { [weak server] state in
                    MainActor.assumeIsolated {
                        guard let server, !server.stopped else { return }
                        switch state {
                        case .ready:
                            guard let port = server.listener.port else { server.stop(); return }
                            server.url = URL(string: "http://\(server.host):\(port.rawValue)\(server.path)")
                            server.ready?.resume(); server.ready = nil
                            server.startupTimeout?.cancel()
                        case .failed: server.stop()
                        default: break
                        }
                    }
                }
                server.listener.newConnectionHandler = { [weak server] connection in
                    MainActor.assumeIsolated { server?.accept(connection) }
                }
                server.listener.start(queue: .main)
                server.startupTimeout = Task { [weak server] in
                    try? await Task.sleep(for: .seconds(5))
                    if !Task.isCancelled { server?.stop() }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor in server.stop() }
        }
        return server
    }

    private init(file: URL, host: String, hls: Bool) throws {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { throw PreparationFailure.delivery }
        self.file = file; self.host = host; self.hls = hls
        if !hls {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw PreparationFailure.failed }
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .init(host), port: .any)
        do { listener = try NWListener(using: parameters) }
        catch { throw PreparationFailure.delivery }
    }

    /// Prefer the system's primary LAN interface. Never advertise localhost automatically.
    nonisolated public static func localAddress() throws -> String {
        let store = SCDynamicStoreCreate(nil, "AirPlayer" as CFString, nil, nil)
        let primary = (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                       as? [String: Any])?["PrimaryInterface"] as? String
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw PreparationFailure.delivery }
        defer { freeifaddrs(interfaces) }
        var choices: [(String, String)] = []
        var current = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == AF_INET,
                  interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            choices.append((name, String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        }
        guard let selected = choices.first(where: { $0.0 == primary }) ?? choices.sorted(by: { $0.0 < $1.0 }).first else {
            throw PreparationFailure.delivery
        }
        return selected.1
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        startupTimeout?.cancel()
        ready?.resume(throwing: PreparationFailure.delivery); ready = nil
        listener.cancel()
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
        for client in Array(clients.values) { finish(client) }
    }

    deinit {
        listener.cancel()
        startupTimeout?.cancel()
        for client in clients.values { client.connection.cancel(); client.timeout?.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, clients.count < 8 else { connection.cancel(); return }
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        connection.start(queue: .main)
        armTimeout(client)
        receive(client)
    }

    private func armTimeout(_ client: Client) {
        client.timeout?.cancel()
        client.timeout = Task { [weak self, weak client] in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled, let client { self?.finish(client) }
        }
    }

    private func finish(_ client: Client) {
        client.timeout?.cancel()
        client.connection.cancel()
        try? client.file?.close(); client.file = nil
        clients.removeValue(forKey: ObjectIdentifier(client))
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.clients[ObjectIdentifier(client)] != nil else { return }
                if let data { client.request.append(data) }
                guard client.request.count <= 8192 else { self.reply(client, code: "431 Request Header Fields Too Large"); return }
                if let end = client.request.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(client, header: client.request[..<end.lowerBound])
                } else if complete || error != nil { self.finish(client) }
                else { self.receive(client) }
            }
        }
    }

    private func respond(_ client: Client, header: Data) {
        guard let text = String(data: header, encoding: .utf8) else { reply(client, code: "400 Bad Request"); return }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(request[2]) else { reply(client, code: "400 Bad Request"); return }
        let requested = String(request[1])
        let resource: URL
        let contentType: String
        if requested == path {
            resource = file
            contentType = hls ? "application/vnd.apple.mpegurl" : "video/mp4"
        } else if hls, requested.hasPrefix(prefix),
                  Self.isSegmentName(String(requested.dropFirst(prefix.count))) {
            resource = file.deletingLastPathComponent().appendingPathComponent(String(requested.dropFirst(prefix.count)))
            contentType = "video/mp2t"
        } else { reply(client, code: "404 Not Found"); return }
        guard request[0] == "GET" || request[0] == "HEAD" else { reply(client, code: "405 Method Not Allowed", extra: "Allow: GET, HEAD\r\n"); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { reply(client, code: "400 Bad Request"); return }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { reply(client, code: "400 Bad Request"); return }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == "0" else {
            reply(client, code: "400 Bad Request"); return
        }
        // Open once, then stat that descriptor: an atomic playlist replacement must
        // not mix the previous Content-Length with the new playlist body.
        let fd = open(resource.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { reply(client, code: "404 Not Found"); return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            try? handle.close(); reply(client, code: "404 Not Found"); return
        }
        client.file = handle
        let size = Int64(info.st_size)
        var start: Int64 = 0, end = size - 1
        var partial = false
        if request[0] == "GET", let range = headers["range"], headers["if-range"] == nil {
            guard let interval = Self.byteRange(range, size: size) else {
                reply(client, code: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n"); return
            }
            (start, end) = interval; partial = true
        }
        do {
            if request[0] == "GET" {
                try client.file?.seek(toOffset: UInt64(start))
                client.remaining = end - start + 1
            }
            let code = partial ? "206 Partial Content" : "200 OK"
            let rangeHeader = partial ? "Content-Range: bytes \(start)-\(end)/\(size)\r\n" : ""
            let response = "HTTP/1.1 \(code)\r\nContent-Type: \(contentType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(end - start + 1)\r\nCache-Control: no-store\r\nConnection: close\r\n\(rangeHeader)\r\n"
            send(client, data: Data(response.utf8))
        } catch { reply(client, code: "500 Internal Server Error") }
    }

    nonisolated static func isSegmentName(_ name: String) -> Bool {
        guard name.hasPrefix("segment"), name.hasSuffix(".ts") else { return false }
        // ffmpeg's %06d widens past six digits, so the index is not width-fixed.
        let digits = name.dropFirst(7).dropLast(3)
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func byteRange(_ value: String, size: Int64) -> (Int64, Int64)? {
        guard size > 0, value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { return nil }
            return (max(0, size - suffix), size - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : Int64(parts[1])
        guard let end, end >= start else { return nil }
        return (start, min(end, size - 1))
    }

    private func reply(_ client: Client, code: String, extra: String = "") {
        client.remaining = 0
        send(client, data: Data("HTTP/1.1 \(code)\r\nContent-Length: 0\r\nConnection: close\r\n\(extra)\r\n".utf8))
    }

    private func send(_ client: Client, data: Data) {
        guard !stopped, clients[ObjectIdentifier(client)] != nil else { return }
        armTimeout(client)
        client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, self.clients[ObjectIdentifier(client)] != nil else { return }
                guard error == nil, client.remaining > 0 else { self.finish(client); return }
                do {
                    guard let chunk = try client.file?.read(upToCount: Int(min(client.remaining, 64 * 1024))), !chunk.isEmpty else {
                        self.finish(client); return
                    }
                    client.remaining -= Int64(chunk.count)
                    self.send(client, data: chunk)
                } catch { self.finish(client) }
            }
        })
    }
}
