import Foundation
import Darwin
import AirThrowCore

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
        // In-place delivery never consumes the prepared-media budget, so a
        // receiver-compatible local file is not bounded by the preparation size
        // limit. The sparse file costs no disk space.
        let large = directory.appendingPathComponent("large.mp4")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(3) * 1024 * 1024 * 1024)
        try handle.close()
        try check(MediaInput.source(large.path) == large.standardizedFileURL, "Large local file was rejected for in-place delivery")
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
        var finite = PlaybackSnapshot()
        finite.duration = 100
        try check(PlaybackPolicy.activeSeekRange(finite) == SeekRange(start: 0, end: 100),
                  "A known finite duration did not define a stable timeline")
        finite.seekableRanges = [SeekRange(start: 0, end: 10)]
        try check(PlaybackPolicy.activeSeekRange(finite) == SeekRange(start: 0, end: 100),
                  "A partial seek range overrode the known finite duration")
        var durationOnly = PlaybackSnapshot()
        durationOnly.state = .ready
        durationOnly.duration = 100
        durationOnly.externalPlaybackActive = true
        try check(PlaybackPolicy.activeSeekRange(durationOnly) == SeekRange(start: 0, end: 100) && !PlaybackPolicy.canSeek(durationOnly),
                  "canSeek allowed seek with empty seekableRanges despite known duration")
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
    }),
    ("source option protocol privacy and compatibility", {
        // A protocol-v1 status that predates the chooser fields still decodes, and
        // the new fields stay absent rather than being invented.
        let legacy = Data(#"{"state":"idle","externalPlaybackActive":false,"seekableRanges":[],"title":"No video loaded","isLive":false}"#.utf8)
        let decoded = try JSONDecoder().decode(PlaybackSnapshot.self, from: legacy)
        try check(decoded.sources == nil && decoded.selectedSourceID == nil && decoded.allowVideoConversion == nil,
                  "Legacy status invented source chooser fields")
        var status = PlaybackSnapshot()
        status.playbackPath = .remux
        status.sources = [
            SourceOptionSnapshot(id: "session-0", quality: "1080p maximum (adaptive)", audio: "English",
                                 playbackPath: .remux, unavailableReason: nil),
            SourceOptionSnapshot(id: "session-1", quality: "Quality unknown", audio: nil,
                                 playbackPath: .videoConversion,
                                 unavailableReason: "Video conversion is off.")
        ]
        status.selectedSourceID = "session-1"
        status.allowVideoConversion = true
        let data = try JSONEncoder().encode(status)
        try check(try JSONDecoder().decode(PlaybackSnapshot.self, from: data) == status,
                  "Source chooser status did not round-trip")
        // The presentation list is session-scoped and URL-free by construction.
        let encoded = String(decoding: data, as: UTF8.self)
        for leaked in ["http", "://", "token", "Authorization", "provider", ".com"] {
            try check(!encoded.contains(leaked), "Source status leaked \(leaked)")
        }
    }),
    ("candidate identity is URL-free", {
        // Identity is an opaque hash of presentation metadata. It must never leak a
        // URL, query, header or title, and it must stay stable when only the
        // expiring media URL or request headers change. Provider identifiers
        // survive only when an adapter supplies them explicitly.
        let signed = URL(string: "https://cdn.example.com/private/movie.mp4?token=secret-value")!
        let derived = MediaCandidate(
            source: ResolvedSource(url: signed, title: "Example", headers: ["Authorization": "secret-value"],
                                   delivery: .hls),
            height: 1080, audioDescription: "English")
        for leaked in ["cdn.example.com", "secret-value", "movie", "private", "Example", "English", "://", "/"] {
            try check(!derived.id.contains(leaked), "Candidate identity leaked \(leaked)")
        }
        try check(derived.id == derived.id.lowercased(), "Candidate identity was not normalized")
        let rotated = MediaCandidate(
            source: ResolvedSource(url: URL(string: "https://other.example.net/x/y.m3u8?t=rotated")!,
                                   title: "Example", delivery: .hls),
            height: 1080, audioDescription: "English")
        try check(derived.id == rotated.id, "Candidate identity changed with only the URL and headers")
        let differentQuality = MediaCandidate(source: ResolvedSource(url: signed, title: "Example", delivery: .hls),
                                              height: 720, audioDescription: "English")
        let differentAudio = MediaCandidate(source: ResolvedSource(url: signed, title: "Example", delivery: .hls),
                                            height: 1080, audioDescription: "Spanish")
        try check(derived.id != differentQuality.id && derived.id != differentAudio.id,
                  "Candidate identity ignored presentation metadata")
        let explicit = MediaCandidate(source: ResolvedSource(url: signed), id: "format-299", height: 1080)
        try check(explicit.id == "format-299", "Explicit adapter identity was replaced")
    }),
    ("CLI arguments parse source commands and JSON", {
        guard case .run(let sources) = try CLIArguments.parse(["sources"]) else {
            throw CheckFailure(message: "sources did not parse")
        }
        try check(sources.command == .sources && sources.request.command == .sources,
                  "sources command was lost")
        try check(sources.showsSources && !sources.json, "sources metadata was wrong")

        guard case .run(let jsonSources) = try CLIArguments.parse(["sources", "--json"]) else {
            throw CheckFailure(message: "sources --json did not parse")
        }
        try check(jsonSources.json && jsonSources.showsSources, "--json was not captured for sources")

        guard case .run(let source) = try CLIArguments.parse(["source", "automatic"]) else {
            throw CheckFailure(message: "source did not parse")
        }
        try check(source.request.sourceID == "automatic", "source id was not forwarded")
        try check(!source.showsSources && !source.json, "source metadata was wrong")

        guard case .run(let boundary) = try CLIArguments.parse(["source", String(repeating: "a", count: CLIArguments.sourceIDLimit)]) else {
            throw CheckFailure(message: "boundary source id was rejected")
        }
        try check(boundary.request.sourceID?.utf8.count == CLIArguments.sourceIDLimit,
                  "boundary source id changed")

        for invalid in [["sources", "extra"], ["source"], ["source", "id", "extra"], ["source", ""],
                        ["source", String(repeating: "a", count: CLIArguments.sourceIDLimit + 1)],
                        ["unknown"], ["--json"], ["status", "extra"]] {
            try rejects { _ = try CLIArguments.parse(invalid) }
        }
    }),
    ("CLI arguments parse conversion and shared flags", {
        guard case .run(let allow) = try CLIArguments.parse(["conversion", "allow-video"]) else {
            throw CheckFailure(message: "conversion allow-video did not parse")
        }
        try check(allow.request.allowVideoConversion == true && allow.command == .conversion,
                  "allow-video was not captured")

        guard case .run(let avoid) = try CLIArguments.parse(["conversion", "avoid-video"]) else {
            throw CheckFailure(message: "conversion avoid-video did not parse")
        }
        try check(avoid.request.allowVideoConversion == false, "avoid-video was not captured")

        for valid in [["conversion", "allow-video", "--json"], ["--json", "conversion", "avoid-video"],
                      ["status", "--json"], ["play", "--json"]] {
            guard case .run(let parsed) = try CLIArguments.parse(valid) else {
                throw CheckFailure(message: "\(valid) did not parse")
            }
            try check(parsed.json, "\(valid) lost the --json flag")
        }

        for invalid in [["conversion"], ["conversion", "maybe"],
                        ["conversion", "allow-video", "extra"], ["conversion", "--json"]] {
            try rejects { _ = try CLIArguments.parse(invalid) }
        }
    }),
    ("CLI arguments preserve help, open, and seek behavior", {
        for help in [[], ["--help"], ["-h"], ["status", "--help"], ["open", "--help"]] {
            guard case .help = try CLIArguments.parse(help) else {
                throw CheckFailure(message: "\(help) did not request help")
            }
        }

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent(".build/cli-args-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = FileManager.default.currentDirectoryPath
        defer {
            FileManager.default.changeCurrentDirectoryPath(original)
            try? FileManager.default.removeItem(at: directory)
        }
        let name = "clip \(UUID().uuidString.prefix(6)).mp4"
        let file = directory.appendingPathComponent(name)
        try Data("media".utf8).write(to: file)
        let expected = file.standardizedFileURL.resolvingSymlinksInPath().path
        try check(FileManager.default.changeCurrentDirectoryPath(directory.path),
                  "Could not enter the fixture directory")

        guard case .run(let relative) = try CLIArguments.parse(["open", name]) else {
            throw CheckFailure(message: "relative open did not parse")
        }
        try check(relative.request.url == expected, "Relative path was not resolved before sending")

        guard case .run(let absolute) = try CLIArguments.parse(["open", file.path]) else {
            throw CheckFailure(message: "absolute open did not parse")
        }
        try check(absolute.request.url == expected, "Local path was not resolved")

        guard case .run(let remote) = try CLIArguments.parse(["open", "https://example.com/video.mp4?token=x"]) else {
            throw CheckFailure(message: "remote open did not parse")
        }
        try check(remote.request.url == "https://example.com/video.mp4?token=x", "Remote URL changed")
        try rejects { _ = try CLIArguments.parse(["open"]) }
        try rejects { _ = try CLIArguments.parse(["open", file.path, "extra"]) }
        try rejects { _ = try CLIArguments.parse(["open", directory.appendingPathComponent("missing.mp4").path]) }

        guard case .run(let seek) = try CLIArguments.parse(["seek", "12.5"]) else {
            throw CheckFailure(message: "seek did not parse")
        }
        try check(seek.request.seconds == 12.5, "Seek seconds were not forwarded")
        guard case .run(let zero) = try CLIArguments.parse(["seek", "0"]) else {
            throw CheckFailure(message: "zero seek did not parse")
        }
        try check(zero.request.seconds == 0, "Zero seek was not accepted")
        for invalid in [["seek"], ["seek", "-1"], ["seek", "abc"], ["seek", "nan"], ["seek", "inf"], ["seek", "1", "extra"]] {
            try rejects { _ = try CLIArguments.parse(invalid) }
        }
    })
]
var failures = 0
for (name, test) in tests {
    do { try test(); print("PASS \(name)") }
    catch { failures += 1; print("FAIL \(name): \(error)") }
}
print("\(tests.count - failures)/\(tests.count) checks passed")
exit(failures == 0 ? 0 : 1)
