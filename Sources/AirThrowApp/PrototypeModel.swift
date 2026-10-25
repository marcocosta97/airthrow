import AppKit
import Foundation

/// Launch switches for the resizable-UI prototype. Absent in a normal launch.
@MainActor
enum PrototypeLaunch {
    static var isActive: Bool {
        CommandLine.arguments.contains("--ui-prototype")
    }

    static var scene: PrototypeScene {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--ui-prototype"), index + 1 < args.count,
           let scene = PrototypeScene(rawValue: args[index + 1]) {
            return scene
        }
        if let raw = ProcessInfo.processInfo.environment["AIRTHROW_UI_SCENE"], let scene = PrototypeScene(rawValue: raw) {
            return scene
        }
        return .idle
    }

    static var prefersDark: Bool {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--ui-prototype"), index + 2 < args.count {
            return args[index + 2] == "dark"
        }
        return ProcessInfo.processInfo.environment["AIRTHROW_UI_APPEARANCE"] == "dark"
    }

    static var snapshotURL: URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }

    /// Empty suite. The prototype does not read the app's UserDefaults domain.
    static func makePreferences() -> UserDefaults {
        UserDefaults(suiteName: "app.airthrow.ui-prototype") ?? UserDefaults()
    }
}

enum PrototypeScene: String {
    case idle, playing, queue, library, xtream, history, error

    var contentSize: NSSize {
        switch self {
        case .idle, .playing: NSSize(width: PrototypeMetrics.minWidth, height: PrototypeMetrics.minHeight)
        case .error: NSSize(width: PrototypeMetrics.minWidth, height: 560)
        case .queue: NSSize(width: 860, height: 640)
        case .library: NSSize(width: 1440, height: 880)
        case .xtream: NSSize(width: 1180, height: 780)
        case .history: NSSize(width: 1120, height: 700)
        }
    }

    var opensSidebar: Bool {
        switch self {
        case .idle, .playing, .error: false
        case .queue, .library, .xtream, .history: true
        }
    }
}

enum PrototypeMetrics {
    static let minWidth: CGFloat = 440
    static let minHeight: CGFloat = 390
    static let regularWidth: CGFloat = 720
    static let expandedWidth: CGFloat = 1100
    static let sidebarWidth: CGFloat = 212
    static let listWidth: CGFloat = 360
}

enum PrototypeSizeClass {
    case compact, regular, expanded

    init(width: CGFloat) {
        if width < PrototypeMetrics.regularWidth { self = .compact }
        else if width < PrototypeMetrics.expandedWidth { self = .regular }
        else { self = .expanded }
    }
}

enum PrototypeSection: String, CaseIterable, Hashable, Identifiable {
    case nowPlaying, queue, favourites, live, films, series, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .queue: "Queue"
        case .favourites: "Favourites"
        case .live: "Live"
        case .films: "Films"
        case .series: "Series"
        case .history: "History"
        }
    }
    var symbol: String {
        switch self {
        case .nowPlaying: "play.rectangle"
        case .queue: "list.bullet"
        case .favourites: "star"
        case .live: "tv"
        case .films: "film"
        case .series: "rectangle.stack"
        case .history: "clock"
        }
    }
}

enum PrototypePlayback {
    case idle, playing, paused, failed
    var label: String {
        switch self {
        case .idle: "No video loaded"
        case .playing: "Playing"
        case .paused: "Paused"
        case .failed: "Failed"
        }
    }
}

struct PrototypeChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    var isFavourite: Bool
}

struct PrototypeProgramme: Identifiable, Hashable {
    let id: String
    let title: String
    let clock: String
    let day: String
    let isCurrent: Bool
    let progress: Double?
    let remaining: String?
}

struct PrototypeQueueItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let isCurrent: Bool
}

struct PrototypeTitleItem: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
}

struct PrototypeHistoryItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let stoppedAt: String?
    let resumeSeconds: Double?
    let duration: Double
}

@MainActor
final class PrototypeModel: ObservableObject {
    static let queueTotal = 248
    static let pageSize = 100
    static let shiftSpan = 2 * 60 * 60
    static let shiftBaseEnd = 18 * 60 * 60 + 2 * 60

