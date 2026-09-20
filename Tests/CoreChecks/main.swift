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
    ("shared media selection and bounded fallback", {
        let file = MediaCandidate(source: ResolvedSource(url: URL(string: "https://cdn.example/video")!, delivery: .file), height: 720)
        let hls = MediaCandidate(source: ResolvedSource(url: URL(string: "https://other.example/master")!, delivery: .hls), height: 720)
        let remux = MediaCandidate(source: ResolvedSource(url: URL(string: "https://third.example/video")!, needsPreparation: true), height: 1080)
        for candidates in [[file, hls, remux], [remux, hls, file], [hls, file, remux]] {
            try check(MediaSelector.select(candidates).url == hls.source.url, "Provider order changed native selection")
        }
        let highFile = MediaCandidate(source: file.source, height: 1080)
        try check(MediaSelector.select([hls, highFile]).url == file.source.url, "HLS overrode higher native quality")
        try check(MediaSelector.select([remux, file]).playbackPath == .direct, "Default unexpectedly prepared higher quality")
        try check(MediaSelector.select([remux]).playbackPath == .remux, "Only usable preparation option was lost")
        let fallback = MediaSelector.remuxFallback(for: file.source, reason: .unreadableMedia)
        try check(fallback?.playbackPath == .remux, "Native format failure did not permit remux inspection")
        try check(MediaSelector.remuxFallback(for: fallback!, reason: .unreadableMedia) == nil, "Preparation retried itself")
        try check(MediaSelector.remuxFallback(for: hls.source, reason: .unreadableMedia) == nil, "Unsupported HLS remux attempted")
        for reason: MediaFailureReason in [.network, .sourceUnavailable, .protectedMedia, .noVideo] {
            try check(MediaSelector.remuxFallback(for: file.source, reason: reason) == nil, "Unrelated failure started remuxing")
        }
    }),
    ("playback path protocol compatibility", {
        let old = try JSONEncoder().encode(PlaybackSnapshot())
        try check(JSONDecoder().decode(PlaybackSnapshot.self, from: old).playbackPath == nil, "Old status required a playback path")
        for path: PlaybackPath in [.direct, .remux] {
            var status = PlaybackSnapshot()
            status.playbackPath = path
            let data = try JSONEncoder().encode(status)
            try check(JSONDecoder().decode(PlaybackSnapshot.self, from: data).playbackPath == path, "Playback path lost on wire")
        }
    }),
    ("signed URL preservation", {
        let value = "https://cdn.example.com/a%2Fb/movie.m3u8?token=a%2Bb%3D&expires=123&x=1&x=2"
        try check(MediaInput.url("  \(value)\n").absoluteString == value, "Signed URL changed")
    }),
    ("invalid URLs", {
        for input in ["", "file:///tmp/movie.mp4", "ftp://example.com/a.mp4", "https:///", "https://name:secret@example.com/a.mp4", "https://example.com/\nmovie.mp4"] {
            try rejects { _ = try MediaInput.url(input) }
        }
    }),
    ("local file validation", {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ap-local-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("example video.mp4")
        try Data("media".utf8).write(to: file)
        let symlink = directory.appendingPathComponent("linked.mov")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        try check(MediaInput.source(file.path) == file.standardizedFileURL, "Absolute local path changed")
        try check(MediaInput.source(file.absoluteString) == file.standardizedFileURL, "File URL changed")
        try check(MediaInput.source(symlink.path) == file.standardizedFileURL, "Local symlink was not resolved")
        try check(MediaInput.source("https://example.com/video.mp4").scheme == "https", "HTTP source stopped working")
        for input in [directory.path, directory.appendingPathComponent("missing.mp4").path,
                      "file://remote.example/tmp/video.mp4", "file:///tmp/video.mp4?token=secret"] {
            try rejects { _ = try MediaInput.source(input) }
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
    ("playlist auto-advance gate", {
        try check(QueuePolicy.shouldAdvanceAfterEnd(hasPlayed: true, externalPlaybackActive: true,
            isProbing: false, hasNext: true), "Completed playing item did not advance")
        for condition in [
            QueuePolicy.shouldAdvanceAfterEnd(hasPlayed: false, externalPlaybackActive: true, isProbing: false, hasNext: true),
            QueuePolicy.shouldAdvanceAfterEnd(hasPlayed: true, externalPlaybackActive: false, isProbing: false, hasNext: true),
            QueuePolicy.shouldAdvanceAfterEnd(hasPlayed: true, externalPlaybackActive: true, isProbing: true, hasNext: true),
            QueuePolicy.shouldAdvanceAfterEnd(hasPlayed: true, externalPlaybackActive: true, isProbing: false, hasNext: false)
        ] { try check(!condition, "Playlist advanced without a genuine routed playback end") }
    }),
    ("finite HLS is not live", {
        try check(!LivePolicy.isLive(sourceDuration: nil, itemDurationIndefinite: false),
                  "A finite HLS item was classified as live")
        try check(LivePolicy.isLive(sourceDuration: nil, itemDurationIndefinite: true),
                  "A live HLS item was classified as on-demand")
        try check(!LivePolicy.isLive(sourceDuration: 20, itemDurationIndefinite: true),
                  "Prepared finite media was classified as live")
    }),
    ("shared control policy, labels and time formatting", {
        var snapshot = PlaybackSnapshot()
        snapshot.state = .ready
        try check(!PlaybackPolicy.canControl(snapshot), "Control enabled without a route")
        snapshot.externalPlaybackActive = true
        try check(PlaybackPolicy.canControl(snapshot) && !PlaybackPolicy.canSeek(snapshot),
                  "Control or seek policy disagreed with the snapshot")
        snapshot.seekableRanges = [SeekRange(start: 0, end: 10), SeekRange(start: 30, end: 50)]
        try check(PlaybackPolicy.activeSeekRange(snapshot) == SeekRange(start: 0, end: 10),
                  "Finite media did not use its first seek range")
        snapshot.isLive = true
        try check(PlaybackPolicy.activeSeekRange(snapshot) == SeekRange(start: 30, end: 50),
                  "Live media did not use its newest seek range")
        snapshot.state = .buffering
        try check(PlaybackPolicy.isPlaying(snapshot) && PlaybackPolicy.canSeek(snapshot),
                  "Buffering control state was wrong")
        snapshot.state = .loading
        snapshot.loadingPhase = "preparing"
        try check(PlaybackPolicy.stateLabel(snapshot) == "Preparing video…", "Preparing label was wrong")
        snapshot.loadingPhase = "resolving"
        try check(PlaybackPolicy.stateLabel(snapshot) == "Finding video…", "Resolving label was wrong")
        try check(PlaybackFormat.time(3661) == "1:01:01" && PlaybackFormat.time(nil) == "—:—",
                  "Shared time format was wrong")
    }),
    ("menu model follows playback and playlist state", {
        var snapshot = PlaybackSnapshot()
        snapshot.title = "clip.mp4"
        var elements = MenuModel.elements(for: snapshot)
        try check(elements.count == 6, "Unexpected menu element count")
        try check(elements[0] == .card(title: "clip.mp4", status: "AirPlay not connected"),
                  "Idle menu card was wrong")
        guard case .controls(let idle) = elements[2] else {
            throw CheckFailure(message: "Menu control row was missing")
        }
        try check(idle == MenuControlState(isPlaying: false, canToggle: false, canStop: false,
                                           canSeek: false, playlist: nil),
                  "Idle menu controls were wrong")
        snapshot.state = .paused
        snapshot.externalPlaybackActive = true
        snapshot.position = 83
        snapshot.duration = 296
        snapshot.seekableRanges = [SeekRange(start: 0, end: 296)]
        snapshot.queue = PlaybackQueueSnapshot(title: "Queue", currentIndex: 1,
            items: [QueueItemSnapshot(title: "One", state: .pending),
                    QueueItemSnapshot(title: "Two", state: .current),
                    QueueItemSnapshot(title: "Three", state: .pending)], truncated: false)
        elements = MenuModel.elements(for: snapshot)
        try check(elements[0] == .card(title: "clip.mp4", status: "Paused · 1:23 / 4:56"),
                  "Paused menu card was wrong")
        guard case .controls(let paused) = elements[2] else {
            throw CheckFailure(message: "Playlist control row was missing")
        }
        try check(paused.playlist == MenuPlaylistControls(canPrevious: true, canNext: true),
                  "Playlist navigation enablement was wrong")
        try check(MenuModel.controlCommands(for: paused) ==
                  [.previous, .skipBackward, .togglePlayback, .stop, .skipForward, .next],
                  "Playlist control order was wrong")
        snapshot.state = .loading
        elements = MenuModel.elements(for: snapshot)
        guard case .controls(let loading) = elements[2] else {
            throw CheckFailure(message: "Loading control row was missing")
        }
        try check(loading.playlist == MenuPlaylistControls(canPrevious: false, canNext: false),
                  "Playlist navigation stayed enabled while loading")
        try check(elements[4] == .command(.showController) && elements[5] == .command(.quit),
                  "Menu footer was wrong")
    }),
    ("wire protocol and URL privacy", {
        let request = Request(.open, url: "https://example.com/video.mp4?token=private")
        let decoded = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(request))
        try check(decoded.version == 1 && decoded.url == request.url, "Request round-trip failed")
        let response = Response(message: "Loading", pending: true, status: PlaybackSnapshot())
        let data = try JSONEncoder().encode(response)
        try check(!String(decoding: data, as: UTF8.self).contains("token"), "Status leaked URL")
        try check(JSONDecoder().decode(Response.self, from: data).pending, "Pending response was lost")
        var queueStatus = PlaybackSnapshot()
        queueStatus.queue = PlaybackQueueSnapshot(title: "Example", currentIndex: 0,
            items: [QueueItemSnapshot(title: "First", state: .current)], truncated: false)
        let queueData = try JSONEncoder().encode(queueStatus)
        try check(try JSONDecoder().decode(PlaybackSnapshot.self, from: queueData).queue?.items.count == 1,
                  "Queue status did not round-trip")
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
