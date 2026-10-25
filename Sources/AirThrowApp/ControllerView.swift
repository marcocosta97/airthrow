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
    @Published var playlistVisible = true
    /// The video field lives in the main window. The toolbar plus button shows and hides it.
    @Published var sourceVisible = false
    @Published var settingsVisible = false
    @Published var xtreamPlaylistVisible = false
    /// Bumped by File ▸ Open… so the controller presents the file panel.
    @Published var openFileRequest = 0
    /// Bumped by File ▸ Open Location… once the source field can take focus.
    @Published var focusSourceRequest = 0
}

private struct WindowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Keep the controller alive while Settings covers it, retaining source input
/// and the playback view's local state across page changes.
struct ControllerWindowView: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var cookieStatus: CookieStatusModel
    @ObservedObject var presentation: ControllerPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var receiverConnection: ReceiverConnectionState
    @State private var width: CGFloat = 960

    init(controller: PlaybackController, cookieStatus: CookieStatusModel, presentation: ControllerPresentation) {
        self.controller = controller
        self.cookieStatus = cookieStatus
        self.presentation = presentation
        _receiverConnection = StateObject(wrappedValue: ReceiverConnectionState(controller: controller))
    }

    private var compact: Bool { width < 720 }

    @ToolbarContentBuilder private var windowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Toggle(isOn: $presentation.playlistVisible) {
                Image(systemName: "sidebar.left")
            }
            .toggleStyle(.button)
            .disabled(presentation.settingsVisible)
            .help(presentation.playlistVisible ? "Hide sidebar" : "Show sidebar")
            .accessibilityLabel(presentation.playlistVisible ? "Hide sidebar" : "Show sidebar")
        }
        if !compact, let label = receiverConnection.toolbarLabel {
            ToolbarItem(placement: .principal) {
                ReceiverToolbarTitle(label: label, connecting: receiverConnection.phase == .connecting)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: sourceVisible) {
                Image(systemName: "plus")
            }
            .toggleStyle(.button)
            .help(presentation.sourceVisible ? "Hide source field" : "Open video or playlist (⌘L)")
            .accessibilityLabel(presentation.sourceVisible ? "Hide source field" : "Open video or playlist")
        }
        ToolbarItem(placement: .primaryAction) {
            ReceiverToolbarButton(controller: controller, connection: receiverConnection)
                .frame(width: 32, height: 28)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: settingsVisible) {
                Image(systemName: "gearshape")
            }
            .toggleStyle(.button)
            .help(presentation.settingsVisible ? "Leave Settings" : "Settings")
            .accessibilityLabel(presentation.settingsVisible ? "Leave Settings" : "Settings")
        }
    }

    private var sourceVisible: Binding<Bool> {
        Binding(get: { presentation.sourceVisible }, set: { show in
            if show {
                presentation.settingsVisible = false
                presentation.sourceVisible = true
                DispatchQueue.main.async { presentation.focusSourceRequest += 1 }
            } else {
                NSApp.keyWindow?.makeFirstResponder(nil)
                presentation.sourceVisible = false
            }
        })
    }

    private var settingsVisible: Binding<Bool> {
        Binding(get: { presentation.settingsVisible }, set: { show in
            NSApp.keyWindow?.makeFirstResponder(nil)
            presentation.settingsVisible = show
        })
    }

    var body: some View {
        ZStack {
            LibraryShell(controller: controller, presentation: presentation)
                .opacity(presentation.settingsVisible ? 0 : 1)
                .allowsHitTesting(!presentation.settingsVisible)
                .disabled(presentation.settingsVisible)
                .accessibilityHidden(presentation.settingsVisible)

            if presentation.settingsVisible {
                VStack(spacing: 0) {
                    HStack {
                        Text("Settings").font(.headline)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    SettingsView(controller: controller, cookieStatus: cookieStatus)
                }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: SurfaceColor.window))
                    .transition(.opacity)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: WindowWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(WindowWidthKey.self) { if $0 > 1 { width = $0 } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18),
                   value: presentation.settingsVisible)
        .toolbar { windowToolbar }
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
    var wide: Bool
    @ViewState private var scrub: Double = 0
    @ViewState private var scrubbing = false

    private var status: PlaybackSnapshot { controller.snapshot }
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
            VStack(alignment: .leading, spacing: 8) {
                noticeBlock
                if status.state == .idle {
                    Text(status.receiverWaiting == true ? "Ready to play on TV" : "Nothing playing")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    playback
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: SurfaceColor.window))
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 12) {
            if wide {
                HStack(alignment: .center, spacing: 20) {
                    titleBlock(limit: 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    transport.fixedSize(horizontal: true, vertical: false)
                }
                timeline
            } else {
                titleBlock(limit: 2)
                timeline
                transport.frame(maxWidth: .infinity)
            }
        }
    }

    private func titleBlock(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if busy || status.state == .buffering || status.seekInProgress == true {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text(status.title)
                    .font(.headline)
                    .lineLimit(limit)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(status.title)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(playbackStateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                if wide, !playbackDetail.isEmpty {
                    Text(playbackDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(playbackDetailHelp)
                }
                Spacer(minLength: 0)
                if showsVideoMenu { VideoMenuView(controller: controller) }
            }
            if status.hasAudio == false {
                Label("No audio track detected. Try a source that includes audio.", systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !status.externalPlaybackActive &&
                (status.state == .awaitingReceiver || status.state == .connecting) {
                Text("Choose a receiver with the AirPlay button to play on TV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var playbackStateLabel: String {
        if status.seekInProgress == true { return "Seeking…" }
        switch status.state {
        case .idle: return "Nothing playing"
        case .loading: return "Loading…"
        case .connecting: return "Connecting…"
        case .awaitingReceiver: return "Ready for AirPlay"
        case .ready: return "Ready"
        case .buffering: return "Buffering…"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .ended: return "Finished"
        case .failed: return "Unable to play"
        }
    }

    private var timeline: some View {
        VStack(spacing: 4) {
            PlaybackTimeline(controller: controller, scrub: $scrub, scrubbing: $scrubbing, perform: perform)
                .frame(height: 28)
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
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            if let queue = status.queue {
                Button { perform { try controller.previous() } } label: { Image(systemName: "backward.end.fill") }
                    .disabled(queue.currentIndex == 0 || busy)
                    .help("Previous playlist item").accessibilityLabel("Previous playlist item")
            }
            Button { perform { try controller.skip(by: -10) } } label: { Image(systemName: "gobackward.10") }
                .disabled(!PlaybackPolicy.canSkip(status, by: -10, position: controller.pendingSeek))
                .help("Back 10 seconds (←)").accessibilityLabel("Back 10 seconds")
            Button {
                if isPlaying { controller.pause() } else { perform { try controller.play() } }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canControl)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .help(isPlaying ? "Pause (Space)" : "Play (Space)")
            Button { perform { try controller.skip(by: 10) } } label: { Image(systemName: "goforward.10") }
                .disabled(!PlaybackPolicy.canSkip(status, by: 10, position: controller.pendingSeek))
                .help("Forward 10 seconds (→)").accessibilityLabel("Forward 10 seconds")
            if let queue = status.queue {
                Button { perform { try controller.next() } } label: { Image(systemName: "forward.end.fill") }
                    .disabled(queue.currentIndex + 1 >= queue.items.count || busy)
                    .help("Next playlist item").accessibilityLabel("Next playlist item")
            }
            Divider().frame(height: 16).padding(.horizontal, 2)
            Button { controller.stop() } label: { Image(systemName: "stop.fill") }
                .disabled(status.state == .idle && status.receiverWaiting != true)
                .help("Stop and unload video").accessibilityLabel("Stop and unload video")
        }
        .controlSize(.regular)
    }

    @ViewBuilder private var noticeBlock: some View {
        if let message = status.error ?? controller.iptvImportError ?? controller.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: status.error == nil && controller.iptvImportError == nil ? "info.circle" : "exclamationmark.triangle")
                    .accessibilityHidden(true)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if status.errorReason == .preparationStorageLimit {
                    Button("Settings…") {
                        presentation.settingsVisible = true
                    }
                    .controlSize(.small)
                }
                Button {
                    if status.error != nil { controller.dismissPlaybackError() }
                    controller.clearNotice()
                    controller.clearIPTVImportError()
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Dismiss message")
                    .accessibilityLabel("Dismiss message")
            }
            .foregroundStyle(status.error == nil ? Color.secondary : Color.primary)
        }
    }

    private var livePositionLabel: String {
        if status.isLive {
            return LivePolicy.positionLabel(status, position: scrubbing ? scrub : controller.pendingSeek)
        }
        return PlaybackFormat.time(scrubbing ? scrub : (controller.pendingSeek ?? status.position))
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { controller.displayError(error) }
    }

}

/// Hover lives here so a pointer move does not rebuild the rest of the controller.
/// The time follows the slider knob, which cannot reach the ends of the view.
private struct PlaybackTimeline: View {
    @ObservedObject var controller: PlaybackController
    @Binding var scrub: Double
    @Binding var scrubbing: Bool
    let perform: (() throws -> Void) -> Void
    @State private var hoverTime: Double?
    @State private var hoverX: CGFloat = 0
    @State private var knobWidth: CGFloat = 18

    private var status: PlaybackSnapshot { controller.snapshot }
    private var range: SeekRange? { PlaybackPolicy.activeSeekRange(status) }
    private var positionLabel: String {
        if status.isLive {
            return LivePolicy.positionLabel(status, position: scrubbing ? scrub : controller.pendingSeek)
        }
        return PlaybackFormat.time(scrubbing ? scrub : (controller.pendingSeek ?? status.position))
    }
    private var progressHelp: String {
        if status.isLive, !LivePolicy.supportsTimeShift(status) {
            return "Live broadcast. No rewind window is currently available."
        }
        let ranges = PlaybackPolicy.readyRanges(status)
        let label = status.preparedRanges == nil ? "Buffered video" : "Video ready on this Mac"
        guard !ranges.isEmpty else { return "Highlighted sections show \(label.lowercased())." }
        let times = ranges.prefix(3).map { "\(PlaybackFormat.time($0.start))–\(PlaybackFormat.time($0.end))" }.joined(separator: ", ")
        let more = ranges.count > 3 ? ", and \(InterfaceCopy.moreRanges(ranges.count - 3))" : ""
        return "\(label): \(times)\(more)."
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                SeekProgressSlider(value: Binding(get: {
                    LivePolicy.timelinePosition(status, requested: scrubbing ? scrub : controller.pendingSeek)
                }, set: { scrub = $0 }), knobWidth: $knobWidth,
                    bounds: (range?.start ?? 0)...(range?.end ?? 1),
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
                .accessibilityValue(positionLabel)
                .accessibilityHint(progressHelp)
                .help(progressHelp)
                if PlaybackPolicy.canSeek(status), let hoverTime {
                    Text(status.isLive ? LivePolicy.positionLabel(status, position: hoverTime) : PlaybackFormat.time(hoverTime))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .position(x: min(max(hoverX, 24), max(geometry.size.width - 24, 24)), y: 7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard PlaybackPolicy.canSeek(status), let range, geometry.size.width > 0 else { hoverTime = nil; return }
                    let inset = max(knobWidth, 1) / 2
                    let span = max(geometry.size.width - max(knobWidth, 1), 1)
                    let x = min(max(location.x, inset), inset + span)
                    let fraction = (x - inset) / span
                    hoverX = x
                    let time = range.start + (range.end - range.start) * fraction
                    hoverTime = min(max(time, range.start), range.end)
                case .ended: hoverTime = nil
                }
            }
        }
    }
}
