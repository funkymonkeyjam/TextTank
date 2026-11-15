// SPDX-License-Identifier: GPL-3.0-or-later
// Shared check harness compiled into every Swift check executable.
//
// A failed check is recorded and the suite carries on, so one run reports every
// failure. Output is uniform: `PASS <label>` or `FAIL <file>:<line> <label>`.
// The process exits non-zero when anything failed; the scripts depend on that.
// `require` is for a precondition the following code cannot run without: it
// throws out of the enclosing `Checks.section`, and the next section still runs.
import Foundation

/// Thrown by `require` after the failure has been recorded.
struct CheckStop: Error, CustomStringConvertible { let description: String }

enum Checks {
    /// Behaviour checks that passed. Suites print this in their summary line.
    static var count = 0
    /// Fixture-integrity checks that passed; reported apart from behaviour checks.
    static var fixtureCount = 0
    static var failures: [String] = []
    /// `TEXTTANK_FORCE_FAIL=<label>` forces the check with exactly that label to
    /// fail. It exists to prove that a failure is reported and later checks still run.
    static let forcedFailure = ProcessInfo.processInfo.environment["TEXTTANK_FORCE_FAIL"]
    /// `TEXTTANK_SHOW_REJECTIONS=1` prints the error each `rejects` caught.
    static let showRejections = ProcessInfo.processInfo.environment["TEXTTANK_SHOW_REJECTIONS"] != nil
    private static var summary: (() -> String)?
    /// This executable, resolved before `enterRepositoryRoot` changes the working
    /// directory. Suites that re-run themselves as a child process launch this.
    static let executable: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

    /// Makes the repository root the working directory, so a check executable
    /// behaves the same wherever it is started from. Unbundled product code falls
    /// back to paths relative to the working directory (`Resources/...`).
    static func enterRepositoryRoot() {
        _ = executable
        FileManager.default.changeCurrentDirectoryPath(TestPaths.repoRoot.path)
    }

    static func location(_ file: StaticString, _ line: UInt) -> String {
        let path = "\(file)", root = TestPaths.repoRoot.path + "/"
        return (path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path) + ":\(line)"
    }
    static func pass(_ label: String) { count += 1; print("PASS \(label)"); fflush(stdout) }
    static func fail(_ label: String, file: StaticString, line: UInt) {
        let entry = "FAIL \(location(file, line)) \(label)"
        failures.append(entry); print(entry); fflush(stdout)
    }
    /// The line a suite prints when every check passed, for example
    /// `Checks.summary { "PASS FileChecks: \(Checks.count) assertions" }`.
    static func summary(_ text: @escaping () -> String) { summary = text }

    /// Runs one named group of checks. An error thrown out of it is recorded as
    /// a failure of that section only.
    static func section(_ name: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do { try body() } catch { fail("section '\(name)' stopped: \(describe(error))", file: file, line: line) }
    }
    static func section(_ name: String, isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do { try await body() } catch { fail("section '\(name)' stopped: \(describe(error))", file: file, line: line) }
    }

