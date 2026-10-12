import Foundation

private struct Failure: Error { let message: String }
@MainActor private final class UnavailableCredentials: MediaHistoryCredentials {
    func save(_ source: URL, reference: String) throws { throw MediaHistoryCredentialFailure.unavailable }
    func source(reference: String) throws -> URL { throw MediaHistoryCredentialFailure.unavailable }
    func remove(reference: String) throws { throw MediaHistoryCredentialFailure.unavailable }
}
@MainActor private final class CountingCredentials: MediaHistoryCredentials {
    let memory = MemoryMediaHistoryCredentials()
    var reads = 0
    var writes = 0
    func save(_ source: URL, reference: String) throws { writes += 1; try memory.save(source, reference: reference) }
    func source(reference: String) throws -> URL { reads += 1; return try memory.source(reference: reference) }
    func remove(reference: String) throws { try memory.remove(reference: reference) }
}
@main struct HistoryCredentialChecks {
    @MainActor static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure(message: message) }
            count += 1; print("PASS", message)
        }
        let suite = "it.mcosta.airthrow.credential-checks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MemoryMediaHistoryCredentials()
        let store = MediaHistoryStore(defaults: defaults, credentials: backend)
        let url = URL(string: "https://provider.example/proxy/get.php?username=private%2Buser&password=private%26pass&type=m3u_plus&output=ts&token=a%2Bb")!
        let counting = CountingCredentials()
        let recent = MediaHistoryStore(defaults: nil, credentials: counting)
        recent.record(url, title: "Account one", kind: .xtream)
        recent.record(URL(string: url.absoluteString.replacingOccurrences(of: "private%2Buser", with: "another-user"))!, title: "Account two", kind: .xtream)
        let first = recent.entries.last!
        recent.togglePin(first.id)
        let writes = counting.writes, reads = counting.reads
        recent.markOpened(first.id)
        try check(counting.writes == writes && counting.reads == reads && recent.entries.first?.id == first.id
                  && recent.entries.first?.isPinned == true && recent.entries.first?.credentialReference == first.credentialReference,
                  "Reopening history updates recency without reading or rewriting any account credentials")
        store.record(url, title: "Provider", kind: .xtream)
        let entry = store.entries[0]
        let reference = entry.credentialReference!
        let saved = String(decoding: defaults.data(forKey: "mediaHistory.v1")!, as: UTF8.self)
        try check(!saved.contains("private") && !saved.contains("username") && !saved.contains("password"), "Preferences contain no credential fields or values")
        try check(entry.url.query == "type=m3u_plus&output=ts&token=a%2Bb", "Sanitized location preserves exact nonsensitive query encoding")
        let reopened = MediaHistoryStore(defaults: defaults, credentials: backend)
        try check(try reopened.source(for: reopened.entries[0]) == url, "Reopening obtains exact credential-bearing source from secure store")
        store.togglePin(entry.id); store.record(url, title: "Provider again", kind: .xtream)
        try check(store.entries.count == 1 && store.entries[0].id == entry.id && store.entries[0].isPinned, "Sensitive history deduplicates while preserving ID and pin")
        store.record(URL(string: url.absoluteString.replacingOccurrences(of: "private%2Buser", with: "another-user"))!, title: "Other account", kind: .xtream)
        try check(store.entries.count == 2, "Different accounts on one server retain distinct references")
        store.clear()
        try check((try backend.source(reference: reference)) == url && store.entries.count == 1, "Clear History retains pinned credentials")
        store.remove(entry.id)
        do { _ = try backend.source(reference: reference); throw Failure(message: "Removed secret retained") }
        catch MediaHistoryCredentialFailure.unavailable { try check(true, "Removing pinned entry deletes its secure-store secret") }
        store.record(url, title: "Missing credentials", kind: .xtream)
        try backend.remove(reference: store.entries[0].credentialReference!)
        do { _ = try store.source(for: store.entries[0]); throw Failure(message: "Missing secret silently used sanitized URL") }
        catch let failure as AppFailure { try check(failure.message == MediaHistoryCredentialFailure.unavailable.message, "Missing credentials produce actionable message") }
        let legacy = MediaHistoryEntry(id: UUID(), url: url, title: "Old account", kind: .xtream, openedAt: Date(), isPinned: true)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "mediaHistory.v1")
        let discarded = MediaHistoryStore(defaults: defaults, credentials: backend)
        try check(discarded.entries.isEmpty && defaults.data(forKey: "mediaHistory.v1") == nil, "Legacy plaintext including pins is discarded without migration")
        let unavailable = MediaHistoryStore(defaults: defaults, credentials: UnavailableCredentials())
        unavailable.record(url, title: "Unavailable", kind: .xtream)
        try check(unavailable.entries.isEmpty && unavailable.credentialError != nil && defaults.data(forKey: "mediaHistory.v1") == nil, "Keychain failure never falls back to plaintext")
        store.clearIncludingPinned()
        store.record(url, title: "Evicted", kind: .xtream)
        let evicted = store.entries[0].credentialReference!
        for n in 0..<MediaHistoryStore.maximumEntries { store.record(URL(string: "https://public.example/\(n).mp4")!, title: "Video \(n)", kind: .video) }
        do { _ = try backend.source(reference: evicted); throw Failure(message: "Evicted secret retained") }
        catch MediaHistoryCredentialFailure.unavailable { try check(true, "History eviction deletes unreferenced credentials") }
        if CommandLine.arguments.contains("--keychain") {
        let keychain = KeychainMediaHistoryCredentials(service: suite, allowInteraction: false)
        let testReference = UUID().uuidString
        defer { try? keychain.remove(reference: testReference) }
        try keychain.save(url, reference: testReference)
        let reopenedKeychain = KeychainMediaHistoryCredentials(service: suite, allowInteraction: false)
        try check(try reopenedKeychain.source(reference: testReference) == url, "New session reads encrypted fixture from real Keychain without authentication UI")
        // Delete only this test's newly generated item using a separate session.
        // The already unlocked session must keep working without another read.
        try reopenedKeychain.remove(reference: testReference)
        try check(try keychain.source(reference: testReference) == url, "Active session reuses credentials without another Keychain read")
        try keychain.save(url, reference: testReference)
        do { _ = try reopenedKeychain.source(reference: testReference); throw Failure(message: "Unchanged account was rewritten") }
        catch MediaHistoryCredentialFailure.unavailable { try check(true, "Reopening an unchanged account does not request another Keychain write") }
        let changed = URL(string: url.absoluteString.replacingOccurrences(of: "private%26pass", with: "new-pass"))!
        try keychain.save(changed, reference: testReference)
        try check(try keychain.source(reference: testReference) == changed, "Real Keychain updates existing item")
        let newSession = KeychainMediaHistoryCredentials(service: suite, allowInteraction: false)
        try check(try newSession.source(reference: testReference) == changed, "Changed credentials remain encrypted and readable in a fresh session")
        try keychain.remove(reference: testReference)
        do { _ = try keychain.source(reference: testReference); throw Failure(message: "Real Keychain item retained") }
        catch MediaHistoryCredentialFailure.unavailable { try check(true, "Real Keychain removal verified") }
        }
        print("History credential checks: \(count) passed.")
    }
}
