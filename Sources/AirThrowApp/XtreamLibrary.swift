import Foundation
import Combine
#if SWIFT_PACKAGE
import AirThrowCore
#endif

@MainActor
final class XtreamLibrary: ObservableObject {
    let client: XtreamClient
    let accountInfo: XtreamAccountInfo
    var source: URL { client.account.source }
    @Published private(set) var section: XtreamSection = .live
    @Published private(set) var categories: [XtreamCategory] = []
    @Published private(set) var categoryID: String?
    @Published private(set) var listing = XtreamListing.empty
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var selected: XtreamItem?
    @Published private(set) var details: XtreamDetails?
    @Published private(set) var guide: [XtreamProgramme] = []
    @Published private(set) var detailLoading = false
    @Published private(set) var detailError: String?
    @Published private(set) var playingID: String?
    struct CatalogKey: Hashable {
        let section: XtreamSection
        let categoryID: String?
    }
    var catalogKey: CatalogKey { CatalogKey(section: section, categoryID: categoryID) }
    @Published private(set) var search = ""
    /// Scroll restoration only. Publishing it made every scroll event refilter the catalog.
    private(set) var scrollID: String?
    private(set) var visibleItems: [XtreamItem] = []
    @Published private(set) var visibleRevision = 0
    private(set) var categoryNames: [String: String] = [:]
    private var visibleRefresh: Task<Void, Never>?
    private var categoryCache: [XtreamSection: [XtreamCategory]] = [:]
    private var listingCache: [CatalogKey: XtreamListing] = [:]
    private var rememberedCategories: [XtreamSection: String] = [:]
    private var searches: [XtreamSection: String] = [:]
    private var positions: [CatalogKey: String] = [:]
    private let catalogStore: XtreamCatalogStore?
    private var task: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var generation = UUID()
    private var detailGeneration = UUID()

    init(client: XtreamClient, accountInfo: XtreamAccountInfo, catalogStore: XtreamCatalogStore? = nil) {
        self.catalogStore = catalogStore
        self.client = XtreamClient(account: client.account, timeZoneIdentifier: accountInfo.timeZoneIdentifier)
        self.accountInfo = accountInfo
    }
    deinit { task?.cancel(); detailTask?.cancel(); visibleRefresh?.cancel() }

