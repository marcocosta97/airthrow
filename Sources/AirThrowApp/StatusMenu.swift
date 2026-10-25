import AppKit
#if SWIFT_PACKAGE
import AirThrowCore
#endif

@MainActor
private enum MenuMetrics {
    static let width: CGFloat = 280
    static let inset: CGFloat = 14
    static let buttonSize: CGFloat = 34
}

/// Playback, connection, and timing remain distinct even with long media titles.
@MainActor
final class MenuCardView: NSView {
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(title: String, status: String, detail: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 90))
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.preferredMaxLayoutWidth = MenuMetrics.width - 2 * MenuMetrics.inset
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        for label in [statusLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [titleLabel, statusLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.setCustomSpacing(6, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MenuMetrics.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -MenuMetrics.inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        update(title: title, status: status, detail: detail)
    }

    required init?(coder: NSCoder) { nil }

    func update(title: String, status: String, detail: String) {
        for (label, text) in [(titleLabel, title), (statusLabel, status), (detailLabel, detail)] {
            label.stringValue = text
            label.toolTip = text
        }
    }
}

/// Transport order matches the player. Stop has its own space to avoid accidental unloading.
@MainActor
final class MenuControlRow: NSView {
    private var buttons: [MenuCommand: MenuControlButton] = [:]
    let commands: [MenuCommand]

    init(controls: MenuControlState, target: AnyObject, action: Selector) {
        commands = MenuModel.controlCommands(for: controls)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 42))
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for command in commands {
            if command == .stop {
                let divider = NSBox()
                divider.boxType = .separator
                if let preceding = stack.arrangedSubviews.last {
                    stack.setCustomSpacing(8, after: preceding)
                }
                stack.addArrangedSubview(divider)
                NSLayoutConstraint.activate([
                    divider.widthAnchor.constraint(equalToConstant: 1),
                    divider.heightAnchor.constraint(equalToConstant: 18),
                ])
                stack.setCustomSpacing(8, after: divider)
            }
            let button = MenuControlButton()
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            button.target = target
            button.action = action
            buttons[command] = button
            stack.addArrangedSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: MenuMetrics.buttonSize),
                button.heightAnchor.constraint(equalToConstant: MenuMetrics.buttonSize),
            ])
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(controls: controls)
    }

    required init?(coder: NSCoder) { nil }

    /// Updates in place, preserving the pointer and accessibility targets while the menu is open.
    func update(controls: MenuControlState) {
        for (command, button) in buttons {
            let spec = Self.spec(for: command, controls: controls)
            button.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            button.toolTip = spec.label
            button.setAccessibilityLabel(spec.label)
            button.isEnabled = spec.enabled
        }
    }

    private static func spec(for command: MenuCommand, controls: MenuControlState)
        -> (symbol: String, label: String, enabled: Bool) {
        switch command {
        case .previous:
            ("backward.end.fill", "Previous in Queue", controls.playlist?.canPrevious == true)
        case .skipBackward: ("gobackward.10", "Back 10 Seconds", controls.canSkipBackward)
        case .togglePlayback:
            (controls.isPlaying ? "pause.fill" : "play.fill",
             controls.isPlaying ? "Pause" : "Play", controls.canToggle)
        case .stop: ("stop.fill", "Stop and Unload", controls.canStop)
        case .skipForward: ("goforward.10", "Forward 10 Seconds", controls.canSkipForward)
        case .next:
            ("forward.end.fill", "Next in Queue", controls.playlist?.canNext == true)
        case .showController, .quit: ("", "", false)
        }
    }
}

@MainActor
private final class MenuControlButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        // AppKit does not send mouseEntered when an open menu changes under the pointer.
        if let window {
            hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            (isHighlighted ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}