    @Published var section: PrototypeSection = .queue
    @Published var libraryEmpty = false
    @Published var showOpen = false
    @Published var sidebarVisible: Bool
    @Published var source = ""
    @Published var playback: PrototypePlayback = .idle
    @Published var title = "No video loaded"
    @Published var detail = ""
    @Published var showAudioWarning = false
    @Published var notice: String?
    @Published var noticeIsError = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var liveShift = false
    @Published var receiverName = "No receiver"
    @Published var receiverConnected = false
    @Published var showSettings = false
    @Published var dropTargeted = false
    @Published var searchFocus = 0
    @Published var queuePage = 0
    @Published var currentQueueIndex: Int?
    @Published var channels: [PrototypeChannel]
    @Published var channelQuery = ""
    @Published var catalogQuery = ""
    @Published var selectedChannelID: String?
    @Published var selectedHistoryID: String?
    @Published var selectedTitleID: String?
    @Published var shiftOrigin = Date()
    @Published var shiftBehind = 12 * 60
    @Published var shiftValue = Double(18 * 60 * 60 + 2 * 60 - 12 * 60)
    @Published var shiftScrubbing = false
    @Published var shiftHeldStart: Int?
    @Published var shiftHeldEnd: Int?

    let films: [PrototypeTitleItem] = [
        PrototypeTitleItem(id: "harbour", name: "Harbour Lights", detail: "2024 · Film"),
        PrototypeTitleItem(id: "paper", name: "The Paper Route", detail: "2022 · Film"),
        PrototypeTitleItem(id: "salt", name: "Salt and Timber", detail: "2019 · Film"),
        PrototypeTitleItem(id: "platform", name: "North Platform", detail: "2025 · Film"),
        PrototypeTitleItem(id: "glass", name: "Glasshouse Week", detail: "2021 · Film"),
        PrototypeTitleItem(id: "crossing", name: "The Long Crossing", detail: "2018 · Film"),
        PrototypeTitleItem(id: "lantern", name: "Red Lantern", detail: "2020 · Film"),
        PrototypeTitleItem(id: "pier", name: "West Pier", detail: "2023 · Film")
    ]
    let series: [PrototypeTitleItem] = [
        PrototypeTitleItem(id: "ferry", name: "The Night Ferry", detail: "Series · 6 episodes"),
        PrototypeTitleItem(id: "street", name: "Quiet Street", detail: "Series · 8 episodes"),
        PrototypeTitleItem(id: "boats", name: "Paper Boats", detail: "Series · 4 episodes"),
        PrototypeTitleItem(id: "weather-desk", name: "Weather Desk", detail: "Series · 10 episodes"),
        PrototypeTitleItem(id: "low-water", name: "Low Water", detail: "Series · 5 episodes"),
        PrototypeTitleItem(id: "morning", name: "Morning Report", detail: "Series · 12 episodes")
    ]
    let history: [PrototypeHistoryItem] = [
        PrototypeHistoryItem(id: "ferry", title: "The Night Ferry — Episode 4", detail: "Video · example.com", symbol: "play.rectangle", stoppedAt: "12:40", resumeSeconds: 760, duration: 2650),
        PrototypeHistoryItem(id: "harbour", title: "Harbour Lights", detail: "Video · local file", symbol: "play.rectangle", stoppedAt: "3:05", resumeSeconds: 185, duration: 1680),
        PrototypeHistoryItem(id: "mix", title: "Summer Mix", detail: "Playlist · 18 videos", symbol: "list.bullet", stoppedAt: nil, resumeSeconds: nil, duration: 0),
        PrototypeHistoryItem(id: "demo", title: "Demo TV", detail: "Channel playlist", symbol: "tv", stoppedAt: nil, resumeSeconds: nil, duration: 0)
    ]

    init(scene: PrototypeScene) {
        channels = Self.makeChannels()
        sidebarVisible = scene.opensSidebar
        selectedChannelID = "demo.harbour"
        selectedHistoryID = "ferry"
        selectedTitleID = "harbour"
        switch scene {
        case .idle:
            section = .queue
            libraryEmpty = true
        case .playing:
            section = .queue
            applyPlayingStress()
        case .error:
            section = .queue
            applyFailure()
        case .queue:
            section = .queue
            connectReceiver()
            currentQueueIndex = 2
            title = queueTitle(2)
            playback = .playing
            detail = "Direct · 1080p"
            position = 186
            duration = 1480
        case .library:
            section = .live
            connectReceiver()
            playback = .playing
            liveShift = true
            title = "Harbour Radio"
            detail = "Live · Demo TV"
            showProgramme(for: "demo.harbour")
        case .xtream:
            section = .films
            receiverName = "No receiver"
            receiverConnected = false
        case .history:
            section = .history
            connectReceiver()
            if let item = history.first {
                showHistory(item, playing: false)
            }
        }
    }

