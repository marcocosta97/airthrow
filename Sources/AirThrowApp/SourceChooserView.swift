import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// The loaded item's video options: one compact, contextual menu for source
/// quality and Mac-side enhancement. Both reload the item from the start,
/// paused, on the shared player and keep the current receiver; neither asserts
/// receiver playback. The source group appears only when the link offers more
/// than one presentation, so a single-file load still reaches enhancement.
struct VideoMenuView: View {
    @ObservedObject var controller: PlaybackController
    private var status: PlaybackSnapshot { controller.snapshot }
    private var sources: [SourceOptionSnapshot] { status.sources ?? [] }
    private var enhancement: VideoEnhancement { status.videoEnhancement ?? .original }
    private var enhancementAction: EnhancementAction { .from(enhancement) }
    private var sourceSelection: String { status.selectedSourceID ?? "automatic" }
    private var isLive: Bool { status.isLive }
    private var busy: Bool { PlaybackPolicy.isBusy(status) }

    /// The chosen source, independent of any prepared output quality.
    private var sourceLabel: String {
        guard let id = status.selectedSourceID,
              let source = sources.first(where: { $0.id == id }) else { return "Automatic" }
        return source.quality.replacingOccurrences(of: " maximum (adaptive)", with: "")
    }

    private var menuLabel: String {
        if enhancement != .original { return enhancement.label }
        if sources.count > 1 { return sourceLabel }
        if let quality = status.quality { return "Original · \(quality)" }
        return "Original"
    }

    private var helpText: String {
        if isLive {
            return "Enhancement is only for on-demand video. This live stream can only change source quality."
        }
        return "Choose this video's source and enhancement. Changes reload from the start, paused, and keep the receiver. 4K needs a compatible receiver."
    }

    var body: some View {
        Menu {
            if sources.count > 1 {
                Section("Source") {
                    Picker("Source", selection: Binding(get: { sourceSelection }, set: { chooseSource($0) })) {
                        Text("Automatic").tag("automatic")
                        ForEach(sources) { source in
                            Text(sourceRow(source))
                                .tag(source.id)
                                .disabled(source.unavailableReason != nil)
                        }
                    }
                    .pickerStyle(.inline)
                    Text("Choosing a source reloads from the start, paused.")
                }
                Divider()
            }
            Section("Enhancement") {
                Toggle("Use 4K instead of 1080p",
                       isOn: Binding(get: { controller.enhancementOutput4K },
                                     set: { chooseOutput4K($0) }))
                    .disabled(isLive)
                    .help("Changing the target during enhancement reloads from the start, paused.")
                Picker("Enhancement", selection: Binding(get: { enhancementAction },
                                                         set: { chooseAction($0) })) {
                    ForEach(EnhancementAction.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .disabled(isLive)
            }
        } label: {
            Text("Video: \(menuLabel)").lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .disabled(busy)
        .help(helpText)
        .accessibilityLabel("Video options")
        .accessibilityValue(menuLabel)
    }

    private func sourceRow(_ source: SourceOptionSnapshot) -> String {
        [source.quality, source.playbackPath.label, source.audio, source.unavailableReason]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func chooseSource(_ id: String) {
        guard id != sourceSelection || status.state == .failed else { return }
        do { try controller.selectSource(id) }
        catch { controller.displayError(error) }
    }

    private func chooseAction(_ action: EnhancementAction) {
        guard action != enhancementAction else { return }
        let option = action.enhancement(output4K: controller.enhancementOutput4K)
        do { try controller.selectEnhancement(option) }
        catch { controller.displayError(error) }
    }

    private func chooseOutput4K(_ enabled: Bool) {
        guard enabled != controller.enhancementOutput4K else { return }
        do { try controller.setEnhancementOutput4K(enabled) }
        catch { controller.displayError(error) }
    }
}

/// The two finite actions the chooser exposes, independent of output height.
/// A picked action resolves against `enhancementOutput4K`; the reverse mapping
/// collapses the four `VideoEnhancement` cases for the picker selection.
private enum EnhancementAction: CaseIterable, Hashable {
    case original
    case upscale
    case cleanUpUpscale

    var label: String {
        switch self {
        case .original: "Original"
        case .upscale: "Upscale"
        case .cleanUpUpscale: "Clean up and upscale"
        }
    }

    static func from(_ enhancement: VideoEnhancement) -> EnhancementAction {
        switch enhancement {
        case .original: .original
        case .upscale1080, .upscale4K: .upscale
        case .cleanup1080, .cleanup4K: .cleanUpUpscale
        }
    }

    func enhancement(output4K: Bool) -> VideoEnhancement {
        switch self {
        case .original: .original
        case .upscale: output4K ? .upscale4K : .upscale1080
        case .cleanUpUpscale: output4K ? .cleanup4K : .cleanup1080
        }
    }
}
