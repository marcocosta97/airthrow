import Foundation
import CSQLite

public struct ShareLibraryConfiguration: Codable, Sendable {
    public var shares: [NetworkShare] = []
    public var pendingCredentialRemovals: Set<UUID> = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case shares, pendingCredentialRemovals }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shares = try values.decode([NetworkShare].self, forKey: .shares)
        pendingCredentialRemovals = try values.decodeIfPresent(Set<UUID>.self, forKey: .pendingCredentialRemovals) ?? []
    }
}
// Keep the existing configuration row and location so saved connections survive
// removal of the experimental catalog. Catalog rows are never loaded.
private final class ShareConfigurationDatabase: @unchecked Sendable {
    var handle: OpaquePointer?
    init(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw ShareError.storage }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(handle) }
}
public actor NetworkShareStore {
    private let db: ShareConfigurationDatabase
    public init(url: URL) throws {
        db = try ShareConfigurationDatabase(url)
        guard sqlite3_exec(db.handle, "CREATE TABLE IF NOT EXISTS library(key TEXT PRIMARY KEY, value BLOB NOT NULL); PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK else { throw ShareError.storage }
    }
    private func put<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value); var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, "INSERT OR REPLACE INTO library VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK else { throw ShareError.storage }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ShareError.storage }
    }
    private func values<T: Decodable>(_ type: T.Type, prefix: String) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, "SELECT value FROM library WHERE key LIKE ?", -1, &stmt, nil) == SQLITE_OK else { throw ShareError.storage }
        defer { sqlite3_finalize(stmt) }
        _ = (prefix + "%").withCString { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw ShareError.storage }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard count <= 4 * 1024 * 1024, let bytes = sqlite3_column_blob(stmt, 0) else { throw ShareError.storage }
            result.append(try JSONDecoder().decode(type, from: Data(bytes: bytes, count: count)))
        }
        return result
    }
    public func configuration() throws -> ShareLibraryConfiguration { try values(ShareLibraryConfiguration.self, prefix: "configuration").first ?? ShareLibraryConfiguration() }
    public func save(_ configuration: ShareLibraryConfiguration) throws { try put(configuration, key: "configuration") }
}
