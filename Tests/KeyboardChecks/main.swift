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
@MainActor private final class ButtonSink: NSButton {
    var received = 0
    override func keyDown(with event: NSEvent) { received += 1 }
}
@MainActor private final class SegmentSink: NSSegmentedControl {
    var received = 0
    override func keyDown(with event: NSEvent) { received += 1 }
}
@MainActor private final class SliderSink: NSSlider {
    var received = 0
    override func keyDown(with event: NSEvent) { received += 1 }
}
@MainActor private final class TableSink: NSTableView {
    var received = 0
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
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
        let button = ButtonSink(frame: sink.bounds)
        window.contentView = button
        check(window.makeFirstResponder(button), "Cannot install button responder")
        send(49); send(123)
        check(keys.count == 4 && button.received == 2, "Playback keys intercepted a focused button")
        let segments = SegmentSink(frame: sink.bounds)
        segments.segmentCount = 2
        window.contentView = segments
        check(window.makeFirstResponder(segments), "Cannot install segmented control")
        send(49); send(124)
        check(keys.count == 4 && segments.received == 2, "Playback keys intercepted a segmented control")
        let slider = SliderSink(frame: sink.bounds)
        window.contentView = slider
        check(window.makeFirstResponder(slider), "Cannot install slider responder")
        send(49); send(123); send(124)
        check(keys.count == 4 && slider.received == 3, "Playback keys intercepted slider adjustment")
        let table = TableSink(frame: sink.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        table.addTableColumn(column)
        window.contentView = table
        window.makeKey()
        let installed = window.makeFirstResponder(table)
        let responderNow = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        check(installed && window.firstResponder === table, "Cannot install list responder (installed \(installed), responder \(responderNow))")
        send(49); send(123)
        check(keys.count == 4 && table.received == 2, "Playback keys intercepted a list")
        window.resignKey()
        check(!window.isVisible, "Keyboard checks opened a visible window")
        print("PASS window-scoped Space/arrows, repeats, modifiers, disabled actions, text editing, buttons, segments, sliders and lists (headless)")
    }
}
