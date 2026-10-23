import Foundation

/// ffmpeg reads these arguments with the C locale. `String(Double)` can emit
/// exponent form (`2.3e-05`) or a comma decimal, both of which shift the cut.
enum MediaClock {
    static func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "0.000000" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// Copy boundaries are decoder refresh points, not arbitrary six-second cuts.
/// Packet DTS keeps reordered video together; audio PTS assigns each packet to
/// exactly one interval. No compressed payload is changed by these filters.
struct RemuxTimeline: Sendable {
    struct Cut: Sendable {
        let pts: Int64
        let dts: Int64?
        /// The next keyframe after this cut, including one that was too close to keep.
        var followingKeyframe: Int64? = nil
    }
    let cuts: [Cut]
    let videoTimeBase: Double
    let audioTimeBase: Double
    let sourceStart: Double
    let inspectBoundaries: Bool
    /// Matroska does not seek by PTS. When the video has a reorder delay, ffmpeg
    /// subtracts 3/23 s before the backward seek, so an exact keyframe time
    /// selects the previous one.
    let containerSeekSlop: Bool
    var audioOffset = 0.0
    var starts: [Double] { cuts.map { Double($0.pts - cuts[0].pts) * videoTimeBase } }

    init(packets: Data, file: URL, codec: String, videoTimeBase: String?, audioTimeBase: String?,
         sourceStart: Double, duration: Double, matroska: Bool, reorderDelay: Bool) throws {
        guard sourceStart.isFinite, abs(sourceStart) < 86_400,
              duration.isFinite, duration > 0, duration <= 14_400 else { throw PreparationFailure.unsupported }
        self.videoTimeBase = try Self.timeBase(videoTimeBase)
        self.audioTimeBase = try Self.timeBase(audioTimeBase)
        self.sourceStart = sourceStart
        self.inspectBoundaries = false
        self.containerSeekSlop = matroska && reorderDelay
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var cuts: [Cut] = []
        var lastDTS: Int64?
        var lastPTS = -Double.infinity
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var packetCount = 0
        for line in String(decoding: packets, as: UTF8.self).split(separator: "\n") {
            let fields = Self.packetLine(line)
            packetCount += 1
            if packetCount % 1024 == 0 {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw PreparationFailure.unsupported }
            }
            let dts = fields.dts
            guard let pts = fields.pts,
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
            guard fields.isKeyframe else { continue }
            if let last = cuts.indices.last, cuts[last].followingKeyframe == nil, pts > cuts[last].pts {
                cuts[last].followingKeyframe = pts
            }
            let seconds = Double(pts) * self.videoTimeBase
            if let last = cuts.last, seconds - Double(last.pts) * self.videoTimeBase < 6.0 { continue }
            guard let position = fields.position,
                  let size = fields.size, size > 0,
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
         sourceStart: Double, duration: Double, inspectBoundaries: Bool, containerSeekSlop: Bool = false) throws {
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
        self.containerSeekSlop = containerSeekSlop
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
            let fields = Self.packetLine(line)
            guard let pts = fields.pts else { continue }
            let dts = fields.dts
            if pts == cuts[index].pts { current = dts }
            if index + 1 < cuts.count, pts == cuts[index + 1].pts { next = dts }
        }
        guard index == 0 || current != nil, index + 1 == cuts.count || next != nil else {
            throw PreparationFailure.unsupported
        }
        return (current, next)
    }

    func arguments(index: Int, length: Double, boundaries: (Int64?, Int64?)? = nil) -> (input: [String], audio: [String], output: [String]) {
        let cut = cuts[index]
        let seconds = Double(cut.pts) * videoTimeBase
        var videoDrop = index == 0 ? "0" : "lt(dts,\(boundaries?.0 ?? cut.dts!))"
        var audioDrop = index == 0 ? "0" : "lt(pts,\(Int64(ceil(seconds / audioTimeBase))))"
        if index + 1 < cuts.count {
            let next = cuts[index + 1]
            videoDrop += "+gte(dts,\(boundaries?.1 ?? next.dts!))"
            audioDrop += "+gte(pts,\(Int64(ceil(Double(next.pts) * videoTimeBase / audioTimeBase))))"
        }
        let origin = max(0, seconds - sourceStart)
        let span = MediaClock.seconds(length + 4)
        // Cancel ffmpeg's fixed subtraction (3*AV_TIME_BASE/23) and one timebase
        // tick of rounding. A keyframe inside that window would be skipped, so
        // the cut time stays put and the drop filter discards the previous GOP.
        let slop = 3.0 / 23.0 + videoTimeBase
        let following = cut.followingKeyframe ?? (index + 1 < cuts.count ? cuts[index + 1].pts : nil)
        let gap = following.map { Double($0 - cut.pts) * videoTimeBase }
        let videoAt = containerSeekSlop && (gap == nil || gap! > slop) ? origin + slop : origin
        return (["-ss", MediaClock.seconds(videoAt), "-t", span],
                ["-ss", MediaClock.seconds(max(0, origin - 0.001)), "-t", span],
                ["-copyts", "-bsf:v", "noise=amount=0:drop='\(videoDrop)'",
                 "-bsf:a", "noise=amount=0:drop='\(audioDrop)'", "-output_ts_offset", MediaClock.seconds(-seconds)])
    }

    struct PacketLine {
        var pts: Int64?
        var dts: Int64?
        var flags: Substring = ""
        var position: UInt64?
        var size: Int?
        var isKeyframe: Bool { flags.contains("K") }
    }

    /// One pass over `key=value|key=value` packet lines. The demuxer prints only
    /// the requested fields, so a dictionary per line is unused work.
    static func packetLine(_ line: Substring) -> PacketLine {
        var packet = PacketLine()
        var rest = line[...]
        while !rest.isEmpty {
            let bar = rest.firstIndex(of: "|") ?? rest.endIndex
            let item = rest[..<bar]
            if let equals = item.firstIndex(of: "=") {
                let value = item[item.index(after: equals)...]
                switch item[..<equals] {
                case "pts": packet.pts = Int64(value)
                case "dts": packet.dts = Int64(value)
                case "flags": packet.flags = value
                case "pos": packet.position = UInt64(value)
                case "size": packet.size = Int(value)
                default: break
                }
            }
            guard bar < rest.endIndex else { break }
            rest = rest[rest.index(after: bar)...]
        }
        return packet
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
