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
        print("PASS serialized cookie checks, coalesced changes, and stale-result rejection (no browser data read)")
    }
}
