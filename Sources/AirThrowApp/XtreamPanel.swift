import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import AirThrowCore
#endif

struct XtreamPanel: View {
    @ObservedObject var library: XtreamLibrary
    @ObservedObject var controller: PlaybackController
    @SwiftUI.State private var season: Int?
    @SwiftUI.State private var accountVisible = false
    @FocusState private var searchFocused: Bool

    private var items: [XtreamItem] {
        let terms = library.search.split(whereSeparator: \.isWhitespace)
        return library.listing.items.filter { item in terms.allSatisfy { item.name.localizedStandardContains($0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(title: "Xtream", back: {
                library.cancelLoading(); library.back(); controller.inspectorPage = .history
            })
            if library.selected != nil {
                details
            } else {
                catalog
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
                XtreamCategoryField(selection: Binding(get: { library.categoryID }, set: { library.browse(library.section, categoryID: $0) }), categories: library.categories)
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
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            HStack(spacing: 0) {
                            Button {
                                searchFocused = false
                                if library.section == .live { play(item) } else { library.select(item) }
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).lineLimit(2)
                                        if let category = library.categories.first(where: { $0.id == item.categoryID }) {
                                            Text(category.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: library.isPlaying(item.id) ? "checkmark" : library.section == .live ? "play.fill" : "chevron.right")
                                        .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(library.section == .live ? "Load \(item.name)" : "Show details for \(item.name)")
                            if library.section == .live {
                                Button { searchFocused = false; library.select(item) } label: { Image(systemName: "info.circle") }
                                    .buttonStyle(.plain).padding(.trailing, 8).help("Programme guide for \(item.name)")
                                    .accessibilityLabel("Programme guide for \(item.name)")
                            }
                            }
                        }
                    }.scrollTargetLayout()
                }
                .scrollPosition(id: Binding(get: { library.scrollID }, set: { library.updateScroll($0, for: key) }), anchor: .top)
                .id(key)
            }
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        var text = "\(items.count) titles"
        if library.listing.skipped > 0 { text += " · \(library.listing.skipped) skipped" }
        if library.listing.truncated { text += " · Limit reached" }
        return text
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { library.back() } label: { Label(library.section.rawValue, systemImage: "chevron.left") }
                    .buttonStyle(.plain).help("Back to catalog")
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
                if info.skippedEpisodes > 0 { Text("\(info.skippedEpisodes) episodes not imported").font(.caption).foregroundStyle(.secondary) }
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
                            Image(systemName: library.isPlaying(episode.id) ? "checkmark" : "play.fill").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 4)
                    }.buttonStyle(.plain).help("Load \(episode.title)")
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

private struct XtreamCategoryField: NSViewRepresentable {
    @Binding var selection: String?
    let categories: [XtreamCategory]
    private var values: [String?] { [nil] + categories.map { Optional($0.id) } }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setAccessibilityLabel("Category")
        button.target = context.coordinator; button.action = #selector(Coordinator.select(_:))
        button.cell?.lineBreakMode = .byTruncatingTail
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = ["All categories"] + categories.map(\.name)
        if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
        button.selectItem(at: values.firstIndex(of: selection) ?? 0)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        // Menu contents must not determine the inspector's width.
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: XtreamCategoryField
        init(_ parent: XtreamCategoryField) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            guard parent.values.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.values[sender.indexOfSelectedItem]
        }
    }
}
