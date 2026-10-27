import AppKit
import AVKit
import Combine
import SwiftUI

/// Confirmed AirPlay connection state, shown in the window toolbar.
/// The route picker itself stays on the AirPlay toolbar button.
struct ReceiverToolbarTitle: View {
    let label: String
    var connecting = false

    var body: some View {
        Text(label)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize()
            .padding(.horizontal, 8)
            .foregroundStyle(connecting ? Color.secondary : Color.primary)
            .accessibilityLabel("AirPlay receiver")
            .accessibilityValue(label)
            .help(connecting ? "Connecting to the AirPlay receiver" : "AirPlay connected")
    }
}

struct ReceiverToolbarButton: View {
    let controller: PlaybackController
    @ObservedObject var connection: ReceiverConnectionState

    var body: some View {
        ReceiverRoutePicker(controller: controller)
            .help(help)
            .accessibilityLabel("AirPlay receiver")
            .accessibilityValue(connection.phase.rawValue)
    }

    private var help: String {
        switch connection.phase {
        case .connected: "AirPlay connected — change receiver"
        case .connecting: "Connecting to the AirPlay receiver"
        case .idle: "Choose an AirPlay receiver"
        }
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
    private var observation: AnyCancellable?

    var toolbarLabel: String? {
        switch phase {
        case .idle: nil
        case .connecting: "Connecting…"
        case .connected: "AirPlay connected"
        }
    }

    init(controller: PlaybackController) {
        phase = ReceiverConnectionPhase(connected: controller.snapshot.externalPlaybackActive,
                                        connecting: controller.snapshot.state == .connecting)
        observation = controller.$snapshot
            .map { ReceiverConnectionPhase(connected: $0.externalPlaybackActive, connecting: $0.state == .connecting) }
            .removeDuplicates()
            .sink { [weak self] in self?.phase = $0 }
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
