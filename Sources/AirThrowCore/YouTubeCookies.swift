import Foundation
import SQLite3
import Security
import CommonCrypto

/// Cookie material for YouTube extraction. AirThrow never hands yt-dlp a raw
/// browser cookie store: browser and file sources are both reduced to the
/// YouTube-owned domains below, written to a private temporary Netscape file,
/// and deleted after the helper exits. Cookie values are never logged, never
/// given to status text, and never embedded in media identifiers.
public enum YouTubeCookies: Sendable, Equatable {
    case none
    case browser(String)
    case file(URL)

    public static let fileEnvironmentKey = "AIRTHROW_YTDLP_COOKIES"
    public static let browserEnvironmentKey = "AIRTHROW_YTDLP_COOKIES_FROM_BROWSER"
    public static let supportedBrowsers = [
        "brave", "chrome", "chromium", "edge", "firefox", "opera", "safari", "vivaldi", "whale",
    ]

    /// A file path wins over a browser when both overrides are present. An
    /// unknown browser name falls back to no cookies rather than reaching the
    /// helper with an argument it might reject.
    public static func fromEnvironment(_ environment: [String: String]) -> YouTubeCookies {
        if let path = environment[fileEnvironmentKey]?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            return .file(URL(fileURLWithPath: path))
        }
        if let browser = environment[browserEnvironmentKey]?.trimmingCharacters(in: .whitespaces).lowercased(),
           supportedBrowsers.contains(browser) {
            return .browser(browser)
        }
        return .none
    }
}

/// The result of checking a configured cookie source, used to tell the user
/// whether YouTube cookies are actually available before they load a video.
public enum YouTubeCookieStatus: Sendable, Equatable {
    case none
    case loaded(Int)
    case notInstalled
    case permissionDenied
    case noSession
    case unavailable
}

/// The cookie domains that can carry a YouTube session. Kept deliberately
/// narrow: no Google-wide or unrelated domains are ever imported.
enum YouTubeCookieScope {
    static let domains = ["youtube.com", "youtu.be", "youtube-nocookie.com"]

    /// The definitive signed-in marker. `LOGIN_INFO` is what yt-dlp relies on
    /// for YouTube authentication; PSID-style cookies can linger after a session
    /// is invalid, so their presence alone is not treated as a session.
    static let authenticationName = "LOGIN_INFO"

    static func includes(_ domain: String) -> Bool {
        var value = domain.lowercased()
        while value.hasPrefix(".") { value.removeFirst() }
        guard !value.isEmpty else { return false }
        return domains.contains { value == $0 || value.hasSuffix("." + $0) }
    }

    static func hasAuthentication(_ cookies: [NetscapeCookie]) -> Bool {
        cookies.contains { $0.name == authenticationName }
    }
}

/// One Netscape cookies.txt record. `domain` keeps any leading dot so
/// subdomain inclusion is preserved exactly.
struct NetscapeCookie: Equatable {
    var domain: String
    var includeSubdomains: Bool
    var path: String
    var secure: Bool
    var expires: Int64
    var name: String
    var value: String
    var httpOnly: Bool = false

    var line: String {
        let domainField = (httpOnly ? "#HttpOnly_" : "") + domain
        return [domainField, includeSubdomains ? "TRUE" : "FALSE", path,
                secure ? "TRUE" : "FALSE", String(expires), name, value].joined(separator: "\t")
    }
}

enum NetscapeCookies {
    static func parse(_ text: String) -> [NetscapeCookie] {
        var result: [NetscapeCookie] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { continue }
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") {
                continue
            }
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 7 else { continue }
            let domain = fields[0]
            let name = fields[5]
            guard !domain.isEmpty, !name.isEmpty else { continue }
            result.append(NetscapeCookie(domain: domain,
                                         includeSubdomains: fields[1].uppercased() == "TRUE",
                                         path: fields[2],
                                         secure: fields[3].uppercased() == "TRUE",
                                         expires: Int64(fields[4]) ?? 0,
                                         name: name,
                                         value: fields[6...].joined(separator: "\t"),
                                         httpOnly: httpOnly))
        }
        return result
    }

    /// Keep only cookies that can carry a YouTube session.
    static func youtube(_ cookies: [NetscapeCookie]) -> [NetscapeCookie] {
        cookies.filter { YouTubeCookieScope.includes($0.domain) }
    }

    static func serialize(_ cookies: [NetscapeCookie]) -> String {
        let header = "# Netscape HTTP Cookie File\n# Generated by AirThrow; YouTube cookies only; deleted after use.\n"
        guard !cookies.isEmpty else { return header }
        return header + cookies.map(\.line).joined(separator: "\n") + "\n"
    }
}

