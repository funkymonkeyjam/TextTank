// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package enum FileEncoding: String, Codable, CaseIterable, Sendable {
    case utf8, utf16LE, utf16BE, windows1252, latin1
    package var displayName: String {
        switch self {
        case .utf8: return Strings.text("encoding.utf8", "UTF-8")
        case .utf16LE: return Strings.text("encoding.utf16le", "UTF-16 LE")
        case .utf16BE: return Strings.text("encoding.utf16be", "UTF-16 BE")
        case .windows1252: return Strings.text("encoding.windows1252", "Windows-1252")
        case .latin1: return Strings.text("encoding.latin1", "ISO-8859-1")
        }
    }
}

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
package struct FileFormat: Codable, Equatable, Sendable {
    package init(encoding: FileEncoding = .utf8, bom: Bool = false) {
        self.encoding = encoding
        self.bom = bom
    }

    package var encoding: FileEncoding
    package var bom: Bool
    package struct Target {
        package init(code: String, format: FileFormat) {
            self.code = code
            self.format = format
        }

        package let code: String
        package let format: FileFormat
        package var title: String {
            if format.bom {
                return String(format: Strings.text("encoding.bom", "%@ with BOM"), format.encoding.displayName)
            }
            return format.encoding.displayName
        }
    }
    static package let convertTargets: [Target] = [
        .init(code: "utf8", format: .init(encoding: .utf8)),
        .init(code: "utf8bom", format: .init(encoding: .utf8, bom: true)),
        .init(code: "utf16LE", format: .init(encoding: .utf16LE, bom: true)),
        .init(code: "utf16BE", format: .init(encoding: .utf16BE, bom: true)),
        .init(code: "windows1252", format: .init(encoding: .windows1252)),
        .init(code: "latin1", format: .init(encoding: .latin1))
    ]
}

package struct DecodedFile {
    package init(text: String, format: FileFormat) {
        self.text = text
        self.format = format
    }

    package let text: String
    package let format: FileFormat
}

package enum FileCodecError: Error, LocalizedError, Equatable {
    case invalidBytes(FileEncoding), unrepresentable(FileEncoding), unsupportedBOM, unsupportedUTF32,
        invalidConversionTarget
    package var errorDescription: String? {
        switch self {
        case .invalidBytes(let e):
            return
                "The file contains invalid \(e.displayName) bytes. Choose an explicit encoding; no bytes were replaced."
        case .unrepresentable(let e):
            return "This text cannot be saved as \(e.displayName) without losing characters. Choose a Unicode encoding."
        case .unsupportedUTF32:
            return
                "This file begins with a UTF-32 signature. UTF-32 is not supported yet; choose UTF-16 explicitly only if the file is known to begin with a NUL character."
        case .invalidConversionTarget:
            return
                "This encoding choice is unavailable. Choose an encoding from the menu; the document was not changed."
        case .unsupportedBOM: return "This encoding does not support a byte-order mark."
        }
    }
}

/// The ending a document inserts for new line breaks. Detection reads the first line break
/// only: it is deterministic and cheap, and existing endings are never rewritten by it.
package enum LineEnding: String, CaseIterable {
    case lf = "LF", crlf = "CRLF", cr = "CR"
    /// CR LF gives CRLF, a lone CR gives CR, LF gives LF; text with no line break gives LF.
    static package func detect(in text: String) -> LineEnding {
        var priorCR = false
        for byte in text.utf8 {
            if priorCR { return byte == 10 ? .crlf : .cr }
            if byte == 10 { return .lf }
            priorCR = byte == 13
        }
        return priorCR ? .cr : .lf
    }
}

