import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import AirThrowCore
#endif

// Explicit alias selects the longstanding property wrapper when an SDK also
// exports a State macro whose plugin is absent from Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

/// Shared window metrics so the controller column, the playlist column, and the
/// window frame all agree on widths.
enum ControllerMetrics {
    static let width: CGFloat = 470
    static let minWidth: CGFloat = 440
    static let playlistWidth: CGFloat = 270
    static let playlistMaximumWidth: CGFloat = 360
    static let animationDuration: TimeInterval = 0.25
}

/// Semantic surfaces follow the system appearance and accessibility contrast.
enum SurfaceColor {
    static let window = NSColor.windowBackgroundColor
    static let section = NSColor.controlBackgroundColor
}

@MainActor
final class ControllerPresentation: ObservableObject {
    @Published var playlistVisible = false
    @Published var settingsVisible = false
    @Published var xtreamPlaylistVisible = false
    /// Bumped by File ▸ Open… so the controller presents the file panel.
    @Published var openFileRequest = 0
    /// Bumped by File ▸ Open Location… once the source field can take focus.
    @Published var focusSourceRequest = 0
}

/// Keep the controller alive while Settings covers it, retaining source input
/// and the playback view's local state across page changes.
struct ControllerWindowView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var cookieStatus: CookieStatusModel
    @ObservedObject var presentation: ControllerPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ControllerView(controller: controller, presentation: presentation)
                .opacity(presentation.settingsVisible ? 0 : 1)
                .allowsHitTesting(!presentation.settingsVisible)
                .disabled(presentation.settingsVisible)
                .accessibilityHidden(presentation.settingsVisible)

            if presentation.settingsVisible {
                SettingsView(controller: controller, cookieStatus: cookieStatus)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18),
                   value: presentation.settingsVisible)
        .sheet(item: sheetBinding) { sheet in
            switch sheet {
            case .http(let request):
                HTTPLoginView(request: controller.httpLoginRequest ?? request, submit: { username, password in
                    controller.submitHTTPLogin(id: request.id, username: username, password: password)
                }, cancel: { controller.cancelHTTPLogin(id: request.id) })
                .id(request.id)
            case .xtream:
                XtreamPlaylistView(signingIn: controller.xtreamSigningIn,
                                   serverError: controller.xtreamSignInError,
                                   submit: { url in
                    try controller.connectXtream(url, reportInSheet: true)
                }, cancel: { presentation.xtreamPlaylistVisible = false },
                                   clearServerError: { controller.clearXtreamSignInError() })
            }
        }
        .onChange(of: controller.httpLoginRequest?.id) { _, request in
            if request != nil { presentation.xtreamPlaylistVisible = false }
        }
        .onChange(of: controller.xtreamSigningIn) { wasSigningIn, signingIn in
            // Close only when a sign-in this sheet started has succeeded.
            // Assigning the idle flag must not dismiss a sheet that is still waiting.
            guard wasSigningIn, !signingIn, presentation.xtreamPlaylistVisible,
                  controller.xtreamSignInError == nil, controller.inspectorPage == .xtream else { return }
            presentation.xtreamPlaylistVisible = false
        }
    }
    private enum Sheet: Identifiable {
        case http(HTTPLoginRequest), xtream
        var id: String {
            switch self {
            case .http(let request): "http-\(request.id)"
            case .xtream: "xtream"
            }
        }
    }
    private var activeSheet: Sheet? {
        if let request = controller.httpLoginRequest { return .http(request) }
        return presentation.xtreamPlaylistVisible ? .xtream : nil
    }
    private var sheetBinding: Binding<Sheet?> {
        let presented = activeSheet
        return Binding(get: { activeSheet }, set: { value in
            // A disappearing sheet must not cancel a newer login request.
            guard value == nil, activeSheet?.id == presented?.id else { return }
            switch presented {
            case .http(let request): controller.cancelHTTPLogin(id: request.id)
            case .xtream:
                controller.cancelIPTVImport()
                presentation.xtreamPlaylistVisible = false
            case nil: break
            }
        })
    }

}

