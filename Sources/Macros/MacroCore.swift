// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package enum MacroLimits {
    static package let recordedActions = 10_000
    static package let repeatCount = 10_000
    static package let playbackActions = 100_000
}

package struct RecordedMacro: Codable, Identifiable, Equatable {
    package init(version: Int = 1, id: UUID, name: String, steps: [Step]) {
        self.version = version
        self.id = id
        self.name = name
        self.steps = steps
    }

    package struct Search: Codable, Equatable {
        package init(
            query: String, replacement: String, mode: Int, matchCase: Bool, wholeWord: Bool, dotMatchesNewline: Bool,
            wrap: Bool, action: String
        ) {
            self.query = query
            self.replacement = replacement
            self.mode = mode
            self.matchCase = matchCase
            self.wholeWord = wholeWord
            self.dotMatchesNewline = dotMatchesNewline
            self.wrap = wrap
            self.action = action
        }

        package var query: String, replacement: String, mode: Int
        package var matchCase: Bool, wholeWord: Bool, dotMatchesNewline: Bool, wrap: Bool
        package var action: String
        package func validate() throws {
            guard !query.isEmpty, (0...2).contains(mode),
                ["next", "previous", "replaceOne", "replaceAll"].contains(action)
            else { throw MacroError.invalid("Invalid captured search parameters or scope.") }
        }
    }
    /// Cases carry only their own payload. Custom Codable retains the version-1 optional-key wire format.
    package enum Step: Codable, Equatable {
        package enum Kind: String, Codable { case insertText, command, findLiteral, replaceSelection, search }
        case insertText(String)
        case command(String)
        case findLiteral(text: String, matchCase: Bool, backwards: Bool)
        case replaceSelection(String)
        case search(Search)
        package var kind: Kind {
            switch self {
            case .insertText: return .insertText
            case .command: return .command
            case .findLiteral: return .findLiteral
            case .replaceSelection: return .replaceSelection
            case .search: return .search
            }
        }
        package var text: String? {
            switch self {
            case .insertText(let text), .replaceSelection(let text), .findLiteral(let text, _, _): return text
            default: return nil
            }
        }
        package var command: String? {
            if case .command(let value) = self { return value }
            return nil
        }
        package var search: Search? {
            if case .search(let value) = self { return value }
            return nil
        }
        static package let commands = EditorCommand.recordableIdentifiers
        package func validate() throws {
            switch self {
            case .insertText, .replaceSelection: break
            case .command(let command):
                guard Self.commands.contains(command) else {
                    throw MacroError.invalid("Unrecognized or unsafe macro command.")
                }
            case .search(let search): try search.validate()
            case .findLiteral(let text, _, _):
                guard !text.isEmpty else {
                    throw MacroError.invalid("Literal find requires nonempty text, matchCase and backwards parameters.")
                }
            }
        }
        private enum CodingKeys: String, CodingKey { case kind, text, command, matchCase, backwards, search }
        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(Kind.self, forKey: .kind)
            // Decode every known key even if it does not belong to this kind. Legacy files ignored
            // unknown keys, but wrong types or incompatible known payloads must still be refused.
            let text = try c.decodeIfPresent(String.self, forKey: .text)
            let command = try c.decodeIfPresent(String.self, forKey: .command)
            let matchCase = try c.decodeIfPresent(Bool.self, forKey: .matchCase)
            let backwards = try c.decodeIfPresent(Bool.self, forKey: .backwards)
            let search = try c.decodeIfPresent(Search.self, forKey: .search)
            if kind != .search && search != nil {
                throw MacroError.invalid("Search parameters belong only to search steps.")
            }
            switch kind {
            case .insertText, .replaceSelection:
                guard let text, command == nil, matchCase == nil, backwards == nil else {
                    throw MacroError.invalid("Text macro step has invalid parameters.")
                }
                self = kind == .insertText ? .insertText(text) : .replaceSelection(text)
            case .command:
                guard let command, text == nil, matchCase == nil, backwards == nil else {
                    throw MacroError.invalid("Unrecognized or unsafe macro command.")
                }
                self = .command(command)
            case .search:
                guard let search, text == nil, command == nil, matchCase == nil, backwards == nil else {
                    throw MacroError.invalid("Invalid search macro step.")
                }
                self = .search(search)
            case .findLiteral:
                guard let text, command == nil, let matchCase, let backwards else {
                    throw MacroError.invalid("Literal find requires nonempty text, matchCase and backwards parameters.")
                }
                self = .findLiteral(text: text, matchCase: matchCase, backwards: backwards)
            }
            try validate()
        }
        package func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            switch self {
            case .insertText(let text), .replaceSelection(let text): try c.encode(text, forKey: .text)
            case .command(let command): try c.encode(command, forKey: .command)
            case .findLiteral(let text, let matchCase, let backwards):
                try c.encode(text, forKey: .text)
                try c.encode(matchCase, forKey: .matchCase)
                try c.encode(backwards, forKey: .backwards)
            case .search(let search): try c.encode(search, forKey: .search)
            }
        }

    }

    package var version: Int
    package var id: UUID
    package var name: String
    package var steps: [Step]
    package func validate() throws {
        let itemName = String(name.prefix(120))
        guard version == 1 else { throw MacroError.invalid("Macro “\(itemName)” requires version 1.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            throw MacroError.invalid("The macro name must contain 1–120 characters.")
        }
        guard !steps.isEmpty, steps.count <= MacroLimits.recordedActions else {
            throw MacroError.invalid(
                "Macro “\(itemName)” requires 1–\(Strings.number(MacroLimits.recordedActions)) supported actions.")
        }
        for (index, step) in steps.enumerated() {
            do { try step.validate() } catch {
                throw MacroError.invalid("Macro “\(itemName)”, action \(index + 1): \(error.localizedDescription)")
            }
        }
    }
}
package enum MacroError: LocalizedError {
    case invalid(String)
    package var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}
/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
package struct MacroLibrary: VersionedLibrary, Equatable {
    package init(version: Int = 1, macros: [RecordedMacro]) {
        self.version = version
        self.macros = macros
    }

    static package let libraryContext = "Saved macros"
    static package var librarySizeError: Error {
        MacroError.invalid("Saved macros exceed the \(SizePolicy.describe(SizePolicy.standard.macroLibrary)) limit. Shorten a recording or remove unused macros.")
    }
    /// Same 32 MiB resource envelope as saved automations; bound both import and persistence.
    static package let maximumBytes = SizePolicy.standard.macroLibrary
    package var version: Int
    package var macros: [RecordedMacro]
    package func validate() throws {
        guard version == 1 else { throw MacroError.invalid("Saved macros require version 1.") }
        guard macros.count <= 200 else { throw MacroError.invalid("Keep at most 200 saved macros.") }
        var seen = Set<UUID>()
        var remaining = Self.maximumBytes
        func consume(_ text: String?) throws {
            guard let text else { return }
            let count = text.utf8.count
            guard count <= remaining else {
                throw MacroError.invalid("Saved macros exceed the \(SizePolicy.describe(SizePolicy.standard.macroLibrary)) limit. Shorten a recording or remove unused macros.")
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
}
