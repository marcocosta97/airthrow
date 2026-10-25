import Foundation
import AVFoundation

private struct Failure: Error { let message: String }
private actor RemuxInputRecorder {
    var input: ResolvedSource?
    var count = 0
    func record(_ source: ResolvedSource) { input = source; count += 1 }
}
private actor ProbeCounter {
    var count = 0
    func record() { count += 1 }
}
private final class RoutedItem: AVPlayerItem, @unchecked Sendable {
    override var tracks: [AVPlayerItemTrack] { [] }
    override var presentationSize: CGSize { .zero }
}
private final class ReceiverPlayer: AVPlayer, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var requestedRate: Float = 0
    nonisolated(unsafe) private var ignoredPlays = 0
    nonisolated(unsafe) private var playRequests = 0
    nonisolated(unsafe) private var seekRequests = 0
    nonisolated(unsafe) private var pauseRequests = 0
    nonisolated(unsafe) private var buffering = false
    override var isExternalPlaybackActive: Bool { true }
    override func currentTime() -> CMTime { .zero }
    override var rate: Float { get { lock.withLock { requestedRate } } set { lock.withLock { requestedRate = newValue } } }
    override var timeControlStatus: AVPlayer.TimeControlStatus { rate > 0 ? .playing : (lock.withLock { buffering } ? .waitingToPlayAtSpecifiedRate : .paused) }
    override func play() {
        lock.withLock {
            playRequests += 1
            if ignoredPlays > 0 { ignoredPlays -= 1 } else { requestedRate = 1 }
        }
    }
    var playCount: Int { lock.withLock { playRequests } }
    var seekCount: Int { lock.withLock { seekRequests } }
    var pauseCount: Int { lock.withLock { pauseRequests } }
    func setBuffering(_ value: Bool) { lock.withLock { buffering = value } }
    func ignoreNextPlays(_ count: Int) { lock.withLock { ignoredPlays = count } }
    override func pause() { lock.withLock { requestedRate = 0; pauseRequests += 1 } }
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        lock.withLock { seekRequests += 1 }
        completionHandler?(true)
    }
}

