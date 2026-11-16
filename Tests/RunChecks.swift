@testable import TextTankCore
import Foundation
@main struct RunChecks {
    static func main() {
        Checks.run("RunChecks") {
            for (command, field) in [
                (ConfiguredRun(name: "", executable: "/bin/echo", arguments: []), "name"),
                (
                    ConfiguredRun(name: "Fixture relative executable", executable: "relative", arguments: []),
                    "executable"
                ),
                (
                    ConfiguredRun(name: "Fixture invalid argument", executable: "/bin/echo", arguments: ["x\0y"]),
                    "argument 1"
                )
            ] {
                do {
                    try command.validate()
                    check(false, "F213 invalid command field is rejected")
                } catch {
                    check(
                        error.localizedDescription.lowercased().contains(field),
                        "F213 command validation identifies its \(field) field")
                    if !command.name.isEmpty {
                        check(
                            error.localizedDescription.contains(command.name),
                            "F213 command validation names the affected command")
                    }
                }
            }
            let dangerous = "space ; $(printf wrong) `touch /no` ' \""
            let c = ConfiguredRun(name: "Arguments", executable: "/usr/bin/printf", arguments: ["%s", "{selection}"])
            let resolved = try c.resolved(file: nil, selection: dangerous)
            let result = try RunExecution().execute(resolved)
            check(
                String(data: result.stdout, encoding: .utf8) == dangerous && result.status == 0,
                "argv preserves spaces quotes and shell metacharacters without interpretation")
            let sample = try RunExecution().execute(.uppercaseSample, input: Data("hello world α".utf8))
            check(
                String(data: sample.stdout, encoding: .utf8) == "HELLO WORLD α",
                "sample extension actual stdin stdout protocol")
            let fail = ConfiguredRun(
                name: "Fail", executable: "/bin/zsh", arguments: ["-c", "printf problem >&2; exit 7"], shellMode: true)
            let failed = try RunExecution().execute(fail)
            check(
                failed.status == 7 && String(data: failed.stderr, encoding: .utf8) == "problem",
                "explicit shell reports stderr and exit status")
            let cancelled = RunExecution()
            cancelled.cancel()
            let stopped = try cancelled.execute(c)
            check(
                stopped.reason == .cancelled && stopped.status == -1 && stopped.stdout.isEmpty,
                "cancel before launch prevents execution")
            let sleeper = ConfiguredRun(name: "Timeout", executable: "/bin/sleep", arguments: ["10"])
            let start = Date()
            let timeout = try RunExecution().execute(sleeper, timeout: 0.1)
            check(
                timeout.reason == .timedOut && Date().timeIntervalSince(start) < 10, "timeout terminates child promptly"
            )
            check(timeout.status == 128 + SIGTERM, "F146 a timed-out command reports 128 + SIGTERM")
            rejects("missing executable surfaces launch error") {
                _ = try RunExecution().execute(
                    ConfiguredRun(name: "Missing", executable: "/no/such/executable", arguments: []))
            }
            let noisy = try RunExecution().execute(
                ConfiguredRun(name: "Bounded output", executable: "/usr/bin/yes", arguments: []), timeout: 2)
            check(
                noisy.reason == .outputLimit && noisy.stdout.count + noisy.stderr.count <= 4 * 1024 * 1024,
                "output flood bounded and process stopped")
            check(noisy.stdout.count == 4 * 1024 * 1024, "the output limit is exactly 4 MiB")
            let descendant = ConfiguredRun(
                name: "Descendant", executable: "/bin/zsh", arguments: ["-c", "/bin/sleep 10 & exit 0"], shellMode: true
            )
            // The 0.5 s descendant grace must end the run long before the 10 s timeout or the 10 s sleep.
            let began = Date()
            let orphan = try RunExecution().execute(descendant, timeout: 10)
            check(
                orphan.reason == .lingeringDescendants && Date().timeIntervalSince(began) < 5,
                "inherited descendant pipes cannot retain worker indefinitely")
            Checks.section("lifecycle") { try lifecycleChecks(c) }
            let config = ConfiguredRun.uppercaseSample
            rejects("duplicate identities rejected before configuration save") {
                try ConfiguredRun.validateLibrary([config, config])
            }
            let encoded = try JSONEncoder().encode(config)
            check(
                try JSONDecoder().decode(ConfiguredRun.self, from: encoded) == config,
                "configuration roundtrip preserves extension identity without execution")
            var boundary = ConfiguredRun(name: "Boundary", executable: "/usr/bin/printf", arguments: [""])
            let overhead = try ConfiguredRun.encodeLibrary([boundary]).count
            boundary.arguments = [String(repeating: "x", count: ConfiguredRun.maximumLibraryBytes - overhead)]
            let boundaryData = try ConfiguredRun.encodeLibrary([boundary])
            check(
                boundaryData.count == ConfiguredRun.maximumLibraryBytes, "exact aggregate JSON byte boundary accepted")
            check(
                try ConfiguredRun.decodeLibrary(boundaryData) == [boundary], "exact-boundary library restart roundtrip")
            boundary.arguments[0] += "x"
            rejects("one byte over aggregate boundary rejected") { _ = try ConfiguredRun.encodeLibrary([boundary]) }
            let escaped = ConfiguredRun(
                name: "Escaped", executable: "/usr/bin/printf", arguments: [String(repeating: "\"\n", count: 300000)])
            rejects("JSON escaping counted in aggregate ceiling") { _ = try ConfiguredRun.encodeLibrary([escaped]) }
            let large = ConfiguredRun(
                name: "Large", executable: "/usr/bin/printf",
                arguments: [String(repeating: "x", count: 600000), String(repeating: "y", count: 600000)])
            rejects("valid individual arguments cannot exceed aggregate ceiling") {
                _ = try ConfiguredRun.encodeLibrary([large])
            }
            var second = large
            second.id = UUID()
            second.arguments.removeLast()
            var first = large
            first.arguments.removeLast()
            rejects("aggregate ceiling spans multiple commands") {
                _ = try ConfiguredRun.encodeLibrary([first, second])
            }
            rejects("restart rejects oversized bytes before JSON decoding") {
                _ = try ConfiguredRun.decodeLibrary(Data(repeating: 32, count: ConfiguredRun.maximumLibraryBytes + 1))
            }
            // Last: it changes how this process is told about its children.
            Checks.section("unknown exit status") {
                signal(SIGCHLD, SIG_IGN)
                defer { signal(SIGCHLD, SIG_DFL) }
                let unknown = try RunExecution().execute(
                    ConfiguredRun(name: "Unknown", executable: "/usr/bin/printf", arguments: ["text"]))
                check(
                    unknown.status == -1 && unknown.reason == .finished && unknown.stdout == Data("text".utf8),
                    "F146 an exit status that cannot be collected is -1, not a clean exit")
                check(unknown.statusLine.hasPrefix("No exit status"), "F146 an unknown exit status is shown as unknown")
            }
            Checks.summary { "PASS RunChecks: \(Checks.count) assertions" }
        }
    }
    static func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
    /// True when this process has no child left, running or waiting to be reaped.
    static func noChildren() -> Bool {
        var status: Int32 = 0
        return waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD
    }
    static func lifecycleChecks(_ printer: ConfiguredRun) throws {
        // F65: one reason per result, each shown differently.
        let lines = RunTermination.allCases.map { RunResult(stdout: Data(), stderr: Data(), status: 0, reason: $0) }
            .map(\.statusLine)
        check(Set(lines).count == RunTermination.allCases.count, "F65 every termination reason has its own status text")
        check(
            RunResult(stdout: Data(), stderr: Data(), status: 0, reason: .finished).statusLine == "Exit 0 · finished",
            "F65 a finished run is shown as before")
        let limitLine = RunResult(stdout: Data(), stderr: Data(), status: 143, reason: .outputLimit).statusLine
        check(
            limitLine.contains("output limit") && !limitLine.contains("cancel") && !limitLine.contains("time"),
            "F65 an output-limit stop is not described as cancelled or timed out")
        let lingerLine = RunResult(stdout: Data(), stderr: Data(), status: 0, reason: .lingeringDescendants).statusLine
        check(lingerLine.contains("background process"), "F65 a lingering descendant is named as the cause")
        check(
            RunTermination.cancelled.summary != RunTermination.timedOut.summary,
            "F65 cancel and timeout are told apart")
        check(RunExecution.defaultTimeout == 30, "the default time limit is 30 seconds")
        rejects("input over 4 MiB is refused before launch", expecting: RunFailure.tooLarge) {
            _ = try RunExecution().execute(.uppercaseSample, input: Data(count: 4 * 1024 * 1024 + 1))
        }

        // F116: cancel and wait is signalled by the worker and leaves no process behind.
        check(RunExecution().cancelAndWait(timeout: 0), "F116 cancel and wait on an idle execution returns at once")
        let leader = ConfiguredRun(
            name: "Leader", executable: "/bin/zsh", arguments: ["-c", "echo $$; exec /bin/sleep 30"], shellMode: true)
        let quitting = RunExecution(), done = DispatchSemaphore(value: 0)
        var quitResult: Result<RunResult, Error>?
        DispatchQueue.global().async {
            quitResult = Result { try quitting.execute(leader) }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)
        let asked = Date()
        let waited = quitting.cancelAndWait(timeout: 5), took = Date().timeIntervalSince(asked)
        check(waited && took < 2, "F116 cancel and wait returns once the command has stopped")
        _ = done.wait(timeout: .now() + 5)
        let quit = try requireValue(try quitResult?.get(), "the cancelled run returned a result")
        check(quit.reason == .cancelled, "F116 the stopped command reports cancelled")
        let leaderPid = try requireValue(
            pid_t(String(decoding: quit.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
            "the command printed its process id before it was stopped")
        check(isGone(leaderPid), "F116 the command's process is gone when cancel and wait returns")
        check(noChildren(), "F146 a cancelled run leaves no unreaped child")
        let blocked = RunExecution(), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? blocked.execute(
                ConfiguredRun(
                    name: "Ignores TERM", executable: "/bin/zsh", arguments: ["-c", "trap '' TERM; /bin/sleep 30"],
                    shellMode: true))
            release.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)
        check(blocked.cancelAndWait(timeout: 2), "F116 a command that ignores SIGTERM is killed within the wait")
        _ = release.wait(timeout: .now() + 5)

        // F142: working directory and environment.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TextTankRunChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pwd = ConfiguredRun(name: "Where", executable: "/bin/pwd", arguments: [])
        func path(_ result: RunResult) -> String {
            URL(fileURLWithPath: String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines))
                .resolvingSymlinksInPath().path
        }
        check(
            path(try RunExecution().execute(pwd, workingDirectory: folder)) == folder.resolvingSymlinksInPath().path,
            "F142 the command starts in the working directory it is given")
        let inherited = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        check(
            path(try RunExecution().execute(pwd)) == inherited,
            "F142 without a working directory the command inherits the caller's")
        check(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path == inherited,
            "F142 a run does not change this process's working directory")
        rejects("F142 a missing working directory is a launch error, not a run elsewhere") {
            _ = try RunExecution().execute(pwd, workingDirectory: folder.appendingPathComponent("absent"))
        }
        setenv("TEXTTANK_RUN_CHECK_MARKER", "1", 1)
        defer { unsetenv("TEXTTANK_RUN_CHECK_MARKER") }
        let environment = String(
            decoding: try RunExecution().execute(
                ConfiguredRun(name: "Environment", executable: "/usr/bin/env", arguments: [])
            ).stdout, as: UTF8.self
        ).components(separatedBy: "\n")
        check(
            environment.contains("TEXTTANK_RUN_CHECK_MARKER=1") && environment.contains { $0.hasPrefix("PATH=") }
                && environment.contains { $0.hasPrefix("HOME=") }, "F142 the environment is inherited unfiltered")

        // F143: a selection that cannot be an argument has its own error.
        let megabyte = 1024 * 1024
        rejects("F143 a selection containing NUL is refused as a selection", expecting: RunFailure.selectionUnsuitable)
        { _ = try printer.resolved(file: nil, selection: "a\0b") }
        rejects("F143 a selection over 1 MiB is refused as a selection", expecting: RunFailure.selectionUnsuitable) {
            _ = try printer.resolved(file: nil, selection: String(repeating: "x", count: megabyte + 1))
        }
        check(
            try printer.resolved(file: nil, selection: String(repeating: "x", count: megabyte)).arguments[1].utf8.count
                == megabyte, "F143 a selection of exactly 1 MiB still resolves")
        let fixed = ConfiguredRun(name: "No placeholder", executable: "/usr/bin/printf", arguments: ["fixed"])
        check(
            try fixed.resolved(file: nil, selection: "a\0b") == fixed
                && fixed.resolved(file: nil, selection: String(repeating: "x", count: megabyte + 1)) == fixed,
            "F143 a command without {selection} ignores an unsuitable selection")
        rejects(
            "F143 a stored argument containing NUL is still an invalid command",
            where: {
                if case RunFailure.configuration(field: .argument(1), message: _) = $0 { return true }
                return false
            }
        ) {
            _ = try ConfiguredRun(name: "Stored NUL", executable: "/usr/bin/printf", arguments: ["a\0b"]).resolved(
                file: nil, selection: "")
        }
        check(
            try printer.resolved(file: nil, selection: "-n").arguments == ["%s", "-n"],
            "F143 a selection beginning with - is passed unchanged and nothing is inserted")
        check(
            (RunFailure.selectionUnsuitable.errorDescription ?? "").contains("selection")
                && RunFailure.selectionUnsuitable.errorDescription != RunFailure.invalid.errorDescription,
            "F143 the selection error names the selection")
        let shell = ConfiguredRun(
            name: "Shell", executable: "/bin/zsh", arguments: ["-c", "echo {selection}"], shellMode: true)
        check(
            try shell.resolved(file: nil, selection: "a\0b") == shell,
            "shell mode never substitutes the selection into shell code")

        // F146: descendants that redirected their output are still cleaned up, nothing is left
        // unreaped, and an ordinary run does not pay the 100 ms group sweep.
        let redirecting = ConfiguredRun(
            name: "Redirecting", executable: "/bin/zsh",
            arguments: ["-c", "/bin/sleep 10 >/dev/null 2>&1 & echo $!; exit 0"], shellMode: true)
        let redirectStart = Date()
        let redirected = try RunExecution().execute(redirecting, timeout: 10)
        let redirectTook = Date().timeIntervalSince(redirectStart)
        check(
            redirected.status == 0 && redirected.reason == .finished && redirectTook < 3,
            "F146 a descendant that redirected its output does not hold the run open")
        let childPid = try requireValue(
            pid_t(String(decoding: redirected.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
            "the shell printed its background process id")
        let gone = Date().addingTimeInterval(3)
        while !isGone(childPid) && Date() < gone { Thread.sleep(forTimeInterval: 0.01) }
        check(isGone(childPid), "F146 a descendant that redirected its output is stopped when the run finishes")
        check(noChildren(), "F146 a finished run leaves no unreaped child")
        var fastest = TimeInterval.infinity
        for _ in 0..<5 {
            let began = Date()
            _ = try RunExecution().execute(printer)
            fastest = min(fastest, Date().timeIntervalSince(began))
        }
        check(fastest < 0.09, "F146 an ordinary run does not wait for the group sweep (\(Int(fastest * 1000)) ms)")
        check(noChildren(), "F146 ordinary runs leave no unreaped child")

        // F137: the summary shown as a menu tooltip.
        check(
            ConfiguredRun.uppercaseSample.summary() == "text extension: /usr/bin/tr a-z A-Z",
            "F137 the summary names mode, executable and arguments")
        check(
            ConfiguredRun(name: "S", executable: "/bin/zsh", arguments: ["-c", "echo hi\nexit 0"], shellMode: true)
                .summary() == "shell: /bin/zsh -c \"echo hi exit 0\"", "F137 the summary marks shell mode on one line")
        check(
            ConfiguredRun(name: "P", executable: "/usr/bin/printf", arguments: ["", "{file}"]).summary()
                == "/usr/bin/printf \"\" {file}", "F137 the summary shows an empty argument")
        let long = ConfiguredRun(
            name: "Long", executable: "/usr/bin/printf", arguments: [String(repeating: "x", count: megabyte), "tail"])
        check(
            long.summary().count <= 301 && long.summary().hasSuffix("…") && long.summary().hasPrefix("/usr/bin/printf"),
            "F137 the summary is bounded for a 1 MiB argument")
    }
}
