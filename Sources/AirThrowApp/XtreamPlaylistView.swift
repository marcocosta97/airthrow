import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private typealias XtreamState<Value> = SwiftUI.State<Value>

struct XtreamPlaylistView: View {
    let submit: (URL) throws -> Void
    let cancel: () -> Void
    @XtreamState private var server = ""
    @XtreamState private var username = ""
    @XtreamState private var password = ""
    @XtreamState private var format: XtreamPlaylist.StreamFormat = .hls
    @XtreamState private var error: String?
    @FocusState private var focus: Field?
    private enum Field { case server, username, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Xtream Server").font(.headline)
            Form {
                TextField("Server", text: $server, prompt: Text("https://server:port"))
                    .focused($focus, equals: .server)
                    .onSubmit { focus = .username }
                TextField("Username", text: $username)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .focused($focus, equals: .password)
                    .onSubmit(add)
                Picker("Live format", selection: $format) {
                    Text("HLS").tag(XtreamPlaylist.StreamFormat.hls)
                    Text("MPEG-TS").tag(XtreamPlaylist.StreamFormat.transportStream)
                }
                .pickerStyle(.menu)
            }
            .textFieldStyle(.roundedBorder)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Browse live TV, films, series and programme guides. The server is saved in History; credentials are stored in Keychain.")
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Connect", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(24).frame(width: 380)
        .task { focus = .server }
        .onDisappear { password = "" }
    }

    private var canAdd: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func add() {
        guard canAdd else { return }
        do {
            let url = try XtreamPlaylist.url(server: server, username: username, password: password, format: format)
            try submit(url)
        } catch let failure as AppFailure { error = failure.message }
        catch { self.error = "Could not add the server. Check the details, then try again." }
    }
}
