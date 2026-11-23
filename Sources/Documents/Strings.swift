// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Bounded English presentation catalog for the audit26 surfaces. Raw native checks have no
/// bundle and use the same explicit English fallbacks. This is not complete app localization.
package enum Strings {
    package static func text(_ key: String, _ english: String, bundle: Bundle = .main) -> String {
        return bundle.localizedString(forKey: key, value: english, table: nil)
    }
    static package func formAction(_ action: String, scope: String) -> String {
        String(format: text("form.action.scope", "%@ in %@"), action, scope)
    }
    static package func number(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }
    static package func points(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0...2)))
    }
    static package func bytes(_ value: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(value))
    }
    package enum Unit: String, CaseIterable {
        case match, document, file, folder, bookmark, character, line, selection, rule, item, recoveryCopy
        package var formats: (String, String) {
            switch self {
            case .match: return (text("count.match.one", "%@ match"), text("count.match.other", "%@ matches"))
            case .document:
                return (text("count.document.one", "%@ document"), text("count.document.other", "%@ documents"))
            case .file: return (text("count.file.one", "%@ file"), text("count.file.other", "%@ files"))
            case .folder: return (text("count.folder.one", "%@ folder"), text("count.folder.other", "%@ folders"))
            case .bookmark:
                return (text("count.bookmark.one", "%@ bookmark"), text("count.bookmark.other", "%@ bookmarks"))
            case .character:
                return (
                    text("count.character.one", "%@ character"),
                    text("count.character.other", "%@ characters")
                )
            case .line: return (text("count.line.one", "%@ line"), text("count.line.other", "%@ lines"))
            case .selection:
                return (text("count.selection.one", "%@ selection"), text("count.selection.other", "%@ selections"))
            case .rule: return (text("count.rule.one", "%@ rule"), text("count.rule.other", "%@ rules"))
            case .item: return (text("count.item.one", "%@ item"), text("count.item.other", "%@ items"))
            case .recoveryCopy:
                return (
                    text("count.recoveryCopy.one", "%@ recovery copy"),
                    text("count.recoveryCopy.other", "%@ recovery copies")
                )
            }
        }
    }
    static package func count(_ value: Int, _ unit: Unit) -> String {
        let formats = unit.formats
        return String(format: value == 1 ? formats.0 : formats.1, number(value))
    }
    static package func found(_ matches: Int, documents: Int, truncated: Bool) -> String {
        let format: String
        switch (matches == 1, documents == 1, truncated) {
        case (true, true, true):
            format = text("search.found.one.one.truncated", "%@ match in %@ document; result limit reached.")
        case (true, true, false): format = text("search.found.one.one.complete", "%@ match in %@ document.")
        case (true, false, true):
            format = text("search.found.one.many.truncated", "%@ match in %@ documents; result limit reached.")
        case (true, false, false): format = text("search.found.one.many.complete", "%@ match in %@ documents.")
        case (false, true, true):
            format = text("search.found.many.one.truncated", "%@ matches in %@ document; result limit reached.")
        case (false, true, false): format = text("search.found.many.one.complete", "%@ matches in %@ document.")
        case (false, false, true):
            format = text("search.found.many.many.truncated", "%@ matches in %@ documents; result limit reached.")
        case (false, false, false): format = text("search.found.many.many.complete", "%@ matches in %@ documents.")
        }
        return String(format: format, number(matches), number(documents))
    }
    static package func cleared(_ n: Int) -> String {
        String(
            format: n == 1
                ? text("search.cleared.one", "Cleared search highlights from %@ document.")
                : text("search.cleared.other", "Cleared search highlights from %@ documents."), number(n))
    }
    static package func folderSummary(matches: Int, files: Int, problems: Int, excluded: Int, state: String) -> String {
        let format: String
        switch (matches == 1, files == 1) {
        case (true, true):
            format = text(
                "folder.summary.1.1", "%@ match in %@ file searched. Not searched: %@. Excluded: %@. Status: %@.")
        case (true, false):
            format = text(
                "folder.summary.1.0", "%@ match in %@ files searched. Not searched: %@. Excluded: %@. Status: %@.")
        case (false, true):
            format = text(
                "folder.summary.0.1", "%@ matches in %@ file searched. Not searched: %@. Excluded: %@. Status: %@.")
        case (false, false):
            format = text(
                "folder.summary.0.0", "%@ matches in %@ files searched. Not searched: %@. Excluded: %@. Status: %@.")
        }
        return String(format: format, number(matches), number(files), number(problems), number(excluded), state)
    }
    static package func folderProgress(files: Int, matches: Int, bytesRead: Int) -> String {
        let format: String
        switch (files == 1, matches == 1) {
        case (true, true): format = text("folder.progress.1.1", "Searching: %@ file; %@ match; %@ read…")
        case (true, false): format = text("folder.progress.1.0", "Searching: %@ file; %@ matches; %@ read…")
        case (false, true): format = text("folder.progress.0.1", "Searching: %@ files; %@ match; %@ read…")
        case (false, false): format = text("folder.progress.0.0", "Searching: %@ files; %@ matches; %@ read…")
        }
        return String(format: format, number(files), number(matches), bytes(bytesRead))
    }
    static package func replaced(_ changed: Int, stale: Int) -> String {
        let format: String
        switch (changed == 1, stale == 1) {
        case (true, true):
            format = text(
                "search.replaced.1.1", "Replaced %@ match; %@ changed document skipped. Undo is per document.")
        case (true, false):
            format = text(
                "search.replaced.1.0", "Replaced %@ match; %@ changed documents skipped. Undo is per document.")
        case (false, true):
            format = text(
                "search.replaced.0.1", "Replaced %@ matches; %@ changed document skipped. Undo is per document.")
        case (false, false):
            format = text(
                "search.replaced.0.0", "Replaced %@ matches; %@ changed documents skipped. Undo is per document.")
        }
        return String(format: format, number(changed), number(stale))
    }
    static package func marked(_ count: Int, stale: Int, zeroWidth: Int) -> String {
        let format: String
        switch (count == 1, stale == 1, zeroWidth == 1) {
        case (true, true, true):
            format = text(
                "search.marked.1.1.1",
                "Marked %@ match; %@ changed/closed document skipped. %@ zero-width match has no visible span.")
        case (true, true, false):
            format = text(
                "search.marked.1.1.0",
                "Marked %@ match; %@ changed/closed document skipped. %@ zero-width matches have no visible span.")
        case (true, false, true):
            format = text(
                "search.marked.1.0.1",
                "Marked %@ match; %@ changed/closed documents skipped. %@ zero-width match has no visible span.")
        case (true, false, false):
            format = text(
                "search.marked.1.0.0",
                "Marked %@ match; %@ changed/closed documents skipped. %@ zero-width matches have no visible span.")
        case (false, true, true):
            format = text(
                "search.marked.0.1.1",
                "Marked %@ matches; %@ changed/closed document skipped. %@ zero-width match has no visible span.")
        case (false, true, false):
            format = text(
                "search.marked.0.1.0",
                "Marked %@ matches; %@ changed/closed document skipped. %@ zero-width matches have no visible span.")
        case (false, false, true):
            format = text(
                "search.marked.0.0.1",
                "Marked %@ matches; %@ changed/closed documents skipped. %@ zero-width match has no visible span.")
        case (false, false, false):
            format = text(
                "search.marked.0.0.0",
                "Marked %@ matches; %@ changed/closed documents skipped. %@ zero-width matches have no visible span.")
        }
        return String(format: format, number(count), number(stale), number(zeroWidth))
    }
    static package func workspaceSkipped(_ count: Int, truncated: Bool, limit: Int) -> String {
        let format: String
        switch (count == 1, truncated) {
        case (true, false):
            format = text("workspace.skipped.one.complete", "%@ hidden, symbolic-link or special entry skipped.")
        case (false, false):
            format = text("workspace.skipped.other.complete", "%@ hidden, symbolic-link or special entries skipped.")
        case (true, true):
            format = text(
                "workspace.skipped.one.truncated",
                "%@ hidden, symbolic-link or special entry skipped; %@-entry listing limit reached.")
        case (false, true):
            format = text(
                "workspace.skipped.other.truncated",
                "%@ hidden, symbolic-link or special entries skipped; %@-entry listing limit reached.")
        }
        return truncated ? String(format: format, number(count), number(limit)) : String(format: format, number(count))
    }
    /// Whole-input grammar precedes NumberFormatter, whose number(from:) accepts prefixes.
    /// Grouping, exponent notation, signs and foreign decimal separators are not accepted in
    /// these bounded positive form inputs. Persisted numeric values keep their existing types.
    static package func decimal(_ input: String, fractional: Bool, locale: Locale = .current) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        formatter.usesGroupingSeparator = false
        let separator = NSRegularExpression.escapedPattern(for: formatter.decimalSeparator ?? ".")
        let pattern = fractional ? "^\\p{Nd}+(?:" + separator + "\\p{Nd}+)?$" : "^\\p{Nd}+$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil,
            let value = formatter.number(from: trimmed)?.doubleValue, value.isFinite
        else { return nil }
        return value
    }
    static package func integer(_ input: String, locale: Locale = .current, signed: Bool = false) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let sign = signed && (trimmed.hasPrefix("-") || trimmed.hasPrefix("+")) ? String(trimmed.prefix(1)) : ""
        let magnitude = sign.isEmpty ? trimmed : String(trimmed.dropFirst())
        guard decimal(magnitude, fractional: false, locale: locale) != nil else { return nil }
        let digits = magnitude.compactMap { $0.wholeNumberValue }
        guard digits.count == magnitude.count else { return nil }
        return Int(sign + digits.map(String.init).joined())
    }
}
