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

/// Fixed errors keep adapter implementation details out of status.
public enum SourceRegistryError: Error, Sendable, Equatable {
    case invalidAdapter, duplicateProvider, duplicateHost, duplicateFallback
}

/// Exact domain dispatch with one optional website fallback. Local files and
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
            guard Self.validID(adapter.id),
                  Self.validHosts(adapter.hosts, fallback: adapter.isFallback) else {
                throw SourceRegistryError.invalidAdapter
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

    public func adapter(for url: URL) -> (any SourceAdapter)? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return nil }
        let registered = byHost[host]
        if SourceResolver.isDirectMediaHint(url) { return registered?.handlesDirectMediaURLs == true ? registered : nil }
        return registered ?? fallback
    }
}
