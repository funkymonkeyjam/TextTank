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
        let itemName = String(name.prefix(120))
        guard version == 1 else { throw MacroError.invalid("Macro “\(itemName)” requires version 1.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            throw MacroError.invalid("The macro name must contain 1–120 characters.")
        }
        guard !steps.isEmpty, steps.count <= 10000 else {
            throw MacroError.invalid("Macro “\(itemName)” requires 1–10000 supported actions.")
        }
        for (index, step) in steps.enumerated() {
            do { try step.validate() } catch {
                throw MacroError.invalid("Macro “\(itemName)”, action \(index + 1): \(error.localizedDescription)")
            }
        }
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
    /// Same 32 MiB resource envelope as saved automations; bound both import and persistence.
    static let maximumBytes = 32 * 1024 * 1024
    var version: Int = 1
    var macros: [RecordedMacro]
    func validate() throws {
        guard version == 1 else { throw MacroError.invalid("Saved macros require version 1.") }
        guard macros.count <= 200 else { throw MacroError.invalid("Keep at most 200 saved macros.") }
        var seen = Set<UUID>()
        var remaining = Self.maximumBytes
        func consume(_ text: String?) throws {
            guard let text else { return }
            let count = text.utf8.count
            guard count <= remaining else {
                throw MacroError.invalid("Saved macros exceed the 32 MiB limit. The file was not changed.")
            }
            remaining -= count
        }
        for macro in macros {
            guard seen.insert(macro.id).inserted else {
                throw MacroError.invalid("Macro “\(String(macro.name.prefix(120)))” appears more than once.")
            }
            try macro.validate()
            try consume(macro.name)
            for step in macro.steps {
                try consume(step.text)
                try consume(step.search?.query)
                try consume(step.search?.replacement)
            }
        }
    }
    static func decode(_ data: Data) throws -> MacroLibrary {
        guard data.count <= maximumBytes else {
            throw MacroError.invalid("Saved macros exceed the 32 MiB limit. The file was not changed.")
        }
        let library = try JSONInputFailure.decode(Self.self, from: data, context: "Saved macros")
        try library.validate()
        return library
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else {
            throw MacroError.invalid("Saved macros exceed the 32 MiB limit. The file was not changed.")
        }
        return data
    }
}
