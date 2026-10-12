import Foundation
import Security

@MainActor
public protocol MediaHistoryCredentials: AnyObject {
    func save(_ source: URL, reference: String) throws
    func source(reference: String) throws -> URL
    func remove(reference: String) throws
}

public enum MediaHistoryCredentialFailure: Error {
    case unavailable
    public var message: String { "The saved credentials are unavailable in Keychain. Add the server again." }
}

/// Keychain stores the original URL; preferences contain only a sanitized URL and opaque reference.
@MainActor
public final class KeychainMediaHistoryCredentials: MediaHistoryCredentials {
    private let service: String
    private let allowInteraction: Bool
    // The active session already holds its account in memory. Reuse successful
    // reads without repeatedly requesting access to the encrypted disk store.
    private var sessionSources: [String: URL] = [:]
    public init(service: String = "it.mcosta.airthrow.media-history", allowInteraction: Bool = true) {
        self.service = service; self.allowInteraction = allowInteraction
    }
    private func query(_ reference: String) -> [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: reference,
            kSecAttrSynchronizable as String: false]
        if !allowInteraction { result[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return result
    }
    public func save(_ source: URL, reference: String) throws {
        if sessionSources[reference] == source { return }
        let query = query(reference)
        let value = [kSecValueData as String: Data(source.absoluteString.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value[kSecValueData as String]
            item[kSecAttrLabel as String] = "AirThrow saved server"
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw MediaHistoryCredentialFailure.unavailable }
        } else if status != errSecSuccess { throw MediaHistoryCredentialFailure.unavailable }
        sessionSources[reference] = source
    }
    public func source(reference: String) throws -> URL {
        if let source = sessionSources[reference] { return source }
        var query = query(reference)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, let text = String(data: data, encoding: .utf8),
              let url = try? MediaInput.url(text) else { throw MediaHistoryCredentialFailure.unavailable }
        sessionSources[reference] = url
        return url
    }
    public func remove(reference: String) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MediaHistoryCredentialFailure.unavailable }
        sessionSources.removeValue(forKey: reference)
    }
}

/// Ephemeral sessions and deterministic checks never write to the user's Keychain.
@MainActor
public final class MemoryMediaHistoryCredentials: MediaHistoryCredentials {
    private var values: [String: URL] = [:]
    public init() {}
    public func save(_ source: URL, reference: String) throws { values[reference] = source }
    public func source(reference: String) throws -> URL {
        guard let value = values[reference] else { throw MediaHistoryCredentialFailure.unavailable }
        return value
    }
    public func remove(reference: String) throws { values[reference] = nil }
}
