import AppKit

enum PlaybackKey: Equatable {
    case toggle, backward, forward
}

/// Window-scoped transport keys for an AppKit-hosted SwiftUI controller.
/// Text editing, lists, segmented controls, buttons, modified keys, sheets
/// and popovers retain native handling.
@MainActor
class PlaybackKeyboardWindow: NSWindow {
    var playbackKeyAction: ((PlaybackKey) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.type == .keyDown, event.windowNumber == windowNumber,
           event.modifierFlags.intersection(modifiers).isEmpty, attachedSheet == nil,
           !Self.controlOwnsKey(firstResponder) {
            let key: PlaybackKey?
            switch event.keyCode {
            case 49: key = .toggle
            case 123: key = .backward
            case 124: key = .forward
            default: key = nil
            }
            if let key {
                // Holding Space should not repeatedly toggle playback.
                if event.isARepeat, key == .toggle { return }
                if playbackKeyAction?(key) == true { return }
            }
        }
        super.sendEvent(event)
    }

    /// Space and arrows move selection in these controls, including when Full
    /// Keyboard Access makes a button the first responder. A focused cell is
    /// inside the control, so walk its ancestors.
    private static func controlOwnsKey(_ responder: NSResponder?) -> Bool {
        var current: NSResponder? = responder
        while let view = current as? NSView {
            if view is NSText || view is NSTextField || view is NSPopUpButton || view is NSComboBox
                || view is NSTableView || view is NSOutlineView || view is NSCollectionView
                || view is NSSegmentedControl || view is NSButton {
                return true
            }
            current = view.superview
        }
        return false
    }
}
