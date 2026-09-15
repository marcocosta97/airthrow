import Foundation
import AVFoundation

struct MediaCase: Codable {
    let name: String
    let path: String?
    let container: String
    let videoCodec: String
    let audioCodec: String
    let expectedState: String?
    let expectedAudio: Bool?
    let skipped: String?
}

struct MediaResult: Encodable {
    let source: MediaCase
    let loadState: String
    let hasAudio: Bool?
    let errorReason: String?
    // Readiness is not proof that samples decode or play on an AirPlay receiver.
    let receiverPicture = "untested"
    let receiverSound = "untested"
    let receiverSeeking = "untested"
    let receiverRemote = "untested"
}

@main
struct MediaChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "MediaChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected server URL and fixture manifest"])
        }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "MediaChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let secret = "https://example.com/private?signature=do-not-log"
        func av(_ code: AVError.Code, underlying: NSError? = nil) -> NSError {
            var info: [String: Any] = [NSLocalizedDescriptionKey: secret]
            if let underlying { info[NSUnderlyingErrorKey] = underlying }
            return NSError(domain: AVFoundationErrorDomain, code: code.rawValue, userInfo: info)
        }
        let network = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
                              userInfo: [NSURLErrorFailingURLStringErrorKey: secret])
        let examples: [(NSError?, MediaFailureReason)] = [
            (av(.unknown, underlying: network), .network),
            (av(.fileFailedToParse, underlying: network), .network),
            (av(.fileFormatNotRecognized), .unreadableMedia),
            (av(.decoderNotFound), .unreadableMedia),
            (av(.externalPlaybackNotSupportedForAsset), .externalPlaybackUnsupported),
            (av(.contentIsProtected), .protectedMedia),
            (av(.contentIsUnavailable), .sourceUnavailable),
            (av(.decoderTemporarilyUnavailable), .loadFailed),
            (av(.serverIncorrectlyConfigured), .loadFailed),
            (nil, .loadFailed)
        ]
        for (error, expected) in examples {
            let reason = MediaDiagnostics.reason(for: error, fallback: .loadFailed)
            try check(reason == expected, "Incorrect classification: \(expected)")
            try check(!reason.message.contains(secret), "Diagnostic leaked source data")
        }
        try check(MediaDiagnostics.reason(for: nil, fallback: .playbackInterrupted) == .playbackInterrupted,
                  "Unknown playback failure was attributed to a codec")
        // Optional diagnostics preserve decoding of existing protocol-v1 snapshots.
        let old = Data(#"{"state":"idle","externalPlaybackActive":false,"seekableRanges":[],"title":"No video loaded","isLive":false}"#.utf8)
        try check(try JSONDecoder().decode(PlaybackSnapshot.self, from: old).errorReason == nil,
                  "Legacy status no longer decodes")

        let base = CommandLine.arguments[1]
        let cases = try JSONDecoder().decode([MediaCase].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let controller = PlaybackController()
        defer { controller.shutdown() }
        func settled(states: [PlaybackState] = [.awaitingReceiver, .failed], audio: Bool? = nil) async throws -> PlaybackSnapshot {
            let deadline = Date().addingTimeInterval(35)
            while Date() < deadline {
                controller.refresh()
                if let audio, controller.snapshot.hasAudio != nil {
                    try check(controller.snapshot.hasAudio == audio, "Audio discovery reported incorrect presence")
                }
                if states.contains(controller.snapshot.state),
                   audio == nil || controller.snapshot.hasAudio == audio || controller.snapshot.state == .failed {
                    return controller.snapshot
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw NSError(domain: "MediaChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Media load did not settle"])
        }
        var results: [MediaResult] = []
        for source in cases {
            guard let path = source.path else {
                results.append(MediaResult(source: source, loadState: "skipped", hasAudio: nil, errorReason: nil))
                continue
            }
            try controller.load(base + "/" + path + "?signature=do-not-log")
            let status = try await settled(audio: source.expectedAudio)
            if let expected = source.expectedState {
                try check(status.state.rawValue == expected, "\(source.name): expected \(expected), got \(status.state.rawValue)")
            }
            if status.state == .awaitingReceiver, let expected = source.expectedAudio {
                try check(status.hasAudio == expected, "\(source.name): wrong audio detection")
            }
            try check(controller.player.rate == 0 && controller.player.isMuted, "Inspection started local playback")
            let encoded = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
            try check(!encoded.contains("do-not-log"), "Status leaked a signed query")
            if source.name == "HLS video only" {
                try check(status.hasAudio != true, "Silent HLS incorrectly reported an audio track")
            }
            if source.name == "Audio only" || source.name == "HLS audio only" { try check(status.errorReason == .noVideo, "Audio-only source was not distinguished") }
            results.append(MediaResult(source: source, loadState: status.state.rawValue,
                hasAudio: status.hasAudio, errorReason: status.errorReason?.rawValue))
            controller.stop()
            try check(controller.snapshot.errorReason == nil && controller.snapshot.error == nil, "Stop retained failure details")
        }

        // Repeated replacements cover the observed race between readiness and HLS track discovery.
        if let path = cases.first(where: { $0.name == "HLS with audio" })?.path {
            for index in 0..<8 {
                let source = index.isMultiple(of: 2) ? path : "hls-no-extension"
                try controller.load(base + "/" + source)
                let status = try await settled(audio: true)
                try check(status.state == .awaitingReceiver && controller.player.rate == 0,
                          "Repeated HLS replacement failed or started playback")
            }
            controller.stop()
        }

        // Exercise the notification path, redaction, failure retention, and recovery on a real item.
        try controller.load(base + "/video.mp4")
        try check(try await settled().state == .awaitingReceiver, "Could not load notification fixture")
        let oldItem = controller.player.currentItem!
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: av(.unknown, underlying: network)])
        try await Task.sleep(for: .milliseconds(100))
        controller.refresh()
        try check(controller.snapshot.state == .failed && controller.snapshot.errorReason == .network,
                  "Playback error notification lost its underlying network reason")
        try check(controller.player.isMuted && controller.player.rate == 0, "Failed playback was not stopped")
        try controller.load(base + "/video.mp4")
        try check(controller.snapshot.errorReason == nil, "Replacement retained old diagnostic")
        try check(try await settled().state == .awaitingReceiver, "Failed load did not recover")
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: av(.decodeFailed)])
        try await Task.sleep(for: .milliseconds(100))
        try check(controller.snapshot.errorReason == nil, "Stale item changed new session diagnostics")
        controller.stop()
        try controller.load(base + "/slow.mp4")
        controller.stop()
        try await Task.sleep(for: .milliseconds(500))
        try check(controller.snapshot.state == .idle && controller.snapshot.errorReason == nil, "Cancelled load published a failure")

        if let videoHLS = cases.first(where: { $0.name == "HLS with audio" })?.path,
           let audioHLS = cases.first(where: { $0.name == "HLS audio only" })?.path {
            controller.pickerWillOpen()
            controller.pickerDidClose()
            try controller.load(base + "/" + audioHLS)
            let audioStatus = try await settled()
            try check(audioStatus.errorReason == .noVideo && controller.player.rate == 0 && controller.player.isMuted,
                      "Receiver-first audio-only HLS started playback")
            try controller.load(base + "/" + videoHLS)
            let videoStatus = try await settled(states: [.connecting, .failed], audio: true)
            try check(videoStatus.state == .connecting && videoStatus.hasAudio == true && controller.player.isMuted,
                      "Receiver-first HLS did not defer negotiation until video/audio discovery")
            controller.stop()
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(results), as: UTF8.self))
        FileHandle.standardError.write(Data("PASS diagnostics, privacy, protocol compatibility, notification lifecycle, and native media loads\n".utf8))
    }
}