    var acceptsQueueActions: Bool { playback != .idle }
    var sourceTrimmed: String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var sourceCaption: String {
        acceptsQueueActions
            ? "Play Now and Open replace playback. Play Next and Add to Queue leave the current video running."
            : "Video URL, website, playlist, or local file"
    }
    var queueCount: Int { libraryEmpty ? 0 : Self.queueTotal }
    var favouriteCount: Int { channels.filter(\.isFavourite).count }
    var visibleChannels: [PrototypeChannel] {
        channels.filter { channel in
            let matchesSection = section != .favourites || channel.isFavourite
            let query = channelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesQuery = query.isEmpty || channel.name.localizedCaseInsensitiveContains(query) || channel.category.localizedCaseInsensitiveContains(query)
            return matchesSection && matchesQuery
        }
    }
    var visibleTitles: [PrototypeTitleItem] {
        let source = section == .series ? series : films
        let query = catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
    }
    var selectedChannel: PrototypeChannel? { channels.first { $0.id == selectedChannelID } }
    var selectedHistory: PrototypeHistoryItem? { history.first { $0.id == selectedHistoryID } }
    var selectedTitle: PrototypeTitleItem? { visibleTitles.first { $0.id == selectedTitleID } ?? (section == .series ? series : films).first { $0.id == selectedTitleID } }
    var pageCount: Int { (Self.queueTotal + Self.pageSize - 1) / Self.pageSize }
    var pageItems: [PrototypeQueueItem] {
        let start = queuePage * Self.pageSize
        let end = min(start + Self.pageSize, Self.queueTotal)
        return (start..<end).map { index in
            PrototypeQueueItem(id: index, title: queueTitle(index), isCurrent: index == currentQueueIndex)
        }
    }
    var pageLabel: String {
        let start = queuePage * Self.pageSize + 1
        let end = min(start + Self.pageSize - 1, Self.queueTotal)
        return "\(start)–\(end) of \(Self.queueTotal)"
    }

    func programmes(for channel: PrototypeChannel) -> [PrototypeProgramme] {
        [
            PrototypeProgramme(id: channel.id + "-now", title: "\(channel.name): Evening Edition", clock: "18:00–18:30", day: "Now", isCurrent: true, progress: 0.55, remaining: "14 min left"),
            PrototypeProgramme(id: channel.id + "-weather", title: "Weather Desk", clock: "18:30", day: "Today", isCurrent: false, progress: nil, remaining: nil),
            PrototypeProgramme(id: channel.id + "-paper", title: "The Paper Route", clock: "19:00", day: "Today", isCurrent: false, progress: nil, remaining: nil),
            PrototypeProgramme(id: channel.id + "-music", title: "Night Music", clock: "21:00", day: "Today", isCurrent: false, progress: nil, remaining: nil),
            PrototypeProgramme(id: channel.id + "-breakfast", title: "Breakfast", clock: "06:00", day: "Tomorrow", isCurrent: false, progress: nil, remaining: nil),
            PrototypeProgramme(id: channel.id + "-morning", title: "Morning Report", clock: "07:30", day: "Tomorrow", isCurrent: false, progress: nil, remaining: nil)
        ]
    }

    func handle(_ key: PlaybackKey) -> Bool {
        switch key {
        case .toggle:
            guard playback == .playing || playback == .paused else { return false }
            playback = playback == .playing ? .paused : .playing
            return true
        case .backward, .forward:
            guard duration > 0, !liveShift else { return false }
            let delta: Double = key == .backward ? -10 : 10
            position = min(duration, max(0, position + delta))
            return true
        }
    }

    @discardableResult
    func stepChannel(_ delta: Int) -> Bool {
        guard section == .live || section == .favourites else { return false }
        let rows = visibleChannels
        guard !rows.isEmpty else { return false }
        let current = rows.firstIndex { $0.id == selectedChannelID } ?? 0
        let next = min(rows.count - 1, max(0, current + delta))
        guard next != current || selectedChannelID != rows[next].id else { return true }
        selectChannel(rows[next].id)
        return true
    }

    func focusSearch() {
        if section != .films && section != .series && section != .favourites {
            section = .live
        }
        searchFocus += 1
    }

