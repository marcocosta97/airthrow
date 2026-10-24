import Foundation

/// Read-only Xtream player API. Media is handed to the existing playback pipeline.
public struct XtreamClient: Sendable {
    public let account: XtreamAccount
    public let timeZoneIdentifier: String?
    public init(account: XtreamAccount, timeZoneIdentifier: String? = nil) {
        self.account = account; self.timeZoneIdentifier = timeZoneIdentifier
    }
    public static let maximumResponseBytes = 64 * 1024 * 1024

    public func authenticate() async throws -> XtreamAccountInfo {
        let data = try await request()
        guard let root = try json(data) as? [String: Any],
              let user = root["user_info"] as? [String: Any] else { throw XtreamFailure.invalidResponse }
        guard XtreamParsing.integer(user["auth"]) == 1 else { throw XtreamFailure.rejectedAccount }
        let status = XtreamParsing.text(user["status"]) ?? "Unknown"
        let expiry = XtreamParsing.text(user["exp_date"]).flatMap(Double.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        guard status.lowercased() == "active", expiry.map({ $0 > Date() }) ?? true else { throw XtreamFailure.inactiveAccount }
        return XtreamAccountInfo(status: status, expires: expiry,
                                 activeConnections: XtreamParsing.integer(user["active_cons"]),
                                 maximumConnections: XtreamParsing.integer(user["max_connections"]),
                                 allowedFormats: user["allowed_output_formats"] as? [String] ?? [],
                                 timeZoneIdentifier: (root["server_info"] as? [String: Any]).flatMap { XtreamParsing.text($0["timezone"]) })
    }

    public func categories(_ section: XtreamSection) async throws -> [XtreamCategory] {
        let data = try await request(section.categoriesAction)
        let rows = try XtreamParsing.rows(json(data))
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = XtreamParsing.id(row["category_id"]), let name = XtreamParsing.text(row["category_name"]), seen.insert(id).inserted else { return nil }
            return XtreamCategory(id: id, name: name)
        }
    }

    public func listing(_ section: XtreamSection, categoryID: String? = nil) async throws -> XtreamListing {
        let parameters = categoryID.map { [URLQueryItem(name: "category_id", value: $0)] } ?? []
        let data = try await request(section.listingAction, parameters: parameters)
        let rows = try XtreamParsing.rows(json(data))
        var items = [XtreamItem](), seen = Set<String>(), skipped = 0
        for row in rows {
            guard let id = XtreamParsing.id(row[section.listingIDKey]),
                  let name = XtreamParsing.text(row["name"]), seen.insert(id).inserted else { skipped += 1; continue }
            items.append(XtreamItem(id: id, name: name, categoryID: XtreamParsing.id(row["category_id"]),
                                    container: XtreamParsing.text(row["container_extension"]) ?? "mp4",
                                    summary: XtreamParsing.text(row["plot"]), year: XtreamParsing.text(row["year"]),
                                    rating: XtreamParsing.text(row["rating"])))
        }
        return XtreamListing(items: items, skipped: skipped, truncated: false)
    }

