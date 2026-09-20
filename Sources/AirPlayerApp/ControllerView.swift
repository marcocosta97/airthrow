import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import AirPlayerCore
#endif

// Explicit alias selects the longstanding property wrapper when an SDK also
// exports a State macro whose plugin is absent from Command Line Tools.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
final class ControllerPresentation: ObservableObject {
    @Published var playlistVisible = true
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
    private var busy: Bool { PlaybackPolicy.isBusy(status) }
    private var range: SeekRange? { PlaybackPolicy.activeSeekRange(status) }
    private var canControl: Bool { PlaybackPolicy.canControl(status) }
    private var isPlaying: Bool { PlaybackPolicy.isPlaying(status) }

    var body: some View {
        ZStack {
        HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Video source").font(.headline)
                HStack(spacing: 8) {
                    TextField("URL or /path/to/video.mp4", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .focused($urlFocused)
                        .onSubmit(load)
                        .accessibilityLabel("Video source")
                        .accessibilityHint("Enter a URL or local file path. You can also drop a video file or link here.")
                        .help("A direct video URL, YouTube video or playlist, or local video file")
                    Button(action: chooseFile) { Image(systemName: "folder") }
                        .help("Choose a local video file")
                        .accessibilityLabel("Choose local video file")
                    Button("Load", action: load)
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Load this video without starting playback")
                }
                Text("Direct URL, YouTube, public playlist, or local file")
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
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text(PlaybackPolicy.stateLabel(status)).font(.title3.weight(.semibold))
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
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            Slider(value: Binding(get: {
                                let value = scrubbing ? scrub : (controller.pendingSeek ?? status.position ?? 0)
                                return min(max(value, range?.start ?? 0), range?.end ?? 1)
                            }, set: { scrub = $0 }), in: (range?.start ?? 0)...(range?.end ?? 1), onEditingChanged: { editing in
                                scrubbing = editing
                                if !editing { perform { try controller.seek(scrub) } }
                            })
                            .padding(.top, 12)
                            .disabled(!canControl || range == nil)
                            .accessibilityLabel("Playback position")
                            .accessibilityValue(PlaybackFormat.time(controller.pendingSeek ?? status.position))
                            if let hoverTime {
                                Text(PlaybackFormat.time(hoverTime))
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
                                guard let range, geometry.size.width > 0 else { hoverTime = nil; return }
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
                        if status.isLive, (status.liveOffset ?? 0) > 3 {
                            Button("Go Live") { perform { try controller.goLive() } }
                                .buttonStyle(.link)
                                .disabled(!canControl)
                        } else {
                            Text(status.isLive ? "Live" : PlaybackFormat.time(status.duration))
                        }
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.top, 6)

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

                    Button { perform { try controller.seek(min(range?.end ?? 0, (status.position ?? 0) + 10)) } } label: {
                        Image(systemName: "goforward.10")
                    }
                    .disabled(!canControl || range == nil)
                    .help("Forward 10 seconds").accessibilityLabel("Forward 10 seconds")

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
        .frame(width: 470)
        if let queue = status.queue, presentation.playlistVisible {
            Divider()
            playlistSidebar(queue)
                .frame(width: 270)
        }
        }
        if dropTargeted {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                Text("Drop to load").font(.headline)
                Text("Video file or web link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(8)
            }
            .padding(8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { sources, _ in
            acceptDrop(sources)
        } isTargeted: {
            if $0 { urlFocused = false }
            dropTargeted = $0
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: dropTargeted)
        .onAppear { if !dropTargeted { urlFocused = true } }
    }

    private func playlistSidebar(_ queue: PlaybackQueueSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(queue.title).font(.headline).lineLimit(2)
                Spacer(minLength: 8)
                Text("\(queue.currentIndex + 1)/\(queue.items.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(queue.items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text("\(index + 1).")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                                Group {
                                    if item.state == .pending {
                                        Color.clear.frame(width: 14, height: 1)
                                    } else {
                                        Image(systemName: queueIcon(item.state))
                                            .foregroundStyle(item.state == .current ? Color.accentColor : .secondary)
                                    }
                                }
                                .frame(width: 14)
                                .accessibilityHidden(true)
                                Text(item.title)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(item.state == .skipped ? .secondary : .primary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .background(item.state == .current ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(queueStateDescription(item.state))
                            .id(index)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(queue.currentIndex, anchor: .center) }
                .onChange(of: queue.currentIndex) { _, index in
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.5))
    }

    private var livePositionLabel: String {
        if status.isLive {
            let offset = scrubbing
                ? max(0, (range?.end ?? scrub) - scrub)
                : (status.liveOffset ?? 0)
            return offset > 3 ? "−\(PlaybackFormat.time(offset))" : "Live"
        }
        return PlaybackFormat.time(scrubbing ? scrub : (controller.pendingSeek ?? status.position))
    }

    private func load() { perform { try controller.load(url) }; urlFocused = false }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Video"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = ["mp4", "m4v", "mov", "mkv", "webm"].compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        url = file.path
        load()
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
    private func queueIcon(_ state: QueueItemState) -> String {
        switch state {
        case .current: "play.circle.fill"
        case .skipped: "exclamationmark.circle"
        case .pending: "circle"
        }
    }

    private func queueStateDescription(_ state: QueueItemState) -> String {
        switch state {
        case .current: "Now playing"
        case .skipped: "Skipped"
        case .pending: "Not yet played"
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
