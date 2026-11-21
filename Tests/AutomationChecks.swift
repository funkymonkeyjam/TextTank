@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main struct AutomationChecks {
    static func progressReentry(_ mode: String) throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(70) }
        let control = AutomationRunControl(), done = DispatchSemaphore(value: 0)
        if mode == "release" {
            installProgressCapture(control, done)
            control.onProgress = nil
        } else if mode == "invoke" {
            control.onProgress = { _, _ in
                control.onProgress = nil
                control.cancel()
                done.signal()
            }
            try control.checkpoint(completed: 0, total: 1)
        } else {
            throw ProgressReentryFailure.unknownMode
        }
        check(
            done.wait(timeout: .now() + 1) == .success,
            "progress callback reentry completes outside the control lock")
        rejects("progress callback reentry reaches the actual cancellation state", message: "Automation cancelled") {
            try control.checkCancellation()
        }
    }
    static func installProgressCapture(_ control: AutomationRunControl, _ done: DispatchSemaphore) {
        let token = AutomationProgressCapture(control: control, done: done)
        control.onProgress = { _, _ in withExtendedLifetime(token) {} }
    }
    static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--progress-reentry" {
            Checks.run("AutomationProgressReentryChecks") {
                try progressReentry(CommandLine.arguments[2])
                Checks.summary { "PASS AutomationProgressReentryChecks: \(Checks.count) assertions" }
            }
        }
        Checks.run("AutomationChecks") {
            for mode in ["release", "invoke"] {
                let child = Process(), output = Pipe()
                child.executableURL = Checks.executable
                child.arguments = ["--progress-reentry", mode]
                child.standardOutput = output
                child.standardError = output
                try child.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                check(
                    child.terminationReason == .exit && child.terminationStatus == 0
                        && text.contains("PASS AutomationProgressReentryChecks: 2 assertions"),
                    "F316 actual progress callback \(mode) can reenter its control without deadlock")
            }
            let concurrentControl = AutomationRunControl(), concurrentObservations = AutomationProgressObservations()
            concurrentControl.onProgress = { step, _ in concurrentObservations.record(step) }
            DispatchQueue.concurrentPerform(iterations: 100) { step in
                _ = try? concurrentControl.checkpoint(completed: step, total: 100)
            }
            check(
                concurrentObservations.completed.sorted() == Array(0..<100),
                "F316 actual concurrent progress callbacks retain every completed checkpoint")
            var definition = AutomationDefinition.example
            // This older generic bullet-only configuration intentionally keeps unmarked rows.
            definition.steps = [.init(kind: .removeListMarkers), .init(kind: .removeBlankLines)]
            let input =
                "• 2 eggs\r\n\r\n- ½ cup flour\r\n* 1½ cups café\r\n1/2 tsp salt\r\n2–3 cloves garlic\r\n2 eggs\r\n2 eggs\r\n1. 5 cups\r\n"
            let expected =
                "2 eggs\r\n½ cup flour\r\n1½ cups café\r\n1/2 tsp salt\r\n2–3 cloves garlic\r\n2 eggs\r\n2 eggs\r\n1. 5 cups\r\n"
            check(
                try definition.transform(input) == expected,
                "quantities fractions ranges names duplicates CRLF preserved")
            let id = definition.id
            definition.shortcut = "r"
            definition.destinationID = "selected-list-identifier"
            var library = AutomationLibrary(workflows: [definition])
            library.workflows[0].name = "Scott chooses this name"
            let decoded = try AutomationLibrary.decode(library.encoded())
            check(
                decoded.workflows[0].id == id && decoded.workflows[0].shortcut == "r"
                    && decoded.workflows[0].steps == definition.steps
                    && decoded.workflows[0].destinationID == "selected-list-identifier",
                "rename roundtrip preserves ID parameters shortcut")
            check(try decoded.workflows[0].transform(input) == expected, "name cannot select behavior")
            definition.steps = [.init(kind: .deduplicateLines)]
            check(try definition.transform("a\nb\na\n") == "a\nb\n", "explicit dedupe stable")
            definition.steps = [.init(kind: .sortLines)]
            check(try definition.transform("z\na") == "a\nz", "sort retains missing final EOL")
            check(try definition.transform("z\ra\r") == "a\rz\r", "CR retained")
            definition.steps = [.init(kind: .replaceLiteral, find: "$()", replacement: "½")]
            check(try definition.transform("$() eggs") == "½ eggs", "metacharacters are literal data")
            definition.steps = [.init(kind: .removeListMarkers)]
            check(
                try definition.transform("• x\r\n- y\nz\r") == "x\r\ny\nz\r", "marker removal preserves mixed exact EOL"
            )
            definition.steps = [.init(kind: .removeBlankLines)]
            rejects("mixed EOL not silently normalized") { _ = try definition.transform("a\r\nb\n") }
            definition.version = 2
            rejects("unknown version", message: "Unsupported workflow version") { try definition.validate() }
            definition.version = 1
            definition.steps = [.init(kind: .replaceLiteral, find: "", replacement: "x")]
            rejects("empty literal find") { try definition.validate() }
            var invalid = library
            invalid.workflows.append(invalid.workflows[0])
            rejects("duplicate stable IDs", message: "identifiers must be unique") { try invalid.validate() }
            invalid.workflows[1].id = UUID()
            rejects("duplicate shortcut") { try invalid.validate() }
            invalid = library
            invalid.version = 2
            rejects("unknown library schema", message: "Unsupported library version") {
                _ = try AutomationLibrary.decode(JSONEncoder().encode(invalid))
            }
            var json = String(data: try library.encoded(), encoding: .utf8)!
            json = json.replacingOccurrences(of: "removeListMarkers", with: "executeShell")
            rejects("unknown executable step", where: { ($0 as? JSONInputFailure)?.underlying is DecodingError }) {
                _ = try AutomationLibrary.decode(Data(json.utf8))
            }
            var sameNames = library
            var second = sameNames.workflows[0]
            second.id = UUID()
            second.shortcut = nil
            sameNames.workflows.append(second)
            check(
                try AutomationLibrary.decode(sameNames.encoded()).workflows.count == 2,
                "same names preserve distinct identities")
            var fileExport = definition
            fileExport.steps = []
            fileExport.input = .file
            fileExport.output = .reminders
            let fileLibrary = try AutomationLibrary.decode(AutomationLibrary(workflows: [fileExport]).encoded())
            check(
                fileLibrary.workflows[0].input == .file && fileLibrary.workflows[0].output == .reminders,
                "file and reminders definitions roundtrip without execution")
            let fixtures = TestPaths.fixtures
            let recipe = try String(
                contentsOf: fixtures.appendingPathComponent("recipe-markdown-input.txt"), encoding: .utf8)
            let cleaned = try String(
                contentsOf: fixtures.appendingPathComponent("recipe-cleaned-expected.txt"), encoding: .utf8)
            let actual = try AutomationDefinition.example.transform(recipe)
            fixtureCheck(
                recipe.split(separator: "\n").filter { $0.hasPrefix("- ") }.count == 28,
                "independently count source28 ingredient rows")
            fixtureCheck(cleaned.split(separator: "\n").count == 28, "expected28 ingredient rows")
            check(actual == cleaned, "exact user Markdown recipe cleanup: \(actual.debugDescription)")
            check(
                AutomationDefinition.example.input == .document && AutomationDefinition.example.output == .editor,
                "cleanup targets current editor")
            check(
                AutomationDefinition.example.previewBeforeApply == false
                    && AutomationDefinition.example.pinToToolbar == true, "direct cleanup favorite defaults")
            check(
                AutomationDefinition.remindersExample.output == .reminders
                    && AutomationDefinition.remindersExample.id != AutomationDefinition.example.id,
                "separate reusable reminder output")
            let noNewKeys = Data(
                "{\"version\":1,\"workflows\":[{\"version\":1,\"id\":\"A931733F-310A-4EBF-9C48-38C59202D586\",\"name\":\"Old name\",\"input\":\"selection\",\"steps\":[],\"output\":\"editor\"}]}"
                    .utf8)
            let legacy = try AutomationLibrary.decode(noNewKeys).workflows[0]
            check(
                legacy.previewBeforeApply == nil && legacy.pinToToolbar == nil,
                "old libraries remain decodable with flags absent")
            var format = AutomationDefinition.example
            format.steps = [.init(kind: .removeMarkdownFormatting)]
            check(
                try format.transform("2 * 3 * 4, snake_case, **salt** and *pepper*")
                    == "2 * 3 * 4, snake_case, salt and pepper",
                "formatting preserves multiplication and intraword underscores")
            check(
                try format.transform("[salt](https://example.invalid/a_(b)) (optional)") == "salt (optional)",
                "balanced URL parentheses do not eat ingredient options")
            check(try format.transform("[salt](broken") == "[salt](broken", "malformed links retained")
            check(try format.transform(#"\*literal\*"#) == "*literal*", "escaped stars remain literal")
            var notes = AutomationDefinition.example
            notes.steps = [.init(kind: .removeNoteReferences)]
            check(
                try notes.transform("1 cup flour (optional, Note 2) (finely sifted)")
                    == "1 cup flour (optional) (finely sifted)",
                "remove explicit note while preserving parenthetical options")
            check(
                try notes.transform("1 notebook (optional) — 2 eggs") == "1 notebook (optional) — 2 eggs",
                "ordinary note-like words unchanged")
            var marks = AutomationDefinition.example
            marks.steps = [.init(kind: .removeCheckboxMarkers)]
            check(
                try marks.transform("▢2 eggs\n☐salt to taste\n[x] pepper\n[ ] ½ cup flour")
                    == "2 eggs\nsalt to taste\npepper\n½ cup flour",
                "checkbox glyphs and ASCII boxes independent of numeric content")
            var filtered = AutomationDefinition.example
            filtered.steps = [.init(kind: .keepMarkedListRows)]
            check(
                try filtered.transform("Heading:\n\n▢salt to taste\n▢2 eggs\n") == "▢salt to taste\n▢2 eggs\n",
                "explicit marked-row filter removes structural headers")
            check(
                try filtered.transform("salt to taste\n2 eggs\n½ cup flour") == "salt to taste\n2 eggs\n½ cup flour",
                "unmarked plain lists do not require checkboxes")
            rejects("unmarked continuation never silently lost") {
                _ = try filtered.transform("• 2 eggs\nunmarked continuation\n")
            }
            rejects("optional ingredient cannot be guessed as heading") {
                _ = try filtered.transform("Salt (optional)\n▢2 eggs\n")
            }
            check(try filtered.transform("# Any heading\n▢salt\n") == "▢salt\n", "explicit Markdown heading accepted")
            let plain = try String(
                contentsOf: fixtures.appendingPathComponent("recipe-plain-copy-derived.txt"), encoding: .utf8)
            // G380: the derived plain copy has its own stored expected bytes.
            let plainExpected = try String(
                contentsOf: fixtures.appendingPathComponent("recipe-plain-copy-expected.txt"), encoding: .utf8)
            fixtureCheck(
                plainExpected != cleaned
                    && plainExpected.split(separator: "\n").count == cleaned.split(separator: "\n").count,
                "plain-copy expected fixture differs from the Markdown expected fixture only within a row")
            check(
                try AutomationDefinition.example.transform(plain) == plainExpected,
                "configured optional heading removed from derived copy")
            let explicit = plain.replacingOccurrences(of: "Garnish (optional)", with: "# Garnish (optional)")
            check(
                try AutomationDefinition.example.transform(explicit) == plainExpected,
                "plain copied28 rows retain quantities after explicit heading markup")
            let native = try String(
                contentsOf: fixtures.appendingPathComponent("recipe-browser-plain-input.txt"), encoding: .utf8)
            let nativeExpected = try String(
                contentsOf: fixtures.appendingPathComponent("recipe-browser-cleaned-expected.txt"), encoding: .utf8)
            check(
                try AutomationDefinition.example.transform(native) == nativeExpected,
                "observed native browser copy cleans28 exactly: \(try AutomationDefinition.example.transform(native).debugDescription)"
            )
            fixtureCheck(nativeExpected.split(separator: "\n").count == 28, "native expected28 ingredient rows")
            rejects("unknown unmarked ingredient aborts entire transform") {
                _ = try AutomationDefinition.example.transform(native + "salt to taste\n")
            }
            var matching = AutomationDefinition.example
            matching.steps = [.init(kind: .clearLinesMatching, find: "Ingredients")]
            check(
                try matching.transform("Ingredients\n2 cups Ingredients mix\n") == "\n2 cups Ingredients mix\n",
                "regex filter requires full-line match")
            matching.steps = [.init(kind: .clearLinesMatching, find: "[")]
            rejects("invalid heading regex") { try matching.validate() }
            matching.steps = [.init(kind: .clearLinesMatching, find: "", replacement: "x")]
            rejects("invalid heading parameters") { try matching.validate() }
            var renamed = AutomationDefinition.example
            renamed.name = "My chosen label"
            check(
                try renamed.transform(native) == nativeExpected, "configured recipe behavior independent of user name")
            matching.steps = [.init(kind: .clearLinesMatching, find: "(a+)+$")]
            let regexStarted = ProcessInfo.processInfo.systemUptime
            rejects("pathological regex interrupted before applying", message: "exceeded its time limit") {
                _ = try matching.transform(String(repeating: "a", count: 32) + "!")
            }
            check(
                ProcessInfo.processInfo.systemUptime - regexStarted < 10,
                "regex timeout returns well inside the hang guard")
            var prompted = AutomationDefinition.example
            prompted.steps = [
                .init(
                    kind: .replaceLiteral, find: "saved", replacement: "default", askForFind: true,
                    askForReplacement: true)
            ]
            var labels: [String] = []
            let resolved = try prompted.resolvingParameters { index, label, value in
                labels.append(label)
                return label == "Text to match" ? "½" : "$()"
            }
            check(
                try resolved?.transform("½ cup") == "$() cup" && labels == ["Text to match", "Replace with"],
                "runtime parameters are ordered literal data")
            check(prompted.steps[0].find == "saved", "runtime parameters do not mutate saved defaults")
            check(
                try prompted.resolvingParameters { _, _, _ in nil } == nil,
                "parameter cancellation returns no runnable definition")
            rejects("runtime empty find rejected") {
                _ = try prompted.resolvingParameters { _, label, _ in label == "Text to match" ? "" : "value" }
            }
            prompted.steps = [.init(kind: .removeBlankLines, askForFind: true)]
            rejects("irrelevant parameter prompt rejected") { try prompted.validate() }
            let control = AutomationRunControl()
            control.cancel()
            rejects("cancelled transform cannot produce output", message: "Automation cancelled") {
                _ = try AutomationDefinition.example.transform(native, control: control)
            }
            let progress = AutomationRunControl()
            let progressObservations = AutomationProgressObservations()
            progress.onProgress = { step, _ in progressObservations.record(step) }
            _ = try AutomationDefinition.example.transform(native, control: progress)
            check(
                progressObservations.completed.first == 0
                    && progressObservations.completed.last == AutomationDefinition.example.steps.count,
                "progress reaches all steps")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "AutomationFiles-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let utf8 = root.appendingPathComponent("sample.txt")
            try Data("café\u{0}👩🏽‍💻".utf8).write(to: utf8)
            check(try AutomationFileInput.read(utf8) == "café\u{0}👩🏽‍💻", "file input preserves Unicode and NUL")
            rejects("file bound") { _ = try AutomationFileInput.read(utf8, limit: 2) }
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: utf8)
            // F72: the error is the system's own reason, and a size message names the limit in force.
            rejects("symlink input is refused as a symbolic link", where: { $0.posixCode == .ELOOP }) {
                _ = try AutomationFileInput.read(link)
            }
            rejects("F72 a missing input file is reported as missing", where: { $0.posixCode == .ENOENT }) {
                _ = try AutomationFileInput.read(root.appendingPathComponent("absent.txt"))
            }
            rejects("F72 an oversized input names the limit that applies", message: "larger than the 2 bytes limit") {
                _ = try AutomationFileInput.read(utf8, limit: 2)
            }
            rejects("F72 a folder is refused as not a regular file", message: "must be a regular file") {
                _ = try AutomationFileInput.readData(root, limit: 1_048_576)
            }
            check(
                AutomationFileInput.describe(limit: 1_048_576) == "1 MiB"
                    && AutomationFileInput.describe(limit: 32 * 1024 * 1024) == "32 MiB"
                    && AutomationFileInput.describe(limit: 65536) == "64 KiB"
                    && AutomationFileInput.describe(limit: 1500) == "1500 bytes",
                "F72 a limit is described in the unit it was given in")
            let fifo = root.appendingPathComponent("fifo")
            try require(mkfifo(fifo.path, 0o600) == 0, "fixture: FIFO created")
            let started = ProcessInfo.processInfo.systemUptime
            rejects("FIFO input rejects without blocking", message: "must be a regular file") {
                _ = try AutomationFileInput.read(fifo)
            }
            check(
                ProcessInfo.processInfo.systemUptime - started < 10, "FIFO rejection returns well inside the hang guard"
            )
            // Friendly literal rules must never reinterpret typed punctuation as regex.
            let literalKinds: [AutomationDefinition.Step.Kind] = [
                .clearLinesEqualTo, .clearLinesContaining, .clearLinesStartingWith
            ]
            for kind in literalKinds {
                var rule = AutomationDefinition.example
                rule.steps = [.init(kind: kind, find: "Note")]
                let source = "Note\r\n Note\r\nnote\r\nNote: optional\r\n2 eggs\r\n2 eggs\r\n½–¾ cup café\r\n"
                let expected: String
                switch kind {
                case .clearLinesEqualTo:
                    expected = "\r\n Note\r\nnote\r\nNote: optional\r\n2 eggs\r\n2 eggs\r\n½–¾ cup café\r\n"
                case .clearLinesContaining: expected = "\r\n\r\nnote\r\n\r\n2 eggs\r\n2 eggs\r\n½–¾ cup café\r\n"
                default: expected = "\r\n Note\r\nnote\r\n\r\n2 eggs\r\n2 eggs\r\n½–¾ cup café\r\n"
                }
                check(
                    try rule.transform(source) == expected,
                    "\(kind.rawValue) case-sensitive literal rows preserve CRLF quantities and duplicates")
                rule.steps = [.init(kind: kind, find: "[x].*")]
                let punctuationInput: String
                switch kind {
                case .clearLinesEqualTo: punctuationInput = "[x].*\n[x] pepper\n2 eggs\n"
                case .clearLinesContaining: punctuationInput = "before [x].* after\n[x] pepper\n2 eggs\n"
                default: punctuationInput = "[x].* annotation\n[x] pepper\n2 eggs\n"
                }
                check(
                    try rule.transform(punctuationInput) == "\n[x] pepper\n2 eggs\n",
                    "\(kind.rawValue) brackets dots and stars remain literal data")
                rule.steps = [.init(kind: kind, find: "drop")]
                check(
                    try rule.transform("drop\r\nkeep\nkeep\rdrop") == "\r\nkeep\nkeep\r",
                    "\(kind.rawValue) clears matching content but retains exact mixed separators")
                check(try rule.transform("drop") == "", "\(kind.rawValue) removes final unterminated matching row")
                check(try rule.transform("keep") == "keep", "\(kind.rawValue) preserves missing final newline")
                rule.steps = [.init(kind: kind, find: "")]
                rejects("\(kind.rawValue) rejects empty search text") { try rule.validate() }
                rule.steps = [.init(kind: kind)]
                rejects("\(kind.rawValue) requires search text") { try rule.validate() }
                rule.steps = [.init(kind: kind, find: "x", replacement: "")]
                rejects("\(kind.rawValue) rejects replacement parameter") { try rule.validate() }
                rule.steps = [.init(kind: kind, find: "x", askForReplacement: true)]
                rejects("\(kind.rawValue) rejects replacement prompt") { try rule.validate() }
                rule.steps = [.init(kind: kind, find: "saved", askForFind: true)]
                let promptedRule = try rule.resolvingParameters { _, label, value in
                    check(
                        label == "Text to match" && value == "saved",
                        "\(kind.rawValue) prompts with saved literal default")
                    return "drop"
                }
                check(
                    try promptedRule?.transform("drop\nkeep\n") == "\nkeep\n" && rule.steps[0].find == "saved",
                    "\(kind.rawValue) runtime text changes only invocation")
                check(
                    try rule.resolvingParameters { _, _, _ in nil } == nil,
                    "\(kind.rawValue) prompt cancellation yields no runnable rule")
            }
            var trimming = AutomationDefinition.example
            trimming.steps = [.init(kind: .trimWhitespace)]
            check(
                try trimming.transform(" \t½ cup café \t\r\n\t2 eggs\t\n \t \r👩🏽‍💻  \r\n")
                    == "½ cup café\r\n2 eggs\n\r👩🏽‍💻\r\n",
                "trim removes only line-edge whitespace and preserves mixed separators and Unicode")
            check(
                try trimming.transform(" 2  eggs\u{0} \t") == "2  eggs\u{0}",
                "trim preserves interior spacing and NUL content")
            check(
                try trimming.transform("") == "" && trimming.transform("\r\n\n\r") == "\r\n\n\r",
                "trim preserves empty input and empty-line boundaries")
            trimming.steps = [.init(kind: .trimWhitespace, find: "x")]
            rejects("trim rejects unexpected find") { try trimming.validate() }
            trimming.steps = [.init(kind: .trimWhitespace, replacement: "x")]
            rejects("trim rejects unexpected replacement") { try trimming.validate() }
            trimming.steps = [.init(kind: .trimWhitespace, askForFind: true)]
            rejects("trim rejects meaningless runtime find prompt") { try trimming.validate() }
            var friendly = AutomationDefinition.example
            friendly.steps = [
                .init(kind: .clearLinesStartingWith, find: "Serves:"), .init(kind: .trimWhitespace),
                .init(kind: .clearLinesEqualTo, find: "Ingredients"),
                .init(kind: .clearLinesContaining, find: "(advertisement)"), .init(kind: .removeBlankLines)
            ]
            let friendlyLibrary = AutomationLibrary(workflows: [friendly])
            check(
                try AutomationLibrary.decode(friendlyLibrary.encoded()) == friendlyLibrary,
                "all friendly rules persist without changing schema or stable IDs")
            check(
                try friendly.transform(
                    "Serves: 4\r\n Ingredients \r\n ½ cup flour \r\n2 eggs\r\n2 eggs\r\ninline (advertisement)\r\n")
                    == "½ cup flour\r\n2 eggs\r\n2 eggs\r\n",
                "ordered friendly-rule recipe pipeline preserves ingredient quantities and duplicates")
            // Sample testing is a pure, bounded transform, even for external-output definitions.
            var sampleOnly = friendly
            sampleOnly.input = .file
            sampleOnly.output = .reminders
            check(
                try sampleOnly.testSample("Serves: 4\n Ingredients \n ½ cup flour \n2 eggs\n2 eggs\n")
                    == "½ cup flour\n2 eggs\n2 eggs\n",
                "sample test uses supplied text only regardless file input or reminder output")
            var emptyRules = AutomationDefinition.example
            emptyRules.steps = []
            check(
                try emptyRules.testSample(String(repeating: "a", count: 65536)).utf8.count == 65536,
                "sample accepts exact 64 KiB boundary")
            rejects("sample rejects oversized source before transformation") {
                _ = try emptyRules.testSample(String(repeating: "a", count: 65537))
            }
            let cancelledSample = AutomationRunControl()
            cancelledSample.cancel()
            rejects("sample cancellation applies even with zero rules", message: "Automation cancelled") {
                _ = try emptyRules.testSample("preserved", control: cancelledSample)
            }
            var expanding = AutomationDefinition.example
            expanding.steps = Array(repeating: .init(kind: .replaceLiteral, find: "a", replacement: "aa"), count: 100)
            let expansionStarted = ProcessInfo.processInfo.systemUptime
            rejects("sample repeated expansion fails before an oversized intermediate", message: "sample-result limit")
            { _ = try expanding.testSample(String(repeating: "a", count: 65536)) }
            check(
                ProcessInfo.processInfo.systemUptime - expansionStarted < 10,
                "sample exponential expansion rejects well inside the hang guard")
            expanding.steps = [
                .init(kind: .replaceLiteral, find: "a", replacement: String(repeating: "b", count: 1048577))
            ]
            rejects("sample oversized replacement rejected before allocation") { _ = try expanding.testSample("a") }
            expanding.steps = [.init(kind: .replaceLiteral, find: "a", replacement: String(repeating: "b", count: 100))]
            rejects("sample single-step multiplicative expansion preflight") {
                _ = try expanding.testSample(String(repeating: "a", count: 65536))
            }
            expanding.steps = [.init(kind: .replaceLiteral, find: "a", replacement: "aa")]
            check(try expanding.testSample("a") == "aa", "sample permits ordinary growing replacement")
            let cancelDuring = AutomationRunControl()
            cancelDuring.onProgress = { completed, total in if completed == total { cancelDuring.cancel() } }
            rejects("sample observes cancellation between completed steps", message: "Automation cancelled") {
                _ = try expanding.testSample("a", control: cancelDuring)
            }
            let portable = AutomationRuleSet(
                name: "Literal heading cleanup",
                steps: [
                    .init(kind: .clearLinesEqualTo, find: "Ingredients", askForFind: true),
                    .init(kind: .removeBlankLines)
                ])
            let portableData = try portable.encoded()
            let portableDecoded = try AutomationRuleSet.decode(portableData)
            check(
                portableDecoded.name == portable.name && portableDecoded.steps == portable.steps,
                "portable rule file roundtrip preserves ordered rules and parameter flags")
            let portableObject = try JSONSerialization.jsonObject(with: portableData) as! [String: Any]
            check(
                Set(portableObject.keys) == Set(["version", "name", "steps"]),
                "portable rules exclude workflow triggers destinations and external outputs")
            var futurePortable = portable
            futurePortable.version = 2
            rejects("future portable version rejects encoding", message: "Unsupported rule-set version") {
                _ = try futurePortable.encoded()
            }
            rejects("future portable version rejects loading", message: "Unsupported rule-set version") {
                _ = try AutomationRuleSet.decode(JSONEncoder().encode(futurePortable))
            }
            rejects(
                "malformed portable file rejected", where: { ($0 as? JSONInputFailure)?.underlying is DecodingError }
            ) {
                _ = try AutomationRuleSet.decode(Data("{bad".utf8))
            }
            rejects("oversized portable file rejected before decode") {
                _ = try AutomationRuleSet.decode(Data(repeating: 32, count: 1048577))
            }
            var invalidPortable = portable
            invalidPortable.steps = [.init(kind: .clearLinesEqualTo, find: "")]
            rejects("invalid portable rule rejects loading") {
                _ = try AutomationRuleSet.decode(JSONEncoder().encode(invalidPortable))
            }
            invalidPortable.name = ""
            rejects("invalid portable name rejects export") { _ = try invalidPortable.encoded() }
            var bounded = AutomationDefinition.example
            bounded.steps = [
                .init(
                    kind: .replaceLiteral, find: "x",
                    replacement: String(repeating: "y", count: AutomationDefinition.maximumTransformBytes + 1))
            ]
            rejects("production replacement rejects oversized output before appending") {
                _ = try bounded.transform("x")
            }
            bounded.steps = []
            rejects("production no-step input remains bounded") {
                _ = try bounded.transform(String(repeating: "x", count: AutomationDefinition.maximumTransformBytes + 1))
            }
            bounded.steps = [.init(kind: .replaceLiteral, find: "x", replacement: "yy")]
            check(
                try bounded.transform("x café x") == "yy café yy",
                "bounded replacement preserves unmatched Unicode and order")
            let cancelledProduction = AutomationRunControl()
            cancelledProduction.cancel()
            rejects("production replacement respects cancellation", message: "Automation cancelled") {
                _ = try bounded.transform("x", control: cancelledProduction)
            }
            rejects("oversized automation configuration rejected at decode", message: "exceeds 32 MiB") {
                _ = try AutomationLibrary.decode(Data(repeating: 32, count: AutomationLibrary.maximumBytes + 1))
            }
            bounded.steps = [.init(kind: .removeMarkdownFormatting)]
            let malformed = String(repeating: "[", count: 20000)
            let malformedStart = ProcessInfo.processInfo.systemUptime
            check(try bounded.transform(malformed) == malformed, "malformed nested brackets remain literal data")
            let balanced = malformed + String(repeating: "]", count: 20000)
            check(try bounded.transform(balanced) == balanced, "balanced nonlink brackets remain literal data")
            check(
                ProcessInfo.processInfo.systemUptime - malformedStart < 10,
                "nested nonlink scan completes well inside the hang guard")
            let activeCancellation = AutomationRunControl()
            let activeText = String(repeating: "[", count: 2 * 1024 * 1024)
            // Cancel from the checkpoint that precedes the only step: the request is then
            // pending while that step runs, with no timer and no dependence on speed.
            let cancellationObservations = AutomationProgressObservations()
            activeCancellation.onProgress = { completed, _ in
                if completed == 0 {
                    activeCancellation.cancel()
                    cancellationObservations.markCancelled()
                }
            }
            rejects("active Markdown transformation observes cancellation", message: "Automation cancelled") {
                _ = try bounded.transform(activeText, control: activeCancellation)
            }
            check(
                cancellationObservations.cancelledAtCheckpoint,
                "active transformation was cancelled from its own progress checkpoint")
            let escapedMalformed = "[" + String(repeating: "\\x", count: 20000)
            check(
                try bounded.transform(escapedMalformed) == escapedMalformed,
                "odd-offset escaped malformed link preserves bytes with threshold checkpoints")
            // Audit package 14. Each group names the finding it guards.
            var rule = AutomationDefinition.example
            // F55: the regex budget is charged for regex work, not for the number of lines.
            rule.steps = [
                .init(kind: .clearLinesMatching, find: AutomationDefinition.recipeHeadingPattern),
                .init(kind: .clearLinesMatching, find: AutomationDefinition.colonLabelPattern)
            ]
            // The 100 ms cumulative production budget includes VM scheduling delays.
            // Keep the full timing check on a dedicated Mac and exercise both patterns on hosted CI.
            let sharedRunner = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
            let lineCount = sharedRunner ? 20_000 : 200_000
            if sharedRunner { print("SKIP F55 200,000-line timing case on a shared runner; testing 20,000 lines") }
            let manyLines = String(repeating: "2 cups flour, sifted\n", count: lineCount)
            check(
                try rule.transform(manyLines).utf8.elementsEqual(manyLines.utf8),
                "F55 two heading patterns leave \(lineCount) short non-matching lines unchanged without a false time limit")
            rule.steps = [.init(kind: .clearLinesMatching, find: "(a+)+$")]
            let slowLines = String(repeating: "aaaaaaaaaaaaaaaaaaaaaaaa!\n", count: 5000)
            let slowLinesStarted = ProcessInfo.processInfo.systemUptime
            rejects("F55 a pathological pattern over thousands of lines is still rejected", message: "time limit") {
                _ = try rule.transform(slowLines)
            }
            check(
                ProcessInfo.processInfo.systemUptime - slowLinesStarted < 10,
                "F55 the pathological many-line rejection returns well inside the hang guard")
            // F58 and F110: Keep marked list rows is linear and observes cancellation.
            rule.steps = [.init(kind: .keepMarkedListRows)]
            let markedRows = (0..<100_000).map { "- item \($0)\n" }.joined()
            let markedStarted = ProcessInfo.processInfo.systemUptime
            check(
                try rule.transform(markedRows).utf8.elementsEqual(markedRows.utf8),
                "F58 100,000 distinct marked rows are kept exactly")
            check(
                ProcessInfo.processInfo.systemUptime - markedStarted < 10,
                "F58 Keep marked list rows over 100,000 rows is not quadratic")
            rejects("F58 the first unmarked row is still reported by line number", message: "Line 3 has no list marker")
            { _ = try rule.transform("- a\n\nplain\n- b\nplain again\n") }
            let markedCancel = AutomationRunControl()
            markedCancel.onProgress = { completed, _ in if completed == 0 { markedCancel.cancel() } }
            // Without a cancellation check inside the step the unmarked last row would be reported instead.
            rejects("F110 Keep marked list rows observes a pending cancellation", message: "Automation cancelled") {
                _ = try rule.transform(markedRows + "unmarked last row\n", control: markedCancel)
            }
            // F62: note removal tidies only the lines it changed.
            rule.steps = [.init(kind: .removeNoteReferences)]
            check(
                try rule.transform("    indented code\n\tTabbed") == "    indented code\n\tTabbed",
                "F62 note removal leaves indentation alone on lines without a note")
            check(
                try rule.transform("a  \r\nb (Note 1)\r\n") == "a  \r\nb\r\n",
                "F62 note removal trims only the line whose note was removed")
            check(
                try rule.transform("1/2 tsp herbs (Note 4)") == "1/2 tsp herbs",
                "F62 the gap left by a removed note is still tidied")
            check(
                try AutomationDefinition.example.transform("- 2 eggs  \n") == "2 eggs\n",
                "F62 the built-in recipe cleanup still trims line edges")
            // F63: a whole-line match is anchored, in validation and in the run alike.
            rule.steps = [.init(kind: .clearLinesMatching, find: "Cups|Cups Metric")]
            check(
                try rule.transform("Cups Metric\n2 Cups Metric flour\n") == "\n2 Cups Metric flour\n",
                "F63 an alternation clears a line its longer branch matches entirely")
            rule.steps = [.init(kind: .clearLinesMatching, find: "(?i)cups")]
            check(try rule.transform("CUPS") == "", "F63 inline flags still apply inside the anchored pattern")
            rule.steps = [.init(kind: .clearLinesMatching, find: "(?x) Cups # label")]
            check(
                try rule.transform("Cups\nCups x") == "\nCups x",
                "F63 a free-spacing pattern ending in a comment still validates and clears its line")
            rule.steps = [.init(kind: .clearLinesMatching, find: #"\QCups"#)]
            check(
                try rule.transform("Cups\nCups x") == "\nCups x",
                "F63 an unterminated quoted literal still validates and clears its line")
            rule.steps = [.init(kind: .clearLinesMatching, find: AutomationDefinition.colonLabelPattern)]
            check(
                try rule.transform("Sauce:\nSauce: 2 tbsp") == "\nSauce: 2 tbsp",
                "F63 the colon-label pattern clears a label and keeps a line with text after the colon")
            // G345: literal rules and dedupe compare bytes, as Find and Remove Duplicate Lines do.
            rule.steps = [.init(kind: .deduplicateLines)]
            check(
                try rule.transform("\u{E9}\ne\u{301}\n").utf8.elementsEqual("\u{E9}\ne\u{301}\n".utf8),
                "G345 dedupe keeps precomposed and decomposed spellings as different rows")
            rule.steps = [.init(kind: .clearLinesContaining, find: "\u{1F469}")]
            check(
                try rule.transform("\u{1F469}\u{200D}\u{1F467}") == "",
                "G345 contains finds a scalar inside a joined emoji sequence")
            rule.steps = [.init(kind: .clearLinesContaining, find: "e")]
            check(try rule.transform("cafe\u{301}") == "", "G345 contains finds the base letter of a decomposed accent")
            rule.steps = [.init(kind: .clearLinesStartingWith, find: "e")]
            check(
                try rule.transform("e\u{301}x") == "", "G345 starts-with matches the base letter of a decomposed accent"
            )
            rule.steps = [.init(kind: .clearLinesEqualTo, find: "\u{E9}")]
            check(
                try rule.transform("e\u{301}").utf8.elementsEqual("e\u{301}".utf8),
                "G345 equal-to does not treat a decomposed spelling as the precomposed text")
            rule.steps = [.init(kind: .trimWhitespace)]
            check(
                try rule.transform("\u{A0}2 eggs\u{A0}") == "2 eggs",
                "G345 trim still removes no-break spaces at line edges")
            rule.steps = [.init(kind: .replaceLiteral, find: "\u{E9}", replacement: "E")]
            check(
                try rule.transform("e\u{301} \u{E9}").utf8.elementsEqual("e\u{301} E".utf8),
                "G345 literal replacement leaves a decomposed spelling untouched")
            // G351: mixed endings that run together are refused, not reordered.
            for kind in [
                AutomationDefinition.Step.Kind.sortLines, .removeBlankLines, .deduplicateLines, .keepMarkedListRows
            ] {
                rule.steps = [.init(kind: kind)]
                rejects(
                    "G351 \(kind.rawValue) refuses CR, CRLF and LF that run together", message: "uniform line endings"
                ) { _ = try rule.transform(kind == .keepMarkedListRows ? "- a\r\r\n\n- b" : "a\r\r\n\nb") }
            }
            rule.steps = [.init(kind: .sortLines)]
            rejects("G351 a longer run of mixed endings is refused", message: "uniform line endings") {
                _ = try rule.transform("a\r\n\r\r\n\n\r\nb")
            }
            check(
                try rule.transform("b\r\n\r\na") == "\r\na\r\nb", "G351 uniform CRLF with an empty line still sorts")
            // G378: Markdown removal does not edit spacing it did not create.
            check(try format.transform("a , b **c**") == "a , b c", "G378 unrelated space before a comma is kept")
            check(try format.transform("x ; y *z*") == "x ; y z", "G378 unrelated space before a semicolon is kept")
            check(
                try format.transform("**salt *, fine***") == "salt, fine",
                "G378 padding before a nested opening delimiter is still removed")
            check(
                try format.transform("salt *, fine*") == "salt, fine",
                "G378 padding before an opening delimiter is still removed")
            check(
                try format.transform("salt _; fine_ and __, x__") == "salt; fine and, x",
                "G378 underscore delimiters take their padding the same way")
            check(
                try format.transform("salt *, fine") == "salt *, fine",
                "G378 an unmatched delimiter keeps its padding")
            // G382: the preview charges one regex budget across all pattern rules, as a run does.
            let catastrophic = String(repeating: "a", count: 32) + "!"
            rule.steps = [
                .init(kind: .clearLinesMatching, find: "(a+)+$"), .init(kind: .clearLinesMatching, find: "Ingredients")
            ]
            rejects("G382 the preview rejects a pathological pattern rule", message: "time limit") {
                _ = try rule.testSample(catastrophic)
            }
            // Find a line that one pattern rule handles in a few milliseconds, then repeat the rule
            // 100 times: one shared 0.1 s budget is exhausted, a fresh budget per rule never is.
            var length = 10, single = 0.0
            rule.steps = [.init(kind: .clearLinesMatching, find: "(a+)+$")]
            while length < 24 {
                let line = String(repeating: "a", count: length) + "!"
                single = .infinity
                for _ in 0..<3 {
                    let began = ProcessInfo.processInfo.systemUptime
                    guard (try? rule.transform(line)) != nil else {
                        single = .infinity
                        break
                    }
                    single = min(single, ProcessInfo.processInfo.systemUptime - began)
                }
                if single >= 0.004 { break }
                length += 1
            }
            try require(single >= 0.004 && single < 0.05, "fixture: one pattern rule takes a few milliseconds")
            rule.steps = Array(repeating: rule.steps[0], count: 100)
            rejects("G382 the preview shares one regex budget across pattern rules", message: "time limit") {
                _ = try rule.testSample(String(repeating: "a", count: length) + "!")
            }
            // F71: a rule that asks for its text when running may be saved with no default.
            for kind in literalKinds + [.clearLinesMatching, .replaceLiteral] {
                var asking = AutomationDefinition.example
                asking.steps = [
                    .init(kind: kind, find: "", replacement: kind == .replaceLiteral ? "" : nil, askForFind: true)
                ]
                check((try? asking.validate()) != nil, "F71 \(kind.rawValue) may ask at run time with an empty default")
                asking.steps[0].find = nil
                check((try? asking.validate()) != nil, "F71 \(kind.rawValue) may ask at run time with no default")
                check(
                    try AutomationLibrary.decode(AutomationLibrary(workflows: [asking]).encoded()).workflows == [
                        asking
                    ],
                    "F71 \(kind.rawValue) ask-only rule persists")
                rejects("F71 \(kind.rawValue) run without a value explains what is missing", message: "needs a value") {
                    _ = try asking.transform("text")
                }
                rejects("F71 \(kind.rawValue) test without a value explains what is missing", message: "needs a value")
                { _ = try asking.testSample("text") }
                rejects("F71 \(kind.rawValue) an empty answer at run time is rejected", message: "needs a value") {
                    _ = try asking.resolvingParameters { _, _, _ in "" }
                }
                let answered = try asking.resolvingParameters { _, _, initial in initial.isEmpty ? "drop" : initial }
                check(
                    try answered?.transform("drop\nkeep") == "\nkeep",
                    "F71 \(kind.rawValue) runs with the value supplied at run time")
            }
            let regexRule = AutomationDefinition.Step(kind: .replaceRegex, find: "(雪)([0-9]+)", replacement: "$2·$1")
            let regexSample = try AutomationDefinition.testRules([regexRule], sample: "雪12\r\n👩🏽‍🚀雪3")
            check(regexSample == "12·雪\r\n👩🏽‍🚀3·雪", "Regex Replace uses Find captures and preserves unmatched Unicode")
            let zeroMatches = try AutomationDefinition.testRules([regexRule], sample: "unchanged")
            check(zeroMatches == "unchanged", "Regex Replace with zero matches preserves bytes")
            let zeroWidth = try AutomationDefinition.testRules(
                [.init(kind: .replaceRegex, find: "(?=雪)", replacement: "A")], sample: "雪雪")
            check(zeroWidth == "A雪A雪", "Regex Replace advances after zero-width Unicode matches")
            rejects("Regex Replace rejects partial sample results", message: "1 MiB") {
                _ = try AutomationDefinition.testRules(
                    [.init(kind: .replaceRegex, find: "x", replacement: String(repeating: "雪", count: 2000))],
                    sample: String(repeating: "x", count: 200))
            }
            // F188: Swift names say what a rule does; the stored spellings are pinned.
            check(
                AutomationDefinition.Step.Kind.allCases.map(\.rawValue) == [
                    "removeListMarkers", "removeBlankLines", "sortLines", "deduplicateLines", "replaceLiteral",
                    "removeLinesEqualTo", "removeLinesContaining", "removeLinesStartingWith", "trimWhitespace",
                    "removeMatchingLines", "removeMarkdownHeadings", "removeMarkdownFormatting",
                    "removeCheckboxMarkers", "removeNoteReferences", "keepMarkedListRows", "sortLinesLocalized", "replaceRegex"
                ], "F188 every persisted step spelling and its order is unchanged")
            check(
                AutomationDefinition.Step.Kind.clearLinesEqualTo.rawValue == "removeLinesEqualTo"
                    && AutomationDefinition.Step.Kind.clearLinesContaining.rawValue == "removeLinesContaining"
                    && AutomationDefinition.Step.Kind.clearLinesStartingWith.rawValue == "removeLinesStartingWith"
                    && AutomationDefinition.Step.Kind.clearLinesMatching.rawValue == "removeMatchingLines"
                    && AutomationDefinition.Step.Kind.clearMarkdownHeadings.rawValue == "removeMarkdownHeadings",
                "F188 the clear rules keep their stored remove spellings")
            let storedSpellings = Data(
                #"{"version":1,"workflows":[{"version":1,"id":"A931733F-310A-4EBF-9C48-38C59202D586","name":"Stored","input":"document","output":"editor","steps":[{"kind":"removeLinesEqualTo","find":"a"},{"kind":"removeLinesContaining","find":"b"},{"kind":"removeLinesStartingWith","find":"c"},{"kind":"removeMatchingLines","find":"d"},{"kind":"removeMarkdownHeadings"}]}]}"#
                    .utf8)
            let storedLibrary = try AutomationLibrary.decode(storedSpellings)
            check(
                storedLibrary.workflows[0].steps.map(\.kind) == [
                    .clearLinesEqualTo, .clearLinesContaining, .clearLinesStartingWith, .clearLinesMatching,
                    .clearMarkdownHeadings
                ], "F188 a library written with the stored spellings decodes to the renamed cases")
            let reencoded = String(data: try storedLibrary.encoded(), encoding: .utf8) ?? ""
            check(
                [
                    "removeLinesEqualTo", "removeLinesContaining", "removeLinesStartingWith", "removeMatchingLines",
                    "removeMarkdownHeadings"
                ].allSatisfy { reencoded.contains("\"\($0)\"") } && !reencoded.contains("clear"),
                "F188 encoding writes the stored spellings back")
            check(
                try storedLibrary.workflows[0].transform("a\nxbx\ncc\nd\n# h\nkeep\n") == "\n\n\n\n\nkeep\n",
                "F188 the clear rules empty a matching line and keep its line ending")
            // G347: a locale-aware sort beside the unchanged code-point sort.
            rule.steps = [.init(kind: .sortLines)]
            check(
                try rule.transform("apples\nZucchini\n\u{C9}clairs\nbananas\nitem 10\nitem 9\n")
                    == "Zucchini\napples\nbananas\nitem 10\nitem 9\n\u{C9}clairs\n",
                "G347 the default sort is still code-point order")
            rule.steps = [.init(kind: .sortLinesLocalized)]
            check(
                try rule.transform("apples\r\nZucchini\r\n\u{C9}clairs\r\nbananas\r\nitem 10\r\nitem 9")
                    == "apples\r\nbananas\r\n\u{C9}clairs\r\nitem 9\r\nitem 10\r\nZucchini",
                "G347 the locale sort puts case and accents second and numbers by value")
            check(
                try rule.transform("e\u{301}\n\u{E9}\ne\u{301}\n").utf8.elementsEqual(
                    "e\u{301}\ne\u{301}\n\u{E9}\n".utf8)
                    && rule.transform("\u{E9}\ne\u{301}\n").utf8.elementsEqual("e\u{301}\n\u{E9}\n".utf8),
                "G347 lines the locale treats as equal get one fixed order and keep their bytes")
            rejects("G347 the locale sort refuses mixed line endings", message: "uniform line endings") {
                _ = try rule.transform("b\r\na\n")
            }
            check(
                try AutomationLibrary.decode(AutomationLibrary(workflows: [rule]).encoded()).workflows[0].steps
                    == [.init(kind: .sortLinesLocalized)], "G347 the locale sort rule persists")
            rule.steps = [.init(kind: .sortLinesLocalized, find: "x")]
            rejects("G347 the locale sort takes no parameter") { try rule.validate() }
            let sortCancel = AutomationRunControl()
            let sortObservations = AutomationProgressObservations()
            sortCancel.onProgress = { completed, _ in
                if completed == 0 { sortCancel.cancel() } else { sortObservations.markComparison() }
            }
            rule.steps = [.init(kind: .sortLinesLocalized)]
            rejects("G347 the locale sort observes cancellation", message: "Automation cancelled") {
                _ = try rule.transform((0..<20_000).map { "row \(20_000 - $0)\n" }.joined(), control: sortCancel)
            }
            check(!sortObservations.comparisonsSeen, "G347 a cancelled sort never reports its step complete")
            check(
                LineOrder.codePointAscending("Z", "a") && !LineOrder.localizedAscending("Z", "a")
                    && LineOrder.localizedAscending("item 9", "item 10")
                    && !LineOrder.codePointAscending("item 9", "item 10"),
                "G347 the shared comparators differ exactly on case and numbers")
            // G376: the first-run preset is named for what it does.
            check(
                AutomationDefinition.example.id.uuidString == "A931733F-310A-4EBF-9C48-38C59202D586"
                    && AutomationDefinition.example.name == "Clean up recipe list",
                "G376 the first-run preset keeps its identifier and is named as a recipe cleanup")
            let userSample = try String(
                contentsOf: fixtures.appendingPathComponent("recipe-user-sample1-input.txt"), encoding: .utf8)
            rejects(
                "G376 the strict preset refuses a list that mixes marked and unmarked rows", message: "no list marker"
            ) { _ = try AutomationDefinition.example.transform(userSample) }
            check(
                AutomationDefinition.example.steps.first?.find == AutomationDefinition.recipeHeadingPattern,
                "G376 the preset uses the one named heading pattern")
            // G377: templates are bundled rule files with no sample-specific text.
            let templateFolder = TestPaths.resources.appendingPathComponent("AutomationTemplates")
            check(
                Set(try FileManager.default.contentsOfDirectory(atPath: templateFolder.path))
                    == Set(AutomationTemplates.resourceNames.map { $0 + ".rules.json" }),
                "G377 every bundled template file is listed and every listed template exists")
            let bundled = AutomationTemplates.loadAll()
            check(
                bundled.problems.isEmpty && bundled.sets.count == AutomationTemplates.resourceNames.count,
                "G377 every bundled template decodes and validates: \(bundled.problems)")
            check(
                bundled.sets.map(\.name) == [
                    "Trim and remove empty lines", "Sort unique lines", "Recipe ingredient cleanup"
                ], "G377 the template names and order are unchanged")
            check(
                bundled.sets.count == 3
                    && bundled.sets[0].steps == [.init(kind: .trimWhitespace), .init(kind: .removeBlankLines)]
                    && bundled.sets[1].steps == [.init(kind: .sortLines), .init(kind: .deduplicateLines)],
                "G377 the two general templates keep their rules")
            if bundled.sets.count == 3 {
                let recipeTemplate = bundled.sets[2].steps
                check(
                    recipeTemplate.prefix(2).map(\.find) == [
                        AutomationDefinition.recipeHeadingPattern, AutomationDefinition.colonLabelPattern
                    ], "G377 the recipe template uses the two named patterns")
                check(
                    recipeTemplate.map(\.kind) == [
                        .clearLinesMatching, .clearLinesMatching, .clearMarkdownHeadings, .removeListMarkers,
                        .removeMarkdownFormatting, .removeCheckboxMarkers, .removeNoteReferences, .trimWhitespace,
                        .removeBlankLines
                    ] && recipeTemplate.dropFirst(2).allSatisfy { $0.find == nil && $0.replacement == nil },
                    "G377 the recipe template holds only general rules")
            }
            rejects("G377 a missing template is an error, not an empty rule list") {
                _ = try AutomationTemplates.load("no-such-template")
            }
            // F141: clipboard HTML becomes text by a local scan; nothing is rendered or fetched.
            func html(_ text: String) -> String? { AutomationHTMLText.plainText(from: Data(text.utf8)) }
            check(
                html(
                    #"<ul><li>2 eggs</li><li>½ cup flour</li></ul><img src="http://127.0.0.1:1/x.png"><script>alert("x")</script>"#
                ) == "2 eggs\n½ cup flour\n", "F141 list items become rows; images and scripts leave nothing behind")
            check(
                html("<p>a &amp; b &lt;c&gt; &quot;d&quot; &#233; &#xE9; &nbsp;e &bogus; &#0; x&y</p>")
                    == "a & b <c> \"d\" \u{E9} \u{E9} \u{A0}e &bogus; &#0; x&y\n",
                "F141 basic character references are decoded and unknown ones are kept as text")
            check(
                html("<div>one<br>two<br/><br>three</div><h2>Head</h2><table><tr><td>a</td><td>b</td></tr></table>")
                    == "one\ntwo\n\nthree\nHead\nab\n", "F141 line breaks and block ends become line endings")
            check(
                html(
                    "<html><head><title>T</title><style>p{color:red}</style></head><body><style>x{}</style>  keep \n  this  <!-- not <b>this</b> --></body></html>"
                ) == "keep this", "F141 head, style and comments are dropped and white space is collapsed")
            check(
                html("<head><meta charset=utf-8><body><p title=\"a > b\">kept</p>") == "kept\n",
                "F141 an unclosed head ends at body and a quoted > does not end a tag")
            check(html("<pre>a\n  b</pre>c") == "a\n  b\nc", "F141 preformatted text keeps its spacing")
            check(
                html("2 < 3 and <notclosed") == "2 < 3 and", "F141 a bare < is text and an unterminated tag is dropped")
            check(
                html("text<script>never closed") == "text" && html("a<!-- never closed") == "a",
                "F141 unterminated script and comment content never becomes text")
            check(
                html("<img src=\"x.png\">") == nil && html("") == nil && html("<p> \n </p>") == nil,
                "F141 markup with no text yields nothing")
            check(
                AutomationHTMLText.plainText(from: Data([0xFF, 0xFE]) + "<b>hi</b>".data(using: .utf16LittleEndian)!)
                    == "hi"
                    && AutomationHTMLText.plainText(from: Data([0xEF, 0xBB, 0xBF]) + Data("<i>hi</i>".utf8)) == "hi"
                    && AutomationHTMLText.plainText(from: Data([0xC3, 0x28])) == nil,
                "F141 UTF-16 and UTF-8 byte order marks are accepted and invalid bytes are refused")
            check(
                html("<SCRIPT type='x'>var a = '</p>';</SCRIPT><P>ok</P>") == "ok\n",
                "F141 tag names are matched without regard to case")
            Checks.section("audit package 15: rule editor support") {
                typealias Step = AutomationDefinition.Step
                let kinds = Step.Kind.allCases
                // G383: Test Rules is independent of the automation's name; Save is not.
                check(
                    try AutomationDefinition.testRules(
                        friendly.steps, sample: "Serves: 4\n Ingredients \n ½ cup flour \n2 eggs\n2 eggs\n")
                        == "½ cup flour\n2 eggs\n2 eggs\n", "G383 rule preview is independent of the workflow name")
                var blankName = friendly
                blankName.name = ""
                rejects("G383 definition with blank name still fails validate", message: "needs a name") {
                    try blankName.validate()
                }
                rejects("G383 a sample test of a blank-named definition still fails", message: "needs a name") {
                    _ = try blankName.testSample("x")
                }
                rejects("G383 the rule preview keeps the 64 KiB sample limit", message: "64 KiB") {
                    _ = try AutomationDefinition.testRules([], sample: String(repeating: "a", count: 65537))
                }
                let cancelledPreview = AutomationRunControl()
                cancelledPreview.cancel()
                rejects("G383 the rule preview honours cancellation", message: "Automation cancelled") {
                    _ = try AutomationDefinition.testRules([], sample: "x", control: cancelledPreview)
                }
                // G387: one list of find-accepting kinds, used by validation.
                check(
                    Set(kinds.filter(\.acceptsFind)) == [
                        .replaceLiteral, .replaceRegex, .clearLinesMatching, .clearLinesEqualTo, .clearLinesContaining,
                        .clearLinesStartingWith
                    ] && kinds.filter(\.acceptsReplacement) == [.replaceLiteral, .replaceRegex],
                    "G387 the kinds that take text to match and a replacement are listed once on the kind")
                for kind in kinds {
                    let withFind = Step(kind: kind, find: "x", replacement: kind.acceptsReplacement ? "y" : nil)
                    check(
                        ((try? withFind.validate()) != nil) == kind.acceptsFind,
                        "G387 \(kind.rawValue): validation accepts text to match exactly when the kind does")
                    let asking = Step(kind: kind, find: kind.acceptsFind ? "x" : nil, askForReplacement: true)
                    check(
                        (try? asking.validate()) == nil || kind.acceptsReplacement,
                        "G387 \(kind.rawValue): a replacement prompt is refused unless the kind takes a replacement")
                }
                check(
                    Step.configured(
                        kind: .trimWhitespace, find: "", replacement: "", askForFind: false, askForReplacement: false,
                        from: Step(kind: .trimWhitespace)) == Step(kind: .trimWhitespace),
                    "G387 a rule saved unchanged equals the rule that was opened")
                for step in AutomationDefinition.example.steps + [
                    Step(kind: .replaceLiteral, find: "a", replacement: ""),
                    Step(kind: .clearLinesEqualTo, find: "", askForFind: true),
                    Step(kind: .replaceLiteral, find: "a", replacement: "b", askForFind: false, askForReplacement: true)
                ] {
                    check(
                        Step.configured(
                            kind: step.kind, find: step.find ?? "", replacement: step.replacement ?? "",
                            askForFind: step.askForFind == true, askForReplacement: step.askForReplacement == true,
                            from: step) == step, "G387 \(step.summary) round-trips unchanged through the rule dialog")
                }
                let offFlags = Step.configured(
                    kind: .replaceLiteral, find: "a", replacement: "b", askForFind: false, askForReplacement: false,
                    from: Step(kind: .removeBlankLines))
                check(
                    offFlags.askForFind == nil && offFlags.askForReplacement == nil,
                    "G387 a prompt flag that is off is left out, not written as false")
                let exportedOff = String(
                    data: try AutomationRuleSet(name: "n", steps: [offFlags]).encoded(), encoding: .utf8)!
                check(
                    !exportedOff.contains("askFor"), "G387 an exported rule with no prompts carries no prompt keys")
                let changedKind = Step.configured(
                    kind: .trimWhitespace, find: "left over", replacement: "left over", askForFind: true,
                    askForReplacement: true, from: Step(kind: .replaceLiteral, find: "a", replacement: "b"))
                check(
                    changedKind == Step(kind: .trimWhitespace),
                    "G387 fields and prompts the chosen kind does not take are dropped")
                let explicitFalse = Data(
                    #"{"version":1,"name":"old","steps":[{"kind":"trimWhitespace","askForFind":false,"askForReplacement":false}]}"#
                        .utf8)
                check(
                    try AutomationRuleSet.decode(explicitFalse).steps
                        == [Step(kind: .trimWhitespace, askForFind: false, askForReplacement: false)],
                    "G387 an old file with explicit false prompt flags still decodes")
                rejects("G387 a single rule validates without a probe definition", message: "needs text to match") {
                    try Step(kind: .clearLinesContaining, find: "").validate()
                }
                rejects("G387 a rule that asks with no value is named as this rule when it has no position") {
                    try Step(kind: .clearLinesContaining, find: "", askForFind: true).validate(requiringValues: true)
                }
                // G381: the JSON reference and the messages are generated from the kinds.
                let reference = AutomationDefinition.ruleKindReference
                check(
                    kinds.allSatisfy { reference.contains($0.rawValue + " — " + $0.label) },
                    "G381 the Advanced JSON reference lists every rule kind with its label")
                check(
                    reference.components(separatedBy: "\n").count == kinds.count,
                    "G381 the reference has one line for each kind")
                check(
                    Set(kinds.map(\.label)).count == kinds.count && Set(kinds.map(\.rawValue)).count == kinds.count,
                    "G381 every rule kind has its own label")
                let help = AutomationDefinition.advancedHelp
                check(
                    help.contains("askForFind") && help.contains("askForReplacement") && help.contains("favorite")
                        && help.contains(AutomationDefinition.favoriteHelp)
                        && help.contains("Favorites appear first in the Automations drop-down")
                        && !help.contains("adds its toolbar button")
                        && help.contains("No automation runs when saved or imported."),
                    "G381 the Advanced JSON help names prompt fields, working favorite buttons and no implicit execution"
                )
                rejects(
                    "G381 a stray find on a kind that takes none is reported with the kind's label",
                    message: "“Trim spaces at line edges” (trimWhitespace in JSON) takes no text to match"
                ) { try Step(kind: .trimWhitespace, find: "x").validate() }
                rejects(
                    "G381 a pattern error names the rule by its label and JSON kind",
                    message: "“Clear lines matching a pattern (advanced)” (removeMatchingLines in JSON)"
                ) { try Step(kind: .clearLinesMatching, find: "[").validate() }
                rejects(
                    "G381 a literal line rule with a replacement is reported for that kind",
                    message: "“Clear lines equal to text” (removeLinesEqualTo in JSON) needs text to match"
                ) { try Step(kind: .clearLinesEqualTo, find: "x", replacement: "y").validate() }
                // G381: a run-time prompt uses the names the rule dialog uses.
                var promptLabels: [String] = []
                var asking = AutomationDefinition.example
                asking.steps = [
                    Step(kind: .clearLinesMatching, find: "a+", askForFind: true),
                    Step(kind: .replaceLiteral, find: "x", replacement: "y", askForFind: true, askForReplacement: true)
                ]
                _ = try asking.resolvingParameters { _, label, value in
                    promptLabels.append(label)
                    return value
                }
                check(
                    promptLabels == ["Pattern", "Text to match", "Replace with"]
                        && promptLabels[0] == Step.Kind.clearLinesMatching.findTitle
                        && promptLabels[2] == Step.Kind.replacementTitle,
                    "G381 run-time prompts are labelled as the rule dialog labels the same fields")
                // G389: the reference document's table cannot drift from the kinds.
                let rulesDocument = try String(
                    contentsOf: TestPaths.repoRoot.appendingPathComponent("docs/AUTOMATION-RULES.md"), encoding: .utf8)
                check(
                    kinds.allSatisfy { rulesDocument.contains("| \($0.label) | `\($0.rawValue)` |") },
                    "G389 the rules reference lists every kind with its builder label and JSON name")
                for kind in kinds {
                    let row = rulesDocument.components(separatedBy: "\n").first {
                        $0.contains("| `\(kind.rawValue)` |")
                    }
                    check(
                        (row?.contains("`find`") == true) == kind.acceptsFind
                            && (row?.contains("`replacement`") == true) == kind.acceptsReplacement,
                        "G389 \(kind.rawValue): the reference names exactly the parameters the kind takes")
                }
                // G386: a row shows the replacement and the prompt flags.
                check(
                    Step(kind: .replaceLiteral, find: "x", replacement: "y").summary
                        == "Find and replace text  ·  “x” → “y”", "G386 a replace rule's row shows its replacement")
                check(
                    Step(kind: .replaceLiteral, find: "x", replacement: "").summary
                        != Step(kind: .replaceLiteral, find: "x", replacement: "z").summary,
                    "G386 replace rules with the same text to match are told apart by their rows")
                check(
                    Step(kind: .clearLinesEqualTo, find: "a\nb", askForFind: true).summary
                        == "Clear lines equal to text  ·  “a↵b”  ·  asks for the text when run"
                        && Step(
                            kind: .replaceLiteral, find: "x", replacement: "y", askForFind: true,
                            askForReplacement: true
                        ).summary.hasSuffix("asks for both when run")
                        && Step(kind: .replaceLiteral, find: "x", replacement: "y", askForReplacement: true).summary
                            .hasSuffix("asks for the replacement when run"),
                    "G386 a row marks a rule that asks for its values when run")
                check(
                    Step(kind: .removeBlankLines).summary == "Remove empty lines"
                        && Step.Kind.sortLines.label == "Sort lines (case-sensitive)"
                        && Step.Kind.clearLinesMatching.findTitle == "Pattern"
                        && Step.Kind.replaceLiteral.findTitle == "Text to match",
                    "G386 the sort rule says it is case-sensitive and the pattern rule calls its field Pattern")
                // G379: the rule list as a value.
                func rule(_ text: String) -> Step { Step(kind: .clearLinesEqualTo, find: text) }
                var list = RuleListDraft([rule("a"), rule("b"), rule("c")])
                check(list.selected == 0 && !list.canMoveUp && list.canMoveDown, "G379 a list opens on its first rule")
                check(
                    list.duplicateSelected() && list.steps.map(\.find) == ["a", "a", "b", "c"] && list.selected == 1,
                    "G379 duplicate inserts after the selected rule and selects the copy")
                check(
                    list.moveSelectedDown() && list.moveSelectedDown() && list.steps.map(\.find) == ["a", "b", "c", "a"]
                        && list.selected == 3, "G379 move down carries the selection with the rule")
                check(
                    !list.moveSelectedDown() && !list.canMoveDown && list.selected == 3,
                    "G379 the last rule cannot move down")
                check(
                    list.moveSelectedUp() && list.selected == 2 && list.steps.map(\.find) == ["a", "b", "a", "c"],
                    "G379 move up carries the selection with the rule")
                list.select(3)
                check(
                    list.removeSelected() && list.steps.map(\.find) == ["a", "b", "a"] && list.selected == 2,
                    "G379 removing the last rule clamps the selection to the new last rule")
                list.select(0)
                check(
                    list.removeSelected() && list.selected == 0 && list.steps.map(\.find) == ["b", "a"]
                        && !list.moveSelectedUp(),
                    "G379 removing the first rule keeps the selection on the first row")
                list.select(-1)
                check(
                    list.selected == nil && !list.removeSelected() && !list.duplicateSelected()
                        && !list.moveSelectedUp()
                        && !list.moveSelectedDown() && !list.replaceSelected(with: rule("z"))
                        && list.steps.map(\.find) == ["b", "a"], "G379 with no selection nothing is changed")
                list.select(7)
                check(list.selected == nil, "G379 a row that does not exist is no selection")
                check(
                    list.add(rule("new")) && list.selected == 2 && list.steps.last == rule("new"),
                    "G379 a new rule goes last and is selected")
                check(
                    list.replaceSelected(with: rule("edited")) && list.steps.map(\.find) == ["b", "a", "edited"]
                        && list.selected == 2, "G379 an edited rule replaces the selected one in place")
                check(
                    list.removeSelected() && list.removeSelected() && list.removeSelected() && list.steps.isEmpty
                        && list.selected == nil && !list.removeSelected(),
                    "G379 removing every rule leaves an empty list with no selection")
                var full = RuleListDraft(Array(repeating: rule("r"), count: RuleListDraft.maximumRules - 1))
                check(full.canAdd && full.canDuplicate, "G379 one below the limit a rule can still be added")
                check(
                    full.duplicateSelected() && full.steps.count == 100 && !full.canAdd && !full.canDuplicate,
                    "G379 the hundredth rule closes Add and Duplicate")
                check(
                    !full.add(rule("x")) && !full.duplicateSelected() && full.steps.count == 100,
                    "G379 the 100-rule limit refuses a further rule")
                check(
                    (try? AutomationDefinition(
                        id: UUID(), name: "n", input: .document, steps: full.steps, output: .editor
                    ).validate()) != nil, "G379 a list at the limit is a valid automation")
                full.replaceAll(with: [])
                check(full.steps.isEmpty && full.selected == nil, "G379 loading an empty rule set clears the selection")
                full.replaceAll(with: [rule("a"), rule("b")])
                check(full.selected == 0, "G379 loaded rules select the first rule")
                check(RuleListDraft([]).selected == nil, "G379 an empty list has no selection")
                // G379 and G385: which test outcome may be shown.
                var preview = RulePreviewState()
                check(!preview.invalidate(), "G385 with nothing shown and nothing running there is nothing stale")
                let first = preview.begin()
                check(preview.isRunning && !preview.showsOutcome, "G379 a started test is running")
                check(preview.invalidate(), "G379 an edit during a test is something to report as stale")
                check(!preview.finish(first), "G379 a result that arrives after an edit is refused")
                check(!preview.invalidate(), "G385 a refused result leaves nothing stale")
                let second = preview.begin(), third = preview.begin()
                check(second != third && !preview.finish(second), "G379 an earlier test's result is refused")
                check(
                    preview.finish(third) && preview.showsOutcome && !preview.isRunning,
                    "G379 the current test's result is accepted")
                check(!preview.finish(third), "G379 a result is accepted once")
                check(
                    preview.invalidate() && !preview.showsOutcome,
                    "G379 an edit after a shown result makes it stale")
                // G388: what Load Rules → Import File makes of a file.
                let ruleFile = try AutomationRuleSet(name: "Heading cleanup", steps: [rule("Ingredients")]).encoded()
                let importedRules = try AutomationRuleImport.ruleSets(from: ruleFile)
                check(
                    !importedRules.fromLibrary && importedRules.sets.count == 1
                        && importedRules.sets[0].name == "Heading cleanup"
                        && importedRules.sets[0].steps == [rule("Ingredients")], "G388 a rule file imports as its rules"
                )
                var twoAutomations = AutomationLibrary(workflows: AutomationDefinition.firstRunPresets)
                twoAutomations.workflows[1].destinationID = "list-identifier"
                let importedLibrary = try AutomationRuleImport.ruleSets(from: twoAutomations.encoded())
                check(
                    importedLibrary.fromLibrary
                        && importedLibrary.sets.map(\.name) == twoAutomations.workflows.map(\.name)
                        && importedLibrary.sets.map(\.steps) == twoAutomations.workflows.map(\.steps),
                    "G388 a library export is recognised and offers each automation's rules")
                rejects("G388 an empty library export has no rules to load", message: "holds no automations") {
                    _ = try AutomationRuleImport.ruleSets(from: AutomationLibrary(workflows: []).encoded())
                }
                for (text, what) in [("{bad", "malformed JSON"), ("[1,2]", "other JSON"), ("plain text", "plain text")]
                {
                    rejects("G388 \(what) is reported as not a rule file", message: "not a rule file") {
                        _ = try AutomationRuleImport.ruleSets(from: Data(text.utf8))
                    }
                }
                let blankNamed = Data(#"{"version":1,"name":"  ","steps":[{"kind":"removeBlankLines"}]}"#.utf8)
                check(
                    try AutomationRuleImport.ruleSets(from: blankNamed).sets.first?.name
                        == AutomationRuleImport.fallbackName, "G388 a rule file with a blank name still imports")
                rejects("G388 a blank name still refuses the strict rule-file decode", message: "needs a name") {
                    _ = try AutomationRuleSet.decode(blankNamed)
                }
                rejects("G388 an invalid rule in an imported file is still refused", message: "needs text to match") {
                    _ = try AutomationRuleImport.ruleSets(
                        from: Data(
                            #"{"version":1,"name":"n","steps":[{"kind":"removeLinesContaining","find":""}]}"#.utf8))
                }
                rejects("G388 a future rule-set version is still refused on import", message: "Unsupported rule-set") {
                    _ = try AutomationRuleImport.ruleSets(from: Data(#"{"version":2,"name":"n","steps":[]}"#.utf8))
                }
                rejects("G388 an oversized file is refused before decoding", message: "at most 1 MiB") {
                    _ = try AutomationRuleImport.ruleSets(from: Data(repeating: 32, count: 1_048_577))
                }
                // G364: the presets a new installation starts with, for the explicit restore.
                check(
                    AutomationDefinition.firstRunPresets.map(\.id)
                        == [AutomationDefinition.example.id, AutomationDefinition.remindersExample.id],
                    "G364 the first-run presets are the cleanup and the reminders automation, in that order")
            }
            Checks.summary {
                "PASS AutomationChecks: \(Checks.count) assertions (pure core; native UI and external outputs not covered)"
            }
        }
    }
}

private enum ProgressReentryFailure: Error { case unknownMode }

/// Only this fixture's complete mutable observation state is protected by its lock.
private final class AutomationProgressObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [Int] = []
    private var cancelled = false
    private var compared = false
    func record(_ step: Int) {
        lock.lock()
        steps.append(step)
        lock.unlock()
    }
    func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    func markComparison() {
        lock.lock()
        compared = true
        lock.unlock()
    }
    var completed: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }
    var cancelledAtCheckpoint: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    var comparisonsSeen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return compared
    }
}

private final class AutomationProgressCapture: Sendable {
    let control: AutomationRunControl
    let done: DispatchSemaphore
    init(control: AutomationRunControl, done: DispatchSemaphore) {
        self.control = control
        self.done = done
    }
    deinit {
        control.cancel()
        done.signal()
    }
}
