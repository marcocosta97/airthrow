import SwiftUI
#if SWIFT_PACKAGE
import AirPlayerCore
#endif

struct SettingsView: View {
    @AppStorage("afterPlaybackBehavior") private var behavior = AfterPlaybackBehavior.keepConnected.rawValue

    var body: some View {
        Form {
            Picker("After a video finishes", selection: $behavior) {
                Text("Keep AirPlay connected").tag(AfterPlaybackBehavior.keepConnected.rawValue)
                Text("Unload finished video").tag(AfterPlaybackBehavior.unloadVideo.rawValue)
            }
            Text(behavior == AfterPlaybackBehavior.unloadVideo.rawValue
                 ? "Unload the video so Apple TV can return to its normal screen."
                 : "Keep the finished video loaded and the receiver available for replay.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 420, height: 170)
    }
}
