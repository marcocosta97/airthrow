import AppKit
import SwiftUI

/// Observe the native list viewport without publishing every scroll event to SwiftUI.
/// A newly mounted catalog restores its own offset, independently of selection.
struct CatalogListScrollPosition: NSViewRepresentable {
    let position: CatalogViewportPosition?
    let ids: [String]
    let changed: (CatalogViewportPosition?) -> Void

    func makeNSView(context: Context) -> Observer { Observer() }

    func updateNSView(_ view: Observer, context: Context) {
        view.position = position
        view.ids = ids
        view.changed = changed
        view.restoreOffsetIfNeeded()
        view.scheduleAttachment()
    }

    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.detach() }

    final class Observer: NSView {
        var position: CatalogViewportPosition?
        var ids: [String] = []
        var changed: ((CatalogViewportPosition?) -> Void)?
        private weak var scrollView: NSScrollView?
        private weak var tableView: NSTableView?
        private var attachmentPending = false
        private var restoring = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { scheduleAttachment() }
        }

        func scheduleAttachment() {
            guard scrollView == nil, !attachmentPending else { return }
            attachmentPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.attachmentPending = false
                guard self.window != nil, self.scrollView == nil else { return }
                // SwiftUI places a background beside the list's AppKit host.
                // Search the nearest shared ancestor, never another window.
                var ancestor = self.superview
                while let parent = ancestor {
                    if let table = self.table(in: parent), let scroll = table.enclosingScrollView {
                        self.tableView = table
                        self.attach(scroll)
                        return
                    }
                    ancestor = parent.superview
                }
            }
        }

        private func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView,
               table.convert(table.visibleRect, to: nil).intersects(convert(bounds, to: nil)) {
                return table
            }
            return view.subviews.lazy.compactMap { self.table(in: $0) }.first
        }

        private func attach(_ scroll: NSScrollView) {
            scrollView = scroll
            restoreOffsetIfNeeded()
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                name: NSView.boundsDidChangeNotification, object: clip)
        }

        func restoreOffsetIfNeeded() {
            guard let table = tableView, let scroll = scrollView, !restoring else { return }
            if position == currentPosition() { return }
            restoring = true
            let row = position.flatMap { ids.firstIndex(of: $0.itemID) } ?? 0
            guard row < table.numberOfRows else { restoring = false; return }
            // Realize the target row before applying the within-row offset.
            // Offscreen SwiftUI rows may still have estimated heights.
            table.scrollRowToVisible(row)
            DispatchQueue.main.async { [weak self, weak table, weak scroll] in
                guard let self, let table, let scroll else { return }
                scroll.layoutSubtreeIfNeeded()
                guard row < table.numberOfRows else { self.restoring = false; return }
                let clip = scroll.contentView
                let offset = min(max(0, self.position?.offset ?? 0), table.rect(ofRow: row).height)
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: table.rect(ofRow: row).minY + offset))
                scroll.reflectScrolledClipView(clip)
                self.restoring = false
                self.scrolled()
            }
        }

        private func currentPosition() -> CatalogViewportPosition? {
            guard let table = tableView else { return nil }
            let row = table.rows(in: table.visibleRect).location
            guard ids.indices.contains(row) else { return nil }
            return CatalogViewportPosition(itemID: ids[row], offset: max(0, table.visibleRect.minY - table.rect(ofRow: row).minY))
        }

        @objc private func scrolled() {
            guard !restoring else { return }
            position = currentPosition()
            changed?(position)
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
            tableView = nil
        }
    }
}
