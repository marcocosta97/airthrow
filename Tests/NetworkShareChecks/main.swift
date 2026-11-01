import Foundation
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private actor AccessProbe: ShareProvider {
    var connections = 0
    var listings = 0
    var disconnected = 0
    var busy = false
    let file: URL
    init(file: URL) { self.file = file }
    func connect() { connections += 1 }
    func list(_ path: String) throws -> [ShareEntry] {
        listings += 1
        if path == "missing" { throw ShareError.unavailable }
        return [ShareEntry(path: path.isEmpty ? "Movies" : path + "/Child", name: "Child", isDirectory: true)]
    }
    func read(_ path: String, maximumBytes: Int) -> Data { Data() }
    func playbackURL(_ path: String) -> URL { file }
    func disconnect() async throws {
        try await Task.sleep(for: .milliseconds(25))
        if busy { throw ShareError.volumeBusy }; disconnected += 1
    }
    func setBusy(_ busy: Bool) { self.busy = busy }
    func counts() -> [Int] { [connections, listings, disconnected] }
}

@MainActor private final class FixtureCredentials: ShareCredentialStorage {
    var values: [UUID: [String]] = [:]
    var reads = 0
    var failSave = false
    var failRemoval = false
    func load(_ id: UUID) -> [String]? { reads += 1; return values[id] }
    func save(_ id: UUID, username: String, password: String) throws {
        if failSave { throw ShareError.accessDenied }
        values[id] = [username, password]
    }
    func remove(_ id: UUID) throws {
        if failRemoval { throw ShareError.accessDenied }
        values[id] = nil
    }
}
@MainActor private final class FixtureWrites { var fail = false; var count = 0; var failOnWrite: Int? }

