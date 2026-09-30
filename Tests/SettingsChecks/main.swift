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

private final class FileHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func release() { gate.signal() }
    func inspect(_ url: URL) -> CookieFileInspection {
        let index = lock.withLock { reads += 1; return reads }
        if index == 1 { _ = gate.wait(timeout: .now() + 5) }
        return index == 1 ? .loaded([CookieServiceSummary(service: .twitch, cookieCount: 1, hasSession: true)]) : .loaded([])
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
            try check(WebsiteCookiePreference.source(service, defaults: defaults) == .none, "Default supplied cookies")
        }
        defaults.set("browser", forKey: YouTubeCookiePreference.modeKey)
        defaults.set("firefox", forKey: YouTubeCookiePreference.browserKey)
        try check(WebsiteCookiePreference.source(.youtube, defaults: defaults) == .browser("firefox")
                  && WebsiteCookiePreference.source(.twitch, defaults: defaults) == .none,
                  "Existing YouTube source/filter did not migrate")
        defaults.set("twitch,twitter,invalid", forKey: WebsiteCookiePreference.servicesKey)
        let browserSessions = WebsiteCookiePreference.current(environment: [:], defaults: defaults)
        try check(browserSessions.source(for: .twitch) == .browser("firefox")
                  && browserSessions.source(for: .twitter) == .browser("firefox")
                  && browserSessions.source(for: .youtube) == .none, "Browser service filter was ignored")
        try check(WebsiteCookiePreference.current(environment: ["AIRTHROW_YTDLP_COOKIES": "/tmp/unused"], defaults: defaults)
                  .source(for: .youtube) == .none, "Unselected YouTube accepted an override")
        defaults.set("", forKey: WebsiteCookiePreference.servicesKey)
        try check(WebsiteCookiePreference.source(.twitch, defaults: defaults) == .none, "Empty browser selection read cookies")
        defaults.set("file", forKey: WebsiteCookiePreference.modeKey)
        defaults.set("/tmp/mixed.txt", forKey: WebsiteCookiePreference.filePathKey)
        let fileSessions = WebsiteCookiePreference.current(environment: [:], defaults: defaults)
        for service in WebsiteService.allCases {
            try check(fileSessions.source(for: service) == .file(URL(fileURLWithPath: "/tmp/mixed.txt")),
                      "File mode incorrectly required selecting a service")
        }
        defaults.set("relative.txt", forKey: WebsiteCookiePreference.filePathKey)
        try check(WebsiteCookiePreference.source(.youtube, defaults: defaults) == .none, "Relative file accepted")
        defaults.set("none", forKey: WebsiteCookiePreference.modeKey)
        try check(WebsiteCookiePreference.current(environment: ["AIRTHROW_YTDLP_COOKIES": "/tmp/unused"], defaults: defaults)
                  .source(for: .youtube) == .none, "None accepted a cookie override")
        defaults.set("browser", forKey: WebsiteCookiePreference.modeKey)
        defaults.set("invalid-browser", forKey: WebsiteCookiePreference.browserKey)
        defaults.set("instagram", forKey: WebsiteCookiePreference.servicesKey)
        try check(WebsiteCookiePreference.source(.instagram, defaults: defaults) == .none, "Invalid browser accepted")
        // Migration from the interim per-service view preserves enabled sites.
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: WebsiteCookiePreference.key(.youtube, "enabled"))
        defaults.set(true, forKey: WebsiteCookiePreference.key(.twitch, "enabled"))
        defaults.set("browser", forKey: WebsiteCookiePreference.key(.twitch, "mode"))
        defaults.set("chrome", forKey: WebsiteCookiePreference.key(.twitch, "browser"))
        try check(WebsiteCookiePreference.source(.twitch, defaults: defaults) == .browser("chrome")
                  && WebsiteCookiePreference.source(.youtube, defaults: defaults) == .none,
                  "Per-service consent was lost during migration")
        defaults.removePersistentDomain(forName: suite)
        let envOnly = WebsiteCookiePreference.current(environment: ["AIRTHROW_YTDLP_COOKIES": "/tmp/override"], defaults: defaults)
        try check(envOnly.source(for: .youtube) == .file(URL(fileURLWithPath: "/tmp/override"))
                  && envOnly.source(for: .twitch) == .none, "Legacy environment scope changed")
        try check(WebsiteCookiePreference.selectedServices(defaults.string(forKey: WebsiteCookiePreference.servicesKey)!)
                  == Set(WebsiteService.allCases), "First browser selection did not offer all services")

        let selectionHarness = ProbeHarness()
        let selection = CookieStatusModel(probe: selectionHarness.probe)
        selection.refreshSelection(source: .browser("safari"), services: [.twitch, .twitter])
        try await wait { selectionHarness.count == 1 }
        selection.refreshSelection(source: .browser("safari"), services: [])
        selectionHarness.release()
        try await Task.sleep(for: .milliseconds(100))
        try check(selectionHarness.count == 1 && selection.checks.values.allSatisfy { $0 == .idle },
                  "Unselecting all services retained a queued browser read or stale result")

        let fileHarness = FileHarness()
        let fileModel = CookieStatusModel(scopedProbe: { _, _, _ in .unavailable }, inspectFile: fileHarness.inspect)
        fileModel.refreshSelection(source: .file(URL(fileURLWithPath: "/tmp/first")), services: [])
        try await wait { fileHarness.count == 1 }
        fileModel.refreshSelection(source: .none, services: [])
        fileHarness.release()
        try await Task.sleep(for: .milliseconds(100))
        try check(fileModel.fileCheck == .idle && fileHarness.count == 1, "Stale file summary returned after None")
        fileModel.refreshSelection(source: .file(URL(fileURLWithPath: "/tmp/second")), services: [])
        try await wait { fileModel.fileCheck == .result(.loaded([])) }
        try check(fileHarness.count == 2 && fileModel.checks.values.allSatisfy { $0 == .idle },
                  "File summary required service selection or read a browser")
        let replacementHarness = FileHarness()
        let replacement = CookieStatusModel(scopedProbe: { _, _, _ in .unavailable }, inspectFile: replacementHarness.inspect)
        replacement.refreshSelection(source: .file(URL(fileURLWithPath: "/tmp/old")), services: [])
        try await wait { replacementHarness.count == 1 }
        replacement.refreshSelection(source: .file(URL(fileURLWithPath: "/tmp/new")), services: [])
        try await wait { replacement.fileCheck == .result(.loaded([])) }
        replacementHarness.release()
        try await Task.sleep(for: .milliseconds(100))
        try check(replacement.fileCheck == .result(.loaded([])), "An old file summary replaced the newer selection")
        print("PASS global cookie source, browser service filter, file autodetection, preference migration and stale file summaries")
        print("PASS serialized cookie checks, coalesced changes, and stale-result rejection (no browser data read)")
    }
}
