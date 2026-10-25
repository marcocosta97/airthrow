import AppKit
import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

private struct PrototypeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Proposal scaffold for a resizable AirThrow window. Data here is invented.
struct PrototypeRoot: View {
    @ObservedObject var model: PrototypeModel
    @ViewState private var width: CGFloat = PrototypeLaunch.scene.contentSize.width
    @FocusState private var searchFocused: Bool

    private var sizeClass: PrototypeSizeClass { PrototypeSizeClass(width: width) }
    private var showsDetail: Bool {
        switch model.section {
        case .live, .favourites, .films, .series, .history: true
        case .queue, .nowPlaying: false
        }
    }

    private var columns: (sidebar: Bool, list: Bool, detail: Bool) {
        let detail = sizeClass == .expanded && showsDetail
        if sizeClass == .compact {
            if model.sidebarVisible { return (true, false, false) }
            return (false, true, false)
        }
        return (model.sidebarVisible, true, detail)
    }

    var body: some View {
        let plan = columns
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 0) {
                    if plan.sidebar {
                        PrototypeSidebar(model: model)
                            .frame(width: plan.list || plan.detail ? PrototypeMetrics.sidebarWidth : nil)
                            .frame(maxWidth: plan.list || plan.detail ? nil : .infinity, maxHeight: .infinity)
                        if plan.list || plan.detail { Divider() }
                    }
                    if plan.list {
                        PrototypeListColumn(model: model, showsDetail: plan.detail, searchFocused: $searchFocused)
                            .frame(minWidth: plan.detail ? PrototypeMetrics.listWidth : 280,
                                   idealWidth: PrototypeMetrics.listWidth,
                                   maxWidth: plan.detail ? PrototypeMetrics.listWidth : .infinity,
                                   maxHeight: .infinity)
                        if plan.detail { Divider() }
                    }
                    if plan.detail {
                        PrototypeDetailColumn(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                if model.dropTargeted { dropOverlay }
            }
            Divider()
            PlayerBar(model: model, wide: sizeClass != .compact)
        }
        .frame(minWidth: PrototypeMetrics.minWidth, minHeight: PrototypeMetrics.minHeight)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: PrototypeWidthKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(PrototypeWidthKey.self) { if $0 > 1 { width = $0 } }
        .onChange(of: model.searchFocus) { _, _ in
            if sizeClass == .compact { model.sidebarVisible = false }
            searchFocused = true
        }
        .onChange(of: model.section) { _, _ in
            if sizeClass == .compact { model.sidebarVisible = false }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                    .help(model.sidebarVisible ? "Hide sidebar" : "Show sidebar")
                    .accessibilityLabel(model.sidebarVisible ? "Hide sidebar" : "Show sidebar")
            }
            if sizeClass != .compact {
                ToolbarItem(placement: .principal) {
                    Text(model.receiverName)
                        .font(.headline)
                        .foregroundStyle(model.receiverConnected ? Color.accentColor : Color.secondary)
                        .accessibilityLabel("AirPlay receiver")
                        .accessibilityValue(model.receiverName)
                        .help(model.receiverConnected ? "AirPlay connected — change receiver" : "No AirPlay receiver")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button { model.showOpen = true } label: { Image(systemName: "plus") }
                        .help("Open a video, website, or playlist (⌘L)")
                        .accessibilityLabel("Open video")
                    Image(systemName: "airplay.video")
                        .foregroundStyle(model.receiverConnected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                        .help(model.receiverConnected ? "AirPlay connected — change receiver" : "No AirPlay receiver")
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                        .help("Settings")
                        .accessibilityLabel("Settings")
                }
            }
        }
        .sheet(isPresented: $model.showOpen) {
            OpenSheet(model: model)
        }
        .sheet(isPresented: $model.showSettings) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings").font(.title2)
                Text("Playback, media preparation, and cookies stay in the grouped Settings form. This prototype does not open that form, so it cannot read account or cookie state.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done") { model.showSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.acceptDrop(urls)
        } isTargeted: { model.dropTargeted = $0 }
    }