    func dismissTransient() -> Bool {
        if showOpen { showOpen = false; return true }
        if showSettings { showSettings = false; return true }
        if notice != nil { notice = nil; noticeIsError = false; return true }
        if !channelQuery.isEmpty || !catalogQuery.isEmpty {
            channelQuery = ""
            catalogQuery = ""
            return true
        }
        return false
    }

    func loadSource() {
        guard !sourceTrimmed.isEmpty else { return }
        beginItem(named: displayName(sourceTrimmed), playing: false)
        notice = nil
        showOpen = false
    }

    func playNow() {
        guard !sourceTrimmed.isEmpty else { return }
        beginItem(named: displayName(sourceTrimmed), playing: true)
        notice = "Play Now replaced playback."
        noticeIsError = false
        showOpen = false
    }

    func playNext() {
        guard !sourceTrimmed.isEmpty else { return }
        notice = "“\(displayName(sourceTrimmed))” will play next. The current video keeps playing."
        noticeIsError = false
        showOpen = false
    }

    func addToQueue() {
        guard !sourceTrimmed.isEmpty else { return }
        notice = "Added “\(displayName(sourceTrimmed))” to the end of the queue."
        noticeIsError = false
        showOpen = false
    }

    func chooseFile() {
        notice = "Choosing a file replaces playback, including while a queue is running."
        noticeIsError = false
    }

    func acceptDrop(_ urls: [URL]) -> Bool {
        let names = urls.map { url -> String in
            url.isFileURL ? url.lastPathComponent : "Link"
        }
        guard !names.isEmpty else { return false }
        if names.count == 1, playback == .idle {
            beginItem(named: names[0], playing: false)
            notice = "Loaded \(names[0])."
        } else if playback == .idle {
            beginItem(named: names[0], playing: false)
            notice = "Loaded \(names[0]). Added \(names.count - 1) more to the queue."
        } else {
            notice = "\(names.count) items added to the queue. The video on the TV keeps playing."
        }
        noticeIsError = false
        return true
    }

    func playQueueItem(_ index: Int) {
        currentQueueIndex = index
        beginItem(named: queueTitle(index), playing: true)
        notice = nil
    }

    func turnPage(_ delta: Int) {
        queuePage = min(pageCount - 1, max(0, queuePage + delta))
    }

    func toggleFavourite(_ id: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        channels[index].isFavourite.toggle()
    }

    func selectChannel(_ id: String) {
        selectedChannelID = id
        showProgramme(for: id)
    }

    func selectHistory(_ id: String) {
        selectedHistoryID = id
    }

    func resume(_ item: PrototypeHistoryItem) {
        guard let seconds = item.resumeSeconds else { return }
        showHistory(item, playing: true)
        position = seconds
        notice = "Resuming at \(item.stoppedAt ?? prototypeTime(seconds))."
        noticeIsError = false
    }

    func playFromStart(_ item: PrototypeHistoryItem) {
        showHistory(item, playing: true)
        position = 0
        notice = "Playing from the start."
        noticeIsError = false
    }

    func playTitle(_ item: PrototypeTitleItem) {
        beginItem(named: item.name, playing: true)
        detail = item.detail
        notice = nil
    }

    func togglePlayback() {
        guard playback == .playing || playback == .paused else { return }
        playback = playback == .playing ? .paused : .playing
    }

    func stop() {
        playback = .idle
        title = "No video loaded"
        detail = ""
        showAudioWarning = false
        position = 0
        duration = 0
        liveShift = false
        currentQueueIndex = nil
        notice = nil
    }

    func skip(_ delta: Double) {
        guard duration > 0, !liveShift else { return }
        position = min(duration, max(0, position + delta))
    }

    func goLive() {
        shiftBehind = 0
        shiftScrubbing = false
        shiftHeldStart = nil
        shiftHeldEnd = nil
    }

    func beginShiftScrub(start: Int, end: Int) {
        if shiftHeldStart == nil {
            shiftHeldStart = start
            shiftHeldEnd = end
            shiftValue = Double(end - shiftBehind)
        }
        shiftScrubbing = true
    }

    func endShiftScrub(end: Int) {
        shiftBehind = max(0, end - Int(shiftValue))
        shiftHeldStart = nil
        shiftHeldEnd = nil
        shiftScrubbing = false
    }

    private func applyPlayingStress() {
        connectReceiver()
        source = "https://example.com/night-ferry"
        playback = .playing
        title = "The Night Ferry — Episode 4: Low Water at the Bend"
        detail = "Direct · 1080p"
        showAudioWarning = true
        position = 760
        duration = 2650
    }

