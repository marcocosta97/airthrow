import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private typealias ChooserState<Value> = SwiftUI.State<Value>

/// A small native inspector for the current item's discovered presentations.
struct SourceChooserView: View {
    @ObservedObject var controller: PlaybackController
    let dismiss: () -> Void
    @ChooserState private var error: String?

    private var status: PlaybackSnapshot { controller.snapshot }
    private var busy: Bool { status.state == .loading || status.loadingPhase != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quality and source").font(.headline)
            Text("Choosing a source reloads this item from the start, paused.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    choice("Automatic", detail: "Prefer less processing, then the best available quality.",
                           id: "automatic", selected: status.selectedSourceID == nil)
                    Divider()
                    ForEach(status.sources ?? []) { source in
                        choice(source.quality, detail: [source.playbackPath.label, source.audio].compactMap { $0 }.joined(separator: " · "),
                               id: source.id, selected: status.selectedSourceID == source.id,
                               unavailable: source.unavailableReason)
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: 270)
            Divider()
            Toggle("Avoid video conversion", isOn: Binding(
                get: { !controller.allowVideoConversion },
                set: { controller.setVideoConversionAllowed(!$0) }))
            Text("Audio conversion preserves the video. Video conversion uses more processing and may take longer; output is SDR, up to 1080p. Adaptive quality is a maximum, not the current rendition.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func choice(_ title: String, detail: String, id: String, selected: Bool,
                        unavailable: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                do { try controller.selectSource(id); dismiss() }
                catch { self.error = (error as? AppFailure)?.message ?? "Could not choose this source." }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.body)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy || unavailable != nil)
            .accessibilityLabel("\(title), \(detail)")
            .accessibilityHint(unavailable ?? "")
            .accessibilityValue(selected ? "Selected" : "Not selected")
            if let unavailable {
                Text(unavailable).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
        }
    }
}
