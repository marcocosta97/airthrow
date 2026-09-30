import Foundation
import SQLite3

@main
struct WebsiteSessionChecks {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "WebsiteSessionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("athrow-website-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mixed.txt")
        let markers: [WebsiteService: String] = [.youtube: "LOGIN_INFO", .twitch: "auth-token", .twitter: "auth_token", .instagram: "sessionid", .vimeo: "vimeo"]
        let urls: [WebsiteService: String] = [.youtube: "https://www.youtube.com/watch?v=BaW_jenozKc", .twitch: "https://www.twitch.tv/example", .twitter: "https://x.com/example/status/123", .instagram: "https://www.instagram.com/reel/example/", .vimeo: "https://vimeo.com/123"]
        var records = WebsiteService.allCases.map { service in
            ".\(service.domains[0])\tTRUE\t/\tTRUE\t0\t\(markers[service]!)\tfixture-\(service.rawValue)"
        }
        records += [".foreign.example\tTRUE\t/\tTRUE\t0\tauth-token\tforeign",
                    ".twitch.tv.evil.example\tTRUE\t/\tTRUE\t0\tauth-token\tspoof"]
        try records.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        for service in WebsiteService.allCases {
            let domain = service.domains[0]
            try check(service.includes(domain: ".\(domain)") && service.includes(domain: "sub.\(domain)"), "Owned domain rejected")
            try check(!service.includes(domain: "evil\(domain)") && !service.includes(domain: "\(domain).evil.example"), "Spoof domain accepted")
            try check(WebsiteService.service(for: URL(string: urls[service]!)!) == service, "Service URL routing failed")
            try check(YouTubeCookies.file(file).probe(for: service) == .loaded(1), "Service marker probe failed")
            let scratch = YouTubeCookies.file(file).materialize(for: service)
            try check(scratch.path != nil && scratch.directory != nil, "No private cookie scratch")
            let parsed = NetscapeCookies.parse(try String(contentsOfFile: scratch.path!, encoding: .utf8))
            try check(parsed.count == 1 && parsed[0].value == "fixture-\(service.rawValue)", "Cookie scopes crossed")
            let permissions = try FileManager.default.attributesOfItem(atPath: scratch.path!)[.posixPermissions] as? NSNumber
            let directoryPermissions = try FileManager.default.attributesOfItem(atPath: scratch.directory!.path)[.posixPermissions] as? NSNumber
            try check(permissions?.intValue == 0o600 && directoryPermissions?.intValue == 0o700, "Cookie scratch permissions changed")
            scratch.cleanup()
            try check(!FileManager.default.fileExists(atPath: scratch.directory!.path), "Cookie scratch survived cleanup")
        }
        try check(WebsiteService.service(for: URL(string: "https://twitch.tv.evil.example/watch")!) == nil
                  && WebsiteService.service(for: URL(string: "file:///twitch.tv")!) == nil, "Foreign URL mapped to a session")
        try check(WebsiteSessions().source(for: .twitch) == .none && WebsiteSessions().source(for: URL(string: "https://example.com")!) == .none,
                  "Absent service supplied cookies")
        let expired = root.appendingPathComponent("expired.txt")
        try ".twitch.tv\tTRUE\t/\tTRUE\t1\tauth-token\tx\n".write(to: expired, atomically: true, encoding: .utf8)
        try check(YouTubeCookies.file(expired).probe(for: .twitch) == .noSession, "Expired marker accepted")
        try ".twitch.tv\tTRUE\t/\tTRUE\t0\tauth-token\t\n".write(to: expired, atomically: true, encoding: .utf8)
        try check(YouTubeCookies.file(expired).probe(for: .twitch) == .noSession, "Empty marker accepted")
        try check(YouTubeCookies.none.materialize(for: .twitch).path == nil, "Disabled session materialized")
        print("PASS all service scopes, URL ownership, session markers, expiry, scratch permissions and cleanup")