    private var dropOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            Text(model.playback == .idle ? "Drop to load" : "Drop to add to the queue")
                .font(.headline)
            Text(model.playback == .idle
                 ? "One video replaces playback. Several files start a queue."
                 : "The video on the TV keeps playing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(8)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PrototypeSidebar: View {
    @ObservedObject var model: PrototypeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group {
                row(.queue, badge: model.queueCount > 0 ? "\(model.queueCount)" : nil)
            }
            group {
                row(.favourites, badge: model.favouriteCount > 0 ? "\(model.favouriteCount)" : nil)
                row(.live)
                row(.films)
                row(.series)
            }
            group { row(.history) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
    }

    private func group(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2, content: content)
    }

    private func row(_ section: PrototypeSection, badge: String? = nil) -> some View {
        let selected = model.section == section
        return Button { model.section = section } label: {
            HStack(spacing: 6) {
                Label(section.title, systemImage: section.symbol)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PrototypeListColumn: View {
    @ObservedObject var model: PrototypeModel
    var showsDetail: Bool
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            switch model.section {
            case .queue: queueColumn
            case .favourites, .live: channelColumn
            case .films, .series: catalogColumn
            case .history: historyColumn
            case .nowPlaying: EmptyView()
            }
        }
    }

    private var queueColumn: some View {
        if model.libraryEmpty {
            return AnyView(emptyQueue)
        }
        return AnyView(queueList)
    }

    private var emptyQueue: some View {
        ContentUnavailableView {
            Label("Nothing queued", systemImage: "list.bullet")
        } description: {
            Text("Open a video, or drop files here. One file replaces playback. Several files start a queue.")
        } actions: {
            Button("Open Video…") { model.showOpen = true }
                .accessibilityLabel("Open video")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Queue").font(.headline)
                Text("Click a row to play it. Dropped files join the queue. Open still replaces playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            List {
                ForEach(model.pageItems) { item in
                    Button { model.playQueueItem(item.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(item.id + 1)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                            Text(item.title).lineLimit(2)
                            Spacer(minLength: 0)
                            if item.isCurrent {
                                Image(systemName: "play.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(item.title)")
                    .accessibilityValue(item.isCurrent ? "Now playing" : "Not yet played")
                    .accessibilityHint("Plays this queue item on the TV")
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button { model.turnPage(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.queuePage == 0)
                    .accessibilityLabel("Previous page")
                Spacer()
                Text(model.pageLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { model.turnPage(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.queuePage + 1 >= model.pageCount)
                    .accessibilityLabel("Next page")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var channelColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.section == .favourites ? "Favourites" : "Live").font(.headline)
                HStack(spacing: 8) {
                    TextField("Find a channel", text: $model.channelQuery)
                        .textFieldStyle(.roundedBorder)
                        .focused(searchFocused)
                        .accessibilityLabel("Find a channel")
                    Button { model.stepChannel(-1) } label: { Image(systemName: "chevron.up") }
                        .help("Previous channel (⌥↑)")
                        .accessibilityLabel("Previous channel")
                    Button { model.stepChannel(1) } label: { Image(systemName: "chevron.down") }
                        .help("Next channel (⌥↓)")
                        .accessibilityLabel("Next channel")
                }
            }
            .padding(16)
            if model.visibleChannels.isEmpty {
                ContentUnavailableView {
                    Label("No matching channels", systemImage: "tv.slash")
                } description: {
                    Text("Try another name, or clear the search.")
                } actions: {
                    Button("Clear Search") { model.channelQuery = "" }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selectedChannelID) {
                        ForEach(model.visibleChannels) { channel in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(channel.name).lineLimit(1)
                                    Text(channel.category).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Button { model.toggleFavourite(channel.id) } label: {
                                    Image(systemName: channel.isFavourite ? "star.fill" : "star")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(channel.isFavourite ? "Remove \(channel.name) from Favourites" : "Add \(channel.name) to Favourites")
                            }
                            .tag(channel.id)
                            .id(channel.id)
                        }
                    }
                    .listStyle(.inset)
                    .onAppear { proxy.scrollTo(model.selectedChannelID, anchor: .center) }
                    .onChange(of: model.selectedChannelID) { _, id in
                        guard let id else { return }
                        model.selectChannel(id)
                        proxy.scrollTo(id, anchor: .center)
                    }
                    .task(id: model.selectedChannelID) {
                        try? await Task.sleep(for: .milliseconds(200))
                        proxy.scrollTo(model.selectedChannelID, anchor: .center)
                    }
                }
            }
        }
    }

    private var catalogColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Demo TV").font(.headline)
                HStack(spacing: 6) {
                    Text("Updated 2 minutes ago")
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing catalog")
                    Text("Refreshing")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("2 of 4 connections in use")
                    .font(.callout)
                Text("A free connection is required before this catalog can play. The saved catalog is already open while it refreshes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Demo TV asked AirThrow to open a different site (example.com). That redirect was blocked, so nothing was sent to the TV. The HTTP status was 302. The status alone does not say the redirect was refused.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                TextField("Find a title", text: $model.catalogQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused(searchFocused)
                    .accessibilityLabel("Find a title")
            }
            .padding(16)
            if model.visibleTitles.isEmpty {
                ContentUnavailableView {
                    Label("No matching titles", systemImage: "film")
                } description: {
                    Text("Try another name, or clear the search.")
                } actions: {
                    Button("Clear Search") { model.catalogQuery = "" }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedTitleID) {
                    ForEach(model.visibleTitles) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(2)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(item.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var historyColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History").font(.headline).padding(16)
            if model.history.isEmpty {
                ContentUnavailableView {
                    Label("No recent sources", systemImage: "clock")
                } description: {
                    Text("Load a video or playlist. It will appear here for next time.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedHistoryID) {
                    ForEach(model.history) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(2)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let stopped = item.stoppedAt {
                                    Text("Stopped at \(stopped)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if !showsDetail, let stopped = item.stoppedAt {
                                Button("Resume") { model.resume(item) }
                                    .controlSize(.small)
                                    .accessibilityLabel("Resume \(item.title) at \(stopped)")
                            }
                        }
                        .tag(item.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct PrototypeDetailColumn: View {
    @ObservedObject var model: PrototypeModel

    var body: some View {
        switch model.section {
        case .live, .favourites: guide
        case .films, .series: titleDetail
        case .history: historyDetail
        case .queue: queueDetail
        case .nowPlaying: EmptyView()
        }
    }

    private var guide: some View {
        ScrollView {
            if let channel = model.selectedChannel {
                let programmes = model.programmes(for: channel)
                VStack(alignment: .leading, spacing: 8) {
                    Text(channel.name).font(.title2)
                    Text("Channel id \(channel.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Stable channel id \(channel.id)")
                    if channel.isFavourite {
                        Label("Favourite", systemImage: "star.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let current = programmes.first(where: \.isCurrent) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(current.title).font(.title3)
                            Spacer(minLength: 8)
                            Text(current.clock).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                        if let progress = current.progress {
                            ProgressView(value: progress)
                                .accessibilityLabel("Programme progress")
                                .accessibilityValue(current.remaining ?? "")
                        }
                        if let remaining = current.remaining {
                            Text(remaining).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(["Today", "Tomorrow"], id: \.self) { day in
                        Text(day).font(.headline).padding(.top, 16)
                        ForEach(programmes.filter { $0.day == day }) { programme in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(programme.clock)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                Text(programme.title)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = model.selectedTitle {
                Text(item.name).font(.title2)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                Button("Play") { model.playTitle(item) }
                    .help("Play this title. Connections were checked above.")
                    .accessibilityHint("Connections were checked before playback")
            } else {
                ContentUnavailableView {
                    Label("No title selected", systemImage: "film")
                } description: {
                    Text("Choose a film or episode.")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var historyDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = model.selectedHistory {
                Text(item.title).font(.title2)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                if let stopped = item.stoppedAt {
                    Text("Stopped at \(stopped)").font(.callout.monospacedDigit())
                    HStack(spacing: 8) {
                        Button("Resume") { model.resume(item) }
                            .accessibilityLabel("Resume at \(stopped)")
                            .help("Continue from the last position sent to the TV")
                        Button("Play from Start") { model.playFromStart(item) }
                            .help("Start again from the beginning")
                    }
                } else {
                    Button("Play") { model.playFromStart(item) }
                    Text("This entry has no saved position.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var queueDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.title).font(.title2)
            Text("Click a row to play that item. Play Next inserts a video after the current one. Add to Queue puts it at the end. Opening a file still replaces playback.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct OpenSheet: View {
    @ObservedObject var model: PrototypeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open").font(.title2)
            HStack(spacing: 8) {
                TextField("Video or playlist URL", text: $model.source)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.acceptsQueueActions ? model.playNow() : model.loadSource() }
                    .accessibilityLabel("Video source")
                    .accessibilityHint("Enter a URL or local file path. You can also drop video files on the window.")
                Button(action: model.chooseFile) { Image(systemName: "folder") }
                    .help("Choose a video or playlist file. Choosing a file replaces playback.")
                    .accessibilityLabel("Choose video or playlist file")
            }
            HStack(spacing: 8) {
                if model.acceptsQueueActions {
                    Button("Play Now", action: model.playNow)
                        .disabled(model.sourceTrimmed.isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .help("Replace playback with this video")
                    Button("Play Next", action: model.playNext)
                        .disabled(model.sourceTrimmed.isEmpty)
                        .help("Play this video after the current one")
                    Button("Add to Queue", action: model.addToQueue)
                        .disabled(model.sourceTrimmed.isEmpty)
                        .help("Add this video to the end of the queue")
                } else {
                    Button("Load", action: model.loadSource)
                        .disabled(model.sourceTrimmed.isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .help("Load this source without starting playback")
                }
                Spacer()
                Button("Cancel") { model.showOpen = false }
                    .keyboardShortcut(.cancelAction)
            }
            Text(model.sourceCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct PlayerBar: View {
    @ObservedObject var model: PrototypeModel
    var wide: Bool

    var body: some View {
        Group {
            if model.playback == .idle && model.notice == nil {
                idleLine
            } else if wide {
                wideBody
            } else {
                compactBody
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.playback != .idle {
                titleStack(limit: 3)
                if model.showAudioWarning { audioWarning }
                if model.liveShift {
                    TimeShiftSlider(model: model)
                } else if model.duration > 0 {
                    finiteTimeline
                }
                transport(centered: true)
            }
            noticeBlock
        }
    }

    private var wideBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.showAudioWarning { audioWarning }
            noticeBlock
            if model.playback != .idle {
                HStack(alignment: .center, spacing: 20) {
                    titleStack(limit: 2)
                        .frame(minWidth: 140, idealWidth: 220, maxWidth: 280, alignment: .leading)
                    Group {
                        if model.liveShift {
                            TimeShiftSlider(model: model)
                        } else if model.duration > 0 {
                            inlineTimeline
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                    transport(centered: false)
                }
            }
        }
    }

    private func titleStack(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(limit)
                .textSelection(.enabled)
                .help(model.title)
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var audioWarning: some View {
        Label("No audio track detected. Try a link that includes audio.", systemImage: "speaker.slash")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("No audio track detected. Try a link that includes audio.")
    }

    private var inlineTimeline: some View {
        HStack(spacing: 8) {
            Text(prototypeTime(model.position))
                .frame(width: 44, alignment: .trailing)
            Slider(value: $model.position, in: 0...max(model.duration, 1))
                .disabled(model.duration <= 0 || model.playback == .failed)
                .accessibilityLabel("Playback position")
                .accessibilityValue(prototypeTime(model.position))
            Text(prototypeTime(model.duration))
                .frame(width: 44, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var idleLine: some View {
        HStack(spacing: 8) {
            Label(model.receiverName, systemImage: "airplay.video")
                .foregroundStyle(model.receiverConnected ? Color.accentColor : Color.secondary)
                .accessibilityLabel("AirPlay receiver")
                .accessibilityValue(model.receiverName)
                .help(model.receiverConnected ? "AirPlay connected — change receiver" : "No AirPlay receiver")
            Spacer(minLength: 8)
            if !model.libraryEmpty {
                Text("Nothing playing")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var finiteTimeline: some View {
        VStack(spacing: 4) {
            Slider(value: $model.position, in: 0...max(model.duration, 1))
                .disabled(model.duration <= 0 || model.playback == .failed)
                .accessibilityLabel("Playback position")
                .accessibilityValue(prototypeTime(model.position))
            HStack {
                Text(prototypeTime(model.position))
                Spacer()
                Text(prototypeTime(model.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func transport(centered: Bool) -> some View {
        HStack(spacing: 12) {
            if model.currentQueueIndex != nil {
                transportIcon("backward.end.fill", label: "Previous playlist item", help: "Previous playlist item") { model.skipQueue(-1) }
                    .disabled((model.currentQueueIndex ?? 0) == 0)
            }
            transportIcon("gobackward.10", label: "Back 10 seconds", help: "Back 10 seconds (←)") { model.skip(-10) }
                .disabled(model.duration <= 0 || model.liveShift)
            playButton(labeled: centered)
            transportIcon("stop.fill", label: "Stop and unload video", help: "Stop and unload video", action: model.stop)
            transportIcon("goforward.10", label: "Forward 10 seconds", help: "Forward 10 seconds (→)") { model.skip(10) }
                .disabled(model.duration <= 0 || model.liveShift)
            if model.currentQueueIndex != nil {
                transportIcon("forward.end.fill", label: "Next playlist item", help: "Next playlist item") { model.skipQueue(1) }
                    .disabled((model.currentQueueIndex ?? 0) + 1 >= PrototypeModel.queueTotal)
            }
        }
        .controlSize(centered ? .regular : .small)
        .fixedSize(horizontal: !centered, vertical: false)
        .frame(maxWidth: centered ? .infinity : nil)
    }

    private func transportIcon(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.bordered)
            .help(help)
            .accessibilityLabel(label)
    }

    private func playButton(labeled: Bool) -> some View {
        Button(action: model.togglePlayback) {
            if labeled {
                Label(model.playback == .playing ? "Pause" : "Play", systemImage: model.playback == .playing ? "pause.fill" : "play.fill")
                    .frame(minWidth: 48)
            } else {
                Image(systemName: model.playback == .playing ? "pause.fill" : "play.fill")
            }
        }
        .buttonStyle(.bordered)
        .disabled(model.playback != .playing && model.playback != .paused)
        .accessibilityLabel(model.playback == .playing ? "Pause" : "Play")
        .help(model.playback == .playing ? "Pause (Space)" : "Play (Space)")
    }

    @ViewBuilder private var noticeBlock: some View {
        if let notice = model.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.noticeIsError ? "exclamationmark.triangle" : "info.circle")
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.noticeIsError {
                        Button("Settings…") { model.showSettings = true }
                            .controlSize(.small)
                    }
                }
                Button { model.notice = nil; model.noticeIsError = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Dismiss message")
                    .accessibilityLabel("Dismiss message")
            }
            .foregroundStyle(model.noticeIsError ? Color.primary : Color.secondary)
        }
    }
}

private struct TimeShiftSlider: View {
    @ObservedObject var model: PrototypeModel

    var body: some View {
        TimelineView(.periodic(from: model.shiftOrigin, by: 1)) { context in
            let drift = max(0, Int(context.date.timeIntervalSince(model.shiftOrigin)))
            let end = model.shiftHeldEnd ?? (PrototypeModel.shiftBaseEnd + drift)
            let start = model.shiftHeldStart ?? (end - PrototypeModel.shiftSpan)
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $model.shiftValue, in: Double(start)...Double(max(start + 1, end))) { editing in
                    if editing {
                        model.beginShiftScrub(start: start, end: end)
                    } else {
                        model.endShiftScrub(end: end)
                    }
                }
                .accessibilityLabel("Live time shift")
                .accessibilityValue(model.shiftScrubbing ? "Bounds held" : "\(model.shiftBehind / 60) minutes behind live")
                HStack {
                    Text(prototypeClock(start))
                    Spacer()
                    if model.shiftBehind > 0 {
                        Button("Go Live") { model.goLive() }
                            .buttonStyle(.link)
                            .disabled(model.playback != .playing && model.playback != .paused)
                    } else {
                        Text("Live")
                    }
                    Spacer()
                    Text(prototypeClock(end))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Text(model.shiftScrubbing ? "Bounds held while dragging" : "Dragging keeps these ends fixed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
final class PrototypeWindow: PlaybackKeyboardWindow {
    var model: PrototypeModel?

    override func sendEvent(_ event: NSEvent) {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.type == .keyDown, event.windowNumber == windowNumber, attachedSheet == nil {
            let flags = event.modifierFlags.intersection(modifiers)
            if flags == .command, event.keyCode == 3 {
                model?.focusSearch()
                return
            }
            if flags == .option, (event.keyCode == 126 || event.keyCode == 125), !Self.textFocused(firstResponder) {
                if model?.stepChannel(event.keyCode == 126 ? -1 : 1) == true { return }
            }
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        if model?.dismissTransient() == true { return }
        super.cancelOperation(sender)
    }

    fileprivate static func textFocused(_ responder: NSResponder?) -> Bool {
        var current = responder
        while let view = current as? NSView {
            if view is NSText || view is NSTextField { return true }
            current = view.superview
        }
        return false
    }
}

@MainActor
enum PrototypeChrome {
    static func makeWindow(model: PrototypeModel) -> PrototypeWindow? {
        guard let screen = NSScreen.screens.first(where: {
            $0.localizedName.range(of: "codex", options: .caseInsensitive) != nil
        }) else {
            fputs("AirThrow UI prototype requires the Codex display.\n", stderr)
            return nil
        }
        let visible = screen.visibleFrame
        let wanted = PrototypeLaunch.scene.contentSize
        let contentRect = NSRect(
            x: visible.minX,
            y: visible.minY,
            width: min(wanted.width, visible.width),
            height: min(wanted.height, visible.height))
        let window = PrototypeWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.model = model
        window.title = "AirThrow"
        window.appearance = NSAppearance(named: PrototypeLaunch.prefersDark ? .darkAqua : .aqua)
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .managed, .participatesInCycle, .fullScreenPrimary, .fullScreenAllowsTiling]
        window.contentMinSize = NSSize(width: PrototypeMetrics.minWidth, height: PrototypeMetrics.minHeight)
        window.contentMaxSize = NSSize(width: 12_000, height: 12_000)
        window.minFullScreenContentSize = window.contentMinSize
        let host = NSHostingController(rootView: PrototypeRoot(model: model)
            .environment(\.colorScheme, PrototypeLaunch.prefersDark ? .dark : .light))
        host.sizingOptions = []
        window.contentViewController = host
        var frame = window.frameRect(forContentRect: contentRect)
        frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentRect.size)).size
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        window.setFrame(frame, display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if PrototypeLaunch.snapshotURL != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                Self.writeSnapshot(of: window)
                exit(EXIT_SUCCESS)
            }
        }
        return window
    }

    private static func writeSnapshot(of window: NSWindow) {
        guard let url = PrototypeLaunch.snapshotURL else { return }
        let view = window.contentView?.superview ?? window.contentView
        guard let view else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

private extension PrototypeModel {
    func skipQueue(_ delta: Int) {
        guard let current = currentQueueIndex else { return }
        let next = min(PrototypeModel.queueTotal - 1, max(0, current + delta))
        guard next != current else { return }
        queuePage = next / PrototypeModel.pageSize
        playQueueItem(next)
    }
}
