import AppKit
import SwiftUI
import NetFS
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import AirThrowCore
#endif

enum NetworkLibrarySelection: Hashable { case share(UUID) }

struct NetworkLibraryView: View {
    @ObservedObject var model: NetworkLibraryModel
    @ObservedObject var controller: PlaybackController
    let selection: NetworkLibrarySelection
    @State private var search = ""
    @State private var selectedEntry: String?
    private var shareID: UUID { switch selection { case .share(let id): id } }
    private var title: String { model.configuration.shares.first { $0.id == shareID }?.name ?? "Share" }
    private var history: ShareNavigation { model.histories[shareID] ?? ShareNavigation() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline).lineLimit(1).help(title)
                Spacer(minLength: 8)
                Button { model.reconnect(shareID) } label: { Image(systemName: "arrow.clockwise") }
                    .help(model.canAccess(shareID) ? "Update share" : "Connect and update share")
                    .accessibilityLabel("Update share").disabled(model.browsing || model.unmounting.contains(shareID))
                if model.connectedShares.contains(shareID) {
                    Button { controller.unmountShare(shareID) } label: { Image(systemName: "eject") }
                        .help("Unmount share").accessibilityLabel("Unmount share")
                        .disabled(!model.connectedShares.contains(shareID) || model.unmounting.contains(shareID))
                }
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ControlGroup {
                        Button { model.back() } label: { Image(systemName: "chevron.left") }
                            .help("Back").accessibilityLabel("Back")
                            .disabled(history.backIndex == nil || model.browsing || !model.canAccess(shareID))
                        Button { model.forward() } label: { Image(systemName: "chevron.right") }
                            .help("Forward").accessibilityLabel("Forward")
                            .disabled(history.forwardIndex == nil || model.browsing || !model.canAccess(shareID))
                    }.fixedSize()
                    SharePathControl(title: title, path: model.directory) { model.browse(shareID, path: $0) }
                        .frame(height: 24).disabled(!model.canAccess(shareID) || model.browsing)
                }.controlSize(.small)
                CatalogSearchField(prompt: "Find a file or folder", text: $search).frame(height: 26)
                    .disabled(!model.canAccess(shareID))
                if model.canAccess(shareID), !model.browsing {
                    Text("\(visibleEntries.count) of \(model.entries.count) items")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            if let message = model.message {
                HStack { Text(message).font(.callout).textSelection(.enabled); Spacer(); Button("Dismiss") { model.message = nil } }.padding(12)
            }
            if model.downloading {
                HStack { ProgressView().controlSize(.small); Text("Downloading temporary copy · " + ByteCountFormatter.string(fromByteCount: model.downloadBytes, countStyle: .file)); Spacer(); Button("Cancel") { controller.stop() } }.padding(12)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { _, _ in search = ""; selectedEntry = nil }
        .onChange(of: model.directory) { _, _ in search = ""; selectedEntry = nil }
    }
    @ViewBuilder private var content: some View {
        if model.unmounting.contains(shareID) { ProgressView("Unmounting…") }
        else if !model.canAccess(shareID) {
            ContentUnavailableView {
                Label("Share not connected", systemImage: "externaldrive")
            } description: {
                Text("Connect explicitly when you are ready. AirThrow will not contact this share in the background.")
            } actions: {
                Button("Connect Share") { model.reconnect(shareID) }
            }
        } else if model.browsing { ProgressView("Opening folder…") }
        else if model.offlineShares.contains(shareID) {
            ContentUnavailableView("Folder unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text("Check the connection, then update the share to try again."))
        }
        else if visibleEntries.isEmpty {
            ContentUnavailableView(search.isEmpty ? "No files" : "No matching files", systemImage: "folder",
                                   description: Text(search.isEmpty ? "This folder is empty or unavailable." : "Try another search."))
        } else {
            List(visibleEntries, selection: $selectedEntry) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.isDirectory ? "folder" : "film").foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).accessibilityHidden(true)
                    Text(entry.name).lineLimit(2)
                    Spacer(minLength: 8)
                    if let size = entry.size, !entry.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }.libraryRowStyle().tag(entry.path)
                    .onTapGesture(count: 2) { open(entry) }
                    .contextMenu {
                        if entry.isDirectory { Button("Open") { open(entry) } }
                        else if entry.isVideo {
                            Button("Open Video") { open(entry) }
                            Button("Add to Queue") {
                                do { controller.enqueueShare(try model.reference(shareID: shareID, path: entry.path), title: entry.name) }
                                catch { model.message = "This share is unavailable." }
                            }
                            Button("Download Temporary Copy and Open…") { play(entry, download: true) }
                        }
                    }
            }.libraryListStyle().accessibilityLabel("Share files")
                .onKeyPress(.return) {
                    guard let entry = visibleEntries.first(where: { $0.path == selectedEntry }) else { return .ignored }
                    open(entry); return .handled
                }
        }
    }
    private var visibleEntries: [ShareEntry] {
        model.entries.filter { search.isEmpty || $0.name.localizedStandardContains(search) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private func open(_ entry: ShareEntry) {
        if entry.isDirectory { model.browse(shareID, path: entry.path) }
        else if entry.isVideo { play(entry) }
    }
    private func play(_ entry: ShareEntry, download: Bool = false) {
        guard model.canAccess(shareID) else { return }
        do { controller.loadShare(try model.reference(shareID: shareID, path: entry.path), title: entry.name, download: download) }
        catch { model.message = "This share is unavailable." }
    }
}

/// NSPathControl provides standard path components and ancestor navigation.
/// Items carry no URLs; clicks map to validated relative paths without exposing a server address.
private struct SharePathControl: NSViewRepresentable {
    let title: String
    let path: String
    let navigate: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(navigate: navigate) }
    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard; control.controlSize = .small; control.isEditable = false
        control.target = context.coordinator; control.action = #selector(Coordinator.selected(_:))
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel("Folder path")
        return control
    }
    func updateNSView(_ control: NSPathControl, context: Context) {
        context.coordinator.navigate = navigate
        control.isEnabled = context.environment.isEnabled
        var items: [NSPathControlItem] = []
        var paths: [String] = []
        var relative = ""
        for (index, name) in ([title] + path.split(separator: "/").map(String.init)).enumerated() {
            if index > 0 { relative += "/" + name }
            let item = NSPathControlItem()
            item.title = name
            item.image = NSWorkspace.shared.icon(for: .folder)
            item.image?.size = NSSize(width: 16, height: 16)
            items.append(item); paths.append(String(relative.dropFirst()))
        }
        control.pathItems = items
        context.coordinator.paths = paths
    }
    @MainActor final class Coordinator: NSObject {
        var navigate: (String) -> Void
        var paths: [String] = []
        init(navigate: @escaping (String) -> Void) { self.navigate = navigate }
        @objc func selected(_ control: NSPathControl) {
            guard let item = control.clickedPathItem,
                  let index = control.pathItems.firstIndex(where: { $0 === item }), paths.indices.contains(index) else { return }
            navigate(paths[index])
        }
    }
}

