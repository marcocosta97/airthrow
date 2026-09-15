import Foundation
import Darwin
import AirPlayerCore

struct CheckFailure: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message: message) }
}
func rejects(_ action: () throws -> Void) throws {
    do { try action() } catch is AppFailure { return }
    throw CheckFailure(message: "Expected an AppFailure")
}

let tests: [(String, () throws -> Void)] = [
    ("signed URL preservation", {
        let value = "https://cdn.example.com/a%2Fb/movie.m3u8?token=a%2Bb%3D&expires=123&x=1&x=2"
        try check(MediaInput.url("  \(value)\n").absoluteString == value, "Signed URL changed")
    }),
    ("invalid URLs", {
        for input in ["", "file:///tmp/movie.mp4", "ftp://example.com/a.mp4", "https:///", "https://name:secret@example.com/a.mp4", "https://example.com/\nmovie.mp4"] {
            try rejects { _ = try MediaInput.url(input) }
        }
    }),
    ("seek bounds and discontinuous live ranges", {
        let ranges = [SeekRange(start: 100, end: 120), SeekRange(start: 130, end: 150)]
        try MediaInput.validateSeek(100, ranges: ranges)
        try MediaInput.validateSeek(150, ranges: ranges)
        for value in [-1, 0, 125, 151, Double.infinity, Double.nan] {
            try rejects { try MediaInput.validateSeek(value, ranges: ranges) }
        }
        try rejects { try MediaInput.validateSeek(5, ranges: []) }
    }),
    ("route loss overrides playing state", {
        try check(PlaybackPolicy.state(hasItem: true, failed: false, ready: true, connecting: false,
            external: false, ended: false, playing: true, waiting: false, hasPlayed: true) == .awaitingReceiver,
            "Lost route reported as playing")
    }),
    ("paused external session", {
        try check(PlaybackPolicy.state(hasItem: true, failed: false, ready: true, connecting: false,
            external: true, ended: false, playing: false, waiting: false, hasPlayed: true) == .paused,
            "Paused external session reported as disconnected")
    }),
    ("negotiation is not successful playback", {
        try check(PlaybackPolicy.state(hasItem: true, failed: false, ready: true, connecting: true,
            external: false, ended: false, playing: true, waiting: false, hasPlayed: false) == .connecting,
            "Connection probe reported as playing")
    }),
    ("failure overrides loading", {
        try check(PlaybackPolicy.state(hasItem: true, failed: true, ready: false, connecting: false,
            external: false, ended: false, playing: false, waiting: false, hasPlayed: false) == .failed,
            "Failed item reported as loading")
    }),
    ("wire protocol and URL privacy", {
        let request = Request(.open, url: "https://example.com/video.mp4?token=private")
        let decoded = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request))
        try check(decoded.version == 1 && decoded.url == request.url, "Request round-trip failed")
        let response = Response(message: "Loading", pending: true, status: PlaybackSnapshot())
        let data = try JSONEncoder().encode(response)
        try check(!String(decoding: data, as: UTF8.self).contains("token"), "Status leaked URL")
        try check(JSONDecoder().decode(Response.self, from: data).pending, "Pending response was lost")
    }),
    ("socket round-trip, duplicate ownership, protocol version", {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ap-test-\(UUID().uuidString.prefix(8))")
        let path = directory.appendingPathComponent("control.sock").path
        let server = CommandServer(path: path)
        try server.start { request, reply in reply(Response(message: request.command.rawValue, status: PlaybackSnapshot())) }
        defer { server.stop() }
        try check(LocalSocket.send(Request(.status), path: path).message == "status", "Socket round-trip failed")
        let duplicate = CommandServer(path: path)
        try rejects { try duplicate.start { _, reply in reply(Response(message: "wrong server")) } }
        try check(LocalSocket.send(Request(.show), path: path).message == "show", "Second process stole the socket")
        var unsupported = Request(.status)
        unsupported.version = 2
        try check(LocalSocket.send(unsupported, path: path).error?.code == .invalidRequest, "Bad version was accepted")
        // Test malformed and oversized clients without relying on the valid request encoder.
        for bytes in [Data("not json\n".utf8), Data(repeating: 65, count: LocalSocket.maxBytes + 1) + Data([10])] {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let name = Array(path.utf8) + [0]
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: name) }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try check(connected == 0, "Malformed-request client could not connect")
            _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &buffer, buffer.count, 0)
            try check(count > 0, "Malformed request received no response")
            let response = try JSONDecoder().decode(Response.self, from: Data(buffer.prefix(count)))
            try check(response.error?.code == .invalidRequest, "Malformed input was accepted")
        }
    }),
    ("socket restart releases ownership", {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ap-restart-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("control.sock").path
        let first = CommandServer(path: path)
        try first.start { _, reply in reply(Response(message: "first")) }
        first.stop()
        let second = CommandServer(path: path)
        try second.start { _, reply in reply(Response(message: "second")) }
        defer { second.stop() }
        try check(LocalSocket.send(Request(.status), path: path).message == "second", "Restarted server did not own the endpoint")
    }),
    ("private command directory", {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ap-insecure-\(UUID().uuidString.prefix(8))").path
        mkdir(directory, 0o755)
        chmod(directory, 0o755)
        defer { rmdir(directory) }
        try rejects { try LocalSocket.prepareDirectory(directory) }
    })
]
var failures = 0
for (name, test) in tests {
    do { try test(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
print("\(tests.count - failures)/\(tests.count) checks passed")
exit(failures == 0 ? 0 : 1)
