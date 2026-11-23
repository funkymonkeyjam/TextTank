// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A start or end tag found by `MarkupTokenizer`.
struct MarkupTag {
    /// The tag name, lowercased.
    var name: String
    var isClosing: Bool
    /// True for `<name ... />`.
    var isSelfClosing: Bool
    /// Attribute names are lowercased; values are as written, without their quotes.
    var attributes: [(name: String, value: String)]
    /// The bytes of the whole tag, from `<` to `>`.
    var range: Range<Int>
}

enum MarkupToken {
    case tag(MarkupTag)
    /// The content of a `<script>` or `<style>` element, which is not markup.
    case rawText(element: String, range: Range<Int>)
    /// `<!DOCTYPE ...>`.
    case doctype(range: Range<Int>)
}

/// A tolerant tokenizer for HTML and SVG source. It finds tags, their attributes and the raw
/// text of script and style elements, and skips comments, CDATA sections and processing
/// instructions. It builds no tree and never fails: malformed markup produces fewer tokens.
/// Every byte is visited a bounded number of times.
struct MarkupTokenizer {
    private static let rawTextElements: Set<String> = ["script", "style"]

    private static let commentStart = Array("<!--".utf8)
    private static let commentEnd = Array("-->".utf8)
    private static let cdataStart = Array("<![cdata[".utf8)
    private static let cdataEnd = Array("]]>".utf8)
    private static let doctypeStart = Array("<!doctype".utf8)
    private static let declarationStart = Array("<!".utf8)
    private static let instructionStart = Array("<?".utf8)
    private static let tagEnd = Array(">".utf8)

    private let bytes: [UInt8]
    /// In XML (SVG) a self-closing `<script/>` or `<style/>` has no content. In HTML the slash
    /// is ignored and the raw text runs to the end tag.
    private let isXML: Bool
    private let poll: CancellationPoll
    private var position = 0
    /// Set after the start tag of a raw-text element: its content is the next token.
    private var pendingRawText: String?

    init(_ bytes: [UInt8], isXML: Bool, poll: CancellationPoll) {
        self.bytes = bytes
        self.isXML = isXML
        self.poll = poll
    }

    /// The next token, or nil at the end of the input. Throws only when cancelled.
    mutating func next() throws -> MarkupToken? {
        if let element = pendingRawText {
            pendingRawText = nil
            let start = position
            position = try startOfEndTag(named: element, from: start)
            if position > start { return .rawText(element: element, range: start..<position) }
        }
        while position < bytes.count {
            try poll.checkpoint()
            guard bytes[position] == PreviewByte.lessThan else {
                position += 1
                continue
            }
            if hasPrefix(Self.commentStart, at: position) {
                position = try index(after: Self.commentEnd, from: position + Self.commentStart.count)
            } else if hasPrefix(Self.cdataStart, at: position) {
                position = try index(after: Self.cdataEnd, from: position + Self.cdataStart.count)
            } else if hasPrefix(Self.doctypeStart, at: position) {
                let start = position
                position = try index(after: Self.tagEnd, from: position)
                return .doctype(range: start..<position)
            } else if hasPrefix(Self.declarationStart, at: position) || hasPrefix(Self.instructionStart, at: position) {
                position = try index(after: Self.tagEnd, from: position)
            } else if let tag = try readTag() {
                if !tag.isClosing, Self.rawTextElements.contains(tag.name), !(isXML && tag.isSelfClosing) {
                    pendingRawText = tag.name
                }
                return .tag(tag)
            } else {
                position += 1
            }
        }
        return nil
    }

    /// Compares the bytes at `start` with a lowercase ASCII prefix, ignoring case.
    private func hasPrefix(_ prefix: [UInt8], at start: Int) -> Bool {
        guard start + prefix.count <= bytes.count else { return false }
        for offset in 0..<prefix.count where PreviewByte.lowercased(bytes[start + offset]) != prefix[offset] {
            return false
        }
        return true
    }

    /// The index just after the next occurrence of `terminator`, or the end of the input.
    private func index(after terminator: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index + terminator.count <= bytes.count {
            try poll.checkpoint()
            if hasPrefix(terminator, at: index) { return index + terminator.count }
            index += 1
        }
        return bytes.count
    }