struct ShareConnectionSheet: View {
    @ObservedObject var model: NetworkLibraryModel
    var existing: NetworkShare?
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ShareKind = .webDAV
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var storage: CredentialStorageChoice = .keychain
    @State private var connectAutomatically = false
    @State private var connecting = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Add Share" : "Edit Share").font(.headline)
            Form {
                Picker("Protocol", selection: $kind) { ForEach(ShareKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField("Name", text: $name)
                TextField("Address", text: $address, prompt: Text(kind == .smb ? "smb://server/share" : "https://server/folder/")).autocorrectionDisabled()
                if kind == .webDAV {
                    ConnectionCredentialFields(editing: existing != nil, username: $username, password: $password, storage: $storage)
                } else {
                    Text("SMB uses macOS authentication. Connect in Finder first if sign-in is required.").font(.caption).foregroundStyle(.secondary)
                    Button("Choose Mounted Folder…") { chooseMountedFolder() }
                    Button("Connect in Finder…") {
                        guard let url = URL(string: address), (try? NetworkShare(name: name, kind: .smb, endpoint: url)) != nil else { error = "Enter a name and a valid SMB address."; return }
                        NSWorkspace.shared.open(url)
                    }
                }
                Toggle("Connect automatically when this share is opened", isOn: $connectAutomatically)
                Text("When off, this share is accessed only after you explicitly connect it. Opening a sidebar entry alone will not contact it.").font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder).disabled(connecting)
            if existing != nil { Text("Saving changes does not connect to the share.").font(.caption).foregroundStyle(.secondary) }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if connecting { ProgressView().controlSize(.small); Text(existing == nil ? "Connecting…" : "Saving…") }
                Spacer()
                Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Connect and Save" : "Save Changes") { connect() }.keyboardShortcut(.defaultAction).disabled(connecting || name.isEmpty || address.isEmpty)
            }
        }.padding(24).frame(width: 440)
        .onAppear { if let existing { storage = .keep; kind = existing.kind; name = existing.name; address = existing.endpoint.absoluteString; connectAutomatically = existing.connectAutomatically } }
        .onDisappear { task?.cancel(); username = ""; password = "" }
    }
    private func chooseMountedFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Choose"; panel.title = "Choose an SMB Folder"
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            do {
                let volume = try folder.resourceValues(forKeys: [.volumeURLKey]).volume ?? folder
                guard let remote = NetFSCopyURLForRemountingVolume(volume as CFURL)?.takeRetainedValue() as URL?, remote.scheme == "smb", folder.path.hasPrefix(volume.path) else { throw ShareError.invalidAddress }
                var parts = URLComponents(url: remote, resolvingAgainstBaseURL: false)!
                parts.user = nil; parts.password = nil
                guard let base = parts.url else { throw ShareError.invalidAddress }
                let suffix = String(folder.path.dropFirst(volume.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                address = suffix.isEmpty ? base.absoluteString : base.appendingPathComponent(suffix).absoluteString
                if name.isEmpty { name = folder.lastPathComponent }
            } catch { self.error = "Choose a folder on a mounted SMB share." }
        }
    }
    private func connect() {
        task = Task {
            connecting = true; error = nil; defer { connecting = false }
            do {
                guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ShareError.invalidAddress }
                let share = try NetworkShare(id: existing?.id ?? UUID(), name: name, kind: kind, endpoint: url, connectAutomatically: connectAutomatically)
                if existing == nil { try await model.add(share, username: username, password: password, remember: storage == .keychain) }
                else {
                    if kind == .webDAV && storage == .keep && existing?.endpoint != share.endpoint {
                        throw AppFailure(.invalidRequest, "Choose how to store the new credentials when changing the address.")
                    }
                    try await model.update(share, username: storage == .keep ? "" : username,
                                           password: storage == .keep ? "" : password, remember: storage == .keychain,
                                           replaceCredentials: kind == .webDAV && storage != .keep)
                }
                dismiss()
            } catch is CancellationError {} catch let failure as AppFailure { self.error = failure.message } catch { self.error = "Could not save the share. Check the connection details and try again." }
        }
    }
}