    public func details(_ item: XtreamItem, section: XtreamSection) async throws -> XtreamDetails {
        guard section != .live else { throw XtreamFailure.invalidResponse }
        let data = try await request(section == .movies ? "get_vod_info" : "get_series_info",
                                     parameters: [URLQueryItem(name: section == .movies ? "vod_id" : "series_id", value: item.id)])
        guard let root = try json(data) as? [String: Any] else { throw XtreamFailure.invalidResponse }
        let info: [String: Any]
        if let object = root["info"] as? [String: Any] { info = object }
        else if let array = root["info"] as? [Any], array.isEmpty { info = [:] }
        else { throw XtreamFailure.invalidResponse }
        var episodes = [XtreamEpisode](), seen = Set<String>(), skipped = 0
        if section == .series {
            // Servers disagree: episodes may be a season dictionary, an empty
            // array, or an array of season arrays. An empty info array is the
            // same as an empty object.
            let groups: [String: Any]
            if let value = root["episodes"] as? [String: Any] { groups = value }
            else if let value = root["episodes"] as? [Any] {
                if value.isEmpty { groups = [:] }
                else {
                    var built: [String: Any] = [:]
                    for (index, element) in value.enumerated() {
                        if let rows = element as? [Any] { built[String(index + 1)] = rows }
                        else if let row = element as? [String: Any] { built[String(index + 1)] = [row] }
                        else { throw XtreamFailure.invalidResponse }
                    }
                    groups = built
                }
            } else { throw XtreamFailure.invalidResponse }
            for key in groups.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                let rows = try XtreamParsing.rows(groups[key]!)
                for row in rows {
                    guard let id = XtreamParsing.id(row["id"]), let season = XtreamParsing.integer(row["season"]) ?? Int(key),
                          let number = XtreamParsing.integer(row["episode_num"]), season >= 0, number >= 0,
                          seen.insert(id).inserted else { skipped += 1; continue }
                    let extra = row["info"] as? [String: Any] ?? [:]
                    episodes.append(XtreamEpisode(id: id, season: season, number: number,
                        title: XtreamParsing.text(row["title"]) ?? "Episode \(number)",
                        container: XtreamParsing.text(row["container_extension"]) ?? "mp4",
                        summary: XtreamParsing.text(extra["plot"]), duration: XtreamParsing.text(extra["duration"])))
                }
            }
            episodes.sort { $0.season == $1.season ? $0.number < $1.number : $0.season < $1.season }
        }
        return XtreamDetails(summary: XtreamParsing.text(info["plot"]) ?? XtreamParsing.text(info["description"]) ?? item.summary,
                              genre: XtreamParsing.text(info["genre"]), cast: XtreamParsing.text(info["cast"]),
                              director: XtreamParsing.text(info["director"]), duration: XtreamParsing.text(info["duration"]),
                              rating: XtreamParsing.text(info["rating"]) ?? item.rating,
                              year: XtreamParsing.text(info["releasedate"]) ?? XtreamParsing.text(info["releaseDate"]) ?? item.year,
                              episodes: episodes, skippedEpisodes: skipped)
    }

    public func guide(streamID: String) async throws -> [XtreamProgramme] {
        guard XtreamParsing.validID(streamID) else { throw XtreamFailure.invalidResponse }
        let parameters = [URLQueryItem(name: "stream_id", value: streamID)]
        let root: [String: Any]
        do {
            root = try guideRoot(await request("get_simple_data_table", parameters: parameters))
        } catch XtreamFailure.httpStatus(400), XtreamFailure.httpStatus(404), XtreamFailure.invalidResponse {
            root = try guideRoot(await request("get_short_epg", parameters: parameters + [URLQueryItem(name: "limit", value: "20")]))
        }
        let value = root["epg_listings"]!
        let rows = try XtreamParsing.rows(value)
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let start = timestamp(row, keys: ["start_timestamp", "start"]),
                  let end = timestamp(row, keys: ["stop_timestamp", "end_timestamp", "end"]), end > start,
                  let raw = XtreamParsing.text(row["title"]) else { return nil }
            let id = String(start.timeIntervalSince1970) + "/" + String(end.timeIntervalSince1970)
            guard seen.insert(id).inserted else { return nil }
            return XtreamProgramme(id: id, title: decoded(raw), summary: XtreamParsing.text(row["description"]).map(decoded), start: start, end: end)
        }.sorted { $0.start < $1.start }
    }

    private func decoded(_ text: String) -> String {
        guard let data = Data(base64Encoded: text), let value = String(data: data, encoding: .utf8),
              let clean = XtreamParsing.text(value) else { return text }; return clean
    }
    private func timestamp(_ row: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = XtreamParsing.text(row[key]), let seconds = Double(value), seconds.isFinite, seconds > 0 {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        // Prefer Unix timestamps; legacy wall-clock dates use the advertised server timezone.
        let iso = ISO8601DateFormatter()
        let wallClock = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)).map { zone in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter
        }
        for key in keys {
            guard let value = XtreamParsing.text(row[key]) else { continue }
            if let date = iso.date(from: value) ?? wallClock?.date(from: value) { return date }
        }
        return nil
    }

    private func json(_ data: Data) throws -> Any {
        try Task.checkCancellation()
        // Parse once and replace parser diagnostics with a URL-free error.
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw XtreamFailure.invalidResponse }
    }
    private func guideRoot(_ data: Data) throws -> [String: Any] {
        guard let root = try json(data) as? [String: Any], root["epg_listings"] != nil else {
            throw XtreamFailure.invalidResponse
        }
        return root
    }
    private func request(_ action: String? = nil, parameters: [URLQueryItem] = []) async throws -> Data {
        let url = try account.apiURL(action: action, parameters: parameters)
        return try await XtreamResponseTransfer(origin: account.server).load(url)
    }

}

class XtreamRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.host?.lowercased() == origin.host?.lowercased(),
              (try? MediaInput.url(url.absoluteString)) != nil else { completionHandler(nil); return }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
        let sameOrigin = url.scheme == origin.scheme && port(url) == port(origin)
        let upgrade = origin.scheme == "http" && url.scheme == "https" && (origin.port ?? 80) == 80 && (url.port ?? 443) == 443
        guard sameOrigin || upgrade, !(response.url?.scheme == "https" && url.scheme != "https") else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
