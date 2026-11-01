import AppKit
import Combine
import Foundation
import NetFS
#if SWIFT_PACKAGE
import AirThrowCore
#endif

@MainActor final class SharePlayback {
    let url: URL
    private let relay: HTTPMediaRelay?
    private let temporary: TemporaryMediaDownload?
    init(url: URL, relay: HTTPMediaRelay? = nil, temporary: TemporaryMediaDownload? = nil) { self.url = url; self.relay = relay; self.temporary = temporary }
    var diagnostics: LivePipelineDiagnostics? { relay?.diagnostics }
    func stop() { relay?.stop(); temporary?.stop() }
}

@MainActor protocol ShareCredentialStorage {
    func load(_ id: UUID) throws -> [String]?
    func save(_ id: UUID, username: String, password: String) throws
    func remove(_ id: UUID) throws
}
struct KeychainShareCredentialStorage: ShareCredentialStorage {
    func load(_ id: UUID) throws -> [String]? { try ShareCredentials.load(id) }
    func save(_ id: UUID, username: String, password: String) throws { try ShareCredentials.save(id, username: username, password: password) }
    func remove(_ id: UUID) throws { try ShareCredentials.remove(id) }
}

@MainActor final class NetworkLibraryModel: ObservableObject {
    @Published var configuration = ShareLibraryConfiguration()
    @Published var entries: [ShareEntry] = []
    @Published var directory = ""
    @Published var activeShare: UUID?
    @Published var browsing = false
    @Published var message: String?
    @Published var downloading = false
    @Published var downloadBytes: Int64 = 0
    @Published var offlineShares: Set<UUID> = []
    @Published private(set) var connectedShares: Set<UUID> = []
    @Published private(set) var suspendedShares: Set<UUID> = []
    @Published private(set) var histories: [UUID: ShareNavigation] = [:]
    @Published private(set) var unmounting: Set<UUID> = []
    @Published private(set) var authorizedShares: Set<UUID> = []
    private let providerFactory: (@Sendable (NetworkShare) async throws -> any ShareProvider)?
    private var store: NetworkShareStore?
    private var savingConfiguration = false
    private var providers: [UUID: any ShareProvider] = [:]
    private var credentials: [UUID: [String]] = [:]
    private var browseTask: Task<Void, Never>?
    private var browserGeneration = UUID()
    private var unmountObservation: AnyCancellable?
    private let directoryURL: URL
    private let credentialStore: any ShareCredentialStorage
    private let configurationWriter: (@MainActor (ShareLibraryConfiguration) async throws -> Void)?
    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("AirThrow/NetworkLibrary"),
         credentialStore: any ShareCredentialStorage = KeychainShareCredentialStorage(),
         configurationWriter: (@MainActor (ShareLibraryConfiguration) async throws -> Void)? = nil,
         providerFactory: (@Sendable (NetworkShare) async throws -> any ShareProvider)? = nil) {
        directoryURL = directory; self.providerFactory = providerFactory
        self.credentialStore = credentialStore; self.configurationWriter = configurationWriter
        unmountObservation = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
            .sink { [weak self] notification in
                guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                Task { @MainActor [weak self] in await self?.volumeUnmounted(volume) }
            }
    }
    func open() async {
        guard store == nil, !savingConfiguration else { return }
        savingConfiguration = true
        defer { savingConfiguration = false }
        do {
            let database = try NetworkShareStore(url: directoryURL.appendingPathComponent("catalog.sqlite"))
            configuration = try await database.configuration(); store = database
            await removeRetiredCredentials()
        } catch { message = "The library could not be opened. Check available disk space." }
    }
    private func volumeUnmounted(_ volume: URL) async {
        for (id, provider) in providers {
            guard let mounted = provider as? MountedShareProvider,
                  await mounted.usesMountedVolume(volume),
                  let current = providers[id] as? MountedShareProvider, current === mounted else { continue }
            providers[id] = nil; connectedShares.remove(id); authorizedShares.remove(id)
            suspendedShares.insert(id); histories[id] = nil
            if activeShare == id {
                browseTask?.cancel(); browserGeneration = UUID(); browsing = false; entries = []; directory = ""
            }
        }
    }
    func canAccess(_ id: UUID) -> Bool {
        !suspendedShares.contains(id) && !unmounting.contains(id)
            && (authorizedShares.contains(id) || configuration.shares.contains { $0.id == id && $0.connectAutomatically })
    }
    func provider(_ id: UUID) async throws -> any ShareProvider {
        guard canAccess(id) else { throw ShareError.connectionRequired }
        if let existing = providers[id] { return existing }
        guard let share = configuration.shares.first(where: { $0.id == id }) else { throw ShareError.unavailable }
        let provider: any ShareProvider
        if let providerFactory { provider = try await providerFactory(share) }
        else if share.kind == .smb { provider = try await MountedShareProvider.connect(share) }
        else {
            let login = try credentials[id] ?? credentialStore.load(share.credentialID) ?? ["", ""]
            guard login.count == 2 else { throw ShareError.accessDenied }
            provider = WebDAVShareProvider(root: share.endpoint, username: login[0], password: login[1])
        }
        try Task.checkCancellation()
        guard canAccess(id), configuration.shares.contains(where: { $0.id == id && $0.endpoint == share.endpoint }) else { throw CancellationError() }
        providers[id] = provider; connectedShares.insert(id); return provider
    }
    private func saveConfiguration(_ value: ShareLibraryConfiguration) async throws {
        guard let store else { throw ShareError.storage }
        if let configurationWriter { try await configurationWriter(value) }
        else { try await store.save(value) }
    }
    private func removeRetiredCredentials() async {
        var cleaned = configuration
        for id in configuration.pendingCredentialRemovals where !configuration.shares.contains(where: { $0.credentialID == id }) {
            do { try credentialStore.remove(id); cleaned.pendingCredentialRemovals.remove(id) }
            catch { message = "Could not remove retired credentials. AirThrow will retry when the library is reopened." }
        }
        if cleaned.pendingCredentialRemovals != configuration.pendingCredentialRemovals {
            // A failed acknowledgement leaves an idempotent deletion queued on disk.
            do { try await saveConfiguration(cleaned); configuration = cleaned }
            catch { message = "Credential cleanup will be retried when the library is reopened." }
        }
    }
    private func saveShare(_ share: NetworkShare, login: [String]?, remember: Bool) async throws {
        guard store != nil, !savingConfiguration else { throw ShareError.storage }
        savingConfiguration = true
        defer { savingConfiguration = false }
        var saved = share
        let original = configuration.shares.first { $0.id == share.id }
        saved.credentialID = original?.credentialID ?? share.credentialID
        if login != nil { saved.credentialID = UUID() }
        if let login, remember {
            // Persist the cleanup intent before Keychain, including interruption between the stores.
            var staging = configuration
            staging.pendingCredentialRemovals.insert(saved.credentialID)
            try await saveConfiguration(staging)
            configuration = staging
            do { try credentialStore.save(saved.credentialID, username: login[0], password: login[1]) }
            catch { await removeRetiredCredentials(); throw error }
        }
        var updated = configuration
        updated.pendingCredentialRemovals.remove(saved.credentialID)
        if let index = updated.shares.firstIndex(where: { $0.id == share.id }) { updated.shares[index] = saved }
        else { updated.shares.append(saved) }
        if let original, original.credentialID != saved.credentialID {
            updated.pendingCredentialRemovals.insert(original.credentialID)
        }
        do { try await saveConfiguration(updated) }
        catch {
            // Only staged items can be retired here; the old share still owns its credentials.
            await removeRetiredCredentials()
            throw error
        }
        configuration = updated
        if let login { credentials[share.id] = login }
        await removeRetiredCredentials()
    }
    func add(_ share: NetworkShare, username: String, password: String, remember: Bool) async throws {
        let provider: any ShareProvider
        if let providerFactory { provider = try await providerFactory(share) }
        else if share.kind == .webDAV { provider = WebDAVShareProvider(root: share.endpoint, username: username, password: password) }
        else { provider = try await MountedShareProvider.connect(share) }
        _ = try await provider.list("")
        try Task.checkCancellation()
        try await saveShare(share, login: share.kind == .webDAV ? [username, password] : nil, remember: remember)
        suspendedShares.remove(share.id); authorizedShares.insert(share.id); providers[share.id] = provider; connectedShares.insert(share.id)
        browse(share.id, path: "")
    }
    /// Editing an offline/VPN share must never require contacting it.
    func update(_ share: NetworkShare, username: String, password: String, remember: Bool, replaceCredentials: Bool = false) async throws {
        guard let original = configuration.shares.first(where: { $0.id == share.id }) else { throw ShareError.storage }
        let addressChanged = original.endpoint != share.endpoint || original.kind != share.kind
        let replace = replaceCredentials || !username.isEmpty || !password.isEmpty || addressChanged
        let connectionChanged = addressChanged || original.connectAutomatically != share.connectAutomatically || replace
        try await saveShare(share, login: replace ? [username, password] : nil, remember: remember && share.kind == .webDAV)
        guard connectionChanged else { return }
        if activeShare == share.id { browseTask?.cancel(); browserGeneration = UUID(); browsing = false; entries = [] }
        providers[share.id] = nil; connectedShares.remove(share.id); authorizedShares.remove(share.id)
    }
    func remove(_ share: NetworkShare) async {
        guard !savingConfiguration else { message = "A share is being saved. Try again."; return }
        savingConfiguration = true
        defer { savingConfiguration = false }
        do {
            guard let original = configuration.shares.first(where: { $0.id == share.id }) else { return }
            var updated = configuration; updated.shares.removeAll { $0.id == share.id }
            updated.pendingCredentialRemovals.insert(original.credentialID)
            try await saveConfiguration(updated)
            configuration = updated
            if activeShare == share.id { browseTask?.cancel(); browserGeneration = UUID(); browsing = false }
            authorizedShares.remove(share.id); connectedShares.remove(share.id); suspendedShares.remove(share.id)
            histories[share.id] = nil; providers[share.id] = nil; credentials[share.id] = nil
            if activeShare == share.id { activeShare = nil; entries = []; browsing = false }
            await removeRetiredCredentials()
        } catch { message = "The share could not be removed. Try again." }
    }
    func browse(_ id: UUID, path: String, historyIndex: Int? = nil) {
        browseTask?.cancel(); let generation = UUID(); browserGeneration = generation
        activeShare = id; directory = path; entries = []; browsing = false; message = nil
        guard canAccess(id) else { return }
        browsing = true
        browseTask = Task {
            defer { if browserGeneration == generation { browsing = false } }
            do {
                let provider = try await provider(id); let result = try await provider.list(path)
                try Task.checkCancellation(); guard browserGeneration == generation else { return }
                entries = result; offlineShares.remove(id)
                var history = histories[id] ?? ShareNavigation()
                if let historyIndex { history.move(to: historyIndex) } else { history.visit(path) }
                histories[id] = history
            } catch is CancellationError {} catch {
                guard browserGeneration == generation else { return }; offlineShares.insert(id); message = "Could not open this folder. Reconnect the share and try again."
            }
        }
    }
    func show(_ id: UUID) { browse(id, path: histories[id]?.current ?? "") }
    func reconnect(_ id: UUID) {
        guard !unmounting.contains(id) else { return }
        suspendedShares.remove(id); authorizedShares.insert(id)
        providers[id] = nil; connectedShares.remove(id)
        show(id)
    }
    func back() {
        guard let id = activeShare, let history = histories[id], let index = history.backIndex else { return }
        browse(id, path: history.paths[index], historyIndex: index)
    }
    func forward() {
        guard let id = activeShare, let history = histories[id], let index = history.forwardIndex else { return }
        browse(id, path: history.paths[index], historyIndex: index)
    }
    func relatedShares(for id: UUID) -> Set<UUID> {
        guard let share = configuration.shares.first(where: { $0.id == id }), share.kind == .smb else { return [id] }
        return Set(configuration.shares.filter {
            $0.kind == .smb && $0.endpoint.host?.lowercased() == share.endpoint.host?.lowercased()
                && ($0.endpoint.port ?? 445) == (share.endpoint.port ?? 445)
                && $0.endpoint.path.split(separator: "/").first == share.endpoint.path.split(separator: "/").first
        }.map(\.id))
    }
    func unmount(_ id: UUID) async {
        guard !unmounting.contains(id), let provider = providers[id] else { return }
        let affected = relatedShares(for: id)
        unmounting.formUnion(affected)
        defer { unmounting.subtract(affected) }
        if let activeShare, affected.contains(activeShare) {
            browseTask?.cancel(); browserGeneration = UUID(); browsing = false
        }
        do {
            try await provider.disconnect()
            suspendedShares.formUnion(affected)
            authorizedShares.subtract(affected); connectedShares.subtract(affected)
            for id in affected { providers[id] = nil; histories[id] = nil }
            if let activeShare, affected.contains(activeShare) { entries = []; directory = "" }
        } catch { message = "The share could not be unmounted. Close files using it and try again." }
    }
    func resolve(_ reference: URL, allowDownload: Bool = false) async throws -> SharePlayback {
        guard let host = reference.host, let id = UUID(uuidString: host) else { throw ShareError.invalidAddress }
        let path = try SharePath.validate(String(reference.path.dropFirst()))
        let provider = try await provider(id)
        let url: URL
        do { url = try await provider.playbackURL(path) }
        catch ShareError.noRanges where allowDownload {
            guard let dav = provider as? WebDAVShareProvider else { throw ShareError.unavailable }
            downloading = true
            defer { downloading = false }
            let temporary = try TemporaryMediaDownload(filename: (path as NSString).lastPathComponent)
            let destination = temporary.url
            let folder = destination.deletingLastPathComponent()
            let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            let maximum = min(Int64(20 * 1024 * 1024 * 1024), max(0, free - 1024 * 1024 * 1024))
            do {
                downloadBytes = 0
                try await dav.download(path, to: destination, maximumBytes: maximum) { [weak self] bytes in
                    await MainActor.run { self?.downloadBytes = bytes }
                }
                try Task.checkCancellation(); return SharePlayback(url: destination, temporary: temporary)
            } catch { temporary.stop(); throw error }
        }
        try Task.checkCancellation()
        guard let dav = provider as? WebDAVShareProvider else { return SharePlayback(url: url) }
        let login = try await dav.playbackCredentials(path)
        let relay = try await HTTPMediaRelay.start(source: url, credentials: login)
        guard !Task.isCancelled, let local = relay.url else { relay.stop(); throw CancellationError() }
        return SharePlayback(url: local, relay: relay)
    }
    func reference(shareID: UUID, path: String) throws -> URL {
        guard let share = configuration.shares.first(where: { $0.id == shareID }) else { throw ShareError.unavailable }
        return try share.reference(path)
    }
}
