import AppKit

@MainActor private final class KeySink: NSView {
    var received = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { received += 1 }
}
@MainActor private final class TextSink: NSTextView {
    var received = 0
    override func keyDown(with event: NSEvent) { received += 1 }
}

@main @MainActor struct KeyboardChecks {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL \(message)"); exit(1) }
    }
    static func main() {
        _ = NSApplication.shared
        // This test never shows, activates or focuses a visible window.
        let screen = NSScreen.screens.first { $0.localizedName.lowercased() == "codex" }
        let origin = screen?.visibleFrame.origin ?? .zero
        let window = PlaybackKeyboardWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 320, height: 160)),
                                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let sink = KeySink(frame: window.contentView!.bounds)
        window.contentView = sink
        check(window.makeFirstResponder(sink), "Cannot install keyboard responder")
        var keys: [PlaybackKey] = []
        var enabled = true
        window.playbackKeyAction = { key in
            guard enabled else { return false }
            keys.append(key); return true
        }
        func send(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: code == 49 ? " " : "", charactersIgnoringModifiers: code == 49 ? " " : "",
                isARepeat: repeated, keyCode: code)!
            window.sendEvent(event)
        }
        send(49); send(123); send(124)
        check(keys == [.toggle, .backward, .forward] && sink.received == 0, "Bare playback keys were not consumed")
        send(49, repeated: true)
        check(keys.count == 3, "Holding Space repeatedly toggled playback")
        send(123, repeated: true)
        check(keys.last == .backward && keys.count == 4, "Holding an arrow did not repeat seeking")
        for modifier in [NSEvent.ModifierFlags.command, .control, .option, .shift] {
            send(49, modifiers: modifier)
        }
        check(keys.count == 4 && sink.received == 4, "Modified keys lost native handling")
        enabled = false
        send(49); send(124)
        check(keys.count == 4 && sink.received == 6, "Disabled playback actions consumed native keys")
        enabled = true
        let text = TextSink(frame: sink.bounds)
        window.contentView = text
        check(window.makeFirstResponder(text), "Cannot install text responder")
        send(49); send(123); send(124)
        check(keys.count == 4 && text.received == 3, "Playback keys intercepted text editing")
        check(!window.isVisible, "Keyboard checks opened a visible window")
        print("PASS window-scoped Space/arrows, repeats, modifiers, disabled actions and text editing (headless)")
    }
}
