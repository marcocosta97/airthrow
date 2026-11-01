import Foundation
import NetFS
import DiskArbitration
import Security

public enum ShareKind: String, Codable, CaseIterable, Sendable { case webDAV = "WebDAV", smb = "SMB" }
public struct NetworkShare: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: ShareKind
    public var endpoint: URL
    public var connectAutomatically: Bool
    public var credentialID: UUID
    public init(id: UUID = UUID(), name: String, kind: ShareKind, endpoint: URL, connectAutomatically: Bool = false) throws {
        guard endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.host != nil, (kind == .smb ? endpoint.scheme == "smb" : ["http", "https"].contains(endpoint.scheme)),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShareError.invalidAddress }
        self.id = id; self.name = name; self.kind = kind; self.connectAutomatically = connectAutomatically
        credentialID = id
        self.endpoint = kind == .webDAV && !endpoint.path.hasSuffix("/") ? endpoint.appendingPathComponent("", isDirectory: true) : endpoint
    }
    private enum CodingKeys: String, CodingKey { case id, name, kind, endpoint, connectAutomatically, credentialID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      kind: values.decode(ShareKind.self, forKey: .kind), endpoint: values.decode(URL.self, forKey: .endpoint),
                      connectAutomatically: values.decodeIfPresent(Bool.self, forKey: .connectAutomatically) ?? false)
        credentialID = try values.decodeIfPresent(UUID.self, forKey: .credentialID) ?? id
    }
    public func reference(_ path: String) throws -> URL {
        let path = try SharePath.validate(path)
        var parts = URLComponents(); parts.scheme = "airthrow-share"; parts.host = id.uuidString.lowercased(); parts.path = "/" + path
        guard let url = parts.url else { throw ShareError.invalidAddress }; return url
    }
}
public struct ShareEntry: Sendable, Identifiable, Hashable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    public var id: String { path }
    public var isVideo: Bool { !isDirectory && ["mp4", "m4v", "mov", "mkv", "webm"].contains((name as NSString).pathExtension.lowercased()) }
    public init(path: String, name: String, isDirectory: Bool, size: Int64? = nil, modified: Date? = nil) {
        self.path = path; self.name = name; self.isDirectory = isDirectory; self.size = size; self.modified = modified
    }
}
public enum ShareError: Error, LocalizedError {
    case invalidAddress, unavailable, accessDenied, invalidResponse, tooLarge, noRanges, storage, connectionRequired, volumeBusy
    public var errorDescription: String? {
        switch self {
        case .volumeBusy: "The share could not be unmounted. Close files using this volume and try again."
        case .connectionRequired: "Connect this share explicitly before accessing its files."
        case .invalidAddress: "Choose a valid share address and a path inside its root."
        case .unavailable: "The share is unavailable. Check the connection and reconnect."
        case .accessDenied: "Access was denied. Check the share credentials."
        case .invalidResponse: "The server returned an unsupported response."
        case .tooLarge: "This directory or sidecar exceeds the supported size."
        case .noRanges: "This server does not support seeking. Download a temporary copy to play this file."
        case .storage: "The library could not be saved. Check available disk space."
        }
    }
}
public enum SharePath {
    public static func validate(_ path: String) throws -> String {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else { throw ShareError.invalidAddress }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    public static func url(root: URL, path: String) throws -> URL {
        let path = try validate(path)
        return path.isEmpty ? root : root.appendingPathComponent(path)
    }
    public static func relative(_ url: URL, root: URL) throws -> String {
        guard url.scheme == root.scheme, url.host?.lowercased() == root.host?.lowercased(), url.port == root.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw ShareError.invalidAddress }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if url.path == root.path || url.path == String(base.dropLast()) { return "" }
        guard url.path.hasPrefix(base) else { throw ShareError.invalidAddress }
        return try validate(String(url.path.dropFirst(base.count)))
    }
}
public protocol ShareProvider: Sendable {
    func list(_ path: String) async throws -> [ShareEntry]
    func read(_ path: String, maximumBytes: Int) async throws -> Data
    func playbackURL(_ path: String) async throws -> URL
    func disconnect() async throws
}
public extension ShareProvider {
    func disconnect() async throws {}
}

/// Separate service namespace: never queries unrelated credentials.
public enum ShareCredentials {
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "AirThrow.NetworkShares", kSecAttrAccount as String: id.uuidString]
    }
    public static func load(_ id: UUID) throws -> [String]? {
        var q = query(id); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ShareError.accessDenied }
        return try JSONDecoder().decode([String].self, from: data)
    }
    public static func save(_ id: UUID, username: String, password: String) throws {
        let data = try JSONEncoder().encode([username, password])
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(id); q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ShareError.accessDenied }
        } else if status != errSecSuccess { throw ShareError.accessDenied }
    }
    public static func remove(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ShareError.accessDenied }
    }
}

