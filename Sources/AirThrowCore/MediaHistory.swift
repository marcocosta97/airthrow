import Foundation

public struct MediaHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case video, playlist, iptv, xtream }
    public let id: UUID
    public let url: URL
    public let credentialReference: String?
    public let title: String
    public let kind: Kind
    public let openedAt: Date
    public var isPinned: Bool
    public var location: String { url.isFileURL ? url.lastPathComponent : (url.host ?? "") }

    public init(id: UUID, url: URL, title: String, kind: Kind, openedAt: Date, isPinned: Bool = false, credentialReference: String? = nil) {
        self.credentialReference = credentialReference
        self.id = id; self.url = url; self.title = title; self.kind = kind
        self.openedAt = openedAt; self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey { case id, url, title, kind, openedAt, isPinned, credentialReference }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(URL.self, forKey: .url)
        credentialReference = try values.decodeIfPresent(String.self, forKey: .credentialReference)
        title = try values.decode(String.self, forKey: .title)
        kind = try values.decode(Kind.self, forKey: .kind)
        openedAt = try values.decode(Date.self, forKey: .openedAt)
        // Existing saved history predates pins.
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

@MainActor
public final class MediaHistoryStore {
    public static let maximumEntries = 100
    private static let key = "mediaHistory.v1"
    private let defaults: UserDefaults?
    private let credentials: any MediaHistoryCredentials
    public private(set) var credentialError: String?
    private var resolvedSources: [String: URL] = [:]
    public private(set) var entries: [MediaHistoryEntry]

    public init(defaults: UserDefaults? = .standard, credentials: (any MediaHistoryCredentials)? = nil) {
        self.defaults = defaults
        self.credentials = credentials ?? (defaults == nil ? MemoryMediaHistoryCredentials() : KeychainMediaHistoryCredentials())
        var seen = Set<String>()
        if let data = defaults?.data(forKey: Self.key), data.count <= 4 * 1024 * 1024,
           let decoded = try? JSONDecoder().decode([MediaHistoryEntry].self, from: data) {
            let accepted = decoded.sorted(by: Self.precedes).filter {
                Self.validURL($0.url) && !Self.containsCredentials($0.url) && $0.url.absoluteString.utf8.count <= 16_384
                    && ($0.credentialReference == nil || Self.validReference($0.credentialReference!))
                    && !$0.title.isEmpty && $0.title.count <= 200 && seen.insert(Self.identity($0.url, reference: $0.credentialReference)).inserted
            }
            entries = Array(accepted.prefix(Self.maximumEntries))
            let kept = Set(entries.compactMap(\.credentialReference))
            let dropped = Set(decoded.compactMap(\.credentialReference)).subtracting(kept)
            for reference in dropped where Self.validReference(reference) {
                try? self.credentials.remove(reference: reference)
            }
        } else { entries = [] }
        // Drop legacy plaintext credential entries; never migrate their secrets.
        persist()
    }

    @discardableResult
    public func record(_ url: URL, title: String, kind: MediaHistoryEntry.Kind, preservingExistingTitle: Bool = false) -> UUID? {
        guard (try? MediaInput.source(url.absoluteString)) != nil,
              url.absoluteString.utf8.count <= 16_384 else { return nil }
        credentialError = nil
        let protected = Self.containsCredentials(url)
        let storedURL = protected ? Self.sanitized(url) : url
        // A failed redaction must not fall back to the original secret URL.
        if protected && Self.containsCredentials(storedURL) { return nil }
        let previous = entries.first { entry in
            guard entry.url == storedURL else { return false }
            if !protected { return entry.credentialReference == nil }
            guard let reference = entry.credentialReference else { return false }
            if let cached = resolvedSources[reference] { return cached == url }
            guard let saved = try? credentials.source(reference: reference) else { return false }
            resolvedSources[reference] = saved
            return saved == url
        }
        let reference = protected ? (previous?.credentialReference ?? UUID().uuidString) : nil
        if let reference {
            do { try credentials.save(url, reference: reference); resolvedSources[reference] = url }
            catch let error as MediaHistoryCredentialFailure { credentialError = error.message; return nil }
            catch { credentialError = MediaHistoryCredentialFailure.unavailable.message; return nil }
        }
        let id = previous?.id ?? UUID()
        let cleanTitle = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200))
        let fallback = url.isFileURL ? url.lastPathComponent : (url.host ?? "Video")
        let proposedTitle = cleanTitle.isEmpty ? fallback : cleanTitle
        let displayTitle = preservingExistingTitle ? (previous?.title ?? proposedTitle) : proposedTitle
        entries.removeAll { $0.id == previous?.id }
        entries.insert(MediaHistoryEntry(id: id, url: storedURL, title: displayTitle,
                                         kind: kind, openedAt: Date(), isPinned: previous?.isPinned ?? false, credentialReference: reference), at: 0)
        let sorted = entries.sorted(by: Self.precedes)
        entries = Array(sorted.prefix(Self.maximumEntries))
        deleteCredentials(for: Array(sorted.dropFirst(Self.maximumEntries)))
        persist()
        return id
    }

    public func source(for entry: MediaHistoryEntry) throws -> URL {
        guard let reference = entry.credentialReference else { return entry.url }
        do {
            let source = try credentials.source(reference: reference)
            guard Self.sanitized(source) == entry.url else {
                throw MediaHistoryCredentialFailure.unavailable
            }
            resolvedSources[reference] = source
            return source
        } catch let error as MediaHistoryCredentialFailure {
            throw AppFailure(.invalidRequest, error.message)
        } catch { throw AppFailure(.invalidRequest, MediaHistoryCredentialFailure.unavailable.message) }
    }

    /// Reopening a known entry only changes recency. It must not compare or
    /// rewrite secrets belonging to this entry or other saved accounts.
    public func markOpened(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        entries[index] = MediaHistoryEntry(id: entry.id, url: entry.url, title: entry.title,
            kind: entry.kind, openedAt: Date(), isPinned: entry.isPinned, credentialReference: entry.credentialReference)
        entries.sort(by: Self.precedes)
        persist()
    }
    /// Rename metadata without retrieving or rewriting the saved credentials.
    public func rename(_ id: UUID, title: String) {
        let clean = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries[index]
        entries[index] = MediaHistoryEntry(id: entry.id, url: entry.url, title: clean,
            kind: entry.kind, openedAt: entry.openedAt, isPinned: entry.isPinned, credentialReference: entry.credentialReference)
        persist()
    }

    public func remove(_ id: UUID) {
        credentialError = nil
        let removed = entries.filter { $0.id == id }
        entries.removeAll { $0.id == id }; deleteCredentials(for: removed); persist()
    }
    public func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned.toggle()
        entries.sort(by: Self.precedes)
        persist()
    }
    public func clear() {
        credentialError = nil
        let removed = entries.filter { !$0.isPinned }
        entries.removeAll { !$0.isPinned }; deleteCredentials(for: removed); persist()
    }
    public func clearIncludingPinned() {
        credentialError = nil
        let removed = entries; entries = []; deleteCredentials(for: removed); persist()
    }
    private func deleteCredentials(for removed: [MediaHistoryEntry]) {
        for reference in Set(removed.compactMap(\.credentialReference)) where !entries.contains(where: { $0.credentialReference == reference }) {
            resolvedSources[reference] = nil
            do { try credentials.remove(reference: reference) }
            catch { credentialError = "Could not remove saved credentials from Keychain." }
        }
    }
    private static func identity(_ url: URL, reference: String?) -> String { reference ?? url.absoluteString }
    private static func validReference(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    private static func containsCredentials(_ url: URL) -> Bool { MediaURLSecrets.contains(url) }
    private static func sanitized(_ url: URL) -> URL { MediaURLSecrets.sanitized(url) }
    private static func precedes(_ lhs: MediaHistoryEntry, _ rhs: MediaHistoryEntry) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return lhs.openedAt > rhs.openedAt
    }
    private func persist() {
        guard !entries.isEmpty else { defaults?.removeObject(forKey: Self.key); return }
        if let data = try? JSONEncoder().encode(entries) { defaults?.set(data, forKey: Self.key) }
    }
    private static func validURL(_ url: URL) -> Bool {
        // File availability is checked when reopening, so moved/deleted files
        // remain removable history entries rather than disappearing silently.
        if url.isFileURL {
            return (url.host == nil || url.host == "" || url.host == "localhost") && url.path.hasPrefix("/")
                && url.query == nil && url.fragment == nil && url.user == nil && url.password == nil
        }
        return (try? MediaInput.url(url.absoluteString)) != nil
    }
}
