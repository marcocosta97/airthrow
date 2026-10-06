import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// The loaded item's video options: one compact, contextual popover for video
/// source, audio track, and Mac-side enhancement. Source changes reload the
/// item from the start, paused, on the shared player and keep the current
/// receiver; neither asserts receiver playback. Source shows only the selectors
/// for which the link offers alternatives.
struct VideoMenuView: View {
    @ObservedObject var controller: PlaybackController
    @SwiftUI.State private var showingOptions = false
    @SwiftUI.State private var draftVideo = "automatic"
    @SwiftUI.State private var draftAction: EnhancementAction = .original
    @SwiftUI.State private var draftOutput4K = false
    @SwiftUI.State private var draftSourceIDs: [String] = []
    private var status: PlaybackSnapshot { controller.snapshot }
    private var sources: [SourceOptionSnapshot] { status.sources ?? [] }
    private var audioOptions: [AudioOptionSnapshot] { status.audioOptions ?? [] }
    private var subtitleOptions: [SubtitleOptionSnapshot] { status.subtitleOptions ?? [] }
    private var enhancement: VideoEnhancement { status.videoEnhancement ?? .original }
    private var enhancementAction: EnhancementAction { .from(enhancement) }
    private var audioSelection: String { status.selectedAudioID ?? "" }
    private var subtitleSelection: String { status.selectedSubtitleID ?? "" }

    /// Show one row per visible quality and processing path. Upstream formats
    /// can differ by codec or bitrate while producing identical chooser labels;
    /// their best available representative keeps the list compact. Audio variants
    /// of one presentation also belong to the separate audio picker.
    private var videoOptions: [SourceOptionSnapshot] {
        var representatives: [SourceOptionSnapshot] = []
        var indexByPresentation: [String: Int] = [:]
        for source in sources {
            let key = presentationKey(source)
            guard let index = indexByPresentation[key] else {
                indexByPresentation[key] = representatives.count
                representatives.append(source)
                continue
            }
            if representatives[index].unavailableReason != nil, source.unavailableReason == nil {
                representatives[index] = source
            }
        }
        return representatives
    }

    private func presentationKey(_ source: SourceOptionSnapshot) -> String {
        "\(source.quality)#\(source.playbackPath.rawValue)"
    }

    /// The chosen presentation's representative, or "automatic" when nothing
    /// is explicitly selected.
    private var videoSelection: String {
        guard let selected = sources.first(where: { $0.id == status.selectedSourceID })
        else { return "automatic" }
        let key = presentationKey(selected)
        return videoOptions.first { presentationKey($0) == key }?.id ?? "automatic"
    }

    private var isLive: Bool { status.isLive }
    private var mediaReady: Bool {
        status.playbackPath != nil || (status.state == .failed && status.videoEnhancement != nil && !sources.isEmpty)
    }
    private var canChooseOutput: Bool { mediaReady && !isLive && draftAction != .original }
    private var requires4K: Bool {
        controller.requires4KOutput(for: draftVideo == videoSelection ? nil : draftVideo)
    }
    private var hasChanges: Bool {
        draftVideo != videoSelection || draftAction != enhancementAction
            || (draftAction != .original && draftOutput4K != controller.enhancementOutput4K)
    }
    private var outputHelp: String {
        if isLive { return "Enhancement is available only for on-demand video." }
        if draftAction == .original { return "Choose an enhancement to change the output resolution." }
        if requires4K { return "This source is above 1080p, so enhancement uses 4K." }
        return "Choose the output resolution before closing this menu."
    }

    private var outputExplanation: String {
        if isLive { return "Enhancement is available only for on-demand video." }
        if !mediaReady { return "Video options become available when the source is ready." }
        if draftAction == .original { return "Choose an enhancement to enable output resolution." }
        if requires4K { return "This source requires 4K output and a compatible receiver." }
        return "4K needs a compatible receiver."
    }

    /// The chosen source, independent of any prepared output quality.
    private var sourceLabel: String {
        guard let id = status.selectedSourceID,
              let source = sources.first(where: { $0.id == id }) else { return "Automatic" }
        return source.quality.replacingOccurrences(of: " maximum (adaptive)", with: "")
    }

    private var menuLabel: String {
        if enhancement != .original { return enhancement.label }
        if videoOptions.count > 1 { return sourceLabel }
        if let quality = status.quality { return "Original · \(quality)" }
        return "Original"
    }

    private var helpText: String {
        if isLive {
            return "Enhancement is only for on-demand video. This live stream can only change source quality."
        }
        return "Choose this video's source, audio, subtitles, and enhancement. Video or enhancement changes reload paused; native track changes stay on the current item. 4K needs a compatible receiver."
    }