@main
struct IPTVChecks {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL \(error)"); exit(1) }
    }
    @MainActor static func run() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let local = CommandLine.arguments[2]
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure(message: message) }
            checks += 1; FileHandle.standardOutput.write(Data("PASS \(message)\n".utf8))
        }
        func parse(_ text: String) throws -> IPTVCatalog { try IPTVPlaylist.parse(Data(text.utf8), baseURL: base) }
        func rejects(_ data: Data, reason: IPTVCatalogFailure, _ message: String) throws {
            do { _ = try IPTVPlaylist.parse(data); throw Failure(message: message) }
            catch let error as IPTVCatalogFailure { try check(String(describing: error) == String(describing: reason), message) }
        }
        let sensitiveTimeout = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
            userInfo: [NSURLErrorFailingURLStringErrorKey: "http://example.test/get.php?password=private-value"])
        try check(IPTVCatalogFailure.message(for: sensitiveTimeout) == IPTVCatalogFailure.timedOut.message
                  && !IPTVCatalogFailure.message(for: sensitiveTimeout).contains("private-value"),
                  "Playlist timeout is actionable without exposing source credentials")
        try check(IPTVCatalogFailure.message(for: URLError(.appTransportSecurityRequiresSecureConnection)) == IPTVCatalogFailure.connectionBlocked.message,
                  "Packaged transport block has a distinct recovery message")
        let queryCatalog = URL(string: base.absoluteString + "/get.php?username=fixture%2Buser&password=fixture%26pass%3Dword&type=m3u_plus&output=ts")!
        let xtreamURL = try XtreamPlaylist.url(server: base.absoluteString, username: "fixture+user", password: "fixture&pass=word")
        try check(xtreamURL.path == "/get.php" && xtreamURL.port == base.port
                  && xtreamURL.query == "username=fixture%2Buser&password=fixture%26pass%3Dword&type=m3u_plus&output=m3u8",
                  "Xtream server details build an HLS catalog URL with escaped credentials")
        try check(try XtreamPlaylist.url(server: base.absoluteString + "/", username: "fixture+user", password: "fixture&pass=word", format: .transportStream) == queryCatalog,
                  "Xtream MPEG-TS choice preserves the explicit server scheme and port")
        let prefixed = try XtreamPlaylist.url(server: "https://example.test/service%20tv/", username: " user+&é ", password: "p%?#/+=")
        let prefixedComponents = URLComponents(url: prefixed, resolvingAgainstBaseURL: false)!
        try check(prefixedComponents.percentEncodedPath == "/service%20tv/get.php"
                  && prefixedComponents.queryItems?.first(where: { $0.name == "username" })?.value == " user+&é "
                  && prefixedComponents.queryItems?.first(where: { $0.name == "password" })?.value == "p%?#/+=",
                  "Xtream preserves reverse-proxy paths, Unicode and exact credential values")
        try check(try XtreamPlaylist.url(server: "example.test:8443", username: "user", password: "pass").scheme == "https",
                  "Xtream server without a scheme defaults to HTTPS")
        for server in ["", "ftp://example.test", "http://user:pass@example.test", "https://example.test/get.php", "https://example.test?token=x", "https://example.test#fragment", "https://example.test:70000"] {
            do { _ = try XtreamPlaylist.url(server: server, username: "user", password: "pass"); throw Failure(message: "Invalid Xtream server accepted") }
            catch is AppFailure { try check(true, "Invalid Xtream server rejected with a recoverable error") }
        }
        for credentials in [("", "pass"), ("  ", "pass"), ("user", ""), ("user", "pass\n"), ("user", String(repeating: "x", count: 4097))] {
            do { _ = try XtreamPlaylist.url(server: base.absoluteString, username: credentials.0, password: credentials.1); throw Failure(message: "Invalid Xtream credentials accepted") }
            catch is AppFailure { try check(true, "Empty, multiline or oversized Xtream credentials rejected") }
        }
        let basicQueryCatalog = URL(string: queryCatalog.absoluteString.replacingOccurrences(of: "type=m3u_plus", with: "type=m3u"))!
        try check(IPTVPlaylist.isCatalogSource(queryCatalog) && IPTVPlaylist.isCatalogSource(basicQueryCatalog),
                  "M3U download query selects catalog import without a file extension")
        try check(IPTVPlaylist.isCatalogSource(URL(string: "https://example.test/download?output=ts&type=m3u_plus")!),
                  "Catalog query detection is independent of host, endpoint and parameter order")
        try check(!IPTVPlaylist.isCatalogSource(URL(string: "https://example.test/get.php?type=ts")!)
                  && !IPTVPlaylist.isCatalogSource(URL(string: "https://example.test/get.php?type=m3u_plus&type=ts")!)
                  && !IPTVPlaylist.isCatalogSource(URL(string: "https://example.test/live.m3u8")!),
                  "Video, ambiguous query and ordinary remote HLS retain media routing")
        try check(IPTVPlaylist.isCatalogSource(URL(fileURLWithPath: "/fixture/catalog.m3u8"))
                  && IPTVPlaylist.isCatalogSource(URL(string: "https://example.test/catalog.M3U")!),
                  "Existing local and remote catalog extensions retain import routing")
        let text = """
        \u{feff}#EXTM3U
        #PLAYLIST:Fixture TV
        #EXTINF:-1 tvg-name="Fallback" group-title="News, local",News One, HD
        /video.mp4?token=a%2Bb%26c
        #EXTINF:-1 group-title="Sports",
        /video.mp4
        #EXTINF:-1 tvg-name="Café" group-title="News, local",
        /video.mp4
        #EXTINF:-1,Uncategorized
        /video.mp4
        """
        let catalog = try parse(text)
        try check(catalog.title == "Fixture TV" && catalog.channels.count == 4 && catalog.channels[0].name == "News One, HD", "Extended metadata, BOM and comma-aware titles")
        try check(catalog.channels[0].url.query == "token=a%2Bb%26c", "Signed query unchanged")
        try check(catalog.categories == ["News, local", "Sports"] && catalog.channels(category: "News, local").count == 2, "Categories and filtering")
        try check(catalog.channels(category: "", search: "").count == 1 && catalog.channels(search: "cafe").count == 1, "Uncategorized and accent-insensitive search")
        try check(catalog.channels(search: "NEWS HD").count == 1 && catalog.channels(search: "not found").isEmpty, "Multi-word and empty-result search")
        try check(catalog.channels[1].name == "Channel 2", "Unnamed channel has a safe numbered label")
        let named = try parse("#EXTM3U\n#EXTINF:-1 tvg-name=\"Headline\" group-title=\"News\"\n/video.mp4\n")
        try check(named.channels.count == 1 && named.channels[0].name == "Headline" && named.channels[0].category == "News",
                  "EXTINF without a comma uses tvg-name")
        let quoted = try parse("#EXTM3U\n#EXTINF:-1 tvg-name='Evening' group-title='News, local'\n/video.mp4\n")
        try check(quoted.channels.count == 1 && quoted.channels[0].name == "Evening" && quoted.channels[0].category == "News, local",
                  "Single-quoted M3U attributes are read")
        let duplicates = try parse("#EXTM3U\n#EXTINF:-1,First\n/video.mp4\n#EXTINF:-1,Second\n/video.mp4\n")
        try check(duplicates.channels.count == 2 && duplicates.channels[0].id != duplicates.channels[1].id, "Duplicate stream URLs retain distinct channel identities")
        let replaced = try parse(text)
        try check(catalog.channels[0].id != replaced.channels[0].id, "Old channel identities cannot target a new import")
        let skipped = try parse("#EXTM3U\n#EXTINF:-1,Bad\nfile:///etc/passwd\n#EXTINF:-1,Credentials\nhttp://user:pass@example.test/video\n#EXTINF:-1,Headers\n#EXTVLCOPT:http-user-agent=custom\n/video.mp4\n#EXTINF:-1,Good\n/video.mp4\n")
        try check(skipped.channels.count == 1 && skipped.skippedEntries == 3, "Unsafe URLs and required custom headers are skipped visibly")
        try rejects(Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n".utf8), reason: .hlsPlaylist, "HLS stream manifests are not catalogs")
        try rejects(Data("<html>not a playlist</html>".utf8), reason: .invalid, "HTML is refused")
        try rejects(Data(repeating: 65, count: IPTVPlaylist.maximumBytes + 1), reason: .tooLarge, "Import byte budget enforced")
        let grouped = try parse("#EXTM3U\n#EXTINF:-1,One\n#EXTGRP:Music\n/video.mp4\n#EXTINF:-1,Two\n/video.mp4\n")
        try check(grouped.channels.allSatisfy { $0.category == "Music" }, "EXTGRP groups preserved")
        let plain = try IPTVPlaylist.parse(Data("https://example.test/video.mp4\nhttps://example.test/second.mp4\n".utf8))
        try check(plain.channels.count == 2, "Basic M3U lists supported")
        let ansi = "#EXTM3U\n#EXTINF:-1,Café\nhttps://example.test/video.mp4\n".data(using: .windowsCP1252)!
        try check(try IPTVPlaylist.parse(ansi).channels[0].name == "Café", "Legacy M3U text encoding")
        let oversizedCatalog = "#EXTM3U\n" + Array(repeating: "#EXTINF:-1,Channel\nhttps://example.test/video.mp4\n", count: IPTVPlaylist.maximumChannels + 1).joined()
        let bounded = try IPTVPlaylist.parse(Data(oversizedCatalog.utf8))
        try check(bounded.truncated && bounded.channels.count == IPTVPlaylist.maximumChannels, "Large catalogs truncate with an explicit signal")
        let fromFile = try await IPTVCatalogLoader.load(URL(fileURLWithPath: local))
        try check(fromFile.channels.count == 3, "Local file import")
        let relativeDirectory = URL(fileURLWithPath: local).deletingLastPathComponent()
        let relativeFile = relativeDirectory.appendingPathComponent("relative-catalog.m3u")
        try Data([0]).write(to: relativeDirectory.appendingPathComponent("channel.mp4"))
        try "#EXTM3U\n#EXTINF:-1,Local\nchannel.mp4\n".write(to: relativeFile, atomically: true, encoding: .utf8)
        let relative = try await IPTVCatalogLoader.load(relativeFile)
        try check(relative.channels.count == 1 && relative.channels[0].url.isFileURL && relative.channels[0].url.lastPathComponent == "channel.mp4",
                  "A local catalog resolves entries beside the file")
        let suite = "it.mcosta.airthrow.history-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyCredentials = MemoryMediaHistoryCredentials()
        let store = MediaHistoryStore(defaults: defaults, credentials: historyCredentials)
        let signed = base.appendingPathComponent("video.mp4").appending(queryItems: [URLQueryItem(name: "token", value: "a+b&c")])
        store.record(signed, title: "Signed video", kind: .video)
        let savedID = store.entries[0].id
        store.record(signed, title: "Updated video", kind: .video)
        try check(store.entries.count == 1 && store.entries[0].id == savedID && store.entries[0].title == "Updated video", "History deduplicates sources while retaining stable identity")
        try check(MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries.first?.url == signed, "History survives relaunch and preserves the original signed URL")
        store.record(URL(string: "http://user:password@example.test/video")!, title: "Unsafe", kind: .video)
        try check(store.entries.count == 1, "History refuses embedded credentials")
        store.remove(savedID)
        try check(MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries.isEmpty, "Removing one history entry persists")
        store.record(signed, title: "Video", kind: .video)
        store.clear()
        try check(MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries.isEmpty, "Clear History persists across relaunch")
        let missingFile = URL(fileURLWithPath: local).deletingLastPathComponent().appendingPathComponent("remembered.mp4")
        try Data([0]).write(to: missingFile)
        store.record(missingFile, title: "Local video", kind: .video)
        try FileManager.default.removeItem(at: missingFile)
        try check(MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries.first?.url == missingFile,
                  "Missing local files remain visible and removable in persisted history")
        store.clear()
        for index in 0...MediaHistoryStore.maximumEntries {
            store.record(base.appendingPathComponent("video-\(index).mp4"), title: "Video \(index)", kind: .video)
        }
        try check(MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries.count == MediaHistoryStore.maximumEntries
                  && store.entries.first?.title == "Video 100", "History keeps a bounded recent list across relaunch")
        store.clear()
        store.record(signed, title: "Pinned video", kind: .video)
        let pinnedID = store.entries[0].id
        store.togglePin(pinnedID)
        let newerURL = base.appendingPathComponent("newer.mp4")
        store.record(newerURL, title: "Newer video", kind: .video)
        try check(store.entries.first?.id == pinnedID && store.entries.last?.url == newerURL,
                  "Pinned history stays above newer unpinned sources")
        try check(MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries.first?.isPinned == true,
                  "Pin status and ordering survive relaunch")
        store.record(signed, title: "Reopened pinned video", kind: .video)
        try check(store.entries.first?.id == pinnedID && store.entries.first?.isPinned == true,
                  "Reopening a pinned source preserves its pin and identity")
        store.clear()
        try check(MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries.map(\.id) == [pinnedID],
                  "Clear History removes recent entries and persists pinned sources")
        store.record(newerURL, title: "Newer video", kind: .video)
        store.togglePin(pinnedID)
        try check(store.entries.first?.url == newerURL && !store.entries.last!.isPinned,
                  "Unpin restores normal recency ordering")
        store.togglePin(pinnedID)
        for index in 0...MediaHistoryStore.maximumEntries {
            store.record(base.appendingPathComponent("recent-\(index).mp4"), title: "Recent \(index)", kind: .video)
        }
        try check(MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries.count == MediaHistoryStore.maximumEntries
                  && store.entries.first?.id == pinnedID,
                  "History capacity never evicts a pinned source for new recent entries")
        store.remove(pinnedID)
        try check(!MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries.contains(where: { $0.id == pinnedID }),
                  "Explicit removal can delete a pinned entry")
        // Simulate the persisted schema before pin support.
        let encoded = try JSONEncoder().encode(store.entries)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        for index in legacy.indices { legacy[index].removeValue(forKey: "isPinned") }
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "mediaHistory.v1")
        let migrated = MediaHistoryStore(defaults: defaults, credentials: historyCredentials).entries
        try check(migrated.count == store.entries.count && migrated.allSatisfy { !$0.isPinned },
                  "Existing saved history loads without losing entries when pin fields are absent")
        let liveURL = base.appendingPathComponent("live.m3u8")
        let evidence = await HLSVideoEvidence.hasVideo(at: liveURL)
        try check(evidence, "Video evidence from a live media playlist without codec metadata")
        let transport = await HLSVideoEvidence.inspectTransportVideo(at: liveURL)
        try check(transport?.codec == .h264 && transport?.container == .mpegts
                  && transport?.width == 320 && transport?.height == 180,
                  "Bounded transport sample identifies actual codec and dimensions")
        let hevc = await HLSVideoEvidence.inspectTransportVideo(at: base.appendingPathComponent("hevc.m3u8"))
        try check(hevc?.codec == .hevc && hevc?.bitDepth == 10 && hevc?.transfer == .smpte2084,
                  "HEVC transport inspection preserves only technical HDR characteristics")
        let directHEVC = await HLSVideoEvidence.inspectTransportVideo(at: base.appendingPathComponent("hevc.ts"))
        try check(directHEVC?.codec == hevc?.codec && directHEVC?.bitDepth == hevc?.bitDepth
                  && directHEVC?.delivery == .transportStream && hevc?.delivery == .hls,
                  "Inspection recognizes direct MPEG-TS without a playlist extension")
        try check(hevc?.profile == .main10 && hevc?.chroma == .yuv420 && hevc?.level != nil,
                  "HEVC sample exposes whitelisted profile, chroma and numeric level")
        let unsafeProbe = Data(#"{"streams":[{"codec_name":"hevc","width":-1,"height":999999,"pix_fmt":"private-value","color_transfer":"private-value","profile":"private-value","level":999999,"tags":{"title":"private-value"}}]}"#.utf8)
        let filtered = HLSVideoEvidence.decodeTransportCharacteristics(unsafeProbe)
        try check(filtered?.width == nil && filtered?.height == nil && filtered?.bitDepth == nil
                  && filtered?.transfer == nil && filtered?.profile == nil && filtered?.chroma == nil
                  && filtered?.level == nil && !(String(data: try JSONEncoder().encode(filtered), encoding: .utf8)!.contains("private-value")),
                  "Technical diagnostics reject arbitrary text and invalid dimensions")
        try check(await HLSVideoEvidence.inspectTransportVideo(at: base.appendingPathComponent("audio-only.m3u8")) == nil,
                  "Audio-only transport yields no video characteristics")
        let noRangeAsset = AVURLAsset(url: base.appendingPathComponent("no-range.ts"))
        let noRangeTracks = try? await noRangeAsset.loadTracks(withMediaType: .video)
        try check(noRangeTracks?.isEmpty != false, "Fixture reproduces rejected remote segment inspection")
        try check(await HLSVideoEvidence.hasVideo(at: base.appendingPathComponent("no-range.m3u8")), "Video evidence survives an origin that ignores segment byte ranges")
        try check(!(await HLSVideoEvidence.hasVideo(at: base.appendingPathComponent("audio-only.m3u8"))), "Audio-only media playlists never supply video evidence")
        let liveAsset = AVURLAsset(url: liveURL)
        let liveTracks = try await liveAsset.loadTracks(withMediaType: .video)
        try check(liveTracks.isEmpty, "Fixture reproduces missing live AVAsset tracks")
        let offloadedPlayer = ReceiverPlayer()
        let offloaded = PlaybackController(player: offloadedPlayer, showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0, isLive: true) },
            inspectVideoEvidence: { _ in false }, makePlayerItem: { RoutedItem(asset: $0) }, prepareSource: nil)
        try offloaded.load(liveURL.absoluteString, autoplay: true)
        try await wait(seconds: 8) { offloaded.snapshot.state == .playing }
        try check(offloaded.snapshot.diagnostics?.itemStatus == "ready"
                  && offloaded.snapshot.diagnostics?.videoConfirmed == false && offloadedPlayer.rate > 0,
                  "Ready routed live item plays when local video metadata and separate inspection are unavailable")
        try check(offloaded.snapshot.diagnostics?.sampleInspectionStatus == nil,
                  "Live Direct uses mounted player diagnostics without active sampling")
        try offloaded.selectXtreamMedia(liveURL, title: "Second routed channel")
        try await wait(seconds: 8) { offloaded.snapshot.state == .playing }
        try check(offloaded.player === offloadedPlayer && offloaded.snapshot.diagnostics?.videoConfirmed == false,
                  "Routed channel replacement does not wait forever for receiver-owned video metadata")
        offloaded.shutdown()
        let remuxRecorder = RemuxInputRecorder()
        let liveProbes = ProbeCounter()
        let liveDirectPlayer = ReceiverPlayer()
        let hevcReceiver = PlaybackController(player: liveDirectPlayer, showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0, isLive: true) },
            inspectVideoEvidence: { _ in await liveProbes.record(); return false },
            inspectStreamingVideo: { _ in await liveProbes.record(); return transport }, makePlayerItem: { RoutedItem(asset: $0) },
            prepareSource: { source in await remuxRecorder.record(source); throw PreparationFailure.unsupported })
        try hevcReceiver.load(liveURL.absoluteString, autoplay: true)
        try await wait(seconds: 12) { hevcReceiver.snapshot.state == .playing }
        try await Task.sleep(for: .milliseconds(1200))
        let remuxInput = await remuxRecorder.input
        let liveProbeCount = await liveProbes.count
        try check(remuxInput == nil && liveProbeCount == 1 && hevcReceiver.snapshot.playbackPath == .direct,
                  "Compatible H264 HLS stays Direct after one bounded preflight")
        let bufferingItem = liveDirectPlayer.currentItem
        liveDirectPlayer.rate = 0
        liveDirectPlayer.setBuffering(true)
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: bufferingItem)
        hevcReceiver.refresh()
        try await Task.sleep(for: .milliseconds(1200))
        hevcReceiver.refresh()
        try check(hevcReceiver.snapshot.state == .buffering && liveDirectPlayer.currentItem === bufferingItem
                  && hevcReceiver.snapshot.receiverWaiting != true,
                  "Temporary live Direct buffering retains the media and receiver instead of restoring waiting screen")
        liveDirectPlayer.setBuffering(false)
        liveDirectPlayer.play()
        hevcReceiver.refresh()
        try check(hevcReceiver.snapshot.state == .playing && hevcReceiver.snapshot.playbackPath == .direct,
                  "Buffered live Direct resumes on the same item without Stop")
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: bufferingItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey:
                NSError(domain: AVFoundationErrorDomain, code: AVError.Code.externalPlaybackNotSupportedForAsset.rawValue)])
        try await wait(seconds: 12) { hevcReceiver.snapshot.state == .failed }
        let lateInput = await remuxRecorder.input
        let lateAttempts = await remuxRecorder.count
        try check(lateInput?.playbackPath == .remux && lateAttempts == 1 && hevcReceiver.player === liveDirectPlayer,
                  "A format failure after live Direct starts can recover through a single remux attempt on the same player")
        hevcReceiver.shutdown()
        let visibleTracksRecorder = RemuxInputRecorder()
        let visibleTracks = PlaybackController(player: ReceiverPlayer(), showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0) }, inspectStreamingVideo: { _ in transport },
            prepareSource: { source in await visibleTracksRecorder.record(source); throw PreparationFailure.unsupported })
        try visibleTracks.selectXtreamMedia(base.appendingPathComponent("video.mp4"), title: "Live with visible tracks", isLive: true)
        try await wait(seconds: 12) { visibleTracks.snapshot.state == .ready }
        try visibleTracks.play()
        try await wait(seconds: 12) { visibleTracks.snapshot.state == .playing }
        try await Task.sleep(for: .milliseconds(1200))
        let visibleTracksInput = await visibleTracksRecorder.input
        try check(visibleTracksInput == nil && visibleTracks.snapshot.playbackPath == .direct,
                  "Visible native tracks keep the live channel on Direct")
        visibleTracks.shutdown()
        let preflightProbes = ProbeCounter()
        let preflightPreparations = RemuxInputRecorder()
        let preflight = PlaybackController(player: ReceiverPlayer(), showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0) },
            inspectStreamingVideo: { _ in await preflightProbes.record(); return hevc }, inspectFirstLiveInput: true,
            enableCompatibilityFallback: false,
            prepareSource: { source in await preflightPreparations.record(source); throw PreparationFailure.unsupported })
        try preflight.selectXtreamMedia(base.appendingPathComponent("video.mp4"), title: "Preflight channel", isLive: true)
        try await wait(seconds: 12) { preflight.snapshot.state == .ready }
        try preflight.play()
        try await wait(seconds: 8) { preflight.snapshot.state == .playing }
        let preflightCount = await preflightProbes.count
        let preflightPreparation = await preflightPreparations.input
        try check(preflightCount == 1 && preflightPreparation == nil && preflight.snapshot.playbackPath == .direct
                  && preflight.snapshot.diagnostics?.sampledVideo?.codec == .hevc,
                  "Opt-in preflight samples before playback and preserves Direct without remux")
        try preflight.selectXtreamMedia(base.appendingPathComponent("second.mp4"), title: "Next direct channel", isLive: true)
        try await wait(seconds: 8) { preflight.snapshot.state == .playing }
        let nextProbeCount = await preflightProbes.count
        try check(nextProbeCount == 1 && preflight.snapshot.diagnostics?.sampledVideo == nil,
                  "Preflight is one-shot and never probes an active replacement stream")
        preflight.shutdown()
        let failedNativeRecorder = RemuxInputRecorder()
        let failedNative = PlaybackController(player: ReceiverPlayer(), showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0) }, inspectStreamingVideo: { _ in nil },
            prepareSource: { source in await failedNativeRecorder.record(source); throw PreparationFailure.unsupported })
        try failedNative.selectXtreamMedia(base.appendingPathComponent("invalid.ts"), title: "Native load failure", isLive: true)
        try await wait(seconds: 15) { failedNative.snapshot.state == .failed }
        let recoveredInput = await failedNativeRecorder.input
        try check(recoveredInput == nil && failedNative.snapshot.diagnostics?.assetErrorCode != nil,
                  "An unclassified native live load failure retains evidence without a speculative remux")
        failedNative.shutdown()
        let incompatibleRecorder = RemuxInputRecorder()
        let incompatiblePlayer = ReceiverPlayer()
        let incompatible = PlaybackController(player: incompatiblePlayer, showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0) }, inspectStreamingVideo: { _ in hevc },
            makePlayerItem: { RoutedItem(asset: $0) }, allowVideoConversion: true,
            prepareSource: { source in await incompatibleRecorder.record(source); throw PreparationFailure.unsupported })
        try incompatible.selectXtreamMedia(liveURL, title: "HEVC TS HLS", isLive: true)
        try await wait(seconds: 12) { incompatible.snapshot.state == .failed }
        let incompatibleInput = await incompatibleRecorder.input
        let incompatibleAttempts = await incompatibleRecorder.count
        try check(incompatibleInput?.playbackPath == .remux && incompatibleInput?.isLive == true
                  && incompatibleInput?.conversionPolicy == .avoidVideo && incompatibleAttempts == 1
                  && incompatible.player === incompatiblePlayer,
                  "HEVC in TS HLS falls back before silent audio-only playback, without a retry loop or video encoding")
        try check(incompatibleInput?.url.host == "127.0.0.1" && incompatibleInput?.url != liveURL,
                  "Live remux helper receives an opaque loopback relay rather than the origin")
        incompatible.shutdown()
        let cancelledRecorder = RemuxInputRecorder()
        let pendingProbe = ProbeCounter()
        let cancelledPreflight = PlaybackController(player: ReceiverPlayer(), showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0, delivery: $0.pathExtension == "mp4" ? .file : .hls) }, inspectStreamingVideo: { _ in
                await pendingProbe.record()
                try? await Task.sleep(for: .milliseconds(500))
                return hevc
            }, prepareSource: { source in await cancelledRecorder.record(source); throw PreparationFailure.unsupported })
        try cancelledPreflight.selectXtreamMedia(liveURL, title: "Cancelled preflight", isLive: true)
        try await wait { await pendingProbe.count > 0 }
        try cancelledPreflight.load(base.appendingPathComponent("video.mp4").absoluteString)
        try await wait(seconds: 12) { cancelledPreflight.snapshot.state == .ready }
        let cancelledAttempts = await cancelledRecorder.count
        try check(cancelledAttempts == 0 && cancelledPreflight.snapshot.playbackPath == .direct,
                  "A cancelled live probe cannot remux or replace the subsequently selected source")
        cancelledPreflight.shutdown()
        let networkRecorder = RemuxInputRecorder()
        let unknownLive = PlaybackController(player: ReceiverPlayer(), showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0) }, inspectStreamingVideo: { _ in nil },
            makePlayerItem: { RoutedItem(asset: $0) },
            prepareSource: { source in await networkRecorder.record(source); throw PreparationFailure.unsupported })
        try unknownLive.selectXtreamMedia(liveURL, title: "Unknown live characteristics", isLive: true)
        try await wait(seconds: 12) { unknownLive.snapshot.state == .ready }
        try unknownLive.play()
        try await wait(seconds: 8) { unknownLive.snapshot.state == .playing }
        try check(unknownLive.snapshot.playbackPath == .direct,
                  "An unavailable compatibility sample does not block playable live Direct")
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: unknownLive.player.currentItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue)])
        try await wait(seconds: 8) { unknownLive.snapshot.state == .failed }
        let networkAttempts = await networkRecorder.count
        try check(networkAttempts == 0 && unknownLive.snapshot.errorReason == .network,
                  "A live network interruption does not trigger format remux recovery")
        unknownLive.shutdown()
        try check(hevc?.requiresHLSRemux == true && directHEVC?.requiresHLSRemux == false
                  && transport?.requiresHLSRemux == false,
                  "Compatibility fallback is specific to HEVC in MPEG-TS HLS")
        try check(hevc?.isLive == true && transport?.isLive == true && directHEVC?.isLive == nil,
                  "Live presentation is inferred from a media playlist rather than its input route or TS container")
        try check(HLSVideoEvidence.livePresentation(in: Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-ENDLIST\n".utf8)) == false
                  && HLSVideoEvidence.livePresentation(in: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvariant.m3u8\n".utf8)) == nil,
                  "Finite HLS and an unknown master never become live merely because they are playlists")
        let sourceRecorder = RemuxInputRecorder()
        let directSource = PlaybackController(player: ReceiverPlayer(), showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0, delivery: .hls) }, inspectStreamingVideo: { _ in hevc },
            prepareSource: { source in await sourceRecorder.record(source); throw PreparationFailure.unsupported })
        try directSource.load(liveURL.absoluteString)
        try await wait(seconds: 12) { directSource.snapshot.state == .failed }
        let sourceInput = await sourceRecorder.input
        try check(sourceInput?.isLive == true && sourceInput?.playbackPath == .remux,
                  "An HLS link opened through Source receives the same live detection and remux fallback as a catalog channel")
        directSource.shutdown()
        let queuePlayer = ReceiverPlayer()
        let queueController = PlaybackController(player: queuePlayer, showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0, delivery: .file) },
            resolvePlaylist: { _ in ResolvedPlaylist(title: "Synthetic YouTube queue", entries: [
                PlaylistEntry(url: base.appendingPathComponent("video.mp4"), title: "First"),
                PlaylistEntry(url: base.appendingPathComponent("second.mp4"), title: "Second")], truncated: false) })
        let queueURL = URL(string: "https://www.youtube.com/playlist?list=PLsynthetic123456")!
        try queueController.load(queueURL.absoluteString, autoplay: true)
        try await wait(seconds: 12) { queueController.snapshot.state == .playing }
        queuePlayer.rate = 0; queuePlayer.setBuffering(true); queueController.refresh()
        try queueController.next()
        queuePlayer.setBuffering(false)
        try await wait(seconds: 12) { queueController.snapshot.state == .playing && queueController.snapshot.queue?.currentIndex == 1 }
        try check(queueController.player === queuePlayer && queuePlayer.rate > 0,
                  "YouTube queue Next preserves requested playback through zero-rate buffering on the same receiver")
        queueController.pause()
        try queueController.previous()
        try await wait(seconds: 12) { queueController.snapshot.state == .ready }
        try check(queuePlayer.rate == 0 && queueController.snapshot.queue?.currentIndex == 0,
                  "YouTube queue Previous respects an explicit user pause")
        // Begin a new forward queue traversal; Previous deliberately preserves
        // backward skipping semantics when it encounters an unavailable item.
        try queueController.load(queueURL.absoluteString, autoplay: true)
        try await wait(seconds: 8) { queueController.snapshot.state == .playing }
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: queuePlayer.currentItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(domain: NSURLErrorDomain,
                code: URLError.networkConnectionLost.rawValue)])
        try await wait(seconds: 12) { queueController.snapshot.state == .playing && queueController.snapshot.queue?.currentIndex == 1 }
        try check(queuePlayer.rate > 0, "Skipping an unavailable YouTube queue item preserves playback intent")
        queueController.shutdown()
        let queueRemuxRecorder = RemuxInputRecorder()
        let liveQueue = PlaybackController(player: ReceiverPlayer(), showReceiverWaitingScreen: false,
            resolveSource: { ResolvedSource(url: $0, delivery: .hls) }, inspectStreamingVideo: { _ in hevc },
            resolvePlaylist: { _ in ResolvedPlaylist(title: "Synthetic live queue", entries: [
                PlaylistEntry(url: liveURL, title: "Live")], truncated: false) },
            prepareSource: { source in await queueRemuxRecorder.record(source); throw PreparationFailure.unsupported })
        try liveQueue.load(queueURL.absoluteString)
        try await wait(seconds: 12) { liveQueue.snapshot.state == .failed }
        let queueRemuxInput = await queueRemuxRecorder.input
        try check(queueRemuxInput?.isLive == true && queueRemuxInput?.playbackPath == .remux,
                  "A resolved YouTube queue item uses the same compatibility fallback as IPTV, without a provider branch")
        liveQueue.shutdown()
        let privateError = NSError(domain: "private-domain", code: 77,
            userInfo: [NSLocalizedDescriptionKey: "private-fixture-description"])
        let nativeError = NSError(domain: AVFoundationErrorDomain, code: -11870,
            userInfo: [NSUnderlyingErrorKey: privateError])
        let safeErrors = MediaDiagnostics.numericErrors(for: nativeError)
        let safeErrorsJSON = String(decoding: try JSONEncoder().encode(safeErrors), as: UTF8.self)
        try check(safeErrors == [MediaErrorCode(domain: .avFoundation, code: -11870), MediaErrorCode(domain: .other, code: 77)]
                  && !safeErrorsJSON.contains("private"),
                  "Failure chain preserves numeric causes and fixed domains without provider text")
        let failedChannelPlayer = ReceiverPlayer()
        let failedChannel = PlaybackController(player: failedChannelPlayer, showReceiverWaitingScreen: false,
            resolveSource: { url in
                if url.path.hasSuffix("fail.mp4") { throw ResolutionFailure.failed }
                return ResolvedSource(url: url)
            }, inspectStreamingVideo: { _ in nil }, prepareSource: nil)
        try failedChannel.load(base.appendingPathComponent("fail.mp4").absoluteString, autoplay: true)
        try await wait(seconds: 5) { failedChannel.snapshot.state == .failed }
        try failedChannel.selectXtreamMedia(base.appendingPathComponent("video.mp4"), title: "Recovery channel", isLive: true)
        try await wait(seconds: 8) { failedChannel.snapshot.state == .playing }
        try check(failedChannel.player === failedChannelPlayer && failedChannelPlayer.rate > 0,
                  "Selecting another channel after failure resumes the retained receiver without Stop")
        try check(failedChannel.snapshot.isLive && failedChannelPlayer.seekCount == 0,
                  "Explicit live catalog selection never rewinds a finite native buffer window to zero")
        failedChannel.shutdown()
        let liveItem = AVPlayerItem(asset: liveAsset)
        let liveProbe = AVPlayer(playerItem: liveItem)
        // A detached layer supplies a rendering clock without opening a window.
        let liveLayer = AVPlayerLayer(player: liveProbe)
        liveProbe.allowsExternalPlayback = false
        try await wait { liveItem.status != .unknown }
        try check(liveItem.status == .readyToPlay && liveItem.presentationSize.width > 0, "Real local AVPlayer item recognizes the live video")
        liveProbe.isMuted = true
        let time = liveProbe.currentTime().seconds
        let initialTime = time.isFinite ? time : 0
        liveProbe.play()
        try await wait(seconds: 5) { liveProbe.currentTime().seconds > initialTime + 0.5 }
        try check(liveProbe.timeControlStatus == .playing, "Real local HLS playback clock advances without a visible player")
        liveProbe.pause()
        liveLayer.player = nil
        liveProbe.replaceCurrentItem(with: nil)
        let fromURL = try await IPTVCatalogLoader.load(base.appendingPathComponent("redirect.m3u"))
        try check(fromURL.channels.count == 3 && fromURL.channels[0].url.path == "/video.mp4", "Remote import resolves resources against final redirect URL")
        do { _ = try await IPTVCatalogLoader.load(base.appendingPathComponent("unavailable.m3u")); throw Failure(message: "Server status was ignored") }
        catch let failure as IPTVCatalogFailure {
            try check(failure.message == IPTVCatalogFailure.httpStatus(503).message,
                      "Server rejection retains its HTTP status in a URL-free recovery message")
        }
        let coldURL = base.appendingPathComponent("cold.m3u")
        let legacyConfig = URLSessionConfiguration.ephemeral
        legacyConfig.timeoutIntervalForRequest = 10; legacyConfig.timeoutIntervalForResource = 20
        let legacySession = URLSession(configuration: legacyConfig)
        do { _ = try await legacySession.data(from: coldURL); throw Failure(message: "Legacy timeout did not reproduce") }
        catch let error as URLError { try check(error.code == .timedOut, "Cold server reproduces former ten-second import timeout") }
        legacySession.invalidateAndCancel()
        let coldCatalog = try await IPTVCatalogLoader.load(coldURL)
        try check(coldCatalog.channels.count == 3, "Cold server imports after more than ten seconds under packaged app transport policy")
        for url in [queryCatalog, basicQueryCatalog, xtreamURL] {
            let downloaded = try await IPTVCatalogLoader.load(url)
            try check(downloaded.channels.count == 3 && downloaded.categories == ["News", "Sports"]
                      && downloaded.channels[0].url.query == "token=a%2Bb%26c",
                      "Credential query reaches playlist server unchanged and channel metadata loads")
        }
        do { _ = try await IPTVCatalogLoader.load(base.appendingPathComponent("oversized.m3u")); throw Failure(message: "Remote length not bounded") }
        catch let error as IPTVCatalogFailure { try check(String(describing: error) == "tooLarge", "Remote content length is bounded") }
        let controller = PlaybackController(showReceiverWaitingScreen: false, resolveSource: { url in
            if url.path.contains("slow.mp4") { try await Task.sleep(for: .seconds(2)) }
            return ResolvedSource(url: url)
        })
        try controller.load(base.appendingPathComponent("video.mp4").absoluteString)
        try await wait { controller.snapshot.state != .loading }
        try check(controller.snapshot.diagnostics?.videoCodecTypes?.contains(kCMVideoCodecType_H264) == true
                  && controller.snapshot.diagnostics?.videoWidth == 320
                  && controller.snapshot.diagnostics?.videoHeight == 180,
                  "Native video diagnostics expose only codec identifiers and encoded dimensions")
        let player = controller.player, retainedItem = player.currentItem
        try controller.enqueue(base.appendingPathComponent("slow.mp4").absoluteString)
        try check(controller.snapshot.queue?.items.count == 2 && controller.player === player
                  && player.currentItem === retainedItem,
                  "Enqueue starts a queue without replacing the current player item")
        try controller.enqueue(base.appendingPathComponent("video.mp4").absoluteString)
        try check(controller.snapshot.queue?.items.count == 3 && controller.snapshot.queue?.currentIndex == 0
                  && player.currentItem === retainedItem,
                  "Appending another source preserves the current queue position and media")
        try controller.load(xtreamURL.absoluteString)
        try await wait { !controller.iptvImporting }
        try check(controller.iptvCatalog?.channels.count == 3 && controller.iptvImportError == nil
                  && controller.inspectorPage == .channels && player.currentItem === retainedItem,
                  "Xtream dialog output uses Source and opens Channels without replacing playback")
        controller.removeHistoryEntry(controller.history.first(where: { $0.credentialReference != nil })!.id)
        try controller.load(queryCatalog.absoluteString)
        try await wait { !controller.iptvImporting }
        try check(controller.iptvCatalog?.channels.count == 3 && controller.iptvImportError == nil
                  && controller.inspectorPage == .channels && controller.history.first?.credentialReference != nil && controller.history.first?.url.query?.contains("password") == false
                  && player.currentItem === retainedItem,
                  "Source imports get.php catalog without replacing current playback")
        try check(controller.iptvPlaylists.count == 2,
                  "A second IPTV playlist stays in the library beside the first")
        let queryHistory = controller.history.first(where: { $0.credentialReference != nil })!
        try check(queryHistory.kind == .iptv && queryHistory.title == "Fixture TV",
                  "Query catalog history retains replayable URL with a clean display title")
        try controller.load(local)
        try await wait { !controller.iptvImporting }
        try controller.selectHistoryEntry(queryHistory.id)
        try await wait { !controller.iptvImporting }
        try check(controller.history.first?.credentialReference != nil && controller.history.first?.url.query?.contains("password") == false && controller.iptvImportError == nil
                  && controller.inspectorPage == .channels && player.currentItem === retainedItem && controller.sourceInput == "",
                  "Remembered query catalog reopens through the catalog loader")
        controller.removeHistoryEntry(queryHistory.id)
        try controller.load(local)
        try await wait { !controller.iptvImporting }
        try check(controller.iptvCatalog?.channels.count == 3 && player.currentItem === retainedItem, "Import leaves current media and player intact")
        let catalogHistory = controller.history.first(where: { $0.kind == .iptv })!
        controller.inspectorPage = .history
        try controller.selectHistoryEntry(catalogHistory.id)
        try check(controller.inspectorPage == .channels && player.currentItem === retainedItem && controller.sourceInput == "",
                  "Opening current IPTV history restores Channels without replacing playback")
        let channel = controller.iptvCatalog!.channels[0]
        try controller.selectIPTVChannel(channel.id)
        try await wait { controller.snapshot.state != .loading }
        try check(controller.player === player && controller.selectedIPTVChannelID == channel.id && controller.snapshot.title == channel.name && player.rate == 0, "Channel selection keeps player, channel name and paused intent")
        try controller.selectSource("automatic")
        try await wait { controller.snapshot.state != .loading }
        try check(controller.selectedIPTVChannelID == channel.id, "Quality reload preserves current channel")
        try check(controller.history.count == 2, "Channel and quality selections do not clutter source history")
        let currentItem = player.currentItem
        controller.toggleHistoryPin(catalogHistory.id)
        controller.clearHistory()
        try check(controller.history.count == 1 && controller.history[0].id == catalogHistory.id
                  && controller.history[0].isPinned && controller.iptvCatalog != nil && player.currentItem === currentItem,
                  "Controller Clear History retains published pins without touching current playback")
        controller.removeHistoryEntry(catalogHistory.id)
        controller.clearHistory()
        try check(controller.history.isEmpty && controller.iptvCatalog != nil && player.currentItem === currentItem,
                  "Removing history leaves the current catalog and playback intact")
        controller.stop()
        try check(controller.iptvCatalog != nil && controller.selectedIPTVChannelID == nil, "Stop clears playback but retains catalog")
        try controller.load(base.appendingPathComponent("video.mp4").absoluteString)
        try await wait { controller.snapshot.state != .loading }
        try check(controller.iptvCatalog != nil && controller.selectedIPTVChannelID == nil, "Ordinary media does not remove the catalog")
        try controller.importIPTV(base.appendingPathComponent("bad.m3u").absoluteString)
        try await wait { !controller.iptvImporting }
        try check(controller.iptvImportError != nil && controller.iptvCatalog?.channels.first?.id == channel.id, "Failed replacement retains working catalog")
        try controller.importIPTV(base.appendingPathComponent("slow.m3u").absoluteString)
        try controller.importIPTV(local)
        try await wait { !controller.iptvImporting }
        try await Task.sleep(for: .milliseconds(200))
        try check(controller.iptvCatalog?.channels.count == 3 && controller.iptvImportError == nil, "New import supersedes a delayed request")
        do { try controller.selectIPTVChannel(channel.id); throw Failure(message: "Stale channel selected a new row") }
        catch is AppFailure { try check(true, "Stale channel selection refused") }
        try controller.importIPTV(base.appendingPathComponent("slow.m3u").absoluteString)
        controller.cancelIPTVImport()
        try await Task.sleep(for: .milliseconds(100))
        try check(!controller.iptvImporting && controller.iptvImportError == nil && controller.iptvCatalog != nil, "Cancel keeps the existing catalog")
        let slow = controller.iptvCatalog!.channels[2]
        let fast = controller.iptvCatalog!.channels[1]
        try controller.selectIPTVChannel(slow.id)
        try controller.selectIPTVChannel(fast.id)
        try await wait { controller.snapshot.state != .loading }
        try check(controller.selectedIPTVChannelID == fast.id && controller.snapshot.title == fast.name && controller.snapshot.state != .failed, "Rapid channel switches discard late media results")
        controller.shutdown()
        let hls = PlaybackController(showReceiverWaitingScreen: false,
                                     resolveSource: { _ in ResolvedSource(url: base.appendingPathComponent("video.mp4")) },
                                     loadIPTVCatalog: { _ in throw IPTVCatalogFailure.hlsPlaylist })
        try hls.load(base.appendingPathComponent("stream.m3u").absoluteString)
        try await wait { !hls.iptvImporting && hls.player.currentItem?.status == .readyToPlay }
        try check(hls.iptvCatalog == nil && hls.iptvImportError == nil && hls.snapshot.state != .failed, "HLS with an M3U URL remains a video through ordinary Load")
        let localHLS = URL(fileURLWithPath: local).deletingLastPathComponent().appendingPathComponent("local-stream.m3u8")
        try Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n".utf8).write(to: localHLS)
        try hls.load(localHLS.path)
        // The previous item is already ready, so wait for this load's own
        // history entry, which is recorded only once the replacement is ready.
        try await wait { !hls.iptvImporting && hls.history.first?.url == localHLS }
        try check(hls.iptvImportError == nil && hls.snapshot.state != .failed && hls.history.first?.url == localHLS,
                  "Local HLS file handed through Source falls back to video loading")
        let unsupportedLocalHLS = PlaybackController(showReceiverWaitingScreen: false)
        try unsupportedLocalHLS.load(localHLS.path)
        try await wait { !unsupportedLocalHLS.iptvImporting && unsupportedLocalHLS.snapshot.state == .failed }
        try check(unsupportedLocalHLS.iptvImportError == nil && unsupportedLocalHLS.snapshot.error?.contains("Local HLS video playlists are not supported") == true,
                  "Unsupported local HLS explains the real limit without circular catalog recovery")
        unsupportedLocalHLS.shutdown()
        let hlsItem = hls.player.currentItem
        try hls.importIPTV(base.appendingPathComponent("stream.m3u").absoluteString)
        try await wait { !hls.iptvImporting }
        try check(hls.iptvImportError == IPTVCatalogFailure.hlsPlaylist.message && hls.player.currentItem === hlsItem, "Explicit catalog import explains HLS without replacing playback")
        hls.shutdown()
        let staleHLS = PlaybackController(showReceiverWaitingScreen: false, resolveSource: { ResolvedSource(url: $0) },
                                          loadIPTVCatalog: { _ in
            try await Task.sleep(for: .milliseconds(500))
            throw IPTVCatalogFailure.hlsPlaylist
        })
        try staleHLS.load(base.appendingPathComponent("old-stream.m3u").absoluteString)
        try staleHLS.load(base.appendingPathComponent("video.mp4").absoluteString)
        try await wait { staleHLS.player.currentItem?.status == .readyToPlay }
        let newerItem = staleHLS.player.currentItem
        try await wait { !staleHLS.iptvImporting }
        try check(staleHLS.player.currentItem === newerItem && staleHLS.snapshot.state != .failed, "Late HLS discovery cannot replace a newer video")
        staleHLS.shutdown()
        let receiver = ReceiverPlayer()
        let playing = PlaybackController(player: receiver, showReceiverWaitingScreen: false, resolveSource: { ResolvedSource(url: $0) })
        try playing.importIPTV(local)
        try await wait { !playing.iptvImporting }
        try playing.load(base.appendingPathComponent("video.mp4").absoluteString, autoplay: true)
        try await wait { playing.snapshot.state == .playing }
        try playing.selectIPTVChannel(playing.iptvCatalog!.channels[0].id)
        try await wait { playing.snapshot.state == .playing }
        try check(playing.player === receiver && receiver.rate > 0, "Active receiver playback resumes through a channel change")
        receiver.ignoreNextPlays(2)
        try playing.selectIPTVChannel(playing.iptvCatalog!.channels[1].id)
        try await wait(seconds: 5) { receiver.rate > 0 }
        try check(playing.snapshot.state == .playing, "Channel replacement retries Play ignored during receiver handoff")
        try await Task.sleep(for: .milliseconds(1500))
        receiver.ignoreNextPlays(2)
        try playing.selectXtreamMedia(base.appendingPathComponent("video.mp4"), title: "Xtream replacement")
        try await wait(seconds: 5) { receiver.rate > 0 }
        try check(playing.snapshot.state == .playing, "Xtream replacement retries Play ignored during receiver handoff")
        try await Task.sleep(for: .milliseconds(1500))
        let bufferingPlayer = ReceiverPlayer()
        let bufferingController = PlaybackController(player: bufferingPlayer, showReceiverWaitingScreen: false,
            resolveSource: { url in
                try await Task.sleep(for: .seconds(2))
                return ResolvedSource(url: url)
            })
        bufferingPlayer.replaceCurrentItem(with: AVPlayerItem(url: base.appendingPathComponent("video.mp4")))
        bufferingPlayer.setBuffering(true)
        try bufferingController.load(base.appendingPathComponent("second.mp4").absoluteString)
        let pausesBeforeBuffering = bufferingPlayer.pauseCount
        for _ in 0..<5 { bufferingController.refresh() }
        try check(bufferingPlayer.pauseCount == pausesBeforeBuffering,
                  "Loading does not repeatedly pause a zero-rate buffering receiver")
        bufferingController.shutdown()
        receiver.ignoreNextPlays(100)
        try playing.selectIPTVChannel(playing.iptvCatalog!.channels[0].id)
        try await wait { playing.snapshot.state != .loading }
        playing.pause()
        let pausedRequests = receiver.playCount
        try await Task.sleep(for: .milliseconds(1300))
        try check(receiver.rate == 0 && receiver.playCount == pausedRequests, "Pause cancels pending channel playback retries")
        receiver.ignoreNextPlays(0)
        playing.pause()
        try playing.selectIPTVChannel(playing.iptvCatalog!.channels[1].id)
        try await wait { playing.snapshot.state != .loading }
        try check(receiver.rate == 0 && playing.snapshot.state != .failed, "Paused receiver playback stays paused when changing channel")
        try playing.importIPTV(base.appendingPathComponent("live-channels.m3u").absoluteString)
        try await wait { !playing.iptvImporting }
        try playing.load(liveURL.absoluteString, autoplay: true)
        do { try await wait(seconds: 8) { playing.snapshot.state == .playing } }
        catch { throw Failure(message: "Initial live playback: \(playing.snapshot), item duration: \(String(describing: receiver.currentItem?.duration)), rate: \(receiver.rate)") }
        let liveSeekCount = receiver.seekCount
        receiver.ignoreNextPlays(1)
        try playing.selectIPTVChannel(playing.iptvCatalog!.channels[1].id)
        do { try await wait(seconds: 8) { playing.snapshot.state == .playing } }
        catch { throw Failure(message: "Replacement live playback: \(playing.snapshot), item duration: \(String(describing: receiver.currentItem?.duration)), rate: \(receiver.rate)") }
        try check(playing.snapshot.isLive && playing.snapshot.diagnostics?.videoConfirmed == true,
                  "Live channel replacement becomes controllable with inspected video evidence")
        try check(receiver.seekCount == liveSeekCount, "Live channel replacement never rewinds to an absolute zero position")
        playing.shutdown()
        print("IPTV checks: \(checks) passed; receiver behavior simulated, physical receiver untested.")
    }
    @MainActor static func wait(seconds: Int = 30, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure(message: "Controller wait timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
