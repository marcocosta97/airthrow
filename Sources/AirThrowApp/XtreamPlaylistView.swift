import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

/// Shared credential controls for playlist and network-share editors.
struct ConnectionCredentialFields: View {
    let editing: Bool
    @Binding var username: String
    @Binding var password: String
    @Binding var storage: CredentialStorageChoice
    var body: some View {
        Picker("Credentials", selection: $storage) {
            if editing { Text("Keep existing credentials").tag(CredentialStorageChoice.keep) }
            Text("Save in Keychain").tag(CredentialStorageChoice.keychain)
            Text("Use for this session only").tag(CredentialStorageChoice.session)
        }
        TextField("Username", text: $username).autocorrectionDisabled().disabled(storage == .keep)
        SecureField("Password", text: $password).disabled(storage == .keep)
        Text(storage == .keep
             ? "Existing credentials stay unchanged. Choose a storage option to replace them or change the address."
             : storage == .keychain ? "Credentials are stored securely in macOS Keychain."
             : "Credentials stay in memory until AirThrow quits. The source remains saved; enter credentials again next time.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct PlaylistConnectionSheet: View {
    @ObservedObject var controller: PlaybackController
    @State var draft: PlaylistConnectionDraft
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var storage: CredentialStorageChoice = .keychain
    @State private var saving = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var nameFocused: Bool
    private var editing: Bool { draft.existingID != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(editing ? "Edit" : "Add") \(draft.kind.rawValue)").font(.headline)
            Form {
                TextField("Name", text: $draft.name).focused($nameFocused)
                TextField("Address", text: $draft.address,
                          prompt: Text(draft.kind == .xtream ? "https://server:port" : "https://server/playlist.m3u"))
                    .autocorrectionDisabled()
                ConnectionCredentialFields(editing: editing, username: $username, password: $password, storage: $storage)
                if draft.kind == .xtream {
                    Picker("Live format", selection: $draft.format) {
                        Text("HLS").tag(XtreamPlaylist.StreamFormat.hls)
                        Text("MPEG-TS").tag(XtreamPlaylist.StreamFormat.transportStream)
                    }.disabled(storage == .keep)
                }
            }.textFieldStyle(.roundedBorder).disabled(saving)
            Text("Saved sources appear in Sources and the sidebar. Changing connection details checks the server before replacing the saved source.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if saving { ProgressView().controlSize(.small); Text("Saving…") }
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing ? "Save Changes" : "Connect and Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.address.isEmpty)
            }
        }.padding(24).frame(width: 440)
            .onAppear { storage = editing ? .keep : .keychain; nameFocused = true }
            .onDisappear { task?.cancel(); password = ""; username = "" }
    }
    private func save() {
        task = Task {
            saving = true; error = nil
            defer { saving = false }
            do {
                try await controller.savePlaylistConnection(draft, username: username, password: password, storage: storage)
                dismiss()
            } catch is CancellationError {} catch let failure as AppFailure { self.error = failure.message }
            catch { self.error = "Could not save the source. Check the address and credentials, then try again." }
        }
    }
}
