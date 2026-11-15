// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import zlib

/// Deterministic UTF-8 text utilities. Binary results are rejected, never repaired
/// with replacement characters. These operations do not execute imported content.
enum TextUtility: String, CaseIterable {
    case base64Encode, base64EncodePadded, base64EncodeUnix, base64EncodeLines, base64Decode, base64DecodeLines,
        base64DecodeStrict
    case quotedPrintableEncode, quotedPrintableDecode, samlDecode
    case urlEncode, urlEncodeExtended, urlEncodeFull, urlEncodeLines, urlEncodeExtendedLines, urlEncodeFullLines,
        urlDecode
    case hexEncode, hexDecode
    var title: String {
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
        case .hexEncode: return "UTF-8 to Hex"
        case .hexDecode: return "Hex to UTF-8"
        }
    }
    func apply(_ input: String) throws -> String {
        guard input.utf8.count <= 16 * 1024 * 1024 else { throw UtilityFailure.tooLarge }
        switch self {
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
            var output = ""
            var column = 0
            for b in input.utf8 {
                let token =
                    ((b > 32 && b < 127 && b != 61) || [9, 10, 13, 32].contains(b))
                    ? String(UnicodeScalar(b)) : String(format: "=%02X", b)
                column = b == 10 ? token.utf8.count : column + token.utf8.count
                if column >= 76 {
                    output += "=\r\n"
                    column = token.utf8.count
                }
                output += token
            }
            return output
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
                guard i + 2 < bytes.count else { throw UtilityFailure.malformed("quoted-printable") }
                if bytes[i + 1] == 13 && bytes[i + 2] == 10 {
                    i += 3
                    continue
                }
                guard let hi = Self.hex(bytes[i + 1]), let lo = Self.hex(bytes[i + 2]) else {
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
            let bytes = Array(data)
            if bytes.starts(with: Array("<?xml".utf8)) || bytes.starts(with: Array("<saml".utf8)) {
                return try Self.text(data)
            }
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw UtilityFailure.malformed("SAML deflate")
            }
            defer { inflateEnd(&stream) }
            var output = [UInt8](repeating: 0, count: 16 * 1024 * 1024 + 1)
            let status = bytes.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = uInt(source.count)
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.avail_in == 0, stream.total_out <= 16 * 1024 * 1024 else {
                throw UtilityFailure.malformed("SAML deflate or output limit")
            }
            let inflated = Data(output.prefix(Int(stream.total_out)))
            guard inflated.starts(with: Array("<?xml".utf8)) || inflated.starts(with: Array("<saml".utf8)) else {
                throw UtilityFailure.malformed("SAML XML")
            }
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
            return input.utf8.map { b in
                if [.urlEncodeLines, .urlEncodeExtendedLines, .urlEncodeFullLines].contains(self)
                    && (b == 10 || b == 13)
                {
                    return String(UnicodeScalar(b))
                }
                if self == .urlEncodeFull || self == .urlEncodeFullLines || b < 32 || b >= 127 || reserved.contains(b) {
                    return String(format: "%%%02X", b)
                }
                return String(UnicodeScalar(b))
            }.joined()
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
        case .hexEncode: return input.utf8.map { String(format: "%02X", $0) }.joined()
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
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
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
            if let n = alphabet.firstIndex(of: b) {
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
enum UtilityFailure: LocalizedError {
    case malformed(String), binaryResult, tooLarge, selectionRequired
    var errorDescription: String? {
        switch self {
        case .malformed(let format): return "Invalid \(format) input. The selection was not changed."
        case .binaryResult: return "The decoded bytes are not valid UTF-8 text. The selection was not changed."
        case .tooLarge: return "Select at most 16 MiB for this utility. The selection was not changed."
        case .selectionRequired: return "Select one nonempty text range before running a utility."
        }
    }
}

struct RadixConversion {
    static func convert(_ input: String, from: Int, to: Int) throws -> String {
        guard [2, 8, 10, 16].contains(from), [2, 8, 10, 16].contains(to), !input.isEmpty,
            input.utf8.allSatisfy({ b in
                if (48...57).contains(b) { return Int(b - 48) < from }
                return from == 16 && ((65...70).contains(b) || (97...102).contains(b))
            }), let value = UInt32(input, radix: from)
        else { throw UtilityFailure.malformed("unsigned 32-bit number") }
        return String(value, radix: to, uppercase: true)
    }
}

struct HexEncodingOptions {
    var insertSpaces = false
    var uppercase = true
    var bytesPerLine = 16
    var lineEnding = "\n"
    func encode(_ text: String) throws -> String {
        guard (0...65536).contains(bytesPerLine), ["\n", "\r", "\r\n"].contains(lineEnding),
            text.utf8.count <= 16 * 1024 * 1024
        else { throw UtilityFailure.malformed("hex options or input size") }
        var output = ""
        for (index, byte) in text.utf8.enumerated() {
            output += String(format: uppercase ? "%02X" : "%02x", byte)
            let lineBreak = bytesPerLine > 0 && (index + 1) % bytesPerLine == 0
            if lineBreak { output += lineEnding } else if insertSpaces { output += " " }
        }
        return output
    }
}