    var body: some View {
        Button {
            if !showingOptions { resetDraft() }
            showingOptions.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("Video: \(menuLabel)").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .controlSize(.small)
        .disabled(!mediaReady && videoOptions.count < 2)
        .help(helpText)
        .accessibilityLabel("Video options")
        .accessibilityValue(menuLabel)
        .popover(isPresented: $showingOptions,
                 attachmentAnchor: .point(.bottomLeading), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if videoOptions.count > 1 || audioOptions.count > 1 || subtitleOptions.count > 1 {
                    Text("Source").font(.subheadline.weight(.medium))
                    if videoOptions.count > 1 {
                        HStack(spacing: 8) {
                            Text("Video").font(.caption)
                            Spacer(minLength: 0)
                            Picker("Video", selection: $draftVideo) {
                                Text("Automatic").tag("automatic")
                                ForEach(videoOptions) { option in
                                    Text(videoRow(option))
                                        .tag(option.id)
                                        .disabled(option.unavailableReason != nil)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                    }
                    if audioOptions.count > 1 {
                        HStack(spacing: 8) {
                            Text("Audio").font(.caption)
                            Spacer(minLength: 0)
                            Picker("Audio", selection: Binding(get: { audioSelection }, set: { chooseAudio($0) })) {
                                if status.selectedAudioID == nil {
                                    Text("Choose audio").tag("").disabled(true)
                                }
                                ForEach(audioOptions) { option in
                                    Text(audioRow(option))
                                        .tag(option.id)
                                        .disabled(option.unavailableReason != nil)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .disabled(status.state == .loading)
                        }
                    }
                    if subtitleOptions.count > 1 {
                        HStack(spacing: 8) {
                            Text("Subtitles").font(.caption)
                            Spacer(minLength: 0)
                            Picker("Subtitles", selection: Binding(get: { subtitleSelection }, set: { chooseSubtitle($0) })) {
                                if status.selectedSubtitleID == nil {
                                    Text("Choose subtitles").tag("").disabled(true)
                                }
                                ForEach(subtitleOptions) { option in
                                    Text(option.label).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .disabled(status.state == .loading)
                            .accessibilityLabel("Subtitles")
                        }
                    }
                    Divider()
                }
                Text("Enhancement").font(.subheadline.weight(.medium))
                Picker("Enhancement", selection: $draftAction) {
                    ForEach(EnhancementAction.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(!mediaReady || isLive)
                Text("Upscale output")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(canChooseOutput ? Color.primary : Color.secondary)
                Picker("Upscale output", selection: $draftOutput4K) {
                    Text("1080p").tag(false).disabled(requires4K)
                    Text("4K").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(!canChooseOutput)
                .help(outputHelp)
                Text(outputExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(isLive
                     ? "Closing this menu applies changes and reloads paused."
                     : "Closing this menu applies changes and restarts the video, paused.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 210, alignment: .leading)
        }
        .onChange(of: showingOptions) { _, isPresented in
            if !isPresented { applyDraft() }
        }
        .onChange(of: sources.map(\.id)) { _, _ in
            if showingOptions { resetDraft() }
        }
        .onChange(of: draftVideo) { _, _ in
            if requires4K { draftOutput4K = true }
        }
    }

    private func videoRow(_ source: SourceOptionSnapshot) -> String {
        [source.quality.replacingOccurrences(of: " maximum (adaptive)", with: " max"),
         source.playbackPath.label, source.unavailableReason]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func audioRow(_ option: AudioOptionSnapshot) -> String {
        [option.label, option.unavailableReason].compactMap { $0 }.joined(separator: " · ")
    }

    private func resetDraft() {
        draftVideo = videoSelection
        draftAction = enhancementAction
        draftOutput4K = controller.enhancementOutput4K
        draftSourceIDs = sources.map(\.id)
    }

    private func applyDraft() {
        // Stop/replacement can dismiss the popover too. Only commit a draft
        // that still belongs to the same source session, and only once.
        guard hasChanges, mediaReady, draftSourceIDs == sources.map(\.id) else { return }
        do {
            try controller.applyVideoOptions(
                sourceID: draftVideo == videoSelection ? nil : draftVideo,
                enhancement: draftAction.enhancement(output4K: draftOutput4K),
                output4K: draftOutput4K)
        } catch { controller.displayError(error) }
    }

    private func chooseAudio(_ id: String) {
        guard id != audioSelection else { return }
        do {
            try controller.selectAudio(id)
        }
        catch { controller.displayError(error) }
    }

    private func chooseSubtitle(_ id: String) {
        guard id != subtitleSelection else { return }
        do {
            try controller.selectSubtitle(id)
        }
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
