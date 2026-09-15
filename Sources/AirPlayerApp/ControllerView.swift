import SwiftUI
import AVKit
#if SWIFT_PACKAGE
import AirPlayerCore
#endif

// Explicit alias selects the longstanding property wrapper when an SDK also
// exports a State macro whose plugin is absent from Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ControllerView: View {
    @ObservedObject var controller: PlaybackController
    @ViewState private var url = ""
    @ViewState private var scrub: Double = 0
    @ViewState private var scrubbing = false
    @FocusState private var urlFocused: Bool

    private var status: PlaybackSnapshot { controller.snapshot }
    private var busy: Bool { [.loading, .connecting].contains(status.state) }
    private var range: SeekRange? { status.isLive ? status.seekableRanges.last : status.seekableRanges.first }
    private var canControl: Bool {
        status.externalPlaybackActive && !busy && ![.idle, .failed].contains(status.state)
    }
    private var isPlaying: Bool { [.playing, .buffering].contains(status.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Video URL").font(.headline)
                HStack(spacing: 8) {
                    TextField("https://example.com/video.m3u8", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .focused($urlFocused)
                        .onSubmit(load)
                        .accessibilityLabel("Video URL")
                    .help("A direct video URL, YouTube video, or public YouTube playlist")
                    Button("Load", action: load)
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Load this video without starting playback")
                }
                Text("Direct video, YouTube video, or public playlist")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: status.externalPlaybackActive ? "tv.fill" : "tv")
                    .foregroundStyle(status.externalPlaybackActive ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.externalPlaybackActive ? "AirPlay connected" : "AirPlay receiver")
                        .font(.subheadline.weight(.medium))
                    Text(status.externalPlaybackActive ? "Use AirPlay to change the receiver" : "Choose before or after loading a video")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RoutePicker(controller: controller)
                    .frame(width: 38, height: 28)
                    .help("Choose an AirPlay video receiver")
                    .accessibilityLabel("Choose AirPlay receiver")
            }

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if busy || status.state == .buffering {
                        ProgressView().controlSize(.small)
                    }
                    Text(stateLabel).font(.title3.weight(.semibold))
                }
                Text(status.title)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                if let path = status.playbackPath {
                    Text(path.label)
                        .font(.caption).foregroundStyle(.secondary)
                        .help(path.explanation)
                        .accessibilityLabel("Playback path: \(path.label)")
                        .accessibilityHint(path.explanation)
                }
                if status.hasAudio == false {
                    Label("No audio track detected. Try a link that includes audio.", systemImage: "speaker.slash")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("No audio track detected. Try a link that includes audio.")
                }
                VStack(spacing: 4) {
                    Slider(value: Binding(get: {
                        let value = scrubbing ? scrub : (controller.pendingSeek ?? status.position ?? 0)
                        return min(max(value, range?.start ?? 0), range?.end ?? 1)
                    }, set: { scrub = $0 }), in: (range?.start ?? 0)...(range?.end ?? 1), onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { perform { try controller.seek(scrub) } }
                    })
                    .disabled(!canControl || range == nil)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue(time(controller.pendingSeek ?? status.position))
                    HStack {
                        Text(livePositionLabel)
                        Spacer()
                        if status.isLive, (status.liveOffset ?? 0) > 3 {
                            Button("Go Live") { perform { try controller.goLive() } }
                                .buttonStyle(.link)
                                .disabled(!canControl)
                        } else {
                            Text(status.isLive ? "Live" : time(status.duration))
                        }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.top, 6)

                if let queue = status.queue {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(queue.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text("\(queue.currentIndex + 1) of \(queue.items.count)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(queue.items.enumerated()), id: \.offset) { index, item in
                                        HStack(spacing: 6) {
                                            Image(systemName: queueIcon(item.state))
                                                .frame(width: 14).foregroundStyle(item.state == .current ? Color.accentColor : .secondary)
                                            Text(item.title).lineLimit(1).foregroundStyle(item.state == .skipped ? .secondary : .primary)
                                        }
                                        .font(.caption)
                                        .id(index)
                                    }
                                }
                            }
                            .frame(maxHeight: 72)
                            .onChange(of: queue.currentIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
                        }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                HStack(spacing: 12) {
                    if let queue = status.queue {
                        Button { perform { try controller.previous() } } label: { Image(systemName: "backward.end.fill") }
                            .disabled(queue.currentIndex == 0 || busy)
                            .help("Previous playlist item").accessibilityLabel("Previous playlist item")
                    }
                    Button { perform { try controller.seek(max(range?.start ?? 0, (status.position ?? 0) - 10)) } } label: {
                        Image(systemName: "gobackward.10")
                    }
                    .disabled(!canControl || range == nil)
                    .help("Back 10 seconds").accessibilityLabel("Back 10 seconds")

                    Button {
                        if isPlaying { controller.pause() } else { perform { try controller.play() } }
                    } label: {
                        Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                            .frame(minWidth: 66)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canControl)
                    .keyboardShortcut(.space, modifiers: [])

                    Button { controller.stop() } label: { Image(systemName: "stop.fill") }
                        .disabled(status.state == .idle)
                        .help("Stop and unload video").accessibilityLabel("Stop")

                    if let queue = status.queue {
                        Button { perform { try controller.next() } } label: { Image(systemName: "forward.end.fill") }
                            .disabled(queue.currentIndex + 1 >= queue.items.count || busy)
                            .help("Next playlist item").accessibilityLabel("Next playlist item")
                    }
                }
                .controlSize(.large)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)

            if let message = status.error ?? controller.notice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: status.error == nil ? "info.circle" : "exclamationmark.triangle")
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if status.error == nil {
                        Button { controller.clearNotice() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss message")
                    }
                }
                .font(.callout)
                .foregroundStyle(status.error == nil ? Color.secondary : Color.primary)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(status.state == .idle ? "Choose a receiver or load a video in either order." : "Playback continues when you close this window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(minWidth: 430, idealWidth: 470, maxWidth: .infinity)
        .onAppear { urlFocused = true }
    }

    private var livePositionLabel: String {
        if status.isLive {
            let offset = scrubbing
                ? max(0, (range?.end ?? scrub) - scrub)
                : (status.liveOffset ?? 0)
            return offset > 3 ? "−\(time(offset))" : "Live"
        }
        return time(scrubbing ? scrub : (controller.pendingSeek ?? status.position))
    }

    private func load() { perform { try controller.load(url) }; urlFocused = false }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { controller.displayError(error) }
    }
    private func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "—:—" }
        let value = Int(seconds)
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    private func queueIcon(_ state: QueueItemState) -> String {
        switch state {
        case .current: "play.circle.fill"
        case .skipped: "exclamationmark.circle"
        case .pending: "circle"
        }
    }
    private var stateLabel: String {
        switch status.state {
        case .idle: "Ready for your next video"
        case .loading:
            switch status.loadingPhase {
            case "resolving": "Finding video…"
            case "preparing": "Preparing video…"
            default: "Loading video…"
            }
        case .connecting: "Connecting to AirPlay…"
        case .awaitingReceiver: "Ready to connect"
        case .ready: "Ready to play"
        case .buffering: "Buffering…"
        case .playing: "Playing on AirPlay"
        case .paused: "Paused"
        case .ended: "Video ended"
        case .failed: "Unable to play video"
        }
    }
}

private struct RoutePicker: NSViewRepresentable {
    let controller: PlaybackController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = controller.player
        view.delegate = context.coordinator
        view.isRoutePickerButtonBordered = true
        return view
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
    @MainActor final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        let controller: PlaybackController
        init(_ controller: PlaybackController) { self.controller = controller }
        nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { Task { @MainActor in controller.pickerWillOpen() } }
        nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { Task { @MainActor in controller.pickerDidClose() } }
    }
}
