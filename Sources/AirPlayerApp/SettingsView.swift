import SwiftUI
#if SWIFT_PACKAGE
import AirPlayerCore
#endif

struct SettingsView: View {
    @ObservedObject var controller: PlaybackController
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
            Section("Media preparation") {
                Toggle("Avoid video conversion", isOn: Binding(
                    get: { !controller.allowVideoConversion },
                    set: { controller.setVideoConversionAllowed(!$0) }))
                Text("Copy compatible video and convert audio when needed. Turn this off to allow SDR video conversion up to 1080p. Applies to the next load or source choice.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 440, height: 280)
    }
}
