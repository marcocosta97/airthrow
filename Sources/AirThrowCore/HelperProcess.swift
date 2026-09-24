import Foundation
import Darwin

struct HelperExecutables {
    let environment: [String: String]
    func executable(_ name: String, override: String) -> String? {
        let fm = FileManager.default
        if let path = environment[override] {
            return path.hasPrefix("/") && fm.isExecutableFile(atPath: path) ? path : nil
        }
        let paths = ["/opt/homebrew/bin", "/usr/local/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.filter { $0.hasPrefix("/") }.map { "\($0)/\(name)" }
            .first { fm.isExecutableFile(atPath: $0) }
    }
}

/// A private process group lets cancellation also stop the helper's JS runtime.
/// Pipes are drained without blocking or retaining unbounded extractor output.
enum HelperProcess {
    struct Result: Sendable {
        let output: Data
        /// A bounded prefix of the helper's stderr, for classifying failures.
        /// It is never logged or placed in status; callers must not surface it.
        let stderr: Data
        let succeeded: Bool
    }

    static func run(executable: String, arguments: [String], timeout: Duration? = .seconds(40),
                    outputLimit: Int = 8 * 1024 * 1024,
                    monitor: (@Sendable () throws -> Void)? = nil) async throws -> Data {
        let result = try await execute(executable: executable, arguments: arguments, timeout: timeout,
                                       outputLimit: outputLimit, monitor: monitor)
        guard result.succeeded else { throw ResolutionFailure.failed }
        return result.output
    }

    static func runCapturingStderr(executable: String, arguments: [String], timeout: Duration = .seconds(40),
                                   outputLimit: Int = 8 * 1024 * 1024,
                                   monitor: (@Sendable () throws -> Void)? = nil) async throws -> Result {
        try await execute(executable: executable, arguments: arguments, timeout: timeout,
                          outputLimit: outputLimit, monitor: monitor)
    }

    private static func execute(executable: String, arguments: [String], timeout: Duration?,
                                outputLimit: Int, monitor: (@Sendable () throws -> Void)?) async throws -> Result {
        try Task.checkCancellation()
        var output: [Int32] = [0, 0]
        var errors: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { throw ResolutionFailure.failed }
        defer { close(output[0]) }
        guard pipe(&errors) == 0 else {
            close(output[1]); throw ResolutionFailure.failed
        }
        defer { close(errors[0]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Do not inherit Python paths, proxy credentials or helper-specific environment options.
        let environment = ["PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG=en_US.UTF-8",
                           "HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)"]
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let launched = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        close(output[1]); close(errors[1])
        guard launched == 0 else { throw ResolutionFailure.unavailable }
        var reaped = false
        defer {
            // Always reap the parent and terminate any remaining descendants.
            kill(-pid, SIGKILL)
            if !reaped {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        for fd in [output[0], errors[0]] {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw ResolutionFailure.failed }
        }
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: $0) }
        var nextMonitor = clock.now
        var data = Data()
        var stderrData = Data()
        var errorBytes = 0
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var status: Int32 = 0
        while true {
            try Task.checkCancellation()
            if let deadline, clock.now >= deadline { throw ResolutionFailure.timedOut }
            if clock.now >= nextMonitor {
                try monitor?()
                nextMonitor = clock.now.advanced(by: .milliseconds(250))
            }
            for fd in [output[0], errors[0]] {
                // Bound each pass so a noisy process cannot starve cancellation or stderr.
                for _ in 0..<32 {
                    let count = read(fd, &buffer, buffer.count)
                    if count <= 0 {
                        if count < 0 && errno != EAGAIN && errno != EINTR { throw ResolutionFailure.failed }
                        break
                    }
                    if fd == output[0] {
                        guard data.count + count <= outputLimit else { throw ResolutionFailure.tooMuchOutput }
                        data.append(contentsOf: buffer.prefix(count))
                    } else {
                        errorBytes += count
                        if stderrData.count < 8192 {
                            stderrData.append(contentsOf: buffer.prefix(min(count, 8192 - stderrData.count)))
                        }
                        guard errorBytes <= 256 * 1024 else { throw ResolutionFailure.tooMuchOutput }
                    }
                }
            }
            // One more drain after exit collects bytes written immediately before termination.
            if reaped {
                return Result(output: data, stderr: stderrData, succeeded: status == 0)
            }
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { reaped = true }
            else if result < 0 && errno != EINTR { throw ResolutionFailure.failed }
            if !reaped { try await Task.sleep(for: .milliseconds(20)) }
        }
    }
}
