import AppKit

enum PlaybackKey: Equatable {
    case toggle, backward, forward
}

/// Window-scoped transport keys for an AppKit-hosted SwiftUI controller.
/// Media lists keep transport shortcuts after selection. Text editors and
/// focused buttons/sliders retain their native Space and arrow-key behavior.
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

    /// SwiftUI may focus a descendant of an AppKit control. Walk its ancestors
    /// so inline editors keep editing keys even when they are inside a media list.
    static func controlOwnsKey(_ responder: NSResponder?) -> Bool {
        var current: NSResponder? = responder
        while let view = current as? NSView {
            if view is NSTableView { return false }
            if view is NSText || view is NSControl {
                return true
            }
            current = view.superview
        }
        return false
    }
}