struct ControllerView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: ControllerPresentation
    @ViewState private var url = ""
    @ViewState private var scrub: Double = 0
    @ViewState private var scrubbing = false
    @ViewState private var hoverTime: Double?
    @ViewState private var hoverX: CGFloat = 0
    @ViewState private var dropTargeted = false
    @FocusState private var urlFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: PlaybackSnapshot { controller.snapshot }
    private var progressHelp: String {
        if status.isLive, !LivePolicy.supportsTimeShift(status) {
            return "Live broadcast. No rewind window is currently available."
        }
        let ranges = PlaybackPolicy.readyRanges(status)
        let label = status.preparedRanges == nil ? "Buffered video" : "Video ready on this Mac"
        guard !ranges.isEmpty else { return "Highlighted sections show \(label.lowercased())." }
        let times = ranges.prefix(3).map { "\(PlaybackFormat.time($0.start))–\(PlaybackFormat.time($0.end))" }.joined(separator: ", ")
        let more = ranges.count > 3 ? ", and \(ranges.count - 3) more ranges" : ""
        return "\(label): \(times)\(more)."
    }
    private var busy: Bool { PlaybackPolicy.isBusy(status) }
    private var range: SeekRange? { PlaybackPolicy.activeSeekRange(status) }
    private var canControl: Bool { PlaybackPolicy.canControl(status) }
    private var isPlaying: Bool { PlaybackPolicy.isPlaying(status) }
    /// Source quality and enhancement belong to any loaded item, including a
    /// single-file source. The item is still shown after a failure so the
    /// enhancement can be reverted without retyping the URL.
    private var showsVideoMenu: Bool { status.state != .idle && status.receiverWaiting != true }
    private var activeEnhancement: VideoEnhancement? {
        guard let value = status.videoEnhancement, value != .original else { return nil }
        return value
    }
    private var playbackDetail: String {
        var parts: [String] = []
        if let path = status.playbackPath { parts.append(path.label) }
        if let quality = status.quality {
            parts.append(quality)
        }
        return parts.joined(separator: " · ")
    }
    private var playbackDetailHelp: String {
        if status.preparationInProgress == true {
            return "This Mac is preparing more video. Playback can continue."
        }
        if let activeEnhancement {
            return "\(activeEnhancement.label): prepared on this Mac. Changing it resumes at the current position. 4K needs a compatible receiver."
        }
        return status.playbackPath?.explanation ?? "Inspected source resolution"
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                section("Source") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("Video or playlist URL", text: $url)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($urlFocused)
                                    .onSubmit(load)
                                    .accessibilityLabel("Video source")
                                    .accessibilityHint("Enter a URL or local file path. You can also drop a video file or link here.")
                                    .help("A direct video URL, website video or playlist, or local video file")
                                Button(action: chooseFile) { Image(systemName: "folder") }
                                    .help("Choose a video or playlist file")
                                    .accessibilityLabel("Choose video or playlist file")
                                Button(controller.iptvImporting ? "Cancel" : "Load") {
                                    if controller.iptvImporting { controller.cancelIPTVImport() } else { load() }
                                }
                                    .disabled(!controller.iptvImporting && url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    .help(controller.iptvImporting ? "Cancel loading the channel playlist" : "Load this source without starting playback")
                            }
                            Text(controller.iptvImporting ? "Loading channel playlist…" : "Video URL, website, playlist, or local file")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                section("Playback", height: 216) {
                    VStack(alignment: .leading, spacing: 5) {
                    if status.state != .idle {
                        HStack(spacing: 8) {
                            if status.state == .buffering || status.seekInProgress == true {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityHidden(true)
                            }
                            Text(PlaybackPolicy.stateLabel(status)).font(.headline)
                        }
                    }
                    Spacer(minLength: 2)
                    if status.state == .idle {
                        Label(status.receiverWaiting == true ? "Ready to play on TV" : "No video loaded",
                              systemImage: status.receiverWaiting == true ? "tv" : "play.rectangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(status.title)
                                .help(status.title)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .textSelection(.enabled)
                            if showsVideoMenu {
                                HStack(spacing: 8) {
                                    if status.preparationInProgress == true,
                                       let speed = status.preparationSpeed, speed.isFinite, speed > 0 {
                                        Text(speed < 0.1 ? "<0.1×" : String(format: "%.1f×", speed))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .help("Video seconds prepared per second, including fetching, conversion and verification. Above 1× is faster than playback.")
                                            .accessibilityLabel("Preparation speed")
                                            .accessibilityValue(String(format: "%.1f times playback speed", speed))
                                    }
                                    if !playbackDetail.isEmpty {
                                        Text(playbackDetail)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .help(playbackDetailHelp)
                                            .accessibilityLabel("Playback: \(playbackDetail)")
                                            .accessibilityHint(playbackDetailHelp)
                                    }
                                    Spacer(minLength: 0)
                                    VideoMenuView(controller: controller)
                                }
                            }
                            if !status.externalPlaybackActive &&
                                (status.state == .awaitingReceiver || status.state == .connecting) {
                                Text("Choose an AirPlay receiver to play. Video options are available above.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if status.hasAudio == false {
                                Label("No audio track detected. Try a link that includes audio.", systemImage: "speaker.slash")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityLabel("No audio track detected. Try a link that includes audio.")
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 4) {
                        GeometryReader { geometry in
                            ZStack(alignment: .topLeading) {
                                SeekProgressSlider(value: Binding(get: {
                                    LivePolicy.timelinePosition(status, requested: scrubbing ? scrub : controller.pendingSeek)
                                }, set: { scrub = $0 }), bounds: (range?.start ?? 0)...(range?.end ?? 1),
                                    readyRanges: PlaybackPolicy.readyRanges(status), onEditingChanged: { editing in
                                    scrubbing = editing
                                    if !editing {
                                        perform {
                                            if status.isLive, (LivePolicy.delay(status, position: scrub) ?? .infinity) <= 3 {
                                                try controller.goLive()
                                            } else { try controller.seek(scrub) }
                                        }
                                    }
                                })
                                .frame(height: 20)
                                .padding(.top, 8)
                                .disabled(!PlaybackPolicy.canSeek(status))
                                .accessibilityLabel("Playback position")
                                .accessibilityValue(status.isLive ? livePositionLabel : PlaybackFormat.time(controller.pendingSeek ?? status.position))
                                .accessibilityHint(progressHelp)
                                .help(progressHelp)
                                if PlaybackPolicy.canSeek(status), let hoverTime {
                                    Text(status.isLive ? LivePolicy.positionLabel(status, position: hoverTime) : PlaybackFormat.time(hoverTime))
                                        .font(.caption2.monospacedDigit())
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                        .position(x: min(max(hoverX, 24), geometry.size.width - 24), y: 7)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard PlaybackPolicy.canSeek(status), let range, geometry.size.width > 0 else { hoverTime = nil; return }
                                    hoverX = min(max(location.x, 0), geometry.size.width)
                                    hoverTime = range.start + (range.end - range.start) * hoverX / geometry.size.width
                                case .ended: hoverTime = nil
                                }
                            }
                        }
                        .frame(height: 34)
                        HStack {
                            Text(livePositionLabel)
                            Spacer()
                            if LivePolicy.supportsTimeShift(status), !LivePolicy.isAtLive(status), status.liveOffset != nil {
                                Button("Go Live") { perform { try controller.goLive() } }
                                    .buttonStyle(.link)
                                    .disabled(!canControl)
                            } else {
                                Text(status.isLive ? "Live" : PlaybackFormat.time(status.duration))
                            }
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        if let queue = status.queue {
                            Button { perform { try controller.previous() } } label: { Image(systemName: "backward.end.fill") }
                                .disabled(queue.currentIndex == 0 || busy)
                                .help("Previous playlist item").accessibilityLabel("Previous playlist item")
                        }
                        Button { perform { try controller.skip(by: -10) } } label: {
                            Image(systemName: "gobackward.10")
                        }
                        .disabled(!PlaybackPolicy.canSkip(status, by: -10, position: controller.pendingSeek))
                        .help("Back 10 seconds (←)").accessibilityLabel("Back 10 seconds")

                        Button {
                            if isPlaying { controller.pause() } else { perform { try controller.play() } }
                        } label: {
                            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                                .frame(minWidth: 48)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canControl)
                        .help(isPlaying ? "Pause (Space)" : "Play (Space)")

                        Button { controller.stop() } label: { Image(systemName: "stop.fill") }
                            .disabled(status.state == .idle && status.receiverWaiting != true)
                            .help("Stop and unload video").accessibilityLabel("Stop and unload video")

                        Button { perform { try controller.skip(by: 10) } } label: {
                            Image(systemName: "goforward.10")
                        }
                        .disabled(!PlaybackPolicy.canSkip(status, by: 10, position: controller.pendingSeek))
                        .help("Forward 10 seconds (→)").accessibilityLabel("Forward 10 seconds")

                        if let queue = status.queue {
                            Button { perform { try controller.next() } } label: { Image(systemName: "forward.end.fill") }
                                .disabled(queue.currentIndex + 1 >= queue.items.count || busy)
                                .help("Next playlist item").accessibilityLabel("Next playlist item")
                        }
                    }
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                Group {
                    if let message = status.error ?? controller.iptvImportError ?? controller.notice {
                        ScrollView {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: status.error == nil && controller.iptvImportError == nil ? "info.circle" : "exclamationmark.triangle")
                                    .accessibilityHidden(true)
                                Text(message)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(message)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                                if status.errorReason == .preparationStorageLimit {
                                    Button("Settings…") {
                                        NSApp.sendAction(NSSelectorFromString("showSettings"), to: NSApp.delegate, from: nil)
                                    }
                                    .controlSize(.small)
                                }
                                if status.error == nil {
                                    Button { controller.clearNotice(); controller.clearIPTVImportError() } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).accessibilityLabel("Dismiss message")
                                }
                            }
                            .font(.callout)
                            .foregroundStyle(status.error == nil ? Color.secondary : Color.primary)
                        }
                    } else {
                        Text(status.receiverWaiting == true
                             ? "Load a video to replace the TV waiting screen."
                             : (status.state == .idle ? "Load a video, then press Play when your receiver is ready." : "Playback continues when you close this window."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                // Preserve the compact layout while allowing the complete
                // recovery message to scroll instead of truncating it.
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minWidth: ControllerMetrics.minWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if dropTargeted {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                    Text("Drop to load").font(.headline)
                    Text("Video file or web link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: SurfaceColor.window))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { sources, _ in
            acceptDrop(sources)
        } isTargeted: {
            if $0 { urlFocused = false }
            dropTargeted = $0
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dropTargeted)
        .onAppear {
            // An already loaded session should open ready for transport keys.
            urlFocused = status.state == .idle && !dropTargeted
        }
        .onChange(of: canControl) { _, ready in
            // Loads from the CLI, shared links and playlists also leave editing.
            if ready { urlFocused = false }
        }
        .onReceive(controller.$sourceInput) { input in
            if let input { url = input; urlFocused = false }
        }
        .onChange(of: presentation.openFileRequest) { _, _ in chooseFile() }
        .onChange(of: presentation.focusSourceRequest) { _, _ in urlFocused = true }
    }

    private func section<Content: View>(
        _ title: String,
        height: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .padding(.leading, 8)
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height, alignment: .top)
                .background(
                    Color(nsColor: SurfaceColor.section),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
    }

    private var livePositionLabel: String {
        if status.isLive {
            return LivePolicy.positionLabel(status, position: scrubbing ? scrub : controller.pendingSeek)
        }
        return PlaybackFormat.time(scrubbing ? scrub : (controller.pendingSeek ?? status.position))
    }

    private func load() { perform { try controller.load(url) }; urlFocused = false }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video or M3U Playlist"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = ["mp4", "m4v", "mov", "mkv", "webm", "m3u", "m3u8"].compactMap {
            UTType(filenameExtension: $0)
        }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let file = panel.url else { return }
            url = file.path
            load()
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    private func acceptDrop(_ sources: [URL]) -> Bool {
        for source in sources {
            let value = source.isFileURL ? source.path : source.absoluteString
            guard (try? MediaInput.source(value)) != nil else { continue }
            url = value
            load()
            return true
        }
        return false
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { controller.displayError(error) }
    }

}