    func switchSection(_ section: XtreamSection) {
        browse(section, categoryID: rememberedCategories[section])
    }
    func setSearch(_ value: String) {
        search = value; searches[section] = value
        scrollID = nil; positions[catalogKey] = nil
        visibleRefresh?.cancel()
        let terms = value.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { rebuildVisible(); return }
        visibleRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.rebuildVisible()
        }
    }
    func updateScroll(_ value: String?, for key: CatalogKey) {
        // A removed scroll view can publish a final update after changing tabs.
        guard key == catalogKey, !loading else { return }
        scrollID = value; positions[key] = value
    }
    func refresh() {
        browse(section, categoryID: categoryID, forceRefresh: true)
    }
    func browse(_ section: XtreamSection, categoryID: String? = nil, forceRefresh: Bool = false) {
        let changed = self.section != section
        task?.cancel(); visibleRefresh?.cancel(); generation = UUID()
        let id = generation
        self.section = section; self.categoryID = categoryID
        rememberedCategories[section] = categoryID
        search = searches[section] ?? ""
        scrollID = positions[catalogKey]
        back(); error = nil
        if forceRefresh {
            categoryCache[section] = nil
            listingCache = listingCache.filter { $0.key.section != section }
        }
        if let cachedCategories = categoryCache[section] { storeCategories(cachedCategories) }
        else if changed { storeCategories([]) }
        if let cached = listingCache[catalogKey] {
            listing = cached; loading = false; task = nil
            rebuildVisible()
            return
        }
        // An all-titles response can also answer subsequent category requests locally.
        let allKey = CatalogKey(section: section, categoryID: nil)
        if let categoryID, let all = listingCache[allKey] {
            listing = all.filtered(toCategory: categoryID)
            loading = false; task = nil
            rebuildVisible()
            return
        }
        loading = true
        listing = .empty
        rebuildVisible()
        let client = client, key = catalogKey, cachedCategories = categoryCache[section]
        task = Task { [weak self] in
            do {
                if let store = self?.catalogStore {
                    if forceRefresh { await store.invalidate(account: client.account, section: section) }
                    else {
                        var savedKey = key
                        var saved = await store.load(account: client.account, section: section, categoryID: categoryID)
                        if saved == nil, categoryID != nil {
                            savedKey = CatalogKey(section: section, categoryID: nil)
                            saved = await store.load(account: client.account, section: section, categoryID: nil)
                        }
                        guard !Task.isCancelled, let self, self.generation == id else { return }
                        if let saved {
                            self.storeCategories(saved.categories); self.categoryCache[section] = saved.categories
                            self.listingCache[savedKey] = saved.listing
                            if savedKey != key, let categoryID { self.listing = saved.listing.filtered(toCategory: categoryID) }
                            else { self.listing = saved.listing }
                            self.rebuildVisible()
                            self.loading = false; self.task = nil
                            return
                        }
                    }
                }
                async let listing = client.listing(section, categoryID: categoryID)
                let categories: [XtreamCategory]
                if let cachedCategories { categories = cachedCategories }
                else { categories = try await client.categories(section) }
                guard !Task.isCancelled, let self, self.generation == id else { return }
                // Keep categories usable even if the all-titles response is too large.
                self.storeCategories(categories); self.categoryCache[section] = categories
                let result = try await listing
                guard !Task.isCancelled, self.generation == id else { return }
                self.listingCache[key] = result
                self.listing = result
                self.rebuildVisible()
                if let store = self.catalogStore {
                    await store.save(.init(categories: categories, listing: result), account: client.account, section: section, categoryID: categoryID)
                }
                guard !Task.isCancelled, self.generation == id else { return }
                self.loading = false; self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == id else { return }
                self.error = XtreamFailure.message(for: error); self.loading = false; self.task = nil
            }
        }
    }

    func persistCatalogs() async {
        guard let store = catalogStore else { return }
        for (key, listing) in listingCache {
            await store.save(.init(categories: categoryCache[key.section] ?? [], listing: listing), account: client.account, section: key.section, categoryID: key.categoryID)
        }
    }

    func cancelLoading() {
        task?.cancel(); task = nil; generation = UUID(); loading = false
    }
    func select(_ item: XtreamItem) {
        back(); selected = item; loadDetails()
    }
    func loadDetails() {
        guard let item = selected else { return }
        detailTask?.cancel(); detailGeneration = UUID()
        let id = detailGeneration, section = section, client = client
        detailLoading = true; detailError = nil
        detailTask = Task { [weak self] in
            do {
                if section == .live {
                    let guide = try await client.guide(streamID: item.id)
                    guard !Task.isCancelled, let self, self.detailGeneration == id else { return }
                    self.guide = guide
                } else {
                    let details = try await client.details(item, section: section)
                    guard !Task.isCancelled, let self, self.detailGeneration == id else { return }
                    self.details = details
                }
                guard let self, self.detailGeneration == id else { return }
                self.detailLoading = false; self.detailTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.detailGeneration == id else { return }
                self.detailLoading = false; self.detailTask = nil; self.detailError = XtreamFailure.message(for: error)
            }
        }
    }
    func back() {
        detailTask?.cancel(); detailTask = nil; detailGeneration = UUID()
        selected = nil; details = nil; guide = []; detailError = nil; detailLoading = false
    }
    private func storeCategories(_ categories: [XtreamCategory]) {
        self.categories = categories
        var names: [String: String] = [:]
        names.reserveCapacity(categories.count)
        for category in categories { names[category.id] = category.name }
        categoryNames = names
    }

    private func rebuildVisible() {
        let terms = search.split(whereSeparator: \.isWhitespace)
        visibleItems = terms.isEmpty ? listing.items : listing.items.filter { item in
            terms.allSatisfy { item.name.localizedStandardContains($0) }
        }
        visibleRevision &+= 1
    }

    func playbackURL(_ item: XtreamItem) throws -> URL {
        guard section != .series else { throw XtreamFailure.invalidResponse }
        let format = client.account.format.rawValue
        if section == .live && !accountInfo.allowedFormats.isEmpty && !accountInfo.allowedFormats.contains("m3u8") && !accountInfo.allowedFormats.contains("ts") {
            throw XtreamFailure.unsupportedLiveFormat
        }
        let liveFormat = accountInfo.allowedFormats.isEmpty || accountInfo.allowedFormats.contains(format)
            ? format : (accountInfo.allowedFormats.contains("m3u8") ? "m3u8" : "ts")
        return try client.account.streamURL(kind: section, id: item.id, extension: section == .live ? liveFormat : item.container)
    }
    func episodeURL(_ episode: XtreamEpisode) throws -> URL {
        try client.account.streamURL(kind: .series, id: episode.id, extension: episode.container)
    }
    func didPlay(_ id: String) { playingID = Self.playingKey(section, id) }
    func isPlaying(_ id: String) -> Bool { playingID == Self.playingKey(section, id) }
    static func playingKey(_ section: XtreamSection, _ id: String) -> String { section.rawValue + "/" + id }
}