        // File inspection summarizes recognized service cookies without leaking names, values or domains.
        guard case .loaded(let summaries) = CookieFileInspection.inspect(file) else {
            try check(false, "Mixed cookie file was unavailable")
            return
        }
        try check(summaries.map(\.service) == WebsiteService.allCases, "Inspection skipped or reordered a recognized service")
        try check(summaries.allSatisfy { $0.cookieCount == 1 && $0.hasSession }, "Mixed inspection counts or sessions wrong")
        let anonymous = root.appendingPathComponent("anonymous.txt")
        try ".youtube.com\tTRUE\t/\tTRUE\t0\tPREF\tvalue\n".write(to: anonymous, atomically: true, encoding: .utf8)
        try check(CookieFileInspection.inspect(anonymous) == .loaded([
            CookieServiceSummary(service: .youtube, cookieCount: 1, hasSession: false)
        ]), "Anonymous recognized cookie reported a session")
        let expiredMarker = root.appendingPathComponent("expired-marker.txt")
        try ".twitch.tv\tTRUE\t/\tTRUE\t1\tauth-token\tx\n".write(to: expiredMarker, atomically: true, encoding: .utf8)
        try check(CookieFileInspection.inspect(expiredMarker) == .loaded([
            CookieServiceSummary(service: .twitch, cookieCount: 1, hasSession: false)
        ]), "Expired inspection marker reported a session")
        let emptyCookies = root.appendingPathComponent("empty.txt")
        try "".write(to: emptyCookies, atomically: true, encoding: .utf8)
        let malformedCookies = root.appendingPathComponent("malformed.txt")
        try "not a cookie line\n# comment only\n".write(to: malformedCookies, atomically: true, encoding: .utf8)
        let foreignCookies = root.appendingPathComponent("foreign-only.txt")
        try ".foreign.example\tTRUE\t/\tTRUE\t0\tauth-token\tforeign\n".write(to: foreignCookies, atomically: true, encoding: .utf8)
        for emptyFile in [emptyCookies, malformedCookies, foreignCookies] {
            try check(CookieFileInspection.inspect(emptyFile) == .loaded([]), "Empty, malformed or foreign-only file produced summaries")
        }
        try check(CookieFileInspection.inspect(root.appendingPathComponent("missing.txt")) == .unavailable, "Missing file was not unavailable")
        try check(CookieFileInspection.inspect(URL(string: "https://example.com/cookies.txt")!) == .unavailable, "Non-file URL accepted by file inspection")
        print("PASS cookie file inspection counts, sessions and inaccessible/empty/foreign cases")

