import AppKit
import Foundation
#if SWIFT_PACKAGE
import AirThrowCore
#endif

@main
struct AirThrowCLI {
    private static let helpText = """
    AirThrow — control the native AirPlay video session

    Usage:
      athrow open SOURCE     Load a URL, YouTube playlist, or local file, paused
      athrow play            Start/resume on the selected video receiver
      athrow pause           Pause the current session
      athrow seek SECONDS    Seek to an absolute position
      athrow previous        Load the previous playlist item
      athrow next            Load the next playlist item
      athrow stop            Stop and unload the video
      athrow status [--json] Show observed playback state
      athrow sources         List available quality/source choices and their IDs
      athrow source ID       Reload a listed source, paused (or use automatic)
      athrow conversion allow-video|avoid-video
                                Set video re-encoding preference for future loads
      athrow show            Open the controller and choose a receiver

    --json is available on every command. Receiver selection uses the app's
    AirPlay picker. open and show launch AirThrow if needed.
    Set AIRTHROW_APP to an explicit AirThrow.app path for development.
    """

    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let json = arguments.contains("--json")
        do {
            switch try CLIArguments.parse(arguments) {
            case .help:
                print(helpText)
                return
            case .run(let parsed):
                if parsed.command == .open || parsed.command == .show {
                    let running = await Task.detached { (try? LocalSocket.send(Request(.status))) != nil }.value
                    if !running { try await launch() }
                }
                let response = try await Task.detached { try LocalSocket.send(parsed.request) }.value
                output(response, json: parsed.json, showSources: parsed.showsSources)
                if let error = response.error { exit(error.code.exitCode) }
            }
        } catch {
            let failure = error as? AppFailure ?? AppFailure(.appUnavailable, "Could not communicate with AirThrow.")
            output(Response(error: failure), json: json)
            exit(failure.code.exitCode)
        }
    }

    @MainActor private static func launch() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent()
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["AIRTHROW_APP"] {
            candidates.append(URL(fileURLWithPath: explicit))
        } else {
            candidates += [directory.appendingPathComponent("AirThrow.app"),
                           directory.deletingLastPathComponent().deletingLastPathComponent(),
                           URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/AirThrow.app"),
                           URL(fileURLWithPath: "/Applications/AirThrow.app")]
        }
        guard let app = candidates.first(where: {
            $0.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/AirThrowApp").path)
        }) else { throw AppFailure(.appUnavailable, "AirThrow.app was not found. Build/install the app or set AIRTHROW_APP to its path.") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
        for _ in 0..<40 {
            let ready = await Task.detached { (try? LocalSocket.send(Request(.status))) != nil }.value
            if ready { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AppFailure(.appUnavailable, "AirThrow launched but its command endpoint is unavailable.")
    }

    private static func output(_ response: Response, json: Bool, showSources: Bool = false) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(response) { print(String(decoding: data, as: UTF8.self)) }
        } else if let error = response.error {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
        } else if let status = response.status {
            print("\(response.message)\nState: \(status.state.rawValue)\nExternal video: \(status.externalPlaybackActive ? "yes" : "no")")
            print("Title: \(status.title)")
            if let path = status.playbackPath { print("Playback path: \(path.label) (tier \(path.tier))") }
            if let allowed = status.allowVideoConversion { print("Video re-encoding: \(allowed ? "allowed" : "avoided")") }
            if showSources, let sources = status.sources {
                print("Source selection: \(status.selectedSourceID ?? "automatic")")
                for source in sources {
                    print("  \(source.id): \(source.quality), \(source.playbackPath.label)\(source.audio.map { ", " + $0 } ?? "")")
                    if let reason = source.unavailableReason { print("    Unavailable: \(reason)") }
                }
            }
            if status.loadingPhase == "resolving" { print("Finding video…") }
            if status.loadingPhase == "preparing" { print("Preparing video…") }
            if let position = status.position { print("Position: \(String(format: "%.1f", position))s") }
            if let hasAudio = status.hasAudio {
                print(hasAudio ? "Audio track: detected" : "Audio track: not detected; try a link that includes audio")
            }
            if let queue = status.queue {
                print("Playlist: \(queue.title)")
                print("Item: \(queue.currentIndex + 1)/\(queue.items.count)")
            }
            if let error = status.error { print("Playback error: \(error)") }
        } else { print(response.message) }
    }
}
