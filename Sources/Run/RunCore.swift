// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
package struct ConfiguredRun: Codable, Equatable, Sendable {
    package init(
        version: Int = 1, id: UUID = UUID(), name: String, executable: String, arguments: [String],
        shellMode: Bool = false, extensionMode: Bool = false
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.shellMode = shellMode
        self.extensionMode = extensionMode
    }

    package var version: Int
    package var id: UUID
    package var name: String
    package var executable: String
    package var arguments: [String]
    package var shellMode: Bool
    package var extensionMode: Bool
    package func validate() throws {
        let title = String(name.prefix(200))
        guard version == 1 else {
            throw RunFailure.configuration(
                field: .version,
                message: "Run command “\(title)” requires version 1. The saved commands were not changed.")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200 else {
            throw RunFailure.configuration(
                field: .name,
                message: "The Run command name must contain 1–200 characters. The saved commands were not changed.")
        }
        guard executable.hasPrefix("/"), !executable.contains("\0") else {
            throw RunFailure.configuration(
                field: .executable,
                message:
                    "Run command “\(title)” must use an absolute executable path without a NUL character. The saved commands were not changed."
            )
        }
        guard arguments.count <= 256 else {
            throw RunFailure.configuration(
                field: .arguments,
                message:
                    "Run command “\(title)” must contain at most 256 arguments. The saved commands were not changed.")
        }
        for (index, argument) in arguments.enumerated() {
            guard !argument.contains("\0"), argument.utf8.count <= SizePolicy.standard.runArgument else {
                throw RunFailure.configuration(
                    field: .argument(index + 1),
                    message:
                        "Argument \(index + 1) of Run command “\(title)” must contain no NUL character and be at most \(SizePolicy.describe(SizePolicy.standard.runArgument)). Shorten the argument before saving."
                )
            }
        }
        guard !(shellMode && extensionMode) else {
            throw RunFailure.configuration(
                field: .mode,
                message:
                    "Run command “\(title)” cannot use shell mode and text extension mode together. The saved commands were not changed."
            )
        }
        if shellMode && (executable != "/bin/zsh" || arguments.count != 2 || arguments.first != "-c") {
            throw RunFailure.configuration(
                field: .shell,
                message:
                    "Run command “\(title)” must use /bin/zsh with -c and one script argument in shell mode. The saved commands were not changed."
            )
        }
    }
    package func resolved(file: URL?, selection: String) throws -> Self {
        try validate()
        var result = self
        // Shell code never interpolates document contents. Those values are exposed
        // only through positional argv in ordinary executable mode.
        if !shellMode {
            result.arguments = try arguments.map { arg in
                if arg == "{file}" {
                    guard let file else { throw RunFailure.fileRequired }
                    return file.path
                }
                if arg == "{directory}" {
                    guard let file else { throw RunFailure.fileRequired }
                    return file.deletingLastPathComponent().path
                }
                if arg == "{selection}" {
                    // Checked here, not left to validate(), so the error names the selection and not
                    // the saved command. The limits are the ones validate() applies to an argument.
                    guard !selection.contains("\0"), selection.utf8.count <= SizePolicy.standard.runArgument else {
                        throw RunFailure.selectionUnsuitable
                    }
                    return selection
                }
                return arg
            }
        }
        try result.validate()
        return result
    }
    static package func validateLibrary(_ commands: [Self]) throws {
        guard commands.count <= 1000 else {
            throw RunFailure.configuration(
                field: .library, message: "Keep at most 1000 Run commands. The saved commands were not changed.")
        }
        var seen = Set<UUID>()
        for command in commands {
            guard seen.insert(command.id).inserted else {
                throw RunFailure.configuration(
                    field: .identity,
                    message:
                        "Run command “\(String(command.name.prefix(200)))” appears more than once. The saved commands were not changed."
                )
            }
            try command.validate()
        }
    }
    /// One shared byte ceiling for persistence and restart, including JSON escaping.
    static package let maximumLibraryBytes = SizePolicy.standard.runLibrary
    static package func encodeLibrary(_ commands: [Self], sortedKeys: Bool = false) throws -> Data {
        try validateLibrary(commands)
        // Reject obviously oversized inputs before JSONEncoder allocates an expanded
        // representation. JSON overhead/escaping is checked on the encoded result.
        var remaining = maximumLibraryBytes
        for command in commands {
            for field in [command.name, command.executable] + command.arguments {
                let bytes = field.utf8.count
                guard bytes <= remaining else { throw RunFailure.configurationTooLarge }
                remaining -= bytes
            }
        }
        let encoder = JSONEncoder()
        if sortedKeys { encoder.outputFormatting = .sortedKeys }
        let data = try encoder.encode(commands)
        guard data.count <= maximumLibraryBytes else { throw RunFailure.configurationTooLarge }
        return data
    }
    static package func decodeLibrary(_ data: Data) throws -> [Self] {
        guard data.count <= maximumLibraryBytes else { throw RunFailure.configurationTooLarge }
        try PersistedFormat.check(data, context: "Run commands", array: true)
        let commands = try JSONInputFailure.decode([Self].self, from: data, context: "Run commands")
        try validateLibrary(commands)
        return commands
    }
    /// What selecting this command executes, for the menu tooltip: the mode, the executable and
    /// the arguments as stored. Bounded, because one argument may be up to 1 MiB.
    package func summary(limit: Int = 300) -> String {
        var text = (shellMode ? "shell: " : extensionMode ? "text extension: " : "") + executable
        for argument in arguments where text.count <= limit {
            let shown = String(argument.prefix(limit + 1)).map { $0.isNewline || $0 == "\t" ? " " : $0 }
            let quoted = argument.isEmpty || argument.contains(where: { $0.isWhitespace || $0 == "\"" })
            text += " " + (quoted ? "\"" + String(shown) + "\"" : String(shown))
        }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
    /// Version 1 extension contract: UTF-8 document/selection on stdin, UTF-8 result
    /// on stdout, diagnostics on stderr, exit 0 required. No automatic mutation.
    static package var uppercaseSample: Self {
        Self(
            name: "Uppercase ASCII (sample extension)", executable: "/usr/bin/tr", arguments: ["a-z", "A-Z"],
            extensionMode: true)
    }
}
package enum RunConfigurationField: Equatable {
    case version, name, executable, arguments, argument(Int), mode, shell, library, identity
}
package enum RunFailure: Error, LocalizedError, Equatable {
    case invalid, fileRequired, busy, tooLarge, configurationTooLarge, documentChanged, documentClosed
    case selectionUnsuitable, noDocument, multipleSelections
    case configuration(field: RunConfigurationField, message: String)
    case preparationFailed(Int32)
    package var errorDescription: String? {
        switch self {
        case .noDocument: return "Open a document before running a text extension. Nothing was changed."
        case .multipleSelections:
            return
                "This text extension needs one selection. Collapse multiple selections and try again. Nothing was changed."
        case .configuration(_, let message): return message
        case .preparationFailed(let code):
            return "The command could not be prepared: \(String(cString: strerror(code))). Nothing was run."
        case .invalid: return "Invalid command configuration. Use an absolute executable path and an argument array."
        case .fileRequired: return "This command needs a saved document path."
        case .busy: return "A command is already running. Wait for it to finish or cancel it, then try again."
        case .documentChanged:
            return "The document or selection changed since this command ran. Run it again. Nothing was changed."
        case .documentClosed: return "The document this command ran on is closed. The result was not applied."
        case .configurationTooLarge:
            return
                "Saved Run commands exceed the \(SizePolicy.describe(SizePolicy.standard.runLibrary)) configuration limit. Shorten arguments or remove commands; the existing configuration was preserved."
        case .tooLarge: return "Process input or output exceeds the \(SizePolicy.describe(SizePolicy.standard.runIO)) limit. Use a smaller input or reduce command output."
        case .selectionUnsuitable:
            return
                "The selection cannot be passed as an argument: it contains a NUL character or exceeds \(SizePolicy.describe(SizePolicy.standard.runArgument)). Shorten the selection, or use a text extension, which receives the selection on standard input."
        }
    }
}
/// Why a run ended. Exactly one applies; only `finished` leaves complete output.
package enum RunTermination: Equatable, CaseIterable, Sendable {
    /// The command exited by itself and all of its output was read.
    case finished
    /// The user cancelled it, or TextTank was quitting.
    case cancelled
    /// It was still running at the time limit.
    case timedOut
    /// The process produced more output than its input/output allowance.
    case outputLimit
    /// It exited, but a process it started still held its output open and was stopped.
    case lingeringDescendants
    package var summary: String {
        switch self {
        case .finished: return "finished"
        case .cancelled: return "cancelled"
        case .timedOut: return "stopped at the time limit"
        case .outputLimit: return "stopped at the \(SizePolicy.describe(SizePolicy.standard.runIO)) output limit; output is incomplete"
        case .lingeringDescendants:
            return
                "finished, but a background process it started kept the output open and was stopped; output may be incomplete"
        }
    }
}
package struct RunResult: Sendable {
    package init(stdout: Data, stderr: Data, status: Int32, reason: RunTermination) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.reason = reason
    }

    package let stdout: Data, stderr: Data
    /// The exit status, 128 + signal for a signalled leader, or -1 when no status is known
    /// (nothing was launched, or the exit status could not be collected).
    package let status: Int32
    package let reason: RunTermination
    package var statusLine: String { (status < 0 ? "No exit status" : "Exit \(status)") + " · " + reason.summary }
}
/// Explicit process group with bounded nonblocking pipes. Imports are inert.
final package class RunExecution: @unchecked Sendable {
    package init() {}

    private let lock = NSLock()
    private var active = false, cancelRequested = false
    private let running = DispatchGroup()
    static package let defaultTimeout: TimeInterval = 30
    package func cancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
    }
    private var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }
    /// Cancels and waits until `execute` has returned on its own thread, so the child and its
    /// process group are gone. The wait is signalled by the worker, never by the main queue, so
    /// this may be called from the main thread. True when nothing is running any more.
    package func cancelAndWait(timeout: TimeInterval) -> Bool {
        cancel()
        return running.wait(timeout: .now() + timeout) == .success
    }
    /// `workingDirectory` nil inherits the caller's working directory. The environment is always
    /// inherited as it is.
    package func execute(
        _ command: ConfiguredRun, input: Data = Data(), timeout: TimeInterval = RunExecution.defaultTimeout,
        workingDirectory: URL? = nil
    ) throws -> RunResult {
        try command.validate()
        guard input.count <= SizePolicy.standard.runIO else { throw RunFailure.tooLarge }
        lock.lock()
        guard !active else {
            lock.unlock()
            throw RunFailure.busy
        }
        active = true
        running.enter()
        lock.unlock()
        defer {
            lock.lock()
            active = false
            lock.unlock()
            running.leave()
        }
        if cancelled { return RunResult(stdout: Data(), stderr: Data(), status: -1, reason: .cancelled) }
        func failure() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Anonymous temporary input avoids SIGPIPE and a blocked writer when a child
        // deliberately never reads stdin. tmpfile is private and unlinked by libc.
        guard let file = tmpfile() else { throw failure() }
        defer { fclose(file) }
        if !input.isEmpty {
            let written = input.withUnsafeBytes { fwrite($0.baseAddress, 1, input.count, file) }
            guard written == input.count, fflush(file) == 0 else { throw failure() }
        }
        rewind(file)
        var stdoutPipe: [Int32] = [0, 0], stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else { throw failure() }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            throw failure()
        }
        var descriptors = stdoutPipe + stderrPipe
        defer { for fd in descriptors where fd >= 0 { close(fd) } }
        for fd in [stdoutPipe[0], stderrPipe[0]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw failure() }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        let actionsError = posix_spawn_file_actions_init(&actions)
        guard actionsError == 0 else { throw RunFailure.preparationFailed(actionsError) }
        let attributesError = posix_spawnattr_init(&attributes)
        guard attributesError == 0 else {
            posix_spawn_file_actions_destroy(&actions)
            throw RunFailure.preparationFailed(attributesError)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, fileno(file), STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        for fd in descriptors { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawn_file_actions_addclose(&actions, fileno(file))
        // Per-child only. The process-wide working directory is never changed: this runs on a
        // worker thread and the working directory is shared by the whole app.
        if let workingDirectory { posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var argv = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        var env = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer {
            for p in argv { free(p) }
            for p in env { free(p) }
        }
        var pid: pid_t = 0
        let launched = posix_spawn(&pid, command.executable, &actions, &attributes, &argv, &env)
        guard launched == 0 else { throw POSIXError(POSIXErrorCode(rawValue: launched) ?? .EIO) }
        close(stdoutPipe[1])
        descriptors[1] = -1
        close(stderrPipe[1])
        descriptors[3] = -1
        var output = Data(), errors = Data(), eof = [false, false], exited = false, limited = false
        var waitFailed = false, reason = RunTermination.finished
        let deadline = Date().addingTimeInterval(max(0.05, min(timeout, 300)))
        var exitDate: Date?
        func drain(_ fd: Int32, _ destination: inout Data, _ ended: inout Bool) {
            var bytes = [UInt8](repeating: 0, count: 65536)
            for _ in 0..<64 {
                let n = read(fd, &bytes, bytes.count)
                if n == 0 {
                    ended = true
                    break
                }
                if n < 0 {
                    if errno != EAGAIN && errno != EINTR { ended = true }
                    break
                }
                let remaining = max(0, SizePolicy.standard.runIO - output.count - errors.count - destination.count)
                destination.append(contentsOf: bytes.prefix(min(n, remaining)))
                if n > remaining {
                    limited = true
                    break
                }
            }
        }
        // The leader is observed without being reaped (WNOWAIT) and reaped only as the last step.
        // Until then its zombie keeps the pid, and so the process-group id, from being reused, so
        // every kill(-pid, ...) below can only reach this run's own group. Darwin also reports a
        // stopped child here although only WEXITED is asked for, hence the si_code test.
        func leaderExited(wait: Bool) -> Bool {
            var info = siginfo_t()
            let options = WEXITED | WNOWAIT | (wait ? 0 : WNOHANG)
            if waitid(P_PID, id_t(pid), &info, options) == 0 {
                return info.si_pid == pid && [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(info.si_code)
            }
            if errno == EINTR { return false }
            // The child cannot be waited for (for example SIGCHLD is ignored, so it was reaped by
            // the system). Its status is unknown and is reported as -1, never as a clean exit.
            waitFailed = true
            return true
        }
        while true {
            // Separate temporary buffers avoid overlapping inout access to output.
            var chunk = Data()
            drain(stdoutPipe[0], &chunk, &eof[0])
            output.append(chunk)
            chunk = Data()
            drain(stderrPipe[0], &chunk, &eof[1])
            errors.append(chunk)
            if !exited, leaderExited(wait: false) {
                exited = true
                exitDate = Date()
            }
            if exited && eof.allSatisfy({ $0 }) { break }
            let timedOut = Date() >= deadline
            if cancelled || limited || timedOut {
                reason = cancelled ? .cancelled : limited ? .outputLimit : .timedOut
                kill(-pid, SIGTERM)
                break
            }
            if let exitDate, Date().timeIntervalSince(exitDate) > 0.5 {
                // A descendant holding output open belongs to this configured run.
                reason = .lingeringDescendants
                kill(-pid, SIGTERM)
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if reason != .finished {
            let grace = Date().addingTimeInterval(0.1)
            while !exited && Date() < grace {
                if leaderExited(wait: false) {
                    exited = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            kill(-pid, SIGKILL)
        }
        while !exited {
            if leaderExited(wait: true) { exited = true } else { Thread.sleep(forTimeInterval: 0.001) }
        }
        // Runs are scoped jobs, never implicit daemon launchers. Clean up remaining
        // group members even if the leader exited and descendants closed output.
        // A zombie leader alone does not answer this probe, so an ordinary run does not wait here.
        if kill(-pid, 0) == 0 {
            kill(-pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.1)
            kill(-pid, SIGKILL)
        }
        var status: Int32 = 0, reaped = false
        while !waitFailed {
            let waited = waitpid(pid, &status, 0)
            if waited == pid { reaped = true }
            if waited == pid || errno != EINTR { break }
        }
        let exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return RunResult(stdout: output, stderr: errors, status: reaped ? exitStatus : -1, reason: reason)
    }
}
