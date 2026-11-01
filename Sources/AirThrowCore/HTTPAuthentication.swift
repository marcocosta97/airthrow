import Foundation

/// The server's protection space, without the source URL or its signed query.
public struct HTTPLoginChallenge: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let scheme: String
    public let realm: String?
    public let method: String

    init?(_ space: URLProtectionSpace) {
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(space.authenticationMethod),
              let scheme = space.protocol?.lowercased(), ["http", "https"].contains(scheme), !space.isProxy() else { return nil }
        host = space.host.lowercased(); port = space.port; self.scheme = scheme
        realm = space.realm; method = space.authenticationMethod
    }

    func matches(_ space: URLProtectionSpace) -> Bool { Self(space) == self }
}

public struct HTTPLoginCredentials: Sendable {
    let challenge: HTTPLoginChallenge
    let username: String
    let password: String
    public init(challenge: HTTPLoginChallenge, username: String, password: String) {
        self.challenge = challenge; self.username = username; self.password = password
    }
}

public enum HTTPLoginFailure: Error {
    case unsupported, accessDenied, unavailable, invalidPlaylist
    public var message: String {
        switch self {
        case .unsupported: "The server uses an unsupported authentication method. Use HTTP Basic or Digest authentication, or an accessible link."
        case .accessDenied: "The server denied access (HTTP 401). The link may have expired. Obtain a fresh link or check access."
        case .unavailable: "Could not verify access to this video. Check the server and load the link again."
        case .invalidPlaylist: "Could not relay this HLS playlist. Use an accessible direct stream."
        }
    }
}

/// Each task owns an ephemeral session. Credentials are offered only to the exact
/// origin, realm and authentication method that requested them; never to a proxy.
/// A serial worker queue gates data delivery on downstream capacity. Merely
/// suspending a URLSession task does not drain already queued delegate callbacks.
@MainActor
final class HTTPMediaTransfer: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let credentials: HTTPLoginCredentials?
    private let origin: URL
    private let target: URL?
    private var originKinds: Set<RelayAddress.Kind>?
    private var validation: Task<Void, Never>?
    private(set) var challenge: HTTPLoginChallenge?
    private var suspended = false
    var response: ((HTTPURLResponse) -> Bool)?
    var data: ((Data) -> Void)?
    var completed: ((Error?) -> Void)?

    init(request: URLRequest, credentials: HTTPLoginCredentials?, origin: URL? = nil, originKinds: Set<RelayAddress.Kind>? = nil) {
        self.credentials = credentials
        self.target = request.url; self.originKinds = originKinds
        self.origin = origin ?? request.url ?? URL(string: "https://invalid.invalid/")!
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 24 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        task = session.dataTask(with: request)
    }

    func start() {
        validation = Task { [weak self] in
            guard let self, let target else { return }
            do {
                let origins: Set<RelayAddress.Kind>
                if let originKinds { origins = originKinds }
                else { origins = try await RelayAddress.resolvedKinds(origin); originKinds = origins }
                let destinations = try await RelayAddress.resolvedKinds(target)
                try Task.checkCancellation()
                guard RelayAddress.permits(destinations, from: origins) else { throw HTTPLoginFailure.invalidPlaylist }
                task?.resume()
            } catch {
                let callback = completed
                cancel()
                callback?(error)
            }
        }
    }
    func pause() { if !suspended { suspended = true; task?.suspend() } }
    func resume() { if suspended { suspended = false; task?.resume() } }
    func cancel() {
        validation?.cancel(); validation = nil
        response = nil; data = nil; completed = nil
        task?.cancel(); session?.invalidateAndCancel()
        task = nil; session = nil
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               didReceive challenge: URLAuthenticationChallenge,
                               completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Task { @MainActor in
            let space = challenge.protectionSpace
            if let login = HTTPLoginChallenge(space) {
                self.challenge = login
                if let credentials, credentials.challenge.matches(space), challenge.previousFailureCount == 0 {
                    completionHandler(.useCredential, URLCredential(user: credentials.username,
                        password: credentials.password, persistence: .none))
                } else { completionHandler(.cancelAuthenticationChallenge, nil) }
            } else if space.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Redirects must authenticate again at their destination. Never follow
        // a TLS-to-cleartext downgrade or a URL carrying embedded credentials.
        Task { @MainActor in
            let source = origin
            guard let old = response.url, let next = request.url,
                  ["http", "https"].contains(next.scheme?.lowercased() ?? ""),
                  next.user == nil, next.password == nil,
                  !(old.scheme == "https" && next.scheme != "https"),
                  RelayAddress.allows(next, from: source),
                  let origins = self.originKinds,
                  let destinations = try? await RelayAddress.resolvedKinds(next),
                  RelayAddress.permits(destinations, from: origins), !Task.isCancelled,
                  self.task != nil else { completionHandler(nil); return }
            var safe = request
            // A redirect can also enter a different realm on the same origin.
            safe.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(safe)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                               didReceive response: URLResponse,
                               completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        Task { @MainActor in
            guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
            completionHandler(self.response?(http) == true ? .allow : .cancel)
        }
    }
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Waiting happens only on this transfer's delegate worker, never on the
        // main thread. At most one callback's data is handed to the main actor.
        let delivered = DispatchSemaphore(value: 0)
        Task { @MainActor [weak self] in
            defer { delivered.signal() }
            guard let self else { return }
            for offset in stride(from: 0, to: data.count, by: 64 * 1024) {
                while self.suspended, self.task != nil {
                    try? await Task.sleep(for: .milliseconds(2))
                }
                guard self.task != nil, let receive = self.data else { return }
                receive(data.subdata(in: offset..<min(data.count, offset + 64 * 1024)))
            }
        }
        delivered.wait()
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            let callback = completed
            response = nil; data = nil; completed = nil
            self.task = nil; self.session = nil
            session.finishTasksAndInvalidate()
            callback?(error)
        }
    }
}

public enum HTTPAuthentication {
    /// Header-only GET also works with servers that don't authenticate HEAD.
    /// A nil challenge means the ordinary source path remains unchanged.
    @MainActor
    public static func challenge(for url: URL, credentials: HTTPLoginCredentials? = nil) async throws -> HTTPLoginChallenge? {
        guard !url.isFileURL else { return nil }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 5
        let transfer = HTTPMediaTransfer(request: request, credentials: credentials)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                var received = false
                transfer.response = { response in
                    received = true
                    if response.statusCode == 401 {
                        let advertised = response.value(forHTTPHeaderField: "WWW-Authenticate")?.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: advertised?.isEmpty == false ? HTTPLoginFailure.unsupported : HTTPLoginFailure.accessDenied)
                    }
                    else { continuation.resume(returning: nil) }
                    return false // Don't fetch the media body during detection.
                }
                transfer.completed = { error in
                    guard !received else { return }
                    if let challenge = transfer.challenge { continuation.resume(returning: challenge) }
                    else { continuation.resume(throwing: error ?? HTTPLoginFailure.unavailable) }
                }
                transfer.start()
            }
        } onCancel: {
            // Preserve the completion callback so cancellation resumes the waiter.
            Task { @MainActor in transfer.sessionCancel() }
        }
    }
}

extension HTTPMediaTransfer {
    func sessionCancel() { validation?.cancel(); task?.cancel(); session?.invalidateAndCancel() }
}
