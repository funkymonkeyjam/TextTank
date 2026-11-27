// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import zlib

/// Deterministic UTF-8 text utilities. Binary results are rejected, never repaired
/// with replacement characters. These operations do not execute imported content.
package enum TextUtility: String, CaseIterable {
    case base64Encode, base64EncodePadded, base64EncodeUnix, base64EncodeLines, base64Decode, base64DecodeLines,
        base64DecodeStrict
    case quotedPrintableEncode, quotedPrintableDecode, samlDecode
    case urlEncode, urlEncodeExtended, urlEncodeFull, urlEncodeLines, urlEncodeExtendedLines, urlEncodeFullLines,
        urlDecode
    case hexEncode, hexDecode
    case inspectUnicode, validateJSON, formatJSON
    package var title: String {
        switch self {
        case .base64EncodeLines: return "Base64 Encode by Line"
        case .base64Decode: return "Base64 Decode"
        case .base64DecodeLines: return "Base64 Decode by Line"
        case .quotedPrintableEncode: return "Quoted-printable Encode"
        case .quotedPrintableDecode: return "Quoted-printable Decode"
        case .samlDecode: return "SAML Decode"
        case .urlEncodeExtendedLines: return "URL Encode (Extended) by Line"
        case .urlEncodeFullLines: return "URL Encode (Full) by Line"
        case .base64Encode: return "Base64 Encode"
        case .base64EncodePadded: return "Base64 Encode with Padding"
        case .base64EncodeUnix: return "Base64 Encode with Unix EOL"
        case .base64DecodeStrict: return "Base64 Decode Strict"
        case .urlEncode: return "URL Encode (RFC1738)"
        case .urlEncodeExtended: return "URL Encode (Extended)"
        case .urlEncodeFull: return "URL Encode (Full)"
        case .urlEncodeLines: return "URL Encode (RFC1738) by Line"
        case .urlDecode: return "URL Decode"
        case .inspectUnicode: return "Inspect Unicode Selection"
        case .validateJSON: return "Validate JSON"
        case .formatJSON: return "Format JSON"
        case .hexEncode: return "UTF-8 to Hex"
        case .hexDecode: return "Hex to UTF-8"
        }
    }
    package func apply(_ input: String) throws -> String {
        guard input.utf8.count <= SizePolicy.standard.utilitySelection else { throw UtilityFailure.tooLarge }
        switch self {
        case .validateJSON, .formatJSON:
            var json = JSONSelection(input, format: self == .formatJSON)
            return try json.run()
        case .inspectUnicode:
            var lines: [String] = [], offset = 0
            for scalar in input.unicodeScalars {
                guard lines.count < 512 else {
                    lines.append("Showing the first 512 Unicode scalars. Select a smaller range to inspect the rest.")
                    break
                }
                let name: String
                switch scalar.value {
                case 0: name = "NULL"
                case 9: name = "CHARACTER TABULATION"
                case 10: name = "LINE FEED"
                case 13: name = "CARRIAGE RETURN"
                default: name = scalar.properties.name ?? String(describing: scalar.properties.generalCategory)
                }
                lines.append(String(format: "Byte %d   U+%04X   %@", offset, scalar.value, name))
                offset += scalar.utf8.count
            }
            return lines.joined(separator: "\n")
        case .base64EncodeLines:
            var output = ""
            var line = Data()
            for b in input.utf8 {
                if b == 10 || b == 13 {
                    output +=
                        line.base64EncodedString().replacingOccurrences(of: "=", with: "") + String(UnicodeScalar(b))
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(b)
                }
            }
            return output + line.base64EncodedString().replacingOccurrences(of: "=", with: "")
        case .base64Decode, .base64DecodeLines:
            return try Self.text(Self.permissiveBase64(input, whitespaceReset: self == .base64DecodeLines))
        case .quotedPrintableEncode:
            // CRLF soft breaks are the documented reference behaviour (docs/research/utility-audit.md).
            var output = [UInt8]()
            output.reserveCapacity(input.utf8.count + input.utf8.count / 8)
            var column = 0
            for b in input.utf8 {
                let literal = (b > 32 && b < 127 && b != 61) || b == 9 || b == 10 || b == 13 || b == 32
                let width = literal ? 1 : 3
                column = b == 10 ? width : column + width
                if column >= 76 {
                    output.append(61)
                    output.append(13)
                    output.append(10)
                    column = width
                }
                if literal {
                    output.append(b)
                } else {
                    output.append(61)
                    Self.appendHex(b, to: &output, digits: Self.upperHexDigits)
                }
            }
            return String(decoding: output, as: UTF8.self)
        case .quotedPrintableDecode:
            let bytes = Array(input.utf8)
            var output = Data()
            var i = 0
            while i < bytes.count {
                if bytes[i] != 61 {
                    output.append(bytes[i])
                    i += 1
                    continue
                }
                // A soft line break is "=" then CRLF, LF or CR; a lone trailing "=" is malformed.
                guard i + 1 < bytes.count else { throw UtilityFailure.malformed("quoted-printable") }
                if bytes[i + 1] == 10 {
                    i += 2
                    continue
                }
                if bytes[i + 1] == 13 {
                    i += (i + 2 < bytes.count && bytes[i + 2] == 10) ? 3 : 2
                    continue
                }
                guard i + 2 < bytes.count, let hi = Self.hex(bytes[i + 1]), let lo = Self.hex(bytes[i + 2]) else {
                    throw UtilityFailure.malformed("quoted-printable")
                }
                output.append(hi * 16 + lo)
                i += 3
            }
            return try Self.text(output)
        case .samlDecode:
            let decoded = try TextUtility.urlDecode.apply(input)
            guard let data = Data(base64Encoded: decoded.filter { !$0.isWhitespace }) else {
                throw UtilityFailure.malformed("SAML Base64")
            }
            // Direct XML first: nothing accepted before this rule is decoded differently, and a
            // deflate stream would have to be valid UTF-8 text starting with "<" to be mistaken.
            if Self.looksLikeXML(data), let direct = try? Self.text(data) { return direct }
            let inflated = try Self.inflateRaw(data, limit: SizePolicy.standard.utilitySelection)
            guard Self.looksLikeXML(inflated) else { throw UtilityFailure.malformed("SAML XML") }
            return try Self.text(inflated)
        case .base64Encode: return Data(input.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        case .base64EncodePadded: return Data(input.utf8).base64EncodedString()
        case .base64EncodeUnix:
            let encoded = Array(Data(input.utf8).base64EncodedString())
            return stride(from: 0, to: encoded.count, by: 64).map { String(encoded[$0..<min($0 + 64, encoded.count)]) }
                .joined(separator: "\n")
        case .base64DecodeStrict:
            let ascii = Array(input.utf8)
            guard
                ascii.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                        || [43, 47, 61, 9, 10, 13, 32].contains($0)
                })
            else { throw UtilityFailure.malformed("Base64") }
            let clean = input.filter { !$0.isWhitespace }
            let bare = clean.prefix(while: { $0 != "=" })
            let padding = clean.dropFirst(bare.count)
            guard padding.allSatisfy({ $0 == "=" }), padding.count <= 2, bare.count % 4 != 1,
                padding.isEmpty || (clean.count % 4 == 0 && padding.count == (4 - bare.count % 4) % 4)
            else { throw UtilityFailure.malformed("Base64") }
            let normalized = String(bare) + String(repeating: "=", count: (4 - bare.count % 4) % 4)
            guard let bytes = Data(base64Encoded: normalized), bytes.base64EncodedString() == normalized else {
                throw UtilityFailure.malformed("Base64")
            }
            return try Self.text(bytes)
        case .urlEncode, .urlEncodeExtended, .urlEncodeFull, .urlEncodeLines, .urlEncodeExtendedLines,
            .urlEncodeFullLines:
            var reserved = Set("<>\"#%{}|\\^~[]`;/?:@=& ".utf8)
            if self == .urlEncodeExtended || self == .urlEncodeExtendedLines { reserved.formUnion("!*'()+$,".utf8) }
            let byLine = [.urlEncodeLines, .urlEncodeExtendedLines, .urlEncodeFullLines].contains(self)
            let full = self == .urlEncodeFull || self == .urlEncodeFullLines
            // One decision per byte value, made once.
            let escaped = (0..<256).map { value -> Bool in
                let b = UInt8(value)
                if byLine && (b == 10 || b == 13) { return false }
                return full || b < 32 || b >= 127 || reserved.contains(b)
            }
            var output = [UInt8]()
            output.reserveCapacity(input.utf8.count * (full ? 3 : 1))
            for b in input.utf8 {
                if escaped[Int(b)] {
                    output.append(37)
                    Self.appendHex(b, to: &output, digits: Self.upperHexDigits)
                } else {
                    output.append(b)
                }
            }
            return String(decoding: output, as: UTF8.self)
        case .urlDecode:
            let bytes = Array(input.utf8)
            var result = Data()
            var i = 0
            while i < bytes.count {
                if bytes[i] == 37 {
                    guard i + 2 < bytes.count, let hi = Self.hex(bytes[i + 1]), let lo = Self.hex(bytes[i + 2]) else {
                        throw UtilityFailure.malformed("URL")
                    }
                    result.append(hi * 16 + lo)
                    i += 3
                } else {
                    result.append(bytes[i])
                    i += 1
                }
            }
            return try Self.text(result)
        case .hexEncode:
            var output = [UInt8]()
            output.reserveCapacity(input.utf8.count * 2)
            for b in input.utf8 { Self.appendHex(b, to: &output, digits: Self.upperHexDigits) }
            return String(decoding: output, as: UTF8.self)
        case .hexDecode:
            // TextTank accepts whitespace between complete byte pairs. A split
            // pair is invalid; odd digits never silently truncate the selection.
            let bytes = Array(input.utf8)
            var result = Data()
            var hi: UInt8?
            for b in bytes {
                if [9, 10, 13, 32].contains(b) {
                    guard hi == nil else { throw UtilityFailure.malformed("hexadecimal") }
                    continue
                }
                guard let n = Self.hex(b) else { throw UtilityFailure.malformed("hexadecimal") }
                if let h = hi {
                    result.append(h * 16 + n)
                    hi = nil
                } else {
                    hi = n
                }
            }
            guard hi == nil else { throw UtilityFailure.malformed("hexadecimal") }
            return try Self.text(result)
        }
    }
    // Segment behavior derived from MIME Tools b64.cpp (GPL-3.0-or-later),
    // Don HO, Paul Nankervis. Invalid separators remain literal; whitespace
    // either joins blocks or resets them for by-line decoding.
    private static func permissiveBase64(_ input: String, whitespaceReset: Bool) throws -> Data {
        let values = base64Values
        var output = Data()
        var field: UInt32 = 0
        var symbols = 0
        func flush() {
            if symbols >= 2 { output.append(UInt8((field >> 16) & 255)) }
            if symbols >= 3 { output.append(UInt8((field >> 8) & 255)) }
            if symbols == 4 { output.append(UInt8(field & 255)) }
            field = 0
            symbols = 0
        }
        for b in input.utf8 {
            let n = values[Int(b)]
            if n >= 0 {
                field |= UInt32(n) << (18 - symbols * 6)
                symbols += 1
                if symbols == 4 { flush() }
            } else if b == 61 {
                continue
            } else if [9, 10, 13, 32].contains(b) && !whitespaceReset {
                continue
            } else {
                flush()
                output.append(b)
            }
        }
        flush()
        return output
    }
    /// Value of each Base64 symbol by byte, or -1 for a byte outside the alphabet.
    private static let base64Values: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for (value, symbol) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            table[Int(symbol)] = Int8(value)
        }
        return table
    }()
    static package let upperHexDigits = Array("0123456789ABCDEF".utf8)
    static package let lowerHexDigits = Array("0123456789abcdef".utf8)
    static package func appendHex(_ byte: UInt8, to output: inout [UInt8], digits: [UInt8]) {
        output.append(digits[Int(byte >> 4)])
        output.append(digits[Int(byte & 15)])
    }
    /// Detection only: an optional UTF-8 BOM and XML whitespace, then "<". The caller returns
    /// every byte unchanged, so a leading U+FEFF stays content.
    private static func looksLikeXML(_ bytes: Data) -> Bool {
        var index = bytes.startIndex
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index += 3 }
        while index < bytes.endIndex, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        return index < bytes.endIndex && bytes[index] == 0x3C
    }
    /// Complete raw-deflate stream only: no trailing input, and at most `limit` output bytes.
    /// The output grows in 64 KiB steps instead of being allocated at the limit.
    private static func inflateRaw(_ input: Data, limit: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw UtilityFailure.malformed("SAML deflate")
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let finished: Bool = input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(source.count)
            while true {
                let (status, produced): (Int32, Int) = chunk.withUnsafeMutableBufferPointer { destination in
                    stream.next_out = destination.baseAddress
                    stream.avail_out = uInt(destination.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    return (status, destination.count - Int(stream.avail_out))
                }
                output.append(contentsOf: chunk[0..<produced])
                if output.count > limit { return false }
                if status == Z_STREAM_END { return true }
                // Z_OK means progress was made. Z_BUF_ERROR, with a whole empty chunk to write
                // into, means the input ended before the stream did.
                guard status == Z_OK else { return false }
            }
        }
        guard finished, stream.avail_in == 0 else { throw UtilityFailure.malformed("SAML deflate or output limit") }
        return output
    }
    private static func hex(_ b: UInt8) -> UInt8? {
        if (48...57).contains(b) { return b - 48 }
        if (65...70).contains(b) { return b - 55 }
        if (97...102).contains(b) { return b - 87 }
        return nil
    }
    private static func text(_ bytes: Data) throws -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.utf8.elementsEqual(bytes) else { throw UtilityFailure.binaryResult }
        return text
    }
}
package enum UtilityFailure: LocalizedError, Equatable {
    case invalidJSON(Int), jsonOutputLimit, jsonDepthLimit
    case malformed(String), binaryResult, tooLarge, selectionRequired, multipleSelections, documentChanged, noDocument
    package var errorDescription: String? {
        switch self {
        case .invalidJSON(let byte): return "Invalid JSON at UTF-8 byte \(byte). The selection was preserved."
        case .jsonOutputLimit:
            return
                "Formatted JSON exceeds \(SizePolicy.describe(SizePolicy.standard.formattedJSONOutput)). Select a smaller value."
        case .jsonDepthLimit: return "This tool supports up to 128 nested arrays and objects."
        case .malformed(let format): return "Invalid \(format) input. The selection was not changed."
        case .binaryResult: return "The decoded bytes are not valid UTF-8 text. The selection was not changed."
        case .tooLarge:
            return
                "Select at most \(SizePolicy.describe(SizePolicy.standard.utilitySelection)) for this utility. The selection was not changed."
        case .selectionRequired: return "Select one nonempty text range before running a utility."
        case .multipleSelections:
            return "This command works on a single selection. Collapse multiple selections and try again."
        case .documentChanged:
            return "The document or selection changed while the dialog was open. Nothing was changed."
        case .noDocument: return "There is no open document to use."
        }
    }
}

