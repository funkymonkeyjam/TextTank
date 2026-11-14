// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct AutomationDefinition: Codable, Equatable, Identifiable {
    enum Input: String, Codable { case selection, document, clipboard, file }
    enum Output: String, Codable { case editor, clipboard, newDocument, file, reminders }
    struct Step: Codable, Equatable {
        enum Kind: String, Codable { case removeListMarkers, removeBlankLines, sortLines, deduplicateLines, replaceLiteral
            case removeMatchingLines, removeMarkdownHeadings, removeMarkdownFormatting, removeCheckboxMarkers, removeNoteReferences, keepMarkedListRows }
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
    /// Older definitions decode without these keys. False means apply local output directly;
    /// external connectors still require their own explicit destination/send confirmation.
    var previewBeforeApply: Bool?
    var pinToToolbar: Bool?

    static var example: AutomationDefinition {
        AutomationDefinition(id: UUID(uuidString: "A931733F-310A-4EBF-9C48-38C59202D586")!, name: "Clean up text", input: .document,
            steps: [Step(kind: .removeMatchingLines, find: #"(?i)^[ \t]*(?:Ingredients|Cups|Metric|Garnish[ \t]*\(optional\))[ \t]*$"#), Step(kind: .keepMarkedListRows), Step(kind: .removeMarkdownHeadings), Step(kind: .removeListMarkers),
                    Step(kind: .removeMarkdownFormatting), Step(kind: .removeCheckboxMarkers),
                    Step(kind: .removeNoteReferences), Step(kind: .removeBlankLines)],
            output: .editor, previewBeforeApply: false, pinToToolbar: true)
    }
    static var remindersExample: AutomationDefinition {
        AutomationDefinition(id: UUID(uuidString: "AE932D35-4371-4D64-9091-95780DCD2441")!, name: "Add to Reminders", input: .document,
            steps: [Step(kind: .removeBlankLines)], output: .reminders,
            previewBeforeApply: false, pinToToolbar: true)
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
            case .removeMatchingLines:
                guard let pattern = step.find, !pattern.isEmpty, pattern.count <= 500, step.replacement == nil else {
                    throw AutomationError.invalid("removeMatchingLines requires a nonempty regex find (up to 500 characters) and no replacement.")
                }
                do { _ = try NSRegularExpression(pattern: pattern) }
                catch { throw AutomationError.invalid("Invalid removeMatchingLines regex: \(error.localizedDescription)") }
            case .replaceLiteral:
                guard let find = step.find, !find.isEmpty, step.replacement != nil else {
                    throw AutomationError.invalid("replaceLiteral requires a nonempty find and a replacement string.")
                }
            default:
                guard step.find == nil, step.replacement == nil else {
                    throw AutomationError.invalid("Only replaceLiteral accepts find/replacement; removeMatchingLines accepts find only.")
                }
            }
        }
    }
    func transform(_ input: String) throws -> String {
        try validate()
        var result = input
        var regexTimeRemaining: TimeInterval = 0.1
        for step in steps {
            switch step.kind {
            case .removeMatchingLines:
                let regex = try NSRegularExpression(pattern: step.find!)
                var timedOut = false
                result = Self.mapLines(result) { line in
                    guard !timedOut else { return line }
                    let range = NSRange(line.startIndex..., in: line)
                    let started = ProcessInfo.processInfo.systemUptime
                    var matched = false
                    regex.enumerateMatches(in: line, options: [.reportProgress], range: range) { match, _, stop in
                        if ProcessInfo.processInfo.systemUptime - started > regexTimeRemaining {
                            timedOut = true; stop.pointee = true; return
                        }
                        if let match {
                            // Whole-line matches only: a keyword inside an ingredient cannot erase it.
                            matched = match.range == range
                            stop.pointee = true
                        }
                    }
                    regexTimeRemaining -= ProcessInfo.processInfo.systemUptime - started
                    if regexTimeRemaining <= 0 { timedOut = true }
                    return matched ? "" : line
                }
                guard !timedOut else {
                    throw AutomationError.invalid("The line-matching pattern exceeded its time limit. Nothing was changed. Simplify the removeMatchingLines regex or use literal replacement steps.")
                }
            case .replaceLiteral:
                result = result.replacingOccurrences(of: step.find!, with: step.replacement!)
            case .removeListMarkers:
                result = Self.mapLines(result) { line in
                    // No numeric prefixes: "2 eggs" and "1. 5 cups" may be quantities.
                    // Strip only an explicit bullet followed by whitespace, preserving other text.
                    line.replacingOccurrences(of: "^[\\t ]*[-*•][\\t ]+", with: "", options: .regularExpression)
                }
            case .keepMarkedListRows:
                let parts = try Self.lines(result)
                let marked = parts.lines.filter { line in
                    line.range(of: #"^[ \t]*(?:[-*•][ \t]+|(?:\*{1,3}|_{1,3})?(?:[▢☐☑☒□]|\[[ xX]\](?:[ \t]+|$)))"#, options: .regularExpression) != nil
                }
                // Markers distinguish list data, but cannot establish that an unmarked
                // ingredient/continuation is a heading. Fail before changing the document.
                if !marked.isEmpty {
                    for (index, line) in parts.lines.enumerated() {
                        if marked.contains(line) || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                        let heading = line.range(of: #"^[ \t]{0,3}#{1,6}(?:[ \t]+|$)"#, options: .regularExpression) != nil
                        let colonLabel = line.range(of: #"^[ \t]*[\p{L}][^:]*:[ \t]*$"#, options: .regularExpression) != nil
                        guard heading || colonLabel else {
                            throw AutomationError.invalid("Line \(index + 1) has no list marker: ‘\(line.prefix(100))’. Nothing was changed. If it is a heading, prefix it with # and a space; if it is an item or continuation, add a bullet. Or remove keepMarkedListRows from this automation to preserve all lines.")
                        }
                    }
                    result = marked.joined(separator: parts.eol) + (parts.trailing ? parts.eol : "")
                }
            case .removeMarkdownHeadings:
                result = Self.mapLines(result) { line in
                    // ATX headings only. A hashtag or an ordinary ingredient is not a heading.
                    line.range(of: #"^[ \t]{0,3}#{1,6}(?:[ \t]+|$)"#, options: .regularExpression) == nil ? line : ""
                }
            case .removeMarkdownFormatting:
                result = Self.mapLines(result, Self.removeInlineMarkdown)
            case .removeCheckboxMarkers:
                result = Self.mapLines(result) { line in
                    line.replacingOccurrences(of: #"^[ \t]*(?:[▢☐☑☒□][ \t]*|\[[ xX]\](?:[ \t]+|$))"#, with: "", options: .regularExpression)
                }
            case .removeNoteReferences:
                result = Self.mapLines(result, Self.removeNotes)
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
    private static func removeInlineMarkdown(_ line: String) -> String {
        var result = inlineLinksToLabels(line)
        // Deliberately bounded inline syntax, not a Markdown renderer. Pair delimiters
        // before unescaping so escaped literal stars/underscores are not mistaken for markup.
        let pairs: [(String,String)] = [
            (#"(?<!\\)\*\*(?=\S)(.+?)(?<=\S)(?<!\\)\*\*"#, "$1"),
            (#"(?<![\\\w])__(?=\S)(.+?)(?<=\S)(?<!\\)__(?!\w)"#, "$1"),
            (#"(?<![\\*])\*(?=\S)(.+?)(?<=\S)(?<!\\)\*(?!\*)"#, "$1"),
            (#"(?<![\\\w])_(?=\S)(.+?)(?<=\S)(?<!\\)_(?!\w)"#, "$1"),
            (#"(?<!\\)`([^`]+)`"#, "$1")
        ]
        // Two passes handle common nesting while bounding runtime; unmatched markers stay data.
        for _ in 0..<2 {
            for (pattern,replacement) in pairs {
                result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
            }
        }
        result = result.replacingOccurrences(of: #"\\([\\*`_\[\]])"#, with: "$1", options: .regularExpression)
        if result != line {
            // Delimiter padding in copied Markdown can leave a space before a comma.
            result = result.replacingOccurrences(of: #"[ \t]+(?=[,;])"#, with: "", options: .regularExpression)
        }
        return result
    }
    private static func inlineLinksToLabels(_ line: String) -> String {
        // Scan balanced labels/destinations instead of greedily deleting ingredient parentheses.
        // Links are never opened or fetched. Malformed/reference-style links remain unchanged.
        let chars = Array(line); var out = ""; var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count {
                out.append(chars[index]);out.append(chars[index+1]);index += 2;continue
            }
            guard chars[index] == "[" else {out.append(chars[index]);index += 1;continue}
            var close = index + 1, depth = 1
            while close < chars.count && depth > 0 {
                if chars[close] == "\\", close + 1 < chars.count {close += 2;continue}
                if chars[close] == "[" {depth += 1}
                if chars[close] == "]" {depth -= 1}
                if depth > 0 {close += 1}
            }
            guard depth == 0, close + 1 < chars.count, chars[close+1] == "(" else {out.append(chars[index]);index += 1;continue}
            var end = close + 2; depth = 1
            while end < chars.count && depth > 0 {
                if chars[end] == "\\", end + 1 < chars.count {end += 2;continue}
                if chars[end] == "(" {depth += 1}
                if chars[end] == ")" {depth -= 1}
                if depth > 0 {end += 1}
            }
            guard depth == 0 else {out.append(chars[index]);index += 1;continue}
            out += String(chars[(index+1)..<close]);index = end + 1
        }
        return out
    }
    private static func removeNotes(_ line: String) -> String {
        // Remove explicit Note N references only, keeping other parenthetical options.
        let note = #"(?:see[ \t]+)?Notes?[ \t]+[0-9]+(?:[ \t]*(?:,|and|–|-)[ \t]*[0-9]+)*"#
        var result = line.replacingOccurrences(of: #"(?i)[\(\[][ \t]*"# + note + #"[ \t]*[\)\]]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)[,;][ \t]*"# + note + #"\b"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b"# + note + #"\b"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
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