/// Pure codec: never normalizes line endings and never guesses a legacy encoding.
package enum FileCodec {
    private static let cp1252: [UInt32?] = [
        0x20AC, nil, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, nil, 0x017D, nil,
        nil, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, nil, 0x017E, 0x0178
    ]
    static package func decode(_ data: Data) throws -> DecodedFile {
        // UTF-32LE overlaps UTF-16LE + leading NUL. Do not silently interpret an
        // apparent UTF-32 file as editable UTF-16; explicit UTF-16 selection remains valid.
        if data.starts(with: [0xFF, 0xFE, 0, 0]) || data.starts(with: [0, 0, 0xFE, 0xFF]) {
            throw FileCodecError.unsupportedUTF32
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return try decode(data, encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return try decode(data, encoding: .utf16LE) }
        if data.starts(with: [0xFE, 0xFF]) { return try decode(data, encoding: .utf16BE) }
        return try decode(data, encoding: .utf8)
    }
    /// Strict UTF-8 content with no external BOM interpretation. Works on the macOS 14 deployment target.
    package static func decodeUTF8Content(_ bytes: UnsafeRawBufferPointer) -> String? {
        var decoded = String(decoding: bytes, as: UTF8.self)
        let exact = decoded.withUTF8 { utf8 in
            utf8.count == bytes.count
                && (bytes.isEmpty || memcmp(utf8.baseAddress!, bytes.baseAddress!, bytes.count) == 0)
        }
        return exact ? decoded : nil
    }

    /// Validates and decodes in place: the bytes are read where they are, with no intermediate
    /// array, and each encoding builds its text in one pass.
    static package func decode(_ data: Data, encoding: FileEncoding) throws -> DecodedFile {
        let marker = bomBytes(encoding)
        let hasBOM = !marker.isEmpty && data.starts(with: marker)
        let text: String = try data.withUnsafeBytes { (all: UnsafeRawBufferPointer) throws -> String in
            let bytes = UnsafeRawBufferPointer(rebasing: all[(hasBOM ? marker.count : 0)...])
            switch encoding {
            case .utf8:
                guard let decoded = decodeUTF8Content(bytes) else { throw FileCodecError.invalidBytes(encoding) }
                return decoded
            case .utf16LE, .utf16BE:
                guard bytes.count % 2 == 0 else { throw FileCodecError.invalidBytes(encoding) }
                // One pass reads each code unit in file byte order and rejects an unpaired
                // surrogate, so the transcoding below never has anything to repair.
                let little = encoding == .utf16LE
                var valid = true
                let words = [UInt16](unsafeUninitializedCapacity: bytes.count / 2) { buffer, initialized in
                    var pendingHigh = false
                    for i in 0..<bytes.count / 2 {
                        let first = UInt16(bytes[2 * i]), second = UInt16(bytes[2 * i + 1])
                        let word = little ? first | second << 8 : first << 8 | second
                        let low = word & 0xFC00 == 0xDC00
                        if pendingHigh != low { valid = false }
                        pendingHigh = word & 0xFC00 == 0xD800
                        buffer[i] = word
                    }
                    if pendingHigh { valid = false }
                    initialized = bytes.count / 2
                }
                guard valid else { throw FileCodecError.invalidBytes(encoding) }
                return String(decoding: words, as: UTF16.self)
            case .latin1, .windows1252:
                // Every byte maps to one scalar of at most three UTF-8 bytes.
                var utf8: [UInt8] = []
                utf8.reserveCapacity(bytes.count + bytes.count / 2)
                for b in bytes {
                    if b < 0x80 {
                        utf8.append(b)
                        continue
                    }
                    var value = UInt32(b)
                    if encoding == .windows1252 && b <= 0x9F {
                        guard let mapped = cp1252[Int(b - 0x80)] else { throw FileCodecError.invalidBytes(encoding) }
                        value = mapped
                    }
                    if value < 0x800 {
                        utf8.append(UInt8(0xC0 | value >> 6))
                    } else {
                        utf8.append(UInt8(0xE0 | value >> 12))
                        utf8.append(UInt8(0x80 | (value >> 6) & 0x3F))
                    }
                    utf8.append(UInt8(0x80 | value & 0x3F))
                }
                return String(decoding: utf8, as: UTF8.self)
            }
        }
        return DecodedFile(text: text, format: FileFormat(encoding: encoding, bom: hasBOM))
    }
    static package func encode(_ text: String, format: FileFormat) throws -> Data {
        let marker = bomBytes(format.encoding)
        if format.bom && marker.isEmpty { throw FileCodecError.unsupportedBOM }
        let prefix = format.bom ? marker : []
        switch format.encoding {
        case .utf8:
            // The text's own UTF-8 storage is copied once, straight into the result.
            var source = text
            return source.withUTF8 { utf8 in
                var data = Data(capacity: prefix.count + utf8.count)
                data.append(contentsOf: prefix)
                data.append(utf8)
                return data
            }
        case .utf16LE, .utf16BE:
            let little = format.encoding == .utf16LE
            var bytes = prefix
            bytes.reserveCapacity(prefix.count + 2 * text.utf16.count)
            for word in text.utf16 {
                let low = UInt8(word & 255), high = UInt8(word >> 8)
                bytes.append(little ? low : high)
                bytes.append(little ? high : low)
            }
            return Data(bytes)
        case .latin1, .windows1252:
            var bytes = prefix
            bytes.reserveCapacity(text.utf8.count)
            for scalar in text.unicodeScalars {
                let value = scalar.value
                if value < 0x80 || (value >= 0xA0 && value <= 0xFF) || (format.encoding == .latin1 && value <= 0xFF) {
                    bytes.append(UInt8(value))
                } else if format.encoding == .windows1252, let index = cp1252.firstIndex(where: { $0 == value }) {
                    bytes.append(UInt8(index + 0x80))
                } else {
                    throw FileCodecError.unrepresentable(format.encoding)
                }
            }
            return Data(bytes)
        }
    }
    private static func bomBytes(_ encoding: FileEncoding) -> [UInt8] {
        switch encoding {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }
}