/// A private temporary cookie file. `cleanup` removes the whole scratch
/// directory, so no cookie material outlives the helper invocation.
struct CookieScratch {
    let directory: URL?
    let path: String?

    static let empty = CookieScratch(directory: nil, path: nil)

    func cleanup() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

extension YouTubeCookies {
    /// Reduce the configured source to YouTube cookies and expose them through a
    /// private temporary file. An empty result means yt-dlp runs without
    /// cookies, matching the pre-cookie behavior.
    func materialize(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CookieScratch {
        let cookies: [NetscapeCookie]
        switch self {
        case .none:
            return .empty
        case .file(let url):
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
            cookies = NetscapeCookies.youtube(NetscapeCookies.parse(text))
        case .browser(let name):
            cookies = BrowserCookieReader.youtubeCookies(browser: name, home: home)
        }
        guard !cookies.isEmpty else { return .empty }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("athrow-cookies-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("cookies.txt")
            try Data(NetscapeCookies.serialize(cookies).utf8).write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return CookieScratch(directory: directory, path: file.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return .empty
        }
    }

    /// Browsers that are installed or have on-disk data, so the picker never
    /// offers a source that cannot possibly produce cookies. Safari ships with
    /// macOS and is always offered.
    public static func installedBrowsers(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        supportedBrowsers.filter { BrowserCookieReader.isInstalled(browser: $0, home: home) }
    }

    /// Check the configured source without exposing cookie values. Used by the
    /// Settings status row to distinguish "loaded" from a missing session or a
    /// denied permission.
    public func probe(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> YouTubeCookieStatus {
        switch self {
        case .none:
            return .none
        case .file(let url):
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .unavailable }
            let youtube = NetscapeCookies.youtube(NetscapeCookies.parse(text))
            guard !youtube.isEmpty, YouTubeCookieScope.hasAuthentication(youtube) else { return .noSession }
            return .loaded(youtube.count)
        case .browser(let name):
            switch BrowserCookieReader.outcome(browser: name, home: home) {
            case .cookies(let cookies):
                guard YouTubeCookieScope.hasAuthentication(cookies) else { return .noSession }
                return .loaded(cookies.count)
            case .notInstalled: return .notInstalled
            case .permissionDenied: return .permissionDenied
            case .noSession: return .noSession
            case .failed: return .unavailable
            }
        }
    }
}

/// Why a browser read produced no cookies, so the UI can explain the failure
/// instead of silently falling back to an unauthenticated request.
enum BrowserCookieOutcome {
    case cookies([NetscapeCookie])
    case notInstalled
    case permissionDenied
    case noSession
    case failed
}

/// Reads YouTube cookies directly out of a browser's own store, filtering in the
/// data source where possible so unrelated cookies are never loaded.
enum BrowserCookieReader {
    static func outcome(browser: String, home: URL) -> BrowserCookieOutcome {
        switch browser {
        case "safari": return safari(home: home)
        case "firefox": return firefox(home: home)
        case "brave", "chrome", "chromium", "edge", "opera", "vivaldi", "whale":
            return chromium(browser: browser, home: home)
        default: return .failed
        }
    }

    static func youtubeCookies(browser: String, home: URL) -> [NetscapeCookie] {
        if case .cookies(let cookies) = outcome(browser: browser, home: home) { return cookies }
        return []
    }

    static func isInstalled(browser: String, home: URL) -> Bool {
        if browser == "safari" { return true }
        let bases = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        for base in bases {
            for name in applicationNames(browser) where FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path) {
                return true
            }
        }
        if browser == "firefox" {
            return FileManager.default.fileExists(atPath: firefoxProfiles(home).path)
        }
        guard let configuration = chromiumConfiguration(browser) else { return false }
        return FileManager.default.fileExists(atPath: chromiumRoot(home, configuration).path)
    }

    private static func applicationNames(_ browser: String) -> [String] {
        switch browser {
        case "brave": return ["Brave Browser.app"]
        case "chrome": return ["Google Chrome.app"]
        case "chromium": return ["Chromium.app"]
        case "edge": return ["Microsoft Edge.app"]
        case "firefox": return ["Firefox.app"]
        case "opera": return ["Opera.app", "Opera GX.app"]
        case "vivaldi": return ["Vivaldi.app"]
        case "whale": return ["Whale.app"]
        default: return []
        }
    }

    // MARK: - Safari

    private static func safari(home: URL) -> BrowserCookieOutcome {
        let candidates = [
            home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"),
            home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
        ]
        var permissionDenied = false
        for url in candidates {
            do {
                let data = try Data(contentsOf: url)
                guard let parsed = SafariCookies.parse(data) else { return .failed }
                let youtube = NetscapeCookies.youtube(parsed)
                return youtube.isEmpty ? .noSession : .cookies(youtube)
            } catch {
                if isPermissionDenied(error) { permissionDenied = true }
            }
        }
        // Safari ships with macOS, so a missing store means no session, not a
        // missing browser.
        return permissionDenied ? .permissionDenied : .noSession
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM)) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EACCES) || underlying.code == Int(EPERM) { return true }
        return false
    }

    // MARK: - Firefox

    private static func firefoxProfiles(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
    }

    private static func firefox(home: URL) -> BrowserCookieOutcome {
        let profiles = firefoxProfiles(home)
        guard FileManager.default.fileExists(atPath: profiles.path) else { return .notInstalled }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: profiles, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var databases = entries.map { $0.appendingPathComponent("cookies.sqlite") }
        databases.append(profiles.appendingPathComponent("cookies.sqlite"))
        let existing = databases.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let newest = existing.max(by: { modificationDate($0) < modificationDate($1) }) else { return .noSession }
        guard let database = SQLiteDatabase(path: newest.path) else { return .failed }
        let schema = database.scalarInt("PRAGMA user_version;") ?? 0
        let rows = database.query("""
            SELECT host, name, value, path, expiry, isSecure FROM moz_cookies
            WHERE host = 'youtube.com' OR host LIKE '%.youtube.com'
               OR host = 'youtu.be' OR host LIKE '%.youtu.be'
               OR host = 'youtube-nocookie.com' OR host LIKE '%.youtube-nocookie.com'
            """)
        var cookies: [NetscapeCookie] = []
        for row in rows {
            guard row.count >= 6, case .text(let host) = row[0],
                  case .text(let name) = row[1], case .text(let value) = row[2] else { continue }
            let path = row[3].string ?? "/"
            // Firefox 142+ (schema 16) records expiry in milliseconds.
            var expires = row[4].integer ?? 0
            if schema >= 16 { expires /= 1000 }
            cookies.append(NetscapeCookie(domain: host, includeSubdomains: host.hasPrefix("."),
                                          path: path, secure: (row[5].integer ?? 0) != 0,
                                          expires: expires, name: name, value: value))
        }
        return cookies.isEmpty ? .noSession : .cookies(cookies)
    }

    // MARK: - Chromium family

    private struct ChromiumConfiguration {
        let directory: String
        let keyring: String
    }

    private static func chromiumConfiguration(_ browser: String) -> ChromiumConfiguration? {
        switch browser {
        case "brave": return ChromiumConfiguration(directory: "BraveSoftware/Brave-Browser", keyring: "Brave")
        case "chrome": return ChromiumConfiguration(directory: "Google/Chrome", keyring: "Chrome")
        case "chromium": return ChromiumConfiguration(directory: "Chromium", keyring: "Chromium")
        case "edge": return ChromiumConfiguration(directory: "Microsoft Edge", keyring: "Microsoft Edge")
        case "opera": return ChromiumConfiguration(directory: "com.operasoftware.Opera", keyring: "Opera")
        case "vivaldi": return ChromiumConfiguration(directory: "Vivaldi", keyring: "Vivaldi")
        case "whale": return ChromiumConfiguration(directory: "Naver/Whale", keyring: "Whale")
        default: return nil
        }
    }

    private static func chromiumRoot(_ home: URL, _ configuration: ChromiumConfiguration) -> URL {
        home.appendingPathComponent("Library/Application Support/\(configuration.directory)")
    }

    private enum KeychainResult {
        case key([UInt8])
        case denied
        case missing
    }

    private static func chromium(browser: String, home: URL) -> BrowserCookieOutcome {
        guard let configuration = chromiumConfiguration(browser) else { return .failed }
        let root = chromiumRoot(home, configuration)
        guard FileManager.default.fileExists(atPath: root.path) else { return .notInstalled }
        guard let file = newestCookiesFile(root: root, depth: 0) else { return .noSession }
        guard let database = SQLiteDatabase(path: file.path) else { return .failed }
        let metaVersion = database.scalarInt("SELECT value FROM meta WHERE key = 'version'") ?? 0
        let columns = database.query("PRAGMA table_info(cookies)").compactMap { $0.count >= 2 ? $0[1].string : nil }
        let secureColumn = columns.contains("is_secure") ? "is_secure" : "secure"
        let keyResult = chromiumKey(keyring: configuration.keyring)
        let key: [UInt8]?
        switch keyResult {
        case .key(let value): key = value
        case .denied, .missing: key = nil
        }
        let rows = database.query("""
            SELECT host_key, name, value, encrypted_value, path, expires_utc, \(secureColumn) FROM cookies
            WHERE host_key = 'youtube.com' OR host_key LIKE '%.youtube.com'
               OR host_key = 'youtu.be' OR host_key LIKE '%.youtu.be'
               OR host_key = 'youtube-nocookie.com' OR host_key LIKE '%.youtube-nocookie.com'
            """)
        var cookies: [NetscapeCookie] = []
        var sawEncrypted = false
        var decryptionFailed = false
        for row in rows {
            guard row.count >= 7, case .text(let host) = row[0], case .text(let name) = row[1] else { continue }
            let plaintext = row[2].string ?? ""
            let encrypted = row[3].data
            let value: String
            if plaintext.isEmpty, let encrypted, !encrypted.isEmpty {
                sawEncrypted = true
                guard let key, let decrypted = ChromiumCookies.decrypt(encrypted, key: key, metaVersion: metaVersion) else {
                    decryptionFailed = true
                    continue
                }
                value = decrypted
            } else {
                value = plaintext
            }
            let path = row[4].string ?? "/"
            let expiresUTC = row[5].integer ?? 0
            // Chromium counts microseconds from 1601-01-01 UTC. Zero is a session cookie.
            let expires = expiresUTC == 0 ? 0 : max(0, (expiresUTC - 11_644_473_600_000_000) / 1_000_000)
            cookies.append(NetscapeCookie(domain: host, includeSubdomains: host.hasPrefix("."),
                                          path: path, secure: (row[6].integer ?? 0) != 0,
                                          expires: expires, name: name, value: value))
        }
        if cookies.isEmpty {
            if case .denied = keyResult, sawEncrypted { return .permissionDenied }
            if decryptionFailed { return .failed }
            return .noSession
        }
        return .cookies(cookies)
    }

    private static func newestCookiesFile(root: URL, depth: Int) -> URL? {
        guard depth <= 3 else { return nil }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
        var found: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if let nested = newestCookiesFile(root: entry, depth: depth + 1) { found.append(nested) }
            } else if entry.lastPathComponent == "Cookies" {
                found.append(entry)
            }
        }
        return found.max { modificationDate($0) < modificationDate($1) }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func chromiumKey(keyring: String) -> KeychainResult {
        switch keychainPassword(service: "\(keyring) Safe Storage", account: keyring) {
        case .key(let password):
            guard let key = ChromiumCookies.deriveKey(password: password) else { return .missing }
            return .key(key)
        case .denied: return .denied
        case .missing: return .missing
        }
    }

    private static func keychainPassword(service: String, account: String) -> KeychainResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return .key(Array(data)) }
        if status == errSecItemNotFound { return .missing }
        return .denied
    }
}

