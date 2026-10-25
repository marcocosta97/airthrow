import Foundation

/// Frames one JSON array element at a time. Provider metadata that the library
/// doesn't use is released immediately instead of building a catalog-sized DOM.
final class XtreamListingDecoder: @unchecked Sendable {
    static let maximumBytes = 512 * 1024 * 1024
    private static let maximumRecordBytes = 2 * 1024 * 1024
    private static let maximumRecords = 250_000
    private enum Phase { case start, bomSecond, bomThird, emptyObject, firstValue, nextValue, element, separator, done }
    private let lock = NSLock()
    private let section: XtreamSection
    private var phase = Phase.start
    private var acceptedBOM = false
    private var record = Data()
    private var depth = 0
    private var quoted = false
    private var escaped = false
    private var items: [XtreamItem] = []
    private var seen = Set<String>()
    private var records = 0
    private var skipped = 0

    init(section: XtreamSection) { self.section = section }

    func consume(_ data: Data) throws {
        try lock.withLock {
            try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var start: Int? = phase == .element ? 0 : nil
                func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
                func append(until end: Int) throws {
                    guard let begin = start else { return }
                    guard end - begin <= Self.maximumRecordBytes - record.count else { throw XtreamFailure.catalogTooLarge }
                    record.append(contentsOf: bytes[begin..<end])
                    start = nil
                }
                for index in bytes.indices {
                    let byte = bytes[index]
                    switch phase {
                    case .start:
                        if whitespace(byte) { continue }
                        if byte == 0xEF, !acceptedBOM { acceptedBOM = true; phase = .bomSecond }
                        else if byte == 91 { phase = .firstValue }
                        else if byte == 123 { phase = .emptyObject }
                        else { throw XtreamFailure.invalidResponse }
                        continue
                    case .bomSecond:
                        guard byte == 0xBB else { throw XtreamFailure.invalidResponse }
                        phase = .bomThird; continue
                    case .bomThird:
                        guard byte == 0xBF else { throw XtreamFailure.invalidResponse }
                        phase = .start; continue
                    case .emptyObject:
                        if whitespace(byte) { continue }
                        guard byte == 125 else { throw XtreamFailure.invalidResponse }
                        phase = .done; continue
                    case .done:
                        guard whitespace(byte) else { throw XtreamFailure.invalidResponse }
                        continue
                    case .separator:
                        if whitespace(byte) { continue }
                        try separator(byte); continue
                    case .firstValue, .nextValue:
                        if whitespace(byte) { continue }
                        if byte == 93, phase == .firstValue { phase = .done; continue }
                        guard byte != 93 && byte != 44 else { throw XtreamFailure.invalidResponse }
                        phase = .element; start = index
                    case .element: break
                    }
                    // A primitive ends at whitespace or the array's delimiter.
                    if !quoted && depth == 0 && (whitespace(byte) || byte == 44 || byte == 93) {
                        try append(until: index); try emit(); phase = .separator
                        if !whitespace(byte) { try separator(byte) }
                        continue
                    }
                    if quoted {
                        if escaped { escaped = false }
                        else if byte == 92 { escaped = true }
                        else if byte == 34 { quoted = false }
                        else { continue }
                    } else if byte == 34 { quoted = true }
                    else if byte == 123 || byte == 91 {
                        depth += 1
                        guard depth <= 64 else { throw XtreamFailure.invalidResponse }
                    } else if byte == 125 || byte == 93 {
                        depth -= 1
                        guard depth >= 0 else { throw XtreamFailure.invalidResponse }
                    }
                    if !quoted && depth == 0 && (byte == 34 || byte == 125 || byte == 93) {
                        try append(until: index + 1); try emit(); phase = .separator
                    }
                }
                try append(until: bytes.count)
            }
        }
    }

    func finish() throws -> XtreamListing {
        try lock.withLock {
            guard phase == .done else { throw XtreamFailure.invalidResponse }
            return XtreamListing(items: items, skipped: skipped, truncated: false)
        }
    }

    private func separator(_ byte: UInt8) throws {
        if byte == 44 { phase = .nextValue }
        else if byte == 93 { phase = .done }
        else { throw XtreamFailure.invalidResponse }
    }

    private func emit() throws {
        records += 1
        guard records <= Self.maximumRecords else { throw XtreamFailure.catalogTooLarge }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: record, options: [.fragmentsAllowed]) }
        catch { throw XtreamFailure.invalidResponse }
        record.removeAll(keepingCapacity: true)
        guard let row = value as? [String: Any],
              let id = XtreamParsing.id(row[section.listingIDKey]),
              let name = XtreamParsing.text(row["name"]), seen.insert(id).inserted else { skipped += 1; return }
        items.append(XtreamItem(id: id, name: name, categoryID: XtreamParsing.id(row["category_id"]),
            container: XtreamParsing.text(row["container_extension"]) ?? "mp4",
            summary: XtreamParsing.text(row["plot"]), year: XtreamParsing.text(row["year"]),
            rating: XtreamParsing.text(row["rating"])))
    }
}
