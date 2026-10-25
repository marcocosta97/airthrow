import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private enum LibrarySelection: Hashable {
    case queue, history, tv, xtream
    case iptv(UUID)
}

/// Sidebar library, the section it opens, and the player along the bottom.
struct LibraryShell: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: ControllerPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 960

    private var sizeClass: LibrarySizeClass { LibrarySizeClass(width: width) }
    private var selection: LibrarySelection {
        switch controller.inspectorPage {
        case .playlist: .queue
        case .xtream: .xtream
        case .channels:
            if let id = controller.selectedIPTVPlaylistID { .iptv(id) } else { .tv }
        case .history: .history
        }
    }

    var body: some View {
        let compact = sizeClass == .compact
        VStack(spacing: 0) {
            if presentation.sourceVisible {
                SourceBar(controller: controller, presentation: presentation, compact: compact)
                Divider()
            } else if controller.iptvImporting {
                importStrip
                Divider()
            }
            HStack(spacing: 0) {
                if presentation.playlistVisible {
                    sidebar
                        .frame(width: compact ? nil : LibraryMetrics.sidebarWidth)
                        .frame(maxWidth: compact ? .infinity : nil, maxHeight: .infinity)
                    if !compact { Divider() }
                }
                if !compact || !presentation.playlistVisible {
                    libraryContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ControllerView(controller: controller, presentation: presentation, wide: !compact)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: LibraryWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(LibraryWidthKey.self) { if $0 > 1 { width = $0 } }
        .onChange(of: sizeClass) { previous, next in
            if next == .compact { presentation.playlistVisible = false }
            else if previous == .compact { presentation.playlistVisible = true }
        }
        .onChange(of: presentation.openFileRequest) { _, _ in
            presentVideoPicker { path in
                do { try controller.load(path) } catch { controller.displayError(error) }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.sourceVisible)
        .background(Color(nsColor: SurfaceColor.window))
        .dropDestination(for: URL.self) { sources, _ in
            acceptDrop(sources)
        } isTargeted: { presentationDrop in
            dropTargeted = presentationDrop
        }
        .overlay {
            if dropTargeted {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                    Text("Drop to load").font(.headline)
                    Text("One file replaces playback. An M3U playlist joins the library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    @State private var dropTargeted = false

    private var importStrip: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading channel playlist…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Cancel") { controller.cancelIPTVImport() }
                .help("Cancel loading the channel playlist")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func acceptDrop(_ sources: [URL]) -> Bool {
        for source in sources {
            let value = source.isFileURL ? source.path : source.absoluteString
            guard (try? MediaInput.source(value)) != nil else { continue }
            do { try controller.load(value) } catch { controller.displayError(error) }
            return true
        }
        return false
    }

    private func presentVideoPicker(onPick: @escaping (String) -> Void) {
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
            onPick(file.path)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private var sidebar: some View {
        List(selection: selectionBinding) {
            Section {
                Label("Queue", systemImage: "list.bullet").tag(LibrarySelection.queue)
                Label("History", systemImage: "clock").tag(LibrarySelection.history)
            }
            Section("TV") {
                if controller.iptvPlaylists.isEmpty {
                    Label("Playlists", systemImage: "tv").tag(LibrarySelection.tv)
                } else {
                    ForEach(controller.iptvPlaylists) { playlist in
                        Label(playlist.title, systemImage: "tv")
                            .tag(LibrarySelection.iptv(playlist.id))
                            .help(playlist.title)
                            .accessibilityLabel(playlist.title)
                    }
                }
            }
            if controller.xtreamLibrary != nil {
                Section {
                    Label("Xtream", systemImage: "film").tag(LibrarySelection.xtream)
                }
            }
        }
        // Sidebar style only lays out inside a navigation split. In this column
        // it keeps the width and draws the rows outside the window.
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: SurfaceColor.window))
        .accessibilityLabel("Library")
    }

    private var selectionBinding: Binding<LibrarySelection> {
        Binding(get: { selection }, set: { next in
            switch next {
            case .queue: controller.inspectorPage = .playlist
            case .history: controller.inspectorPage = .history
            case .tv:
                controller.inspectorPage = .channels
            case .xtream: controller.inspectorPage = .xtream
            case .iptv(let id): controller.selectIPTVPlaylist(id)
            }
        })
    }

    @ViewBuilder private var libraryContent: some View {
        switch controller.inspectorPage {
        case .playlist:
            if let queue = controller.snapshot.queue {
                PlaylistView(queue: queue)
            } else {
                ContentUnavailableView {
                    Label("Nothing queued", systemImage: "list.bullet")
                } description: {
                    Text("Use Open in the toolbar, or drop files here. One file replaces playback.")
                }
            }
        case .channels:
            if controller.iptvCatalog != nil {
                IPTVPanel(controller: controller, catalogID: controller.iptvCatalog?.id,
                          selectedID: controller.selectedIPTVChannelID).equatable()
            } else {
                ContentUnavailableView {
                    Label("No playlists", systemImage: "tv")
                } description: {
                    Text("Use Open in the toolbar to add an M3U playlist. Each one stays in the library until you remove it.")
                }
            }
        case .xtream:
            if let library = controller.xtreamLibrary {
                XtreamPanel(library: library, controller: controller,
                            placesDetailBesideList: sizeClass == .expanded).equatable()
            }
        case .history:
            HistoryPanel(controller: controller)
        }
    }
}

private struct SourceBar: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: ControllerPresentation
    var compact: Bool
    @State private var url = ""
    @FocusState private var urlFocused: Bool

    private var trimmed: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var somethingPlaying: Bool { controller.snapshot.state != .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sourceField
                sourceActions
                    .fixedSize(horizontal: true, vertical: false)
            }
            if controller.iptvImporting || !compact {
                HStack(spacing: 6) {
                    if controller.iptvImporting {
                        ProgressView().controlSize(.small)
                        Text("Loading channel playlist…")
                    } else if somethingPlaying {
                        Text("Play replaces playback. Add to Queue leaves the current video running.")
                    } else {
                        Text("Play replaces playback. An M3U playlist is added to the library.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: presentation.focusSourceRequest) { _, _ in urlFocused = true }
        .onAppear { urlFocused = true }
        .onReceive(controller.$sourceInput) { input in
            if let input { url = input }
        }
    }

    private var sourceField: some View {
        TextField("Video or playlist URL", text: $url)
            .textFieldStyle(.roundedBorder)
            .focused($urlFocused)
            .onSubmit(play)
            .accessibilityLabel("Video source")
            .accessibilityHint("Enter a URL or local file path. An M3U playlist is added to the library.")
    }

    @ViewBuilder private var sourceActions: some View {
        Button(action: chooseFile) {
            Image(systemName: "folder")
        }
        .help("Choose a video or playlist file")
        .accessibilityLabel("Choose video or playlist file")
        if controller.iptvImporting {
            Button("Cancel") { controller.cancelIPTVImport() }
                .help("Cancel loading the channel playlist")
        } else {
            Button(action: play) {
                Image(systemName: "play.fill")
            }
            .disabled(trimmed.isEmpty)
            .keyboardShortcut(.defaultAction)
            .help("Play this source. Play replaces what is playing. An M3U playlist is added to the library.")
            .accessibilityLabel("Play")
            if somethingPlaying {
                Button(action: enqueue) {
                    Image(systemName: "text.badge.plus")
                }
                .disabled(trimmed.isEmpty)
                .help("Add to the queue. The video on the TV keeps playing.")
                .accessibilityLabel("Add to queue")
            }
        }
    }

    private func play() {
        guard !trimmed.isEmpty else { return }
        do { try controller.load(url, autoplay: true) } catch { controller.displayError(error) }
        urlFocused = false
    }

    private func enqueue() {
        guard !trimmed.isEmpty else { return }
        do { try controller.enqueue(url) } catch { controller.displayError(error) }
        urlFocused = false
    }

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
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}

private enum LibraryMetrics {
    static let sidebarWidth: CGFloat = 212
    static let regularWidth: CGFloat = 720
    static let expandedWidth: CGFloat = 1100
}

private enum LibrarySizeClass: Equatable {
    case compact, regular, expanded

    init(width: CGFloat) {
        if width < LibraryMetrics.regularWidth { self = .compact }
        else if width < LibraryMetrics.expandedWidth { self = .regular }
        else { self = .expanded }
    }
}

private struct LibraryWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