    private func applyFailure() {
        connectReceiver()
        source = "https://example.com/night-ferry"
        playback = .failed
        title = "The Night Ferry — Episode 4"
        detail = "Preparing on this Mac"
        position = 760
        duration = 2650
        noticeIsError = true
        notice = "AirThrow stopped preparing this video because the temporary workspace on this Mac reached its 8 GB limit. Playback on the TV paused at 12:40. Free space in Settings, then try again, or switch this video back to Original quality and load it again. Nothing on the TV will resume until this Mac has room to prepare the rest of the file."
    }

    private func connectReceiver() {
        receiverName = "Living Room Apple TV"
        receiverConnected = true
    }

    private func beginItem(named name: String, playing: Bool) {
        playback = playing ? .playing : .paused
        title = name
        detail = "Direct · 1080p"
        showAudioWarning = false
        liveShift = false
        position = 0
        duration = 1800
        if !receiverConnected {
            receiverName = "No receiver"
        }
    }

    private func showProgramme(for id: String) {
        guard let channel = channels.first(where: { $0.id == id }) else { return }
        liveShift = true
        playback = .playing
        title = channel.name
        detail = "Live · Demo TV"
        showAudioWarning = false
        position = 0
        duration = 0
    }

    private func showHistory(_ item: PrototypeHistoryItem, playing: Bool) {
        liveShift = false
        showAudioWarning = false
        title = item.title
        detail = item.detail
        duration = item.duration
        position = playing ? (item.resumeSeconds ?? 0) : (item.resumeSeconds ?? 0)
        playback = playing ? .playing : (item.resumeSeconds == nil ? .idle : .paused)
        if item.resumeSeconds == nil && !playing {
            title = "No video loaded"
            duration = 0
            position = 0
        }
    }

    private func queueTitle(_ index: Int) -> String {
        let stems = [
            "The Night Ferry", "Harbour Lights", "The Paper Route", "Salt and Timber",
            "North Platform", "Glasshouse Week", "Low Water", "City Weather",
            "Night Music", "Platform Sports", "Morning Report", "The Long Crossing",
            "Red Lantern", "Quiet Street", "West Pier", "Paper Boats"
        ]
        return "\(stems[index % stems.count]) — Episode \(index + 1)"
    }

    private func displayName(_ source: String) -> String {
        if let url = URL(string: source), url.scheme != nil {
            let name = url.lastPathComponent
            if !name.isEmpty, name != "/" { return name.removingPercentEncoding ?? name }
            return url.host ?? "Video"
        }
        return (source as NSString).lastPathComponent
    }

    private static func makeChannels() -> [PrototypeChannel] {
        let rows: [(String, String, String, Bool)] = [
            ("demo.news", "Demo News", "News", true),
            ("demo.city", "City Weather", "News", false),
            ("demo.desk", "Weather Desk", "News", false),
            ("demo.morning", "Morning Report", "News", false),
            ("demo.sport", "Platform Sports", "Sport", false),
            ("demo.pier", "West Pier", "Sport", false),
            ("demo.music", "Night Music", "Music", true),
            ("demo.lantern", "Red Lantern", "Music", false),
            ("demo.boats", "Paper Boats", "Music", false),
            ("demo.quiet", "Quiet Street", "Music", false),
            ("demo.salt", "Salt and Timber", "Film", false),
            ("demo.glass", "Glasshouse Week", "Film", false),
            ("demo.north", "North Platform", "Film", false),
            ("demo.crossing", "The Long Crossing", "Film", false),
            ("demo.paper", "The Paper Route", "Film", false),
            ("demo.harbour", "Harbour Radio", "Music", true),
            ("demo.ferry", "The Night Ferry", "Series", false),
            ("demo.low", "Low Water", "Series", false),
            ("demo.lights", "Harbour Lights", "Film", false),
            ("demo.breakfast", "Breakfast", "News", false),
            ("demo.late", "Late Session", "Music", false),
            ("demo.kids", "Paper Club", "Kids", false)
        ]
        return rows.map { PrototypeChannel(id: $0.0, name: $0.1, category: $0.2, isFavourite: $0.3) }
    }
}

func prototypeTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remain = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remain) }
    return String(format: "%d:%02d", minutes, remain)
}

func prototypeClock(_ seconds: Int) -> String {
    let day = 24 * 3600
    let wrapped = ((seconds % day) + day) % day
    return String(format: "%d:%02d", wrapped / 3600, (wrapped % 3600) / 60)
}