/// Chromium macOS cookie crypto. Only the AES-CBC v10 scheme is decrypted; any
/// other prefix is treated as the older plaintext format.
enum ChromiumCookies {
    static func deriveKey(password: [UInt8]) -> [UInt8]? {
        // os_crypt_mac.mm: PBKDF2-HMAC-SHA1, salt "saltysalt", 1003 rounds, 16 bytes.
        pbkdf2SHA1(password: password, salt: Array("saltysalt".utf8), iterations: 1003, length: 16)
    }

    static func decrypt(_ encrypted: Data, key: [UInt8], metaVersion: Int64) -> String? {
        guard encrypted.count > 3 else { return nil }
        guard encrypted.prefix(3) == Data("v10".utf8) else {
            return String(data: encrypted, encoding: .utf8)
        }
        let ciphertext = Data(encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: 16)
        var output = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBufferPointer { keyBuffer in
            output.withUnsafeMutableBufferPointer { out in
                ciphertext.withUnsafeBytes { input in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), keyBuffer.baseAddress, key.count, iv,
                            input.baseAddress, ciphertext.count, out.baseAddress, out.count, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        var plaintext = Data(output.prefix(moved))
        // Chromium 130+ (meta version 24) prefixes a SHA-256 hash of the domain.
        if metaVersion >= 24, plaintext.count > 32 { plaintext = plaintext.dropFirst(32) }
        return String(data: plaintext, encoding: .utf8)
    }

    static func pbkdf2SHA1(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) -> [UInt8]? {
        var derived = [UInt8](repeating: 0, count: length)
        let status = derived.withUnsafeMutableBufferPointer { out -> Int32 in
            password.withUnsafeBufferPointer { passwordBuffer -> Int32 in
                salt.withUnsafeBufferPointer { saltBuffer -> Int32 in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         UnsafeRawPointer(passwordBuffer.baseAddress)?
                                            .assumingMemoryBound(to: CChar.self), passwordBuffer.count,
                                         saltBuffer.baseAddress, saltBuffer.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), UInt32(iterations),
                                         out.baseAddress, length)
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }
}

/// Safari's `Cookies.binarycookies` container. Parsing is defensive: any
/// truncated or oversized structure yields no cookies instead of reading past
/// the buffer.
enum SafariCookies {
    static func parse(_ data: Data) -> [NetscapeCookie]? {
        var reader = ByteReader(data)
        guard reader.read(4) == Data("cook".utf8), let pageCount = reader.uint32BE(), pageCount <= 10_000 else {
            return nil
        }
        // The header lists every page size before the page bodies.
        var sizes: [Int] = []
        sizes.reserveCapacity(Int(pageCount))
        for _ in 0..<pageCount {
            guard let size = reader.uint32BE() else { return nil }
            sizes.append(Int(size))
        }
        var cookies: [NetscapeCookie] = []
        for size in sizes {
            guard size <= data.count, let page = reader.read(size) else { return nil }
            cookies.append(contentsOf: parsePage(page))
        }
        return cookies
    }

    private static func parsePage(_ page: Data) -> [NetscapeCookie] {
        var reader = ByteReader(page)
        guard reader.read(4) == Data([0x00, 0x00, 0x01, 0x00]), let count = reader.uint32LE(), count <= 100_000 else {
            return []
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let offset = reader.uint32LE() else { return [] }
            offsets.append(Int(offset))
        }
        var cookies: [NetscapeCookie] = []
        for offset in offsets where offset >= 0 && offset < page.count {
            if let record = parseRecord(Data(page[offset...])) { cookies.append(record) }
        }
        return cookies
    }

    private static func parseRecord(_ record: Data) -> NetscapeCookie? {
        var reader = ByteReader(record)
        guard let recordSize = reader.uint32LE(), recordSize >= 56, Int(recordSize) <= record.count else { return nil }
        guard reader.skip(4), let flags = reader.uint32LE(), reader.skip(4),
              let domainOffset = reader.uint32LE(), let nameOffset = reader.uint32LE(),
              let pathOffset = reader.uint32LE(), let valueOffset = reader.uint32LE(),
              reader.skip(8), let expiration = reader.doubleLE() else { return nil }
        guard let domain = string(record, at: Int(domainOffset)),
              let name = string(record, at: Int(nameOffset)),
              let path = string(record, at: Int(pathOffset)),
              let value = string(record, at: Int(valueOffset)) else { return nil }
        // Safari dates are seconds since 2001-01-01 UTC; zero means a session cookie.
        let expires = expiration > 0 ? Int64(expiration + 978_307_200) : 0
        return NetscapeCookie(domain: domain, includeSubdomains: domain.hasPrefix("."), path: path,
                              secure: flags & 0x0001 != 0, expires: expires, name: name, value: value)
    }

    private static func string(_ data: Data, at offset: Int) -> String? {
        var reader = ByteReader(data)
        guard reader.skip(offset) else { return nil }
        return reader.cString()
    }
}

/// A minimal read-only SQLite wrapper. Only parameter-free queries are used, so
/// statement binding is intentionally absent.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init?(path: String) {
        var database: OpaquePointer?
        if sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            handle = database
            return
        }
        sqlite3_close(database)
        // A live browser may hold a WAL lock; an immutable read still sees the
        // committed store without copying it.
        var immutable: OpaquePointer?
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if sqlite3_open_v2("file:\(escaped)?mode=ro&immutable=1", &immutable,
                           SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            handle = immutable
            return
        }
        sqlite3_close(immutable)
        return nil
    }

