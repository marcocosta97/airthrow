import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import AirThrowCore
#endif

struct XtreamPanel: View, Equatable {
    @ObservedObject var library: XtreamLibrary
    /// Not observed. Playback snapshots update several times a second and must
    /// not rebuild this catalog; the parent compares the fields below instead.
    let controller: PlaybackController
    /// Same library instance means a playback snapshot can skip rebuilding this panel.
    /// Library publishes its own changes through the observed object.
    let libraryIdentity: ObjectIdentifier
    /// At the expanded width the catalog stays beside the selected title.
    let placesDetailBesideList: Bool

    init(library: XtreamLibrary, controller: PlaybackController, placesDetailBesideList: Bool = false) {
        self.library = library
        self.controller = controller
        self.libraryIdentity = ObjectIdentifier(library)
        self.placesDetailBesideList = placesDetailBesideList
    }
    @SwiftUI.State private var season: Int?
    @SwiftUI.State private var accountVisible = false
    @FocusState private var searchFocused: Bool

    private var items: [XtreamItem] { library.visibleItems }

    nonisolated static func == (lhs: XtreamPanel, rhs: XtreamPanel) -> Bool {
        lhs.libraryIdentity == rhs.libraryIdentity && lhs.placesDetailBesideList == rhs.placesDetailBesideList
    }

