// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The kinds of document that have a rendered preview. See docs/preview-model.md.
package enum PreviewKind: Sendable, Hashable {
    case markdown
    case html
    /// Delimiter-separated values. The delimiter is a comma or a tab.
    case delimited(Character)
    case svg
    case json

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    private static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]
    /// Languages that are close to JSON but are not strict JSON. They have no tree preview,
    /// even when the file is named `.json`.
    private static let relaxedJSONLanguages: Set<String> = ["json5", "jsonc"]

    /// Decides which preview applies to a document, or nil when none does.
    ///
    /// `languageID` is the document's language identifier (`markdown`, `html`, `json`, `xml`,
    /// `normal`, ...). `fileExtension` is the saved file's extension without the dot, in any case,
    /// or nil for an untitled document. An untitled document is decided by its language alone, so
    /// SVG and delimited text need a saved name: no language identifier selects them.
    package static func kind(languageID: String, fileExtension: String?) -> PreviewKind? {
        let fileExtension = fileExtension?.lowercased() ?? ""
        switch fileExtension {
        case "csv": return .delimited(",")
        case "tsv", "tab": return .delimited("\t")
        case "svg": return .svg
        default: break
        }
        switch languageID {
        case "markdown": return .markdown
        case "html": return .html
        case "json": return .json
        default: break
        }
        if relaxedJSONLanguages.contains(languageID) { return nil }
        if markdownExtensions.contains(fileExtension) { return .markdown }
        if htmlExtensions.contains(fileExtension) { return .html }
        if fileExtension == "json" { return .json }
        return nil
    }

    /// The format this preview belongs to in Settings, where comma- and tab-separated text are
    /// one choice.
    package var format: PreviewFormat {
        switch self {
        case .markdown: return .markdown
        case .html: return .html
        case .delimited: return .delimited
        case .svg: return .svg
        case .json: return .json
        }
    }
}

/// The five kinds of document that have a preview, as Settings lists them. The raw values are
/// keys of `previewOpenModes` in the version-1 settings file (docs/architecture.md, "Persisted
/// formats"); never rename one.
package enum PreviewFormat: String, CaseIterable, Sendable {
    case markdown, html, delimited, svg, json
}

/// The custom URL scheme the preview web view loads everything from. The presentation layer
/// registers a handler for it; no other scheme is permitted by the content security policy.
package enum PreviewScheme {
    package static let name = "texttank-preview"
}

/// The bundled stylesheet for rendered Markdown and the image wrapper. The presentation layer
/// loads the resource and passes its text to `StaticHTMLPolicy.wrapFragment`.
package enum PreviewStylesheet {
    package static let resourceName = "preview"
    package static let resourceExtension = "css"
}

/// Every bound a preview enforces. A parser or renderer that reaches one stops and reports a
/// `PreviewLimit`; it never keeps working on an input of unbounded size.
package struct PreviewLimits: Sendable, Equatable {
    /// The largest document, in UTF-8 bytes, that any preview accepts.
    package var maxSourceBytes = 8 * 1024 * 1024
    /// The most delimited-text rows that are kept. Later rows are not shown.
    package var delimitedMaxRows = 100_000
    /// The most delimited-text columns that are kept in a row. Later cells are not shown.
    package var delimitedMaxColumns = 512
    /// The most JSON values (objects, arrays and scalars together) that are kept.
    package var jsonMaxNodes = 500_000
    /// The deepest JSON nesting that is followed. The outermost value is at depth 1.
    package var jsonMaxDepth = 512
    /// The largest HTML, in UTF-8 bytes, that the Markdown renderer produces.
    package var maxOutputBytes = 16 * 1024 * 1024
    /// The deepest nesting of Markdown block quotes and lists. Deeper markers are shown as text.
    package var markdownMaxNesting = 32
    /// The most columns a Markdown table may have. A wider header is not a table: its lines are
    /// shown as text.
    package var markdownMaxTableColumns = 4096
    /// The most Markdown table cells, empty ones included, in one document.
    package var markdownMaxTableCells = 1_000_000
    /// The largest local file, in bytes, that the preview serves to a page (a stylesheet or image).
    package var maxResourceBytes = 8 * 1024 * 1024

    package static let standard = PreviewLimits()
    package init() {}
}