public actor MountedShareProvider: ShareProvider {
    private let root: URL
    private let mountedVolume: URL?
    public init(root: URL) { self.root = root.resolvingSymlinksInPath(); mountedVolume = nil }
    private init(root: URL, mountedVolume: URL) { self.root = root.resolvingSymlinksInPath(); self.mountedVolume = mountedVolume }
    public static func connect(_ share: NetworkShare) async throws -> MountedShareProvider {
        // System authentication is suppressed here. The UI can explicitly open Finder's
        // connection flow; background scans must never produce system dialogs.
        let components = share.endpoint.path.split(separator: "/").map(String.init)
        guard let volume = components.first else { throw ShareError.invalidAddress }
        let suffix = try SharePath.validate(components.dropFirst().joined(separator: "/"))
        var address = URLComponents(url: share.endpoint, resolvingAgainstBaseURL: false)!
        address.path = "/" + volume
        let mount = try NetworkShare(id: share.id, name: share.name, kind: .smb, endpoint: address.url!)
        let operation = ShareMountOperation()
        let root = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in operation.start(mount, continuation: continuation) }
        } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        return MountedShareProvider(root: try SharePath.url(root: root, path: suffix), mountedVolume: root)
    }
    public func usesMountedVolume(_ volume: URL) -> Bool { mountedVolume == volume }
    private func file(_ path: String) throws -> URL {
        let url = try SharePath.url(root: root, path: path).resolvingSymlinksInPath()
        guard url == root || url.path.hasPrefix(root.path + "/") else { throw ShareError.invalidAddress }
        return url
    }
    public func playbackURL(_ path: String) throws -> URL {
        let url = try file(path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ShareError.unavailable }; return url
    }
    public func list(_ path: String) throws -> [ShareEntry] {
        try Task.checkCancellation()
        let directory = try file(path)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        guard urls.count <= 100_000 else { throw ShareError.tooLarge }
        return try urls.compactMap { url in
            try Task.checkCancellation()
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
            guard v.isSymbolicLink != true else { return nil }
            let child = path.isEmpty ? url.lastPathComponent : path + "/" + url.lastPathComponent
            return ShareEntry(path: child, name: url.lastPathComponent, isDirectory: v.isDirectory == true, size: v.fileSize.map(Int64.init), modified: v.contentModificationDate)
        }
    }
    public func disconnect() async throws {
        guard let mountedVolume, let session = DASessionCreate(nil),
              let disk = DADiskCreateFromVolumePath(nil, session, mountedVolume as CFURL) else { throw ShareError.volumeBusy }
        DASessionSetDispatchQueue(session, .main)
        defer { DASessionSetDispatchQueue(session, nil) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Unmanaged.passRetained(UnmountCompletion(continuation)).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, context in
                guard let context else { return }
                let completion = Unmanaged<UnmountCompletion>.fromOpaque(context).takeRetainedValue()
                if dissenter != nil { completion.continuation.resume(throwing: ShareError.volumeBusy) }
                else { completion.continuation.resume() }
            }, context)
        }
    }
    public func read(_ path: String, maximumBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file(path)); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ShareError.tooLarge }; return data
    }
}

/// NetFS does not invoke its completion block after cancellation, so cancellation
/// must also resume our continuation. The lock arbitrates both completion paths.
private final class ShareMountOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: AsyncRequestID?
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false
    func start(_ share: NetworkShare, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let options = CFDictionaryCreateMutableCopy(nil, 0, [kNAUIOptionKey: kNAUIOptionNoUI] as CFDictionary)
        let status = NetFSMountURLAsync(share.endpoint as CFURL, nil, nil, nil, options, nil, &request, .global(qos: .userInitiated)) { [self] status, _, points in
            guard status == 0, let paths = points as? [String], let path = paths.first else {
                complete(.failure(ShareError.unavailable)); return
            }
            let root = URL(fileURLWithPath: path, isDirectory: true)
            guard let actual = NetFSCopyURLForRemountingVolume(root as CFURL)?.takeRetainedValue() as URL?,
                  actual.host?.lowercased() == share.endpoint.host?.lowercased(),
                  actual.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == share.endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
                complete(.failure(ShareError.unavailable)); return
            }
            complete(.success(root))
        }
        lock.unlock()
        if status != 0 { complete(.failure(ShareError.unavailable)) }
    }
    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let continuation = self.continuation; self.continuation = nil; request = nil
        lock.unlock(); continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let request = self.request; self.request = nil
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        if let request { NetFSMountURLCancel(request) }
        continuation?.resume(throwing: CancellationError())
    }
}

private final class UnmountCompletion: @unchecked Sendable {
    let continuation: CheckedContinuation<Void, Error>
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
}

public struct ShareNavigation: Sendable {
    public private(set) var paths: [String] = []
    public private(set) var index = -1
    public var current: String { paths.indices.contains(index) ? paths[index] : "" }
    public var backIndex: Int? { index > 0 ? index - 1 : nil }
    public var forwardIndex: Int? { index + 1 < paths.count ? index + 1 : nil }
    public init() {}
    public mutating func visit(_ path: String) {
        guard paths.isEmpty || current != path else { return }
        paths = Array(paths.prefix(index + 1)); paths.append(path); index = paths.count - 1
    }
    public mutating func move(to index: Int) { if paths.indices.contains(index) { self.index = index } }
}
