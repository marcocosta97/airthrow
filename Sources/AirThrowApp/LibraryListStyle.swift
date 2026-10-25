import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// Shared geometry keeps library pages stable when switching between them.
struct LibraryHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                actions.controlSize(.small)
            }
            .frame(height: 24)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
        }
    }
}

struct LibraryItemLabel: View {
    let title: String
    let subtitle: String
    let kind: MediaHistoryEntry.Kind
    var isPinned = false

    private var symbol: String {
        switch kind {
        case .xtream: "rectangle.stack"
        case .iptv: "tv"
        case .playlist: "list.bullet"
        case .video: "play.rectangle"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.body).foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension View {
    func libraryListStyle() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
    }

    func libraryRowStyle() -> some View {
        frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            .listRowSeparator(.hidden)
    }
}
