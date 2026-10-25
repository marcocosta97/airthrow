import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private enum LibrarySelection: Hashable {
    case queue, history, tv
    case xtream(UUID, XtreamSection)
    case iptv(UUID)
}

/// Sidebar library, the section it opens, and the player along the bottom.
struct LibraryShell: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: ControllerPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 960
    @State private var sourceDraft = ""
    @State private var regularSidebarVisible = true
    @State private var renamingPlaylist: XtreamPlaylistSummary?
    @State private var collapsedPlaylists: Set<UUID> = []

    private var sizeClass: LibrarySizeClass { LibrarySizeClass(width: width) }
    private var selection: LibrarySelection {
        switch controller.inspectorPage {
        case .playlist: .queue
        case .xtream: controller.xtreamLibrary.map { .xtream($0.id, controller.selectedXtreamSection) } ?? .tv
        case .channels:
            if let id = controller.selectedIPTVPlaylistID { .iptv(id) } else { .tv }
        case .history: .history
        }
    }

    var body: some View {
        let compact = sizeClass == .compact
        VStack(spacing: 0) {
            if presentation.sourceVisible {
                SourceBar(controller: controller, presentation: presentation, compact: compact, url: $sourceDraft)
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
            if next == .compact {
                regularSidebarVisible = presentation.playlistVisible
                presentation.playlistVisible = false
            } else if previous == .compact {
                presentation.playlistVisible = regularSidebarVisible
            }
        }
        .onChange(of: controller.sourceInput, initial: true) { _, input in
            if let input { sourceDraft = input }
        }
        .onChange(of: controller.inspectorPage) { _, _ in
            if sizeClass == .compact { presentation.playlistVisible = false }
        }
        .onChange(of: presentation.openFileRequest) { _, _ in
            presentVideoPicker { path in
                do { try controller.load(path) } catch { controller.displayError(error) }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.sourceVisible)
        .background(Color(nsColor: SurfaceColor.window))
        .sheet(item: $renamingPlaylist) { playlist in
            PlaylistNameSheet(name: playlist.title) { name in
                controller.renameXtreamPlaylist(playlist.id, name: name)
                renamingPlaylist = nil
            } cancel: { renamingPlaylist = nil }
        }
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
            Text("Loading playlist…")
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
                Label("Playlists", systemImage: "rectangle.stack").tag(LibrarySelection.tv)
            }
            if !controller.iptvPlaylists.isEmpty {
                Section("TV") {
                    ForEach(controller.iptvPlaylists) { playlist in
                        Label(playlist.title, systemImage: "tv")
                            .tag(LibrarySelection.iptv(playlist.id))
                            .help(playlist.title)
                    }
                }
            }
            ForEach(controller.xtreamPlaylists) { playlist in
                Section {
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsedPlaylists.contains(playlist.id) },
                        set: { expanded in
                            if expanded { collapsedPlaylists.remove(playlist.id) }
                            else { collapsedPlaylists.insert(playlist.id) }
                        })) {
                        ForEach(XtreamSection.allCases, id: \.self) { section in
                            Label(section.sidebarTitle, systemImage: section.sidebarSymbol)
                                .tag(LibrarySelection.xtream(playlist.id, section))
                                .contextMenu {
                                    Button("Rename Playlist…") { renamingPlaylist = playlist }
                                }
                        }
                    } label: {
                        Label(playlist.title, systemImage: "rectangle.stack")
                            .lineLimit(1).help(playlist.title)
                    }
                    .contextMenu {
                        Button("Rename Playlist…") { renamingPlaylist = playlist }
                    }
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
            case .tv: controller.showPlaylists()
            case .xtream(let id, let section):
                controller.openXtreamPlaylist(id, section: section)
            case .iptv(let id): controller.selectIPTVPlaylist(id)
            }
            if sizeClass == .compact { presentation.playlistVisible = false }
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
                    Text("Open a video or drop a file here to get started.")
                } actions: {
                    openSourceButton
                }
            }
        case .channels:
            if controller.iptvCatalog != nil {
                IPTVPanel(controller: controller, catalogID: controller.iptvCatalog?.id,
                          selectedID: controller.selectedIPTVChannelID).equatable()
            } else if !controller.xtreamPlaylists.isEmpty || !controller.iptvPlaylists.isEmpty {
                playlistOverview
            } else {
                ContentUnavailableView {
                    Label("No playlists", systemImage: "tv")
                } description: {
                    Text("Add an M3U playlist or Xtream account. Your playlists appear here and in the sidebar.")
                } actions: {
                    Button("Add Playlist…", action: openSource)
                    Button("Add Xtream Server…") { presentation.xtreamPlaylistVisible = true }
                }
            }
        case .xtream:
            if let library = controller.xtreamLibrary {
                XtreamPanel(library: library, controller: controller,
                            placesDetailBesideList: sizeClass == .expanded, showsSectionPicker: false).equatable()
            }
        case .history:
            HistoryPanel(controller: controller, openSource: openSource)
        }
    }
    private var playlistOverview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Playlists").font(.headline)
                Spacer()
                Menu("Add Playlist", systemImage: "plus") {
                    Button("M3U Playlist…", action: openSource)
                    Button("Xtream Account…") { presentation.xtreamPlaylistVisible = true }
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
            List {
                ForEach(controller.xtreamPlaylists) { playlist in
                    HStack {
                        Button {
                            controller.openXtreamPlaylist(playlist.id, section: .live)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(playlist.title, systemImage: "rectangle.stack")
                                Text("Xtream · Live TV, Films and TV Series").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button("Rename…") { renamingPlaylist = playlist }.buttonStyle(.bordered).controlSize(.small)
                    }.padding(.vertical, 6)
                }
                ForEach(controller.iptvPlaylists) { playlist in
                    Button { controller.selectIPTVPlaylist(playlist.id) } label: {
                        Label(playlist.title, systemImage: "tv")
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, 6)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
        }
    }

    private var openSourceButton: some View {
        Button("Open Video…", systemImage: "plus", action: openSource)
    }

    private func openSource() {
        presentation.sourceVisible = true
        presentation.focusSourceRequest += 1
    }
}

private struct SourceBar: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: ControllerPresentation
    var compact: Bool
    @Binding var url: String
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
                        Text("Loading playlist…")
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
    }

    private var sourceField: some View {
        TextField("Video, playlist URL, or file path", text: $url)
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
                Label("Play", systemImage: "play.fill")
            }
            .disabled(trimmed.isEmpty)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
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

private struct PlaylistNameSheet: View {
    @State var name: String
    let save: (String) -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Playlist").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(name) }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 340).task { focused = true }
    }
}
