// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

package struct AutomationDefinition: Codable, Equatable, Identifiable, Sendable {
    package init(
        version: Int = 1, id: UUID, name: String, input: Input, steps: [Step], output: Output, shortcut: String? = nil,
        destinationID: String? = nil, previewBeforeApply: Bool? = nil, pinToToolbar: Bool? = nil
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.input = input
        self.steps = steps
        self.output = output
        self.shortcut = shortcut
        self.destinationID = destinationID
        self.previewBeforeApply = previewBeforeApply
        self.pinToToolbar = pinToToolbar
    }

    package enum Input: String, Codable, CaseIterable, Sendable {
        case selection, document, clipboard, file
        package var displayName: String {
            switch self {
            case .selection: return Strings.text("automation.selected_text", "Selected text")
            case .document: return Strings.text("automation.document", "Document")
            case .clipboard: return Strings.text("automation.clipboard", "Clipboard")
            case .file: return Strings.text("automation.file", "File")
            }
        }
    }
    package enum Output: String, Codable, CaseIterable, Sendable {
        case editor, clipboard, newDocument, file, reminders
        package var displayName: String {
            switch self {
            case .editor: return Strings.text("automation.captured_document", "Captured document")
            case .clipboard: return Strings.text("automation.clipboard", "Clipboard")
            case .newDocument: return Strings.text("automation.new_document", "New document")
            case .file: return Strings.text("automation.file", "File")
            case .reminders: return Strings.text("automation.reminders", "Reminders")
            }
        }
    }
    package struct Step: Codable, Equatable, Sendable {
        package init(
            kind: Kind, find: String? = nil, replacement: String? = nil, askForFind: Bool? = nil,
            askForReplacement: Bool? = nil
        ) {
            self.kind = kind
            self.find = find
            self.replacement = replacement
            self.askForFind = askForFind
            self.askForReplacement = askForReplacement
        }

        /// Raw values are the persisted spellings in Automations.json and rule files and never
        /// change. The five `clear…` kinds empty a matching line and keep its line ending, so their
        /// Swift names say "clear" although the stored spelling says "remove".
        package enum Kind: String, Codable, CaseIterable, Sendable {
            case removeListMarkers, removeBlankLines, sortLines, deduplicateLines, replaceLiteral
            case clearLinesEqualTo = "removeLinesEqualTo"
            case clearLinesContaining = "removeLinesContaining"
            case clearLinesStartingWith = "removeLinesStartingWith"
            case trimWhitespace
            case clearLinesMatching = "removeMatchingLines"
            case clearMarkdownHeadings = "removeMarkdownHeadings"
            case removeMarkdownFormatting, removeCheckboxMarkers, removeNoteReferences, keepMarkedListRows
            /// Locale-aware order (`LineOrder.localizedAscending`); `sortLines` stays code-point order.
            case sortLinesLocalized
        }
        package var kind: Kind
        package var find: String?
        package var replacement: String?
        package var askForFind: Bool?
        package var askForReplacement: Bool?
    }
    package var version: Int
    package var id: UUID
    package var name: String
    package var input: Input
    package var steps: [Step]
    package var output: Output
    /// A single ASCII letter. UI binds Command-Option-letter and rejects collisions.
    package var shortcut: String?
    package var destinationID: String?
    /// Older definitions decode without these keys. False means apply local output directly;
    /// external connectors still require their own explicit destination/send confirmation.
    package var previewBeforeApply: Bool?
    package var pinToToolbar: Bool?

    /// The whole-line recipe controls the built-in recipe cleanup clears.
    static package let recipeHeadingPattern =
        #"(?i)^[ \t]*(?:Ingredients|Cups|Metric|Garnish[ \t]*\(optional\))[ \t]*$"#
    /// An unmarked line that starts with a letter and ends in a colon: a section label.
    static package let colonLabelPattern = #"^[ \t]*[\p{L}][^:]*:[ \t]*$"#
    /// The first-run preset: a strict, marker-based recipe cleanup. Its name says so, because it
    /// refuses a list that mixes marked rows with unmarked rows instead of guessing.
    static package var example: AutomationDefinition {
        AutomationDefinition(
            id: UUID(uuidString: "A931733F-310A-4EBF-9C48-38C59202D586")!, name: "Clean up recipe list",
            input: .document,
            steps: [
                Step(kind: .clearLinesMatching, find: recipeHeadingPattern),
                Step(kind: .keepMarkedListRows), Step(kind: .clearMarkdownHeadings), Step(kind: .removeListMarkers),
                Step(kind: .removeMarkdownFormatting), Step(kind: .removeCheckboxMarkers),
                Step(kind: .removeNoteReferences), Step(kind: .trimWhitespace), Step(kind: .removeBlankLines)
            ],
            output: .editor, previewBeforeApply: false, pinToToolbar: true)
    }
    static package var remindersExample: AutomationDefinition {
        AutomationDefinition(
            id: UUID(uuidString: "AE932D35-4371-4D64-9091-95780DCD2441")!, name: "Add to Reminders", input: .document,
            steps: [Step(kind: .removeBlankLines)], output: .reminders,
            previewBeforeApply: false, pinToToolbar: true)
    }
    /// A saved definition may leave the text of an "ask when running" rule empty. A definition that
    /// is about to run or be tested must have every value; `requiringValues` checks that.
    package func validate() throws { try validate(requiringValues: false) }
    private func validate(requiringValues: Bool) throws {
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
        for (index, step) in steps.enumerated() {
            try step.validate(requiringValues: requiringValues, position: index + 1)
        }
    }
    /// The first-run automations, in menu order. Restore Default Automations appends fresh copies.
    static package var firstRunPresets: [AutomationDefinition] { [.example, .remindersExample] }
    /// Test Rules: the rules alone against a sample. The automation's name, shortcut, input and
    /// output play no part, so an unfinished name in the builder cannot fail a test.
    static package func testRules(_ steps: [Step], sample: String, control: AutomationRunControl? = nil) throws
        -> String
    {
        try AutomationDefinition(id: UUID(), name: "Rule test", input: .document, steps: steps, output: .editor)
            .testSample(sample, control: control)
    }
    /// Resolves only explicitly configured prompts. Cancelling any prompt cancels the whole run.
    package func resolvingParameters(_ ask: (Int, String, String) throws -> String?) throws -> AutomationDefinition? {
        try validate()
        var resolved = self
        for index in steps.indices {
            if steps[index].askForFind == true {
                guard let value = try ask(index, steps[index].kind.findTitle, steps[index].find ?? "") else {
                    return nil
                }
                resolved.steps[index].find = value
            }
            if steps[index].askForReplacement == true {
                guard let value = try ask(index, Step.Kind.replacementTitle, steps[index].replacement ?? "") else {
                    return nil
                }
                resolved.steps[index].replacement = value
            }
        }
        try resolved.validate(requiringValues: true)
        return resolved
    }
    package func transform(_ input: String, control: AutomationRunControl? = nil) throws -> String {
        try validate(requiringValues: true)
        try control?.checkCancellation()
        guard input.utf8.count <= Self.maximumTransformBytes else {
            throw AutomationError.invalid("Automation input exceeds 32 MiB. Nothing was changed.")
        }
        var result = input
        var regexTimeRemaining = Self.regexBudget
        for (index, step) in steps.enumerated() {
            try control?.checkpoint(completed: index, total: steps.count)
            result = try Self.apply(step, to: result, regexTimeRemaining: &regexTimeRemaining, control: control)
        }
        try control?.checkpoint(completed: steps.count, total: steps.count)
        return result
    }
    /// One run, or one sample test, spends at most this long inside pattern matching, summed over
    /// every pattern rule and every line.
    static package let regexBudget: TimeInterval = 0.1
    /// The fixed cost of asking the regex engine about one cheap line is not charged to the budget,
    /// so the number of lines alone can never exhaust it.
    static package let regexPerLineAllowance: TimeInterval = 0.000_005
    /// Compiles a pattern for the whole-line rule. The pattern is compiled as typed first, so
    /// validation errors describe the user's own text. It is then wrapped as `\A(?:…)\z`, which makes
    /// the engine try every alternative that could cover the line. A pattern that is valid as typed
    /// but not when wrapped (free-spacing ending in a comment, an unterminated `\Q`) keeps the plain
    /// form, and the caller compares the first match with the line instead.
    static package func wholeLineRegex(_ pattern: String) throws -> (regex: NSRegularExpression, anchored: Bool) {
        let plain = try NSRegularExpression(pattern: pattern)
        if let wrapped = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z"),
            wrapped.numberOfCaptureGroups == plain.numberOfCaptureGroups
        {
            return (wrapped, true)
        }
        return (plain, false)
    }
    private static let markedRowPattern =
        #"^[ \t]*(?:[-*•][ \t]+|(?:\*{1,3}|_{1,3})?(?:[▢☐☑☒□]|\[[ xX]\](?:[ \t]+|$)))"#
    private static let atxHeadingPattern = #"^[ \t]{0,3}#{1,6}(?:[ \t]+|$)"#
    /// One rule applied to the whole text. A run and a sample test both go through here and pass
    /// the same regex budget along, so they follow the same rules.
    private static func apply(
        _ step: Step, to input: String, regexTimeRemaining: inout TimeInterval, control: AutomationRunControl?
    ) throws -> String {
        var result = input
        switch step.kind {
        case .clearLinesEqualTo, .clearLinesContaining, .clearLinesStartingWith:
            // Literal means the same scalars, as in Find: no canonical-equivalence or
            // grapheme-boundary matching.
            let needle = step.find ?? ""
            result = try mapLines(result, control: control) { line in
                let matches: Bool
                switch step.kind {
                case .clearLinesEqualTo: matches = line.utf8.elementsEqual(needle.utf8)
                case .clearLinesContaining:
                    matches = (line as NSString).range(of: needle, options: .literal).location != NSNotFound
                default: matches = line.utf8.starts(with: needle.utf8)
                }
                return matches ? "" : line
            }
        case .trimWhitespace:
            // Unicode spaces and tab: web-copied text often carries no-break spaces.
            result = try mapLines(result, control: control) { $0.trimmingCharacters(in: .whitespaces) }
        case .clearLinesMatching:
            let (regex, anchored) = try wholeLineRegex(step.find ?? "")
            var timedOut = false
            var remaining = regexTimeRemaining
            result = try mapLines(result, control: control) { line in
                guard !timedOut else { return line }
                let range = NSRange(line.startIndex..., in: line)
                let started = ProcessInfo.processInfo.systemUptime
                var matched = false
                regex.enumerateMatches(in: line, options: [.reportProgress], range: range) { match, _, stop in
                    if ProcessInfo.processInfo.systemUptime - started > remaining {
                        timedOut = true
                        stop.pointee = true
                        return
                    }
                    if let match {
                        // Whole-line matches only: a keyword inside an ingredient cannot erase it.
                        matched = anchored || match.range == range
                        stop.pointee = true
                    }
                }
                remaining -= max(0, ProcessInfo.processInfo.systemUptime - started - regexPerLineAllowance)
                if remaining <= 0 { timedOut = true }
                return matched ? "" : line
            }
            regexTimeRemaining = remaining
            guard !timedOut else {
                throw AutomationError.invalid(
                    "The line-matching pattern exceeded its time limit. Nothing was changed. Simplify the removeMatchingLines regex or use literal replacement steps."
                )
            }
        case .replaceLiteral:
            result = try boundedReplacement(
                result, find: step.find ?? "", replacement: step.replacement ?? "", control: control)
        case .removeListMarkers:
            result = try mapLines(result, control: control) { line in
                // No numeric prefixes: "2 eggs" and "1. 5 cups" may be quantities.
                // Strip only an explicit bullet followed by whitespace, preserving other text.
                line.replacingOccurrences(of: "^[\\t ]*[-*•][\\t ]+", with: "", options: .regularExpression)
            }
        case .keepMarkedListRows:
            let parts = try lines(result)
            try control?.checkCancellation()
            // Whether a row is marked depends only on its own text, so each row is classified once.
            var isMarked = [Bool](repeating: false, count: parts.lines.count)
            var anyMarked = false
            for (index, line) in parts.lines.enumerated() {
                if index % 4096 == 0 { try control?.checkCancellation() }
                if line.range(of: markedRowPattern, options: .regularExpression) != nil {
                    isMarked[index] = true
                    anyMarked = true
                }
            }
            // Markers distinguish list data, but cannot establish that an unmarked
            // ingredient/continuation is a heading. Fail before changing the document.
            if anyMarked {
                var marked: [String] = []
                for (index, line) in parts.lines.enumerated() {
                    if index % 4096 == 0 { try control?.checkCancellation() }
                    if isMarked[index] {
                        marked.append(line)
                        continue
                    }
                    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    let heading = line.range(of: atxHeadingPattern, options: .regularExpression) != nil
                    let colonLabel = line.range(of: colonLabelPattern, options: .regularExpression) != nil
                    guard heading || colonLabel else {
                        throw AutomationError.invalid(
                            "Line \(index + 1) has no list marker: ‘\(line.prefix(100))’. Nothing was changed. If it is a heading, prefix it with # and a space; if it is an item or continuation, add a bullet. Or remove keepMarkedListRows from this automation to preserve all lines."
                        )
                    }
                }
                try control?.checkCancellation()
                result = marked.joined(separator: parts.eol) + (parts.trailing ? parts.eol : "")
            }
        case .clearMarkdownHeadings:
            result = try mapLines(result, control: control) { line in
                // ATX headings only. A hashtag or an ordinary ingredient is not a heading.
                line.range(of: atxHeadingPattern, options: .regularExpression) == nil ? line : ""
            }
        case .removeMarkdownFormatting:
            result = try mapLines(result, control: control) {
                try removeInlineMarkdown($0, control: control)
            }
        case .removeCheckboxMarkers:
            result = try mapLines(result, control: control) { line in
                line.replacingOccurrences(
                    of: #"^[ \t]*(?:[▢☐☑☒□][ \t]*|\[[ xX]\](?:[ \t]+|$))"#, with: "", options: .regularExpression)
            }
        case .removeNoteReferences:
            result = try mapLines(result, control: control, removeNotes)
        case .removeBlankLines, .sortLines, .sortLinesLocalized, .deduplicateLines:
            // Splitting, sorting and joining cannot be interrupted, so cancellation is checked
            // between them; the locale-aware comparator, the slow one, also checks as it goes.
            let parts = try lines(result)
            try control?.checkCancellation()
            var body = parts.lines
            if step.kind == .removeBlankLines { body.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
            if step.kind == .sortLines { body.sort(by: LineOrder.codePointAscending) }
            if step.kind == .sortLinesLocalized {
                var comparisons = 0
                try body.sort { a, b in
                    comparisons += 1
                    if comparisons % 4096 == 0 { try control?.checkCancellation() }
                    return LineOrder.localizedAscending(a, b)
                }
            }
            if step.kind == .deduplicateLines {
                // Byte-exact, as Remove Duplicate Lines in the Edit menu: canonically equivalent
                // spellings are different rows.
                var seen = Set<Data>()
                body = body.filter { seen.insert(Data($0.utf8)).inserted }
            }
            try control?.checkCancellation()
            result = body.joined(separator: parts.eol) + (parts.trailing && !body.isEmpty ? parts.eol : "")
        }
        guard result.utf8.count <= maximumTransformBytes else {
            throw AutomationError.invalid("Automation result exceeds 32 MiB. Nothing was changed.")
        }
        return result
    }
    static package let maximumTransformBytes = 32 * 1024 * 1024
    private static func boundedReplacement(
        _ input: String, find: String, replacement: String, control: AutomationRunControl?
    ) throws -> String {
        let source = input as NSString
        var cursor = 0, output = "", bytes = 0
        func append(_ part: String) throws {
            try control?.checkCancellation()
            let count = part.utf8.count
            guard count <= maximumTransformBytes - bytes else {
                throw AutomationError.invalid("Automation result exceeds 32 MiB. Nothing was changed.")
            }
            bytes += count
            output.append(contentsOf: part)
        }
        while cursor < source.length {
            try control?.checkCancellation()
            let range = source.range(
                of: find, options: .literal, range: NSRange(location: cursor, length: source.length - cursor))
            if range.location == NSNotFound { break }
            try append(source.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            try append(replacement)
            cursor = NSMaxRange(range)
        }
        try append(source.substring(from: cursor))
        return output
    }
    /// Draft-only test harness: never resolves inputs/parameters or invokes an output.
    package func testSample(_ input: String, control: AutomationRunControl? = nil) throws -> String {
        try validate(requiringValues: true)
        guard input.utf8.count <= 65536 else { throw AutomationError.invalid("Use a sample of at most 64 KiB.") }
        var text = input
        let started = ProcessInfo.processInfo.systemUptime
        // One budget for every pattern rule, exactly as in a run.
        var regexTimeRemaining = Self.regexBudget
        for step in steps {
            try control?.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < 2 else {
                throw AutomationError.invalid(
                    "Sample test exceeded two seconds. Simplify the rules or use a smaller sample.")
            }
            if step.kind == .replaceLiteral, let find = step.find, let replacement = step.replacement {
                // Conservative bound before allocating expanded replacement text.
                let possibleMatches = text.utf8.count / max(1, find.utf8.count)
                guard replacement.utf8.count <= 1_048_576,
                    possibleMatches <= (1_048_576 - min(text.utf8.count, 1_048_576)) / max(1, replacement.utf8.count)
                else {
                    throw AutomationError.invalid(
                        "This replacement could exceed the 1 MiB sample-result limit. Use a smaller sample or replacement."
                    )
                }
            }
            text = try Self.apply(step, to: text, regexTimeRemaining: &regexTimeRemaining, control: control)
            guard text.utf8.count <= 1_048_576 else { throw AutomationError.invalid("Sample result exceeds 1 MiB.") }
        }
        try control?.checkpoint(completed: steps.count, total: steps.count)
        try control?.checkCancellation()
        return text
    }
    /// Emphasis pairs, then code spans. The flag says whether the pair also takes its padding.
    private static let inlinePairs: [(NSRegularExpression, Bool)] = [
        (#"(?<!\\)\*\*(?=\S)(.+?)(?<=\S)(?<!\\)\*\*"#, true),
        (#"(?<![\\\w])__(?=\S)(.+?)(?<=\S)(?<!\\)__(?!\w)"#, true),
        (#"(?<![\\*])\*(?=\S)(.+?)(?<=\S)(?<!\\)\*(?!\*)"#, true),
        (#"(?<![\\\w])_(?=\S)(.+?)(?<=\S)(?<!\\)_(?!\w)"#, true),
        (#"(?<!\\)`([^`]+)`"#, false)
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    /// Replaces each delimited span with its content. Copied Markdown pads an emphasised
    /// continuation as "each) *, halved*", so a pair whose content starts with a comma or semicolon
    /// also takes the spaces directly before its opening delimiter. No other spacing on the line
    /// is touched, and a delimiter that has no partner keeps its padding.
    private static func unwrap(_ text: String, pair: NSRegularExpression, takesPadding: Bool) -> String {
        let source = text as NSString
        var output = "", cursor = 0
        pair.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match else { return }
            let content = match.range(at: 1)
            var end = match.range.location
            let first = source.character(at: content.location)
            if takesPadding, first == 0x2C || first == 0x3B {
                while end > cursor, source.character(at: end - 1) == 0x20 || source.character(at: end - 1) == 0x09 {
                    end -= 1
                }
            }
            output += source.substring(with: NSRange(location: cursor, length: end - cursor))
            output += source.substring(with: content)
            cursor = NSMaxRange(match.range)
        }
        return cursor == 0 ? text : output + source.substring(from: cursor)
    }
    private static func removeInlineMarkdown(_ line: String, control: AutomationRunControl?) throws -> String {
        var result = try inlineLinksToLabels(line, control: control)
        // Deliberately bounded inline syntax, not a Markdown renderer. Pair delimiters
        // before unescaping so escaped literal stars/underscores are not mistaken for markup.
        // Two passes handle common nesting while bounding runtime; unmatched markers stay data.
        for _ in 0..<2 {
            for (pair, takesPadding) in inlinePairs {
                try control?.checkCancellation()
                result = unwrap(result, pair: pair, takesPadding: takesPadding)
            }
        }
        result = result.replacingOccurrences(of: #"\\([\\*`_\[\]])"#, with: "$1", options: .regularExpression)
        return result
    }
    private static func inlineLinksToLabels(_ line: String, control: AutomationRunControl?) throws -> String {
        // Scan balanced labels/destinations instead of greedily deleting ingredient parentheses.
        // Links are never opened or fetched. Malformed/reference-style links remain unchanged.
        let chars = Array(line)
        var out = ""
        var index = 0
        var nextCheckpoint = 0
        func checkpoint(_ position: Int) throws {
            if position >= nextCheckpoint {
                try control?.checkCancellation()
                nextCheckpoint = position + 4096
            }
        }
        while index < chars.count {
            try checkpoint(index)
            if chars[index] == "\\", index + 1 < chars.count {
                out.append(chars[index])
                out.append(chars[index + 1])
                index += 2
                continue
            }
            guard chars[index] == "[" else {
                out.append(chars[index])
                index += 1
                continue
            }
            var close = index + 1, depth = 1
            while close < chars.count && depth > 0 {
                try checkpoint(close)
                if chars[close] == "\\", close + 1 < chars.count {
                    close += 2
                    continue
                }
                if chars[close] == "[" { depth += 1 }
                if chars[close] == "]" { depth -= 1 }
                if depth > 0 { close += 1 }
            }
            guard depth == 0 else {
                out += String(chars[index...])
                break
            }
            guard close + 1 < chars.count, chars[close + 1] == "(" else {
                out += String(chars[index...close])
                index = close + 1
                continue
            }
            var end = close + 2
            depth = 1
            while end < chars.count && depth > 0 {
                try checkpoint(end)
                if chars[end] == "\\", end + 1 < chars.count {
                    end += 2
                    continue
                }
                if chars[end] == "(" { depth += 1 }
                if chars[end] == ")" { depth -= 1 }
                if depth > 0 { end += 1 }
            }
            guard depth == 0 else {
                out += String(chars[index...])
                break
            }
            out += String(chars[(index + 1)..<close])
            index = end + 1
        }
        return out
    }
    private static func removeNotes(_ line: String) -> String {
        // Remove explicit Note N references only, keeping other parenthetical options.
        let note = #"(?:see[ \t]+)?Notes?[ \t]+[0-9]+(?:[ \t]*(?:,|and|–|-)[ \t]*[0-9]+)*"#
        var result = line.replacingOccurrences(
            of: #"(?i)[\(\[][ \t]*"# + note + #"[ \t]*[\)\]]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?i)[,;][ \t]*"# + note + #"\b"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b"# + note + #"\b"#, with: "", options: .regularExpression)
        // Tidy the gap a removed reference leaves, and only on a line that had one.
        return result == line ? line : result.trimmingCharacters(in: .whitespaces)
    }
    private static func lines(_ text: String) throws -> (lines: [String], eol: String, trailing: Bool) {
        // Classify by bytes. CR+LF is one Character in Swift, so character-based searches miss
        // a lone CR or LF that sits next to a CRLF.
        var cr = false, lf = false, crlf = false, priorCR = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if priorCR { crlf = true } else { lf = true }
                priorCR = false
            } else {
                if priorCR { cr = true }
                priorCR = byte == 0x0D
            }
        }
        if priorCR { cr = true }
        guard [cr, lf, crlf].filter({ $0 }).count <= 1 else {
            throw AutomationError.invalid(
                "Line filtering/reordering requires uniform line endings. Mixed endings were not changed.")
        }
        let eol = crlf ? "\r\n" : (cr ? "\r" : "\n")
        var lines = text.components(separatedBy: eol)
        let trailing = text.hasSuffix(eol)
        if trailing { lines.removeLast() }
        return (lines, eol, trailing)
    }
    private static func mapLines(_ text: String, control: AutomationRunControl?, _ transform: (String) throws -> String)
        throws -> String
    {
        // Preserve each exact separator, including mixed line endings.
        var output = "", line = ""
        for (index, scalar) in text.unicodeScalars.enumerated() {
            if index % 4096 == 0 { try control?.checkCancellation() }
            if scalar == "\r" || scalar == "\n" {
                output += try transform(line)
                output.unicodeScalars.append(scalar)
                line = ""
            } else {
                line.unicodeScalars.append(scalar)
            }
        }
        return output + (try transform(line))
    }
}

extension AutomationDefinition.Step.Kind {
    /// The name the rule builder shows. Advanced JSON and rule files use `rawValue`.
    package var label: String {
        switch self {
        case .removeListMarkers: return "Remove bullet markers"
        case .removeBlankLines: return "Remove empty lines"
        case .sortLines: return "Sort lines (case-sensitive)"
        case .sortLinesLocalized: return "Sort lines in locale order"
        case .deduplicateLines: return "Remove duplicate lines"
        case .replaceLiteral: return "Find and replace text"
        case .clearLinesEqualTo: return "Clear lines equal to text"
        case .clearLinesContaining: return "Clear lines containing text"
        case .clearLinesStartingWith: return "Clear lines starting with text"
        case .trimWhitespace: return "Trim spaces at line edges"
        case .clearLinesMatching: return "Clear lines matching a pattern (advanced)"
        case .clearMarkdownHeadings: return "Clear Markdown headings"
        case .removeMarkdownFormatting: return "Remove Markdown formatting"
        case .removeCheckboxMarkers: return "Remove checkbox markers"
        case .removeNoteReferences: return "Remove numbered note references"
        case .keepMarkedListRows: return "Keep marked list rows (strict)"
        }
    }
    /// The one list of kinds that take text to match. Validation, the rule dialog and the JSON
    /// reference all read it here.
    package var acceptsFind: Bool {
        switch self {
        case .replaceLiteral, .clearLinesMatching, .clearLinesEqualTo, .clearLinesContaining,
            .clearLinesStartingWith:
            return true
        default: return false
        }
    }
    package var acceptsReplacement: Bool { self == .replaceLiteral }
    /// The kind whose text to match is a regular expression.
    package var findIsPattern: Bool { self == .clearLinesMatching }
    /// What the rule dialog and the run-time prompt call the text to match for this kind.
    package var findTitle: String { findIsPattern ? "Pattern" : "Text to match" }
    /// What the rule dialog and the run-time prompt call the replacement.
    static package let replacementTitle = "Replace with"
    /// Both names, for a message that the rule builder and the JSON editor each show.
    package var described: String { "“\(label)” (\(rawValue) in JSON)" }
    /// The JSON fields this kind takes, for the reference.
    package var parameters: String {
        guard acceptsFind else { return "no parameters" }
        let find = findIsPattern ? "find (whole-line regular expression)" : "find (literal text)"
        return acceptsReplacement
            ? find + ", replacement, askForFind, askForReplacement" : find + ", askForFind"
    }
}

extension AutomationDefinition.Step {
    /// One rule on its own, as `AutomationDefinition.validate` applies it to every rule. `position`
    /// is the rule's 1-based place in its list, when it has one.
    package func validate(requiringValues: Bool = false, position: Int? = nil) throws {
        if askForFind == true && !kind.acceptsFind {
            throw AutomationError.invalid(
                "\(kind.described) takes no text to match, so it cannot ask for one when running.")
        }
        if askForReplacement == true && !kind.acceptsReplacement {
            throw AutomationError.invalid(
                "\(kind.described) takes no replacement, so it cannot ask for one when running.")
        }
        // The text may be left empty only when the rule asks for it at run time.
        let awaitsValue = askForFind == true && (find ?? "").isEmpty
        if awaitsValue && requiringValues {
            throw AutomationError.invalid(
                "\(position.map { "Rule \($0)" } ?? "This rule") needs a value: it asks for its text when running and none was supplied. Nothing was changed."
            )
        }
        guard kind.acceptsFind else {
            guard find == nil, replacement == nil else {
                throw AutomationError.invalid("\(kind.described) takes no text to match and no replacement.")
            }
            return
        }
        if kind.findIsPattern {
            let pattern = find ?? ""
            guard awaitsValue || !pattern.isEmpty, pattern.count <= 500, replacement == nil else {
                throw AutomationError.invalid(
                    "\(kind.described) needs a pattern of 1–500 characters and takes no replacement.")
            }
            if !pattern.isEmpty {
                do { _ = try AutomationDefinition.wholeLineRegex(pattern) } catch {
                    throw AutomationError.invalid(
                        "The pattern for \(kind.described) is not a valid regular expression: \(error.localizedDescription)"
                    )
                }
            }
        } else if kind.acceptsReplacement {
            guard awaitsValue || !(find ?? "").isEmpty, replacement != nil else {
                throw AutomationError.invalid(
                    "\(kind.described) needs text to match and a replacement, which may be empty.")
            }
        } else {
            guard awaitsValue || !(find ?? "").isEmpty, replacement == nil else {
                throw AutomationError.invalid("\(kind.described) needs text to match and takes no replacement.")
            }
        }
    }
    /// The rule the Configure Rule dialog returns for its controls. A field the kind does not take
    /// is left out, and a prompt flag that is off is left out too, so a rule opened and saved
    /// unchanged compares equal to the one that was opened and adds no keys to an exported file.
    /// A flag stored as an explicit `false` stays `false` while the kind is unchanged.
    static package func configured(
        kind: Kind, find: String, replacement: String, askForFind: Bool, askForReplacement: Bool,
        from initial: AutomationDefinition.Step
    ) -> AutomationDefinition.Step {
        func flag(_ on: Bool, accepted: Bool, stored: Bool?) -> Bool? {
            guard accepted else { return nil }
            if on { return true }
            return kind == initial.kind && stored == false ? false : nil
        }
        return AutomationDefinition.Step(
            kind: kind, find: kind.acceptsFind ? find : nil, replacement: kind.acceptsReplacement ? replacement : nil,
            askForFind: flag(askForFind, accepted: kind.acceptsFind, stored: initial.askForFind),
            askForReplacement: flag(
                askForReplacement, accepted: kind.acceptsReplacement, stored: initial.askForReplacement))
    }
    /// One line for the rule list: the kind, its text, its replacement and whether it asks when run.
    package var summary: String {
        func quoted(_ text: String) -> String { "“\(text.replacingOccurrences(of: "\n", with: "↵").prefix(70))”" }
        var text = kind.label
        if let find { text += "  ·  " + quoted(find) }
        if let replacement { text += " → " + quoted(replacement) }
        switch (askForFind == true, askForReplacement == true) {
        case (true, true): text += "  ·  asks for both when run"
        case (true, false): text += "  ·  asks for the text when run"
        case (false, true): text += "  ·  asks for the replacement when run"
        case (false, false): break
        }
        return text
    }
}

extension AutomationDefinition {
    /// The rule kinds as Advanced JSON spells them, one line each, generated from `Kind.allCases`
    /// so that a new kind cannot be left out.
    static package var ruleKindReference: String {
        Step.Kind.allCases.map { "\($0.rawValue) — \($0.label). Takes \($0.parameters)." }.joined(separator: "\n")
    }
    static package var favoriteHelp: String {
        Strings.text(
            "automation.favorite.help",
            "Marking an automation as a favorite adds its toolbar button. Favorites also appear first in the Automations launcher and the editor context menu. The menu bar and Run Automation list keep the saved order."
        )
    }
    /// The help shown above the Advanced JSON editor; complete English fallback, not fragments.
    static package var advancedHelp: String {
        Strings.text(
            "automation.advanced.help",
            "Edit the JSON below. Rename by changing name and keeping id unchanged. Input: selection, document, clipboard, file. Output: editor, clipboard, newDocument, file, reminders. Each entry of steps has a kind from the list below and only the fields that kind takes. Set askForFind or askForReplacement true to be asked for that text on every run. Optional shortcut: one lowercase letter, bound to Command-Option. Set previewBeforeApply true for a preview before the result is applied. Set pinToToolbar true to mark the automation as a favorite. Marking an automation as a favorite adds its toolbar button. Favorites also appear first in the Automations launcher and the editor context menu. The menu bar and Run Automation list keep the saved order. No automation runs when saved or imported."
        )
    }
}

/// The rule builder's ordered list and its selected row. Every change keeps the selection on a
/// row that exists and refuses to pass the rule limit; a method returns false when it did nothing.
package struct RuleListDraft: Equatable {
    static package let maximumRules = 100
    private(set) package var steps: [AutomationDefinition.Step]
    private(set) package var selected: Int?
    package init(_ steps: [AutomationDefinition.Step]) {
        self.steps = steps
        selected = steps.isEmpty ? nil : 0
    }
    package var canAdd: Bool { steps.count < Self.maximumRules }
    package var canDuplicate: Bool { selected != nil && canAdd }
    package var canMoveUp: Bool { (selected ?? 0) > 0 }
    package var canMoveDown: Bool { selected.map { $0 + 1 < steps.count } ?? false }
    /// Follows the list's own selection: a row that does not exist means no selection.
    mutating package func select(_ row: Int) { selected = steps.indices.contains(row) ? row : nil }
    private mutating func settle(on row: Int) { selected = steps.isEmpty ? nil : max(0, min(row, steps.count - 1)) }
    mutating package func add(_ step: AutomationDefinition.Step) -> Bool {
        guard canAdd else { return false }
        steps.append(step)
        settle(on: steps.count - 1)
        return true
    }
    mutating package func replaceSelected(with step: AutomationDefinition.Step) -> Bool {
        guard let selected else { return false }
        steps[selected] = step
        return true
    }
    mutating package func duplicateSelected() -> Bool {
        guard let selected, canAdd else { return false }
        steps.insert(steps[selected], at: selected + 1)
        settle(on: selected + 1)
        return true
    }
    mutating package func removeSelected() -> Bool {
        guard let selected else { return false }
        steps.remove(at: selected)
        settle(on: selected)
        return true
    }
    mutating package func moveSelectedUp() -> Bool {
        guard let selected, canMoveUp else { return false }
        steps.swapAt(selected, selected - 1)
        settle(on: selected - 1)
        return true
    }
    mutating package func moveSelectedDown() -> Bool {
        guard let selected, canMoveDown else { return false }
        steps.swapAt(selected, selected + 1)
        settle(on: selected + 1)
        return true
    }
    /// Load Rules: the whole list is replaced and the first rule selected.
    mutating package func replaceAll(with replacement: [AutomationDefinition.Step]) {
        steps = replacement
        settle(on: 0)
    }
}

/// Which test outcome the rule builder may show. A test presents the token it was started with;
/// every later test, edit or close moves the generation on, so a late result is refused.
package struct RulePreviewState: Equatable {
    package init() {}

    private(set) package var generation = 0
    private(set) package var isRunning = false
    private(set) package var showsOutcome = false
    /// Starts a test and returns the token its outcome must present.
    mutating package func begin() -> Int {
        generation += 1
        isRunning = true
        showsOutcome = false
        return generation
    }
    /// True when the outcome belongs to the test that is still current and may be shown.
    mutating package func finish(_ token: Int) -> Bool {
        guard isRunning, token == generation else { return false }
        isRunning = false
        showsOutcome = true
        return true
    }
    /// An edit, or the builder closing. Returns whether an outcome was on show or a test under way,
    /// which is when the builder has something stale to say so about.
    mutating package func invalidate() -> Bool {
        let hadSomething = isRunning || showsOutcome
        generation += 1
        isRunning = false
        showsOutcome = false
        return hadSomething
    }
}

package enum AutomationError: LocalizedError {
    case invalid(String)
    package var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
package struct AutomationLibrary: VersionedLibrary, Equatable {
    package init(version: Int = 1, workflows: [AutomationDefinition]) {
        self.version = version
        self.workflows = workflows
    }

    static package let libraryContext = "Automations"
    static package var librarySizeError: Error { AutomationError.invalid("Automation configuration exceeds 32 MiB.") }
    static package let maximumBytes = 32 * 1024 * 1024
    package var version: Int
    package var workflows: [AutomationDefinition]
    package func validate() throws {
        guard version == 1 else { throw AutomationError.invalid("Unsupported library version \(version).") }
        guard workflows.count <= 200 else { throw AutomationError.invalid("At most 200 automations are supported.") }
        var ids = Set<UUID>(), keys = Set<String>()
        for workflow in workflows {
            try workflow.validate()
            guard ids.insert(workflow.id).inserted else {
                throw AutomationError.invalid(
                    "Workflow identifiers must be unique. Generate a new UUID when duplicating a workflow.")
            }
            if let key = workflow.shortcut, !key.isEmpty, !keys.insert(key).inserted {
                throw AutomationError.invalid("Two automations use Command-Option-\(key.uppercased()).")
            }
        }
    }
}

/// Shared by the worker and native progress controls; no editor escapes onto the worker queue.
final package class AutomationRunControl: @unchecked Sendable {
    package init() {}

    private let lock = NSLock()
    private var cancelled = false
    package var onProgress: ((Int, Int) -> Void)?
    package func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    package func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw AutomationError.invalid("Automation cancelled. Nothing was changed.") }
    }
    package func checkpoint(completed: Int, total: Int) throws {
        try checkCancellation()
        onProgress?(completed, total)
    }
}

/// Explicit file inputs are bounded regular UTF-8 files, never pipes/devices or followed symlinks.
package enum AutomationFileInput {
    static package func read(_ url: URL, limit: Int = 32 * 1024 * 1024) throws -> String {
        let data = try readData(url, limit: limit)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutomationError.invalid(
                "Automation file input requires valid UTF-8. Open the file with its encoding first.")
        }
        return text
    }
    /// A byte limit as a person reads it: "32 MiB", "64 KiB" or "2 bytes".
    static package func describe(limit: Int) -> String {
        if limit >= 1_048_576, limit % 1_048_576 == 0 { return "\(limit / 1_048_576) MiB" }
        if limit >= 1024, limit % 1024 == 0 { return "\(limit / 1024) KiB" }
        return "\(limit) bytes"
    }
    static package func readData(_ url: URL, limit: Int, parent: PrivateFileStore.ParentPolicy = .selectedInput) throws
        -> Data
    {
        guard url.isFileURL else { throw AutomationError.invalid("Choose a local text file.") }
        do { return try PrivateFileStore.read(url, maximumBytes: limit, parent: parent) } catch PrivateFileError
            .unsafeLocation
        {
            throw AutomationError.invalid("Automation input must be a regular file, not a folder, pipe or device.")
        } catch PrivateFileError.tooLarge {
            throw AutomationError.invalid(
                "This file is larger than the \(describe(limit: limit)) limit for this input.")
        }
    }
}

/// Portable processing rules only. Loading never changes a workflow's identity or output.
package struct AutomationRuleSet: VersionedLibrary {
    package init(version: Int = 1, name: String, steps: [AutomationDefinition.Step]) {
        self.version = version
        self.name = name
        self.steps = steps
    }

    static package let libraryContext = "Rules"
    static package var librarySizeError: Error { AutomationError.invalid("Rule files must be at most 1 MiB.") }
    static package let maximumBytes = 1_048_576
    static package let libraryEncodingOptions: JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys]
    package var version: Int
    package var name: String
    package var steps: [AutomationDefinition.Step]
    package func validate() throws {
        let probe = AutomationDefinition(id: UUID(), name: name, input: .document, steps: steps, output: .editor)
        guard version == 1 else { throw AutomationError.invalid("Unsupported rule-set version.") }
        try probe.validate()
    }
}

/// What Load Rules → Import File finds in a file: the rules of a rule file, or the rules of each
/// automation in a library export. Only steps are ever taken from either.
package enum AutomationRuleImport {
    static package let fallbackName = "Imported rules"
    static package func ruleSets(from data: Data) throws -> (sets: [AutomationRuleSet], fromLibrary: Bool) {
        guard data.count <= 1_048_576 else { throw AutomationError.invalid("Rule files must be at most 1 MiB.") }
        let decoder = JSONDecoder()
        let ruleSet: AutomationRuleSet
        do { ruleSet = try decoder.decode(AutomationRuleSet.self, from: data) } catch is DecodingError {
            let library: AutomationLibrary
            do { library = try decoder.decode(AutomationLibrary.self, from: data) } catch is DecodingError {
                throw AutomationError.invalid(
                    "This is not a rule file that this version of TextTank can read. Choose a file written by Export Rules, or an automation library exported from Advanced JSON."
                )
            }
            try library.validate()
            guard !library.workflows.isEmpty else {
                throw AutomationError.invalid(
                    "This automation library holds no automations, so it has no rules to load.")
            }
            return (library.workflows.map { AutomationRuleSet(name: $0.name, steps: $0.steps) }, true)
        }
        // Only the steps are applied, so a missing or over-long name does not refuse the file; the
        // name is a label in the confirmation and nothing more.
        guard ruleSet.version == 1 else { throw AutomationError.invalid("Unsupported rule-set version.") }
        let name = ruleSet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let imported = AutomationRuleSet(
            name: name.isEmpty || name.count > 120 ? fallbackName : name, steps: ruleSet.steps)
        try imported.validate()
        return ([imported], false)
    }
}

/// Built-in rule templates ship as rule-set JSON resources and are read with the same bounded
/// decoder as an imported rule file. They carry no sample-specific text.
package enum AutomationTemplates {
    /// Resource names in the order the Load Rules list shows them.
    static package let resourceNames = ["trim-and-remove-empty-lines", "sort-unique-lines", "recipe-ingredient-cleanup"]
    static package func url(_ name: String) -> URL {
        Bundle.main.url(forResource: name + ".rules", withExtension: "json")
            ?? URL(fileURLWithPath: "Resources/AutomationTemplates/\(name).rules.json")
    }
    static package func load(_ name: String) throws -> AutomationRuleSet {
        try AutomationRuleSet.decode(AutomationFileInput.readData(url(name), limit: 1_048_576))
    }
    /// Every template that loads, and one line for each that does not, so a damaged resource is
    /// reported instead of silently missing from the list.
    static package func loadAll() -> (sets: [AutomationRuleSet], problems: [String]) {
        var sets: [AutomationRuleSet] = [], problems: [String] = []
        for name in resourceNames {
            do { sets.append(try load(name)) } catch {
                problems.append("\(name): \(error.localizedDescription)")
            }
        }
        return (sets, problems)
    }
}

/// Plain text from clipboard HTML by a local scan. Nothing is rendered, run or fetched: markup never
/// reaches AppKit's WebKit-backed importer, which may load the resources a page refers to.
package enum AutomationHTMLText {
    static package func plainText(from data: Data) -> String? {
        guard data.count <= AutomationDefinition.maximumTransformBytes else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16).flatMap(plainText(from:))
        }
        return String(data: data, encoding: .utf8).flatMap(plainText(from:))
    }
    /// Text outside tags, with script, style and head content dropped, line breaks at `<br>` and at
    /// the end of paragraphs, list items, table rows, headings and divisions, runs of white space
    /// collapsed outside `<pre>`, and the basic character references decoded. Returns nil when no
    /// text remains. An unterminated tag or comment drops the rest of the input, as a browser does.
    static package func plainText(from html: String) -> String? {
        let source = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = source.first == "\u{FEFF}" ? 1 : 0
        var pendingSpace = false, preDepth = 0, hasText = false
        let commentOpen = Array("!--".unicodeScalars), commentClose = Array("-->".unicodeScalars)
        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{C}"
        }
        func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
        }
        func emit(_ scalar: Unicode.Scalar) {
            if preDepth == 0 && isSpace(scalar) {
                pendingSpace = true
                return
            }
            if pendingSpace, let last = out.last, last != "\n" { out.append(" ") }
            pendingSpace = false
            if !isSpace(scalar) { hasText = true }
            out.append(scalar)
        }
        func lineBreak(always: Bool) {
            pendingSpace = false
            if always || (out.last != nil && out.last != "\n") { out.append("\n") }
        }
        /// True when the ASCII text `word`, compared without case, starts at `position`.
        func matches(_ word: [Unicode.Scalar], at position: Int) -> Bool {
            guard position + word.count <= source.count else { return false }
            for (offset, expected) in word.enumerated() {
                let scalar = source[position + offset]
                let value = scalar.value, folded = value >= 0x41 && value <= 0x5A ? value + 0x20 : value
                guard folded == expected.value else { return false }
            }
            return true
        }
        /// The index of the `>` that ends the tag opened before `start`, honouring quoted attributes.
        func tagEnd(from start: Int) -> Int? {
            var quote: Unicode.Scalar?, position = start
            while position < source.count {
                let scalar = source[position]
                if let open = quote {
                    if scalar == open { quote = nil }
                } else if scalar == "\"" || scalar == "'" {
                    quote = scalar
                } else if scalar == ">" {
                    return position
                }
                position += 1
            }
            return nil
        }
        func decodeReference(at start: Int) -> (Unicode.Scalar, Int)? {
            var end = start + 1
            while end < source.count, end - start <= 10, source[end] != ";" { end += 1 }
            guard end < source.count, source[end] == ";" else { return nil }
            let body = String(String.UnicodeScalarView(source[(start + 1)..<end]))
            let named: [String: Unicode.Scalar] = [
                "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}"
            ]
            if let scalar = named[body] { return (scalar, end - start + 1) }
            guard body.hasPrefix("#") else { return nil }
            let digits = body.dropFirst()
            let value =
                digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return (scalar, end - start + 1)
        }
        while index < source.count {
            let scalar = source[index]
            if scalar == "&", let (decoded, length) = decodeReference(at: index) {
                emit(decoded)
                index += length
                continue
            }
            guard scalar == "<", index + 1 < source.count else {
                emit(scalar)
                index += 1
                continue
            }
            if matches(commentOpen, at: index + 1) {
                var close = index + 4
                while close < source.count, !matches(commentClose, at: close) { close += 1 }
                index = close < source.count ? close + 3 : source.count
                continue
            }
            let next = source[index + 1]
            guard next == "/" || next == "!" || next == "?" || (next.isASCII && CharacterSet.letters.contains(next))
            else {
                emit(scalar)
                index += 1
                continue
            }
            guard let end = tagEnd(from: index + 1) else { break }
            let closing = next == "/"
            var nameEnd = index + (closing ? 2 : 1)
            let nameStart = nameEnd
            while nameEnd < end, isNameScalar(source[nameEnd]) { nameEnd += 1 }
            let name = String(String.UnicodeScalarView(source[nameStart..<nameEnd])).lowercased()
            index = end + 1
            if !closing, ["script", "style", "head"].contains(name) {
                // Raw content: skip to the matching end tag. A head that never closes ends at <body>.
                let endTag = Array(("</" + name).unicodeScalars), body = Array("<body".unicodeScalars)
                var position = index, found = false
                while position < source.count {
                    if source[position] == "<" {
                        if matches(endTag, at: position) {
                            found = true
                            break
                        }
                        if name == "head", matches(body, at: position) { break }
                    }
                    position += 1
                }
                if found {
                    guard let close = tagEnd(from: position + 1) else { break }
                    index = close + 1
                } else {
                    index = position
                }
                continue
            }
            switch name {
            case "br": lineBreak(always: true)
            case "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6":
                if closing { lineBreak(always: false) }
            case "pre":
                preDepth = closing ? max(0, preDepth - 1) : preDepth + 1
                if closing { lineBreak(always: false) }
            default: break
            }
        }
        return hasText ? String(out) : nil
    }
}
