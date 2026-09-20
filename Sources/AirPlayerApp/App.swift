import AppKit
import Combine
import SwiftUI
#if SWIFT_PACKAGE
import AirPlayerCore
#endif

@main
@MainActor
struct AirPlayerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSMenuDelegate {
    private static let playlistToolbarIdentifier = NSToolbarItem.Identifier("app.airplayer.playlist")
    private let controller = PlaybackController()
    private let presentation = ControllerPresentation()
    private let server = CommandServer()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var playlistToolbarItem: NSToolbarItem?
    private var playlistToolbarButton: NSButton?
    private var playlistToolbarWidth: NSLayoutConstraint?
    private var snapshotObservation: AnyCancellable?
    private var playlistShownInWindow = false
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        do {
            try server.start { [weak self] request, reply in
                Task { @MainActor in
                    guard let self else { reply(Response(error: AppFailure(.appUnavailable, "AirPlayer is shutting down."))); return }
                    reply(self.handle(request))
                }
            }
        } catch {
            // A second copy should reveal the existing app rather than steal its socket.
            if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "app.airplayer.mac").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                existing.activate(options: [])
                NSApp.terminate(nil)
                return
            }
            controller.displayError(error)
        }
        MediaPreparer.cleanAbandonedFiles()
        showWindow()
        snapshotObservation = controller.$snapshot.sink { [weak self] snapshot in
            self?.updatePlaylistAvailability(snapshot.queue != nil)
        }
    }

    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 520), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "AirPlayer"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ControllerView(controller: controller, presentation: presentation))
            let toolbar = NSToolbar(identifier: "AirPlayerControllerToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            toolbar.autosavesConfiguration = false
            window.toolbarStyle = .unifiedCompact
            window.toolbar = toolbar
            window.center()
            window.setFrameAutosaveName("AirPlayerController")
            window.setContentSize(NSSize(width: 470, height: window.contentLayoutRect.height))
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.playlistToolbarIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.playlistToolbarIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.playlistToolbarIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let button = NSButton(image: NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Show playlist")!,
                              target: self, action: #selector(togglePlaylist))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 28),
            container.heightAnchor.constraint(equalToConstant: 32),
        ])
        let width = container.widthAnchor.constraint(equalToConstant: 55)
        width.isActive = true
        item.view = container
        item.label = "Playlist"
        item.paletteLabel = "Playlist"
        item.isBordered = false
        item.autovalidates = false
        playlistToolbarItem = item
        playlistToolbarButton = button
        playlistToolbarWidth = width
        updatePlaylistButton()
        return item
    }

    @objc private func togglePlaylist() {
        guard controller.snapshot.queue != nil else { return }
        presentation.playlistVisible.toggle()
        setPlaylistShown(presentation.playlistVisible)
    }

    private func updatePlaylistAvailability(_ available: Bool) {
        playlistToolbarButton?.isEnabled = available
        if available {
            presentation.playlistVisible = true
            setPlaylistShown(true)
        } else {
            setPlaylistShown(false)
        }
        updatePlaylistButton()
    }

    private func updatePlaylistButton() {
        let visible = presentation.playlistVisible && controller.snapshot.queue != nil
        playlistToolbarItem?.label = visible ? "Hide Playlist" : "Show Playlist"
        playlistToolbarItem?.toolTip = visible ? "Hide playlist" : "Show playlist"
        playlistToolbarButton?.toolTip = visible ? "Hide playlist" : "Show playlist"
        playlistToolbarButton?.setAccessibilityLabel(visible ? "Hide playlist" : "Show playlist")
        playlistToolbarWidth?.constant = visible ? 326 : 55
    }

    private func setPlaylistShown(_ shown: Bool) {
        guard shown != playlistShownInWindow, let window else {
            updatePlaylistButton()
            return
        }
        playlistShownInWindow = shown
        let targetWidth: CGFloat = shown ? 741 : 470
        let widthChange = targetWidth - window.contentLayoutRect.width
        var frame = window.frame
        frame.size.width += widthChange
        window.setFrame(frame, display: true, animate: false)
        updatePlaylistButton()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AirPlayer Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !terminating {
            terminating = true
            server.stop()
            Task { @MainActor in
                await controller.shutdownAndWait()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { server.stop(); controller.shutdown() }

    private func handle(_ request: Request) -> Response {
        do {
            switch request.command {
            case .open:
                guard let url = request.url else { throw AppFailure(.invalidRequest, "The open command requires a video URL.") }
                try controller.load(url)
                if !controller.snapshot.externalPlaybackActive { showWindow() }
                return Response(message: controller.snapshot.loadingPhase == "resolving"
                    ? "Finding video. Choose a receiver, then play." : "Loading video. Choose a receiver, then play.",
                    pending: true, status: controller.snapshot)
            case .play:
                try controller.play()
                return Response(message: "Playback requested.", pending: true, status: controller.snapshot)
            case .pause: controller.pause()
            case .stop: controller.stop()
            case .seek:
                guard let seconds = request.seconds else { throw AppFailure(.invalidRequest, "The seek command requires seconds.") }
                try controller.seek(seconds)
                return Response(message: "Seek requested.", pending: true, status: controller.snapshot)
            case .previous:
                try controller.previous()
                return Response(message: "Previous playlist item requested.", pending: true, status: controller.snapshot)
            case .next:
                try controller.next()
                return Response(message: "Next playlist item requested.", pending: true, status: controller.snapshot)
            case .show: showWindow()
            case .status: controller.refresh()
            }
            return Response(message: request.command == .status ? controller.snapshot.state.rawValue : "Done.", status: controller.snapshot)
        } catch {
            return Response(error: error as? AppFailure ?? AppFailure(.playbackFailed, "The operation failed."), status: controller.snapshot)
        }
    }

    @objc private func showAbout() {
        let revision = Bundle.main.url(forResource: "BuildCommit", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Commit: \(revision ?? "unknown")",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        ])
    }

    private func makeMenu() {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "About AirPlayer", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let show = appMenu.addItem(withTitle: "Show Controller", action: #selector(showWindow), keyEquivalent: "0")
        show.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AirPlayer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit AirPlayer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "airplay.video", accessibilityDescription: "AirPlayer")
        item.button?.toolTip = "AirPlayer"
        let menu = NSMenu()
        // Rebuild from the latest observed snapshot when the menu opens. AppKit's
        // automatic validation would otherwise replace the model's enablement.
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // MARK: - Status-item menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        for element in MenuModel.elements(for: controller.snapshot) {
            switch element {
            case .card(let title, let status):
                let item = NSMenuItem()
                item.view = MenuCardView(title: title, status: status)
                item.setAccessibilityLabel("\(title). \(status)")
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            case .controls(let controls):
                let item = NSMenuItem()
                item.view = MenuControlRow(controls: controls, target: self,
                    action: #selector(runMenuControl(_:)))
                item.setAccessibilityLabel("Playback controls")
                menu.addItem(item)
            case .command(let command):
                let item = NSMenuItem(title: menuTitle(command),
                    action: #selector(runMenuCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command.rawValue
                menu.addItem(item)
            }
        }
    }

    private func menuTitle(_ command: MenuCommand) -> String {
        switch command {
        case .previous: "Previous Playlist Item"
        case .skipBackward: "Back 10 Seconds"
        case .togglePlayback: PlaybackPolicy.isPlaying(controller.snapshot) ? "Pause" : "Play"
        case .stop: "Stop"
        case .skipForward: "Forward 10 Seconds"
        case .next: "Next Playlist Item"
        case .showController: "Show AirPlayer"
        case .quit: "Quit AirPlayer"
        }
    }

    @objc private func runMenuControl(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let command = MenuCommand(rawValue: rawValue) else { return }
        run(command)
        statusItem?.menu?.cancelTracking()
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let command = MenuCommand(rawValue: rawValue) else { return }
        run(command)
    }

    private func run(_ command: MenuCommand) {
        do {
            switch command {
            case .previous: try controller.previous()
            case .skipBackward: try skip(by: -MenuModel.skipInterval)
            case .togglePlayback:
                if PlaybackPolicy.isPlaying(controller.snapshot) { controller.pause() }
                else { try controller.play() }
            case .stop: controller.stop()
            case .skipForward: try skip(by: MenuModel.skipInterval)
            case .next: try controller.next()
            case .showController: showWindow()
            case .quit: NSApp.terminate(nil)
            }
        } catch {
            controller.displayError(error)
        }
    }

    private func skip(by delta: Double) throws {
        let snapshot = controller.snapshot
        guard let range = PlaybackPolicy.activeSeekRange(snapshot) else {
            throw AppFailure(.unsupportedOperation, "This video does not currently support seeking.")
        }
        let position = snapshot.position ?? range.start
        try controller.seek(min(max(position + delta, range.start), range.end))
    }
}

@MainActor
private enum MenuMetrics {
    static let width: CGFloat = 168
}

/// Compact playback context at the top of the status-item menu.
@MainActor
private final class MenuCardView: NSView {
    init(title: String, status: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 46))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [titleLabel, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let labelWidth = MenuMetrics.width - 26
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -13),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: labelWidth),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: labelWidth),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// Inline transport controls. Playlist navigation appears only for a queue.
@MainActor
private final class MenuControlRow: NSView {
    init(controls: MenuControlState, target: AnyObject, action: Selector) {
        let commands = MenuModel.controlCommands(for: controls)
        let controlsWidth = CGFloat(commands.count) * Self.buttonWidth
        super.init(frame: NSRect(x: 0, y: 0, width: max(MenuMetrics.width, controlsWidth), height: 36))
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for command in commands {
            let spec = Self.spec(for: command, controls: controls)
            let button = NSButton()
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = Self.symbol(spec.symbol)
            button.toolTip = spec.label
            button.setAccessibilityLabel(spec.label)
            button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            button.target = target
            button.action = action
            button.isEnabled = spec.enabled
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: controlsWidth),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private static let buttonWidth: CGFloat = 30

    private static func spec(for command: MenuCommand, controls: MenuControlState)
        -> (symbol: String, label: String, enabled: Bool) {
        switch command {
        case .previous:
            ("backward.end.fill", "Previous Playlist Item", controls.playlist?.canPrevious == true)
        case .skipBackward: ("gobackward.10", "Back 10 Seconds", controls.canSeek)
        case .togglePlayback:
            (controls.isPlaying ? "pause.fill" : "play.fill",
             controls.isPlaying ? "Pause" : "Play", controls.canToggle)
        case .stop: ("stop.fill", "Stop", controls.canStop)
        case .skipForward: ("goforward.10", "Forward 10 Seconds", controls.canSeek)
        case .next:
            ("forward.end.fill", "Next Playlist Item", controls.playlist?.canNext == true)
        case .showController, .quit: ("", "", false)
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
    }
}
