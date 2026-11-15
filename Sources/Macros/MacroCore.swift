// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct RecordedMacro: Codable, Identifiable, Equatable {
    struct Search: Codable, Equatable {
        var query: String, replacement: String, mode: Int
        var matchCase: Bool, wholeWord: Bool, dotMatchesNewline: Bool, wrap: Bool
        var action: String
        func validate() throws {
            guard !query.isEmpty, (0...2).contains(mode),
                ["next", "previous", "replaceOne", "replaceAll"].contains(action)
            else { throw MacroError.invalid("Invalid captured search parameters or scope.") }
        }
    }
    struct Step: Codable, Equatable {
        enum Kind: String, Codable { case insertText, command, findLiteral, replaceSelection, search }
        var kind: Kind
        var text: String?
        var command: String?
        var matchCase: Bool?
        var backwards: Bool?
        var search: Search?
        static let commands: Set<String> = [
            "cut", "copy", "paste", "selectAll", "duplicateLine", "deleteLine", "transposeLine", "indent", "unindent",
            "upper", "lower",
            "charLeft", "charRight", "lineUp", "lineDown", "home", "lineEnd", "documentStart", "documentEnd",
            "wordLeft", "wordRight", "deleteBack", "deleteForward", "newLine", "tab", "backTab",
            "charLeftExtend", "charRightExtend", "lineUpExtend", "lineDownExtend", "homeExtend", "lineEndExtend",
            "documentStartExtend", "documentEndExtend", "wordLeftExtend", "wordRightExtend",
            // G367: the rest of the standard Mac key map. Each name is also in the bridge's table.
            "vcHome", "vcHomeExtend", "pageUp", "pageUpExtend", "pageDown", "pageDownExtend",
            "paraUp", "paraUpExtend", "paraDown", "paraDownExtend",
            "wordPartLeft", "wordPartLeftExtend", "wordPartRight", "wordPartRightExtend",
            "homeDisplay", "lineEndDisplay",
            "deleteWordLeft", "deleteWordRight", "deleteLineLeft", "deleteLineRight",
            "lineCut", "lineCopy", "duplicateSelection", "moveLineUp", "moveLineDown", "cancel"
        ]
        func validate() throws {
            if kind != .search && search != nil {
                throw MacroError.invalid("Search parameters belong only to search steps.")
            }
            switch kind {
            case .insertText, .replaceSelection:
                guard text != nil, command == nil, matchCase == nil, backwards == nil else {
                    throw MacroError.invalid("Text macro step has invalid parameters.")
                }
            case .command:
                guard let command, Self.commands.contains(command), text == nil, matchCase == nil, backwards == nil
                else { throw MacroError.invalid("Unrecognized or unsafe macro command.") }
            case .search:
                guard let search, text == nil, command == nil, matchCase == nil, backwards == nil else {
                    throw MacroError.invalid("Invalid search macro step.")
                }
                try search.validate()
            case .findLiteral:
                guard let text, !text.isEmpty, command == nil, matchCase != nil, backwards != nil else {
                    throw MacroError.invalid("Literal find requires nonempty text, matchCase and backwards parameters.")
                }
            }
        }
    }
    var version: Int = 1
    var id: UUID
    var name: String
    var steps: [Step]
    func validate() throws {
        guard version == 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
            !steps.isEmpty, steps.count <= 10000
        else {
            throw MacroError.invalid(
                "A macro requires version 1, a name of 1–120 characters, and 1–10000 supported steps.")
        }
        for step in steps { try step.validate() }
    }
}
enum MacroError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}
/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct MacroLibrary: Codable, Equatable {
    var version: Int = 1
    var macros: [RecordedMacro]
    func validate() throws {
        guard version == 1, macros.count <= 200, Set(macros.map(\.id)).count == macros.count else {
            throw MacroError.invalid("Invalid macro library version, count or duplicate IDs.")
        }
        for macro in macros { try macro.validate() }
    }
    static func decode(_ data: Data) throws -> MacroLibrary {
        let library = try JSONDecoder().decode(Self.self, from: data)
        try library.validate()
        return library
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
