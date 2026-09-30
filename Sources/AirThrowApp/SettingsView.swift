import AppKit
import Combine
import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// Cookie-source check state for the Settings window. Held by the app delegate
/// so the view can observe it without a `@State` macro (unavailable to the
/// Command Line Tools SwiftUI build).
@MainActor
final class CookieStatusModel: ObservableObject {
    enum Check: Equatable {
        case idle
        case checking
        case result(YouTubeCookieStatus)
    }

    @Published private(set) var checks: [WebsiteService: Check] = [:]
    @Published private(set) var installedBrowsers: [String] = []
    var check: Check { checks[.youtube] ?? .idle }
    private var task: Task<Void, Never>?
    private var requested: [WebsiteService: YouTubeCookies] = [:]
    private var revisions: [WebsiteService: Int] = [:]
    private var pending = Set<WebsiteService>()
    private let probe: @Sendable (WebsiteService, YouTubeCookies, URL) -> YouTubeCookieStatus

    init() { probe = { service, source, home in source.probe(for: service, home: home) } }
    init(probe: @escaping @Sendable (YouTubeCookies, URL) -> YouTubeCookieStatus) {
        self.probe = { _, source, home in probe(source, home) }
    }
    init(scopedProbe: @escaping @Sendable (WebsiteService, YouTubeCookies, URL) -> YouTubeCookieStatus) {
        probe = scopedProbe
    }

    func discoverBrowsers() {
        installedBrowsers = YouTubeCookiePreference.installedBrowsers()
    }