package struct RadixConversion {
    /// Whitespace and line breaks around the number are ignored: a selected line brings its
    /// line ending along. Anything inside the number is still rejected.
    static package func convert(_ input: String, from: Int, to: Int) throws -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [2, 8, 10, 16].contains(from), [2, 8, 10, 16].contains(to), !input.isEmpty,
            input.utf8.allSatisfy({ b in
                if (48...57).contains(b) { return Int(b - 48) < from }
                return from == 16 && ((65...70).contains(b) || (97...102).contains(b))
            }), let value = UInt32(input, radix: from)
        else { throw UtilityFailure.malformed("unsigned 32-bit number") }
        return String(value, radix: to, uppercase: true)
    }
}

package struct HexEncodingOptions {
    package init(insertSpaces: Bool = false, uppercase: Bool = true, bytesPerLine: Int = 16, lineEnding: String = "\n")
    {
        self.insertSpaces = insertSpaces
        self.uppercase = uppercase
        self.bytesPerLine = bytesPerLine
        self.lineEnding = lineEnding
    }

    package var insertSpaces: Bool
    package var uppercase: Bool
    package var bytesPerLine: Int
    package var lineEnding: String
    package func encode(_ text: String) throws -> String {
        guard (0...65536).contains(bytesPerLine), ["\n", "\r", "\r\n"].contains(lineEnding),
            text.utf8.count <= SizePolicy.standard.utilitySelection
        else { throw UtilityFailure.malformed("hex options or input size") }
        let digits = uppercase ? TextUtility.upperHexDigits : TextUtility.lowerHexDigits
        let ending = Array(lineEnding.utf8), count = text.utf8.count
        var output = [UInt8]()
        output.reserveCapacity(count * 3 + (bytesPerLine > 0 ? count / bytesPerLine * ending.count : 0))
        // A space goes between two bytes on a line, never after the last one. A completed
        // line keeps its line ending, including the last line.
        for (index, byte) in text.utf8.enumerated() {
            TextUtility.appendHex(byte, to: &output, digits: digits)
            if bytesPerLine > 0 && (index + 1) % bytesPerLine == 0 {
                output.append(contentsOf: ending)
            } else if insertSpaces && index + 1 < count {
                output.append(32)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Reads strict JSON from UTF-8. Formatting copies complete lexical tokens, including
/// exponent spelling, duplicate member names and escapes. Only JSON whitespace is rewritten.
private struct JSONSelection {
    private let bytes: [UInt8]
    private let formatting: Bool
    private var cursor = 0
    private var output: [UInt8] = []
    private let limit = SizePolicy.standard.formattedJSONOutput
    init(_ text: String, format: Bool) {
        bytes = Array(text.utf8)
        formatting = format
    }
    mutating func run() throws -> String {
        try value(depth: 0)
        skipWhitespace()
        guard cursor == bytes.count else { throw invalid }
        return formatting ? String(decoding: output, as: UTF8.self) : "Valid JSON."
    }
    private var invalid: UtilityFailure { .invalidJSON(cursor + 1) }
    private var peek: UInt8? { cursor < bytes.count ? bytes[cursor] : nil }
    private mutating func skipWhitespace() {
        while let b = peek, b == 9 || b == 10 || b == 13 || b == 32 { cursor += 1 }
    }
    private mutating func emit<C: Collection>(_ piece: C) throws where C.Element == UInt8 {
        guard formatting else { return }
        guard piece.count <= limit - output.count else { throw UtilityFailure.jsonOutputLimit }
        output.append(contentsOf: piece)
    }
    private mutating func punctuation(_ b: UInt8) throws {
        guard peek == b else { throw invalid }
        cursor += 1
        try emit(CollectionOfOne(b))
    }
    private mutating func indent(_ depth: Int) throws {
        guard formatting else { return }
        try emit(CollectionOfOne(10))
        try emit(repeatElement(32, count: depth * 2))
    }
    private mutating func value(depth: Int) throws {
        skipWhitespace()
        guard let b = peek else { throw invalid }
        switch b {
        case 123, 91:
            guard depth < 128 else { throw UtilityFailure.jsonDepthLimit }
            let object = b == 123, end: UInt8 = object ? 125 : 93
            try punctuation(b)
            skipWhitespace()
            if peek == end {
                try punctuation(end)
                return
            }
            while true {
                try indent(depth + 1)
                if object {
                    try string()
                    skipWhitespace()
                    try punctuation(58)
                    try emit(CollectionOfOne(32))
                }
                try value(depth: depth + 1)
                skipWhitespace()
                if peek == end { break }
                try punctuation(44)
                skipWhitespace()
            }
            try indent(depth)
            try punctuation(end)
        case 34: try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57: try number()
        default: throw invalid
        }
    }
    private mutating func literal(_ word: String) throws {
        for b in word.utf8 {
            guard peek == b else { throw invalid }
            cursor += 1
        }
        try emit(word.utf8)
    }
    private mutating func string() throws {
        let start = cursor
        guard peek == 34 else { throw invalid }
        cursor += 1
        while let b = peek {
            guard b >= 32 else { throw invalid }
            cursor += 1
            if b == 34 {
                try emit(bytes[start..<cursor])
                return
            }
            if b == 92 {
                guard let escape = peek else { throw invalid }
                cursor += 1
                switch escape {
                case 34, 47, 92, 98, 102, 110, 114, 116: break
                case 117:
                    for _ in 0..<4 {
                        guard let h = peek, (48...57).contains(h) || (65...70).contains(h) || (97...102).contains(h)
                        else { throw invalid }
                        cursor += 1
                    }
                default:
                    cursor -= 1
                    throw invalid
                }
            }
        }
        throw invalid
    }
    private mutating func digits() throws {
        guard let b = peek, (48...57).contains(b) else { throw invalid }
        repeat { cursor += 1 } while peek.map { (48...57).contains($0) } == true
    }
    private mutating func number() throws {
        let start = cursor
        if peek == 45 { cursor += 1 }
        if peek == 48 { cursor += 1 } else { try digits() }
        if peek == 46 {
            cursor += 1
            try digits()
        }
        if peek == 101 || peek == 69 {
            cursor += 1
            if peek == 45 || peek == 43 { cursor += 1 }
            try digits()
        }
        try emit(bytes[start..<cursor])
    }
}
