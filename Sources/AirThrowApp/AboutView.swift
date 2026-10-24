import AppKit
import SwiftUI

/// Replaces the system About panel's one-line credit. The version and build
/// are the values stamped into this copy of the app, not the source plist.
struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
    private var commit: String {
        let revision = Bundle.main.url(forResource: "BuildCommit", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let revision, !revision.isEmpty else { return "Commit unavailable" }
        return revision
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityLabel("AirThrow")
            Text("AirThrow")
                .font(.title2.weight(.semibold))
            VStack(spacing: 2) {
                Text("Version \(version)")
                    .font(.body)
                Text("Build \(build)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Text(commit)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help(commit)
            Text("Sends video to an AirPlay receiver.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 320)
        .background(Color(nsColor: SurfaceColor.window))
    }
}
