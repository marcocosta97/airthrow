import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private typealias XtreamState<Value> = SwiftUI.State<Value>

struct XtreamPlaylistView: View {
    let signingIn: Bool
    let serverError: String?
    let submit: (URL, String) throws -> Void
    let cancel: () -> Void
    let clearServerError: () -> Void
    @XtreamState private var name = ""
    @XtreamState private var server = ""
    @XtreamState private var username = ""
    @XtreamState private var password = ""
    @XtreamState private var format: XtreamPlaylist.StreamFormat = .hls
    @XtreamState private var error: String?
    @FocusState private var focus: Field?
    private enum Field { case name, server, username, password }
    private var presentedError: String? { error ?? serverError }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Xtream Server").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("My TV"))
                    .focused($focus, equals: .name)
                    .disabled(signingIn)
                    .onSubmit { focus = .server }
                TextField("Server", text: $server, prompt: Text("https://server:port"))
                    .focused($focus, equals: .server)
                    .disabled(signingIn)
                    .onSubmit { focus = .username }
                    .onChange(of: server) { _, _ in clearError() }
                TextField("Username", text: $username)
                    .focused($focus, equals: .username)
                    .disabled(signingIn)
                    .onSubmit { focus = .password }
                    .onChange(of: username) { _, _ in clearError() }
                SecureField("Password", text: $password)
                    .focused($focus, equals: .password)
                    .disabled(signingIn)
                    .onSubmit(add)
                    .onChange(of: password) { _, _ in clearError() }
                Picker("Live format", selection: $format) {
                    Text("HLS").tag(XtreamPlaylist.StreamFormat.hls)
                    Text("MPEG-TS").tag(XtreamPlaylist.StreamFormat.transportStream)
                }
                .pickerStyle(.menu)
                .disabled(signingIn)
                .onChange(of: format) { _, _ in clearError() }
            }
            .textFieldStyle(.roundedBorder)
            if signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing in…")
                }
                .accessibilityElement(children: .combine)
            } else if let presentedError {
                Label(presentedError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Browse live TV, films, series and programme guides. The playlist appears in the sidebar and History; credentials are stored in Keychain.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Connect", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd || signingIn)
            }
        }
        .padding(24).frame(width: 380)
        .task { focus = .name }
        .onDisappear { password = "" }
    }

    private var canAdd: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func clearError() {
        error = nil
        if serverError != nil { clearServerError() }
    }

    private func add() {
        guard canAdd, !signingIn else { return }
        clearError()
        do {
            let url = try XtreamPlaylist.url(server: server, username: username, password: password, format: format)
            try submit(url, name)
        } catch let failure as AppFailure { error = failure.message }
        catch { self.error = "Could not add the server. Check the details, then try again." }
    }
}
