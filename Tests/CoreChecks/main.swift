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
        try check(MediaSelector.remuxFallback(for: hls.source, reason: .unreadableMedia)?.playbackPath == .remux,
                  "HLS format recovery did not use the shared fallback")
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
    ("video enhancement protocol compatibility", {
        let idle = try JSONEncoder().encode(PlaybackSnapshot())
        try check(!String(decoding: idle, as: UTF8.self).contains("videoEnhancement"),
                  "Idle status exposed an enhancement")
        for choice in VideoEnhancement.allCases {
            var status = PlaybackSnapshot()
            status.videoEnhancement = choice
            let data = try JSONEncoder().encode(status)
            try check(JSONDecoder().decode(PlaybackSnapshot.self, from: data).videoEnhancement == choice,
                      "Enhancement choice was lost on the wire")
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
    ("ready timeline ranges and legacy protocol", {
        var snapshot = PlaybackSnapshot()
        snapshot.state = .paused
        snapshot.duration = 120
        snapshot.preparedRanges = [SeekRange(start: 60, end: 72), SeekRange(start: 0, end: 6),
                                   SeekRange(start: 6, end: 12), SeekRange(start: 110, end: 130),
                                   SeekRange(start: .nan, end: 20)]
        try check(PlaybackPolicy.readyRanges(snapshot) == [SeekRange(start: 0, end: 12),
                  SeekRange(start: 60, end: 72), SeekRange(start: 110, end: 120)], "Ready ranges lost gaps or timeline clipping")
        snapshot.preparedRanges?.removeLast()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(PlaybackSnapshot.self, from: data)
        try check(decoded.preparedRanges?.count == 4, "Prepared ranges did not round-trip")
        var legacy = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "preparedRanges")
        let old = try JSONDecoder().decode(PlaybackSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(old.preparedRanges == nil, "Legacy status incorrectly claimed preparation")
        var diagnostics = PlaybackDiagnostics()
        diagnostics.bufferedRanges = [SeekRange(start: 30, end: 40)]
        snapshot.diagnostics = diagnostics
        snapshot.preparedRanges = []
        try check(PlaybackPolicy.readyRanges(snapshot).isEmpty, "Empty preparation fell back to stale player buffering")
        snapshot.preparedRanges = nil
        try check(PlaybackPolicy.readyRanges(snapshot) == diagnostics.bufferedRanges, "Direct player buffering was not shown")
        snapshot.state = .loading
        try check(PlaybackPolicy.readyRanges(snapshot).isEmpty, "Replacement displayed stale progress")
        snapshot.state = .playing
        snapshot.isLive = true
        snapshot.seekableRanges = [SeekRange(start: 35, end: 45)]
        try check(PlaybackPolicy.readyRanges(snapshot) == [SeekRange(start: 35, end: 40)], "Live progress used the wrong timeline origin")
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
    ("shared replacement playback intent", {
        try check(PlaybackPolicy.shouldAutoplayReplacement(pendingPlay: false, playbackRequested: true,
            external: true, playing: false, recoveringReceiver: false), "Buffering lost the requested playback intent")
        try check(PlaybackPolicy.shouldAutoplayReplacement(pendingPlay: false, playbackRequested: false,
            external: true, playing: false, recoveringReceiver: true), "Receiver recovery lost autoplay")
        try check(!PlaybackPolicy.shouldAutoplayReplacement(pendingPlay: false, playbackRequested: false,
            external: true, playing: false, recoveringReceiver: false), "A user-paused replacement autoplayed")
        try check(!PlaybackPolicy.shouldAutoplayReplacement(pendingPlay: false, playbackRequested: true,
            external: false, playing: true, recoveringReceiver: true), "An inactive receiver armed replacement playback")
    }),
    ("shared compatibility recovery boundaries", {
        let url = URL(string: "https://example.test/stream.m3u8")!
        let live = ResolvedSource(url: url, delivery: .hls, isLive: true, conversionPolicy: .allowVideo)
        let finite = ResolvedSource(url: url, delivery: .hls)
        let sampled = StreamingVideoCharacteristics(codec: .hevc, width: 3840, height: 2160,
            bitDepth: 10, transfer: .bt709, delivery: .hls, isLive: true)
        try check(MediaSelector.remuxFallback(for: live, sampledVideo: sampled)?.conversionPolicy == .avoidVideo,
                  "Automatic HEVC HLS recovery allowed video encoding")
        try check(MediaSelector.remuxFallback(for: live, reason: .externalPlaybackUnsupported, hasPlayed: true) != nil,
                  "An established live presentation could not recover a format failure")
        try check(MediaSelector.remuxFallback(for: finite, reason: .unreadableMedia, hasPlayed: true) == nil,
                  "Established finite playback restarted unexpectedly")
        for source in [live, finite] {
            for reason: MediaFailureReason in [.network, .sourceUnavailable, .protectedMedia, .noVideo, .playbackInterrupted] {
                try check(MediaSelector.remuxFallback(for: source, reason: reason) == nil,
                          "A non-format failure enabled remux")
            }
        }
        try check(MediaSelector.shouldInspectCompatibility(of: finite), "Direct HLS skipped compatibility inspection")
        try check(!MediaSelector.shouldInspectCompatibility(of: ResolvedSource(url: url, delivery: .file)),
                  "Known finite file delivery opened a supplemental request")
    }),
    ("finite HLS is not live", {
        try check(!LivePolicy.isLive(sourceDuration: nil, itemDurationIndefinite: false),
                  "A finite HLS item was classified as live")
        try check(LivePolicy.isLive(sourceDuration: nil, itemDurationIndefinite: true),
                  "A live HLS item was classified as on-demand")
        try check(!LivePolicy.isLive(sourceDuration: 20, itemDurationIndefinite: true),
                  "Prepared finite media was classified as live")
    }),
    ("live timeline ignores native latency and moving buffer edges", {
        var live = PlaybackSnapshot()
        live.isLive = true
        live.recommendedLiveOffset = 12
        for edge in [100.0, 102, 104, 106] {
            live.seekableRanges = [SeekRange(start: edge - 60, end: edge)]
            live.position = edge - 14
            live.liveOffset = 14
            try check(LivePolicy.timelinePosition(live) == edge && LivePolicy.positionLabel(live) == "Live",
                      "The live knob follows the moving buffer rather than staying at Live")
        }
        live.liveOffset = 27
        live.position = 79
        try check(LivePolicy.timelinePosition(live) == 79 && LivePolicy.positionLabel(live) == "−0:15",
                  "Real time-shifted playback was hidden as Live")
        live.liveOffset = 12
        try check(LivePolicy.timelinePosition(live, requested: 85) == 85
                  && LivePolicy.positionLabel(live, position: 85) == "−0:09",
                  "Live presentation hid an explicit seek target")
        live.recommendedLiveOffset = .nan
        try check(LivePolicy.delay(live) == 12, "Invalid native latency changed the live delay")
        var finite = PlaybackSnapshot()
        finite.duration = 100; finite.position = 42
        try check(LivePolicy.timelinePosition(finite) == 42 && LivePolicy.delay(finite) == nil,
                  "Live stabilization changed the finite timeline")
    }),
    ("segmented live-edge updates do not move the Live indicator", {
        var previous = PlaybackSnapshot()
        previous.isLive = true; previous.state = .playing
        previous.seekableRanges = [SeekRange(start: 145, end: 3730)]
        previous.position = 3714; previous.liveOffset = 16; previous.recommendedLiveOffset = 15
        for edge in [3735.0, 3740, 3745, 3750] {
            var current = previous
            current.seekableRanges = [SeekRange(start: edge - 3585, end: edge)]
            current.position = edge - 19.5; current.liveOffset = 19.5
            current.liveEdgeUpdateInterval = LivePolicy.edgeUpdateInterval(previous: previous, current: current)
            try check(current.liveEdgeUpdateInterval == 5 && LivePolicy.timelinePosition(current) == edge
                      && LivePolicy.positionLabel(current) == "Live",
                      "Five-second manifest update made the continuous live playhead jump backwards")
            current.liveOffset = 15.5; current.position = edge - 15.5
            current.liveEdgeUpdateInterval = LivePolicy.edgeUpdateInterval(previous: current, current: current)
            try check(LivePolicy.timelinePosition(current) == edge, "Between-update playback lost the live pin")
            previous = current
        }
        previous.position = 3721; previous.liveOffset = 29
        try check(!LivePolicy.isAtLive(previous) && LivePolicy.timelinePosition(previous) == 3721
                  && LivePolicy.positionLabel(previous) == "−0:14", "Manifest tolerance hid actual time-shifted playback")
        try check(LivePolicy.positionLabel(previous, position: 3731) == "−0:04",
                  "Manifest tolerance hid an explicit four-second seek target")
        previous.state = .paused; previous.liveOffset = 19
        try check(!LivePolicy.isAtLive(previous), "Paused playback was hidden by manifest tolerance")
        var reset = previous; reset.isLive = false
        try check(LivePolicy.edgeUpdateInterval(previous: previous, current: reset) == nil,
                  "A replacement retained the previous source's live cadence")
        reset = previous; reset.seekableRanges = [SeekRange(start: 0, end: 100)]
        try check(LivePolicy.edgeUpdateInterval(previous: previous, current: reset) == nil,
                  "A reset live clock retained its old cadence")
    }),
    ("manual HLS rendition selection preserves groups and automatic mode", {
        let master = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",URI="audio.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=426x240,FRAME-RATE=30,CODECS="avc1.64001f,mp4a.40.2",AUDIO="audio",SUBTITLES="subs"
        low.m3u8?token=fixture
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=426x240,FRAME-RATE=30,CODECS="avc1.64001f,mp4a.40.2",AUDIO="audio",SUBTITLES="subs"
        medium.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,FRAME-RATE=30,CODECS="avc1.64001f,mp4a.40.2",AUDIO="audio",SUBTITLES="subs"
        high.m3u8
        """
        let data = Data(master.utf8)
        let variants = HLSRenditions.variants(data)
        try check(variants.count == 3 && Set(variants.map(\.id)).count == 3, "Same-resolution bitrate variants collapsed")
        let pinned = String(decoding: try HLSRenditions.selecting(variants[0], in: data), as: UTF8.self)
        try check(pinned.contains("low.m3u8") && !pinned.contains("medium.m3u8") && !pinned.contains("high.m3u8")
                  && pinned.contains("audio.m3u8") && pinned.contains("subs.m3u8"), "Manual master lost its selected video, audio or subtitles")
        let renewed = HLSRenditions.variants(Data(master.replacingOccurrences(of: "token=fixture", with: "token=renewed").utf8))
        try check(renewed.map(\.id) == variants.map(\.id), "Manual rendition identity depended on expiring addresses")
        try check(HLSRenditions.variants(Data(repeating: 65, count: 1_048_577)).isEmpty, "Unbounded master metadata accepted")
        try check(HLSRenditions.variants(Data("#EXTM3U\n#EXTINF:5,\nsegment.ts".utf8)).isEmpty, "Media playlist became a quality menu")
        do {
            _ = try HLSRenditions.selecting(variants[0], in: Data((master + "\n" + master).utf8))
            throw CheckFailure(message: "Ambiguous rendition was silently pinned")
        } catch is HTTPLoginFailure {}
        let crlf = Data(master.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        let crlfVariants = HLSRenditions.variants(crlf)
        try check(crlfVariants.map(\.id) == variants.map(\.id), "CRLF master hid rendition URIs behind blank lines")
        let crlfPinned = String(decoding: try HLSRenditions.selecting(crlfVariants[0], in: crlf), as: UTF8.self)
        try check(crlfPinned.contains("low.m3u8") && !crlfPinned.contains("medium.m3u8") && !crlfPinned.contains("\r"),
                  "CRLF selection kept a blank URI line")
        let dangling = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=426x240,CODECS=\"avc1.64001f,mp4a.40.2\"\nonly.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS=\"avc1.64001f,mp4a.40.2\"\n".utf8)
        let danglingVariants = HLSRenditions.variants(dangling)
        try check(danglingVariants.count == 1, "A trailing STREAM-INF without a URI became a rendition")
        _ = try HLSRenditions.selecting(danglingVariants[0], in: dangling)
        let url = URL(string: "https://cdn.example/master.m3u8")!
        let automatic = MediaCandidate(source: ResolvedSource(url: url, delivery: .hls), id: "adaptive", height: 1080)
        var fixed = automatic.source; fixed.hlsVariant = variants[0]
        let manual = MediaCandidate(source: fixed, id: variants[0].id, height: 240, bitrate: 600)
        try check(try MediaSelector.select([manual, automatic]).hlsVariant == nil, "Automatic unexpectedly pinned a rendition")
        let selected = try MediaSelector.select([automatic, manual], sourceID: manual.id)
        try check(selected.hlsVariant == variants[0] && selected.withLivePresentation().hlsVariant == variants[0]
                  && selected.withTransportRemux(isLive: true).hlsVariant == variants[0], "Explicit quality was lost during selection or fallback")
    }),
    ("live controls follow actual seek targets", {
        var live = PlaybackSnapshot()
        live.isLive = true; live.state = .playing; live.externalPlaybackActive = true
        live.position = 95; live.liveOffset = 5
        try check(!PlaybackPolicy.canSeek(live) && LivePolicy.timelinePosition(live) == 1,
                  "Live without ranges exposed an interactive or moving timeline")
        live.seekableRanges = [SeekRange(start: 80, end: 100)]
        live.recommendedLiveOffset = 12
        try check(PlaybackPolicy.canSeek(live) && PlaybackPolicy.canSkip(live, by: -10)
                  && !PlaybackPolicy.canSkip(live, by: 10) && PlaybackPolicy.canControl(live),
                  "A short seekable live window lost rewind or allowed seeking beyond the live edge")
        live.position = 85
        try check(!PlaybackPolicy.canSkip(live, by: -10) && PlaybackPolicy.canSkip(live, by: 10),
                  "Directional skips ignored the window start")
        try check(PlaybackPolicy.skipTarget(live, by: -10, position: 90) == 80
                  && PlaybackPolicy.skipTarget(live, by: -10, position: 80) == nil,
                  "Rapid skips ignored the pending seek position or clamped an unavailable target")
        live.seekableRanges = [SeekRange(start: 0, end: 75), SeekRange(start: 80, end: 100)]
        try check(!PlaybackPolicy.canSkip(live, by: -10), "Live skip crossed into an older discontinuous range")
        live.state = .paused
        try check(PlaybackPolicy.canControl(live) && PlaybackPolicy.canSeek(live), "Paused live lost its controls")
        live.seekableRanges = [SeekRange(start: .nan, end: 100)]
        try check(!PlaybackPolicy.canSeek(live) && !PlaybackPolicy.canSkip(live, by: -10), "Invalid live range enabled seek")
        live.seekableRanges = [SeekRange(start: 100, end: 100)]
        try check(!PlaybackPolicy.canSeek(live), "Empty live range enabled seek")
        var finite = PlaybackSnapshot()
        finite.state = .playing; finite.externalPlaybackActive = true; finite.position = 15
        finite.seekableRanges = [SeekRange(start: 0, end: 20), SeekRange(start: 30, end: 100)]
        try check(PlaybackPolicy.canSkip(finite, by: -10) && !PlaybackPolicy.canSkip(finite, by: 10),
                  "Finite skips ignored discontinuous seek ranges")
        guard case .controls(let controls) = MenuModel.elements(for: finite)[2] else {
            throw CheckFailure(message: "Menu controls missing")
        }
        try check(controls.canSkipBackward && !controls.canSkipForward, "Menu skip availability differs from shared policy")
        try check(!PlaybackPolicy.canSkip(finite, by: .infinity), "Nonfinite skip target was allowed")
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
        snapshot.seekableRanges = [SeekRange(start: 30, end: 90)]
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
        snapshot.receiverWaiting = true
        guard case .controls(let waiting) = MenuModel.elements(for: snapshot)[2] else {
            throw CheckFailure(message: "Waiting screen controls were missing")
        }
        try check(waiting.canStop && !waiting.canToggle && !waiting.canSeek,
                  "Waiting screen should allow Stop without user media controls")
        snapshot.receiverWaiting = nil
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
    ("shared-link handoff validates entry and preserves URL data", {
        let target = "https://example.com/watch?v=a%2Fb&token=secret+value#t=12"
        var components = URLComponents()
        components.scheme = "airthrow"
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "url", value: target)]
        let handoff = try MediaHandoff(url: components.url!)
        try check(handoff.sourceURL == target && handoff.autoplay, "Shared URL was decoded twice or play intent was lost")
        try check(MediaHandoff(url: MediaHandoff.url(for: target)).sourceURL == target,
                  "Share encoding changed a signed source URL")
        try check(!MediaHandoff(url: MediaHandoff.url(for: target, autoplay: false)).autoplay,
                  "Paused share encoding requested playback")
        components.host = "open"
        try check(!MediaHandoff(url: components.url!).autoplay, "Shared open unexpectedly requested playback")
        let invalid = [
            "https://play?url=https%3A%2F%2Fexample.com",
            "airthrow://play/path?url=https%3A%2F%2Fexample.com",
            "airthrow://user@play?url=https%3A%2F%2Fexample.com",
            "airthrow://play:80?url=https%3A%2F%2Fexample.com",
            "airthrow://play?url=https%3A%2F%2Fexample.com#extra",
            "airthrow://stop?url=https%3A%2F%2Fexample.com",
            "airthrow://play?url=https%3A%2F%2Fexample.com&url=https%3A%2F%2Fexample.org",
            "airthrow://play?url=https%3A%2F%2Fexample.com&header=secret",
            "airthrow://play?url=file%3A%2F%2F%2Ftmp%2Fvideo.mp4",
            "airthrow://play?url=https%3A%2F%2Fuser%3Asecret%40example.com",
            "airthrow://play?url=https%3A%2F%2Fexample.com%2F%25oops",
            "airthrow://play?url=https%3A%2F%2Fexample.com%2F%0Asecret",
            "airthrow://play?url=%20https%3A%2F%2Fexample.com",
            "airthrow://play?url=https%3A%2F%2Fexample.com%2Fa%20b",
            "airthrow://play?url=https%3A%2F%2Fexample.com%5Cpath",
            "airthrow://play?url=https%253A%252F%252Fexample.com",
            "airthrow://play?url="
        ]
        for input in invalid {
            do {
                _ = try MediaHandoff(url: URL(string: input)!)
                throw CheckFailure(message: "Malformed shared-link handoff accepted")
            } catch let failure as AppFailure {
                try check(failure.code == .invalidRequest && !failure.message.contains("secret"), "Shared-link failure leaked request data")
            }
        }
        components.queryItems = [URLQueryItem(name: "url", value: "https://example.com/" + String(repeating: "x", count: 16_384))]
        try rejects { _ = try MediaHandoff(url: components.url!) }
    }),
    ("explicit CLI open-and-play is additive and scoped", {
        let target = "https://example.com/movie.mp4"
        for args in [["open", "--play", target], ["open", target, "--play", "--json"]] {
            guard case .run(let parsed) = try CLIArguments.parse(args) else {
                throw CheckFailure(message: "Explicit open-and-play did not parse")
            }
            try check(parsed.request.autoplay == true && parsed.request.url == target, "Open-and-play intent was lost")
            let decoded = try JSONDecoder().decode(Request.self, from: JSONEncoder().encode(parsed.request))
            try check(decoded.autoplay == true && decoded.version == 1, "Open-and-play protocol did not round-trip")
        }
        let legacy = try JSONDecoder().decode(Request.self, from: Data(#"{"version":1,"command":"open","url":"https://example.com/movie.mp4"}"#.utf8))
        try check(legacy.autoplay == nil, "Legacy open armed playback")
        for args in [["open", "--play"], ["open", "--play", "--play", target], ["play", "--play"], ["status", "--play"]] {
            try rejects { _ = try CLIArguments.parse(args) }
        }
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
        let wideDirectory = directory.appendingPathComponent("wide-replies")
        let widePath = wideDirectory.appendingPathComponent("control.sock").path
        let body = String(repeating: "q", count: LocalSocket.maxBytes + 4096)
        let wide = CommandServer(path: widePath)
        try wide.start { _, reply in reply(Response(message: body)) }
        defer { wide.stop() }
        try check(LocalSocket.send(Request(.status), path: widePath).message.count == body.count,
                  "Status reply over 32 KB was rejected")
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
        try check(decoded.sources == nil && decoded.selectedSourceID == nil && decoded.audioOptions == nil
                  && decoded.selectedAudioID == nil && decoded.subtitleOptions == nil
                  && decoded.selectedSubtitleID == nil && decoded.allowVideoConversion == nil,
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
        status.audioOptions = [AudioOptionSnapshot(id: "session-audio-0", label: "Italiano - original")]
        status.selectedAudioID = "session-audio-0"
        status.subtitleOptions = [SubtitleOptionSnapshot(id: "session-subtitle-off", label: "Off"),
                                  SubtitleOptionSnapshot(id: "session-subtitle-0", label: "Italiano")]
        status.selectedSubtitleID = "session-subtitle-off"
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
    ("conversion preference default and preparation speed protocol", {
        let suite = "airthrow-conversion-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try check(ConversionPolicy.current(defaults: defaults) == .allowVideo, "Fresh installs avoided video conversion")
        defaults.set(false, forKey: ConversionPolicy.preferenceKey)
        try check(ConversionPolicy.current(defaults: defaults) == .avoidVideo, "Explicit avoidance preference was overwritten")
        let source = ResolvedSource(url: URL(string: "https://example.com/video.mp4")!)
        for choice in [VideoEnhancement.upscale1080, .cleanup1080, .upscale4K, .cleanup4K] {
            try check(source.withEnhancement(choice).conversionPolicy == .avoidVideo,
                      "Enhancement silently authorized video re-encoding")
        }
        defaults.set(true, forKey: ConversionPolicy.preferenceKey)
        try check(ConversionPolicy.current(defaults: defaults) == .allowVideo, "Explicit permission was lost")
        var snapshot = PlaybackSnapshot()
        snapshot.preparationSpeed = 3.2
        snapshot.seekInProgress = true
        let data = try JSONEncoder().encode(snapshot)
        try check(try JSONDecoder().decode(PlaybackSnapshot.self, from: data).preparationSpeed == 3.2,
                  "Preparation speed did not round-trip")
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "preparationSpeed")
        try check(try JSONDecoder().decode(PlaybackSnapshot.self, from: data).seekInProgress == true,
                  "Explicit seek progress did not round-trip")
        old.removeValue(forKey: "seekInProgress")
        try check(try JSONDecoder().decode(PlaybackSnapshot.self,
                  from: JSONSerialization.data(withJSONObject: old)).seekInProgress == nil,
                  "Legacy status invented seek progress")
        try check(try JSONDecoder().decode(PlaybackSnapshot.self,
                  from: JSONSerialization.data(withJSONObject: old)).preparationSpeed == nil,
                  "Legacy status invented preparation speed")
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
