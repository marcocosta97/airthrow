import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// Quality belongs to the loaded item, beside its playback details.
struct SourceChooserView: View {
    @ObservedObject var controller: PlaybackController
    private var status: PlaybackSnapshot { controller.snapshot }
    private var selection: String { status.selectedSourceID ?? "automatic" }
    private var label: String {
        guard let id = status.selectedSourceID,
              let source = status.sources?.first(where: { $0.id == id }) else {
            return status.quality.map { "Automatic · \($0)" } ?? "Automatic"
        }
        return status.quality ?? source.quality.replacingOccurrences(of: " maximum (adaptive)", with: "")
    }

    var body: some View {
        Menu {
            Text("Choosing quality reloads from the start, paused.")
            Picker("Quality", selection: Binding(get: { selection }, set: choose)) {
                Text("Automatic").tag("automatic")
                ForEach(status.sources ?? []) { source in
                    Text([source.quality, source.playbackPath.label, source.audio,
                          source.unavailableReason].compactMap { $0 }.joined(separator: " · "))
                        .tag(source.id)
                        .disabled(source.unavailableReason != nil)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text(controller.preferQuality
                 ? "Automatic prefers higher quality."
                 : "Automatic prefers less processing.")
            Text("Adaptive quality is the available maximum.")
        } label: {
            Text("Quality: \(label)").lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .disabled(PlaybackPolicy.isBusy(status))
        .help("Choose playback quality. Changing it reloads this item from the start, paused. Set conversion preferences in Settings.")
        .accessibilityLabel("Playback quality")
        .accessibilityValue(label)
    }

    private func choose(_ id: String) {
        guard id != selection || status.state == .failed else { return }
        do { try controller.selectSource(id) }
        catch { controller.displayError(error) }
    }
}