    deinit { sqlite3_close(handle) }

    func query(_ sql: String) -> [SQLiteRow] {
        guard let handle else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [SQLiteRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let count = Int(sqlite3_column_count(statement))
            var values: [SQLiteValue] = []
            values.reserveCapacity(count)
            for index in 0..<count {
                switch sqlite3_column_type(statement, Int32(index)) {
                case SQLITE_INTEGER:
                    values.append(.integer(sqlite3_column_int64(statement, Int32(index))))
                case SQLITE_FLOAT:
                    values.append(.integer(Int64(sqlite3_column_double(statement, Int32(index)))))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, Int32(index)) {
                        values.append(.text(String(decodingCString: text, as: UTF8.self)))
                    } else {
                        values.append(.null)
                    }
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, Int32(index)))
                    if let bytes = sqlite3_column_blob(statement, Int32(index)), length > 0 {
                        values.append(.data(Data(bytes: bytes, count: length)))
                    } else {
                        values.append(.null)
                    }
                default:
                    values.append(.null)
                }
            }
            rows.append(SQLiteRow(values: values))
        }
        return rows
    }

    func scalarInt(_ sql: String) -> Int64? {
        query(sql).first?.integer
    }
}

enum SQLiteValue {
    case text(String)
    case integer(Int64)
    case data(Data)
    case null

