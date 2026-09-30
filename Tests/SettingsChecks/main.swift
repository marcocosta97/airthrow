import Foundation

private final class ProbeHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var requests: [YouTubeCookies] = []
    var count: Int { lock.withLock { requests.count } }
    var lastSource: YouTubeCookies? { lock.withLock { requests.last } }
    func release() { gate.signal() }
    func probe(_ source: YouTubeCookies, _ home: URL) -> YouTubeCookieStatus {
        let index = lock.withLock { requests.append(source); return requests.count }
        if index == 1 { _ = gate.wait(timeout: .now() + 5) }
        return .loaded(index)
    }
}

@main
@MainActor
struct SettingsChecks {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "SettingsChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(condition(), "Cookie check did not settle")
    }
    static func main() async throws {
        let harness = ProbeHarness()
        let model = CookieStatusModel(probe: harness.probe)
        model.refresh(for: .browser("safari"))
        try await wait { harness.count == 1 }
        model.refresh(for: .browser("chrome"))
        model.refresh(for: .browser("firefox"))
        try await Task.sleep(for: .milliseconds(80))
        try check(harness.count == 1, "Browser reads overlapped")
        harness.release()
        try await wait { model.check == .result(.loaded(2)) }
        try check(harness.count == 2, "Intermediate selections were not coalesced")
        try check(harness.lastSource == .browser("firefox"), "The latest browser choice was not checked")

        let clearing = ProbeHarness()
        let cleared = CookieStatusModel(probe: clearing.probe)
        cleared.refresh(for: .browser("safari"))
        try await wait { clearing.count == 1 }
        cleared.refresh(for: .none)
        clearing.release()
        try await Task.sleep(for: .milliseconds(100))
        try check(cleared.check == .idle && clearing.count == 1, "A stale cookie result replaced the cleared state")
        let scoped = ProbeHarness()
        let multi = CookieStatusModel(scopedProbe: { _, source, home in scoped.probe(source, home) })
        multi.refresh(for: .browser("safari"), service: .twitch)
        try await wait { scoped.count == 1 }
        multi.refresh(for: .browser("firefox"), service: .twitter)
        multi.refresh(for: .none, service: .twitch)
        scoped.release()
        try await wait { multi.checks[.twitter] == .result(.loaded(2)) }
        try check(multi.checks[.twitch] == .idle && scoped.count == 2,
                  "Disabling one service lost another check or revived a stale result")
        multi.refresh(for: .none, service: .instagram)
        try await Task.sleep(for: .milliseconds(60))
        try check(scoped.count == 2, "Disabled service triggered a read")

        let suite = "airthrow-settings-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for service in WebsiteService.allCases {
            try check(!WebsiteCookiePreference.enabled(service, defaults: defaults), "New service was enabled by default")
            try check(WebsiteCookiePreference.source(service, defaults: defaults) == .none, "Disabled service supplied cookies")
        }
        defaults.set("browser", forKey: YouTubeCookiePreference.modeKey)
        defaults.set("firefox", forKey: YouTubeCookiePreference.browserKey)
        try check(WebsiteCookiePreference.enabled(.youtube, defaults: defaults)
                  && WebsiteCookiePreference.source(.youtube, defaults: defaults) == .browser("firefox"),
                  "Existing YouTube preference did not migrate")
        defaults.set(false, forKey: WebsiteCookiePreference.key(.youtube, "enabled"))
        try check(WebsiteCookiePreference.current(environment: ["AIRTHROW_YTDLP_COOKIES": "/tmp/unused"], defaults: defaults)
                  .source(for: .youtube) == .none, "Disabling YouTube failed to prevent cookie use")
        defaults.set(true, forKey: WebsiteCookiePreference.key(.twitch, "enabled"))
        defaults.set("file", forKey: WebsiteCookiePreference.key(.twitch, "mode"))
        defaults.set("/tmp/twitch-only.txt", forKey: WebsiteCookiePreference.key(.twitch, "filePath"))
        let sessions = WebsiteCookiePreference.current(environment: [:], defaults: defaults)
        try check(sessions.source(for: .twitch) == .file(URL(fileURLWithPath: "/tmp/twitch-only.txt")),
                  "Enabled Twitch file preference was lost")
        try check(sessions.source(for: .youtube) == .none && sessions.source(for: .twitter) == .none,
                  "Selecting Twitch enabled another service")
        defaults.set(false, forKey: WebsiteCookiePreference.key(.twitch, "enabled"))
        try check(WebsiteCookiePreference.source(.twitch, defaults: defaults) == .none, "Saved file was used after disabling")
        defaults.set(true, forKey: WebsiteCookiePreference.key(.instagram, "enabled"))
        defaults.set("invalid-browser", forKey: WebsiteCookiePreference.key(.instagram, "browser"))
        try check(WebsiteCookiePreference.source(.instagram, defaults: defaults) == .none, "Invalid browser was accepted")
        print("PASS service opt-in, YouTube migration, scoped preferences and serialized cross-service checks")
        print("PASS serialized cookie checks, coalesced changes, and stale-result rejection (no browser data read)")
    }
}
