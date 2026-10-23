import AppKit
import Combine
import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// Effectively no maximum for a resizable window dimension.
private let unboundedWindowLength: CGFloat = 12_000

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    // Fixed playback surface reserves room for a two-line title and warning.
    private static let controllerHeight: CGFloat = 416
    private let controller = PlaybackController()
    private let cookieStatus = CookieStatusModel()
    private let presentation = ControllerPresentation()
    private let server = CommandServer()
    private var window: NSWindow?
    private var aboutWindow: NSWindow?
    private var windowControls: NSToolbarItemGroup?
    private var splitViewController: ControllerSplitViewController?
    private var mainHosting: NSHostingController<ControllerWindowView>?
    private var playlistHosting: NSHostingController<PlaylistPanel>?
    private var inspectorItem: NSSplitViewItem?
    private var inspectorObservation: NSKeyValueObservation?
    private var statusItem: NSStatusItem?
    private var presentationObservation: AnyCancellable?
    private var snapshotObservation: AnyCancellable?
    private var menuObservation: AnyCancellable?
    private var iptvObservation: AnyCancellable?
    private var httpLoginObservation: AnyCancellable?
    private var menuIsOpen = false
    private var playbackMenuItems: [MenuCommand: NSMenuItem] = [:]
    private var menuCardView: MenuCardView?
    private var menuControlRow: MenuControlRow?
    private var menuControlsItem: NSMenuItem?
    private var terminating = false
    private var didFinishLaunching = false
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        YouTubeCookies.removeAbandonedScratch()
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
        iptvObservation = controller.$inspectorPage.dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] page in
                guard let self, self.controller.inspectorPage == page else { return }
                if page != .history { self.presentation.playlistVisible = true }
            }
        httpLoginObservation = controller.$httpLoginRequest
            .map { $0?.id }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                if request != nil { self?.showWindow() }
            }
        menuObservation = controller.$snapshot
            .sink { [weak self] snapshot in
                self?.refreshOpenMenu(snapshot)
        }
        presentationObservation = Publishers.CombineLatest(
            presentation.$playlistVisible.removeDuplicates(),
            presentation.$settingsVisible.removeDuplicates())
            .sink { [weak self] visible, settingsVisible in
                // Settings scrolls behind the toolbar; the compact player
                // retains its original transparent titlebar and spacing.
                self?.window?.titlebarAppearsTransparent = !settingsVisible
                self?.window?.titlebarSeparatorStyle = settingsVisible ? .automatic : .none
                self?.setInspector(collapsed: !visible)
                self?.windowControls?.setSelected(settingsVisible, at: 0)
                self?.windowControls?.setSelected(visible, at: 1)
                self?.updatePlaybackKeyEquivalents()
            }
        didFinishLaunching = true
        openPendingURLs()
    }

    /// Finder files and shared-link handoffs share the persistent playback session.
    /// A cold launch buffers delivery until the controller is ready.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !terminating else { return }
        pendingOpenURLs.append(contentsOf: urls.filter {
            $0.isFileURL || $0.scheme?.lowercased() == "airthrow"
        })
        if didFinishLaunching { openPendingURLs() }
    }

    private func openPendingURLs() {
        guard !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        // Shared links replace each other; Finder keeps its existing first-file
        // behavior when no shared-link handoff was delivered during startup.
        if let url = urls.last(where: { !$0.isFileURL }) {
            do {
                let handoff = try MediaHandoff(url: url)
                try controller.load(handoff.sourceURL, autoplay: handoff.autoplay)
                if !controller.snapshot.externalPlaybackActive { showWindow() }
            } catch {
                controller.displayError(error)
                showWindow()
            }
        } else if let file = urls.first {
            controller.perform { try controller.load(file.path) }
            showWindow()
        }
    }

    @objc func showWindow() {
        presentation.settingsVisible = false
        revealWindow()
    }

    @objc private func addXtreamPlaylist() {
        showWindow()
        guard controller.httpLoginRequest == nil else { return }
        presentation.xtreamPlaylistVisible = true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(addXtreamPlaylist) {
            return controller.httpLoginRequest == nil && !presentation.xtreamPlaylistVisible
        }
        if menuItem.action == #selector(runMenuCommand(_:)),
           let rawValue = menuItem.representedObject as? String,
           let command = MenuCommand(rawValue: rawValue) {
            if command == .togglePlayback {
                menuItem.title = PlaybackPolicy.isPlaying(controller.snapshot) ? "Pause" : "Play"
            }
            return playbackCommandEnabled(command)
        }
        if menuItem.action == #selector(NSWindow.performClose(_:))
            || menuItem.action == #selector(NSWindow.performMiniaturize(_:)) {
            return window?.isVisible == true
        }
        return true
    }

    func windowWillBeginSheet(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updatePlaybackKeyEquivalents() }
    }

    func windowDidEndSheet(_ notification: Notification) {
        updatePlaybackKeyEquivalents()
    }

    private func revealWindow() {
        if window == nil {
            let window = ControllerWindow(contentRect: NSRect(x: 0, y: 0, width: ControllerMetrics.width, height: Self.controllerHeight), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.presentation = presentation
            window.playbackKeyAction = { [weak self] key in
                guard let self, !self.presentation.settingsVisible else { return false }
                let status = self.controller.snapshot
                do {
                    switch key {
                    case .toggle:
                        guard PlaybackPolicy.canControl(status) else { return false }
                        try self.controller.togglePlayback()
                    case .backward, .forward:
                        let interval = key == .backward ? -MenuModel.skipInterval : MenuModel.skipInterval
                        guard PlaybackPolicy.canSkip(status, by: interval, position: self.controller.pendingSeek) else { return false }
                        try self.controller.skip(by: interval)
                    }
                } catch { self.controller.displayError(error) }
                return true
            }
            window.title = "AirThrow"
            window.backgroundColor = SurfaceColor.window
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.responderChanged = { [weak self] in self?.updatePlaybackKeyEquivalents() }

            let mainHosting = NSHostingController(rootView: ControllerWindowView(
                controller: controller, cookieStatus: cookieStatus, presentation: presentation))
            mainHosting.sizingOptions = []
            mainHosting.preferredContentSize = NSSize(width: ControllerMetrics.width, height: Self.controllerHeight)
            let playlistHosting = NSHostingController(rootView: PlaylistPanel(controller: controller))
            playlistHosting.sizingOptions = []
            playlistHosting.preferredContentSize = NSSize(width: ControllerMetrics.playlistWidth, height: Self.controllerHeight)
            self.mainHosting = mainHosting
            self.playlistHosting = playlistHosting

            let split = ControllerSplitViewController()
            split.minimumContentHeight = Self.controllerHeight
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
                    if collapsed { self?.controller.inspectorPage = .history }
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
            // The compact controller has no full-screen layout. The Window menu
            // would otherwise offer Enter Full Screen.
            window.collectionBehavior.insert(.fullScreenNone)
            window.contentMinSize = NSSize(width: ControllerMetrics.minWidth, height: Self.controllerHeight)
            window.contentMaxSize = NSSize(width: unboundedWindowLength, height: Self.controllerHeight)
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, NSToolbarItem.Identifier("AirPlayReceiver"), .space,
         NSToolbarItem.Identifier("WindowControls")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == NSToolbarItem.Identifier("AirPlayReceiver") {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "AirPlay"
            item.paletteLabel = "AirPlay receiver"
            item.toolTip = "Choose an AirPlay video receiver"
            item.view = NSHostingView(rootView: ReceiverToolbarButton(controller: controller)
                .frame(width: 40, height: 30))
            return item
        }
        guard itemIdentifier == NSToolbarItem.Identifier("WindowControls"),
              let settingsImage = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings"),
              let playlistImage = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "History")
        else { return nil }
        let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier,
            images: [settingsImage, playlistImage], selectionMode: .selectAny,
            labels: ["Settings", "History"], target: self,
            action: #selector(toggleWindowControl(_:)))
        group.label = "Window controls"
        group.controlRepresentation = .expanded
        group.setSelected(presentation.settingsVisible, at: 0)
        group.setSelected(presentation.playlistVisible, at: 1)
        if let control = group.view as? NSSegmentedControl {
            control.setToolTip("Show or hide Settings (⌘,)", forSegment: 0)
            control.setToolTip("Show or hide history", forSegment: 1)
        }
        windowControls = group
        return group
    }

    @objc private func toggleWindowControl(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 {
            window?.makeFirstResponder(nil)
            presentation.settingsVisible.toggle()
        } else if sender.selectedIndex == 1 {
            presentation.playlistVisible.toggle()
        }
    }

    /// The compact controller keeps its height. With the inspector open, the
    /// window can grow so a channel list is not stuck at 416 pt.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let inspectorOpen = !(inspectorItem?.isCollapsed ?? true)
        let minimumWidth = ControllerMetrics.minWidth + (inspectorOpen ? ControllerMetrics.playlistWidth : 0)
        let width = max(frameSize.width, minimumWidth)
        let compactHeight = sender.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: Self.controllerHeight)).height
        guard inspectorOpen else {
            // Closing animates back to the designed height. Any other request
            // stays put, so the compact controller cannot be dragged taller.
            let height = abs(frameSize.height - compactHeight) < 1 ? compactHeight : sender.frame.height
            return NSSize(width: width, height: height)
        }
        (sender as? ControllerWindow)?.allowsVerticalGrowth = true
        sender.contentMaxSize = NSSize(width: unboundedWindowLength, height: unboundedWindowLength)
        var height = max(frameSize.height, compactHeight)
        // Layout asks for the hosting controllers' old preferred height after
        // the drag has already been accepted. Ignore that snap-back. A real
        // drag still has the mouse down and keeps the proposed height.
        if NSEvent.pressedMouseButtons == 0, height + 1 < sender.frame.height {
            height = sender.frame.height
        }
        let contentHeight = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: NSSize(width: width, height: height))).height
        syncInspectorPreferredHeight(to: contentHeight)
        return NSSize(width: width, height: height)
    }

    func windowDidResize(_ notification: Notification) {
        guard let resized = notification.object as? NSWindow, resized === window,
              inspectorItem?.isCollapsed == false,
              (resized as? ControllerWindow)?.allowsVerticalGrowth == true else { return }
        let contentHeight = resized.contentRect(forFrameRect: resized.frame).height
        syncInspectorPreferredHeight(to: contentHeight)
    }

    /// The split view treats a fixed preferred height as the window's height.
    /// Keep the designed widths and follow the live content height.
    private func syncInspectorPreferredHeight(to contentHeight: CGFloat) {
        guard contentHeight > 1 else { return }
        updatePreferredHeight(mainHosting, width: ControllerMetrics.width, height: contentHeight)
        updatePreferredHeight(playlistHosting, width: ControllerMetrics.playlistWidth, height: contentHeight)
    }

    private func updatePreferredHeight<Content: View>(_ hosting: NSHostingController<Content>?, width: CGFloat, height: CGFloat) {
        guard let hosting else { return }
        let size = NSSize(width: width, height: height)
        guard hosting.preferredContentSize != size else { return }
        hosting.preferredContentSize = size
    }

    private func updatePlaylistAvailability(_ available: Bool) {
        if !available, controller.inspectorPage == .playlist { controller.inspectorPage = .history }
    }

    /// AppKit animates the inspector item's collapse; because the split view
    /// controller owns the window's content, the window frame and the panel move
    /// in one coordinated animation instead of two competing ones.
    private func setInspector(collapsed: Bool) {
        guard let inspectorItem, inspectorItem.isCollapsed != collapsed else { return }
        // Let the user drag taller as soon as the list is opening. The width
        // minimum follows the split view once its animation has settled.
        if !collapsed {
            splitViewController?.allowsVerticalGrowth = true
            (window as? ControllerWindow)?.allowsVerticalGrowth = true
            let contentHeight = window.map { $0.contentRect(forFrameRect: $0.frame).height } ?? Self.controllerHeight
            syncInspectorPreferredHeight(to: max(contentHeight, Self.controllerHeight))
            window?.contentMaxSize = NSSize(width: unboundedWindowLength, height: unboundedWindowLength)
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            inspectorItem.isCollapsed = collapsed
            if collapsed { restoreCompactController() }
            updateVerticalResizeLimit(inspectorOpen: !collapsed)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ControllerMetrics.animationDuration
            inspectorItem.animator().isCollapsed = collapsed
        } completionHandler: { [weak self] in
            let collapsed = collapsed
            Task { @MainActor in
                guard let self else { return }
                if collapsed { self.restoreCompactController() }
                self.updateVerticalResizeLimit(inspectorOpen: !collapsed)
            }
        }
    }

    private func updateVerticalResizeLimit(inspectorOpen: Bool) {
        guard let window else { return }
        let minimumWidth = ControllerMetrics.minWidth + (inspectorOpen ? ControllerMetrics.playlistWidth : 0)
        window.contentMinSize = NSSize(width: minimumWidth, height: Self.controllerHeight)
        window.contentMaxSize = NSSize(width: unboundedWindowLength, height: inspectorOpen ? unboundedWindowLength : Self.controllerHeight)
    }

    /// Closing the inspector returns the controller to its designed height.
    private func restoreCompactController() {
        (window as? ControllerWindow)?.allowsVerticalGrowth = false
        splitViewController?.allowsVerticalGrowth = false
        mainHosting?.preferredContentSize = NSSize(width: ControllerMetrics.width, height: Self.controllerHeight)
        playlistHosting?.preferredContentSize = NSSize(width: ControllerMetrics.playlistWidth, height: Self.controllerHeight)
        restoreCompactHeight()
    }

    private func restoreCompactHeight() {
        guard let window else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - Self.controllerHeight) > 0.5 else { return }
        var next = content
        next.origin.y += content.height - Self.controllerHeight
        next.size.height = Self.controllerHeight
        let frame = window.frameRect(forContentRect: next)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true, animate: true)
        }
    }

    @objc private func showSettings() {
        revealWindow()
        window?.makeFirstResponder(nil)
        presentation.settingsVisible = true
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
                let playOnReceiver = request.autoplay == true && controller.snapshot.externalPlaybackActive
                try controller.load(url, autoplay: request.autoplay == true)
                if !controller.snapshot.externalPlaybackActive || controller.iptvImporting { showWindow() }
                if controller.iptvImporting { return Response(message: "Importing channel playlist.", pending: true, status: controller.snapshot) }
                return Response(message: playOnReceiver ? "Loading video on the current receiver."
                    : (controller.snapshot.loadingPhase == "resolving"
                        ? "Finding video. Choose a receiver, then play." : "Loading video. Choose a receiver, then play."),
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
                return Response(message: "Changing source at the current position, preserving play/pause.", pending: true, status: controller.snapshot)
            case .conversion:
                guard let allowed = request.allowVideoConversion else {
                    throw AppFailure(.invalidRequest, "Choose allow-video or avoid-video.")
                }
                controller.setVideoConversionAllowed(allowed)
                return Response(message: "Re-encoding preference saved.",
                                pending: controller.snapshot.state == .loading || controller.snapshot.loadingPhase != nil,
                                status: controller.snapshot)
            case .enhance:
                guard let enhancement = request.enhancement else {
                    throw AppFailure(.invalidRequest, "Choose an enhancement preset.")
                }
                try controller.selectEnhancement(enhancement, upscaler: request.upscaler ?? .automatic)
                return Response(message: "Changing enhancement at the current position, preserving play/pause.", pending: true, status: controller.snapshot)
            }
            return Response(message: request.command == .status ? controller.snapshot.state.rawValue : "Done.", status: controller.snapshot)
        } catch {
            return Response(error: error as? AppFailure ?? AppFailure(.playbackFailed, "The operation failed."), status: controller.snapshot)
        }
    }

    @objc private func showAbout() {
        let about = aboutWindow ?? {
            let hosting = NSHostingController(rootView: AboutView())
            hosting.sizingOptions = .intrinsicContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "About AirThrow"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = SurfaceColor.window
            window.isReleasedWhenClosed = false
            hosting.view.layoutSubtreeIfNeeded()
            let fitted = hosting.sizeThatFits(in: NSSize(width: 320, height: 800))
            if fitted.width > 1, fitted.height > 1 { window.setContentSize(fitted) }
            window.center()
            return window
        }()
        aboutWindow = about
        about.center()
        NSApp.activate(ignoringOtherApps: true)
        about.makeKeyAndOrderFront(nil)
    }

    @objc private func openVideo() {
        presentation.settingsVisible = false
        revealWindow()
        presentation.openFileRequest += 1
    }

    @objc private func openLocation() {
        presentation.settingsVisible = false
        revealWindow()
        // The source field is disabled while Settings is on screen. Focus it
        // after that page has been removed.
        DispatchQueue.main.async { [weak self] in
            self?.presentation.focusSourceRequest += 1
        }
    }

    private func addPlaybackItem(_ command: MenuCommand, to menu: NSMenu, keyEquivalent: String = "",
                                 modifiers: NSEvent.ModifierFlags = []) {
        let item = NSMenuItem(title: menuTitle(command), action: #selector(runMenuCommand(_:)), keyEquivalent: keyEquivalent)
        item.target = self
        item.representedObject = command.rawValue
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        playbackMenuItems[command] = item
    }

    /// Space and the arrow keys stay with a focused field, list, or button.
    /// The menu shows those shortcuts only while the window would handle them.
    private func updatePlaybackKeyEquivalents() {
        let live = playbackShortcutsLive()
        let left = live ? String(UnicodeScalar(NSLeftArrowFunctionKey)!) : ""
        let right = live ? String(UnicodeScalar(NSRightArrowFunctionKey)!) : ""
        playbackMenuItems[.togglePlayback]?.keyEquivalent = live ? " " : ""
        playbackMenuItems[.togglePlayback]?.keyEquivalentModifierMask = []
        playbackMenuItems[.skipBackward]?.keyEquivalent = left
        playbackMenuItems[.skipBackward]?.keyEquivalentModifierMask = []
        playbackMenuItems[.skipForward]?.keyEquivalent = right
        playbackMenuItems[.skipForward]?.keyEquivalentModifierMask = []
    }

    private func playbackShortcutsLive() -> Bool {
        guard !presentation.settingsVisible, window?.attachedSheet == nil else { return false }
        return !PlaybackKeyboardWindow.controlOwnsKey(window?.firstResponder)
    }

    private func playbackCommandEnabled(_ command: MenuCommand) -> Bool {
        let status = controller.snapshot
        switch command {
        case .togglePlayback:
            return PlaybackPolicy.canControl(status)
        case .stop:
            return status.state != .idle || status.receiverWaiting == true
        case .skipBackward:
            return PlaybackPolicy.canSkip(status, by: -MenuModel.skipInterval, position: controller.pendingSeek)
        case .skipForward:
            return PlaybackPolicy.canSkip(status, by: MenuModel.skipInterval, position: controller.pendingSeek)
        case .previous:
            guard let queue = status.queue else { return false }
            return queue.currentIndex > 0 && !PlaybackPolicy.isBusy(status)
        case .next:
            guard let queue = status.queue else { return false }
            return queue.currentIndex + 1 < queue.items.count && !PlaybackPolicy.isBusy(status)
        case .showController, .quit:
            return true
        }
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
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        let open = file.addItem(withTitle: "Open…", action: #selector(openVideo), keyEquivalent: "o")
        open.target = self
        let openLocation = file.addItem(withTitle: "Open Location…", action: #selector(openLocation), keyEquivalent: "l")
        openLocation.target = self
        file.addItem(.separator())
        let xtream = file.addItem(withTitle: "Add Xtream Server…", action: #selector(addXtreamPlaylist), keyEquivalent: "")
        xtream.target = self
        fileItem.submenu = file
        main.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let playbackItem = NSMenuItem()
        let playback = NSMenu(title: "Playback")
        addPlaybackItem(.togglePlayback, to: playback)
        addPlaybackItem(.stop, to: playback, keyEquivalent: ".", modifiers: .command)
        playback.addItem(.separator())
        addPlaybackItem(.skipBackward, to: playback)
        addPlaybackItem(.skipForward, to: playback)
        playback.addItem(.separator())
        addPlaybackItem(.previous, to: playback)
        addPlaybackItem(.next, to: playback)
        playbackItem.submenu = playback
        main.addItem(playbackItem)
        updatePlaybackKeyEquivalents()
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
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
                try controller.togglePlayback()
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

/// Escape dismisses the Settings page through the native responder chain,
/// including when focus is on the window rather than a form control.
/// Reapplies the height ceiling after the split view lays out. The split view
/// otherwise keeps the hosting controllers' original height as a maximum.
@MainActor
private final class ControllerSplitViewController: NSSplitViewController {
    var allowsVerticalGrowth = false
    var minimumContentHeight: CGFloat = 416

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window else { return }
        let minWidth = window.contentMinSize.width
        let maxHeight = allowsVerticalGrowth ? unboundedWindowLength : minimumContentHeight
        let minSize = NSSize(width: minWidth, height: minimumContentHeight)
        let maxSize = NSSize(width: max(minWidth, unboundedWindowLength), height: maxHeight)
        if window.contentMinSize != minSize { window.contentMinSize = minSize }
        if window.contentMaxSize != maxSize { window.contentMaxSize = maxSize }
    }
}

@MainActor
private final class ControllerWindow: PlaybackKeyboardWindow {
    weak var presentation: ControllerPresentation?
    var responderChanged: (() -> Void)?
    /// While the inspector is open, AppKit keeps writing the compact height
    /// back into the window's maximum. Refuse that ceiling.
    var allowsVerticalGrowth = false

    override var contentMaxSize: NSSize {
        get { super.contentMaxSize }
        set {
            var size = newValue
            if allowsVerticalGrowth {
                size.width = max(size.width, unboundedWindowLength)
                size.height = max(size.height, unboundedWindowLength)
            }
            guard super.contentMaxSize != size else { return }
            super.contentMaxSize = size
        }
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        responderChanged?()
        return accepted
    }

    override func cancelOperation(_ sender: Any?) {
        if presentation?.settingsVisible == true {
            presentation?.settingsVisible = false
        } else {
            super.cancelOperation(sender)
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
        case .skipBackward: ("gobackward.10", "Back 10 Seconds", controls.canSkipBackward)
        case .togglePlayback:
            (controls.isPlaying ? "pause.fill" : "play.fill",
             controls.isPlaying ? "Pause" : "Play", controls.canToggle)
        case .stop: ("stop.fill", "Stop", controls.canStop)
        case .skipForward: ("goforward.10", "Forward 10 Seconds", controls.canSkipForward)
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
