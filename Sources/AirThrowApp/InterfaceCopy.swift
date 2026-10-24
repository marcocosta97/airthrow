import Foundation

/// Counted interface strings. The English forms live in the string catalog so
/// a single item is not labelled with a plural.
enum InterfaceCopy {
    static func titles(_ count: Int) -> String {
        String(localized: "\(count) titles")
    }

    static func episodesNotImported(_ count: Int) -> String {
        String(localized: "\(count) episodes not imported")
    }

    static func channels(visible: Int, total: Int) -> String {
        if total == 1 { return String(localized: "1 channel") }
        return String(localized: "\(visible) of \(total) channels")
    }

    static func unsupportedEntriesNotImported(_ count: Int) -> String {
        String(localized: "\(count) unsupported entries were not imported.")
    }

    static func skippedPlaylistItems(_ count: Int) -> String {
        String(localized: "Skipped \(count) unavailable playlist items.")
    }

    static func moreRanges(_ count: Int) -> String {
        String(localized: "\(count) more ranges")
    }
}
