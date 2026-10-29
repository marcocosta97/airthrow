import Foundation

enum RemuxIndexFailure: Error {
    case deadline, readBudget, byteRanges, restartPoint
    var preparationFailure: PreparationFailure {
        switch self {
        case .deadline: .stalled
        case .readBudget: .limit
        case .byteRanges, .restartPoint: .unsupported
        }
    }
    var message: String {
        switch self {
        case .deadline: "Reading the remote seek index timed out."
        case .readBudget: "The remote seek index exceeded the bounded metadata-read limit."
        case .byteRanges: "The server did not return the requested media byte range."
        case .restartPoint: "This video segment has no supported random-access frame."
        }
    }
}

/// Read container indexes and small decoder-refresh headers, never scan the
/// remote media payload. Byte-range support and all memory/I/O bounds are real
/// response checks. The reader is only alive during preparation's index step.
actor RemuxRangeReader {
    let size: Int64
    private let url: URL
    private let headers: [String: String]
    private let deadline = ContinuousClock().now.advanced(by: .seconds(25))
    private var used = 0
    private var blocks: [Int64: Data] = [:]
    private var loads: [Int64: BlockLoad] = [:]
    private final class BlockLoad {
        var waiters: [CheckedContinuation<Data, Error>] = []
    }
    private init(url: URL, headers: [String: String], size: Int64) {
        self.url = url; self.headers = headers; self.size = size
    }
    static func open(_ url: URL, headers: [String: String]) async throws -> RemuxRangeReader {
        if url.isFileURL {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard let size, size.int64Value > 0 else { throw PreparationFailure.unsupported }
            return RemuxRangeReader(url: url, headers: [:], size: size.int64Value)
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") {
            request.setValue("1", forHTTPHeaderField: PreparationInputCache.metadataHeader)
        }
        let (_, response): (Data, HTTPURLResponse)
        do { (_, response) = try await ChunkedBody.fetch(request, maximum: 1, timeout: 5, resourceTimeout: 8) }
        catch is ChunkedBody.Overflow { throw RemuxIndexFailure.byteRanges }
        try Task.checkCancellation()
        guard response.statusCode == 206,
              let range = response.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes 0-0/"),
              let size = Int64(range.dropFirst(10)), size > 0 else { throw RemuxIndexFailure.byteRanges }
        return RemuxRangeReader(url: url, headers: headers, size: size)
    }
    func read(_ offset: Int64, _ count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard ContinuousClock().now < deadline else { throw RemuxIndexFailure.deadline }
        guard count > 0, count <= 32 * 1024 * 1024, offset >= 0, offset <= size - Int64(count) else { throw PreparationFailure.unsupported }
        if url.isFileURL {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else { throw PreparationFailure.unsupported }
            return data
        }
        let block = offset / 4096 * 4096
        if count <= 4096, offset + Int64(count) <= block + 4096 {
            let data = try await blockBytes(block)
            return data.subdata(in: Int(offset - block)..<Int(offset - block) + count)
        }
        return try await fetch(offset, count)
    }
    /// Concurrent reads of one 4 KB block share a single range request.
    private func blockBytes(_ block: Int64) async throws -> Data {
        if let data = blocks[block] { return data }
        if let load = loads[block] {
            return try await withCheckedThrowingContinuation { load.waiters.append($0) }
        }
        let load = BlockLoad()
        loads[block] = load
        do {
            let data = try await fetch(block, Int(min(4096, size - block)))
            if blocks.count < 256 { blocks[block] = data }
            loads[block] = nil
            load.waiters.forEach { $0.resume(returning: data) }
            return data
        } catch {
            loads[block] = nil
            load.waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }
    private func fetch(_ offset: Int64, _ count: Int) async throws -> Data {
        used += count
        guard used <= 64 * 1024 * 1024 else { throw RemuxIndexFailure.readBudget }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let end = offset + Int64(count) - 1
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") {
            request.setValue("1", forHTTPHeaderField: PreparationInputCache.metadataHeader)
        }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await ChunkedBody.fetch(request, maximum: count, timeout: 5, resourceTimeout: 8) }
        catch is ChunkedBody.Overflow { throw RemuxIndexFailure.byteRanges }
        guard response.statusCode == 206,
              response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(size)",
              response.expectedContentLength == -1 || response.expectedContentLength == count,
              data.count == count else { throw RemuxIndexFailure.byteRanges }
        guard ContinuousClock().now < deadline else { throw RemuxIndexFailure.deadline }
        return data
    }
}