    /// The index of the `</name` that ends a raw-text element, or the end of the input. The
    /// name must end there: `</scriptx` does not end a script.
    private func startOfEndTag(named name: String, from start: Int) throws -> Int {
        let endTag = Array(("</" + name).utf8)
        var index = start
        while index < bytes.count {
            try poll.checkpoint()
            if bytes[index] == PreviewByte.lessThan, hasPrefix(endTag, at: index) {
                let after = index + endTag.count
                if after >= bytes.count || Self.endsName(bytes[after]) { return index }
            }
            index += 1
        }
        return bytes.count
    }

    /// Reads the tag at `position`, which is at a `<`. Returns nil, leaving `position` unchanged,
    /// when the `<` is not followed by a tag name.
    private mutating func readTag() throws -> MarkupTag? {
        let start = position
        var index = start + 1
        let isClosing = index < bytes.count && bytes[index] == PreviewByte.slash
        if isClosing { index += 1 }
        guard index < bytes.count, PreviewByte.isLetter(bytes[index]) else { return nil }
        let nameStart = index
        while index < bytes.count, !Self.endsName(bytes[index]) { index += 1 }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()

        var attributes: [(name: String, value: String)] = []
        var isSelfClosing = false
        while index < bytes.count, bytes[index] != PreviewByte.greaterThan {
            try poll.checkpoint()
            if PreviewByte.isWhitespace(bytes[index]) {
                index += 1
            } else if bytes[index] == PreviewByte.slash {
                isSelfClosing = index + 1 < bytes.count && bytes[index + 1] == PreviewByte.greaterThan
                index += 1
            } else {
                attributes.append(readAttribute(at: &index))
            }
        }
        position = min(bytes.count, index + 1)
        try poll.checkpoint(position - start)
        return MarkupTag(
            name: name, isClosing: isClosing, isSelfClosing: isSelfClosing, attributes: attributes,
            range: start..<position)
    }

    private static func endsName(_ byte: UInt8) -> Bool {
        PreviewByte.isWhitespace(byte) || byte == PreviewByte.slash || byte == PreviewByte.greaterThan
    }

    /// Reads `name`, `name=value`, `name="value"` or `name='value'` starting at `index`, which is
    /// at the first byte of the name. Always advances by at least one byte.
    private func readAttribute(at index: inout Int) -> (name: String, value: String) {
        let nameStart = index
        index += 1
        while index < bytes.count, !Self.endsName(bytes[index]), bytes[index] != PreviewByte.equals { index += 1 }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
        var afterName = index
        while afterName < bytes.count, PreviewByte.isWhitespace(bytes[afterName]) { afterName += 1 }
        guard afterName < bytes.count, bytes[afterName] == PreviewByte.equals else { return (name, "") }
        index = afterName + 1
        while index < bytes.count, PreviewByte.isWhitespace(bytes[index]) { index += 1 }
        guard index < bytes.count else { return (name, "") }
        let valueStart: Int
        let valueEnd: Int
        if bytes[index] == PreviewByte.quote || bytes[index] == PreviewByte.apostrophe {
            let quote = bytes[index]
            valueStart = index + 1
            index = valueStart
            while index < bytes.count, bytes[index] != quote { index += 1 }
            valueEnd = index
            index = min(bytes.count, index + 1)
        } else {
            valueStart = index
            while index < bytes.count, !PreviewByte.isWhitespace(bytes[index]), bytes[index] != PreviewByte.greaterThan
            {
                index += 1
            }
            valueEnd = index
        }
        return (name, String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self))
    }
}

/// What a page or image contains that the preview will not load or run.
package struct PreviewContentReport: Sendable, Equatable {
    /// Addresses on other computers (`http:`, `https:` or starting with `//`) that the document
    /// asks to load, in the order found, without repeats. At most `maxListedReferences` are kept.
    package var externalReferences: [String] = []
    /// Script elements, inline event handlers (`onclick=...`) and `javascript:` addresses.
    package var scriptCount = 0
    /// True when the document has a `<base>` tag. The content security policy sent with the
    /// page (`base-uri 'none'`) makes the browser ignore it.
    package var hasBaseTag = false
    /// Every listed reference, for a fast "already listed" test.
    private var listed: Set<String> = []

    package static let maxListedReferences = 1000

    package init() {}

    mutating func noteReference(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MarkupScan.isExternal(trimmed), externalReferences.count < Self.maxListedReferences,
            listed.insert(trimmed).inserted
        else { return }
        externalReferences.append(trimmed)
    }
}