    func refresh(for source: YouTubeCookies, service: WebsiteService = .youtube) {
        requested[service] = source
        revisions[service, default: 0] += 1
        checks[service] = source == .none ? .idle : .checking
        if source == .none { pending.remove(service) }
        else { pending.insert(service) }
        // Serialize browser/Keychain reads and coalesce each service to its
        // latest choice. Disabling one cannot revive a stale check result.
        guard task == nil, !pending.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probe = self.probe
        task = Task { [weak self] in
            while let self, let service = WebsiteService.allCases.first(where: { self.pending.contains($0) }) {
                self.pending.remove(service)
                let source = self.requested[service] ?? .none
                let revision = self.revisions[service]
                let result = await Task.detached { probe(service, source, home) }.value
                if self.revisions[service] == revision { self.checks[service] = .result(result) }
            }
            self?.task = nil
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var cookieStatus: CookieStatusModel
    @AppStorage("afterPlaybackBehavior") private var behavior = AfterPlaybackBehavior.keepConnected.rawValue

    var body: some View {
        Form {
            Section("Playback") {
                Picker("After a video finishes", selection: $behavior) {
                    Text("Keep AirPlay connected").tag(AfterPlaybackBehavior.keepConnected.rawValue)
                    Text("Unload finished video").tag(AfterPlaybackBehavior.unloadVideo.rawValue)
                }
                Text(behavior == AfterPlaybackBehavior.unloadVideo.rawValue
                     ? "Unload the video so Apple TV can return to its normal screen."
                     : "Keep the finished video loaded and the receiver available for replay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Media preparation") {
                Toggle("Avoid video conversion", isOn: Binding(
                    get: { !controller.allowVideoConversion },
                    set: { controller.setVideoConversionAllowed(!$0) }))
                Text("Copy compatible video, and convert audio when needed. This preference governs automatic source selection: when on, automatic choice avoids video encoding. Choosing an enhancement in Video options authorizes encoding for that item, whatever this setting is.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Prefer higher quality", isOn: Binding(
                    get: { controller.preferQuality },
                    set: { controller.setPreferQuality($0) }))
                Text("Automatic chooses higher quality even when it requires more processing. Applies to the next load or source change; an explicit enhancement is unaffected.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Website sessions") {
                Text("Select the services whose signed-in sessions AirThrow may use. Public links work without enabling a session.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(WebsiteService.allCases, id: \.self) { service in
                    WebsiteSessionRow(service: service, cookieStatus: cookieStatus)
                }
                Text("Only the loaded website’s cookies are passed to yt-dlp. Changes apply to the next load. Safari needs Full Disk Access; Chrome-family browsers may ask for Keychain access.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(width: 440, height: 560)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { cookieStatus.discoverBrowsers() }
    }
}

private struct WebsiteSessionRow: View {
    let service: WebsiteService
    @ObservedObject var cookieStatus: CookieStatusModel
    @AppStorage private var enabled: Bool
    @AppStorage private var cookieMode: String
    @AppStorage private var cookieBrowser: String
    @AppStorage private var cookieFilePath: String

    init(service: WebsiteService, cookieStatus: CookieStatusModel) {
        self.service = service
        self.cookieStatus = cookieStatus
        _enabled = AppStorage(wrappedValue: WebsiteCookiePreference.enabled(service),
                              WebsiteCookiePreference.key(service, "enabled"))
        _cookieMode = AppStorage(wrappedValue: "browser", WebsiteCookiePreference.key(service, "mode"))
        _cookieBrowser = AppStorage(wrappedValue: WebsiteCookiePreference.defaultBrowser,
                                    WebsiteCookiePreference.key(service, "browser"))
        _cookieFilePath = AppStorage(wrappedValue: "", WebsiteCookiePreference.key(service, "filePath"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(service.title, isOn: $enabled)
                .accessibilityLabel("Use \(service.title) session")
            if enabled {
                Picker("Session from", selection: $cookieMode) {
                    Text("Browser").tag("browser")
                    Text("Cookies file").tag("file")
                    // A legacy or malformed preference stays visibly inactive.
                    if cookieMode == "none" { Text("None").tag("none") }
                }
                .accessibilityLabel("\(service.title) cookie source")
                if cookieMode == "browser" {
                    Picker("Browser", selection: $cookieBrowser) {
                        if !installedBrowsers.contains(cookieBrowser) {
                            Text("\(browserName(cookieBrowser)) (not installed)").tag(cookieBrowser)
                        }
                        ForEach(installedBrowsers, id: \.self) { browser in
                            Text(browserName(browser)).tag(browser)
                        }
                    }
                    .accessibilityLabel("\(service.title) browser")
                }
                if cookieMode == "file" {
                    HStack {
                        Text(cookieFilePath.isEmpty ? "No file selected" : (cookieFilePath as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(cookieFilePath.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { chooseCookiesFile() }
                            .accessibilityLabel("Choose \(service.title) cookies file")
                    }
                }
                statusView
                if selectedSource != .none {
                    Button("Recheck") {
                        cookieStatus.discoverBrowsers()
                        cookieStatus.refresh(for: selectedSource, service: service)
                    }
                    .disabled(check == .checking)
                    .accessibilityLabel("Recheck \(service.title) session")
                }
            }
        }
        .onChange(of: enabled) { _, value in
            if value, cookieMode == "none" { cookieMode = "browser" }
        }
        .task(id: probeKey) { cookieStatus.refresh(for: selectedSource, service: service) }
    }

    private var check: CookieStatusModel.Check { cookieStatus.checks[service] ?? .idle }
    private var probeKey: String { "\(enabled)|\(cookieMode)|\(cookieBrowser)|\(cookieFilePath)" }
    private var installedBrowsers: [String] { cookieStatus.installedBrowsers }
    private var effectiveBrowser: String { cookieBrowser }
    private var selectedSource: YouTubeCookies {
        guard enabled else { return .none }
        switch cookieMode {
        case "browser": return .browser(effectiveBrowser)
        case "file": return cookieFilePath.isEmpty ? .none : .file(URL(fileURLWithPath: cookieFilePath))
        default: return .none
        }
    }

    @ViewBuilder private var statusView: some View {
        switch check {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking session…").font(.caption).foregroundStyle(.secondary)
            }
        case .result(let status):
            switch status {
            case .none: EmptyView()
            case .loaded:
                statusLabel("Session cookies found. Access is checked when loading a video.", color: .secondary, symbol: "checkmark.circle")
            case .permissionDenied:
                statusLabel(permissionMessage, color: .red, symbol: "xmark.circle.fill")
            case .noSession:
                statusLabel("No \(service.title) session found. Sign in in the selected browser or choose a fresh cookies file.",
                            color: .secondary, symbol: "person.crop.circle.badge.questionmark")
            case .notInstalled:
                statusLabel("\(browserName(effectiveBrowser)) is not installed.", color: .red, symbol: "xmark.circle.fill")
            case .unavailable:
                statusLabel(cookieMode == "file" ? "Cannot read that cookies file." : "Could not read cookies from \(browserName(effectiveBrowser)).",
                            color: .red, symbol: "xmark.circle.fill")
            }
        }
    }

    private func statusLabel(_ message: String, color: Color, symbol: String) -> some View {
        Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.caption).foregroundStyle(color)
    }
    private var permissionMessage: String {
        effectiveBrowser == "safari"
            ? "Allow AirThrow Full Disk Access in System Settings, then recheck."
            : "Allow access to the browser’s stored Keychain key, then recheck."
    }
    private func browserName(_ browser: String) -> String {
        switch browser {
        case "brave": "Brave"
        case "chrome": "Google Chrome"
        case "chromium": "Chromium"
        case "edge": "Microsoft Edge"
        case "firefox": "Firefox"
        case "opera": "Opera"
        case "safari": "Safari"
        case "vivaldi": "Vivaldi"
        case "whale": "Whale"
        default: browser.capitalized
        }
    }
    private func chooseCookiesFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Netscape cookies.txt file. Only \(service.title) cookies are used."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { cookieFilePath = url.path }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
