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
    private var task: Task<Void, Never>?

    func refresh(for source: YouTubeCookies) {
        task?.cancel()
        guard source != .none else { check = .idle; return }
        check = .checking
        let home = FileManager.default.homeDirectoryForCurrentUser
        task = Task { [weak self] in
            let result = await Task.detached { source.probe(home: home) }.value
            guard !Task.isCancelled else { return }
            self?.check = .result(result)
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
            Section("Media preparation") {
                Toggle("Avoid video conversion", isOn: Binding(
                    get: { !controller.allowVideoConversion },
                    set: { controller.setVideoConversionAllowed(!$0) }))
                Text("Copy compatible video and convert audio when needed. Turn this off to allow SDR video conversion up to 1080p. Applies to the next load or source choice.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Prefer higher quality", isOn: Binding(
                    get: { controller.preferQuality },
                    set: { controller.setPreferQuality($0) }))
                Text("Pick the highest resolution available, usually a remux, instead of the least processing. A YouTube video may default to a higher-quality remux rather than a lower-quality direct stream. Applies to the next load or source choice.")
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
                    if installedBrowsers.isEmpty {
                        Text("No supported browser was found on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Browser", selection: Binding(get: { effectiveBrowser }, set: { cookieBrowser = $0 })) {
                            ForEach(installedBrowsers, id: \.self) { browser in
                                Text(browserName(browser)).tag(browser)
                            }
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
                Text("Some public videos are blocked unless yt-dlp presents a signed-in session. Only YouTube cookies are read; they stay on this Mac and are never shown or logged. Applies to the next load. Safari needs Full Disk Access; Chrome-family browsers ask for Keychain access.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 440, height: 560)
        .task(id: probeKey) { cookieStatus.refresh(for: selectedSource) }
    }

    // MARK: - Cookie status

    private var probeKey: String { "\(cookieMode)|\(effectiveBrowser)|\(cookieFilePath)" }

    private var installedBrowsers: [String] { YouTubeCookiePreference.installedBrowsers() }

    private var effectiveBrowser: String {
        let installed = installedBrowsers
        if installed.contains(cookieBrowser) { return cookieBrowser }
        return installed.first ?? cookieBrowser
    }

    private var selectedSource: YouTubeCookies {
        switch cookieMode {
        case "browser":
            return installedBrowsers.isEmpty ? .none : .browser(effectiveBrowser)
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
            "Cannot read Safari cookies. Grant AirThrow Full Disk Access in System Settings → Privacy & Security → Full Disk Access, then reopen Settings."
        default:
            "Keychain access was denied. Allow AirThrow to read the browser's stored key, then reopen Settings."
        }
    }

    private var noSessionMessage: String {
        cookieMode == "file"
            ? "No YouTube cookies found in that file."
            : "No YouTube session found in \(browserName(effectiveBrowser)). Sign in to YouTube there, then reopen Settings."
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
        if panel.runModal() == .OK, let url = panel.url { cookieFilePath = url.path }
    }
}