    var string: String? { if case .text(let value) = self { return value }; return nil }
    var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
    var data: Data? { if case .data(let value) = self { return value }; return nil }
}

struct SQLiteRow {
    let values: [SQLiteValue]

    subscript(index: Int) -> SQLiteValue {
        if index >= 0 && index < values.count { return values[index] }
        return .null
    }

    var count: Int { values.count }

    var integer: Int64? { first?.integer }
    var string: String? { first?.string }
    var data: Data? { first?.data }
    private var first: SQLiteValue? { values.first }
}

/// Bounds-checked big/little-endian reader for the Safari container.
private struct ByteReader {
    private let data: Data
    private var index = 0

    init(_ data: Data) { self.data = data }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, index + count <= data.count else { return false }
        index += count
        return true
    }

    mutating func read(_ count: Int) -> Data? {
        guard count >= 0, index + count <= data.count else { return nil }
        let slice = Data(data[index..<(index + count)])
        index += count
        return slice
    }

    mutating func uint32LE() -> UInt32? { readUInt32(littleEndian: true) }
    mutating func uint32BE() -> UInt32? { readUInt32(littleEndian: false) }

    private mutating func readUInt32(littleEndian: Bool) -> UInt32? {
        guard let bytes = read(4) else { return nil }
        var value: UInt32 = 0
        for (offset, byte) in bytes.enumerated() {
            value |= UInt32(byte) << UInt32(littleEndian ? offset * 8 : (3 - offset) * 8)
        }
        return value
    }

    mutating func doubleLE() -> Double? {
        guard let bytes = read(8) else { return nil }
        var value: UInt64 = 0
        for (offset, byte) in bytes.enumerated() { value |= UInt64(byte) << UInt64(offset * 8) }
        return Double(bitPattern: value)
    }

    mutating func cString() -> String? {
        var bytes: [UInt8] = []
        while true {
            guard let byte = read(1)?.first else { return nil }
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
