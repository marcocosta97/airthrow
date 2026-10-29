import Foundation

/// ffmpeg reads these arguments with the C locale. `String(Double)` can emit
/// exponent form (`2.3e-05`) or a comma decimal, both of which shift the cut.
enum MediaClock {
    static func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "0.000000" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

extension Duration {
    var timeInterval: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
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
        var precedingKeyframe: Int64? = nil
    }
    let cuts: [Cut]
    let videoTimeBase: Double
    let audioTimeBase: Double
    let sourceStart: Double
    let usesSyncPacketIntervals: Bool
    /// Reordered Matroska needs packets before a cut to establish its initial
    /// DTS values. Seek to a preceding keyframe and trim on the known clock.
    let needsDecodePreroll: Bool
    var audioOffset = 0.0
    var remoteValidation: RemoteRemuxIndex.Validation?
    private(set) var presentationReorderAllowance = 0.15
    var starts: [Double] { cuts.map { Double($0.pts - cuts[0].pts) * videoTimeBase } }

    init(packets: Data, file: URL, codec: String, videoTimeBase: String?, audioTimeBase: String?,
         sourceStart: Double, duration: Double, matroska: Bool, reorderDelay: Bool) throws {
        guard sourceStart.isFinite, abs(sourceStart) < 86_400,
              duration.isFinite, duration > 0, duration <= 14_400 else { throw PreparationFailure.unsupported }
        self.videoTimeBase = try Self.timeBase(videoTimeBase)
        self.audioTimeBase = try Self.timeBase(audioTimeBase)
        self.sourceStart = sourceStart
        self.usesSyncPacketIntervals = false
        self.needsDecodePreroll = matroska && reorderDelay
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var cuts: [Cut] = []
        var lastDTS: Int64?
        var lastPTS = -Double.infinity
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var packetCount = 0
        var reorderDelaySeconds = 0.0
        var previousKeyframe: Int64?
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
                reorderDelaySeconds = max(reorderDelaySeconds, (Double(pts) - Double(dts)) * self.videoTimeBase)
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
            let precedingKeyframe = previousKeyframe
            previousKeyframe = pts
            if let last = cuts.indices.last, cuts[last].followingKeyframe == nil, pts > cuts[last].pts {
                cuts[last].followingKeyframe = pts
            }
            let seconds = Double(pts) * self.videoTimeBase
            if let last = cuts.last, seconds - Double(last.pts) * self.videoTimeBase < 6.0 { continue }
            guard let position = fields.position,
                  let size = fields.size, size > 0,
                  try Self.isRefreshPoint(reader, position: position, size: size, codec: codec, matroska: matroska) else {
                // Only immediate, exact AVC recovery points and HEVC IDR/CRA
                // can restart decoding. Leading pictures use a continuous clock.
                continue
            }
            if let last = cuts.last {
                guard pts > last.pts, let dts, last.dts == nil || dts > last.dts!,
                      seconds - Double(last.pts) * self.videoTimeBase <= 30 else { throw PreparationFailure.unsupported }
            } else {
                guard abs(seconds - sourceStart) < 0.1 else { throw PreparationFailure.unsupported }
            }
            if let dts {
                guard (Double(pts) - Double(dts)) * self.videoTimeBase >= 0,
                      (Double(pts) - Double(dts)) * self.videoTimeBase < 2 else { throw PreparationFailure.unsupported }
            }
            cuts.append(Cut(pts: pts, dts: dts, precedingKeyframe: precedingKeyframe))
        }
        guard let first = cuts.first, let last = cuts.last,
              duration - Double(last.pts - first.pts) * self.videoTimeBase <= 30,
              abs(lastPTS - Double(first.pts) * self.videoTimeBase - duration) < 0.25 else {
            throw PreparationFailure.unsupported
        }
        // A keyframe at the very end can leave only an audio/container tail.
        if cuts.count > 1, duration - Double(last.pts - first.pts) * self.videoTimeBase < 0.25 { cuts.removeLast() }
        self.cuts = cuts
        presentationReorderAllowance = Self.reorderAllowance(delay: reorderDelaySeconds)
    }

    static func timeBase(_ value: String?) throws -> Double {
        let parts = (value ?? "").split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0,
              (1e-9...1).contains(parts[0] / parts[1]) else { throw PreparationFailure.unsupported }
        return parts[0] / parts[1]
    }

    init(cuts: [Cut], videoTimeBase: Double, audioTimeBase: Double,
         sourceStart: Double, duration: Double, usesSyncPacketIntervals: Bool, needsDecodePreroll: Bool = false) throws {
        guard sourceStart.isFinite, abs(sourceStart) < 86_400, duration.isFinite, duration > 0, duration <= 14_400,
              let first = cuts.first, let last = cuts.last,
              abs(Double(first.pts) * videoTimeBase - sourceStart) < 0.1,
              Double(last.pts - first.pts) * videoTimeBase < duration,
              duration - Double(last.pts - first.pts) * videoTimeBase <= 30,
              zip(cuts, cuts.dropFirst()).allSatisfy({
                  $1.pts > $0.pts && Double($1.pts - $0.pts) * videoTimeBase <= 30
                  && (usesSyncPacketIntervals || ($1.dts != nil && ($0.dts == nil || $1.dts! > $0.dts!)))
              }) else { throw PreparationFailure.unsupported }
        self.cuts = cuts; self.videoTimeBase = videoTimeBase; self.audioTimeBase = audioTimeBase
        self.sourceStart = sourceStart; self.usesSyncPacketIntervals = usesSyncPacketIntervals
        self.needsDecodePreroll = needsDecodePreroll
    }

    /// AVC accepts IDR or an explicitly signalled immediate exact intra recovery;
    /// HEVC accepts IDR/CRA. Retain leading pictures on a continuous media clock.
    static func isRefreshPoint(_ data: Data, codec: String) -> Bool {
        for width in [4, 2, 1] {
            var offset = 0
            var recovery = false
            for _ in 0..<64 {
                guard offset + width + 1 <= data.count else { break }
                let length = data[offset..<offset + width].reduce(0) { ($0 << 8) | Int($1) }
                guard length > 0 else { break }
                let header = data[offset + width]
                guard header & 0x80 == 0 else { break }
                let type = codec == "h264" ? header & 0x1f : (header >> 1) & 0x3f
                if codec == "h264", (1...5).contains(type) {
                    if type == 5 { return true }
                    guard recovery, type == 1 else { return false }
                    // An exact recovery SEI must accompany an intra slice.
                    let end = min(data.count, offset + width + length)
                    var bits = AVCBits(rbsp(data[(offset + width + 1)..<end]))
                    guard bits.ue() != nil, let slice = bits.ue(), slice <= 9 else { return false }
                    return slice % 5 == 2
                }
                if codec == "hevc", type <= 31 { return type == 19 || type == 20 || type == 21 }
                guard length <= data.count - offset - width else { break }
                if codec == "h264", type == 6 {
                    recovery = recovery || immediateAVCRecovery(data[(offset + width + 1)..<(offset + width + length)])
                }
                offset += width + length
            }
        }
        return false
    }

    private static func rbsp(_ data: Data.SubSequence) -> [UInt8] {
        var result: [UInt8] = [], zeros = 0
        for byte in data {
            if zeros >= 2, byte == 3 { zeros = 0; continue }
            result.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return result
    }

    /// H.264 D.1.7: accept only recovery_frame_cnt=0, exact_match=1,
    /// broken_link=0 and changing_slice_group_idc=0. Delayed/approximate
    /// recovery and a mere container keyframe flag are insufficient.
    private static func immediateAVCRecovery(_ data: Data.SubSequence) -> Bool {
        let bytes = rbsp(data)
        var at = 0
        for _ in 0..<64 {
            var type = 0, size = 0
            while at < bytes.count, bytes[at] == 255 { type += 255; at += 1 }
            guard at < bytes.count else { return false }
            type += Int(bytes[at]); at += 1
            while at < bytes.count, bytes[at] == 255 { size += 255; at += 1 }
            guard at < bytes.count else { return false }
            size += Int(bytes[at]); at += 1
            guard size > 0, size <= bytes.count - at else { return false }
            if type == 6 { return size == 1 && bytes[at] == 0xc4 }
            at += size
        }
        return false
    }

    private struct AVCBits {
        let bytes: [UInt8]
        var at = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        mutating func bit() -> Int? {
            guard at < bytes.count * 8 else { return nil }
            defer { at += 1 }
            return Int((bytes[at / 8] >> (7 - at % 8)) & 1)
        }
        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let value = bit(), zeros < 31 else { return nil }
                if value == 1 { break }
                zeros += 1
            }
            var value = 1
            for _ in 0..<zeros {
                guard let next = bit() else { return nil }
                value = value * 2 + next
            }
            return value - 1
        }
    }

    static func reorderAllowance(delay: Double) -> Double {
        // The first and last decoded packets can each precede the presentation
        // edge. Bound tolerance by observed reordering, never by source length.
        max(0.15, min(1, 2 * delay + 0.01))
    }

    func arguments(index: Int, length: Double) -> (input: [String], audio: [String], output: [String]) {
        let cut = cuts[index]
        let seconds = Double(cut.pts) * videoTimeBase
        let videoDrop: String
        if usesSyncPacketIntervals {
            // Matroska stores presentation clocks. Toggle at the indexed sync
            // packets in decode order; leading pictures stay with their GOP,
            // even when their PTS precedes its recovery frame.
            var toggle = "if(eq(pts,\(cut.pts)),st(0,1),0)"
            if index + 1 < cuts.count {
                toggle = "if(eq(pts,\(cut.pts)),st(0,1),if(eq(pts,\(cuts[index + 1].pts)),st(0,0),0))"
            }
            videoDrop = toggle + ";1-ld(0)"
        } else {
            var drop = index == 0 ? "0" : "lt(dts,\(cut.dts!))"
            if index + 1 < cuts.count { drop += "+gte(dts,\(cuts[index + 1].dts!))" }
            videoDrop = drop
        }
        var audioDrop = index == 0 ? "0" : "lt(pts,\(Int64(ceil(seconds / audioTimeBase))))"
        if index + 1 < cuts.count {
            let next = cuts[index + 1]
            audioDrop += "+gte(pts,\(Int64(ceil(Double(next.pts) * videoTimeBase / audioTimeBase))))"
        }
        let origin = max(0, seconds - sourceStart)
        // Starting exactly on a reordered GOP can leave its first DTS values
        // unknown; the lower-bound filter would then discard the recovery
        // frame. Reading the preceding GOP establishes DTS before the cut.
        let predecessor = cut.precedingKeyframe.flatMap { $0 < cut.pts ? $0 : nil }
            ?? (index > 0 ? cuts[index - 1].pts : cut.pts)
        let videoAt = needsDecodePreroll && index > 0
            ? max(0, Double(predecessor) * videoTimeBase - sourceStart) : origin
        let videoSpan = MediaClock.seconds(length + max(0, origin - videoAt) + 4)
        return (["-ss", MediaClock.seconds(videoAt), "-t", videoSpan],
                ["-ss", MediaClock.seconds(max(0, origin - 0.001)), "-t", MediaClock.seconds(length + 4)],
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
        try reader.seek(toOffset: start)
        let prefix = try reader.read(upToCount: min(size, 4096)) ?? Data()
        let recovery = codec == "h264" && Self.isRefreshPoint(prefix, codec: codec)
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
                if codec == "h264" ? type == 5 : type == 19 || type == 20 || type == 21 { refresh = true }
                offset += width + length
            }
            if offset == size { return refresh || recovery }
        }
        return false
    }
}
