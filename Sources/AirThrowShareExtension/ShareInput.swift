import Foundation
import UniformTypeIdentifiers

/// Only URL attachments are accepted. Text, files and browser credentials are
/// never read by the sharing extension.
@MainActor
enum ShareInput {
    static func loadURL(from items: [NSExtensionItem],
                        completion: @escaping @MainActor @Sendable (String?) -> Void) {
        let providers = items.flatMap { $0.attachments ?? [] }.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        guard providers.count == 1, let provider = providers.first else {
            completion(nil)
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, error in
            let source = error == nil ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
            Task { @MainActor in completion(source) }
        }
    }
}
