import Foundation
import AVFoundation

private struct CheckFailure: Error { let message: String }
@main struct XtreamChecks {
    @MainActor static func main() async {
        do { try await run() } catch { print("FAIL", error); exit(1) }
    }
    @MainActor static func run() async throws {
        let base = CommandLine.arguments[1]
        var count = 0
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw CheckFailure(message: message) }
            count += 1; print("PASS", message)
        }
        func account(_ prefix: String = "", password: String = "fixture&pass=/word") throws -> XtreamAccount {
            try XtreamAccount(source: XtreamPlaylist.url(server: base + prefix, username: "fixture+user", password: password))
        }
        func wait(_ predicate: @MainActor () -> Bool) async throws {
            for _ in 0..<200 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw CheckFailure(message: "Timed out waiting for local operation")
        }
        let credentials = try account()
        try check(try XtreamAccount(source: credentials.source) == credentials, "Saved Xtream account round-trips without altering credentials")
        let api = try credentials.apiURL(action: "get_live_streams")
        try check(api.path == "/player_api.php" && api.query!.contains("fixture%2Buser"), "Player API encodes literal plus for PHP query decoding")
        let stream = try credentials.streamURL(kind: .live, id: "11", extension: "m3u8")
        try check(stream.path(percentEncoded: true).contains("fixture%26pass%3D%2Fword/11.m3u8"), "Stream path encodes slash and delimiters inside credentials")
        let prefixed = try account("/proxy%20tv")
        try check(try prefixed.apiURL().path(percentEncoded: true) == "/proxy%20tv/player_api.php", "API retains encoded reverse-proxy path")
        try check(try prefixed.streamURL(kind: .movies, id: "11", extension: "mp4").path(percentEncoded: true).hasPrefix("/proxy%20tv/movie/"), "Stream path retains reverse-proxy prefix")
        do { _ = try credentials.streamURL(kind: .live, id: "../bad", extension: "ts"); throw CheckFailure(message: "Unsafe stream ID accepted") }
        catch XtreamFailure.invalidResponse { try check(true, "Server stream identifiers cannot escape the playback path") }
        do { _ = try credentials.streamURL(kind: .movies, id: "11", extension: "mp4?token=bad"); throw CheckFailure(message: "Unsafe extension accepted") }
        catch XtreamFailure.invalidResponse { try check(true, "Server container extension cannot inject query data") }
        let client = XtreamClient(account: credentials)
        let info = try await client.authenticate()
        try check(info.status == "Active" && info.maximumConnections == 2 && info.activeConnections == 1, "Account accepts mixed string/numeric fields")
        try check(info.expires != nil && info.timeZoneIdentifier == "Europe/Rome", "Account provides expiry and server timezone")
        do { _ = try await XtreamClient(account: account(password: "wrong")).authenticate(); throw CheckFailure(message: "Invalid login accepted") }
        catch XtreamFailure.rejectedAccount { try check(true, "HTTP 200 auth=0 rejects sign-in") }
        do { _ = try await XtreamClient(account: account("/expired")).authenticate(); throw CheckFailure(message: "Expired account accepted") }
        catch XtreamFailure.inactiveAccount { try check(true, "Inactive accounts have an actionable error") }
        do { _ = try await XtreamClient(account: account("/bad")).authenticate(); throw CheckFailure(message: "HTML accepted") }
        catch XtreamFailure.invalidResponse { try check(true, "Malformed provider responses never surface raw credentials") }
        do { _ = try await XtreamClient(account: account("/oversize")).authenticate(); throw CheckFailure(message: "Oversized response accepted") }
        catch XtreamFailure.tooLarge { try check(true, "Oversized API response is rejected before reading body") }
        for prefix in ["/chunked", "/compressed"] {
            do { _ = try await XtreamClient(account: account(prefix)).authenticate(); throw CheckFailure(message: "Decoded response budget bypassed") }
            catch XtreamFailure.tooLarge { try check(true, "\(prefix) response enforces received bytes independently of Content-Length") }
        }
        let largeClient = XtreamClient(account: try account("/large"))
        let largeList = try await largeClient.listing(.movies)
        try check(largeList.items.count == 12_000 && largeList.items.last?.id == "12000" && !largeList.truncated,
                  "Catalog larger than 8 MiB retains all 12,000 titles")
        let filteredLibrary = XtreamLibrary(client: XtreamClient(account: try account("/filtered")), accountInfo: info)
        filteredLibrary.browse(.movies)
        try await wait { !filteredLibrary.loading }
        try check(filteredLibrary.categories.count == 2 && filteredLibrary.error == XtreamFailure.tooLarge.message,
                  "Over-budget all-titles response retains usable category menu")
        filteredLibrary.browse(.movies, categoryID: "1")
        try await wait { !filteredLibrary.loading }
        try check(filteredLibrary.error == nil && filteredLibrary.listing.items.count == 2 && filteredLibrary.categoryID == "1",
                  "Category request recovers from oversized all-titles catalog")
        do { _ = try await XtreamClient(account: account("/redirect")).authenticate(); throw CheckFailure(message: "Cross-origin redirect accepted") }
        catch XtreamFailure.httpStatus(302) { try check(true, "API credentials are not forwarded to another origin") }
        for section in XtreamSection.allCases {
            let categories = try await client.categories(section)
            let list = try await client.listing(section)
            try check(categories.count == 2 && list.items.count == 2 && list.skipped == 3,
                      "\(section.rawValue) catalog uses API and skips duplicate/malformed entries")
            try check(try await client.listing(section, categoryID: "2").items.isEmpty, "\(section.rawValue) accepts empty category object")
        }
        let film = try await client.listing(.movies).items[0]
        let detail = try await client.details(film, section: .movies)
        try check(detail.summary == "Film plot" && detail.duration == "01:02:03" && detail.director == "Director", "Film metadata comes from get_vod_info")
        let show = try await client.listing(.series).items[0]
        let series = try await client.details(show, section: .series)
        try check(series.episodes.map(\.id) == ["101", "102", "202"] && series.skippedEpisodes == 2, "Series details sort seasons/episodes and deduplicate IDs")
        let arrayClient = XtreamClient(account: try account("/array"))
        let arrayShow = try await arrayClient.listing(.series).items[0]
        let arraySeries = try await arrayClient.details(arrayShow, section: .series)
        try check(arraySeries.episodes.map(\.id) == ["301", "302"] && arraySeries.episodes[0].season == 1
                  && arraySeries.episodes[0].summary == "Opens" && arraySeries.episodes[1].season == 2,
                  "Series details accept an empty info array and episode arrays")
        try check(series.episodes[0].summary == "Episode plot" && series.episodes[0].duration == "00:30:00", "Episode metadata is retained")
        try check(try credentials.streamURL(kind: .series, id: series.episodes[2].id, extension: series.episodes[2].container).lastPathComponent == "202.mkv", "Episode playback uses provider container")
        let guideClient = XtreamClient(account: credentials, timeZoneIdentifier: info.timeZoneIdentifier)
        let guide = try await guideClient.guide(streamID: "11")
        try check(guide.count == 2 && guide.contains(where: { $0.title == "Notizie italiane" && $0.summary == "La guida" }), "Guide decodes base64 and drops invalid intervals")
        let legacy = guide.first { $0.title == "Legacy schedule" }!
        try check(legacy.start.timeIntervalSince1970 == 2_000_003_600, "Legacy EPG wall-clock timestamps use the server timezone")
        try check(try await guideClient.guide(streamID: "12").count == 2, "Guide falls back to short EPG when full guide is unsupported")
        let library = XtreamLibrary(client: client, accountInfo: info)
        library.browse(.live)
        try await wait { !library.loading }
        try check(library.listing.items.count == 2 && library.error == nil, "Library loads categories and live streams together")
        try check(try library.playbackURL(library.listing.items[0]).pathExtension == "ts", "Live playback honors account output-format restrictions")
        let unavailableFormats = XtreamAccountInfo(status: "Active", expires: nil, activeConnections: nil, maximumConnections: nil,
                                                   allowedFormats: ["mp4"], timeZoneIdentifier: nil)
        let unsupportedLibrary = XtreamLibrary(client: client, accountInfo: unavailableFormats)
        do { _ = try unsupportedLibrary.playbackURL(library.listing.items[0]); throw CheckFailure(message: "Unavailable live format accepted") }
        catch XtreamFailure.unsupportedLiveFormat { try check(true, "Unavailable account formats never produce an unsupported live URL") }
        library.browse(.live, categoryID: "3")
        library.browse(.movies, categoryID: "2")
        try await wait { !library.loading }
        try await Task.sleep(for: .milliseconds(800))
        try check(library.section == .movies && library.listing.items.isEmpty, "Late category response cannot overwrite a newer tab")
        library.browse(.series)
        try await wait { !library.loading }
        library.select(library.listing.items[0])
        try await wait { !library.detailLoading }
        try check(library.details?.episodes.count == 3, "Library opens series episodes on demand")
        library.back()
        try check(library.selected == nil && library.details == nil && library.guide.isEmpty, "Back clears detail state without reloading catalog")
        library.browse(.live, categoryID: "3"); library.cancelLoading()
        try await Task.sleep(for: .milliseconds(800))
        try check(!library.loading && library.listing.items.isEmpty, "Cancel prevents a late catalog response from publishing")
        let cachedLibrary = XtreamLibrary(client: XtreamClient(account: try account("/cache")), accountInfo: info)
        func requestCounts() async throws -> [String: Int] {
            let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/cache/stats")!)
            return try JSONDecoder().decode([String: Int].self, from: data)
        }
        cachedLibrary.switchSection(.movies)
        try await wait { !cachedLibrary.loading }
        cachedLibrary.browse(.movies, categoryID: "1")
        cachedLibrary.setSearch("Second")
        let filmKey = cachedLibrary.catalogKey
        cachedLibrary.updateScroll("12", for: filmKey)
        cachedLibrary.switchSection(.series)
        try await wait { !cachedLibrary.loading }
        cachedLibrary.setSearch("First")
        let beforeSwitch = try await requestCounts()
        cachedLibrary.switchSection(.movies)
        try check(!cachedLibrary.loading && cachedLibrary.categoryID == "1" && cachedLibrary.search == "Second" && cachedLibrary.scrollID == "12",
                  "Tab return restores cached catalog, category, search and scroll immediately")
        cachedLibrary.updateScroll("11", for: .init(section: .series, categoryID: nil))
        try check(cachedLibrary.scrollID == "12", "Removed tab cannot overwrite current scroll position")
        cachedLibrary.switchSection(.series)
        try check(cachedLibrary.search == "First" && !cachedLibrary.loading, "Each section retains its own search")
        try check(try await requestCounts() == beforeSwitch && beforeSwitch["get_vod_streams:all"] == 1 && beforeSwitch["get_vod_streams:1"] == nil,
                  "Cached tabs and category filtering make no provider requests")
        cachedLibrary.switchSection(.movies)
        cachedLibrary.refresh()
        try await wait { !cachedLibrary.loading }
        let afterRefresh = try await requestCounts()
        try check(afterRefresh["get_vod_categories:all"] == 2 && afterRefresh["get_vod_streams:1"] == 1 && cachedLibrary.search == "Second",
                  "Refresh fetches categories and selected catalog while preserving search")
        cachedLibrary.switchSection(.series)
        cachedLibrary.switchSection(.movies)
        try check(try await requestCounts() == afterRefresh && !cachedLibrary.loading, "Refreshed category is cached for subsequent tab returns")
        cachedLibrary.browse(.movies)
        try await wait { !cachedLibrary.loading }
        try check(try await requestCounts()["get_vod_streams:all"] == 2,
                  "Refresh invalidates other listings in its section")
        let raceLibrary = XtreamLibrary(client: client, accountInfo: info)
        raceLibrary.browse(.live, categoryID: "3")
        raceLibrary.browse(.movies, categoryID: "2")
        try await wait { !raceLibrary.loading }
        try await Task.sleep(for: .milliseconds(800))
        raceLibrary.browse(.live, categoryID: "3")
        try check(raceLibrary.loading, "Cancelled request never populates the cache")
        raceLibrary.cancelLoading()
        let savedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("xtream-saved-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: savedDirectory) }
        let disabledStore = XtreamCatalogStore(directory: savedDirectory)
        let savedAccount = try account("/cache")
        let disabledLibrary = XtreamLibrary(client: XtreamClient(account: savedAccount), accountInfo: info, catalogStore: disabledStore)
        disabledLibrary.browse(.movies)
        try await wait { !disabledLibrary.loading }
        try check(!FileManager.default.fileExists(atPath: savedDirectory.path), "Catalog persistence is off by default and creates no files")
        await disabledStore.setEnabled(true)
        await disabledLibrary.persistCatalogs()
        let files = try FileManager.default.contentsOfDirectory(at: savedDirectory, includingPropertiesForKeys: nil)
        let savedData = try Data(contentsOf: files[0])
        try check(files.count == 1 && !String(decoding: savedData, as: UTF8.self).contains("fixture&pass") && !files[0].lastPathComponent.contains("fixture"),
                  "Enabling persistence saves existing catalogs without encoding account credentials")
        let restartedStore = XtreamCatalogStore(directory: savedDirectory, enabled: true)
        let reopenedLibrary = XtreamLibrary(client: XtreamClient(account: savedAccount), accountInfo: info, catalogStore: restartedStore)
        let beforeReopen = try await requestCounts()
        reopenedLibrary.browse(.movies)
        try await wait { !reopenedLibrary.loading }
        try check(try await requestCounts() == beforeReopen && reopenedLibrary.listing.items.count == 2,
                  "New library and disk store reuse saved catalog without provider requests")
        reopenedLibrary.browse(.movies, categoryID: "1")
        try check(try await requestCounts() == beforeReopen && !reopenedLibrary.loading,
                  "Saved full catalog supports immediate local category filtering")
        try check(await restartedStore.load(account: try XtreamAccount(source: XtreamPlaylist.url(server: base + "/cache", username: "other-user", password: "fixture&pass=/word")), section: .movies, categoryID: nil) == nil,
                  "Saved catalog is isolated by server and username")
        reopenedLibrary.refresh()
        try await wait { !reopenedLibrary.loading }
        let refreshedLibrary = XtreamLibrary(client: XtreamClient(account: savedAccount), accountInfo: info,
                                             catalogStore: XtreamCatalogStore(directory: savedDirectory, enabled: true))
        let afterSavedRefresh = try await requestCounts()
        refreshedLibrary.browse(.movies, categoryID: "1")
        try await wait { !refreshedLibrary.loading }
        try check(try await requestCounts() == afterSavedRefresh && refreshedLibrary.listing.items.count == 2,
                  "Refresh replaces the saved category and a reopened library uses the replacement")
        try check(await restartedStore.load(account: savedAccount, section: .movies, categoryID: nil) == nil,
                  "Refresh invalidates saved all-titles catalog for its section")
        let refreshedFiles = try FileManager.default.contentsOfDirectory(at: savedDirectory, includingPropertiesForKeys: nil)
        try Data("invalid saved catalog".utf8).write(to: refreshedFiles[0])
        let damagedLibrary = XtreamLibrary(client: XtreamClient(account: savedAccount), accountInfo: info, catalogStore: restartedStore)
        damagedLibrary.browse(.movies, categoryID: "1")
        try await wait { !damagedLibrary.loading }
        try check(try await requestCounts() != afterSavedRefresh && damagedLibrary.error == nil && damagedLibrary.listing.items.count == 2,
                  "Corrupt saved catalog falls back to provider and is repaired")
        await restartedStore.setEnabled(false)
        await restartedStore.save(.init(categories: damagedLibrary.categories, listing: damagedLibrary.listing), account: savedAccount, section: .movies, categoryID: nil)
        try check(await restartedStore.load(account: savedAccount, section: .movies, categoryID: "1") == nil && !FileManager.default.fileExists(atPath: savedDirectory.path),
                  "Disabling persistence deletes saved catalogs and blocks later reads and writes")
        let defaults = UserDefaults(suiteName: "app.airthrow.xtream-checks.\(UUID().uuidString)")!
        let historyCredentials = MemoryMediaHistoryCredentials()
        let store = MediaHistoryStore(defaults: defaults, credentials: historyCredentials)
        let controller = PlaybackController(historyStore: store, xtreamCatalogStore: XtreamCatalogStore(directory: savedDirectory), xtreamCatalogDefaults: defaults)
        let player = controller.player
        try controller.connectXtream(credentials.source)
        try await wait { !controller.iptvImporting }
        try await wait { controller.xtreamLibrary?.loading == false }
        try check(controller.player === player && controller.snapshot.state == .idle, "Xtream sign-in/catalog browsing preserve the mounted playback session")
        try check(controller.inspectorPage == .xtream && controller.history.first?.kind == .xtream, "Successful account opens API catalog and records Xtream history")
        let saved = MediaHistoryStore(defaults: defaults, credentials: historyCredentials)
        try check(saved.entries.count == 1 && saved.entries[0].kind == .xtream && (try saved.source(for: saved.entries[0])) == credentials.source && saved.entries[0].credentialReference != nil, "Xtream history persists account and kind across store reload")
        controller.toggleHistoryPin(controller.history[0].id); controller.clearHistory()
        try check(controller.history.count == 1 && controller.history[0].isPinned, "Pinned Xtream accounts survive Clear History")
        let previous = controller.xtreamLibrary
        try controller.connectXtream(try account(password: "wrong").source)
        try await wait { !controller.iptvImporting }
        try check(controller.xtreamLibrary === previous && controller.history.count == 1 && controller.iptvImportError != nil, "Failed sign-in retains working account without recording credentials")
        try controller.connectXtream(try account("/slow").source)
        controller.cancelIPTVImport()
        try await Task.sleep(for: .milliseconds(900))
        try check(controller.xtreamLibrary === previous && !controller.iptvImporting && controller.history.count == 1, "Cancelled sign-in cannot replace library or history")
        controller.inspectorPage = .history
        try controller.selectHistoryEntry(controller.history[0].id)
        try check(controller.inspectorPage == .xtream && controller.xtreamLibrary === previous && controller.player === player
                  && controller.sourceInput == "", "History reuses working API session without touching playback or filling Source")
        try check(!controller.saveXtreamCatalogs && !defaults.bool(forKey: XtreamCatalogStore.preferenceKey), "Saved-catalog setting defaults to off")
        controller.setSaveXtreamCatalogs(true)
        try await wait { FileManager.default.fileExists(atPath: savedDirectory.path) }
        try check(controller.saveXtreamCatalogs && defaults.bool(forKey: XtreamCatalogStore.preferenceKey), "Settings toggle persists preference and saves already loaded library")
        controller.setSaveXtreamCatalogs(false)
        try await wait { !FileManager.default.fileExists(atPath: savedDirectory.path) }
        try check(!defaults.bool(forKey: XtreamCatalogStore.preferenceKey) && controller.xtreamLibrary?.listing.items.count == 2,
                  "Turning setting off removes disk cache without clearing session catalog")
        controller.stop()
        try check(controller.xtreamLibrary === previous, "Stop retains Xtream browsing session")
        print("Xtream checks: \(count) passed; physical receiver untested.")
    }
}
