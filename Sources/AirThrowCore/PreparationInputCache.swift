import Foundation

/// Compressed input bytes only. A preparation session shares range responses
/// across probes, chunk jobs and muxing. Never maps decoded pixels or stores URLs
/// in filenames. Demand plus two blocks of look-ahead have a fixed RAM ceiling.
actor PreparationInputCache {
    static let metadataHeader = "x-airthrow-metadata"
    nonisolated let size: Int64
    nonisolated let mime: String
    nonisolated let validator: String?
    nonisolated let validatorHeader: String?
    private let url: URL
    private let headers: [String: String]
    // Small blocks on small inputs; larger bounded transfers amortize NAS RTT
    // on ordinary films. Retain enough compressed input for probing and muxing
    // the same high-bitrate interval without evicting its opening bytes.
    private let blockBytes: Int
    private let maximumBlocks = 32
    private var blocks: [Int64: Data] = [:]
    private var order: [Int64] = []
    private struct Load { let id: UUID; let task: Task<Data, Error> }
    private var loads: [Int64: Load] = [:]
    // Without validators, retain only the current block of each HTTP response.
    // Never reuse those bytes for a later probe, seek or preparation job.
    private var scopedBlocks: [UUID: (index: Int64, data: Data)] = [:]
    private var scopeOrder: [UUID] = []
    // A nested relay allows four connections per peer. Share one budget across
    // block fetches and metadata, reserving a slot for short index reads and
    // leaving another connection available to an overlapping native probe.
    private let maximumTransfers = 3
    private let maximumBlockLoads = 2
    private var directReads = 0
    private var stopped = false
    private init(url: URL, headers: [String: String], size: Int64, mime: String, validator: String?, validatorHeader: String?) {
        self.url = url; self.headers = headers; self.size = size; self.mime = mime; self.validator = validator; self.validatorHeader = validatorHeader
        blockBytes = size >= 32 * 1024 * 1024 ? 2 * 1024 * 1024 : 512 * 1024
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
        let validator = strongETag ?? response.value(forHTTPHeaderField: "Last-Modified")
        guard validator.map({ !$0.contains("\r") && !$0.contains("\n") }) ?? true else { throw PreparationFailure.unsupported }
        // Some servers acknowledge 0-0 but ignore other ranges. Check a
        // distant byte before committing a relay response to chunked reads.
        if size > 1 {
            request.setValue("bytes=\(size - 1)-\(size - 1)", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
            let (tail, tailResponse) = try await ChunkedBody.fetch(request, maximum: 1, timeout: 5, resourceTimeout: 8, redirect: { _, _ in nil })
            guard tail.count == 1, tailResponse.statusCode == 206,
                  tailResponse.value(forHTTPHeaderField: "Content-Range") == "bytes \(size - 1)-\(size - 1)/\(size)" else { throw PreparationFailure.unsupported }
        }
        return PreparationInputCache(url: url, headers: headers, size: size, mime: response.mimeType ?? "application/octet-stream", validator: validator, validatorHeader: validator == nil ? nil : strongETag == nil ? "Last-Modified" : "ETag")
    }
    private func load(_ index: Int64) throws -> Load {
        if let load = loads[index] { return load }
        guard !stopped, index >= 0, index * Int64(blockBytes) < size else { throw CancellationError() }
        let offset = index * Int64(blockBytes), count = Int(min(Int64(blockBytes), size - offset))
        let url = url, headers = headers, size = size, validator = validator, validatorHeader = validatorHeader, id = UUID()
        let task = Task<Data, Error> {
            try await Self.fetch(url: url, headers: headers, size: size, validator: validator,
                                 validatorHeader: validatorHeader, offset: offset, count: count)
        }
        let result = Load(id: id, task: task); loads[index] = result; return result
    }
    private static func fetch(url: URL, headers: [String: String], size: Int64,
                              validator: String?, validatorHeader: String?, offset: Int64, count: Int) async throws -> Data {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
            let (data, response) = try await ChunkedBody.fetch(request, maximum: count, timeout: 15, resourceTimeout: 30, redirect: { _, _ in nil })
            guard response.statusCode == 206, data.count == count,
                  response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(offset + Int64(count) - 1)/\(size)",
                  (validatorHeader.map { response.value(forHTTPHeaderField: $0) == validator } ?? true) else {
                throw PreparationFailure.unsupported
            }
            return data
    }

    private func remember(_ data: Data, index: Int64) {
        guard validator != nil else { return }
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
    /// Container tables can exceed one small range. Keep their exact span in
    /// the reserved slot instead of expanding them to a speculative media block.
    func readMetadata(offset: Int64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped, offset >= 0, count > 0, count <= 32 * 1024 * 1024,
              offset <= size - Int64(count) else { throw PreparationFailure.unsupported }
        let index = offset / Int64(blockBytes), local = Int(offset % Int64(blockBytes))
        if let data = blocks[index], count <= data.count - local {
            return data.subdata(in: local..<local + count)
        }
        while directReads + loads.count >= maximumTransfers {
            try await Task.sleep(for: .milliseconds(2))
            guard !stopped else { throw CancellationError() }
        }
        directReads += 1
        defer { directReads -= 1 }
        let data = try await Self.fetch(url: url, headers: headers, size: size, validator: validator,
                                       validatorHeader: validatorHeader, offset: offset, count: count)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        return data
    }
    func read(offset: Int64, maximum: Int, scope: UUID? = nil, requestEnd: Int64? = nil, requestStart: Int64? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard !stopped, offset >= 0, offset < size, maximum > 0 else { throw PreparationFailure.unsupported }
        let index = offset / Int64(blockBytes)
        // Metadata probes request a few bytes, not a movie-sized response.
        // Do not expand each indexed cue/keyframe read to a media-block transfer.
        let remaining = min(size - 1, requestEnd ?? (size - 1)) - offset + 1
        guard remaining > 0 else { throw PreparationFailure.unsupported }
        // Classify the original HTTP response, not its shrinking tail: otherwise
        // every 64 KiB read near EOF becomes another NAS round trip.
        let requested = min(size - 1, requestEnd ?? (size - 1)) - (requestStart ?? offset) + 1
        if requested <= 64 * 1024 && blocks[index] == nil && scope.flatMap({ scopedBlocks[$0]?.index }) != index {
            while directReads + loads.count >= maximumTransfers {
                try await Task.sleep(for: .milliseconds(2))
                guard !stopped else { throw CancellationError() }
            }
            directReads += 1
            defer { directReads -= 1 }
            let data = try await Self.fetch(url: url, headers: headers, size: size, validator: validator,
                                           validatorHeader: validatorHeader, offset: offset, count: min(maximum, Int(remaining)))
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            return data
        }
        // Never cancel another consumer's demand when seeking. Await one bounded
        // transfer before starting another; speculative work only uses free slots.
        while blocks[index] == nil && loads[index] == nil
                && (loads.count >= maximumBlockLoads || loads.count + directReads >= maximumTransfers) {
            if let first = loads.first { _ = try? await resolve(first.key, job: first.value) }
            else { try await Task.sleep(for: .milliseconds(2)) }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
        }
        let scoped = scope.flatMap { scopedBlocks[$0] }
        let existing = validator == nil ? (scoped?.index == index ? scoped?.data : nil) : blocks[index]
        let data: Data
        if let existing { data = existing }
        else { data = try await resolve(index, job: load(index)) }
        try Task.checkCancellation()
        remember(data, index: index)
        if validator == nil, let scope {
            scopedBlocks[scope] = (index, data)
            scopeOrder.removeAll { $0 == scope }; scopeOrder.append(scope)
            while scopeOrder.count > maximumBlocks { scopedBlocks[scopeOrder.removeFirst()] = nil }
        }
        for ahead in 1...2 where validator != nil && index + Int64(ahead) <= (size - 1) / Int64(blockBytes) {
            let next = index + Int64(ahead)
            if blocks[next] == nil && loads[next] == nil && loads.count < maximumBlockLoads && loads.count + directReads < maximumTransfers { _ = try load(next) }
        }
        let local = Int(offset % Int64(blockBytes)), count = min(maximum, data.count - local)
        guard count > 0 else { throw PreparationFailure.failed }
        return data.subdata(in: local..<local + count)
    }
    func release(scope: UUID) { scopedBlocks[scope] = nil; scopeOrder.removeAll { $0 == scope } }
    func stop() { scopedBlocks.removeAll(); scopeOrder.removeAll(); stopped = true; loads.values.forEach { $0.task.cancel() }; loads.removeAll(); blocks.removeAll(); order.removeAll() }
}
