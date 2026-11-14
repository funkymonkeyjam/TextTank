// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct RecordedMacro: Codable, Identifiable, Equatable {
    struct Step: Codable, Equatable {
        enum Kind: String, Codable { case insertText, command, findLiteral, replaceSelection }
        var kind: Kind
        var text: String?
        var command: String?
        var matchCase: Bool?
        var backwards: Bool?
        static let commands: Set<String> = [
            "cut", "copy", "paste", "selectAll", "duplicateLine", "deleteLine", "transposeLine", "indent", "unindent", "upper", "lower",
            "charLeft", "charRight", "lineUp", "lineDown", "home", "lineEnd", "documentStart", "documentEnd",
            "wordLeft", "wordRight", "deleteBack", "deleteForward", "newLine", "tab", "backTab",
            "charLeftExtend", "charRightExtend", "lineUpExtend", "lineDownExtend", "homeExtend", "lineEndExtend",
            "documentStartExtend", "documentEndExtend", "wordLeftExtend", "wordRightExtend"
        ]
        func validate() throws {
            switch kind {
            case .insertText, .replaceSelection:
                guard text != nil, command == nil, matchCase == nil, backwards == nil else { throw MacroError.invalid("Text macro step has invalid parameters.") }
            case .command:
                guard let command, Self.commands.contains(command), text == nil, matchCase == nil, backwards == nil else { throw MacroError.invalid("Unrecognized or unsafe macro command.") }
            case .findLiteral:
                guard let text, !text.isEmpty, command == nil, matchCase != nil, backwards != nil else { throw MacroError.invalid("Literal find requires nonempty text, matchCase and backwards parameters.") }
            }
        }
    }
    var version: Int = 1
    var id: UUID
    var name: String
    var steps: [Step]
    func validate() throws {
        guard version == 1, !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name.count <= 120, !steps.isEmpty, steps.count <= 10000 else { throw MacroError.invalid("A macro requires version 1, a name of 1–120 characters, and 1–10000 supported steps.") }
        for step in steps { try step.validate() }
    }
}
enum MacroError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}
struct MacroLibrary: Codable, Equatable {
    var version: Int = 1
    var macros: [RecordedMacro]
    func validate() throws {
        guard version == 1, macros.count <= 200, Set(macros.map(\.id)).count == macros.count else { throw MacroError.invalid("Invalid macro library version, count or duplicate IDs.") }
        for macro in macros { try macro.validate() }
    }
    static func decode(_ data: Data) throws -> MacroLibrary {
        let library = try JSONDecoder().decode(Self.self,from:data);try library.validate();return library
    }
    func encoded() throws -> Data {
        try validate();let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
