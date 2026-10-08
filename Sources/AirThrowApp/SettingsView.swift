import AppKit
import Combine
import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// Cookie-source check state for the Settings page. Held by the app delegate
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
    enum FileCheck: Equatable {
        case idle
        case checking
        case result(CookieFileInspection)
    }
    @Published private(set) var fileCheck: FileCheck = .idle
    private var fileTask: Task<Void, Never>?
    private var fileRevision = 0
    private let inspectFile: @Sendable (URL) -> CookieFileInspection
    @Published private(set) var installedBrowsers: [String] = []
    var check: Check { checks[.youtube] ?? .idle }
    private var task: Task<Void, Never>?
    private var requested: [WebsiteService: YouTubeCookies] = [:]
    private var revisions: [WebsiteService: Int] = [:]
    private var pending = Set<WebsiteService>()
    private let probe: @Sendable (WebsiteService, YouTubeCookies, URL) -> YouTubeCookieStatus

    init() {
        probe = { service, source, home in source.probe(for: service, home: home) }
        inspectFile = CookieFileInspection.inspect
    }
    init(probe: @escaping @Sendable (YouTubeCookies, URL) -> YouTubeCookieStatus) {
        self.probe = { _, source, home in probe(source, home) }
        inspectFile = CookieFileInspection.inspect
    }
    init(scopedProbe: @escaping @Sendable (WebsiteService, YouTubeCookies, URL) -> YouTubeCookieStatus,
         inspectFile: @escaping @Sendable (URL) -> CookieFileInspection = CookieFileInspection.inspect) {
        probe = scopedProbe
        self.inspectFile = inspectFile
    }

    func refreshSelection(source: YouTubeCookies, services: Set<WebsiteService>) {
        fileRevision += 1
        fileTask?.cancel()
        fileTask = nil
        fileCheck = .idle
        for service in WebsiteService.allCases {
            refresh(for: services.contains(service) && isBrowser(source) ? source : .none, service: service)
        }
        guard case .file(let url) = source else { return }
        fileCheck = .checking
        let revision = fileRevision
        let inspect = inspectFile
        fileTask = Task { [weak self] in
            let result = await Task.detached { inspect(url) }.value
            guard let self, self.fileRevision == revision else { return }
            self.fileCheck = .result(result)
            self.fileTask = nil
        }
    }

    private func isBrowser(_ source: YouTubeCookies) -> Bool {
        if case .browser = source { return true }
        return false
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
    @AppStorage(PreparationPreferences.maximumGiBKey) private var preparationGiB = 2
    @AppStorage(PreparationPreferences.retainAllKey) private var retainAll = false
    @AppStorage(PreparationPreferences.remuxCacheKey) private var remuxCache = false
    @AppStorage(PreparationPreferences.windowSecondsKey) private var windowSeconds = 60

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("Show a waiting screen on the TV", isOn: Binding(
                    get: { controller.showReceiverWaitingScreen },
                    set: { controller.setShowReceiverWaitingScreen($0) }))
                    .background(SettingsScrollStyle().allowsHitTesting(false))
                Text("When choosing a receiver with no video loaded, show AirThrow on a black background. Stays on until you load a video, press Stop, or leave on the TV.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                Toggle("Avoid video re-encoding", isOn: Binding(
                    get: { !controller.allowVideoConversion },
                    set: { controller.setVideoConversionAllowed(!$0) }))
                Text("Automatic selection copies compatible video and re-encodes audio when needed. Enhancements in Video options can still re-encode video.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Prefer higher quality", isOn: Binding(
                    get: { controller.preferQuality },
                    set: { controller.setPreferQuality($0) }))
                Text("Automatic selection favors quality within your re-encoding preference, even if more processing is needed. Applies to the next load or source change; enhancements are unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Prepared video storage") {
                Picker("Maximum preparation space", selection: $preparationGiB) {
                    ForEach([1, 2, 4, 8, 16, 32, 64], id: \.self) { value in
                        Text("\(value) GB").tag(value)
                    }
                }
                if !retainAll {
                    Picker("Playback cache window", selection: $windowSeconds) {
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                        Text("10 minutes").tag(600)
                    }
                    Text("Faster preparation can buffer beyond this window, up to the preparation space limit. Changes apply to the next load.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Keep all prepared video", isOn: $retainAll)
                Toggle("Remux on demand (experimental)", isOn: $remuxCache)
                    .disabled(retainAll)
                    .help("Requires a seekable source with compatible video and audio. Other sources prepare sequentially. Changes apply to the next load.")
                Text("Produces only the parts needed for playback, without re-encoding. Works with local files and compatible remote sources.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Cookies") {
                CookieSourceView(cookieStatus: cookieStatus)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .settingsScrollEdgeEffect()
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { cookieStatus.discoverBrowsers() }
    }
}

private extension View {
    @ViewBuilder
    func settingsScrollEdgeEffect() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// Apply AppKit's fading overlay indicators to this Form's own scroll view.
/// Mount inside a row so the lookup stays within the Settings scroll hierarchy.
private struct SettingsScrollStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollStyleView { ScrollStyleView() }
    func updateNSView(_ view: ScrollStyleView, context: Context) {
        view.applyStyle()
    }

    final class ScrollStyleView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyStyle()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyStyle()
        }

        func applyStyle() {
            // SwiftUI can attach the row before its scroll ancestor is ready.
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView else { return }
                scrollView.scrollerStyle = .overlay
            }
        }
    }
}

