// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main struct AutomationChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { fatalError("FAIL \(name)") }; count += 1
    }
    static func rejects(_ name: String, _ work: () throws -> Void) {
        do { try work(); fatalError("FAIL expected rejection: \(name)") } catch { count += 1 }
    }
    static func main() throws {
        var definition = AutomationDefinition.example
        // This older generic bullet-only configuration intentionally keeps unmarked rows.
        definition.steps = [.init(kind:.removeListMarkers),.init(kind:.removeBlankLines)]
        let input = "• 2 eggs\r\n\r\n- ½ cup flour\r\n* 1½ cups café\r\n1/2 tsp salt\r\n2–3 cloves garlic\r\n2 eggs\r\n2 eggs\r\n1. 5 cups\r\n"
        let expected = "2 eggs\r\n½ cup flour\r\n1½ cups café\r\n1/2 tsp salt\r\n2–3 cloves garlic\r\n2 eggs\r\n2 eggs\r\n1. 5 cups\r\n"
        try check(definition.transform(input) == expected, "quantities fractions ranges names duplicates CRLF preserved")
        let id = definition.id; definition.shortcut = "r"; definition.destinationID = "selected-list-identifier"
        var library = AutomationLibrary(workflows:[definition])
        library.workflows[0].name = "Scott chooses this name"
        let decoded = try AutomationLibrary.decode(library.encoded())
        try check(decoded.workflows[0].id == id && decoded.workflows[0].shortcut == "r" && decoded.workflows[0].steps == definition.steps && decoded.workflows[0].destinationID == "selected-list-identifier","rename roundtrip preserves ID parameters shortcut")
        try check(decoded.workflows[0].transform(input) == expected,"name cannot select behavior")
        definition.steps = [.init(kind:.deduplicateLines)]
        try check(definition.transform("a\nb\na\n") == "a\nb\n","explicit dedupe stable")
        definition.steps = [.init(kind:.sortLines)]
        try check(definition.transform("z\na") == "a\nz","sort retains missing final EOL")
        try check(definition.transform("z\ra\r") == "a\rz\r","CR retained")
        definition.steps = [.init(kind:.replaceLiteral,find:"$()",replacement:"½")]
        try check(definition.transform("$() eggs") == "½ eggs","metacharacters are literal data")
        definition.steps = [.init(kind:.removeListMarkers)]
        try check(definition.transform("• x\r\n- y\nz\r") == "x\r\ny\nz\r","marker removal preserves mixed exact EOL")
        definition.steps = [.init(kind:.removeBlankLines)]
        rejects("mixed EOL not silently normalized") { _ = try definition.transform("a\r\nb\n") }
        definition.version = 2
        rejects("unknown version") { try definition.validate() }
        definition.version = 1; definition.steps = [.init(kind:.replaceLiteral,find:"",replacement:"x")]
        rejects("empty literal find") { try definition.validate() }
        var invalid = library; invalid.workflows.append(invalid.workflows[0])
        rejects("duplicate stable IDs") { try invalid.validate() }
        invalid.workflows[1].id = UUID()
        rejects("duplicate shortcut") { try invalid.validate() }
        invalid = library; invalid.version = 2
        rejects("unknown library schema") { _ = try AutomationLibrary.decode(JSONEncoder().encode(invalid)) }
        var json = String(data:try library.encoded(),encoding:.utf8)!
        json = json.replacingOccurrences(of:"removeListMarkers",with:"executeShell")
        rejects("unknown executable step") { _ = try AutomationLibrary.decode(Data(json.utf8)) }
        var sameNames = library
        var second = sameNames.workflows[0]; second.id = UUID(); second.shortcut = nil
        sameNames.workflows.append(second)
        try check(AutomationLibrary.decode(sameNames.encoded()).workflows.count == 2,"same names preserve distinct identities")
        var fileExport = definition; fileExport.steps = []; fileExport.input = .file; fileExport.output = .reminders
        let fileLibrary = try AutomationLibrary.decode(AutomationLibrary(workflows:[fileExport]).encoded())
        try check(fileLibrary.workflows[0].input == .file && fileLibrary.workflows[0].output == .reminders,"file and reminders definitions roundtrip without execution")
        let fixtures=URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let recipe=try String(contentsOf:fixtures.appendingPathComponent("recipe-markdown-input.txt"),encoding:.utf8)
        let cleaned=try String(contentsOf:fixtures.appendingPathComponent("recipe-cleaned-expected.txt"),encoding:.utf8)
        let actual=try AutomationDefinition.example.transform(recipe)
        try check(recipe.split(separator:"\n").filter {$0.hasPrefix("- ")}.count == 28,"independently count source28 ingredient rows")
        try check(cleaned.split(separator:"\n").count == 28,"expected28 ingredient rows")
        try check(actual == cleaned,"exact user Markdown recipe cleanup: \(actual.debugDescription)")
        try check(AutomationDefinition.example.input == .document && AutomationDefinition.example.output == .editor,"cleanup targets current editor")
        try check(AutomationDefinition.example.previewBeforeApply == false && AutomationDefinition.example.pinToToolbar == true,"direct cleanup button defaults")
        try check(AutomationDefinition.remindersExample.output == .reminders && AutomationDefinition.remindersExample.id != AutomationDefinition.example.id,"separate reusable reminder output")
        let noNewKeys = Data("{\"version\":1,\"workflows\":[{\"version\":1,\"id\":\"A931733F-310A-4EBF-9C48-38C59202D586\",\"name\":\"Old name\",\"input\":\"selection\",\"steps\":[],\"output\":\"editor\"}]}".utf8)
        let legacy = try AutomationLibrary.decode(noNewKeys).workflows[0]
        try check(legacy.previewBeforeApply == nil && legacy.pinToToolbar == nil,"old libraries remain decodable with flags absent")
        var format=AutomationDefinition.example;format.steps=[.init(kind:.removeMarkdownFormatting)]
        try check(format.transform("2 * 3 * 4, snake_case, **salt** and *pepper*") == "2 * 3 * 4, snake_case, salt and pepper","formatting preserves multiplication and intraword underscores")
        try check(format.transform("[salt](https://example.invalid/a_(b)) (optional)") == "salt (optional)","balanced URL parentheses do not eat ingredient options")
        try check(format.transform("[salt](broken") == "[salt](broken","malformed links retained")
        try check(format.transform(#"\*literal\*"#) == "*literal*","escaped stars remain literal")
        var notes=AutomationDefinition.example;notes.steps=[.init(kind:.removeNoteReferences)]
        try check(notes.transform("1 cup flour (optional, Note 2) (finely sifted)") == "1 cup flour (optional) (finely sifted)","remove explicit note while preserving parenthetical options")
        try check(notes.transform("1 notebook (optional) — 2 eggs") == "1 notebook (optional) — 2 eggs","ordinary note-like words unchanged")
        var marks=AutomationDefinition.example;marks.steps=[.init(kind:.removeCheckboxMarkers)]
        try check(marks.transform("▢2 eggs\n☐salt to taste\n[x] pepper\n[ ] ½ cup flour") == "2 eggs\nsalt to taste\npepper\n½ cup flour","checkbox glyphs and ASCII boxes independent of numeric content")
        var filtered=AutomationDefinition.example;filtered.steps=[.init(kind:.keepMarkedListRows)]
        try check(filtered.transform("Heading:\n\n▢salt to taste\n▢2 eggs\n") == "▢salt to taste\n▢2 eggs\n","explicit marked-row filter removes structural headers")
        try check(filtered.transform("salt to taste\n2 eggs\n½ cup flour") == "salt to taste\n2 eggs\n½ cup flour","unmarked plain lists do not require checkboxes")
        rejects("unmarked continuation never silently lost") { _ = try filtered.transform("• 2 eggs\nunmarked continuation\n") }
        rejects("optional ingredient cannot be guessed as heading") { _ = try filtered.transform("Salt (optional)\n▢2 eggs\n") }
        try check(filtered.transform("# Any heading\n▢salt\n") == "▢salt\n", "explicit Markdown heading accepted")
        let plain = try String(contentsOf:fixtures.appendingPathComponent("recipe-plain-copy-derived.txt"),encoding:.utf8)
        try check(AutomationDefinition.example.transform(plain) == cleaned.replacingOccurrences(of:"chopped\"",with:"chopped"), "configured optional heading removed from derived copy")
        let explicit = plain.replacingOccurrences(of:"Garnish (optional)",with:"# Garnish (optional)")
        try check(AutomationDefinition.example.transform(explicit) == cleaned.replacingOccurrences(of:"chopped\"",with:"chopped"), "plain copied28 rows retain quantities after explicit heading markup")
        let native = try String(contentsOf:fixtures.appendingPathComponent("recipe-browser-plain-input.txt"),encoding:.utf8)
        let nativeExpected = try String(contentsOf:fixtures.appendingPathComponent("recipe-browser-cleaned-expected.txt"),encoding:.utf8)
        try check(AutomationDefinition.example.transform(native) == nativeExpected, "observed native browser copy cleans28 exactly: \(try AutomationDefinition.example.transform(native).debugDescription)")
        try check(nativeExpected.split(separator:"\n").count == 28, "native expected28 ingredient rows")
        rejects("unknown unmarked ingredient aborts entire transform") { _ = try AutomationDefinition.example.transform(native + "salt to taste\n") }
        var matching = AutomationDefinition.example; matching.steps = [.init(kind:.removeMatchingLines,find:"Ingredients")]
        try check(matching.transform("Ingredients\n2 cups Ingredients mix\n") == "\n2 cups Ingredients mix\n", "regex filter requires full-line match")
        matching.steps = [.init(kind:.removeMatchingLines,find:"[")]
        rejects("invalid heading regex") { try matching.validate() }
        matching.steps = [.init(kind:.removeMatchingLines,find:"",replacement:"x")]
        rejects("invalid heading parameters") { try matching.validate() }
        var renamed = AutomationDefinition.example; renamed.name = "My chosen label"
        try check(renamed.transform(native) == nativeExpected, "configured recipe behavior independent of user name")
        matching.steps = [.init(kind:.removeMatchingLines,find:"(a+)+$")]
        let regexStarted = ProcessInfo.processInfo.systemUptime
        rejects("pathological regex interrupted before applying") { _ = try matching.transform(String(repeating:"a",count:32) + "!") }
        try check(ProcessInfo.processInfo.systemUptime - regexStarted < 2, "regex timeout bounded below two seconds")
        var prompted = AutomationDefinition.example
        prompted.steps = [.init(kind:.replaceLiteral,find:"saved",replacement:"default",askForFind:true,askForReplacement:true)]
        var labels:[String] = []
        let resolved = try prompted.resolvingParameters { index,label,value in labels.append(label); return label == "Find" ? "½" : "$()" }
        try check(resolved?.transform("½ cup") == "$() cup" && labels == ["Find","Replacement"],"runtime parameters are ordered literal data")
        try check(prompted.steps[0].find == "saved", "runtime parameters do not mutate saved defaults")
        try check(prompted.resolvingParameters { _,_,_ in nil } == nil,"parameter cancellation returns no runnable definition")
        rejects("runtime empty find rejected") { _ = try prompted.resolvingParameters { _,label,_ in label == "Find" ? "" : "value" } }
        prompted.steps = [.init(kind:.removeBlankLines,askForFind:true)]
        rejects("irrelevant parameter prompt rejected") { try prompted.validate() }
        let control = AutomationRunControl(); control.cancel()
        rejects("cancelled transform cannot produce output") { _ = try AutomationDefinition.example.transform(native,control:control) }
        let progress = AutomationRunControl(); var completed:[Int] = []; progress.onProgress = { step,_ in completed.append(step) }
        _ = try AutomationDefinition.example.transform(native,control:progress)
        try check(completed.first == 0 && completed.last == AutomationDefinition.example.steps.count,"progress reaches all steps")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomationFiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let utf8 = root.appendingPathComponent("sample.txt"); try Data("café\u{0}👩🏽‍💻".utf8).write(to:utf8)
        try check(AutomationFileInput.read(utf8) == "café\u{0}👩🏽‍💻","file input preserves Unicode and NUL")
        rejects("file bound") { _ = try AutomationFileInput.read(utf8,limit:2) }
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:utf8)
        rejects("symlink input") { _ = try AutomationFileInput.read(link) }
        let fifo = root.appendingPathComponent("fifo"); precondition(mkfifo(fifo.path,0o600) == 0)
        let started = ProcessInfo.processInfo.systemUptime
        rejects("FIFO input rejects without blocking") { _ = try AutomationFileInput.read(fifo) }
        try check(ProcessInfo.processInfo.systemUptime - started < 1,"FIFO rejection below one second")
        print("PASS AutomationChecks: \(count) assertions (pure core; native UI and external outputs not covered)")
    }
}
