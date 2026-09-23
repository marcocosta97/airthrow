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

    @Published private(set) var check: Check = .idle
    @Published private(set) var installedBrowsers: [String] = []
    private var task: Task<Void, Never>?
    private var requestedSource: YouTubeCookies = .none
    private var revision = 0
    private let probe: @Sendable (YouTubeCookies, URL) -> YouTubeCookieStatus

    init(probe: @escaping @Sendable (YouTubeCookies, URL) -> YouTubeCookieStatus = { $0.probe(home: $1) }) {
        self.probe = probe
    }

    func discoverBrowsers() {
        installedBrowsers = YouTubeCookiePreference.installedBrowsers()
    }

    func refresh(for source: YouTubeCookies) {
        requestedSource = source
        revision += 1
        check = source == .none ? .idle : .checking
        // A synchronous Keychain/browser read cannot be cancelled midway.
        // Keep at most one in flight and coalesce changes to the latest choice.
        guard task == nil, source != .none else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probe = self.probe
        task = Task { [weak self] in
            while let self {
                let source = self.requestedSource
                let revision = self.revision
                guard source != .none else { self.task = nil; return }
                let result = await Task.detached { probe(source, home) }.value
                if self.revision == revision {
                    self.check = .result(result)
                    self.task = nil
                    return
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var cookieStatus: CookieStatusModel
    @AppStorage("afterPlaybackBehavior") private var behavior = AfterPlaybackBehavior.keepConnected.rawValue
    @AppStorage(YouTubeCookiePreference.modeKey) private var cookieMode = "none"
    @AppStorage(YouTubeCookiePreference.browserKey) private var cookieBrowser = YouTubeCookiePreference.defaultBrowser
    @AppStorage(YouTubeCookiePreference.filePathKey) private var cookieFilePath = ""

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
                Text("Copy compatible video; convert audio when needed. Turn off to allow SDR video conversion up to 1080p.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Prefer higher quality", isOn: Binding(
                    get: { controller.preferQuality },
                    set: { controller.setPreferQuality($0) }))
                Text("Automatic chooses higher quality even when it requires more processing. Both preferences apply to the next load or quality choice.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("YouTube access") {
                Picker("Cookies", selection: $cookieMode) {
                    Text("Don't use cookies").tag("none")
                    Text("From a browser").tag("browser")
                    Text("From a cookies file").tag("file")
                }
                if cookieMode == "browser" {
                    Picker("Browser", selection: $cookieBrowser) {
                        if !installedBrowsers.contains(cookieBrowser) {
                            Text("\(browserName(cookieBrowser)) (not installed)").tag(cookieBrowser)
                        }
                        ForEach(installedBrowsers, id: \.self) { browser in
                            Text(browserName(browser)).tag(browser)
                        }
                    }
                }
                if cookieMode == "file" {
                    HStack {
                        Text(cookieFilePath.isEmpty
                             ? "No file selected"
                             : (cookieFilePath as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(cookieFilePath.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { chooseCookiesFile() }
                    }
                }
                statusView
                if selectedSource != .none {
                    Button("Recheck") {
                        cookieStatus.discoverBrowsers()
                        cookieStatus.refresh(for: selectedSource)
                    }
                    .disabled(cookieStatus.check == .checking)
                    .help("Check again after signing in or changing browser permissions")
                }
                Text("Use a signed-in YouTube session for videos that require it. Only YouTube cookies are read and passed to yt-dlp; their values are never shown or logged. Applies to the next load. Safari needs Full Disk Access; Chrome-family browsers ask for Keychain access.")
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
        .task(id: probeKey) { cookieStatus.refresh(for: selectedSource) }
    }

    // MARK: - Cookie status

    private var probeKey: String { "\(cookieMode)|\(effectiveBrowser)|\(cookieFilePath)" }

    private var installedBrowsers: [String] { cookieStatus.installedBrowsers }

    private var effectiveBrowser: String {
        cookieBrowser
    }

    private var selectedSource: YouTubeCookies {
        switch cookieMode {
        case "browser":
            return .browser(effectiveBrowser)
        case "file":
            return cookieFilePath.isEmpty ? .none : .file(URL(fileURLWithPath: cookieFilePath))
        default:
            return .none
        }
    }

    @ViewBuilder private var statusView: some View {
        switch cookieStatus.check {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking cookies…").font(.caption).foregroundStyle(.secondary)
            }
        case .result(let status):
            switch status {
            case .none:
                EmptyView()
            case .loaded(let count):
                let message = cookieMode == "file"
                    ? "Loaded \(count) YouTube cookie\(count == 1 ? "" : "s"). A file is a snapshot and can expire; re-export it if loading fails."
                    : "Loaded \(count) YouTube cookie\(count == 1 ? "" : "s")."
                statusLabel(message, color: .green, symbol: "checkmark.circle.fill")
            case .permissionDenied:
                statusLabel(permissionMessage, color: .red, symbol: "xmark.circle.fill")
            case .noSession:
                statusLabel(noSessionMessage, color: .red, symbol: "xmark.circle.fill")
            case .notInstalled:
                statusLabel("\(browserName(effectiveBrowser)) is not installed.", color: .red, symbol: "xmark.circle.fill")
            case .unavailable:
                statusLabel(cookieMode == "file" ? "Cannot read that cookies file."
                                                 : "Could not read cookies from \(browserName(effectiveBrowser)).",
                            color: .red, symbol: "xmark.circle.fill")
            }
        }
    }

    private func statusLabel(_ message: String, color: Color, symbol: String) -> some View {
        Label {
            Text(message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(color)
    }

    private var permissionMessage: String {
        switch effectiveBrowser {
        case "safari":
            "Cannot read Safari cookies. Grant AirThrow Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then recheck."
        default:
            "Keychain access was denied. Allow AirThrow to read the browser's stored key, then recheck."
        }
    }

    private var noSessionMessage: String {
        cookieMode == "file"
            ? "No YouTube cookies found in that file."
            : "No YouTube session found in \(browserName(effectiveBrowser)). Sign in to YouTube there, then recheck."
    }

    // MARK: - Helpers

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
        panel.message = "Choose a Netscape cookies.txt file. Only YouTube cookies are used."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { cookieFilePath = url.path }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
