import AppKit

enum PlaybackKey: Equatable {
    case toggle, backward, forward
}

/// Window-scoped transport keys for an AppKit-hosted SwiftUI controller.
/// Text editing, modified keys, sheets and popovers retain native handling.
@MainActor
class PlaybackKeyboardWindow: NSWindow {
    var playbackKeyAction: ((PlaybackKey) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.type == .keyDown, event.windowNumber == windowNumber,
           event.modifierFlags.intersection(modifiers).isEmpty, attachedSheet == nil,
           !(firstResponder is NSText), !(firstResponder is NSTextField),
           !(firstResponder is NSPopUpButton), !(firstResponder is NSComboBox) {
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
}
