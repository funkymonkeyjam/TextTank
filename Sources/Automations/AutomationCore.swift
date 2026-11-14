// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct AutomationDefinition: Codable, Equatable, Identifiable {
    enum Input: String, Codable { case selection, document, clipboard, file }
    enum Output: String, Codable { case editor, clipboard, newDocument, file, reminders }
    struct Step: Codable, Equatable {
        enum Kind: String, Codable { case removeListMarkers, removeBlankLines, sortLines, deduplicateLines, replaceLiteral }
        var kind: Kind
        var find: String?
        var replacement: String?
    }
    var version: Int = 1
    var id: UUID
    var name: String
    var input: Input
    var steps: [Step]
    var output: Output
    /// A single ASCII letter. UI binds Command-Option-letter and rejects collisions.
    var shortcut: String?
    var destinationID: String?

    static var example: AutomationDefinition {
        AutomationDefinition(id: UUID(), name: "My ingredient cleanup", input: .clipboard,
            steps: [Step(kind: .removeListMarkers), Step(kind: .removeBlankLines)], output: .newDocument)
    }
    func validate() throws {
        guard version == 1 else { throw AutomationError.invalid("Unsupported workflow version \(version).") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            throw AutomationError.invalid("Each automation needs a name of 1–120 characters.")
        }
        guard steps.count <= 100 else { throw AutomationError.invalid("An automation supports at most 100 steps.") }
        if let shortcut, !shortcut.isEmpty {
            guard shortcut.utf8.count == 1, shortcut.range(of: "^[a-z]$", options: .regularExpression) != nil else {
                throw AutomationError.invalid("Shortcut must be one lowercase ASCII letter, or omitted.")
            }
        }
        for step in steps {
            switch step.kind {
            case .replaceLiteral:
                guard let find = step.find, !find.isEmpty, step.replacement != nil else {
                    throw AutomationError.invalid("replaceLiteral requires a nonempty find and a replacement string.")
                }
            default:
                guard step.find == nil, step.replacement == nil else {
                    throw AutomationError.invalid("Only replaceLiteral accepts find/replacement parameters.")
                }
            }
        }
    }
    func transform(_ input: String) throws -> String {
        try validate()
        var result = input
        for step in steps {
            switch step.kind {
            case .replaceLiteral:
                result = result.replacingOccurrences(of: step.find!, with: step.replacement!)
            case .removeListMarkers:
                result = Self.mapLines(result) { line in
                    // No numeric prefixes: "2 eggs" and "1. 5 cups" may be quantities.
                    // Strip only an explicit bullet followed by whitespace, preserving other text.
                    line.replacingOccurrences(of: "^[\\t ]*[-*•][\\t ]+", with: "", options: .regularExpression)
                }
            case .removeBlankLines, .sortLines, .deduplicateLines:
                let parts = try Self.lines(result)
                var body = parts.lines
                if step.kind == .removeBlankLines { body.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
                if step.kind == .sortLines { body.sort() }
                if step.kind == .deduplicateLines {
                    var seen = Set<String>(); body = body.filter { seen.insert($0).inserted }
                }
                result = body.joined(separator: parts.eol) + (parts.trailing && !body.isEmpty ? parts.eol : "")
            }
        }
        return result
    }
    private static func lines(_ text: String) throws -> (lines: [String], eol: String, trailing: Bool) {
        let eol = text.contains("\r\n") ? "\r\n" : (text.contains("\r") && !text.contains("\n") ? "\r" : "\n")
        let withoutCRLF = text.replacingOccurrences(of: "\r\n", with: "")
        if (text.contains("\r\n") && (withoutCRLF.contains("\r") || withoutCRLF.contains("\n"))) || (!text.contains("\r\n") && text.contains("\r") && text.contains("\n")) {
            throw AutomationError.invalid("Line filtering/reordering requires uniform line endings. Mixed endings were not changed.")
        }
        var lines = text.components(separatedBy: eol)
        let trailing = text.hasSuffix(eol)
        if trailing { lines.removeLast() }
        return (lines, eol, trailing)
    }
    private static func mapLines(_ text: String, _ transform: (String)->String) -> String {
        // Preserve each exact separator, including mixed line endings.
        var output = "", line = ""
        for scalar in text.unicodeScalars {
            if scalar == "\r" || scalar == "\n" { output += transform(line); output.unicodeScalars.append(scalar); line = "" }
            else { line.unicodeScalars.append(scalar) }
        }
        return output + transform(line)
    }
}

enum AutomationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

struct AutomationLibrary: Codable, Equatable {
    var version: Int = 1
    var workflows: [AutomationDefinition]
    func validate() throws {
        guard version == 1 else { throw AutomationError.invalid("Unsupported library version \(version).") }
        guard workflows.count <= 200 else { throw AutomationError.invalid("At most 200 automations are supported.") }
        var ids = Set<UUID>(), keys = Set<String>()
        for workflow in workflows {
            try workflow.validate()
            guard ids.insert(workflow.id).inserted else { throw AutomationError.invalid("Workflow identifiers must be unique. Generate a new UUID when duplicating a workflow.") }
            if let key = workflow.shortcut, !key.isEmpty, !keys.insert(key).inserted {
                throw AutomationError.invalid("Two automations use Command-Option-\(key.uppercased()).")
            }
        }
    }
    static func decode(_ data: Data) throws -> AutomationLibrary {
        let result = try JSONDecoder().decode(AutomationLibrary.self, from: data)
        try result.validate(); return result
    }
    func encoded() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
