import SwiftUI
import AppKit

/// Category filter for inspector catalogs. A nil value means all categories.
struct CategoryPopUpField: NSViewRepresentable {
    struct Option: Equatable {
        let title: String
        let value: String?
    }
    @Binding var selection: String?
    let options: [Option]
    let accessibilityLabel: String

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setAccessibilityLabel(accessibilityLabel)
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.cell?.lineBreakMode = .byTruncatingTail
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = options.map(\.title)
        if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
        button.selectItem(at: options.firstIndex { $0.value == selection } ?? 0)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        // Menu contents must not determine the inspector's width.
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: CategoryPopUpField
        init(_ parent: CategoryPopUpField) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            guard parent.options.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.options[sender.indexOfSelectedItem].value
        }
    }
}
