import Foundation

/// Compressed input bytes only. A preparation session shares range responses
/// across probes, chunk jobs and muxing. Never maps decoded pixels or stores URLs
/// in filenames. Demand plus two blocks of look-ahead have a fixed RAM ceiling.
actor PreparationInputCache {
    nonisolated let size: Int64
    nonisolated let mime: String
    nonisolated let validator: String
    nonisolated let validatorHeader: String
    private let url: URL
    private let headers: [String: String]
    private let blockBytes = 512 * 1024
    private let maximumBlocks = 16
    private var blocks: [Int64: Data] = [:]
    private var order: [Int64] = []
    private struct Load { let id: UUID; let task: Task<Data, Error> }
    private var loads: [Int64: Load] = [:]
    private var stopped = false
    private init(url: URL, headers: [String: String], size: Int64, mime: String, validator: String, validatorHeader: String) {
        self.url = url; self.headers = headers; self.size = size; self.mime = mime; self.validator = validator; self.validatorHeader = validatorHeader
    }
    static func open(url: URL, headers: [String: String]) async throws -> PreparationInputCache {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range"); request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await ChunkedBody.fetch(request, maximum: 1, timeout: 5, resourceTimeout: 8, redirect: { _, _ in nil })
        guard response.statusCode == 206, data.count == 1,
              let range = response.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes 0-0/"),
              let size = Int64(range.dropFirst(10)), size > 0,
              !(response.mimeType?.lowercased().contains("mpegurl") ?? false) else { throw PreparationFailure.unsupported }
        let strongETag = response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
        guard let validator = strongETag ?? response.value(forHTTPHeaderField: "Last-Modified"),
              !validator.contains("\r"), !validator.contains("\n") else { throw PreparationFailure.unsupported }
        return PreparationInputCache(url: url, headers: headers, size: size, mime: response.mimeType ?? "application/octet-stream", validator: validator, validatorHeader: strongETag == nil ? "Last-Modified" : "ETag")
    }
    private func load(_ index: Int64) throws -> Load {
        if let load = loads[index] { return load }
        guard !stopped, index >= 0, index * Int64(blockBytes) < size else { throw CancellationError() }
        let offset = index * Int64(blockBytes), count = Int(min(Int64(blockBytes), size - offset))
        let url = url, headers = headers, size = size, validator = validator, validatorHeader = validatorHeader, id = UUID()
        let task = Task<Data, Error> {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
            let (data, response) = try await ChunkedBody.fetch(request, maximum: count, timeout: 15, resourceTimeout: 30, redirect: { _, _ in nil })
            guard response.statusCode == 206, data.count == count,
                  response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(offset + Int64(count) - 1)/\(size)",
                  response.value(forHTTPHeaderField: validatorHeader) == validator else {
                throw PreparationFailure.unsupported
            }
            return data
        }
        let result = Load(id: id, task: task); loads[index] = result; return result
    }
    private func remember(_ data: Data, index: Int64) {
        blocks[index] = data
        order.removeAll { $0 == index }; order.append(index)
        while order.count > maximumBlocks { blocks[order.removeFirst()] = nil }
    }
    private func resolve(_ index: Int64, job: Load) async throws -> Data {
        do {
            let data = try await job.task.value
            guard !stopped else { throw CancellationError() }
            if loads[index]?.id == job.id { loads[index] = nil; remember(data, index: index) }
            return data
        } catch {
            if loads[index]?.id == job.id { loads[index] = nil }
            throw error
        }
    }
    func read(offset: Int64, maximum: Int) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped, offset >= 0, offset < size, maximum > 0 else { throw PreparationFailure.unsupported }
        let index = offset / Int64(blockBytes)
        // Never cancel another consumer's demand when seeking. Await one bounded
        // transfer before starting another; speculative work only uses free slots.
        while blocks[index] == nil && loads[index] == nil && loads.count >= 4 {
            guard let first = loads.first else { break }
            _ = try? await resolve(first.key, job: first.value)
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
        }
        let data: Data
        if let existing = blocks[index] { data = existing }
        else { data = try await resolve(index, job: load(index)) }
        try Task.checkCancellation()
        remember(data, index: index)
        for ahead in 1...2 where index + Int64(ahead) <= (size - 1) / Int64(blockBytes) {
            let next = index + Int64(ahead)
            if blocks[next] == nil && loads[next] == nil && loads.count < 4 { _ = try load(next) }
        }
        let local = Int(offset % Int64(blockBytes)), count = min(maximum, data.count - local)
        guard count > 0 else { throw PreparationFailure.failed }
        return data.subdata(in: local..<local + count)
    }
    func stop() { stopped = true; loads.values.forEach { $0.task.cancel() }; loads.removeAll(); blocks.removeAll(); order.removeAll() }
}
