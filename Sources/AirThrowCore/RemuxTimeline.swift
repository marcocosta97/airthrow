import Foundation

/// Copy boundaries are decoder refresh points, not arbitrary six-second cuts.
/// Packet DTS keeps reordered video together; audio PTS assigns each packet to
/// exactly one interval. No compressed payload is changed by these filters.
struct RemuxTimeline: Sendable {
    struct Cut: Sendable {
        let pts: Int64
        let dts: Int64?
    }
    let cuts: [Cut]
    let videoTimeBase: Double
    let audioTimeBase: Double
    let sourceStart: Double
    let inspectBoundaries: Bool
    var audioOffset = 0.0
    var starts: [Double] { cuts.map { Double($0.pts - cuts[0].pts) * videoTimeBase } }

    init(packets: Data, file: URL, codec: String, videoTimeBase: String?, audioTimeBase: String?,
         sourceStart: Double, duration: Double, matroska: Bool) throws {
        guard sourceStart.isFinite, abs(sourceStart) < 86_400,
              duration.isFinite, duration > 0, duration <= 14_400 else { throw PreparationFailure.unsupported }
        self.videoTimeBase = try Self.timeBase(videoTimeBase)
        self.audioTimeBase = try Self.timeBase(audioTimeBase)
        self.sourceStart = sourceStart
        self.inspectBoundaries = false
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var cuts: [Cut] = []
        var lastDTS: Int64?
        var lastPTS = -Double.infinity
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var packetCount = 0
        for line in String(decoding: packets, as: UTF8.self).split(separator: "\n") {
            let fields = Dictionary(line.split(separator: "|").compactMap { item -> (String, String)? in
                let pair = item.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }, uniquingKeysWith: { first, _ in first })
            packetCount += 1
            if packetCount % 1024 == 0 {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw PreparationFailure.unsupported }
            }
            let dts = fields["dts"].flatMap(Int64.init)
            guard let pts = fields["pts"].flatMap(Int64.init),
                  (sourceStart - 2...sourceStart + duration + 2).contains(Double(pts) * self.videoTimeBase) else {
                throw PreparationFailure.unsupported
            }
            if let dts {
                guard (sourceStart - 2...sourceStart + duration + 2).contains(Double(dts) * self.videoTimeBase) else {
                    throw PreparationFailure.unsupported
                }
                guard lastDTS == nil || dts > lastDTS! else { throw PreparationFailure.unsupported }
                lastDTS = dts
            } else {
                // Matroska omits the initial reorder-delay DTS values. Only
                // the leading packets can do this; later boundaries need DTS.
                guard lastDTS == nil, packetCount <= 32 else { throw PreparationFailure.unsupported }
            }
            lastPTS = max(lastPTS, Double(pts) * self.videoTimeBase)
            guard fields["flags"]?.contains("K") == true else { continue }
            let seconds = Double(pts) * self.videoTimeBase
            if let last = cuts.last, seconds - Double(last.pts) * self.videoTimeBase < 6.0 { continue }
            guard let position = fields["pos"].flatMap(UInt64.init),
                  let size = fields["size"].flatMap(Int.init), size > 0,
                  try Self.isRefreshPoint(reader, position: position, size: size, codec: codec, matroska: matroska) else {
                // A CRA/recovery point can depend on the previous GOP. Wait for
                // an IDR; sources without usable IDRs keep sequential delivery.
                continue
            }
            if let last = cuts.last {
                guard pts > last.pts, let dts, last.dts == nil || dts > last.dts!,
                      seconds - Double(last.pts) * self.videoTimeBase <= 30 else { throw PreparationFailure.unsupported }
            } else {
                guard abs(seconds - sourceStart) < 0.1 else { throw PreparationFailure.unsupported }
            }
            if let dts {
                guard Double(pts - dts) * self.videoTimeBase >= 0,
                      Double(pts - dts) * self.videoTimeBase < 2 else { throw PreparationFailure.unsupported }
            }
            cuts.append(Cut(pts: pts, dts: dts))
        }
        guard let first = cuts.first, let last = cuts.last,
              duration - Double(last.pts - first.pts) * self.videoTimeBase <= 30,
              abs(lastPTS - Double(first.pts) * self.videoTimeBase - duration) < 0.25 else {
            throw PreparationFailure.unsupported
        }
        // A keyframe at the very end can leave only an audio/container tail.
        if cuts.count > 1, duration - Double(last.pts - first.pts) * self.videoTimeBase < 0.25 { cuts.removeLast() }
        self.cuts = cuts
    }

    static func timeBase(_ value: String?) throws -> Double {
        let parts = (value ?? "").split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0,
              (1e-9...1).contains(parts[0] / parts[1]) else { throw PreparationFailure.unsupported }
        return parts[0] / parts[1]
    }

    init(cuts: [Cut], videoTimeBase: Double, audioTimeBase: Double,
         sourceStart: Double, duration: Double, inspectBoundaries: Bool) throws {
        guard sourceStart.isFinite, abs(sourceStart) < 86_400, duration.isFinite, duration > 0, duration <= 14_400,
              let first = cuts.first, let last = cuts.last,
              abs(Double(first.pts) * videoTimeBase - sourceStart) < 0.1,
              Double(last.pts - first.pts) * videoTimeBase < duration,
              duration - Double(last.pts - first.pts) * videoTimeBase <= 30,
              zip(cuts, cuts.dropFirst()).allSatisfy({
                  $1.pts > $0.pts && Double($1.pts - $0.pts) * videoTimeBase <= 30
                  && (inspectBoundaries || ($1.dts != nil && ($0.dts == nil || $1.dts! > $0.dts!)))
              }) else { throw PreparationFailure.unsupported }
        self.cuts = cuts; self.videoTimeBase = videoTimeBase; self.audioTimeBase = audioTimeBase
        self.sourceStart = sourceStart; self.inspectBoundaries = inspectBoundaries
    }

    /// Container sync flags may describe recovery/CRA points. Require an IDR
    /// slice in the bounded prefix; unknown/oversized layouts fall back safely.
    static func isRefreshPoint(_ data: Data, codec: String) -> Bool {
        for width in [4, 2, 1] {
            var offset = 0
            for _ in 0..<64 {
                guard offset + width + 1 <= data.count else { break }
                let length = data[offset..<offset + width].reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0 else { break }
                let type = codec == "h264" ? data[offset + width] & 0x1f : (data[offset + width] >> 1) & 0x3f
                if codec == "h264", (1...5).contains(type) { return type == 5 }
                if codec == "hevc", type <= 31 { return type == 19 || type == 20 }
                guard length <= data.count - offset - width else { break }
                offset += width + length
            }
        }
        return false
    }

    func boundaryInterval(index: Int, duration: Double) -> String {
        let start = max(sourceStart, Double(cuts[index].pts) * videoTimeBase - 3)
        let end = index + 1 < cuts.count ? Double(cuts[index + 1].pts) * videoTimeBase + 1 : sourceStart + duration + 1
        return "\(start)%\(end)"
    }

    func boundaries(_ packets: Data, index: Int) throws -> (Int64?, Int64?) {
        var current: Int64?, next: Int64?
        for line in String(decoding: packets, as: UTF8.self).split(separator: "\n") {
            let fields = Dictionary(line.split(separator: "|").compactMap { item -> (String, String)? in
                let pair = item.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }, uniquingKeysWith: { first, _ in first })
            guard let pts = fields["pts"].flatMap(Int64.init) else { continue }
            let dts = fields["dts"].flatMap(Int64.init)
            if pts == cuts[index].pts { current = dts }
            if index + 1 < cuts.count, pts == cuts[index + 1].pts { next = dts }
        }
        guard index == 0 || current != nil, index + 1 == cuts.count || next != nil else {
            throw PreparationFailure.unsupported
        }
        return (current, next)
    }

    func arguments(index: Int, length: Double, boundaries: (Int64?, Int64?)? = nil) -> (input: [String], output: [String]) {
        let cut = cuts[index]
        let seconds = Double(cut.pts) * videoTimeBase
        var videoDrop = index == 0 ? "0" : "lt(dts,\(boundaries?.0 ?? cut.dts!))"
        var audioDrop = index == 0 ? "0" : "lt(pts,\(Int64(ceil(seconds / audioTimeBase))))"
        if index + 1 < cuts.count {
            let next = cuts[index + 1]
            videoDrop += "+gte(dts,\(boundaries?.1 ?? next.dts!))"
            audioDrop += "+gte(pts,\(Int64(ceil(Double(next.pts) * videoTimeBase / audioTimeBase))))"
        }
        return (["-ss", String(max(0, seconds - sourceStart - 0.001)), "-t", String(length + 4)],
                ["-copyts", "-bsf:v", "noise=amount=0:drop='\(videoDrop)'",
                 "-bsf:a", "noise=amount=0:drop='\(audioDrop)'", "-output_ts_offset", String(-seconds)])
    }

    /// Read only NAL headers, using the demuxer's packet positions. Matroska
    /// positions include a block header; laced/encrypted blocks are ineligible.
    /// Both AVC and HEVC length-prefixed packet layouts are checked explicitly.
    private static func isRefreshPoint(_ reader: FileHandle, position: UInt64, size: Int,
                                       codec: String, matroska: Bool) throws -> Bool {
        let end = try reader.seekToEnd()
        guard position < end, UInt64(size) <= end - position else { return false }
        var start = position
        if matroska {
            try reader.seek(toOffset: position)
            guard let header = try reader.read(upToCount: 12), let byte = header.first, byte != 0 else { return false }
            let width = byte.leadingZeroBitCount + 1
            guard width <= 8, header.count >= width + 3, header[width + 2] & 0x06 == 0 else { return false }
            start += UInt64(width + 3)
            guard start <= end, UInt64(size) <= end - start else { return false }
        }
        for width in [4, 2, 1] {
            var offset = 0
            var refresh = false
            var headers = 0
            while offset < size {
                try Task.checkCancellation()
                headers += 1
                guard headers <= 4096 else { return false }
                guard offset + width + 1 <= size else { break }
                try reader.seek(toOffset: start + UInt64(offset))
                guard let header = try reader.read(upToCount: width + 1), header.count == width + 1 else { break }
                let length = header.prefix(width).reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0, length <= size - offset - width else { break }
                let type = codec == "h264" ? header[width] & 0x1f : (header[width] >> 1) & 0x3f
                if codec == "h264" ? type == 5 : type == 19 || type == 20 { refresh = true }
                offset += width + length
            }
            if offset == size { return refresh }
        }
        return false
    }
}
