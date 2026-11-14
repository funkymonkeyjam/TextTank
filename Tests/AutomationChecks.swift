// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

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
        print("PASS AutomationChecks: \(count) assertions (pure core; native UI and external outputs not covered)")
    }
}
