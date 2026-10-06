import Foundation

/// Read container indexes and small decoder-refresh headers, never scan the
/// remote media payload. Byte-range support and all memory/I/O bounds are real
/// response checks. The reader is only alive during preparation's index step.
actor RemuxRangeReader {
    let size: Int64
    private let url: URL
    private let headers: [String: String]
    private let session = URLSession(configuration: .ephemeral)
    private let deadline = ContinuousClock().now.advanced(by: .seconds(25))
    private var used = 0
    private var blocks: [Int64: Data] = [:]
    private init(url: URL, headers: [String: String], size: Int64) {
        self.url = url; self.headers = headers; self.size = size
    }
    deinit { session.invalidateAndCancel() }
    static func open(_ url: URL, headers: [String: String]) async throws -> RemuxRangeReader {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 5)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (_, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 206,
              let range = response.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes 0-0/"),
              let size = Int64(range.dropFirst(10)), size > 0 else { throw PreparationFailure.unsupported }
        return RemuxRangeReader(url: url, headers: headers, size: size)
    }
    func read(_ offset: Int64, _ count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard count > 0, count <= 32 * 1024 * 1024, offset >= 0, offset <= size - Int64(count),
              ContinuousClock().now < deadline else { throw PreparationFailure.unsupported }
        let block = offset / 4096 * 4096
        if count <= 4096, offset + Int64(count) <= block + 4096 {
            if let data = blocks[block] { return data.subdata(in: Int(offset - block)..<Int(offset - block) + count) }
            let data = try await fetch(block, Int(min(4096, size - block)))
            if blocks.count < 256 { blocks[block] = data }
            return data.subdata(in: Int(offset - block)..<Int(offset - block) + count)
        }
        return try await fetch(offset, count)
    }
    private func fetch(_ offset: Int64, _ count: Int) async throws -> Data {
        used += count
        guard used <= 64 * 1024 * 1024 else { throw PreparationFailure.unsupported }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let end = offset + Int64(count) - 1
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 206,
              response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(size)",
              response.expectedContentLength == -1 || response.expectedContentLength == count else {
            session.invalidateAndCancel(); throw PreparationFailure.unsupported
        }
        var data = Data(); data.reserveCapacity(count)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < count, ContinuousClock().now < deadline else {
                session.invalidateAndCancel(); throw PreparationFailure.unsupported
            }
            data.append(byte)
        }
        guard data.count == count else { throw PreparationFailure.unsupported }
        return data
    }
}

/// Bounded parsers for seekable file containers. A container's sync/cue entries
/// alone are insufficient: selected cuts must also contain an AVC/HEVC IDR.
enum RemoteRemuxIndex {
    struct Point: Sendable {
        let pts: Int64; let dts: Int64?; let offset: Int64; let size: Int; let block: Bool
        var track: UInt64? = nil
        var relative: Int64? = nil
    }
    static func timeline(url: URL, headers: [String: String], stream: Int, codec: String,
                         videoTimeBase: String?, audioTimeBase: String?, sourceStart: Double,
                         duration: Double, matroska: Bool) async throws -> RemuxTimeline {
        let reader = try await RemuxRangeReader.open(url, headers: headers)
        let vtb = try RemuxTimeline.timeBase(videoTimeBase)
        let atb = try RemuxTimeline.timeBase(audioTimeBase)
        let points = matroska ? try await mkv(reader, stream: stream, timeBase: vtb)
                             : try await mp4(reader, stream: stream, timeBase: vtb)
        var selected: [Point] = []
        for point in points {
            if let last = selected.last, Double(point.pts - last.pts) * vtb < 6 { continue }
            selected.append(point)
        }
        guard !selected.isEmpty, selected.count <= 2401 else { throw PreparationFailure.unsupported }
        // Limit parallel network reads. Joining the group also closes every
        // pending range operation when validation or cancellation fails.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue(_ point: Point) {
                group.addTask {
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
                    guard RemuxTimeline.isRefreshPoint(data, codec: codec) else { throw PreparationFailure.unsupported }
                }
            }
            while next < min(16, selected.count) { enqueue(selected[next]); next += 1 }
            while try await group.next() != nil {
                if next < selected.count { enqueue(selected[next]); next += 1 }
            }
        }
        return try RemuxTimeline(cuts: selected.map { .init(pts: $0.pts, dts: $0.dts) },
                                 videoTimeBase: vtb, audioTimeBase: atb, sourceStart: sourceStart,
                                 duration: duration, inspectBoundaries: matroska)
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
        for cue in cues where cue.id == 0xbb {
            let fields = try elements(cue.data)
            let seconds = Double(try integer(fields, 0xb3)) * scale / 1e9
            if let last, seconds - last < 6 { continue }
            for position in fields where position.id == 0xb7 {
                let values = try elements(position.data)
                guard try integer(values, 0xf7) == number else { continue }
                let relative = try integer(values, 0xf1)
                guard relative < UInt64(reader.size - segment.start) else { throw PreparationFailure.unsupported }
                let blockRelative = values.contains(where: { $0.id == 0xf0 }) ? try integer(values, 0xf0) : nil
                guard blockRelative == nil || blockRelative! < UInt64(reader.size - segment.start),
                      abs(seconds / timeBase) < 1e14 else { throw PreparationFailure.unsupported }
                result.append(Point(pts: Int64((seconds / timeBase).rounded()), dts: nil,
                                    offset: segment.start + Int64(relative), size: 4096, block: true,
                                    track: number, relative: blockRelative.map { Int64($0) }))
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
