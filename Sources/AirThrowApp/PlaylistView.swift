import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// The trailing inspector's content. Hosted by the AppKit split-view controller
/// so AppKit can resize the window and slide the panel as one animation.
struct PlaylistPanel: View {
    @ObservedObject var controller: PlaybackController

    var body: some View {
        VStack(spacing: 0) {
            if controller.inspectorPage == .playlist, let queue = controller.snapshot.queue {
                InspectorHeader(title: "Queue", back: nil)
                PlaylistView(queue: queue)
            } else if controller.inspectorPage == .xtream, let library = controller.xtreamLibrary {
                XtreamPanel(library: library, controller: controller).equatable()
            } else if controller.inspectorPage == .channels, controller.iptvCatalog != nil {
                IPTVPanel(controller: controller, catalogID: controller.iptvCatalog?.id,
                          selectedID: controller.selectedIPTVChannelID).equatable()
            } else {
                HistoryPanel(controller: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: SurfaceColor.window))
    }
}

struct PlaylistView: View {
    let queue: PlaybackQueueSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(queue.title).font(.headline).lineLimit(2).help(queue.title)
                Spacer(minLength: 8)
                Text("\(queue.currentIndex + 1) of \(queue.items.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(16)

            ScrollViewReader { proxy in
                List(Array(queue.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(item.title)
                            .help(item.title)
                            .lineLimit(2)
                            .foregroundStyle(item.state == .skipped ? .secondary : .primary)
                        Spacer(minLength: 0)
                        if item.state != .pending {
                            Image(systemName: item.state == .current ? "play.fill" : "exclamationmark.circle")
                                .foregroundStyle(item.state == .current ? Color.accentColor : .secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(item.state == .current ? "Now playing" : item.state == .skipped ? "Skipped" : "Not yet played")
                    .id(index)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: SurfaceColor.window))
                .onAppear { proxy.scrollTo(queue.currentIndex, anchor: .center) }
                .onChange(of: queue.currentIndex) { _, index in
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
