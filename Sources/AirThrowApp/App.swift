import AppKit
import Combine
import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

@main
@MainActor
struct AirThrowMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSToolbarDelegate {
    // Fixed playback surface reserves room for a two-line title and warning.
    private static let controllerHeight: CGFloat = 464
    private let controller = PlaybackController()
    private let cookieStatus = CookieStatusModel()
    private let presentation = ControllerPresentation()
    private let server = CommandServer()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var splitViewController: NSSplitViewController?
    private var inspectorItem: NSSplitViewItem?
    private var inspectorObservation: NSKeyValueObservation?
    private var statusItem: NSStatusItem?
    private var presentationObservation: AnyCancellable?
    private var snapshotObservation: AnyCancellable?
    private var menuObservation: AnyCancellable?
    private var menuIsOpen = false
    private var menuCardView: MenuCardView?
    private var menuControlRow: MenuControlRow?
    private var menuControlsItem: NSMenuItem?
    private var terminating = false
    private var didFinishLaunching = false
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        do {
            try server.start { [weak self] request, reply in
                Task { @MainActor in
                    guard let self else { reply(Response(error: AppFailure(.appUnavailable, "AirThrow is shutting down."))); return }
                    reply(self.handle(request))
                }
            }
        } catch {
            // A second copy should reveal the existing app rather than steal its socket.
            if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "it.mcosta.airthrow").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                existing.activate(options: [])
                NSApp.terminate(nil)
                return
            }
            controller.displayError(error)
        }
        MediaPreparer.cleanAbandonedFiles()
        showWindow()
        snapshotObservation = controller.$snapshot
            .map { $0.queue != nil }
            .removeDuplicates()
            // @Published emits before storing the new snapshot. Defer AppKit
            // layout until the controller and inspector can read that value.
            .receive(on: RunLoop.main)
            .sink { [weak self] available in
                self?.updatePlaylistAvailability(available)
        }
        menuObservation = controller.$snapshot
            .sink { [weak self] snapshot in
                self?.refreshOpenMenu(snapshot)
        }
        presentationObservation = presentation.$playlistVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.setInspector(collapsed: !visible)
            }
        didFinishLaunching = true
        openPendingFiles()
    }

    /// Files opened from Finder, the Dock, or `open -a` load into the shared
    /// session. A cold launch buffers them until the controller is ready.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpenURLs.append(contentsOf: urls.filter(\.isFileURL))
        if didFinishLaunching { openPendingFiles() }
    }

    private func openPendingFiles() {
        guard !pendingOpenURLs.isEmpty else { return }
        let files = pendingOpenURLs
        pendingOpenURLs.removeAll()
        guard let file = files.first else { return }
        do { try controller.load(file.path) }
        catch { controller.displayError(error) }
        showWindow()
    }

    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ControllerMetrics.width, height: Self.controllerHeight), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "AirThrow"
            window.backgroundColor = SurfaceColor.window
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.delegate = self

            let mainHosting = NSHostingController(rootView: ControllerView(controller: controller))
            mainHosting.sizingOptions = []
            mainHosting.preferredContentSize = NSSize(width: ControllerMetrics.width, height: Self.controllerHeight)
            let playlistHosting = NSHostingController(rootView: PlaylistPanel(controller: controller))
            playlistHosting.sizingOptions = []

            let split = NSSplitViewController()
            let contentItem = NSSplitViewItem(viewController: mainHosting)
            contentItem.minimumThickness = ControllerMetrics.minWidth
            contentItem.canCollapse = false
            let inspectorItem = NSSplitViewItem(inspectorWithViewController: playlistHosting)
            inspectorItem.minimumThickness = ControllerMetrics.playlistWidth
            inspectorItem.maximumThickness = ControllerMetrics.playlistMaximumWidth
            inspectorItem.isCollapsed = true
            // Keep the controller at its size and let the window take on the
            // inspector's width, matching the native inspector behavior.
            inspectorItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
            split.addSplitViewItem(contentItem)
            split.addSplitViewItem(inspectorItem)
            splitViewController = split
            self.inspectorItem = inspectorItem
            // Keep the app's intent in step with the native toolbar toggle.
            inspectorObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
                guard let collapsed = change.newValue else { return }
                Task { @MainActor [weak self] in
                    self?.presentation.playlistVisible = !collapsed
                }
            }

            let toolbar = NSToolbar(identifier: "AirThrowToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified

            window.contentViewController = split
            window.center()
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .toggleInspector]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == .toggleInspector else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Playlist"
        item.paletteLabel = "Playlist"
        item.toolTip = "Show or hide the playlist"
        item.action = #selector(NSSplitViewController.toggleInspector(_:))
        return item
    }

    /// Horizontal resizing only: the proposed width is honored, the height is
    /// pinned so the controller keeps its designed vertical layout.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let inspectorOpen = !(inspectorItem?.isCollapsed ?? true)
        let minimum = ControllerMetrics.minWidth + (inspectorOpen ? ControllerMetrics.playlistWidth : 0)
        return NSSize(width: max(frameSize.width, minimum), height: sender.frame.height)
    }

    private func updatePlaylistAvailability(_ available: Bool) {
        presentation.playlistVisible = available
    }

    /// AppKit animates the inspector item's collapse; because the split view
    /// controller owns the window's content, the window frame and the panel move
    /// in one coordinated animation instead of two competing ones.
    private func setInspector(collapsed: Bool) {
        guard let inspectorItem, inspectorItem.isCollapsed != collapsed else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            inspectorItem.isCollapsed = collapsed
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ControllerMetrics.animationDuration
            inspectorItem.animator().isCollapsed = collapsed
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "AirThrow Settings"
            window.backgroundColor = .textBackgroundColor
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(controller: controller, cookieStatus: cookieStatus))
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
            Task { @MainActor in
                // A client may still be waiting for a main-actor reply. Drain
                // the command queue without blocking that reply or the UI.
                await Task.detached { [server] in server.stop() }.value
                await controller.shutdownAndWait()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { server.stop(); controller.shutdown() }

    private func handle(_ request: Request) -> Response {
        guard !terminating else {
            return Response(error: AppFailure(.appUnavailable, "AirThrow is shutting down."))
        }
        do {
            switch request.command {
            case .open:
                guard let url = request.url else { throw AppFailure(.invalidRequest, "The open command requires a video URL or local file path.") }
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
            case .status, .sources: controller.refresh()
            case .source:
                guard let id = request.sourceID else { throw AppFailure(.invalidRequest, "Choose a source ID or automatic.") }
                try controller.selectSource(id)
                return Response(message: "Reloading the selected source, paused.", pending: true, status: controller.snapshot)
            case .conversion:
                guard let allowed = request.allowVideoConversion else {
                    throw AppFailure(.invalidRequest, "Choose allow-video or avoid-video.")
                }
                controller.setVideoConversionAllowed(allowed)
                return Response(message: "Conversion preference saved. Applies to the next load or source choice.", status: controller.snapshot)
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

    @objc private func showHelp() {
        guard let url = URL(string: "https://github.com/marcocosta97/airthrow#play-a-video") else { return }
        NSWorkspace.shared.open(url)
    }

    private func makeMenu() {
        let main = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "About AirThrow", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let show = appMenu.addItem(withTitle: "Show Controller", action: #selector(showWindow), keyEquivalent: "0")
        show.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AirThrow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        let guide = help.addItem(withTitle: "AirThrow Help", action: #selector(showHelp), keyEquivalent: "")
        guide.target = self
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = main

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "airplay.video", accessibilityDescription: "AirThrow")
        item.button?.toolTip = "AirThrow"
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
                let card = MenuCardView(title: title, status: status)
                item.view = card
                item.setAccessibilityLabel("\(title). \(status)")
                menu.addItem(item)
                menuCardView = card
            case .separator:
                menu.addItem(.separator())
            case .controls(let controls):
                let item = NSMenuItem()
                let row = MenuControlRow(controls: controls, target: self,
                    action: #selector(runMenuControl(_:)))
                item.view = row
                item.setAccessibilityLabel("Playback controls")
                menu.addItem(item)
                menuControlRow = row
                menuControlsItem = item
            case .command(let command):
                if command == .quit {
                    let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
                    settings.target = self
                    menu.addItem(settings)
                }
                let item = NSMenuItem(title: menuTitle(command),
                    action: #selector(runMenuCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = command.rawValue
                menu.addItem(item)
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menuIsOpen = false
        menuCardView = nil
        menuControlRow = nil
        menuControlsItem = nil
    }

    /// Keeps the already-open menu's card and controls in step with playback,
    /// instead of leaving stale glyphs until the menu is reopened.
    private func refreshOpenMenu(_ snapshot: PlaybackSnapshot) {
        guard menuIsOpen else { return }
        for element in MenuModel.elements(for: snapshot) {
            switch element {
            case .card(let title, let status):
                menuCardView?.update(title: title, status: status)
            case .controls(let controls):
                if menuControlRow?.commands != MenuModel.controlCommands(for: controls) {
                    let row = MenuControlRow(controls: controls, target: self,
                                             action: #selector(runMenuControl(_:)))
                    menuControlsItem?.view = row
                    menuControlRow = row
                } else {
                    menuControlRow?.update(controls: controls)
                }
            default:
                break
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
        case .showController: "Show Controller"
        case .quit: "Quit"
        }
    }

    @objc private func runMenuControl(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let command = MenuCommand(rawValue: rawValue) else { return }
        run(command)
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
            case .skipBackward: try controller.skip(by: -MenuModel.skipInterval)
            case .togglePlayback:
                if PlaybackPolicy.isPlaying(controller.snapshot) { controller.pause() }
                else { try controller.play() }
            case .stop: controller.stop()
            case .skipForward: try controller.skip(by: MenuModel.skipInterval)
            case .next: try controller.next()
            case .showController: showWindow()
            case .quit: NSApp.terminate(nil)
            }
        } catch {
            controller.displayError(error)
        }
    }

}

@MainActor
private enum MenuMetrics {
    static let width: CGFloat = 168
}

/// Compact playback context at the top of the status-item menu.
@MainActor
private final class MenuCardView: NSView {
    private let titleLabel: NSTextField
    private let statusLabel: NSTextField

    init(title: String, status: String) {
        titleLabel = NSTextField(labelWithString: title)
        statusLabel = NSTextField(labelWithString: status)
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 46))
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.toolTip = title
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.toolTip = status
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

    func update(title: String, status: String) {
        titleLabel.stringValue = title
        statusLabel.stringValue = status
        titleLabel.toolTip = title
        statusLabel.toolTip = status
    }
}

/// Inline transport controls. Playlist navigation appears only for a queue.
@MainActor
private final class MenuControlRow: NSView {
    private var buttons: [MenuCommand: MenuControlButton] = [:]
    let commands: [MenuCommand]

    init(controls: MenuControlState, target: AnyObject, action: Selector) {
        commands = MenuModel.controlCommands(for: controls)
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
            let button = MenuControlButton()
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = Self.symbol(spec.symbol)
            button.toolTip = spec.label
            button.setAccessibilityLabel(spec.label)
            button.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            button.target = target
            button.action = action
            button.isEnabled = spec.enabled
            buttons[command] = button
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

    /// Re-applies the current state to the existing buttons so an open menu
    /// tracks playback without being torn down and rebuilt.
    func update(controls: MenuControlState) {
        for (command, button) in buttons {
            let spec = Self.spec(for: command, controls: controls)
            button.image = Self.symbol(spec.symbol)
            button.toolTip = spec.label
            button.setAccessibilityLabel(spec.label)
            button.isEnabled = spec.enabled
            if !spec.enabled { button.contentTintColor = nil }
        }
    }

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
            .withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .title3, scale: .medium))
    }
}

/// Borderless menu button that paints a subtle rounded highlight while the
/// pointer is over it, so the passive-looking glyphs read as targets.
@MainActor
private final class MenuControlButton: NSButton {
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        contentTintColor = .controlAccentColor
    }

    override func mouseExited(with event: NSEvent) { contentTintColor = nil }
}
