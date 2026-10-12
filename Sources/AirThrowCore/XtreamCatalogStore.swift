import Foundation
import CryptoKit

/// Optional saved catalog data. Account credentials and stream URLs are not encoded.
public actor XtreamCatalogStore {
    public static let preferenceKey = "saveXtreamCatalogs"
    public static let shared = XtreamCatalogStore(enabled: UserDefaults.standard.bool(forKey: preferenceKey))
    public struct Snapshot: Codable, Sendable {
        public let categories: [XtreamCategory]
        public let listing: XtreamListing
        fileprivate let version: Int
        public init(categories: [XtreamCategory], listing: XtreamListing) {
            self.categories = categories; self.listing = listing; version = 1
        }
    }
    private let directory: URL
    private var enabled: Bool
    private static let maximumBytes = 64 * 1024 * 1024

    public init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("AirThrow/XtreamCatalogs", isDirectory: true), enabled: Bool = false) {
        self.directory = directory; self.enabled = enabled
    }
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { try? FileManager.default.removeItem(at: directory) }
    }
    public func load(account: XtreamAccount, section: XtreamSection, categoryID: String?) -> Snapshot? {
        guard enabled else { return nil }
        let file = file(account, section, categoryID)
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= Self.maximumBytes else { return nil }
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maximumBytes else { return nil }
            let result = try JSONDecoder().decode(Snapshot.self, from: data)
            guard result.version == 1 else { return nil }
            return result
        } catch { return nil }
    }
    public func save(_ snapshot: Snapshot, account: XtreamAccount, section: XtreamSection, categoryID: String?) {
        guard enabled, !Task.isCancelled else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= Self.maximumBytes, !Task.isCancelled else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = file(account, section, categoryID)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* A disk cache failure must not prevent browsing. */ }
    }
    public func invalidate(account: XtreamAccount, section: XtreamSection) {
        guard enabled else { return }
        let prefix = accountID(account) + "-" + section.rawValue + "-"
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
    }
    private func file(_ account: XtreamAccount, _ section: XtreamSection, _ categoryID: String?) -> URL {
        directory.appendingPathComponent(accountID(account) + "-" + section.rawValue + "-" + digest(categoryID.map { "category:" + $0 } ?? "all") + ".json")
    }
    private func accountID(_ account: XtreamAccount) -> String {
        // Cache identity must not publish a password-derived digest outside Keychain.
        let identity = [account.server.absoluteString, account.username, account.format.rawValue]
        let data = (try? JSONEncoder().encode(identity)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
