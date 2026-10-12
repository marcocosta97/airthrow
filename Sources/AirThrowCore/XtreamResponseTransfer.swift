import Foundation

/// Collect response chunks on a serial delegate queue, outside the UI actor.
/// All mutable state is protected because Swift task cancellation can race callbacks.
final class XtreamResponseTransfer: XtreamRedirectDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var body = Data()
    private var finished = false
    private var cancelled = false

    func load(_ url: URL) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Data = try await withCheckedThrowingContinuation { continuation in
                let task = lock.withLock { () -> URLSessionDataTask? in
                    guard !cancelled else { return nil }
                    self.continuation = continuation
                    let config = URLSessionConfiguration.ephemeral
                    config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.urlCache = nil
                    config.httpShouldSetCookies = false
                    config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 90
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                    self.session = session
                    let task = session.dataTask(with: url)
                    self.task = task
                    return task
                }
                if let task { task.resume() }
                else { continuation.resume(throwing: CancellationError()) }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !lock.withLock({ finished }) else { completionHandler(.cancel); return }
        let failure: XtreamFailure?
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { failure = .rejectedAccount }
            else if http.statusCode != 200 { failure = .httpStatus(http.statusCode) }
            else if response.expectedContentLength > XtreamClient.maximumResponseBytes { failure = .tooLarge }
            else { failure = nil }
        } else { failure = .invalidResponse }
        if let failure {
            completionHandler(.cancel)
            finish(.failure(failure))
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock { () -> Bool in
            guard !finished else { return false }
            // Enforce received/decoded bytes as well as Content-Length, including
            // compressed, chunked and lengthless responses.
            guard data.count <= XtreamClient.maximumResponseBytes - body.count else { return true }
            body.append(data)
            return false
        }
        if tooLarge { finish(.failure(XtreamFailure.tooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else {
            let data = lock.withLock { body }
            finish(.success(data))
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<Data, Error>?, URLSession?) in
            guard !finished else { return (nil, nil) }
            finished = true
            let state = (continuation, session)
            continuation = nil; session = nil; task = nil; body = Data()
            return state
        }
        state.1?.invalidateAndCancel()
        state.0?.resume(with: result)
    }
}
