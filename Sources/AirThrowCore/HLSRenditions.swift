import Foundation

/// Stable advertised attributes identify a rendition without exposing its URI.
public struct HLSVariantSelection: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let frameRate: Double?
    public let bandwidth: Double
    public let codecs: String
    public var id: String {
        "hls-" + MediaCandidate.stableHash(MediaCandidate.signature([
            String(width), String(height), MediaCandidate.stableNumber(frameRate),
            MediaCandidate.stableNumber(bandwidth), codecs]))
    }
}

/// HLS lines end in LF or CRLF. Swift treats CRLF as one character, and
/// splitting on every newline scalar turns that pair into a blank line, which
/// hides the URI after a tag.
enum PlaylistText {
    static func lines(in text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var skippingLead = true
        for character in text {
            if isBreak(character) {
                if skippingLead { continue }
                lines.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            if skippingLead, character == " " || character == "\t" || character == "\u{FEFF}" { continue }
            skippingLead = false
            current.append(character)
        }
        if !skippingLead { lines.append(current.trimmingCharacters(in: .whitespaces)) }
        return lines
    }

    private static func isBreak(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }

    static func startsAsPlaylist(_ data: Data) -> Bool {
        let sample = data.prefix(256)
        guard let text = String(data: sample, encoding: .utf8)
                ?? String(data: sample.dropLast(), encoding: .utf8) else { return false }
        return lines(in: text).first == "#EXTM3U"
    }
}

public enum HLSRenditions {
    private static func selection(_ line: String) -> HLSVariantSelection? {
        guard line.hasPrefix("#EXT-X-STREAM-INF:"),
              let attrs = HLSMaster.attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count))),
              let dimensions = attrs["RESOLUTION"]?.split(separator: "x"), dimensions.count == 2,
              let width = Int(dimensions[0]), let height = Int(dimensions[1]),
              (1...16384).contains(width), (1...16384).contains(height),
              let bandwidth = attrs["BANDWIDTH"].flatMap(Double.init), bandwidth.isFinite, bandwidth > 0 else { return nil }
        let rawCodecs = attrs["CODECS"] ?? ""
        guard rawCodecs.count <= 256, rawCodecs.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ",. ".contains($0)) }) else { return nil }
        let codecs = rawCodecs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.sorted().joined(separator: ",")
        let fps = attrs["FRAME-RATE"].flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return HLSVariantSelection(width: width, height: height, frameRate: fps, bandwidth: bandwidth, codecs: codecs)
    }

    public static func variants(_ data: Data) -> [HLSVariantSelection] {
        guard data.count <= HLSMaster.maximumBytes, let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = PlaylistText.lines(in: text)
        guard lines.first == "#EXTM3U" else { return [] }
        var result: [HLSVariantSelection] = []
        for (index, line) in lines.enumerated() {
            guard let selected = selection(line), index + 1 < lines.count,
                  !lines[index + 1].isEmpty, !lines[index + 1].hasPrefix("#") else { continue }
            result.append(selected)
            if result.count > 128 { return [] }
        }
        return result
    }

    /// Preserve rendition groups, keys and session attributes. Only the chosen
    /// STREAM-INF/URI pair remains; resource rewriting belongs to the relay.
    public static func selecting(_ selected: HLSVariantSelection, in data: Data) throws -> Data {
        let variants = variants(data)
        guard variants.filter({ $0 == selected }).count == 1,
              let text = String(data: data, encoding: .utf8) else { throw HTTPLoginFailure.invalidPlaylist }
        let lines = PlaylistText.lines(in: text)
        var output: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                if index + 1 < lines.count {
                    let uri = lines[index + 1]
                    if selection(line) == selected, !uri.isEmpty, !uri.hasPrefix("#") {
                        output.append(line)
                        output.append(uri)
                    }
                    index += 2
                } else {
                    index += 1
                }
            } else {
                if !line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") { output.append(lines[index]) }
                index += 1
            }
        }
        return Data(output.joined(separator: "\n").utf8)
    }

    static func candidates(_ data: Data, for adaptive: MediaCandidate) -> [MediaCandidate] {
        let variants = variants(data)
        return variants.filter { variant in variants.filter({ $0 == variant }).count == 1 }.map { variant in
            var source = adaptive.source
            source.hlsVariant = variant
            var candidate = MediaCandidate(source: source, id: adaptive.id + "-" + variant.id,
                height: Double(variant.height), bitrate: variant.bandwidth / 1000,
                frameRate: variant.frameRate, audioDescription: adaptive.audioDescription,
                unavailableReason: adaptive.unavailableReason)
            candidate.discovery = adaptive.discovery
            return candidate
        }
    }

    static func expand(_ candidates: [MediaCandidate]) async throws -> [MediaCandidate] {
        var result = candidates
        var inspected = Set<URL>()
        for candidate in candidates where candidate.source.delivery == .hls && candidate.source.playbackPath == .direct && candidate.source.audio == nil && candidate.source.hlsVariant == nil {
            guard inspected.count < 2, inspected.insert(candidate.source.url).inserted,
                  !candidates.contains(where: { $0.source.url == candidate.source.url && $0.source.hlsVariant != nil }) else { continue }
            try Task.checkCancellation()
            do {
                let data = try await HLSMaster.fetch(candidate.source.url)
                let manual = Self.candidates(data, for: candidate)
                if let best = manual.max(by: { ($0.height ?? 0, $0.bitrate ?? 0) < ($1.height ?? 0, $1.bitrate ?? 0) }),
                   let index = result.firstIndex(where: { $0.id == candidate.id && $0.source.url == candidate.source.url }) {
                    var adaptive = MediaCandidate(source: candidate.source, id: candidate.id,
                        height: candidate.height ?? best.height, bitrate: candidate.bitrate ?? best.bitrate,
                        frameRate: candidate.frameRate ?? best.frameRate, audioDescription: candidate.audioDescription,
                        unavailableReason: candidate.unavailableReason)
                    adaptive.discovery = candidate.discovery
                    result[index] = adaptive
                }
                result += manual.sorted { ($0.height ?? 0, $0.bitrate ?? 0) > ($1.height ?? 0, $1.bitrate ?? 0) }
                    .prefix(max(0, 40 - result.count))
            } catch {
                try Task.checkCancellation()
                // Unknown rendition metadata never removes the native source.
            }
        }
        return result
    }
}
