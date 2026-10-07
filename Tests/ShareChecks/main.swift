import AppKit
import UniformTypeIdentifiers

@main
struct ShareChecks {
    @MainActor
    static func main() async throws {
        func item(_ providers: [NSItemProvider]) -> NSExtensionItem {
            let item = NSExtensionItem()
            item.attachments = providers
            return item
        }
        func load(_ items: [NSExtensionItem]) async -> String? {
            await withCheckedContinuation { continuation in
                ShareInput.loadURL(from: items) { continuation.resume(returning: $0) }
            }
        }
        func check(_ result: Bool, _ message: String) throws {
            if !result { throw NSError(domain: "ShareChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let source = "https://example.com/video?v=a%2Fb&token=secret+value#t=12"
        let provider = NSItemProvider(object: URL(string: source)! as NSURL)
        let loaded = await load([item([provider])])
        try check(loaded == source, "URL attachment changed during loading")
        let handoff = try MediaHandoff.url(for: loaded!)
        try check(MediaHandoff(url: handoff).sourceURL == source, "Signed query did not survive handoff")
        print("PASS native URL attachment and handoff preserve signed source")

        let text = NSItemProvider()
        text.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(source.utf8), nil)
            return nil
        }
        try check(await load([item([text])]) == nil, "Plain text was accepted")
        try check(await load([]) == nil, "Empty share was accepted")
        try check(await load([item([provider, provider])]) == nil, "Multiple URLs were accepted")
        print("PASS text, empty input and multiple URLs rejected")

        let file = NSItemProvider(object: URL(fileURLWithPath: "/tmp/video.mp4") as NSURL)
        let fileSource = await load([item([file])])!
        do {
            _ = try MediaHandoff.url(for: fileSource)
            throw NSError(domain: "ShareChecks", code: 2)
        } catch let error as AppFailure {
            try check(error.code == .invalidRequest, "File URL failure was incorrect")
        }
        print("PASS file URL rejected before app delivery")

        let data = NSItemProvider()
        data.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(Data(source.utf8), nil)
            return nil
        }
        try check(await load([item([data])]) == source, "Data URL representation failed")
        let string = NSItemProvider()
        string.registerObject(source as NSString, visibility: .all)
        string.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(Data(source.utf8), nil)
            return nil
        }
        try check(await load([item([string, text])]) == source, "String URL or supplementary text failed")
        print("PASS data and string URL representations supported")
    }
}
