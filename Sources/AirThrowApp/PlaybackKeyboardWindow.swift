import AppKit

enum PlaybackKey: Equatable {
    case toggle, backward, forward
}

/// Window-scoped transport keys for an AppKit-hosted SwiftUI controller.
/// A text field keeps Space and the arrows. Lists and buttons do not: the
/// library stays focused after a click, and that was swallowing playback keys.
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

    /// A focused cell sits inside the field, so walk its ancestors. Buttons,
    /// lists, and segmented controls are not included: they remain first
    /// responder after an ordinary click and would block Space and the arrows.
    static func controlOwnsKey(_ responder: NSResponder?) -> Bool {
        var current: NSResponder? = responder
        while let view = current as? NSView {
            if view is NSText || view is NSTextField || view is NSPopUpButton || view is NSComboBox {
                return true
            }
            current = view.superview
        }
        return false
    }
}
