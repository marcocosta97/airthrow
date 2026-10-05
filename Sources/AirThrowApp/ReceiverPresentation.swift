import AppKit
import AVKit
import Combine
import SwiftUI

/// Observe routing independently of playback progress. AVKit can retain a
/// selected receiver after its session ends; that is not a new connection.
struct ReceiverToolbarButton: View {
    let controller: PlaybackController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var connection: ReceiverConnectionState

    init(controller: PlaybackController) {
        self.controller = controller
        _connection = StateObject(wrappedValue: ReceiverConnectionState(controller: controller))
    }

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
            .help(connection.phase == .connected
                  ? "AirPlay connected — change receiver"
                  : "Choose or change the AirPlay receiver")
            .accessibilityValue(connection.phase.rawValue)
    }
}

private enum ReceiverConnectionPhase: String {
    case idle = "Not connected"
    case connecting = "Connecting"
    case connected = "Connected"

    init(connected: Bool, connecting: Bool) {
        self = connected ? .connected : (connecting ? .connecting : .idle)
    }
}

@MainActor
private final class ReceiverConnectionState: ObservableObject {
    @Published private(set) var phase: ReceiverConnectionPhase
    private var observation: AnyCancellable?

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
