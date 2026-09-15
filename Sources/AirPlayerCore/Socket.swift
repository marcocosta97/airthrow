import Foundation
import Darwin

public enum LocalSocket {
    public static let maxBytes = 32_768
    public static var directory: String {
        // Darwin's per-user temporary directory is short enough for sockaddr_un.
        let root = FileManager.default.temporaryDirectory.path
        return root + "/airplayer-\(getuid())"
    }
    public static var path: String { directory + "/control.sock" }

    public static func prepareDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw unavailable("Cannot create the command directory.") }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw unavailable("The command directory must be private and owned by this user.")
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw unavailable("The command socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
        return address
    }

    static func configure(_ fd: Int32) {
        // BSD accept inherits the listener flags. Clients use bounded blocking I/O.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw unavailable("Cannot create a command connection.") }
        configure(fd)
        do {
            var addr = try address(path)
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, sameUser(fd) else { throw unavailable("AirPlayer is not running. Use ‘airplayer open URL’ or ‘airplayer show’.") }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    static func readLine(_ fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(4)
        while data.count <= maxBytes && Date() < deadline {
            let count = recv(fd, &buffer, min(buffer.count, maxBytes + 1 - data.count), 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw unavailable("The command connection closed or timed out.") }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<newline])
                guard data.count <= maxBytes else { break }
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw AppFailure(.invalidRequest, "Command exceeds the size or time limit.")
    }

    static func writeLine(_ data: Data, to fd: Int32) throws {
        guard data.count <= maxBytes else { throw AppFailure(.invalidRequest, "Command is too large.") }
        let bytes = data + Data([10])
        try bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw unavailable("Cannot send the command response.") }
                sent += count
            }
        }
    }

    public static func send(_ request: Request, path: String = LocalSocket.path) throws -> Response {
        let fd = try connect(path)
        defer { Darwin.close(fd) }
        try writeLine(JSONEncoder().encode(request), to: fd)
        return try JSONDecoder().decode(Response.self, from: readLine(fd))
    }

    static func unavailable(_ message: String) -> AppFailure { AppFailure(.appUnavailable, message) }
}

/// All descriptor access is serialized on queue. The handler must reply asynchronously;
/// it may dispatch to the main actor without blocking the app's UI.
public final class CommandServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Request, @escaping @Sendable (Response) -> Void) -> Void
    private let queue = DispatchQueue(label: "app.airplayer.commands", qos: .userInitiated)
    private var source: DispatchSourceRead?
    private let path: String

    public init(path: String = LocalSocket.path) { self.path = path }

    public func start(handler: @escaping Handler) throws {
        try queue.sync {
            guard source == nil else { return }
            let directory = (path as NSString).deletingLastPathComponent
            try LocalSocket.prepareDirectory(directory)
            // A held lock prevents a second process from unlinking a live endpoint.
            let lock = Darwin.open(directory + "/owner.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw LocalSocket.unavailable("Cannot lock the command endpoint.") }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(lock)
                throw LocalSocket.unavailable("Another AirPlayer instance already owns this session.")
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { Darwin.close(lock); throw LocalSocket.unavailable("Cannot create the command endpoint.") }
            do {
                LocalSocket.configure(fd)
                var addr = try LocalSocket.address(path)
                unlink(path)
                let result = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard result == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                    throw LocalSocket.unavailable("Cannot start the command endpoint.")
                }
                _ = fcntl(fd, F_SETFL, O_NONBLOCK)
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler {
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    defer { Darwin.close(client) }
                    LocalSocket.configure(client)
                    guard LocalSocket.sameUser(client) else { return }
                    do {
                        let request = try JSONDecoder().decode(Request.self, from: LocalSocket.readLine(client))
                        guard request.version == 1 else { throw AppFailure(.invalidRequest, "Unsupported command protocol version.") }
                        let box = ReplyBox()
                        handler(request) { box.set($0) }
                        guard box.semaphore.wait(timeout: .now() + 2) == .success, let reply = box.get() else {
                            throw LocalSocket.unavailable("AirPlayer did not respond in time.")
                        }
                        try LocalSocket.writeLine(JSONEncoder().encode(reply), to: client)
                    } catch {
                        let failure = error as? AppFailure ?? AppFailure(.invalidRequest, "Invalid command JSON.")
                        if let data = try? JSONEncoder().encode(Response(error: failure)) {
                            try? LocalSocket.writeLine(data, to: client)
                        }
                    }
                }
                let socketPath = path
                source.setCancelHandler {
                    Darwin.close(fd)
                    unlink(socketPath)
                    flock(lock, LOCK_UN)
                    Darwin.close(lock)
                }
                self.source = source
                source.resume()
            } catch { Darwin.close(fd); Darwin.close(lock); throw error }
        }
    }

    public func stop() {
        queue.async { [self] in source?.cancel(); source = nil }
    }
}

private final class ReplyBox: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reply: Response?
    func set(_ response: Response) { lock.lock(); reply = response; lock.unlock(); semaphore.signal() }
    func get() -> Response? { lock.lock(); defer { lock.unlock() }; return reply }
}
