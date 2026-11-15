// SPDX-License-Identifier: GPL-3.0-or-later
// Proves the shared check harness itself: a failed check is named with its file
// and line, later checks and later sections still run, and the process exits
// non-zero. The demonstration suite runs in a child process so that its
// deliberate failures do not fail this one.
import Foundation

enum DemoError: Error, Equatable { case intended, other }

@main struct HarnessChecks {
    static func demonstration() async -> Never {
        await Checks.run("HarnessDemo") {
            Checks.section("first") {
                check(true, "demo first check")
                check(true, "demo second check")
                check(true, "demo third check")
                rejects("demo typed rejection", expecting: DemoError.intended) { throw DemoError.intended }
                if ProcessInfo.processInfo.environment["HARNESS_DEMO_FAULTS"] != nil {
                    rejects("demo wrong error", expecting: DemoError.intended) { throw DemoError.other }
                    rejects("demo nothing thrown") {}
                    rejects("demo wrong message", message: "expected words") { throw DemoError.other }
                    check(try { throw DemoError.other }(), "demo throwing condition")
                    spinUntil(timeout: 0.05, "demo condition that never holds") { false }
                }
            }
            Checks.section("precondition") {
                if ProcessInfo.processInfo.environment["HARNESS_DEMO_FAULTS"] != nil {
                    try require(false, "demo precondition")
                    check(true, "demo unreachable check")
                }
            }
            Checks.section("thrown") {
                if ProcessInfo.processInfo.environment["HARNESS_DEMO_FAULTS"] != nil { throw DemoError.other }
            }
            await Checks.section("asynchronous") {
                if ProcessInfo.processInfo.environment["HARNESS_DEMO_FAULTS"] != nil {
                    await waitUntil(timeout: 0.05, "demo asynchronous condition that never holds") { false }
                    await rejects("demo asynchronous nothing thrown") { await Task.yield() }
                }
            }
            Checks.section("later") { check(true, "demo later section") }
            fixtureCheck(true, "demo fixture")
            Checks.summary { "PASS HarnessDemo: \(Checks.count) assertions" }
        }
    }
    static func child(_ environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = Checks.executable
        process.arguments = ["--demonstration"]
        var merged = ProcessInfo.processInfo.environment
        merged["TEXTTANK_FORCE_FAIL"] = nil; merged["HARNESS_DEMO_FAULTS"] = nil
        for (key, value) in environment { merged[key] = value }
        process.environment = merged
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "--demonstration" { await demonstration() }
        await Checks.run("HarnessChecks") {
            let clean = try child([:])
            let cleanLines = clean.output.split(separator: "\n").map(String.init)
            check(clean.status == 0, "suite with no failure exits zero")
            check(cleanLines.contains("PASS demo first check") && cleanLines.contains("PASS demo typed rejection"), "passing checks print PASS and their label")
            check(cleanLines.contains("PASS HarnessDemo: 5 assertions"), "summary line reports the number of passed checks")
            check(cleanLines.contains("FIXTURE demo fixture") && cleanLines.contains("FIXTURES HarnessDemo: 1 fixture integrity checks, not counted below"), "fixture integrity checks are reported apart from behaviour checks")
            check(!clean.output.contains("FAIL"), "clean run prints no failure line")

            let forced = try child(["TEXTTANK_FORCE_FAIL": "demo second check"])
            let forcedLines = forced.output.split(separator: "\n").map(String.init)
            check(forced.status == 1, "one forced failure makes the suite exit non-zero")
            check(forcedLines.contains { $0.hasPrefix("FAIL Tests/HarnessChecks.swift:") && $0.hasSuffix(" demo second check") }, "failure line names the file, the line and the label")
            check(forcedLines.contains("PASS demo third check"), "checks after a failure in the same section still run")
            check(forcedLines.contains("PASS demo later section"), "sections after a failure still run")
            check(!forced.output.contains("PASS HarnessDemo") && forcedLines.contains("FAILED HarnessDemo: 1 failed, 4 passed"), "a failed suite prints a failure summary instead of its PASS line")
            check(forcedLines.last?.hasSuffix(" demo second check") == true, "failure summary repeats each failure at the end of the output")

            let faults = try child(["HARNESS_DEMO_FAULTS": "1"])
            let faultLines = faults.output.split(separator: "\n").map(String.init)
            func failed(_ fragment: String) -> Bool { faultLines.contains { $0.hasPrefix("FAIL Tests/HarnessChecks.swift:") && $0.contains(fragment) } }
            check(faults.status == 1, "faulty suite exits non-zero")
            check(failed("demo wrong error (expected DemoError.intended, got DemoError"), "rejects(expecting:) fails on a different error and says which was expected")
            check(failed("demo nothing thrown (expected rejection, nothing was thrown)"), "rejects fails when nothing is thrown")
            check(failed("demo wrong message (expected an error mentioning 'expected words'"), "rejects(message:) fails when the message does not match")
            check(failed("demo throwing condition (threw DemoError"), "a condition that throws is a recorded failure, not a crash")
            check(failed("timed out after 0.05 s waiting for demo condition that never holds"), "an expired wait fails with a timeout message")
            check(failed("timed out after 0.05 s waiting for demo asynchronous condition that never holds") && failed("demo asynchronous nothing thrown (expected rejection"), "asynchronous waits and rejections report the same way")
            check(failed("demo precondition") && !faults.output.contains("demo unreachable check"), "require stops its own section")
            check(failed("section 'precondition' stopped: required: demo precondition") && failed("section 'thrown' stopped: DemoError"), "a stopped section is reported with its reason")
            check(faultLines.contains("PASS demo later section"), "sections after a stopped section still run")

            let waited = await waitUntil(timeout: 2, "immediate condition") { true }
            check(waited && Checks.failures.isEmpty, "a wait whose condition holds returns true and counts nothing")

            check(FileManager.default.fileExists(atPath: TestPaths.repoRoot.appendingPathComponent("scripts/test-suites.sh").path), "repository root is found without relying on the current directory")
            check(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path == TestPaths.repoRoot.resolvingSymlinksInPath().path && Checks.executable.path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: Checks.executable.path), "a suite runs from the repository root wherever it was started, and can still find its own executable")
            check(FileManager.default.fileExists(atPath: TestPaths.fixtures.appendingPathComponent("README.md").path) && FileManager.default.fileExists(atPath: TestPaths.resources.appendingPathComponent("LanguageProfiles.json").path), "fixtures and resources resolve from the repository root")
            let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent("TextTankHarnessArtifacts-" + UUID().uuidString)
            setenv("TEXTTANK_TEST_ARTIFACTS", artifacts.path, 1)
            var isDirectory: ObjCBool = false
            check(TestPaths.artifacts.path == artifacts.path && FileManager.default.fileExists(atPath: artifacts.path, isDirectory: &isDirectory) && isDirectory.boolValue, "artifact directory can be overridden and is created on demand")
            unsetenv("TEXTTANK_TEST_ARTIFACTS"); try? FileManager.default.removeItem(at: artifacts)
            check(TestPaths.artifacts.path == TestPaths.repoRoot.appendingPathComponent("build/tests").path, "artifact directory defaults to build/tests under the repository root")

            let before = ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]
            let inside: URL = try withIsolatedSupportDirectory("TextTankHarnessChecks") { url in
                check(String(cString: getenv("TEXTTANK_SUPPORT_DIRECTORY")) == url.path && FileManager.default.fileExists(atPath: url.path), "isolated support directory exists and is exported")
                return url
            }
            check(getenv("TEXTTANK_SUPPORT_DIRECTORY").map { String(cString: $0) } == before && !FileManager.default.fileExists(atPath: inside.path), "isolated support directory is removed and the previous value restored")
            Checks.summary { "PASS HarnessChecks: \(Checks.count) assertions; shared check harness" }
        }
    }
}
