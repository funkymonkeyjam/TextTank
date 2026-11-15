// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum FileEncoding: String, Codable, CaseIterable {
    case utf8, utf16LE, utf16BE, windows1252, latin1
}

struct FileFormat: Codable, Equatable {
    var encoding: FileEncoding = .utf8
    var bom: Bool = false
}

struct DecodedFile {
    let text: String
    let format: FileFormat
}

enum FileCodecError: Error, LocalizedError {
    case invalidBytes(FileEncoding), unrepresentable(FileEncoding), unsupportedBOM, unsupportedUTF32
    var errorDescription: String? {
        switch self {
        case .invalidBytes(let e): return "The file contains invalid \(e.rawValue) bytes. Choose an explicit encoding; no bytes were replaced."
        case .unrepresentable(let e): return "This text cannot be saved as \(e.rawValue) without losing characters. Choose a Unicode encoding."
        case .unsupportedUTF32: return "This file begins with a UTF-32 signature. UTF-32 is not supported yet; choose UTF-16 explicitly only if the file is known to begin with a NUL character."
        case .unsupportedBOM: return "This encoding does not support a byte-order mark."
        }
    }
}

/// The ending a document inserts for new line breaks. Detection reads the first line break
/// only: it is deterministic and cheap, and existing endings are never rewritten by it.
enum LineEnding: String, CaseIterable {
    case lf = "LF", crlf = "CRLF", cr = "CR"
    /// CR LF gives CRLF, a lone CR gives CR, LF gives LF; text with no line break gives LF.
    static func detect(in text: String) -> LineEnding {
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
struct FileCodec {
    private static let cp1252: [UInt32?] = [
        0x20AC,nil,0x201A,0x0192,0x201E,0x2026,0x2020,0x2021,
        0x02C6,0x2030,0x0160,0x2039,0x0152,nil,0x017D,nil,
        nil,0x2018,0x2019,0x201C,0x201D,0x2022,0x2013,0x2014,
        0x02DC,0x2122,0x0161,0x203A,0x0153,nil,0x017E,0x0178
    ]
    static func decode(_ data: Data) throws -> DecodedFile {
        // UTF-32LE overlaps UTF-16LE + leading NUL. Do not silently interpret an
        // apparent UTF-32 file as editable UTF-16; explicit UTF-16 selection remains valid.
        if data.starts(with: [0xFF,0xFE,0,0]) || data.starts(with: [0,0,0xFE,0xFF]) {
            throw FileCodecError.unsupportedUTF32
        }
        if data.starts(with: [0xEF,0xBB,0xBF]) { return try decode(data, encoding: .utf8) }
        if data.starts(with: [0xFF,0xFE]) { return try decode(data, encoding: .utf16LE) }
        if data.starts(with: [0xFE,0xFF]) { return try decode(data, encoding: .utf16BE) }
        return try decode(data, encoding: .utf8)
    }
    static func decode(_ data: Data, encoding: FileEncoding) throws -> DecodedFile {
        var bytes = Array(data)
        let marker = bomBytes(encoding)
        let hasBOM = !marker.isEmpty && bytes.starts(with: marker)
        if hasBOM { bytes.removeFirst(marker.count) }
        var scalars = String.UnicodeScalarView()
        let text: String
        switch encoding {
        case .utf8:
            // String(decoding:as:) preserves a leading U+FEFF on macOS 14.
            // Its replacement behavior is rejected by exact UTF-8 byte comparison.
            let decoded = String(decoding: bytes, as: UTF8.self)
            guard decoded.utf8.elementsEqual(bytes) else { throw FileCodecError.invalidBytes(encoding) }
            text = decoded
        case .utf16LE, .utf16BE:
            guard bytes.count % 2 == 0 else { throw FileCodecError.invalidBytes(encoding) }
            let words: [UInt16] = stride(from: 0, to: bytes.count, by: 2).map { i in
                encoding == .utf16LE ? UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8 : UInt16(bytes[i]) << 8 | UInt16(bytes[i+1])
            }
            var i = 0
            while i < words.count {
                let w = words[i]; var scalar = UInt32(w)
                if (0xD800...0xDBFF).contains(w) {
                    guard i + 1 < words.count, (0xDC00...0xDFFF).contains(words[i+1]) else { throw FileCodecError.invalidBytes(encoding) }
                    scalar = 0x10000 + (UInt32(w - 0xD800) << 10) + UInt32(words[i+1] - 0xDC00); i += 1
                } else if (0xDC00...0xDFFF).contains(w) { throw FileCodecError.invalidBytes(encoding) }
                guard let s = UnicodeScalar(scalar) else { throw FileCodecError.invalidBytes(encoding) }
                scalars.append(s); i += 1
            }
            text = String(scalars)
        case .latin1, .windows1252:
            for b in bytes {
                let value: UInt32?
                if encoding == .windows1252 && b >= 0x80 && b <= 0x9F { value = cp1252[Int(b - 0x80)] }
                else { value = UInt32(b) }
                guard let value, let scalar = UnicodeScalar(value) else { throw FileCodecError.invalidBytes(encoding) }
                scalars.append(scalar)
            }
            text = String(scalars)
        }
        return DecodedFile(text: text, format: FileFormat(encoding: encoding, bom: hasBOM))
    }
    static func encode(_ text: String, format: FileFormat) throws -> Data {
        let marker = bomBytes(format.encoding)
        if format.bom && marker.isEmpty { throw FileCodecError.unsupportedBOM }
        var bytes: [UInt8] = format.bom ? marker : []
        switch format.encoding {
        case .utf8: bytes.append(contentsOf: text.utf8)
        case .utf16LE, .utf16BE:
            for word in text.utf16 {
                let low = UInt8(word & 255), high = UInt8(word >> 8)
                bytes.append(contentsOf: format.encoding == .utf16LE ? [low,high] : [high,low])
            }
        case .latin1, .windows1252:
            for scalar in text.unicodeScalars {
                let value = scalar.value
                if value < 0x80 || (value >= 0xA0 && value <= 0xFF) || (format.encoding == .latin1 && value <= 0xFF) {
                    bytes.append(UInt8(value))
                } else if format.encoding == .windows1252, let index = cp1252.firstIndex(where: { $0 == value }) {
                    bytes.append(UInt8(index + 0x80))
                } else { throw FileCodecError.unrepresentable(format.encoding) }
            }
        }
        return Data(bytes)
    }
    private static func bomBytes(_ encoding: FileEncoding) -> [UInt8] {
        switch encoding {
        case .utf8: return [0xEF,0xBB,0xBF]
        case .utf16LE: return [0xFF,0xFE]
        case .utf16BE: return [0xFE,0xFF]
        default: return []
        }
    }
}
