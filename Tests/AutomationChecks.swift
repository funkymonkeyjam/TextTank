// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main struct AutomationChecks {
    static func main() {
        Checks.run("AutomationChecks") {
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
            rejects("unknown executable step", where: { $0 is DecodingError }) {
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
                    && AutomationDefinition.example.pinToToolbar == true, "direct cleanup button defaults")
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
            matching.steps = [.init(kind: .removeMatchingLines, find: "Ingredients")]
            check(
                try matching.transform("Ingredients\n2 cups Ingredients mix\n") == "\n2 cups Ingredients mix\n",
                "regex filter requires full-line match")
            matching.steps = [.init(kind: .removeMatchingLines, find: "[")]
            rejects("invalid heading regex") { try matching.validate() }
            matching.steps = [.init(kind: .removeMatchingLines, find: "", replacement: "x")]
            rejects("invalid heading parameters") { try matching.validate() }
            var renamed = AutomationDefinition.example
            renamed.name = "My chosen label"
            check(
                try renamed.transform(native) == nativeExpected, "configured recipe behavior independent of user name")
            matching.steps = [.init(kind: .removeMatchingLines, find: "(a+)+$")]
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
                return label == "Find" ? "½" : "$()"
            }
            check(
                try resolved?.transform("½ cup") == "$() cup" && labels == ["Find", "Replacement"],
                "runtime parameters are ordered literal data")
            check(prompted.steps[0].find == "saved", "runtime parameters do not mutate saved defaults")
            check(
                try prompted.resolvingParameters { _, _, _ in nil } == nil,
                "parameter cancellation returns no runnable definition")
            rejects("runtime empty find rejected") {
                _ = try prompted.resolvingParameters { _, label, _ in label == "Find" ? "" : "value" }
            }
            prompted.steps = [.init(kind: .removeBlankLines, askForFind: true)]
            rejects("irrelevant parameter prompt rejected") { try prompted.validate() }
            let control = AutomationRunControl()
            control.cancel()
            rejects("cancelled transform cannot produce output", message: "Automation cancelled") {
                _ = try AutomationDefinition.example.transform(native, control: control)
            }
            let progress = AutomationRunControl()
            var completed: [Int] = []
            progress.onProgress = { step, _ in completed.append(step) }
            _ = try AutomationDefinition.example.transform(native, control: progress)
            check(
                completed.first == 0 && completed.last == AutomationDefinition.example.steps.count,
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
            rejects("symlink input", where: { ($0 as? CocoaError)?.code == .fileReadNoPermission }) {
                _ = try AutomationFileInput.read(link)
            }
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
                .removeLinesEqualTo, .removeLinesContaining, .removeLinesStartingWith
            ]
            for kind in literalKinds {
                var rule = AutomationDefinition.example
                rule.steps = [.init(kind: kind, find: "Note")]
                let source = "Note\r\n Note\r\nnote\r\nNote: optional\r\n2 eggs\r\n2 eggs\r\n½–¾ cup café\r\n"
                let expected: String
                switch kind {
                case .removeLinesEqualTo:
                    expected = "\r\n Note\r\nnote\r\nNote: optional\r\n2 eggs\r\n2 eggs\r\n½–¾ cup café\r\n"
                case .removeLinesContaining: expected = "\r\n\r\nnote\r\n\r\n2 eggs\r\n2 eggs\r\n½–¾ cup café\r\n"
                default: expected = "\r\n Note\r\nnote\r\n\r\n2 eggs\r\n2 eggs\r\n½–¾ cup café\r\n"
                }
                check(
                    try rule.transform(source) == expected,
                    "\(kind.rawValue) case-sensitive literal rows preserve CRLF quantities and duplicates")
                rule.steps = [.init(kind: kind, find: "[x].*")]
                let punctuationInput: String
                switch kind {
                case .removeLinesEqualTo: punctuationInput = "[x].*\n[x] pepper\n2 eggs\n"
                case .removeLinesContaining: punctuationInput = "before [x].* after\n[x] pepper\n2 eggs\n"
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
                    check(label == "Find" && value == "saved", "\(kind.rawValue) prompts with saved literal default")
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
                .init(kind: .removeLinesStartingWith, find: "Serves:"), .init(kind: .trimWhitespace),
                .init(kind: .removeLinesEqualTo, find: "Ingredients"),
                .init(kind: .removeLinesContaining, find: "(advertisement)"), .init(kind: .removeBlankLines)
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
                    .init(kind: .removeLinesEqualTo, find: "Ingredients", askForFind: true),
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
            rejects("malformed portable file rejected", where: { $0 is DecodingError }) {
                _ = try AutomationRuleSet.decode(Data("{bad".utf8))
            }
            rejects("oversized portable file rejected before decode") {
                _ = try AutomationRuleSet.decode(Data(repeating: 32, count: 1048577))
            }
            var invalidPortable = portable
            invalidPortable.steps = [.init(kind: .removeLinesEqualTo, find: "")]
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
            var cancelledAtCheckpoint = false
            activeCancellation.onProgress = { completed, _ in
                if completed == 0 {
                    activeCancellation.cancel()
                    cancelledAtCheckpoint = true
                }
            }
            rejects("active Markdown transformation observes cancellation", message: "Automation cancelled") {
                _ = try bounded.transform(activeText, control: activeCancellation)
            }
            check(cancelledAtCheckpoint, "active transformation was cancelled from its own progress checkpoint")
            let escapedMalformed = "[" + String(repeating: "\\x", count: 20000)
            check(
                try bounded.transform(escapedMalformed) == escapedMalformed,
                "odd-offset escaped malformed link preserves bytes with threshold checkpoints")
            Checks.summary {
                "PASS AutomationChecks: \(Checks.count) assertions (pure core; native UI and external outputs not covered)"
            }
        }
    }
}
