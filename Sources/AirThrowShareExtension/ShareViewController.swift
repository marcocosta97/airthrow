import AppKit

@objc(ShareViewController)
@MainActor
final class ShareViewController: NSViewController {
    private let message = NSTextField(labelWithString: "Sending to AirThrow…")
    private let progress = NSProgressIndicator()
    private var started = false
    private var finished = false
    private var timeout: Task<Void, Never>?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byWordWrapping
        message.preferredMaxLayoutWidth = 268
        message.alignment = .center
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelSharing))
        let stack = NSStackView(views: [progress, message, cancel])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        preferredContentSize = view.frame.size
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.fail("The link could not be sent. Try sharing it again.")
        }
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        ShareInput.loadURL(from: items) { [weak self] source in
            guard let self, !self.finished else { return }
            guard let source, let handoff = try? MediaHandoff.url(for: source) else {
                self.fail("Choose one HTTP or HTTPS video link to send to AirThrow.")
                return
            }
            // Address the containing app explicitly, avoiding scheme-handler
            // ambiguity when several development copies are installed.
            let app = Bundle.main.bundleURL.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            guard app.pathExtension == "app" else {
                self.fail("AirThrow could not be found. Reinstall the app and try again.")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open([handoff], withApplicationAt: app, configuration: configuration) { [weak self] _, error in
                let succeeded = error == nil
                Task { @MainActor [weak self] in
                    guard let self, !self.finished else { return }
                    if succeeded {
                        self.finished = true
                        self.timeout?.cancel()
                        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                    } else {
                        self.fail("AirThrow could not be opened. Try opening the app first.")
                    }
                }
            }
        }
    }

    private func fail(_ text: String) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        progress.stopAnimation(nil)
        progress.isHidden = true
        message.stringValue = text
    }

    @objc private func cancelSharing() {
        finished = true
        timeout?.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