    /// Runs a whole suite, prints its summary or its failures, and exits with the matching status.
    static func run(_ name: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) -> Never {
        enterRepositoryRoot()
        do { try body() } catch { fail("\(name) stopped: \(describe(error))", file: file, line: line) }
        finish(name)
    }
    static func run(_ name: String, isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async -> Never {
        enterRepositoryRoot()
        do { try await body() } catch { fail("\(name) stopped: \(describe(error))", file: file, line: line) }
        finish(name)
    }
    static func finish(_ name: String) -> Never {
        if failures.isEmpty {
            if fixtureCount > 0 { print("FIXTURES \(name): \(fixtureCount) fixture integrity checks, not counted below") }
            print(summary?() ?? "PASS \(name): \(count) assertions")
            fflush(stdout); exit(0)
        }
        print("FAILED \(name): \(failures.count) failed, \(count) passed")
        for entry in failures { print("  " + entry) }
        fflush(stdout); exit(1)
    }
    static func describe(_ error: Error) -> String {
        if let stop = error as? CheckStop { return stop.description }
        return "\(type(of: error)): \(error.localizedDescription)"
    }
}

@discardableResult
func check(_ condition: @autoclosure () throws -> Bool, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
    do {
        let value = try condition()
        guard value, Checks.forcedFailure != label else { Checks.fail(label, file: file, line: line); return false }
        Checks.pass(label); return true
    } catch { Checks.fail("\(label) (threw \(Checks.describe(error)))", file: file, line: line); return false }
}

/// `check` for a condition that has to await. It has its own name so that the
/// synchronous form stays the one chosen inside asynchronous suites.
@discardableResult
func checkAsync(_ condition: @autoclosure () async throws -> Bool, _ label: String, isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
    do {
        let value = try await condition()
        guard value, Checks.forcedFailure != label else { Checks.fail(label, file: file, line: line); return false }
        Checks.pass(label); return true
    } catch { Checks.fail("\(label) (threw \(Checks.describe(error)))", file: file, line: line); return false }
}

/// A check about a fixture file itself, not about product behaviour. It is
/// reported as `FIXTURE <label>` and is not counted with the behaviour checks.
@discardableResult
func fixtureCheck(_ condition: @autoclosure () throws -> Bool, _ label: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
    do {
        guard try condition() else { Checks.fail("fixture integrity: \(label)", file: file, line: line); return false }
        Checks.fixtureCount += 1; print("FIXTURE \(label)"); fflush(stdout); return true
    } catch { Checks.fail("fixture integrity: \(label) (threw \(Checks.describe(error)))", file: file, line: line); return false }
}

/// For a precondition the following code cannot run without. A failure is
/// recorded and thrown; success is not counted as a check.
func require(_ condition: @autoclosure () throws -> Bool, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
    do { if try condition() { return } } catch { Checks.fail("\(label) (threw \(Checks.describe(error)))", file: file, line: line); throw CheckStop(description: "required: \(label)") }
    Checks.fail(label, file: file, line: line); throw CheckStop(description: "required: \(label)")
}
/// Unwraps a value the following code needs, without counting a check.
func requireValue<T>(_ value: T?, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { Checks.fail(label, file: file, line: line); throw CheckStop(description: "required: \(label)") }
    return value
}

private func judge(_ label: String, _ thrown: Error?, _ expectation: String?, _ matches: (Error) -> Bool, file: StaticString, line: UInt) -> Bool {
    guard let thrown else { Checks.fail("\(label) (expected rejection, nothing was thrown)", file: file, line: line); return false }
    if Checks.showRejections { print("  REJECTED \(label): \(Checks.describe(thrown))") }
    guard matches(thrown) else {
        Checks.fail("\(label) (expected \(expectation ?? "a matching error"), got \(Checks.describe(thrown)))", file: file, line: line); return false
    }
    guard Checks.forcedFailure != label else { Checks.fail(label, file: file, line: line); return false }
    Checks.pass(label); return true
}
private func attempt(_ work: () throws -> Void) -> Error? { do { try work(); return nil } catch { return error } }
private func attempt(isolation: isolated (any Actor)? = #isolation, _ work: () async throws -> Void) async -> Error? { do { try await work(); return nil } catch { return error } }

/// Passes when `work` throws. Prefer the `expecting:`, `where:` or `message:`
/// forms, which also state which error is the intended one.
@discardableResult
func rejects(_ label: String, file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> Void) -> Bool {
    judge(label, attempt(work), nil, { _ in true }, file: file, line: line)
}
@discardableResult
func rejects<E: Error & Equatable>(_ label: String, expecting expected: E, file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> Void) -> Bool {
    judge(label, attempt(work), "\(E.self).\(expected)", { ($0 as? E) == expected }, file: file, line: line)
}
@discardableResult
func rejects(_ label: String, where matches: (Error) -> Bool, file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> Void) -> Bool {
    judge(label, attempt(work), nil, matches, file: file, line: line)
}
@discardableResult
func rejects(_ label: String, message fragment: String, file: StaticString = #filePath, line: UInt = #line, _ work: () throws -> Void) -> Bool {
    judge(label, attempt(work), "an error mentioning '\(fragment)'", { $0.localizedDescription.contains(fragment) }, file: file, line: line)
}
@discardableResult
func rejects(_ label: String, isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void) async -> Bool {
    judge(label, await attempt(work), nil, { _ in true }, file: file, line: line)
}
@discardableResult
func rejects(_ label: String, where matches: (Error) -> Bool, isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void) async -> Bool {
    judge(label, await attempt(work), nil, matches, file: file, line: line)
}
@discardableResult
func rejects(_ label: String, message fragment: String, isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> Void) async -> Bool {
    judge(label, await attempt(work), "an error mentioning '\(fragment)'", { $0.localizedDescription.contains(fragment) }, file: file, line: line)
}

/// Polls `condition` on the current run loop until it holds. On expiry it
/// records `timed out ... waiting for <label>` instead of letting a later,
/// unrelated check fail. A successful wait is not counted as a check.
@discardableResult
func spinUntil(timeout: TimeInterval = 10, _ label: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () throws -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if (try? condition()) == true { return true }
        if Date() >= deadline { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    Checks.fail("timed out after \(timeout) s waiting for \(label)", file: file, line: line); return false
}
/// The same for asynchronous suites; it suspends instead of spinning the run loop.
@discardableResult
func waitUntil(timeout: TimeInterval = 10, _ label: String, isolation: isolated (any Actor)? = #isolation, file: StaticString = #filePath, line: UInt = #line, _ condition: () throws -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if (try? condition()) == true { return true }
        if Date() >= deadline { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    Checks.fail("timed out after \(timeout) s waiting for \(label)", file: file, line: line); return false
}

/// Locations that do not depend on the current directory. The scripts pass this
/// file to the compiler by absolute path, so `#filePath` is absolute.
enum TestPaths {
    static let repoRoot: URL = {
        if let override = ProcessInfo.processInfo.environment["TEXTTANK_REPO_ROOT"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }()
    static var fixtures: URL { repoRoot.appendingPathComponent("Tests/Fixtures", isDirectory: true) }
    static var resources: URL { repoRoot.appendingPathComponent("Resources", isDirectory: true) }
    /// Diagnostic output such as screenshots. `TEXTTANK_TEST_ARTIFACTS` overrides
    /// the default `build/tests`; the directory is created on demand.
    static var artifacts: URL {
        let url = ProcessInfo.processInfo.environment["TEXTTANK_TEST_ARTIFACTS"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? repoRoot.appendingPathComponent("build/tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A temporary directory used as `TEXTTANK_SUPPORT_DIRECTORY` for the life of
/// one suite. `restore()` puts the previous value back and removes the directory.
final class IsolatedSupportDirectory {
    let url: URL
    private let previous: String?
    init(_ name: String) throws {
        previous = ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        setenv("TEXTTANK_SUPPORT_DIRECTORY", url.path, 1)
    }
    func restore() {
        if let previous { setenv("TEXTTANK_SUPPORT_DIRECTORY", previous, 1) } else { unsetenv("TEXTTANK_SUPPORT_DIRECTORY") }
        try? FileManager.default.removeItem(at: url)
    }
}
func withIsolatedSupportDirectory<T>(_ name: String, _ body: (URL) throws -> T) throws -> T {
    let support = try IsolatedSupportDirectory(name)
    defer { support.restore() }
    return try body(support.url)
}
