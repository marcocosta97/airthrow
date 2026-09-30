import Foundation

/// A website whose cookies AirThrow can import for authenticated extraction.
/// The raw value is the stable preference key; titles and owned domains live
/// here so no caller repeats the cookie-scope rules.
public enum WebsiteService: String, CaseIterable, Sendable, Hashable {
    case youtube
    case twitch
    case twitter
    case instagram
    case vimeo

    /// Human-facing name for settings and status text.
    public var title: String {
        switch self {
        case .youtube: return "YouTube"
        case .twitch: return "Twitch"
        case .twitter: return "X (Twitter)"
        case .instagram: return "Instagram"
        case .vimeo: return "Vimeo"
        }
    }

    /// Domains that can carry a session for this service. Deliberately narrow:
    /// no shared or unrelated domains are ever imported.
    public var domains: [String] {
        switch self {
        case .youtube: return ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        case .twitch: return ["twitch.tv"]
        case .twitter: return ["x.com", "twitter.com"]
        case .instagram: return ["instagram.com"]
        case .vimeo: return ["vimeo.com"]
        }
    }

    /// Suffix-safe ownership check: the host must equal an owned domain or be a
    /// genuine subdomain of it, so both `youtube.com.evil.example` and
    /// `notyoutube.com` are rejected.
    public func includes(domain: String) -> Bool {
        var value = domain.lowercased()
        while value.hasPrefix(".") { value.removeFirst() }
        guard !value.isEmpty else { return false }
        return domains.contains { value == $0 || value.hasSuffix("." + $0) }
    }

    /// Resolve an HTTP(S) URL to the service that owns its host, or nil when the
    /// host is neither an exact service domain nor one of its owned subdomains.
    public static func service(for url: URL) -> WebsiteService? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host, !rawHost.isEmpty else { return nil }
        var host = rawHost.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        return allCases.first { $0.includes(domain: host) }
    }
}

/// The scope rules shared by the file and browser readers: which domains carry
/// a session and which cookie names prove one. Cookie values are never logged.
enum WebsiteCookieScope {
    /// The signed-in marker for each service when there is no single universal
    /// cross-service marker.
    static func authenticationNames(for service: WebsiteService) -> [String] {
        switch service {
        case .youtube: return ["LOGIN_INFO"]
        case .twitch: return ["auth-token"]
        case .twitter: return ["auth_token"]
        case .instagram: return ["sessionid"]
        case .vimeo: return ["vimeo"]
        }
    }

    static func includes(_ domain: String, service: WebsiteService) -> Bool {
        service.includes(domain: domain)
    }

    /// A signed-in marker must be scoped, carry a non-empty value, and not be
    /// expired. A zero expiry is a session cookie, which still counts.
    static func hasAuthentication(_ cookies: [NetscapeCookie], service: WebsiteService) -> Bool {
        let names = authenticationNames(for: service)
        let now = Int64(Date().timeIntervalSince1970)
        return cookies.contains { cookie in
            service.includes(domain: cookie.domain) && names.contains(cookie.name)
                && !cookie.value.isEmpty
                && (cookie.expires == 0 || cookie.expires > now)
        }
    }
}

/// A non-sensitive summary of one service's cookies inside an inspected file.
/// Only the service, how many scoped cookies it holds, and whether a signed-in
/// marker is present are exposed; cookie names, values, and domains never leave
/// `CookieFileInspection`.
public struct CookieServiceSummary: Sendable, Equatable {
    public let service: WebsiteService
    public let cookieCount: Int
    public let hasSession: Bool

    public init(service: WebsiteService, cookieCount: Int, hasSession: Bool) {
        self.service = service
        self.cookieCount = cookieCount
        self.hasSession = hasSession
    }
}

/// The result of reading a Netscape cookies file for session discovery without
/// exposing any cookie material.
public enum CookieFileInspection: Sendable, Equatable {
    /// The file was readable. One summary per service with a nonzero scoped
    /// count, in `WebsiteService.allCases` order; an empty array means the file
    /// was readable but held no recognized service cookies (including malformed
    /// or foreign-only files).
    case loaded([CookieServiceSummary])
    /// The file could not be read.
    case unavailable

    /// Read `file` once, parse it, and summarize each service's scoped cookies.
    /// Cookie names, values, and domains are never exported.
    public static func inspect(_ file: URL) -> CookieFileInspection {
        guard file.isFileURL, let text = try? String(contentsOf: file, encoding: .utf8) else { return .unavailable }
        let cookies = NetscapeCookies.parse(text)
        let summaries = WebsiteService.allCases.compactMap { service -> CookieServiceSummary? in
            let scoped = NetscapeCookies.scoped(cookies, service: service)
            guard !scoped.isEmpty else { return nil }
            return CookieServiceSummary(service: service,
                                        cookieCount: scoped.count,
                                        hasSession: WebsiteCookieScope.hasAuthentication(scoped, service: service))
        }
        return .loaded(summaries)
    }
}

/// Maps loaded services to the cookie source the user configured for each. The
/// app keeps one entry per service; absent entries mean "run unauthenticated".
public struct WebsiteSessions: Sendable, Equatable {
    private let sources: [WebsiteService: YouTubeCookies]

    public init(sources: [WebsiteService: YouTubeCookies] = [:]) {
        self.sources = sources
    }

    /// The configured source for a service, or `.none`.
    public func source(for service: WebsiteService) -> YouTubeCookies {
        sources[service] ?? .none
    }

    /// The configured source for the service that owns `url`, or `.none` when
    /// the URL belongs to no known service.
    public func source(for url: URL) -> YouTubeCookies {
        guard let service = WebsiteService.service(for: url) else { return .none }
        return source(for: service)
    }
}
