import AppKit
#if SWIFT_PACKAGE
import AirThrowCore
#endif

@MainActor
private enum MenuMetrics {
    static let width: CGFloat = 280
    static let inset: CGFloat = 14
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

/// An inline AppKit palette retains the compact transport layout and native
/// menu keyboard navigation, highlighting, and accessibility.
@MainActor
final class MenuControlsMenu: NSMenu {
    let commands: [MenuCommand]

    init(controls: MenuControlState, target: AnyObject, action: Selector) {
        commands = MenuModel.controlCommands(for: controls)
        super.init(title: "Playback controls")
        presentationStyle = .palette
        autoenablesItems = false
        for command in commands {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = command.rawValue
            addItem(item)
        }
        update(controls: controls)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(controls: MenuControlState) {
        for (command, item) in zip(commands, items) {
            let spec = Self.spec(for: command, controls: controls)
            item.title = spec.label
            item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
            item.toolTip = spec.label
            item.isEnabled = spec.enabled
            item.state = .off
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
