import AppKit
import Foundation
#if SWIFT_PACKAGE
import AirPlayerCore
#endif

@main
struct AirPlayerCLI {
    private static let helpText = """
    AirPlayer — control the native AirPlay video session

    Usage:
      airplayer open SOURCE     Load a URL, YouTube playlist, or local file, paused
      airplayer play            Start/resume on the selected video receiver
      airplayer pause           Pause the current session
      airplayer seek SECONDS    Seek to an absolute position
      airplayer previous        Load the previous playlist item
      airplayer next            Load the next playlist item
      airplayer stop            Stop and unload the video
      airplayer status [--json] Show observed playback state
      airplayer sources         List available quality/source choices and their IDs
      airplayer source ID       Reload a listed source, paused (or use automatic)
      airplayer conversion allow-video|avoid-video
                                Set video conversion preference for future loads
      airplayer show            Open the controller and choose a receiver

    --json is available on every command. Receiver selection uses the app's
    AirPlay picker. open and show launch AirPlayer if needed.
    Set AIRPLAYER_APP to an explicit AirPlayer.app path for development.
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
            let failure = error as? AppFailure ?? AppFailure(.appUnavailable, "Could not communicate with AirPlayer.")
            output(Response(error: failure), json: json)
            exit(failure.code.exitCode)
        }
    }

    @MainActor private static func launch() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent()
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["AIRPLAYER_APP"] {
            candidates.append(URL(fileURLWithPath: explicit))
        } else {
            candidates += [directory.appendingPathComponent("AirPlayer.app"),
                           directory.deletingLastPathComponent().deletingLastPathComponent(),
                           URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/AirPlayer.app"),
                           URL(fileURLWithPath: "/Applications/AirPlayer.app")]
        }
        guard let app = candidates.first(where: {
            $0.pathExtension == "app" && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/AirPlayerApp").path)
        }) else { throw AppFailure(.appUnavailable, "AirPlayer.app was not found. Build/install the app or set AIRPLAYER_APP to its path.") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
        for _ in 0..<40 {
            let ready = await Task.detached { (try? LocalSocket.send(Request(.status))) != nil }.value
            if ready { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AppFailure(.appUnavailable, "AirPlayer launched but its command endpoint is unavailable.")
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
            if let allowed = status.allowVideoConversion { print("Video conversion: \(allowed ? "allowed" : "avoided")") }
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
