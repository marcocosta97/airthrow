import Foundation

/// Discovery only: adapters return complete presentations for the shared
/// selector and never own the player or decide conversion permissions.
public protocol SourceAdapter: Sendable {
    var id: String { get }
    var hosts: [String] { get }
    var isFallback: Bool { get }
    var handlesDirectMediaURLs: Bool { get }
    func candidates(for url: URL) async throws -> [MediaCandidate]
}

public extension SourceAdapter {
    var isFallback: Bool { false }
    var handlesDirectMediaURLs: Bool { false }
}

/// Fixed errors keep manifest contents and filesystem paths out of status.
public enum SourceRegistryError: Error, Sendable, Equatable {
    case invalidManifest, duplicateProvider, duplicateHost, duplicateFallback, unavailableManifests
}

/// A bundled declaration for an extractor already installed with yt-dlp.
/// Headers, cookies, helper options and executable paths are not source options.
public struct YTDLPSourceManifest: Decodable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let hosts: [String]
    public let extractors: [String]
    public let fallback: Bool

    public init(schemaVersion: Int = 1, id: String, name: String, hosts: [String],
                extractors: [String], fallback: Bool = false) throws {
        guard schemaVersion == 1, Self.validID(id), !name.trimmingCharacters(in: .whitespaces).isEmpty,
              name.count <= 128, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              Self.validHosts(hosts, fallback: fallback), (1...16).contains(extractors.count),
              Set(extractors.map { $0.lowercased() }).count == extractors.count,
              extractors.allSatisfy(Self.validExtractor),
              fallback ? extractors == ["generic"] : !extractors.contains(where: { $0.lowercased() == "generic" }) else {
            throw SourceRegistryError.invalidManifest
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.hosts = hosts
        self.extractors = extractors
        self.fallback = fallback
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, id, name, hosts, extractors, fallback
    }
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard all.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw SourceRegistryError.invalidManifest
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
                      id: values.decode(String.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      hosts: values.decode([String].self, forKey: .hosts),
                      extractors: values.decode([String].self, forKey: .extractors),
                      fallback: values.decodeIfPresent(Bool.self, forKey: .fallback) ?? false)
    }

    static func validID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first, (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    static func validHosts(_ hosts: [String], fallback: Bool) -> Bool {
        if fallback { return hosts.isEmpty }
        guard (1...32).contains(hosts.count), Set(hosts).count == hosts.count else { return false }
        return hosts.allSatisfy { host in
            guard host.utf8.count <= 253, host == host.lowercased() else { return false }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2 else { return false }
            return labels.allSatisfy { label in
                let bytes = Array(label.utf8)
                func alphanumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
                guard (1...63).contains(bytes.count), let first = bytes.first, let last = bytes.last,
                      alphanumeric(first), alphanumeric(last) else { return false }
                return bytes.allSatisfy { alphanumeric($0) || $0 == 45 }
            }
        }
    }

    private static func validExtractor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphanumeric(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        }
        guard (1...128).contains(bytes.count), let first = bytes.first, alphanumeric(first),
              !["all", "default", "end"].contains(value.lowercased()) else { return false }
        return bytes.allSatisfy { alphanumeric($0) || $0 == 95 || $0 == 58 || $0 == 45 }
    }

    /// Reads at most 64 regular JSON files, each at most 64 KiB. All files must
    /// validate; a broken provider is never silently replaced by another source.
    public static func load(from directory: URL) throws -> [YTDLPSourceManifest] {
        guard directory.isFileURL else { throw SourceRegistryError.unavailableManifests }
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch { throw SourceRegistryError.unavailableManifests }
        guard !entries.isEmpty else { throw SourceRegistryError.unavailableManifests }
        guard entries.count <= 64 else { throw SourceRegistryError.invalidManifest }
        return try entries.map { file in
            do {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
                    throw SourceRegistryError.invalidManifest
                }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let bytes = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
                guard bytes.count <= 64 * 1024 else { throw SourceRegistryError.invalidManifest }
                return try JSONDecoder().decode(YTDLPSourceManifest.self, from: bytes)
            } catch { throw SourceRegistryError.invalidManifest }
        }
    }
}

/// Exact domain dispatch with one optional generic fallback. Local files and
/// recognizable direct media bypass website extraction.
public struct SourceRegistry: Sendable {
    public let providerIDs: [String]
    private let byHost: [String: any SourceAdapter]
    private let fallback: (any SourceAdapter)?

    public init(adapters: [any SourceAdapter]) throws {
        var ids = Set<String>()
        var byHost: [String: any SourceAdapter] = [:]
        var fallback: (any SourceAdapter)?
        for adapter in adapters {
            guard YTDLPSourceManifest.validID(adapter.id),
                  YTDLPSourceManifest.validHosts(adapter.hosts, fallback: adapter.isFallback) else {
                throw SourceRegistryError.invalidManifest
            }
            guard ids.insert(adapter.id).inserted else { throw SourceRegistryError.duplicateProvider }
            if adapter.isFallback {
                guard fallback == nil else { throw SourceRegistryError.duplicateFallback }
                fallback = adapter
            }
            for host in adapter.hosts {
                guard byHost[host] == nil else { throw SourceRegistryError.duplicateHost }
                byHost[host] = adapter
            }
        }
        self.providerIDs = adapters.map(\.id)
        self.byHost = byHost
        self.fallback = fallback
    }

    public func adapter(for url: URL) -> (any SourceAdapter)? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return nil }
        let registered = byHost[host]
        if SourceResolver.isDirectMediaHint(url) { return registered?.handlesDirectMediaURLs == true ? registered : nil }
        return registered ?? fallback
    }
}
