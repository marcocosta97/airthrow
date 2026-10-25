import AppKit
import AVKit
import Combine
import SwiftUI

/// The connected AirPlay device, shown as the window’s center title.
/// The route picker itself stays on the AirPlay toolbar button.
struct ReceiverToolbarTitle: View {
    let label: String
    var connecting = false

    var body: some View {
        Text(label)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 180)
            .foregroundStyle(connecting ? Color.secondary : Color.primary)
            .accessibilityLabel("AirPlay receiver")
            .accessibilityValue(label)
            .help(connecting ? "Connecting to the AirPlay receiver" : "Connected to \(label)")
    }
}

struct ReceiverToolbarButton: View {
    let controller: PlaybackController
    @ObservedObject var connection: ReceiverConnectionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ReceiverRoutePicker(controller: controller)
            .overlay {
                Image(systemName: "airplay.audio")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(nsColor: connection.phase == .idle ? .secondaryLabelColor : .systemBlue))
                    .symbolEffect(.variableColor.iterative, isActive: connection.phase == .connecting && !reduceMotion)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .help(help)
            .accessibilityLabel("AirPlay receiver")
            .accessibilityValue(connection.receiverName ?? connection.phase.rawValue)
    }

    private var help: String {
        if let name = connection.receiverName {
            return "Connected to \(name). Choose another receiver"
        }
        return connection.phase == .connecting
            ? "Connecting to the AirPlay receiver"
            : "Choose an AirPlay receiver"
    }
}

enum ReceiverConnectionPhase: String {
    case idle = "Not connected"
    case connecting = "Connecting"
    case connected = "Connected"

    init(connected: Bool, connecting: Bool) {
        self = connected ? .connected : (connecting ? .connecting : .idle)
    }
}

@MainActor
final class ReceiverConnectionState: ObservableObject {
    @Published private(set) var phase: ReceiverConnectionPhase
    /// Name of the receiver that is actually playing. Empty while the Mac is the output.
    @Published private(set) var receiverName: String?
    private let controller: PlaybackController
    private var observation: AnyCancellable?
    private let routeWatcher = RouteNameWatcher()

    /// Center title: the device name once AirPlay is up, “Connecting…” while it starts,
    /// and nothing while the Mac is playing locally. The AirPlay button remains the picker.
    var toolbarLabel: String? {
        switch phase {
        case .idle: nil
        case .connecting: "Connecting…"
        case .connected: receiverName
        }
    }

    init(controller: PlaybackController) {
        self.controller = controller
        phase = ReceiverConnectionPhase(connected: controller.snapshot.externalPlaybackActive,
                                        connecting: controller.snapshot.state == .connecting)
        observation = controller.$snapshot
            .map { ReceiverConnectionPhase(connected: $0.externalPlaybackActive, connecting: $0.state == .connecting) }
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.phase = phase
                self?.refreshName()
            }
        routeWatcher.onChange = { [weak self] in
            Task { @MainActor in self?.refreshName() }
        }
        routeWatcher.watch(controller.player)
        refreshName()
    }

    isolated deinit { routeWatcher.stop() }

    private func refreshName() {
        let name = Self.remoteReceiverName(player: controller.player)
        if receiverName != name { receiverName = name }
    }

    /// `AVPlayer.outputContext.deviceName` names the active route. The SDK overlay does not
    /// export that type, and the same property names the Mac when playback is local.
    private static func remoteReceiverName(player: AVPlayer) -> String? {
        guard player.isExternalPlaybackActive else { return nil }
        guard let context = player.value(forKey: "outputContext") as? NSObject else { return nil }
        if let name = displayName(context.value(forKey: "deviceName") as? String) { return name }
        let devices = context.value(forKey: "outputDevices") as? [NSObject] ?? []
        for device in devices {
            if let name = displayName(device.value(forKey: "deviceName") as? String
                                      ?? device.value(forKey: "name") as? String) {
                return name
            }
        }
        return nil
    }

    private static func displayName(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let host = Host.current().localizedName, trimmed.caseInsensitiveCompare(host) == .orderedSame {
            return nil
        }
        return trimmed
    }
}

/// `outputContext.deviceName` changes when the route attaches, sometimes after
/// `externalPlaybackActive` has already flipped.
private final class RouteNameWatcher: NSObject, @unchecked Sendable {
    private weak var player: AVPlayer?
    var onChange: @Sendable () -> Void = {}

    func watch(_ player: AVPlayer) {
        self.player = player
        player.addObserver(self, forKeyPath: "outputContext.deviceName", options: [.initial, .new], context: nil)
    }

    func stop() {
        player?.removeObserver(self, forKeyPath: "outputContext.deviceName")
        player = nil
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "outputContext.deviceName" else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        onChange()
    }
}

private struct ReceiverRoutePicker: NSViewRepresentable {
    let controller: PlaybackController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = controller.player
        view.delegate = context.coordinator
        view.isRoutePickerButtonBordered = false
        // Retain the native interaction and accessible picker, but render one
        // session-driven symbol in every state, including disconnection.
        // Keep nonzero opacity so AVKit can still present its popover.
        for state: AVRoutePickerView.ButtonState in [.normal, .normalHighlighted, .active, .activeHighlighted] {
            view.setRoutePickerButtonColor(.clear, for: state)
        }
        view.wantsLayer = true
        view.layer?.opacity = 0.02
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}

    @MainActor final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        let controller: PlaybackController
        init(_ controller: PlaybackController) { self.controller = controller }

        nonisolated func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor in controller.pickerWillOpen() }
        }

        nonisolated func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            Task { @MainActor in controller.pickerDidClose() }
        }
    }
}