/// Bounded parsers for seekable file containers. A container's sync/cue entries
/// alone are insufficient: selected cuts need a supported AVC/HEVC recovery point.
enum RemoteRemuxIndex {
    struct Point: Sendable {
        let pts: Int64; let dts: Int64?; let offset: Int64; let size: Int; let block: Bool
        var track: UInt64? = nil
        var relative: Int64? = nil
        var followingPTS: Int64? = nil
        var precedingPTS: Int64? = nil
    }
    static func timeline(url: URL, headers: [String: String], stream: Int, codec: String,
                         videoTimeBase: String?, audioTimeBase: String?, sourceStart: Double,
                         duration: Double, matroska: Bool, reorderDelay: Bool) async throws -> RemuxTimeline {
        let reader = try await RemuxRangeReader.open(url, headers: headers)
        let vtb = try RemuxTimeline.timeBase(videoTimeBase)
        let atb = try RemuxTimeline.timeBase(audioTimeBase)
        let points = matroska ? try await mkv(reader, stream: stream, timeBase: vtb)
                             : try await mp4(reader, stream: stream, timeBase: vtb)
        guard !points.isEmpty else { throw PreparationFailure.unsupported }
        // Unsupported sync samples are skipped, as the local packet scan does.
        // The next sample is still eligible, so one open GOP does not abandon
        // the cache. Reads stay in small parallel batches.
        var accepted: [Point] = []
        var verifiedPrefix = 0
        var index = 0
        while index < points.count, accepted.count <= 2401 {
            // Read the container index up front, but do not fetch refresh-frame
            // headers throughout a whole movie before starting its first chunk.
            if accepted.count >= 3 {
                verifiedPrefix = accepted.count
                for point in points[index...] {
                    if let last = accepted.last, Double(point.pts - last.pts) * vtb < 6 { continue }
                    accepted.append(point)
                    guard accepted.count <= 2401 else { throw PreparationFailure.unsupported }
                }
                break
            }
            var batch: [(offset: Int, point: Point)] = []
            var scan = index
            var lastPTS = accepted.last?.pts
            // Leave one of the relay's four per-peer connections free for
            // probe teardown or a simultaneous player request.
            while scan < points.count, batch.count < 3 {
                let point = points[scan]
                scan += 1
                if let lastPTS, Double(point.pts - lastPTS) * vtb < 6 { continue }
                batch.append((offset: scan - 1, point: point))
                lastPTS = point.pts
            }
            if batch.isEmpty { break }
            let flags = try await refreshFlags(reader, points: batch.map(\.point), codec: codec)
            guard let failed = flags.firstIndex(of: false) else {
                accepted.append(contentsOf: batch.map(\.point))
                index = scan
                continue
            }
            accepted.append(contentsOf: batch.prefix(failed).map(\.point))
            index = batch[failed].offset + 1
        }
        guard !accepted.isEmpty, accepted.count <= 2401 else { throw PreparationFailure.unsupported }
        if verifiedPrefix == 0 { verifiedPrefix = accepted.count }
        var timeline = try RemuxTimeline(cuts: accepted.map {
                                     var cut = RemuxTimeline.Cut(pts: $0.pts, dts: $0.dts)
                                     cut.followingKeyframe = $0.followingPTS
                                     cut.precedingKeyframe = $0.precedingPTS
                                     return cut
                                 },
                                 videoTimeBase: vtb, audioTimeBase: atb, sourceStart: sourceStart,
                                 duration: duration, usesSyncPacketIntervals: matroska,
                                 needsDecodePreroll: matroska && reorderDelay)
        timeline.remoteValidation = Validation(url: url, headers: headers, points: accepted,
                                               codec: codec, verifiedPrefix: verifiedPrefix)
        return timeline
    }

    /// A fresh bounded reader verifies each requested interval before muxing.
    /// Validated cuts are reusable across seeks; the startup reader's deadline
    /// must never expire while a viewer is watching an already prepared chunk.
    actor Validation {
        private let url: URL
        private let headers: [String: String]
        private let points: [Point]
        private let codec: String
        private var verified: Set<Int>
        init(url: URL, headers: [String: String], points: [Point], codec: String, verifiedPrefix: Int) {
            self.url = url; self.headers = headers; self.points = points; self.codec = codec
            verified = Set(0..<verifiedPrefix)
        }
        func validate(index: Int) async throws {
            try Task.checkCancellation()
            guard points.indices.contains(index) else { throw PreparationFailure.unsupported }
            let needed = [index, index + 1].filter { points.indices.contains($0) && !verified.contains($0) }
            guard !needed.isEmpty else { return }
            let reader = try await RemuxRangeReader.open(url, headers: headers)
            let flags = try await RemoteRemuxIndex.refreshFlags(reader, points: needed.map { points[$0] }, codec: codec)
            try Task.checkCancellation()
            guard flags.allSatisfy({ $0 }) else { throw RemuxIndexFailure.restartPoint }
            verified.formUnion(needed)
        }
    }

