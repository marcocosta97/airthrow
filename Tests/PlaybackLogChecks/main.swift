import Foundation
import AirThrowCore

@main struct PlaybackLogChecks {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("playback-log-checks-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let file = root.appendingPathComponent("playback.jsonl")
        let log = PlaybackLog(fileURL: file, maximumBytes: 4096)
        let session = UUID()
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "PlaybackLogChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        var snapshot = PlaybackSnapshot()
        snapshot.state = .buffering
        snapshot.title = "PRIVATE_TITLE"
        snapshot.error = "https://private.invalid/account?password=PRIVATE_CREDENTIAL"
        snapshot.loadingPhase = "PRIVATE_PHASE"
        snapshot.selectedAudioID = "PRIVATE_ID"
        snapshot.audioOptions = [.init(id: "PRIVATE_ID", label: "PRIVATE_LABEL")]
        snapshot.position = 11.8
        snapshot.preparationSpeed = 0.5
        snapshot.duration = .nan
        var diagnostic = PlaybackDiagnostics()
        diagnostic.playerStatus = "PRIVATE_STATUS"
        diagnostic.failureErrors = [.init(domain: .urlLoading, code: -1005)]
        diagnostic.bufferedRanges = [.init(start: 0, end: 36)]
        diagnostic.itemErrorCode = -12889
        var preparation = PreparationDiagnostics()
        preparation.stage = .chunkMux; preparation.chunkIndex = 6; preparation.videoCodec = .hevc
        diagnostic.preparation = preparation
        snapshot.diagnostics = diagnostic
        log.record(snapshot, session: session)
        await log.flush()
        try check(!manager.fileExists(atPath: file.path), "Disabled logging created a file")
        log.setEnabled(true)
        for _ in 0..<100 { log.record(snapshot, session: session) }
        await log.flush()
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        try check(!text.contains("PRIVATE_") && !text.contains("private.invalid") && !text.contains("https"), "The log exposed free-form source data")
        let lines = text.split(separator: "\n")
        try check(lines.count == 2, "Repeated refreshes were not limited to one sample per second")
        let row = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as! [String: Any]
        let values = row["values"] as! [String: Any]
        try check(values["position"] as? Double == 11.8 && values["itemErrorCode"] as? Int == -12889
                  && values["selectedAudioIndex"] as? Int == 0, "Allowed diagnostic values were lost")
        print("PASS opt-in recording, URL/title/credential exclusion, numeric diagnostics and sampling limit")
        for index in 0..<40 {
            snapshot.state = index.isMultiple(of: 2) ? .playing : .buffering
            log.record(snapshot, session: session)
        }
        log.setEnabled(false)
        await log.flush()
        let files = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        try check(files.count == 2, "Log rotation did not retain exactly two files")
        for file in files {
            let content = try Data(contentsOf: file)
            try check(content.count <= 4096, "A rotated log exceeded the size limit")
            for line in content.split(separator: 10) { _ = try JSONSerialization.jsonObject(with: Data(line)) }
            let mode = (try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber).intValue
            try check(mode & 0o077 == 0, "The log was readable by other users")
        }
        let stopped = try Data(contentsOf: file)
        log.record(snapshot, session: session)
        await log.flush()
        try check(try Data(contentsOf: file) == stopped, "Disabling logging allowed later writes")
        print("PASS complete-line rotation, bounded storage, private file permissions and immediate disable")
        let invalid = root.appendingPathComponent("blocked")
        try manager.createDirectory(at: invalid, withIntermediateDirectories: false)
        let failing = PlaybackLog(fileURL: invalid)
        var failed = false
        failing.onFailure = { failed = true }
        failing.setEnabled(true)
        await failing.flush()
        for _ in 0..<20 where !failed { try await Task.sleep(for: .milliseconds(10)) }
        try check(failed && !failing.enabled, "A write failure was not reported and disabled")
        try manager.removeItem(at: invalid)
        failing.setEnabled(true)
        await failing.flush()
        try check(manager.fileExists(atPath: invalid.path), "Logging could not recover after a write failure")
        failing.setEnabled(false)
        await failing.flush()
        print("PASS write-failure reporting and explicit retry")
        print("3/3 playback log groups passed")
    }
}
