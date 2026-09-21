import Foundation

/// Pure command-line parsing shared by the CLI executable and its regressions.
///
/// The parser only builds a `Request` and records presentation flags. It never
/// launches the app, opens a socket, prints, or exits, so checks can exercise
/// the real production parsing without side effects.
public enum CLIArguments {
    /// Maximum accepted byte length of a `source` identifier.
    public static let sourceIDLimit = 128

    /// A parsed request together with the flags that affect presentation.
    public struct Parsed: Sendable {
        public let command: Command
        public let request: Request
        public let json: Bool
        public let showsSources: Bool
    }

    public enum Invocation: Sendable {
        case help
        case run(Parsed)
    }

    /// Parses arguments after the executable name. Throws `AppFailure` with
    /// `.invalidRequest` for the same malformed inputs the CLI has always
    /// rejected, preserving its usage messages and exit codes.
    public static func parse(_ rawArguments: [String]) throws -> Invocation {
        var arguments = rawArguments
        if arguments.isEmpty || arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
            return .help
        }
        let json = arguments.contains("--json")
        arguments.removeAll { $0 == "--json" }
        guard let first = arguments.first, let command = Command(rawValue: first) else {
            throw AppFailure(.invalidRequest, "Unknown command. Run airplayer --help.")
        }
        var request = Request(command)
        switch command {
        case .open:
            guard arguments.count == 2 else { throw AppFailure(.invalidRequest, "Usage: airplayer open URL_OR_PATH") }
            let source = try MediaInput.source(arguments[1])
            // The app has a different working directory. Resolve relative paths
            // in the invoking shell before sending the request.
            request.url = source.isFileURL ? source.path : arguments[1]
        case .seek:
            guard arguments.count == 2, let seconds = Double(arguments[1]), seconds.isFinite, seconds >= 0 else {
                throw AppFailure(.invalidRequest, "Usage: airplayer seek SECONDS (finite and nonnegative)")
            }
            request.seconds = seconds
        case .source:
            guard arguments.count == 2, !arguments[1].isEmpty, arguments[1].utf8.count <= sourceIDLimit else {
                throw AppFailure(.invalidRequest, "Usage: airplayer source ID_OR_automatic")
            }
            request.sourceID = arguments[1]
        case .conversion:
            guard arguments.count == 2, ["allow-video", "avoid-video"].contains(arguments[1]) else {
                throw AppFailure(.invalidRequest, "Usage: airplayer conversion allow-video|avoid-video")
            }
            request.allowVideoConversion = arguments[1] == "allow-video"
        default:
            guard arguments.count == 1 else { throw AppFailure(.invalidRequest, "Unexpected arguments. Run airplayer --help.") }
        }
        return .run(Parsed(command: command, request: request, json: json, showsSources: command == .sources))
    }
}