    var body: some View {
        Group {
            if placesDetailBesideList, library.selected != nil {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        InspectorHeader(title: "Xtream", back: nil)
                        catalog
                    }
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                    Divider()
                    details
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    InspectorHeader(title: "Xtream", back: nil)
                    if library.selected != nil {
                        details
                    } else {
                        catalog
                    }
                }
            }
        }
        .onChange(of: library.selected?.id) { _, _ in season = nil }
    }

    private var catalog: some View {
        let key = library.catalogKey
        return VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                Picker("Catalog", selection: Binding(get: { library.section }, set: { library.switchSection($0) })) {
                    ForEach(XtreamSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Catalog")
                CategoryPopUpField(selection: Binding(get: { library.categoryID }, set: { library.browse(library.section, categoryID: $0) }),
                                   options: [.init(title: "All categories", value: nil)] + library.categories.map { .init(title: $0.name, value: $0.id) },
                                   accessibilityLabel: "Category")
                    .frame(height: 26)
                TextField("Find a title", text: Binding(get: { library.search }, set: { library.setSearch($0) })).textFieldStyle(.roundedBorder)
                    .focused($searchFocused).accessibilityLabel("Find a title").frame(height: 26)
                HStack {
                    Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { accountVisible.toggle() } label: { Image(systemName: "person.crop.circle") }
                        .buttonStyle(.plain).help("Account details").accessibilityLabel("Account details")
                        .popover(isPresented: $accountVisible) { accountDetails }
                    Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).disabled(library.loading).help("Refresh catalog").accessibilityLabel("Refresh catalog")
                }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if library.loading {
                HStack { ProgressView().controlSize(.small); Text("Loading catalog…"); Spacer(); Button("Cancel") { library.cancelLoading() } }
                    .padding(12)
            } else if let error = library.error {
                recovery(error) { library.refresh() }
            } else if items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(library.search.isEmpty ? "No titles in this category" : "No matching titles").font(.callout)
                    if !library.search.isEmpty { Button("Clear search") { library.setSearch("") } }
                }.padding(12)
            } else {
                ScrollView {
                    XtreamTitleList(revision: library.visibleRevision, items: items,
                                    categoryNames: library.categoryNames, playingID: library.playingID,
                                    section: library.section, resignSearch: { searchFocused = false },
                                    play: play, select: { library.select($0) })
                        .equatable()
                }
                .scrollPosition(id: Binding(get: { library.scrollID }, set: { library.updateScroll($0, for: key) }), anchor: .top)
                .id(key)
            }
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        var text = InterfaceCopy.titles(items.count)
        if library.listing.skipped > 0 { text += " · \(library.listing.skipped) skipped" }
        if library.listing.truncated { text += " · Limit reached" }
        return text
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { library.back() } label: {
                    Label {
                        Text("Back to \(library.section.rawValue)")
                    } icon: {
                        Image(systemName: "chevron.left").accessibilityHidden(true)
                    }
                }
                    .buttonStyle(.plain)
                    .help("Back to \(library.section.rawValue)")
                    .accessibilityLabel("Back to \(library.section.rawValue)")
                Spacer()
                if !library.detailLoading {
                    Button { library.loadDetails() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh details").accessibilityLabel("Refresh details")
                }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let item = library.selected {
                        Text(item.name).font(.headline).textSelection(.enabled)
                        if library.section != .series {
                            Button(library.section == .live ? "Load channel" : "Load film", systemImage: "play.fill") { play(item) }
                        }
                        if library.detailLoading {
                            HStack { ProgressView().controlSize(.small); Text(library.section == .live ? "Loading guide…" : "Loading details…") }
                        }
                        if let error = library.detailError { recovery(error) { library.loadDetails() } }
                        if library.section == .live { guide }
                        else if let info = library.details {
                            metadata(info)
                            if library.section == .series { episodes(info, series: item) }
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var guide: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
        let programmes = library.guide.filter { $0.end > context.date }
        LazyVStack(alignment: .leading, spacing: 10) {
            if !library.detailLoading && library.detailError == nil && programmes.isEmpty { Text("No programme guide available").foregroundStyle(.secondary) }
            ForEach(programmes) { programme in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(programme.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                        Text("–")
                        Text(programme.end, style: .time)
                    }.font(.caption).foregroundStyle(.secondary)
                    Text(programme.title).font(.callout.weight(programme.start <= context.date ? .semibold : .regular))
                    if let summary = programme.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
            }
        }.textSelection(.enabled)
        }
    }

    private func metadata(_ info: XtreamDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([info.year, info.genre, info.duration, info.rating.map { "Rating \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let summary = info.summary { Text(summary).font(.callout) }
            if let director = info.director { Text("Director: \(director)").font(.caption).foregroundStyle(.secondary) }
            if let cast = info.cast { Text("Cast: \(cast)").font(.caption).foregroundStyle(.secondary) }
        }.textSelection(.enabled)
    }

    private func episodes(_ info: XtreamDetails, series: XtreamItem) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            let seasons = Array(Set(info.episodes.map(\.season))).sorted()
            if info.episodes.isEmpty { Text("No episodes available").foregroundStyle(.secondary) }
            else {
                Picker("Season", selection: $season) {
                    Text("All seasons").tag(Optional<Int>.none)
                    ForEach(seasons, id: \.self) { Text("Season \($0)").tag(Optional($0)) }
                }
                if info.skippedEpisodes > 0 { Text(InterfaceCopy.episodesNotImported(info.skippedEpisodes)).font(.caption).foregroundStyle(.secondary) }
                ForEach(info.episodes.filter { season == nil || $0.season == season }) { episode in
                    Button {
                        do {
                            try controller.selectXtreamMedia(library.episodeURL(episode), title: "\(series.name) · \(episode.title)")
                            library.didPlay(episode.id)
                        } catch { controller.displayError(error) }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(episode.season).\(episode.number) · \(episode.title)").lineLimit(2)
                                if let duration = episode.duration { Text(duration).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: library.isPlaying(episode.id) ? "checkmark" : "play.fill")
                                .font(.caption)
                                .accessibilityHidden(true)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 4)
                    }.buttonStyle(.plain).help("Load \(episode.title)")
                        .accessibilityValue(library.isPlaying(episode.id) ? "Now playing" : "")
                }
            }
        }
    }

    private var accountDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Xtream account").font(.headline)
            Text(library.client.account.server.host ?? "Server").font(.callout)
            Text("Status: \(library.accountInfo.status)")
            if let expires = library.accountInfo.expires { Text("Expires: \(expires.formatted(date: .abbreviated, time: .omitted))") }
            if let max = library.accountInfo.maximumConnections {
                Text("Connections: \(library.accountInfo.activeConnections ?? 0) of \(max)")
            }
            Text("Connection counts are from the last sign-in.").font(.caption).foregroundStyle(.secondary)
        }.font(.callout).padding(16)
    }

    private func recovery(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle").font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: retry)
        }.padding(12)
    }
    private func play(_ item: XtreamItem) {
        do {
            try controller.selectXtreamMedia(library.playbackURL(item), title: item.name, isLive: library.section == .live)
            library.didPlay(item.id)
        } catch { controller.displayError(error) }
    }
}

private struct XtreamTitleList: View, Equatable {
    let revision: Int
    let items: [XtreamItem]
    let categoryNames: [String: String]
    let playingID: String?
    let section: XtreamSection
    let resignSearch: () -> Void
    let play: (XtreamItem) -> Void
    let select: (XtreamItem) -> Void

    nonisolated static func == (lhs: XtreamTitleList, rhs: XtreamTitleList) -> Bool {
        lhs.revision == rhs.revision && lhs.playingID == rhs.playingID && lhs.section == rhs.section
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: 0) {
                    Button {
                        resignSearch()
                        if section == .live { play(item) } else { select(item) }
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(2)
                                if let categoryID = item.categoryID, let category = categoryNames[categoryID] {
                                    Text(category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: playingID == XtreamLibrary.playingKey(section, item.id) ? "checkmark" : section == .live ? "play.fill" : "chevron.right")
                                .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(section == .live ? "Load \(item.name)" : "Show details for \(item.name)")
                    if section == .live {
                        Button { resignSearch(); select(item) } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.plain).padding(.trailing, 8).help("Programme guide for \(item.name)")
                            .accessibilityLabel("Programme guide for \(item.name)")
                    }
                }
            }
        }.scrollTargetLayout()
    }
}