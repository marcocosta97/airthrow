import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private typealias CatalogState<Value> = SwiftUI.State<Value>

struct IPTVPanel: View {
    @ObservedObject var controller: PlaybackController
    @CatalogState private var search = ""
    @CatalogState private var category: String?
    @FocusState private var searchFocused: Bool
    private var channels: [IPTVChannel] { controller.iptvCatalog?.channels(category: category, search: search) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(title: "Channels", back: { controller.inspectorPage = .history })
            if let catalog = controller.iptvCatalog {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        ChannelCategoryField(selection: $category, categories: catalog.categories,
                                             includesUncategorized: catalog.channels.contains(where: { $0.category == nil }))
                            .frame(height: 26)
                        TextField("Find a channel", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchFocused)
                            .accessibilityLabel("Find a channel")
                            .frame(height: 26)
                    }
                    Text(channelSummary(catalog))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(importDetails(catalog))
                }.padding(.horizontal, 12).padding(.bottom, 10)
                Divider()
                if channels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No matching channels").font(.callout)
                        Button("Clear filters") { search = ""; category = nil }
                    }.padding(16)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(channels) { channel in
                                Button {
                                    searchFocused = false
                                    do { try controller.selectIPTVChannel(channel.id) }
                                    catch { controller.displayError(error) }
                                } label: {
                                    HStack(spacing: 8) {
                                        Text("\(channel.number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(minWidth: 20, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(channel.name).lineLimit(2)
                                            if let category = channel.category { Text(category).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                        }
                                        Spacer(minLength: 0)
                                        if controller.selectedIPTVChannelID == channel.id {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .help("Load \(channel.name). Active TV playback continues; paused playback stays paused.")
                                    .accessibilityLabel("Load channel \(channel.number), \(channel.name)")
                                    .accessibilityValue(controller.selectedIPTVChannelID == channel.id ? "Selected channel" : "")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onChange(of: controller.iptvCatalog?.id) { _, _ in search = ""; category = nil }
    }

    private func channelSummary(_ catalog: IPTVCatalog) -> String {
        var parts = ["\(channels.count) of \(catalog.channels.count) channels"]
        if catalog.skippedEntries > 0 { parts.append("\(catalog.skippedEntries) not imported") }
        if catalog.truncated { parts.append("Limit reached") }
        return parts.joined(separator: " · ")
    }

    private func importDetails(_ catalog: IPTVCatalog) -> String {
        var parts = ["\(channels.count) of \(catalog.channels.count) channels"]
        if catalog.skippedEntries > 0 { parts.append("\(catalog.skippedEntries) unsupported entries were not imported.") }
        if catalog.truncated { parts.append("Showing the first \(IPTVPlaylist.maximumChannels) supported channels.") }
        return parts.joined(separator: "\n")
    }
}

private struct ChannelCategoryField: NSViewRepresentable {
    @Binding var selection: String?
    let categories: [String]
    let includesUncategorized: Bool
    private var values: [String?] { [nil] + categories.map(Optional.some) + (includesUncategorized ? [""] : []) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setAccessibilityLabel("Channel category")
        button.target = context.coordinator
        button.action = #selector(Coordinator.select(_:))
        button.cell?.lineBreakMode = .byTruncatingTail
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = ["All categories"] + categories + (includesUncategorized ? ["Uncategorized"] : [])
        if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
        button.selectItem(at: values.firstIndex(of: selection) ?? 0)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        // Menu contents must not determine the inspector's width.
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    @MainActor final class Coordinator: NSObject {
        var parent: ChannelCategoryField
        init(_ parent: ChannelCategoryField) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            guard parent.values.indices.contains(sender.indexOfSelectedItem) else { return }
            parent.selection = parent.values[sender.indexOfSelectedItem]
        }
    }
}