/// Why a preview is incomplete or unavailable. `message` is the whole sentence shown to the user.
package enum PreviewLimit: Sendable, Equatable {
    case sourceTooLarge(maxBytes: Int)
    case outputTooLarge(maxBytes: Int)
    case tooManyRows(shown: Int)
    case tooManyColumns(shown: Int)
    case tooManyValues(shown: Int)
    case nestedTooDeeply(maxDepth: Int)
    case tooManyTableCells(maxCells: Int)

    package var message: String {
        switch self {
        case .sourceTooLarge(let maxBytes):
            return String(
                format: Strings.text(
                    "preview.limit.sourceTooLarge",
                    "This document is too large to preview. Preview works with documents up to %@."),
                Strings.bytes(maxBytes))
        case .outputTooLarge(let maxBytes):
            return String(
                format: Strings.text(
                    "preview.limit.outputTooLarge",
                    "This document is too large to preview. The formatted page would be larger than %@."),
                Strings.bytes(maxBytes))
        case .tooManyRows(let shown):
            return String(
                format: Strings.text("preview.limit.rows", "Only the first %@ rows are shown."),
                Strings.number(shown))
        case .tooManyColumns(let shown):
            return String(
                format: Strings.text("preview.limit.columns", "Only the first %@ columns are shown."),
                Strings.number(shown))
        case .tooManyValues(let shown):
            return String(
                format: Strings.text("preview.limit.values", "Only the first %@ values are shown."),
                Strings.number(shown))
        case .nestedTooDeeply(let maxDepth):
            return String(
                format: Strings.text(
                    "preview.limit.depth", "Only the first %@ levels of nesting are shown."),
                Strings.number(maxDepth))
        case .tooManyTableCells(let maxCells):
            return String(
                format: Strings.text(
                    "preview.limit.tableCells",
                    "This document is too large to preview. Its tables have more than %@ cells."),
                Strings.number(maxCells))
        }
    }
}

/// Why a parser or renderer stopped before finishing. Internal: the package API reports these as
/// cases of each result type.
enum PreviewStop: Error {
    case cancelled
    case outputTooLarge
    case tooManyTableCells
}

/// Asks the caller's cancellation closure about once for every `interval` units of work, so a
/// hot loop can report progress for every byte or line without paying for the closure each time.
/// A unit is roughly one input byte; the default interval polls every few thousand bytes.
///
/// The closure is called on the thread doing the work. The default used by the package API is
/// `{ Task.isCancelled }`, which reads the cancellation state of the task running the parser and
/// therefore works when a parser is called from `Task.detached`.
final class CancellationPoll {
    private let isCancelled: () -> Bool
    private let interval: Int
    private var remaining: Int

    init(every interval: Int = 4096, _ isCancelled: @escaping () -> Bool) {
        self.isCancelled = isCancelled
        self.interval = max(1, interval)
        self.remaining = max(1, interval)
    }

    /// Reports `units` of finished work and throws `PreviewStop.cancelled` when the caller has
    /// cancelled.
    func checkpoint(_ units: Int = 1) throws {
        remaining -= units
        guard remaining <= 0 else { return }
        remaining = interval
        if isCancelled() { throw PreviewStop.cancelled }
    }
}

/// ASCII byte values used by the byte-oriented parsers.
enum PreviewByte {
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let bang = UInt8(ascii: "!")
    static let quote = UInt8(ascii: "\"")
    static let hash = UInt8(ascii: "#")
    static let ampersand = UInt8(ascii: "&")
    static let apostrophe = UInt8(ascii: "'")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let star = UInt8(ascii: "*")
    static let plus = UInt8(ascii: "+")
    static let comma = UInt8(ascii: ",")
    static let minus = UInt8(ascii: "-")
    static let dot = UInt8(ascii: ".")
    static let slash = UInt8(ascii: "/")
    static let colon = UInt8(ascii: ":")
    static let semicolon = UInt8(ascii: ";")
    static let lessThan = UInt8(ascii: "<")
    static let equals = UInt8(ascii: "=")
    static let greaterThan = UInt8(ascii: ">")
    static let at = UInt8(ascii: "@")
    static let openBracket = UInt8(ascii: "[")
    static let backslash = UInt8(ascii: "\\")
    static let closeBracket = UInt8(ascii: "]")
    static let underscore = UInt8(ascii: "_")
    static let backtick = UInt8(ascii: "`")
    static let openBrace = UInt8(ascii: "{")
    static let pipe = UInt8(ascii: "|")
    static let closeBrace = UInt8(ascii: "}")
    static let tilde = UInt8(ascii: "~")

