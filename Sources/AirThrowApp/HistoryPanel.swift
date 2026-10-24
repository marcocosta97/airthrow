import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

struct InspectorHeader: View {
    let title: String
    var back: (() -> Void)?
    var body: some View {
        ZStack {
            Text(title).font(.headline)
            HStack {
                if let back {
                    Button(action: back) { Label("History", systemImage: "chevron.left") }
                        .buttonStyle(.plain).help("Back to history").accessibilityLabel("Back to history")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, minHeight: 20)
            .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

struct HistoryPanel: View {
    @ObservedObject var controller: PlaybackController
    @SwiftUI.State private var hoveredEntryID: UUID?
    @SwiftUI.State private var confirmClear = false
    @FocusState private var focusedRemovalID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer(minLength: 8)
                Menu {
                    Button("Clear History", role: .destructive) { confirmClear = true }
                        .disabled(!controller.history.contains(where: { !$0.isPinned }))
                        .help("Remove all unpinned entries")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("History options").accessibilityLabel("History options")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            if controller.snapshot.queue != nil {
                Button { controller.inspectorPage = .playlist } label: {
                    Label("Current playlist", systemImage: "list.bullet")
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            if controller.history.isEmpty {
                ContentUnavailableView {
                    Label("No recent sources", systemImage: "clock")
                } description: {
                    Text("Load a video or playlist in Source. It will appear here for next time.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.history) { entry in
                    HStack(spacing: 8) {
                        Button {
                            do { try controller.selectHistoryEntry(entry.id) }
                            catch { controller.displayError(error) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: entry.kind == .iptv || entry.kind == .xtream ? "tv" : entry.kind == .playlist ? "list.bullet" : "play.rectangle")
                                    .foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).lineLimit(2)
                                    Text(entry.kind == .xtream ? "Xtream · \(entry.location)" : entry.kind == .iptv ? "Channel playlist · \(entry.location)" : entry.location)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if entry.isPinned {
                                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Open \(entry.title)").accessibilityLabel("Open \(entry.title)")
                            .accessibilityValue(entry.isPinned ? "Pinned" : "")
                            .accessibilityAction(named: Text("Remove from History")) { controller.removeHistoryEntry(entry.id) }
                        ZStack {
                            if entry.kind != .video {
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    .opacity(removalVisible(for: entry) ? 0 : 1).accessibilityHidden(true)
                            }
                            Button { controller.removeHistoryEntry(entry.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .focused($focusedRemovalID, equals: entry.id)
                                .opacity(removalVisible(for: entry) ? 1 : 0)
                                .allowsHitTesting(removalVisible(for: entry))
                                .help("Remove from history").accessibilityLabel("Remove \(entry.title) from history")
                        }.frame(width: 18)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hoveredEntryID = entry.id }
                            else if hoveredEntryID == entry.id { hoveredEntryID = nil }
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8))
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin") {
                                controller.toggleHistoryPin(entry.id)
                            }
                            Divider()
                            Button("Remove from History", role: .destructive) { controller.removeHistoryEntry(entry.id) }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                controller.removeHistoryEntry(entry.id)
                            }
                        }
                }.listStyle(.plain)
                    .contentMargins(.horizontal, 0, for: .scrollContent)
            }
        }
        .confirmationDialog("Clear history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { controller.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unpinned items are removed. Pinned items stay. Account credentials for the removed items are deleted and cannot be restored.")
        }
    }

    private func removalVisible(for entry: MediaHistoryEntry) -> Bool {
        hoveredEntryID == entry.id || focusedRemovalID == entry.id
    }
}