        // A synthetic Firefox profile verifies SQL-level service scoping.
        let home = root.appendingPathComponent("home")
        let profile = home.appendingPathComponent("Library/Application Support/Firefox/Profiles/fixture.default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        var db: OpaquePointer?
        try check(sqlite3_open(profile.appendingPathComponent("cookies.sqlite").path, &db) == SQLITE_OK, "Could not create browser fixture")
        let sql = "CREATE TABLE moz_cookies(host TEXT,name TEXT,value TEXT,path TEXT,expiry INTEGER,isSecure INTEGER);"
            + "INSERT INTO moz_cookies VALUES('.twitch.tv','auth-token','fixture','/',0,1),('.x.com','auth_token','fixture','/',0,1),('.twitch.tv.evil.example','auth-token','spoof','/',0,1);"
        try check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Browser fixture failed")
        sqlite3_close(db)
        try check(YouTubeCookies.browser("firefox").probe(for: .twitch, home: home) == .loaded(1), "Firefox Twitch filter failed")
        try check(YouTubeCookies.browser("firefox").probe(for: .twitter, home: home) == .loaded(1), "Firefox X filter failed")
        try check(YouTubeCookies.browser("firefox").probe(for: .youtube, home: home) == .noSession, "Firefox imported unrelated session")
        print("PASS scoped browser queries using a synthetic profile")

        let output = root.appendingPathComponent("output.json")
        let argsFile = root.appendingPathComponent("args.txt")
        let copy = root.appendingPathComponent("handoff.txt")
        let helper = root.appendingPathComponent("yt-dlp-fixture")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argsFile.path)'
        previous=''
        for arg in "$@"; do
            if [ "$previous" = '--cookies' ]; then cp "$arg" '\(copy.path)'; fi
            previous="$arg"
        done
        case "$arg" in */failure) exit 1;; */slow) sleep 5;; esac
        cat '\(output.path)'
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let environment = ["AIRTHROW_YTDLP": helper.path, "AIRTHROW_DENO": "/usr/bin/true"]
        let sessions = WebsiteSessions(sources: Dictionary(uniqueKeysWithValues: WebsiteService.allCases.map { ($0, YouTubeCookies.file(file)) }))
        let resolver = SourceResolver(environment: environment, sessions: sessions)
        var metadata: [String: Any] = ["_type": "video", "formats": [
            ["format_id": "combined", "url": "https://cdn.example/video.mp4", "protocol": "https",
             "ext": "mp4", "height": 1080, "vcodec": "avc1.640028", "acodec": "mp4a.40.2"]
        ]]
        func writeMetadata() throws { try JSONSerialization.data(withJSONObject: metadata).write(to: output) }
        func arguments() throws -> [String] { try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init) }
        func verifyCleanup() throws {
            let args = try arguments()
            if let index = args.firstIndex(of: "--cookies") {
                try check(!FileManager.default.fileExists(atPath: args[index + 1]), "Helper cookie file survived")
            }
            try check(!args.contains("--cookies-from-browser"), "Raw browser handoff enabled")
        }
        try writeMetadata()
        for service in WebsiteService.allCases {
            _ = try await resolver.resolve(URL(string: urls[service]!)!)
            let handed = NetscapeCookies.parse(try String(contentsOf: copy, encoding: .utf8))
            try check(handed.count == 1 && handed[0].value == "fixture-\(service.rawValue)", "Helper received another service's cookies")
            try verifyCleanup()
        }
        let registered = try SourceRegistry.standard(environment: environment, sessions: sessions)
        _ = try await SourceResolver(environment: environment, registry: registered).resolve(URL(string: urls[.youtube]!)!)
        try check(NetscapeCookies.parse(try String(contentsOf: copy, encoding: .utf8)).first?.value == "fixture-youtube",
                  "Registry factory ignored its YouTube session")
        try verifyCleanup()
        var legacyEnvironment = environment
        legacyEnvironment["AIRTHROW_YTDLP_COOKIES"] = file.path
        _ = try await SourceResolver(environment: legacyEnvironment).resolve(URL(string: urls[.youtube]!)!)
        try check((try arguments()).contains("--cookies"), "Legacy YouTube environment override was lost")
        try verifyCleanup()
        for url in ["https://unregistered.example/watch", "https://twitch.tv.evil.example/watch"] {
            _ = try await resolver.resolve(URL(string: url)!)
            try check(!(try arguments()).contains("--cookies"), "Foreign URL received cookies")
        }
        _ = try await SourceResolver(environment: environment, sessions: WebsiteSessions()).resolve(URL(string: urls[.twitch]!)!)
        try check(!(try arguments()).contains("--cookies"), "Disabled service supplied cookies")
        metadata["availability"] = "private"
        try writeMetadata()
        _ = try await resolver.resolve(URL(string: urls[.twitch]!)!)
        do {
            _ = try await SourceResolver(environment: environment).resolve(URL(string: urls[.twitch]!)!)
            try check(false, "Unauthenticated private metadata accepted")
        } catch is ResolutionFailure { }
        metadata["has_drm"] = true
        try writeMetadata()
        do {
            _ = try await resolver.resolve(URL(string: urls[.twitch]!)!)
            try check(false, "Cookies bypassed DRM exclusion")
        } catch is ResolutionFailure { }
        try verifyCleanup()
        metadata.removeValue(forKey: "has_drm")
        metadata["http_headers"] = ["Authorization": "fixture-only"]
        try writeMetadata()
        do {
            _ = try await resolver.resolve(URL(string: urls[.twitch]!)!)
            try check(false, "Cookies bypassed media-header exclusion")
        } catch is ResolutionFailure { }
        try verifyCleanup()
        metadata.removeValue(forKey: "http_headers")
        try writeMetadata()
        _ = try await resolver.resolve(URL(string: "https://twitch.tv/failure")!)
        try verifyCleanup()
        try? FileManager.default.removeItem(at: argsFile)
        let pending = Task { try await resolver.resolve(URL(string: "https://twitch.tv/slow")!) }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: argsFile.path), FileManager.default.fileExists(atPath: copy.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(FileManager.default.fileExists(atPath: argsFile.path), "Slow helper did not launch")
        pending.cancel()
        do { _ = try await pending.value; try check(false, "Cancellation ignored") }
        catch is CancellationError { }
        try verifyCleanup()
        print("PASS per-service helper handoff, disabled/foreign isolation, authenticated metadata, DRM/header limits and failure/cancellation cleanup")
        print("Website session checks passed; no real browser session or receiver tested.")
    }
}