private struct CookieSourceView: View {
    @ObservedObject var cookieStatus: CookieStatusModel
    @AppStorage(WebsiteCookiePreference.modeKey) private var cookieMode = "none"
    @AppStorage(WebsiteCookiePreference.browserKey) private var cookieBrowser = WebsiteCookiePreference.defaultBrowser
    @AppStorage(WebsiteCookiePreference.filePathKey) private var cookieFilePath = ""
    @AppStorage(WebsiteCookiePreference.servicesKey) private var cookieServices = WebsiteCookiePreference.allServices

    init(cookieStatus: CookieStatusModel) {
        WebsiteCookiePreference.prepare()
        self.cookieStatus = cookieStatus
    }

    var body: some View {
        Picker("Cookies from", selection: $cookieMode) {
            Text("None").tag("none")
            Text("Browser").tag("browser")
            Text("Cookies file").tag("file")
        }
        .pickerStyle(.menu)
        .task(id: probeKey) { refresh() }
        if cookieMode == "browser" {
            Picker("Browser", selection: $cookieBrowser) {
                if !cookieStatus.installedBrowsers.contains(cookieBrowser) {
                    Text("\(browserName(cookieBrowser)) (not installed)").tag(cookieBrowser)
                }
                ForEach(cookieStatus.installedBrowsers, id: \.self) { browser in
                    Text(browserName(browser)).tag(browser)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Text("Services")
                Spacer()
                Menu {
                    ForEach(WebsiteService.allCases, id: \.self) { service in
                        Toggle(service.title, isOn: Binding(
                            get: { selectedServices.contains(service) },
                            set: { included in
                                var services = selectedServices
                                if included { services.insert(service) } else { services.remove(service) }
                                cookieServices = WebsiteService.allCases.filter { services.contains($0) }
                                    .map(\.rawValue).joined(separator: ",")
                            }))
                    }
                } label: { Text(serviceSelectionLabel) }
                .accessibilityLabel("Services to extract cookies for")
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if selectedServices.isEmpty {
                Text("Select a service to use its browser cookies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(WebsiteService.allCases.filter { selectedServices.contains($0) }, id: \.self) { service in
                browserStatus(service)
            }
        }
        if cookieMode == "file" {
            HStack {
                Text(cookieFilePath.isEmpty ? "No file selected" : (cookieFilePath as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(cookieFilePath.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Choose…") { chooseCookiesFile() }
                    .accessibilityLabel("Choose cookies file")
            }
            fileStatus
        }
        if selectedSource != .none, cookieMode == "file" || !selectedServices.isEmpty {
            Button("Recheck") { refresh() }
                .disabled(isChecking)
        }
        Text(cookieMode == "file"
             ? "Recognized services are detected automatically. Only the loaded website’s cookies are used."
             : "Public links work without cookies. Browser extraction reads only the selected services.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if cookieMode == "browser" {
            Text("Safari needs Full Disk Access; Chrome-family browsers may ask for Keychain access.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if cookieMode != "none" {
            Text("Changes apply to the next load. Detected cookies do not guarantee sign-in or receiver playback.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var selectedServices: Set<WebsiteService> { WebsiteCookiePreference.selectedServices(cookieServices) }
    private var serviceSelectionLabel: String {
        if selectedServices.isEmpty { return "No services" }
        if selectedServices.count == WebsiteService.allCases.count { return "All services" }
        if selectedServices.count == 1 { return WebsiteService.allCases.first { selectedServices.contains($0) }!.title }
        return "\(selectedServices.count) services"
    }
    private var probeKey: String { "\(cookieMode)|\(cookieBrowser)|\(cookieFilePath)|\(cookieServices)" }
    private var selectedSource: YouTubeCookies {
        switch cookieMode {
        case "browser": return YouTubeCookies.supportedBrowsers.contains(cookieBrowser) ? .browser(cookieBrowser) : .none
        case "file": return cookieFilePath.hasPrefix("/") ? .file(URL(fileURLWithPath: cookieFilePath)) : .none
        default: return .none
        }
    }
    private var isChecking: Bool {
        cookieStatus.fileCheck == .checking || cookieStatus.checks.values.contains(.checking)
    }
    private func refresh() {
        cookieStatus.discoverBrowsers()
        cookieStatus.refreshSelection(source: selectedSource, services: selectedServices)
    }

    @ViewBuilder private var fileStatus: some View {
        switch cookieStatus.fileCheck {
        case .idle: EmptyView()
        case .checking: checkingLabel("Reading cookies file…")
        case .result(.unavailable):
            statusLabel("Cannot read that cookies file.", color: .red, symbol: "xmark.circle.fill")
        case .result(.loaded(let summaries)):
            if summaries.isEmpty {
                statusLabel("No supported service cookies found. Choose a Netscape cookies.txt file.",
                            symbol: "info.circle")
            }
            ForEach(summaries, id: \.service) { summary in
                HStack {
                    Text(summary.service.title)
                    Spacer()
                    Text("\(cookieCountLabel(summary.cookieCount)) · \(summary.hasSession ? "Session found" : "No session marker")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func browserStatus(_ service: WebsiteService) -> some View {
        switch cookieStatus.checks[service] ?? .idle {
        case .idle: EmptyView()
        case .checking: checkingLabel("\(service.title): checking…")
        case .result(let status):
            switch status {
            case .none: EmptyView()
            case .loaded(let count):
                statusLabel("\(service.title): \(cookieCountLabel(count)) · Session found", symbol: "checkmark.circle")
            case .noSession:
                statusLabel("\(service.title): no session found", symbol: "person.crop.circle.badge.questionmark")
            case .permissionDenied:
                statusLabel("\(service.title): allow \(cookieBrowser == "safari" ? "Full Disk Access" : "Keychain access"), then recheck.",
                            color: .red, symbol: "xmark.circle.fill")
            case .notInstalled:
                statusLabel("\(browserName(cookieBrowser)) is not installed.", color: .red, symbol: "xmark.circle.fill")
            case .unavailable:
                statusLabel("\(service.title): could not read browser cookies.", color: .red, symbol: "xmark.circle.fill")
            }
        }
    }
    private func cookieCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "cookie" : "cookies")"
    }
    private func checkingLabel(_ message: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func statusLabel(_ message: String, color: Color = .secondary, symbol: String) -> some View {
        Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.caption).foregroundStyle(color)
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
        panel.message = "Choose a Netscape cookies.txt file. Supported services are detected automatically."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { cookieFilePath = url.path }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