    private static func refreshFlags(_ reader: RemuxRangeReader, points: [Point], codec: String) async throws -> [Bool] {
        try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
            for (index, point) in points.enumerated() {
                group.addTask { (index, try await isDecoderRefresh(reader, point: point, codec: codec)) }
            }
            var flags = [Bool](repeating: false, count: points.count)
            for try await (index, flag) in group { flags[index] = flag }
            return flags
        }
    }

    private static func isDecoderRefresh(_ reader: RemuxRangeReader, point: Point, codec: String) async throws -> Bool {
        let location = point.block ? try await blockLocation(reader, point: point) : (point.offset, point.size)
        var data = try await reader.read(location.0, min(location.1, 4096))
        if point.block {
            guard let first = data.first, first != 0 else { throw PreparationFailure.unsupported }
            let width = first.leadingZeroBitCount + 1
            guard width <= 8, data.count > width + 3, data[width + 2] & 0x06 == 0 else {
                throw PreparationFailure.unsupported
            }
            data = Data(data.dropFirst(width + 3))
        }
        return RemuxTimeline.isRefreshPoint(data, codec: codec)
    }

    private struct Box { let type: String; let payload: Data }
    private static func boxes(_ data: Data) throws -> [Box] {
        var offset = 0, result: [Box] = []
        while offset < data.count {
            guard offset + 8 <= data.count, result.count < 100_000 else { throw PreparationFailure.unsupported }
            var size = try data.uint(offset, 4); var header = 8
            if size == 1 { size = try data.uint(offset + 8, 8); header = 16 }
            if size == 0 { size = UInt64(data.count - offset) }
            guard size >= header, size <= data.count - offset else { throw PreparationFailure.unsupported }
            result.append(Box(type: String(decoding: data[offset + 4..<offset + 8], as: UTF8.self),
                              payload: data.subdata(in: offset + header..<offset + Int(size))))
            offset += Int(size)
        }
        return result
    }
    private static func child(_ data: Data, _ type: String) throws -> Data {
        guard let box = try boxes(data).first(where: { $0.type == type }) else { throw PreparationFailure.unsupported }
        return box.payload
    }
    private static func table(_ data: Data, width: Int) throws -> [[UInt64]] {
        let count = Int(try data.uint(4, 4))
        guard count <= 1_000_000, 8 + count * width * 4 == data.count else { throw PreparationFailure.unsupported }
        return try (0..<count).map { row in try (0..<width).map { try data.uint(8 + (row * width + $0) * 4, 4) } }
    }
    private static func mp4(_ reader: RemuxRangeReader, stream: Int, timeBase: Double) async throws -> [Point] {
        var offset: Int64 = 0, movie: Data?
        for _ in 0..<4096 {
            guard offset <= reader.size - 8 else { break }
            let header = try await reader.read(offset, Int(min(16, reader.size - offset)))
            var size = try header.uint(0, 4); var headerSize = 8
            if size == 1 { size = try header.uint(8, 8); headerSize = 16 }
            if size == 0 { size = UInt64(reader.size - offset) }
            guard size >= headerSize, size <= UInt64(reader.size - offset) else { throw PreparationFailure.unsupported }
            if String(decoding: header[4..<8], as: UTF8.self) == "moov" {
                guard size <= 32 * 1024 * 1024 else { throw PreparationFailure.unsupported }
                movie = try await reader.read(offset + Int64(headerSize), Int(size) - headerSize); break
            }
            offset += Int64(size)
        }
        guard let movie else { throw PreparationFailure.unsupported }
        let tracks = try boxes(movie).filter { $0.type == "trak" }
        guard tracks.indices.contains(stream) else { throw PreparationFailure.unsupported }
        let track = tracks[stream].payload
        let media = try child(track, "mdia")
        let handler = try child(media, "hdlr")
        guard handler.count >= 12, String(decoding: handler[8..<12], as: UTF8.self) == "vide" else { throw PreparationFailure.unsupported }
        let mdhd = try child(media, "mdhd")
        let timescale = Double(try mdhd.uint(mdhd.first == 1 ? 20 : 12, 4))
        guard timescale > 0 else { throw PreparationFailure.unsupported }
        let samples = try child(child(media, "minf"), "stbl")
        let sz = try child(samples, "stsz")
        let fixed = try sz.uint(4, 4), count = Int(try sz.uint(8, 4))
        guard count > 0, count <= 1_000_000, fixed > 0 || sz.count == 12 + count * 4 else { throw PreparationFailure.unsupported }
        let sizes = try (0..<count).map { fixed > 0 ? fixed : try sz.uint(12 + $0 * 4, 4) }
        var prefix: [UInt64] = [0]
        for size in sizes {
            guard size > 0, size <= reader.size, prefix.last! <= UInt64(reader.size) - size else { throw PreparationFailure.unsupported }
            prefix.append(prefix.last! + size)
        }
        var dts: [Int64] = [], current: Int64 = 0
        for row in try table(child(samples, "stts"), width: 2) {
            guard row[0] > 0, row[0] <= count - dts.count, row[1] > 0, row[1] <= 1_000_000_000 else { throw PreparationFailure.unsupported }
            for _ in 0..<row[0] { dts.append(current); current += Int64(row[1]) }
        }
        guard dts.count == count else { throw PreparationFailure.unsupported }
        var pts = dts
        if let ctts = try boxes(samples).first(where: { $0.type == "ctts" })?.payload {
            var sample = 0
            for row in try table(ctts, width: 2) {
                guard row[0] <= count - sample else { throw PreparationFailure.unsupported }
                let shift = ctts.first == 1 ? Int64(Int32(bitPattern: UInt32(row[1]))) : Int64(row[1])
                for _ in 0..<row[0] { pts[sample] += shift; sample += 1 }
            }
            guard sample == count else { throw PreparationFailure.unsupported }
        }
        var shift: Double = 0
        if let edits = try boxes(track).first(where: { $0.type == "edts" })?.payload {
            let elst = try child(edits, "elst"), version = elst.first == 1
            let mvhd = try child(movie, "mvhd")
            let movieScale = Double(try mvhd.uint(mvhd.first == 1 ? 20 : 12, 4))
            guard movieScale > 0 else { throw PreparationFailure.unsupported }
            let entries = Int(try elst.uint(4, 4)), width = version ? 20 : 12
            guard (1...8).contains(entries), elst.count == 8 + entries * width else { throw PreparationFailure.unsupported }
            var positive = false
            for entry in 0..<entries {
                let start = 8 + entry * width
                let length = Double(try elst.uint(start, version ? 8 : 4))
                let raw = try elst.uint(start + (version ? 8 : 4), version ? 8 : 4)
                let mediaTime = version ? Int64(bitPattern: raw) : Int64(Int32(bitPattern: UInt32(raw)))
                guard try elst.uint(start + width - 4, 4) == 0x00010000 else { throw PreparationFailure.unsupported }
                if mediaTime == -1, !positive { shift += length / movieScale }
                else {
                    guard !positive, mediaTime >= 0 else { throw PreparationFailure.unsupported }
                    shift -= Double(mediaTime) / timescale; positive = true
                }
            }
        }
        let sampleBoxes = try boxes(samples)
        let offsets: [UInt64]
        if let co64 = sampleBoxes.first(where: { $0.type == "co64" })?.payload {
            let n = Int(try co64.uint(4, 4))
            guard n <= count, co64.count == 8 + n * 8 else { throw PreparationFailure.unsupported }
            offsets = try (0..<n).map { try co64.uint(8 + $0 * 8, 8) }
        } else { offsets = try table(child(samples, "stco"), width: 1).map { $0[0] } }
        let chunks = try table(child(samples, "stsc"), width: 3)
        guard chunks.first?.first == 1 else { throw PreparationFailure.unsupported }
        var positions = [UInt64](repeating: 0, count: count), sample = 0, row = 0
        for chunk in offsets.indices {
            if row + 1 < chunks.count, chunks[row + 1][0] == chunk + 1 { row += 1 }
            let n = chunks[row][1]
            guard n > 0, n <= count - sample, offsets[chunk] <= UInt64(reader.size) else { throw PreparationFailure.unsupported }
            for i in 0..<Int(n) {
                let delta = prefix[sample + i] - prefix[sample]
                guard delta <= UInt64(reader.size) - offsets[chunk] else { throw PreparationFailure.unsupported }
                positions[sample + i] = offsets[chunk] + delta
            }
            sample += Int(n)
        }
        guard sample == count else { throw PreparationFailure.unsupported }
        let sync = try sampleBoxes.first(where: { $0.type == "stss" }).map { try table($0.payload, width: 1).map { Int($0[0]) - 1 } } ?? Array(0..<count)
        var result: [Point] = []
        for index in sync {
            guard (0..<count).contains(index), positions[index] <= UInt64(reader.size), sizes[index] <= UInt64(reader.size) - positions[index] else { throw PreparationFailure.unsupported }
            let p = (Double(pts[index]) / timescale + shift) / timeBase
            let d = (Double(dts[index]) / timescale + shift) / timeBase
            guard abs(p) < 1e14, abs(d) < 1e14 else { throw PreparationFailure.unsupported }
            result.append(Point(pts: Int64(p.rounded()), dts: Int64(d.rounded()), offset: Int64(positions[index]), size: Int(sizes[index]), block: false))
        }
        return result
    }

    /// Subtitle packets are indexed independently of video. Reading only their
    /// BlockGroups preserves cues spanning seeks without scanning movie payloads.
    struct SubtitleIndex: Sendable {
        struct Cue: Sendable {
            let time: Double
            let duration: Double?
            let cluster: Int64
            let relative: Int64?
        }
        struct Track: Sendable { let number: UInt64; let entry: Data; let cues: [Cue] }
        let url: URL
        let headers: [String: String]
        let ebml: Data
        let info: Data
        let tracks: [Track]

        func fragment(track index: Int, start: Double, end: Double) async throws -> Data? {
            let track = tracks[index]
            let cues = track.cues.filter { $0.time < end && ($0.duration == nil || $0.time + $0.duration! > start) }
            if cues.isEmpty { return nil }
            let reader = try await RemuxRangeReader.open(url, headers: headers)
            var clusters = Data()
            for cue in cues {
                try Task.checkCancellation()
                let cluster = try await header(reader, cue.cluster)
                guard cluster.id == 0x1f43b675, cue.relative.map({ $0 >= 0 && $0 < cluster.size }) ?? true else { throw PreparationFailure.unsupported }
                var cursor = cluster.start, timestamp: Data?
                for _ in 0..<16 {
                    let child = try await header(reader, cursor)
                    if child.id == 0xe7 {
                        guard child.size <= 8 else { throw PreparationFailure.unsupported }
                        timestamp = try await reader.read(child.start, Int(child.size)); break
                    }
                    cursor = child.start + child.size
                    guard cursor < cluster.start + cluster.size else { break }
                }
                guard let timestamp else { throw PreparationFailure.unsupported }
                var group: (id: UInt64, start: Int64, size: Int64)?
                if let relative = cue.relative { group = try await header(reader, cluster.start + relative) }
                else {
                    // Older Matroska indexes omit CueRelativePosition. Walk
                    // element headers, skipping compressed video/audio bodies.
                    let scaleFields = try elements(info)
                    let scale = scaleFields.contains(where: { $0.id == 0x2ad7b1 }) ? try integer(scaleFields, 0x2ad7b1) : 1_000_000
                    let clusterTime = try timestamp.uint(0, timestamp.count)
                    cursor = cluster.start
                    for _ in 0..<4096 {
                        let child = try await header(reader, cursor)
                        guard child.start + child.size <= cluster.start + cluster.size else { throw PreparationFailure.unsupported }
                        if child.id == 0xa0 {
                            var blockOffset = child.start
                            for _ in 0..<16 {
                                let field = try await header(reader, blockOffset)
                                guard field.start + field.size <= child.start + child.size else { throw PreparationFailure.unsupported }
                                if field.id == 0xa1 {
                                    let prefix = try await reader.read(field.start, Int(min(12, field.size)))
                                    let (number, width) = try vint(prefix, 0)
                                    guard prefix.count >= width + 3 else { throw PreparationFailure.unsupported }
                                    let delta = Int16(bitPattern: UInt16(try prefix.uint(width, 2)))
                                    let time = (Double(clusterTime) + Double(delta)) * Double(scale) / 1e9
                                    if number == track.number && abs(time - cue.time) < 0.000001 { group = child }
                                    break
                                }
                                blockOffset = field.start + field.size
                                if blockOffset >= child.start + child.size { break }
                            }
                        }
                        if group != nil { break }
                        cursor = child.start + child.size
                        if cursor >= cluster.start + cluster.size { break }
                    }
                }
                guard let group, group.id == 0xa0, group.size <= 1024 * 1024,
                      group.start + group.size <= cluster.start + cluster.size else { throw PreparationFailure.unsupported }
                let body = try await reader.read(group.start, Int(group.size))
                let fields = try elements(body)
                guard let block = fields.first(where: { $0.id == 0xa1 }),
                      try vint(block.data, 0).0 == track.number else { throw PreparationFailure.unsupported }
                // Missing CueDuration is legal. Use the packet's BlockDuration
                // before deciding whether an older cue still overlaps this seek.
                let ticks = try integer(fields, 0x9b)
                let scaleFields = try elements(info)
                let scale = scaleFields.contains(where: { $0.id == 0x2ad7b1 }) ? try integer(scaleFields, 0x2ad7b1) : 1_000_000
                if cue.time + Double(ticks) * Double(scale) / 1e9 <= start { continue }
                clusters += element(0x1f43b675, element(0xe7, timestamp) + element(0xa0, body))
                guard clusters.count <= 8 * 1024 * 1024 else { throw PreparationFailure.limit }
            }
            guard !clusters.isEmpty else { return nil }
            return ebml + element(0x18538067, element(0x1549a966, info)
                + element(0x1654ae6b, element(0xae, track.entry)) + clusters)
        }
    }

    private static func element(_ id: UInt64, _ body: Data) -> Data {
        let width = max(1, (64 - id.leadingZeroBitCount + 7) / 8)
        let bytes = (0..<width).reversed().map { UInt8(truncatingIfNeeded: id >> ($0 * 8)) }
        let size = UInt64(body.count) | (1 << 56)
        return Data(bytes + (0..<8).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) }) + body
    }

    static func subtitles(url: URL, headers: [String: String], streams: [Int]) async throws -> SubtitleIndex {
        let reader = try await RemuxRangeReader.open(url, headers: headers)
        let ebml = try await header(reader, 0)
        guard ebml.id == 0x1a45dfa3, ebml.size <= 4096 else { throw PreparationFailure.unsupported }
        let prefix = try await reader.read(0, Int(ebml.start + ebml.size))
        let segment = try await header(reader, ebml.start + ebml.size)
        guard segment.id == 0x18538067 else { throw PreparationFailure.unsupported }
        var offset = segment.start, cueOffset: Int64?, tracks: Data?, info: Data?
        for _ in 0..<256 {
            let item = try await header(reader, offset)
            if item.id == 0x114d9b74 {
                guard item.size <= 1024 * 1024 else { throw PreparationFailure.unsupported }
                for seek in try elements(await reader.read(item.start, Int(item.size))) where seek.id == 0x4dbb {
                    let fields = try elements(seek.data)
                    if try integer(fields, 0x53ab) == 0x1c53bb6b {
                        let position = try integer(fields, 0x53ac)
                        guard position < UInt64(reader.size - segment.start) else { throw PreparationFailure.unsupported }
                        cueOffset = segment.start + Int64(position)
                    }
                }
            } else if item.id == 0x1654ae6b || item.id == 0x1549a966 {
                guard item.size <= 4 * 1024 * 1024 else { throw PreparationFailure.unsupported }
                let data = try await reader.read(item.start, Int(item.size))
                if item.id == 0x1654ae6b { tracks = data } else { info = data }
            } else if item.id == 0x1c53bb6b { cueOffset = offset }
            if item.id == 0x1f43b675 { break }
            offset = item.start + item.size
        }
        guard let tracks, let info, let cueOffset else { throw PreparationFailure.unsupported }
        let entries = try elements(tracks).filter { $0.id == 0xae }
        let infoFields = try elements(info)
        let scale = infoFields.contains(where: { $0.id == 0x2ad7b1 }) ? try integer(infoFields, 0x2ad7b1) : 1_000_000
        guard scale > 0 else { throw PreparationFailure.unsupported }
        let cueHeader = try await header(reader, cueOffset)
        guard cueHeader.id == 0x1c53bb6b, cueHeader.size <= 16 * 1024 * 1024 else { throw PreparationFailure.unsupported }
        let cues = try elements(await reader.read(cueHeader.start, Int(cueHeader.size)))
        var result: [SubtitleIndex.Track] = []
        for stream in streams {
            guard entries.indices.contains(stream) else { throw PreparationFailure.unsupported }
            let fields = try elements(entries[stream].data)
            guard try integer(fields, 0x83) == 17 else { throw PreparationFailure.unsupported }
            let number = try integer(fields, 0xd7)
            var locations: [SubtitleIndex.Cue] = []
            for cue in cues where cue.id == 0xbb {
                let values = try elements(cue.data)
                let time = Double(try integer(values, 0xb3)) * Double(scale) / 1e9
                for position in values where position.id == 0xb7 {
                    let location = try elements(position.data)
                    guard try integer(location, 0xf7) == number else { continue }
                    let relative = location.contains(where: { $0.id == 0xf0 }) ? try integer(location, 0xf0) : nil
                    let cluster = try integer(location, 0xf1)
                    guard cluster < UInt64(reader.size - segment.start), relative.map({ $0 < UInt64(reader.size) }) ?? true else { throw PreparationFailure.unsupported }
                    if location.contains(where: { $0.id == 0xea }), try integer(location, 0xea) != 0 { throw PreparationFailure.unsupported }
                    let duration = location.contains(where: { $0.id == 0xb2 }) ? Double(try integer(location, 0xb2)) * Double(scale) / 1e9 : nil
                    guard time.isFinite, time >= 0, time < 86_400, duration.map({ $0.isFinite && $0 >= 0 && $0 <= 86_400 }) ?? true else { throw PreparationFailure.unsupported }
                    locations.append(.init(time: time, duration: duration, cluster: segment.start + Int64(cluster), relative: relative.map(Int64.init)))
                }
            }
            guard !locations.isEmpty else { throw PreparationFailure.unsupported }
            result.append(.init(number: number, entry: entries[stream].data, cues: locations))
        }
        return SubtitleIndex(url: url, headers: headers, ebml: prefix, info: info, tracks: result)
    }

    private struct Element { let id: UInt64; let data: Data }
    private static func vint(_ data: Data, _ offset: Int, id: Bool = false) throws -> (UInt64, Int) {
        guard offset < data.count, data[offset] != 0 else { throw PreparationFailure.unsupported }
        let width = data[offset].leadingZeroBitCount + 1
        guard width <= (id ? 4 : 8), offset + width <= data.count else { throw PreparationFailure.unsupported }
        let raw = try data.uint(offset, width)
        return (id ? raw : raw & ((UInt64(1) << (width * 7)) - 1), width)
    }
    private static func elements(_ data: Data) throws -> [Element] {
        var offset = 0, result: [Element] = []
        while offset < data.count {
            let (id, iw) = try vint(data, offset, id: true), (size, sw) = try vint(data, offset + iw)
            let start = offset + iw + sw
            guard size <= data.count - start, result.count < 100_000 else { throw PreparationFailure.unsupported }
            result.append(Element(id: id, data: data.subdata(in: start..<start + Int(size))))
            offset = start + Int(size)
        }
        return result
    }
    private static func header(_ reader: RemuxRangeReader, _ offset: Int64) async throws -> (id: UInt64, start: Int64, size: Int64) {
        let data = try await reader.read(offset, Int(min(16, reader.size - offset)))
        let (id, iw) = try vint(data, 0, id: true), (size, sw) = try vint(data, iw)
        let start = offset + Int64(iw + sw)
        let unknown = size == (UInt64(1) << (sw * 7)) - 1
        guard unknown || size <= UInt64(reader.size - start) else { throw PreparationFailure.unsupported }
        return (id, start, unknown ? reader.size - start : Int64(size))
    }
    private static func integer(_ elements: [Element], _ id: UInt64) throws -> UInt64 {
        guard let data = elements.first(where: { $0.id == id })?.data, (1...8).contains(data.count) else { throw PreparationFailure.unsupported }
        return try data.uint(0, data.count)
    }
    private static func blockLocation(_ reader: RemuxRangeReader, point: Point) async throws -> (Int64, Int) {
        let cluster = try await header(reader, point.offset)
        guard cluster.id == 0x1f43b675, let track = point.track,
              point.relative == nil || point.relative! < cluster.size else { throw PreparationFailure.unsupported }
        var offset = cluster.start + (point.relative ?? 0)
        for _ in 0..<128 {
            let item = try await header(reader, offset)
            if item.id == 0xa3 || item.id == 0xa1 {
                let data = try await reader.read(item.start, Int(min(12, item.size)))
                if try vint(data, 0).0 == track {
                    guard item.size > 4, item.size <= 64 * 1024 * 1024 else { throw PreparationFailure.unsupported }
                    return (item.start, Int(item.size))
                }
            } else if item.id == 0xa0 {
                // BlockGroup metadata can precede the Block. A bounded header
                // walk skips it without fetching the compressed payload.
                var childOffset = item.start
                for _ in 0..<16 {
                    let child = try await header(reader, childOffset)
                    if child.id == 0xa1 {
                        let data = try await reader.read(child.start, Int(min(12, child.size)))
                        guard try vint(data, 0).0 == track, child.size <= 64 * 1024 * 1024 else { throw PreparationFailure.unsupported }
                        return (child.start, Int(child.size))
                    }
                    childOffset = child.start + child.size
                    if childOffset >= item.start + item.size { break }
                }
            }
            offset = item.start + item.size
            if offset >= cluster.start + cluster.size { break }
        }
        throw PreparationFailure.unsupported
    }

    private static func mkv(_ reader: RemuxRangeReader, stream: Int, timeBase: Double) async throws -> [Point] {
        let ebml = try await header(reader, 0)
        guard ebml.id == 0x1a45dfa3 else { throw PreparationFailure.unsupported }
        let segment = try await header(reader, ebml.start + ebml.size)
        guard segment.id == 0x18538067 else { throw PreparationFailure.unsupported }
        var offset = segment.start, cueOffset: Int64?, tracks: Data?, scale = 1_000_000.0
        for _ in 0..<256 {
            let element = try await header(reader, offset)
            if element.id == 0x114d9b74 {
                guard element.size <= 1024 * 1024 else { throw PreparationFailure.unsupported }
                let seek = try elements(await reader.read(element.start, Int(element.size)))
                for item in seek where item.id == 0x4dbb {
                    let entry = try elements(item.data)
                    if try integer(entry, 0x53ab) == 0x1c53bb6b {
                        let position = try integer(entry, 0x53ac)
                        guard position < UInt64(reader.size - segment.start) else { throw PreparationFailure.unsupported }
                        cueOffset = segment.start + Int64(position)
                    }
                }
            } else if element.id == 0x1549a966 {
                guard element.size <= 1024 * 1024 else { throw PreparationFailure.unsupported }
                let info = try elements(await reader.read(element.start, Int(element.size)))
                if info.contains(where: { $0.id == 0x2ad7b1 }) { scale = Double(try integer(info, 0x2ad7b1)) }
            } else if element.id == 0x1654ae6b {
                guard element.size <= 4 * 1024 * 1024 else { throw PreparationFailure.unsupported }
                tracks = try await reader.read(element.start, Int(element.size))
            } else if element.id == 0x1c53bb6b { cueOffset = offset }
            if element.id == 0x1f43b675 { break }
            offset = element.start + element.size
        }
        guard let cueOffset, let tracks, scale > 0 else { throw PreparationFailure.unsupported }
        let trackEntries = try elements(tracks).filter { $0.id == 0xae }
        guard trackEntries.indices.contains(stream) else { throw PreparationFailure.unsupported }
        let track = try elements(trackEntries[stream].data)
        guard try integer(track, 0x83) == 1 else { throw PreparationFailure.unsupported }
        let number = try integer(track, 0xd7)
        let cueHeader = try await header(reader, cueOffset)
        guard cueHeader.id == 0x1c53bb6b, cueHeader.size <= 16 * 1024 * 1024 else { throw PreparationFailure.unsupported }
        let cues = try elements(await reader.read(cueHeader.start, Int(cueHeader.size)))
        var result: [Point] = []
        var last: Double?
        var previousVideoPTS: Int64?
        for cue in cues where cue.id == 0xbb {
            let fields = try elements(cue.data)
            let seconds = Double(try integer(fields, 0xb3)) * scale / 1e9
            for position in fields where position.id == 0xb7 {
                let values = try elements(position.data)
                guard try integer(values, 0xf7) == number else { continue }
                guard abs(seconds / timeBase) < 1e14 else { throw PreparationFailure.unsupported }
                let pts = Int64((seconds / timeBase).rounded())
                let precedingPTS = previousVideoPTS
                previousVideoPTS = pts
                // Subtitle/audio CuePoints cannot define the video's next
                // seek target, even when interleaved with video Cues.
                if let last, seconds - last < 6 {
                    if let index = result.indices.last, result[index].followingPTS == nil {
                        result[index].followingPTS = Int64((seconds / timeBase).rounded())
                    }
                    break
                }
                let relative = try integer(values, 0xf1)
                guard relative < UInt64(reader.size - segment.start) else { throw PreparationFailure.unsupported }
                let blockRelative = values.contains(where: { $0.id == 0xf0 }) ? try integer(values, 0xf0) : nil
                guard blockRelative == nil || blockRelative! < UInt64(reader.size - segment.start),
                      abs(seconds / timeBase) < 1e14 else { throw PreparationFailure.unsupported }
                result.append(Point(pts: Int64((seconds / timeBase).rounded()), dts: nil,
                                    offset: segment.start + Int64(relative), size: 4096, block: true,
                                    track: number, relative: blockRelative.map { Int64($0) }, precedingPTS: precedingPTS))
                last = seconds
                break
            }
        }
        return result
    }
}

private extension Data {
    func uint(_ offset: Int, _ count: Int) throws -> UInt64 {
        guard offset >= 0, count > 0, count <= 8, offset <= self.count - count else { throw PreparationFailure.unsupported }
        return self[offset..<offset + count].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
