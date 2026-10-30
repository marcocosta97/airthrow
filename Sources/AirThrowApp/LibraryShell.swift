import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private enum LibrarySelection: Hashable {
    case queue, history, sources
    case network(NetworkLibrarySelection)
    case xtream(UUID, XtreamSection)
    case iptv(UUID)
}

/// Sidebar library, the section it opens, and the player along the bottom.
struct LibraryShell: View {
    @ObservedObject var controller: PlaybackController
    @ObservedObject var presentation: ControllerPresentation
    @ObservedObject private var networkLibrary: NetworkLibraryModel
    @State private var networkSelection: NetworkLibrarySelection?
    @State private var shareSheet = false
    @State private var editingShare: NetworkShare?
    init(controller: PlaybackController, presentation: ControllerPresentation) {
        self.controller = controller; self.presentation = presentation
        self.networkLibrary = controller.networkLibrary
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 960
    @State private var sourceDraft = ""
    @State private var regularSidebarVisible = true
    @State private var renamingPlaylist: XtreamPlaylistSummary?
    @State private var addingM3U = false
    @State private var editingIPTV: IPTVPlaylistSummary?
    @State private var collapsedPlaylists: Set<UUID> = []

    private var sizeClass: LibrarySizeClass { LibrarySizeClass(width: width) }
    private var selection: LibrarySelection {
        if let networkSelection { return .network(networkSelection) }
        return switch controller.inspectorPage {
        case .playlist: .queue
        case .xtream: controller.xtreamLibrary.map { .xtream($0.id, controller.selectedXtreamSection) } ?? .sources
        case .channels:
            if let id = controller.selectedIPTVPlaylistID { .iptv(id) } else { .sources }
        case .history: .history
        }
    }

    var body: some View {
        let compact = sizeClass == .compact
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: sidebarVisibility) {
                sidebar
                    .toolbar(removing: presentation.settingsVisible ? .sidebarToggle : nil)
                    // Apply sizing last so toolbar customization does not mask
                    // the native sidebar's minimum and maximum widths.
                    .navigationSplitViewColumnWidth(min: LibraryMetrics.sidebarMinimumWidth,
                                                    ideal: LibraryMetrics.sidebarWidth,
                                                    max: LibraryMetrics.sidebarMaximumWidth)
            } detail: {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationSplitViewStyle(.balanced)
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
        .task { await networkLibrary.open() }
        .onChange(of: networkLibrary.activeShare) { _, id in
            if let id { networkSelection = .share(id) }
        }
        .onChange(of: networkLibrary.configuration.shares.isEmpty) { _, empty in
            if empty, networkSelection != nil { networkSelection = nil; controller.showPlaylists() }
        }
        .sheet(isPresented: $shareSheet) {
            ShareConnectionSheet(model: networkLibrary, existing: editingShare)
        }
        .onChange(of: controller.sourceInput, initial: true) { _, input in
            if let input { sourceDraft = input }
        }
        .onChange(of: presentation.focusSourceRequest) { _, _ in
            if sizeClass == .compact { presentation.playlistVisible = false }
        }
        .onChange(of: presentation.openFileRequest) { _, _ in
            presentVideoPicker { path in
                do { try controller.load(path) } catch { controller.displayError(error) }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: presentation.sourceVisible)
        .background(Color(nsColor: SurfaceColor.window))
        .sheet(item: $editingIPTV) { playlist in
            PlaylistConnectionSheet(controller: controller, draft: controller.playlistConnectionDraft(kind: .m3u, id: playlist.id))
        }
        .sheet(item: $renamingPlaylist) { playlist in
            PlaylistConnectionSheet(controller: controller, draft: controller.playlistConnectionDraft(kind: .xtream, id: playlist.id))
        }
        .sheet(isPresented: $addingM3U) {
            PlaylistConnectionSheet(controller: controller, draft: controller.playlistConnectionDraft(kind: .m3u))
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

    private var mainContent: some View {
        VStack(spacing: 0) {
            if presentation.sourceVisible {
                SourceBar(controller: controller, presentation: presentation,
                          compact: sizeClass == .compact, url: $sourceDraft)
                Divider()
            } else if controller.iptvImporting {
                importStrip
                Divider()
            }
            libraryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

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
        sidebarList
        .listStyle(.sidebar)
        .accessibilityLabel("Library")
    }

    private var sidebarList: some View {
        List(selection: selectionBinding) {
            Section("Library") {
                Label("Queue", systemImage: "list.bullet").tag(LibrarySelection.queue)
                Label("History", systemImage: "clock").tag(LibrarySelection.history)
                Label("Sources", systemImage: "rectangle.stack").tag(LibrarySelection.sources)
            }
            Section("Shares") {
                ForEach(networkLibrary.configuration.shares) { share in
                    HStack {
                        Label(share.name, systemImage: "externaldrive").lineLimit(1)
                        Spacer(minLength: 4)
                        if networkLibrary.connectedShares.contains(share.id) {
                            Button { controller.unmountShare(share.id) } label: { Image(systemName: "eject") }
                                .buttonStyle(.borderless).help("Unmount \(share.name)")
                                .accessibilityLabel("Unmount \(share.name)")
                                .disabled(networkLibrary.unmounting.contains(share.id))
                        }
                    }
                    .tag(LibrarySelection.network(.share(share.id)))
                    .contextMenu {
                        Button("Update") { networkLibrary.reconnect(share.id) }
                        Button("Unmount") { controller.unmountShare(share.id) }
                            .disabled(!networkLibrary.connectedShares.contains(share.id))
                        Button("Edit Share…") { editingShare = share; shareSheet = true }
                        Button("Remove Share", role: .destructive) { Task { await networkLibrary.remove(share) } }
                    }
                }
            }
            if !controller.iptvPlaylistSources.isEmpty || !controller.xtreamPlaylists.isEmpty {
                Section("Saved Playlists") {
                    ForEach(controller.iptvPlaylistSources) { playlist in
                        Label(playlist.title, systemImage: "tv")
                            .lineLimit(1)
                            .tag(LibrarySelection.iptv(playlist.id))
                            .help(playlist.title)
                    }
                    ForEach(controller.xtreamPlaylists) { playlist in
                        DisclosureGroup(isExpanded: playlistExpanded(playlist.id)) {
                            playlistSections(playlist)
                        } label: {
                            playlistHeading(playlist)
                        }
                    }
                }
            }
        }
    }

    private func playlistExpanded(_ id: UUID) -> Binding<Bool> {
        Binding(get: { !collapsedPlaylists.contains(id) }, set: { expanded in
            if expanded { collapsedPlaylists.remove(id) }
            else { collapsedPlaylists.insert(id) }
        })
    }

    private func playlistSections(_ playlist: XtreamPlaylistSummary) -> some View {
        ForEach(XtreamSection.allCases, id: \.self) { section in
            Label(section.sidebarTitle, systemImage: section.sidebarSymbol)
                .tag(LibrarySelection.xtream(playlist.id, section))
                .contextMenu {
                    Button("Edit Playlist…") { renamingPlaylist = playlist }
                    Button("Remove Account", role: .destructive) { controller.removeHistoryEntry(playlist.id) }
                }
        }
    }

    private func playlistHeading(_ playlist: XtreamPlaylistSummary) -> some View {
        Label(playlist.title, systemImage: "rectangle.stack")
            .lineLimit(1).help(playlist.title)
            .contextMenu {
                Button("Edit Playlist…") { renamingPlaylist = playlist }
                    Button("Remove Account", role: .destructive) { controller.removeHistoryEntry(playlist.id) }
            }
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { presentation.playlistVisible ? .all : .detailOnly },
                set: { presentation.playlistVisible = $0 != .detailOnly })
    }

    private var selectionBinding: Binding<LibrarySelection> {
        Binding(get: { selection }, set: { next in
            if case .network(let selection) = next {
                networkSelection = selection
                if case .share(let id) = selection { networkLibrary.show(id) }
                return
            }
            networkSelection = nil
            switch next {
            case .network: break
            case .queue: controller.inspectorPage = .playlist
            case .history: controller.inspectorPage = .history
            case .sources: controller.showPlaylists()
            case .xtream(let id, let section):
                controller.openXtreamPlaylist(id, section: section)
            case .iptv(let id): controller.selectIPTVPlaylist(id)
            }
        })
    }

    @ViewBuilder private var libraryContent: some View {
        if let networkSelection {
            NetworkLibraryView(model: networkLibrary, controller: controller, selection: networkSelection)
        } else { nativeLibraryContent }
    }
    @ViewBuilder private var nativeLibraryContent: some View {
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
            } else {
                playlistOverview
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
            LibraryHeader(title: "Sources") {
                Menu("Add Source", systemImage: "plus") {
                    Button("M3U Playlist…", action: openSource)
                    Button("M3U Playlist…") { addingM3U = true }
                    Button("Xtream Account…") { presentation.xtreamPlaylistVisible = true }
                    Button("Network Share…") { editingShare = nil; shareSheet = true }
                }
            }
            if controller.xtreamPlaylists.isEmpty && controller.iptvPlaylistSources.isEmpty && networkLibrary.configuration.shares.isEmpty {
                ContentUnavailableView {
                    Label("No sources", systemImage: "rectangle.stack")
                } description: {
                    Text("Add an M3U playlist, Xtream account or network share. Your sources appear here and in the sidebar.")
                } actions: {
                    Button("Add Playlist…", action: openSource)
                    Button("Add Xtream Server…") { presentation.xtreamPlaylistVisible = true }
                    Button("Add Share…") { editingShare = nil; shareSheet = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(controller.xtreamPlaylists) { playlist in
                        HStack(spacing: 8) {
                            Button {
                                controller.openXtreamPlaylist(playlist.id, section: .live)
                            } label: {
                                LibraryItemLabel(title: playlist.title,
                                    subtitle: "Xtream · Live TV, Films and TV Series", kind: .xtream)
                            }.buttonStyle(.plain)
                            Button("Edit…") { renamingPlaylist = playlist }.buttonStyle(.bordered).controlSize(.small)
                            Button("Remove", role: .destructive) { controller.removeHistoryEntry(playlist.id) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }.libraryRowStyle()
                    }
                    ForEach(networkLibrary.configuration.shares) { share in
                        HStack(spacing: 8) {
                        Button {
                            networkSelection = .share(share.id); networkLibrary.show(share.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "externaldrive").font(.body).foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(share.name).font(.body).foregroundStyle(.primary).lineLimit(2)
                                    Text(share.kind.rawValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button("Edit…") { editingShare = share; shareSheet = true }.buttonStyle(.bordered).controlSize(.small)
                        }.libraryRowStyle()
                    }
                    ForEach(controller.iptvPlaylistSources) { playlist in
                        HStack(spacing: 8) {
                        Button { controller.selectIPTVPlaylist(playlist.id) } label: {
                            LibraryItemLabel(title: playlist.title, subtitle: "Channel playlist", kind: .iptv)
                        }.buttonStyle(.plain)
                        Button("Edit…") { editingIPTV = playlist }.buttonStyle(.bordered).controlSize(.small)
                        }.libraryRowStyle()
                    }
                }
                .libraryListStyle()
            }
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
        do { try controller.load(url, autoplay: controller.autoplayVideos ? nil : true) }
        catch { controller.displayError(error) }
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
    static let sidebarMinimumWidth: CGFloat = 180
    static let sidebarWidth: CGFloat = 212
    static let sidebarMaximumWidth: CGFloat = 320
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