@main struct NetworkShareChecks {
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NSError(domain: "NetworkShareChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        print("PASS \(label)")
    }
    @MainActor static func settle(_ model: NetworkLibraryModel) async throws {
        for _ in 0..<100 where model.browsing { try await Task.sleep(for: .milliseconds(10)) }
        try check(!model.browsing, "folder request completed")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--abandon-download" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let download = try TemporaryMediaDownload(filename: "fixture.mp4", root: root)
            try Data([42]).write(to: download.url)
            try Data(download.url.path.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            _exit(0)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("airthrow-share-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let downloadRoot = temporary.appendingPathComponent("downloads", isDirectory: true)
        let activeDownload = try TemporaryMediaDownload(filename: "fixture.mp4", root: downloadRoot)
        try Data([42]).write(to: activeDownload.url)
        PreparationWorkspace.cleanAbandoned(root: downloadRoot)
        try check(FileManager.default.fileExists(atPath: activeDownload.url.path), "cleanup preserves a live download lease")
        let marker = temporary.appendingPathComponent("abandoned-path")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--abandon-download", downloadRoot.path, marker.path]
        try child.run(); child.waitUntilExit()
        try check(child.terminationStatus == 0, "download fixture exits without cleanup")
        let abandonedPath = try String(contentsOf: marker, encoding: .utf8)
        try check(FileManager.default.fileExists(atPath: abandonedPath), "interrupted download remains before recovery")
        PreparationWorkspace.cleanAbandoned(root: downloadRoot)
        try check(!FileManager.default.fileExists(atPath: abandonedPath) && FileManager.default.fileExists(atPath: activeDownload.url.path), "recovery removes only abandoned downloads")
        activeDownload.stop()
        try check(!FileManager.default.fileExists(atPath: activeDownload.url.path), "Stop releases the downloaded source")
        let publicSource = URL(string: "http://public.example/media.m3u8")!
        for host in ["127.1", "2130706433", "0x7f000001", "0177.0.0.1", "[::ffff:127.0.0.1]", "[fe80::1%25en0]"] {
            let target = URL(string: "http://" + host + "/fixture")!
            try check(!RelayAddress.allows(target, from: publicSource), "relay rejects nonpublic numeric address forms")
        }
        let localKinds = try await RelayAddress.resolvedKinds(URL(string: "http://localhost/fixture")!)
        try check(!RelayAddress.permits(localKinds, from: [.publicHost]), "resolved loopback hostname is blocked for public sources")
        try check(!RelayAddress.permits([.publicHost, .privateNetwork], from: [.publicHost])
                  && !RelayAddress.permits([.loopback], from: [.publicHost, .loopback])
                  && RelayAddress.permits([.privateNetwork], from: [.privateNetwork]), "mixed DNS answers cannot broaden network access")
        let blocked = HTTPMediaTransfer(request: URLRequest(url: URL(string: "http://localhost:1/fixture")!), credentials: nil, origin: publicSource, originKinds: [.publicHost])
        let blockedError: Error? = await withCheckedContinuation { continuation in
            blocked.completed = { continuation.resume(returning: $0) }
            blocked.start()
        }
        try check(blockedError is HTTPLoginFailure, "transfer rejects a local DNS destination before issuing HTTP")
        let share = try NetworkShare(name: "Fixture", kind: .webDAV, endpoint: URL(string: "http://127.0.0.1:9876/dav/")!)
        try check(try share.reference("TV/Épisode #1.mkv").path == "/TV/Épisode #1.mkv", "stable Unicode references")
        for path in ["../escape", "a/../b", "/outside", "a\\b"] {
            do { _ = try SharePath.validate(path); throw NSError(domain: "accepted invalid path", code: 1) }
            catch ShareError.invalidAddress { print("PASS rejected unsafe path") }
        }
        let xml = Data("""
        <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/dav/A%20Film.mkv</d:href><d:propstat><d:prop><d:getcontentlength>123</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><d:getcontentlength>999</d:getcontentlength></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        <d:response><d:href>http://elsewhere.invalid/dav/secret.mkv</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/outside/escape.mkv</d:href><d:propstat><d:prop><d:getcontentlength>1</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
        let listing = try WebDAVShareProvider.decode(xml, root: share.endpoint, directory: "")
        try check(listing.count == 1 && listing[0].name == "A Film.mkv" && listing[0].size == 123, "multistatus and root containment")
        let local = temporary.appendingPathComponent("files"); try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 2048).write(to: local.appendingPathComponent("Video.mp4"))
        try Data([1]).write(to: temporary.appendingPathComponent("outside"))
        try FileManager.default.createSymbolicLink(at: local.appendingPathComponent("escape"), withDestinationURL: temporary)
        let mounted = MountedShareProvider(root: local)
        let localListing = try await mounted.list("")
        try check(localListing.count == 1 && localListing[0].isVideo, "mounted filesystem browsing excludes symlinks")
        do { _ = try await mounted.playbackURL("escape/outside"); throw NSError(domain: "escaped root", code: 1) } catch ShareError.invalidAddress { print("PASS symlink containment") }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(share)) as! [String: Any]
        legacy.removeValue(forKey: "connectAutomatically")
        legacy.removeValue(forKey: "credentialID")
        let migrated = try JSONDecoder().decode(NetworkShare.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(!migrated.connectAutomatically, "existing shares migrate to explicit connection")
        try check(migrated.credentialID == migrated.id, "legacy shares retain their saved credential identifier")
        let legacyConfiguration = try JSONDecoder().decode(ShareLibraryConfiguration.self, from: JSONSerialization.data(withJSONObject: ["shares": [legacy]]))
        try check(legacyConfiguration.pendingCredentialRemovals.isEmpty && legacyConfiguration.shares[0].credentialID == share.id, "legacy configurations decode without a cleanup queue")
        let modelDirectory = temporary.appendingPathComponent("connections")
        let modelStore = try NetworkShareStore(url: modelDirectory.appendingPathComponent("catalog.sqlite"))
        var configuration = ShareLibraryConfiguration(); configuration.shares = [share]
        try await modelStore.save(configuration)
        let probe = AccessProbe(file: local.appendingPathComponent("Video.mp4"))
        let model = NetworkLibraryModel(directory: modelDirectory, providerFactory: { _ in await probe.connect(); return probe })
        await model.open(); model.show(share.id)
        do { _ = try await model.resolve(share.reference("Video.mp4")); throw NSError(domain: "implicit connection", code: 1) }
        catch ShareError.connectionRequired { print("PASS playback requires explicit connection") }
        let deniedCounts = await probe.counts()
        try check(deniedCounts == [0, 0, 0] && !model.browsing, "startup and sidebar selection perform no remote access by default")
        try check(model.configuration.shares == [share], "saved connections survive without loading catalog data")
        model.reconnect(share.id); try await settle(model)
        let connectedCounts = await probe.counts()
        try check(connectedCounts[0] == 1 && model.canAccess(share.id), "explicit Update connects for this session")
        for path in ["Movies", "Movies/Child"] { model.browse(share.id, path: path); try await settle(model) }
        model.back(); try await settle(model)
        try check(model.directory == "Movies" && model.histories[share.id]?.forwardIndex != nil, "Back preserves forward history")
        model.forward(); try await settle(model)
        try check(model.directory == "Movies/Child", "Forward returns to visited folder")
        model.back(); try await settle(model); model.browse(share.id, path: "Other"); try await settle(model)
        try check(model.histories[share.id]?.forwardIndex == nil, "new navigation discards forward branch")
        let beforeFailure = model.histories[share.id]?.paths
        model.browse(share.id, path: "missing"); try await settle(model)
        try check(model.histories[share.id]?.paths == beforeFailure, "failed folders do not enter navigation history")
        let resource = try await model.resolve(share.reference("Video.mp4")); resource.stop()
        let reopened = NetworkLibraryModel(directory: modelDirectory, providerFactory: { _ in await probe.connect(); return probe })
        await reopened.open()
        try check(!reopened.canAccess(share.id), "manual connection permission expires on relaunch")
        await probe.setBusy(true); await model.unmount(share.id)
        try check(model.connectedShares.contains(share.id) && model.canAccess(share.id), "busy unmount keeps connection available")
        await probe.setBusy(false)
        let unmount = Task { await model.unmount(share.id) }
        while !model.unmounting.contains(share.id) { await Task.yield() }
        let beforeRace = await probe.counts()
        model.reconnect(share.id)
        let duringRace = await probe.counts()
        try check(!model.canAccess(share.id) && beforeRace == duringRace, "Update cannot race an in-flight unmount")
        await unmount.value
        let unmountedCounts = await probe.counts()
        model.show(share.id)
        let afterSelection = await probe.counts()
        try check(!model.canAccess(share.id) && model.connectedShares.isEmpty && afterSelection == unmountedCounts, "unmount closes the connection without an implicit remount")
        var automaticShare = share; automaticShare.connectAutomatically = true
        configuration.shares = [automaticShare]; try await modelStore.save(configuration)
        let automatic = NetworkLibraryModel(directory: modelDirectory, providerFactory: { _ in await probe.connect(); return probe })
        await automatic.open(); automatic.show(share.id); try await settle(automatic)
        await automatic.unmount(share.id); automatic.show(share.id)
        try check(!automatic.canAccess(share.id), "explicit unmount overrides automatic connection for the session")
        automatic.reconnect(share.id); try await settle(automatic)
        try check(automatic.canAccess(share.id), "Update can reconnect after unmount")
        var renamed = automaticShare; renamed.name = "Renamed fixture"
        let beforeRename = await probe.counts()
        try await automatic.update(renamed, username: "", password: "", remember: false)
        let afterRename = await probe.counts()
        try check(automatic.connectedShares.contains(share.id) && beforeRename == afterRename, "renaming preserves the active connection without server access")
        let historyDefaults = UserDefaults(suiteName: "share-history-" + UUID().uuidString)!
        let historyStore = MediaHistoryStore(defaults: historyDefaults, credentials: MemoryMediaHistoryCredentials())
        let reference = try share.reference("Movies/Film.mp4")
        historyStore.record(reference, title: "Film", kind: .video)
        let restoredHistory = MediaHistoryStore(defaults: historyDefaults, credentials: MemoryMediaHistoryCredentials())
        try check(restoredHistory.entries.first?.url == reference, "share video history survives reload without server addresses")
        historyStore.clearIncludingPinned()
        let beforeEdit = await probe.counts()
        automaticShare.connectAutomatically = false
        try await automatic.update(automaticShare, username: "", password: "", remember: false)
        automatic.show(share.id)
        let afterEdit = await probe.counts()
        try check(!automatic.canAccess(share.id) && beforeEdit == afterEdit, "editing connection policy requires no server access")
        let credentialFixture = FixtureCredentials()
        credentialFixture.values[share.credentialID] = ["old", "fixture"]
        let writes = FixtureWrites()
        let failureModel = NetworkLibraryModel(directory: modelDirectory, credentialStore: credentialFixture, configurationWriter: { value in
            writes.count += 1
            if writes.fail || writes.failOnWrite == writes.count { throw ShareError.storage }
            try await modelStore.save(value)
        }, providerFactory: { _ in probe })
        await failureModel.open()
        let original = failureModel.configuration.shares[0]
        var edited = original; edited.name = "Edited fixture"
        writes.fail = true
        do {
            try await failureModel.update(edited, username: "new", password: "fixture", remember: true, replaceCredentials: true)
            throw NSError(domain: "accepted failed save", code: 1)
        } catch ShareError.storage {}
        try check(failureModel.configuration.shares == [original] && credentialFixture.values == [share.credentialID: ["old", "fixture"]], "failed edit preserves saved credentials and removes staging")
        await failureModel.remove(original)
        try check(failureModel.configuration.shares == [original] && credentialFixture.values[share.credentialID] != nil, "failed removal retains configuration and credentials")
        writes.fail = false; writes.failOnWrite = writes.count + 2
        do {
            try await failureModel.update(edited, username: "new", password: "fixture", remember: true, replaceCredentials: true)
            throw NSError(domain: "accepted failed staged save", code: 1)
        } catch ShareError.storage {}
        try check(failureModel.configuration.shares == [original] && credentialFixture.values == [share.credentialID: ["old", "fixture"]], "failure after credential staging preserves the old account")
        writes.failOnWrite = nil; credentialFixture.failSave = true
        do {
            try await failureModel.update(edited, username: "new", password: "fixture", remember: true, replaceCredentials: true)
            throw NSError(domain: "accepted failed credential save", code: 1)
        } catch ShareError.accessDenied {}
        try check(failureModel.configuration.shares == [original], "Keychain write failure leaves configuration unchanged")
        credentialFixture.failSave = false; credentialFixture.failRemoval = true
        try await failureModel.update(edited, username: "new", password: "fixture", remember: true, replaceCredentials: true)
        let replacement = failureModel.configuration.shares[0]
        try check(replacement.credentialID != original.credentialID && credentialFixture.values[replacement.credentialID] == ["new", "fixture"] && failureModel.configuration.pendingCredentialRemovals.contains(original.credentialID), "successful edit switches references and queues failed credential cleanup")
        credentialFixture.failRemoval = false
        let recovered = NetworkLibraryModel(directory: modelDirectory, credentialStore: credentialFixture)
        await recovered.open()
        try check(recovered.configuration.pendingCredentialRemovals.isEmpty && credentialFixture.values[original.credentialID] == nil && credentialFixture.values[replacement.credentialID] != nil && credentialFixture.reads == 0, "reopening retries cleanup without reading any credentials")
        try await recovered.update(replacement, username: "session", password: "fixture", remember: false, replaceCredentials: true)
        try check(credentialFixture.values.isEmpty, "session-only edit removes old persisted credentials")
        await recovered.remove(recovered.configuration.shares[0])
        try check(recovered.configuration.shares.isEmpty && credentialFixture.values.isEmpty, "successful removal commits configuration before credential cleanup")
        let orderDirectory = temporary.appendingPathComponent("ordered-shares")
        let orderStore = try NetworkShareStore(url: orderDirectory.appendingPathComponent("catalog.sqlite"))
        let secondShare = try NetworkShare(name: "Second fixture", kind: .webDAV, endpoint: share.endpoint)
        var ordered = ShareLibraryConfiguration(); ordered.shares = [share, secondShare]
        try await orderStore.save(ordered)
        let orderModel = NetworkLibraryModel(directory: orderDirectory, credentialStore: credentialFixture)
        await orderModel.open()
        var renamedFirst = share; renamedFirst.name = "Renamed first"
        try await orderModel.update(renamedFirst, username: "", password: "", remember: false)
        try check(orderModel.configuration.shares.map(\.id) == [share.id, secondShare.id] && credentialFixture.reads == 0, "renaming preserves source order and never retrieves credentials")
        if CommandLine.arguments.count > 1, let endpoint = URL(string: CommandLine.arguments[1]) {
            let dav = WebDAVShareProvider(root: endpoint, username: "fixture", password: "fixture")
            let entries = try await dav.list("")
            try check(entries.count == 2, "authenticated WebDAV listing")
            let video = try await dav.playbackURL("Video.mp4")
            let credentials = try await dav.playbackCredentials("Video.mp4")
            let relay = try await HTTPMediaRelay.start(source: video, credentials: credentials, host: "127.0.0.1")
            defer { relay.stop() }
            var request = URLRequest(url: relay.url!); request.setValue("bytes=1000000-1004095", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            try check((response as? HTTPURLResponse)?.statusCode == 206 && data == Data(repeating: 42, count: 4096), "authenticated relay distant byte ranges")
            do { _ = try await dav.playbackURL("NoRanges.mp4"); throw NSError(domain: "accepted ignored range", code: 1) } catch ShareError.noRanges { print("PASS explicit download required when ranges ignored") }
            let destination = temporary.appendingPathComponent("download.mp4")
            try await dav.download("NoRanges.mp4", to: destination, maximumBytes: 40 * 1024 * 1024) { _ in }
            let downloaded = try Data(contentsOf: destination)
            try check(downloaded.count == 32 * 1024 * 1024, "explicit bounded temporary download")
            let start = ContinuousClock.now
            let all: Data
            do { (all, _) = try await URLSession.shared.data(from: relay.url!) }
            catch {
                let d = relay.diagnostics
                print("Relay failure counters: bytes=\(d.relayReceivedBytes) peak=\(d.relayPeakBufferBytes) bufferClosures=\(d.relayBufferLimitClosures) EOF=\(d.relayEOFClosures)")
                throw error
            }
            let elapsed = start.duration(to: .now)
            try check(all.count == 32 * 1024 * 1024, "full relay stream has exact byte count")
            print("Synthetic loopback relay: 32 MiB in \(elapsed). This is not an SMB or receiver benchmark.")
        }
        print("Network share checks passed")
    }
}