/// Finds external references and scripts in tags and style sheets.
enum MarkupScan {
    /// Elements whose address attributes make the browser load something.
    private static let loadingElements: Set<String> = [
        "link", "img", "script", "iframe", "frame", "source", "video", "audio", "object", "embed", "track", "input",
        "image", "use", "feimage"
    ]
    private static let addressAttributes: Set<String> = ["src", "href", "xlink:href", "poster", "data", "background"]
    private static let scriptAddressAttributes: Set<String> = ["src", "href", "xlink:href", "action", "formaction"]

    static func isExternal(_ address: String) -> Bool {
        let lowercased = address.lowercased()
        return lowercased.hasPrefix("http:") || lowercased.hasPrefix("https:") || lowercased.hasPrefix("//")
    }

    /// Records what one start tag loads or would run. Throws only when cancelled.
    static func note(_ tag: MarkupTag, in report: inout PreviewContentReport, poll: CancellationPoll) throws {
        guard !tag.isClosing else { return }
        if tag.name == "script" { report.scriptCount += 1 }
        if tag.name == "base" { report.hasBaseTag = true }
        let loadsResources = loadingElements.contains(tag.name)
        for attribute in tag.attributes {
            if attribute.name.count > 2, attribute.name.hasPrefix("on") { report.scriptCount += 1 }
            if scriptAddressAttributes.contains(attribute.name), isScriptAddress(attribute.value) {
                report.scriptCount += 1
            }
            if attribute.name == "style" { try noteStyleSheet(attribute.value, in: &report, poll: poll) }
            guard loadsResources else { continue }
            if addressAttributes.contains(attribute.name) {
                report.noteReference(attribute.value)
            } else if attribute.name == "srcset" || attribute.name == "imagesrcset" {
                // Each candidate is an address followed by an optional size.
                for candidate in attribute.value.split(separator: ",") {
                    if let address = candidate.split(whereSeparator: { $0.isWhitespace }).first {
                        report.noteReference(String(address))
                    }
                }
            }
        }
    }

    /// A `javascript:` address. Browsers skip whitespace and control characters inside the
    /// scheme, so they are skipped here too.
    private static func isScriptAddress(_ value: String) -> Bool {
        let significant = value.unicodeScalars.filter { $0.value > 0x20 }.prefix(11)
        return String(String.UnicodeScalarView(significant)).lowercased() == "javascript:"
    }

    private static let urlKeyword = Array("url(".utf8)
    private static let importKeyword = Array("@import".utf8)

    /// Records every `url(...)` and `@import "..."` address in CSS text. Throws only when
    /// cancelled.
    static func noteStyleSheet(_ css: String, in report: inout PreviewContentReport, poll: CancellationPoll) throws {
        let lowercased = Array(css.lowercased().utf8)
        let original = Array(css.utf8)
        // Lowercasing can change the length of non-ASCII text; then scan the original as written.
        let bytes = lowercased.count == original.count ? lowercased : original
        var index = 0
        while index < bytes.count {
            try poll.checkpoint()
            if matches(urlKeyword, in: bytes, at: index) {
                let start = index + 4
                var end = start
                while end < bytes.count, bytes[end] != PreviewByte.closeParen { end += 1 }
                report.noteReference(unquoted(original[start..<end]))
                index = end
            } else if matches(importKeyword, in: bytes, at: index) {
                var start = index + 7
                while start < bytes.count, PreviewByte.isWhitespace(bytes[start]) { start += 1 }
                if start < bytes.count, bytes[start] == PreviewByte.quote || bytes[start] == PreviewByte.apostrophe {
                    var end = start + 1
                    while end < bytes.count, bytes[end] != bytes[start] { end += 1 }
                    report.noteReference(unquoted(original[start..<min(bytes.count, end + 1)]))
                    index = end
                } else {
                    index = start
                    continue
                }
            }
            index += 1
        }
    }

    private static func matches(_ keyword: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard bytes[index] == keyword[0], index + keyword.count <= bytes.count else { return false }
        return bytes[index..<index + keyword.count].elementsEqual(keyword)
    }

    /// Removes surrounding whitespace and one pair of quotes.
    private static func unquoted(_ bytes: ArraySlice<UInt8>) -> String {
        var text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, first == "\"" || first == "'" { text.removeFirst() }
        if let last = text.last, last == "\"" || last == "'" { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
