import AppKit
import SwiftUI

/// Keep search in the catalog header, with AppKit's clear button and Escape behavior.
struct CatalogSearchField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String

    static func field(in window: NSWindow?) -> NSSearchField? {
        guard let window, window.attachedSheet == nil else { return nil }
        func find(_ view: NSView) -> NSSearchField? {
            guard !view.isHidden else { return nil }
            if let field = view as? NSSearchField, field.isEnabled { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    static func focus(in window: NSWindow?) {
        guard let field = field(in: window) else { return }
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.sendsSearchStringImmediately = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.isEnabled = context.environment.isEnabled
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            search(field)
        }

        @objc func search(_ field: NSSearchField) {
            if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
        }
    }
}
