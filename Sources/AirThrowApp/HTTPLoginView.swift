import SwiftUI
#if SWIFT_PACKAGE
import AirThrowCore
#endif

private typealias LoginState<Value> = SwiftUI.State<Value>

struct HTTPLoginView: View {
    let request: HTTPLoginRequest
    let submit: (String, String) -> Void
    let cancel: () -> Void
    @LoginState private var username = ""
    @LoginState private var password = ""
    @FocusState private var focus: Field?
    private enum Field { case username, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in to server").font(.headline)
            Text(request.challenge.host).font(.subheadline).textSelection(.enabled)
            if request.retry {
                Text("The server did not accept those credentials. Try again.")
                    .foregroundStyle(.red).font(.callout)
            }
            Form {
                TextField("Username", text: $username)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .focused($focus, equals: .password)
                    .onSubmit(signIn)
            }
            .disabled(request.submitting)
            Text("Used for this video only; not saved on disk.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if request.submitting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Sign In", action: signIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.isEmpty || request.submitting)
            }
        }
        .padding(24).frame(width: 340)
        .task(id: request.id) {
            username = request.username
            await Task.yield()
            focus = username.isEmpty ? .username : .password
        }
        .onDisappear { password = "" }
    }

    private func signIn() { if !username.isEmpty { submit(username, password); password = "" } }
}
