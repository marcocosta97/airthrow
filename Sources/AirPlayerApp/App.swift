import AppKit
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = PlaybackController()
    private let server = CommandServer()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?

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
        showWindow()
    }

    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 420), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "AirPlayer"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ControllerView(controller: controller))
            window.center()
            window.setFrameAutosaveName("AirPlayerController")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
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
        let reopen = menu.addItem(withTitle: "Show AirPlayer", action: #selector(showWindow), keyEquivalent: "")
        reopen.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AirPlayer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        statusItem = item
    }
}