    static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    static func isLetter(_ byte: UInt8) -> Bool { (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x7A }
    static func isAlphanumeric(_ byte: UInt8) -> Bool { isDigit(byte) || isLetter(byte) }
    static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || ((byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x66)
    }
    /// Space or tab.
    static func isBlank(_ byte: UInt8) -> Bool { byte == space || byte == tab }
    /// Space, tab, line feed, form feed or carriage return.
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == lineFeed || byte == carriageReturn || byte == 0x0C
    }
    /// The ASCII punctuation characters, which are the ones a Markdown backslash can escape.
    static func isPunctuation(_ byte: UInt8) -> Bool {
        (byte >= 0x21 && byte <= 0x2F) || (byte >= 0x3A && byte <= 0x40) || (byte >= 0x5B && byte <= 0x60)
            || (byte >= 0x7B && byte <= 0x7E)
    }
    static func lowercased(_ byte: UInt8) -> UInt8 { (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte }
}

/// Writing text into HTML.
enum HTMLText {
    /// Appends `bytes` with `&`, `<`, `>` and `"` replaced by entities, so the result is safe as
    /// element text and inside a double-quoted attribute value.
    ///
    /// With `preservingEntities`, a well-formed entity reference such as `&amp;` or `&#169;` is
    /// copied unchanged so the reader sees the character it names. Never preserve entities in a
    /// URL: the browser would decode them after the URL has been checked.
    static func appendEscaped<Bytes: RandomAccessCollection>(
        _ bytes: Bytes, to output: inout [UInt8], preservingEntities: Bool = false
    ) where Bytes.Element == UInt8, Bytes.Index == Int {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            switch byte {
            case PreviewByte.ampersand:
                if preservingEntities, let length = entityLength(in: bytes, at: index) {
                    output.append(contentsOf: bytes[index..<index + length])
                    index += length
                    continue
                }
                output.append(contentsOf: Array("&amp;".utf8))
            case PreviewByte.lessThan: output.append(contentsOf: Array("&lt;".utf8))
            case PreviewByte.greaterThan: output.append(contentsOf: Array("&gt;".utf8))
            case PreviewByte.quote: output.append(contentsOf: Array("&quot;".utf8))
            default: output.append(byte)
            }
            index += 1
        }
    }

    static func escaped(_ text: String) -> String {
        var output: [UInt8] = []
        appendEscaped(Array(text.utf8), to: &output)
        return String(decoding: output, as: UTF8.self)
    }

    /// The length of the entity reference that starts with the `&` at `index`, or nil. Accepts
    /// `&name;` (a letter then up to 31 letters or digits), `&#digits;` and `&#xhex;`.
    static func entityLength<Bytes: RandomAccessCollection>(in bytes: Bytes, at index: Int) -> Int?
    where Bytes.Element == UInt8, Bytes.Index == Int {
        let end = bytes.endIndex
        var cursor = index + 1
        guard cursor < end else { return nil }
        if bytes[cursor] == PreviewByte.hash {
            cursor += 1
            var isHex = false
            if cursor < end, PreviewByte.lowercased(bytes[cursor]) == UInt8(ascii: "x") {
                isHex = true
                cursor += 1
            }
            let digitsStart = cursor
            while cursor < end, cursor - digitsStart < 7,
                isHex ? PreviewByte.isHexDigit(bytes[cursor]) : PreviewByte.isDigit(bytes[cursor])
            {
                cursor += 1
            }
            guard cursor > digitsStart, cursor < end, bytes[cursor] == PreviewByte.semicolon else { return nil }
            return cursor + 1 - index
        }
        guard PreviewByte.isLetter(bytes[cursor]) else { return nil }
        let nameStart = cursor
        while cursor < end, cursor - nameStart < 32, PreviewByte.isAlphanumeric(bytes[cursor]) { cursor += 1 }
        guard cursor < end, bytes[cursor] == PreviewByte.semicolon else { return nil }
        return cursor + 1 - index
    }
}

/// Which link and image addresses rendered Markdown may contain.
package enum PreviewURLPolicy {
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// The scheme of `url`, lowercased, when it starts with one (`letter (letter|digit|+|.|-)* :`).
    package static func scheme(of url: String) -> String? {
        let bytes = Array(url.utf8)
        guard let first = bytes.first, PreviewByte.isLetter(first) else { return nil }
        for (index, byte) in bytes.enumerated() {
            if byte == PreviewByte.colon { return String(decoding: bytes[..<index], as: UTF8.self).lowercased() }
            let isSchemeByte =
                PreviewByte.isAlphanumeric(byte) || byte == PreviewByte.plus || byte == PreviewByte.dot
                || byte == PreviewByte.minus
            if !isSchemeByte { return nil }
        }
        return nil
    }

    /// True for `http:`, `https:` and `mailto:` addresses and for relative addresses. False for
    /// every other scheme (`javascript:`, `data:`, `file:`, ...), for an address that starts
    /// with `//`, and for any address containing a control character, because browsers ignore
    /// some of them when they read the scheme.
    package static func allowsMarkdownDestination(_ url: String) -> Bool {
        let scalars = Array(url.unicodeScalars.drop(while: { $0.value <= 0x20 }))
        if scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        var trimmed = String.UnicodeScalarView()
        trimmed.append(contentsOf: scalars)
        let address = String(trimmed)
        // "//host/path" names another computer without naming a scheme.
        if address.hasPrefix("//") { return false }
        guard let scheme = scheme(of: address) else { return true }
        return allowedSchemes.contains(scheme)
    }
}
