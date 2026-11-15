// SPDX-License-Identifier: GPL-3.0-or-later
// One Unicode fixture table for every suite (audit finding G354). A suite adds this
// file to its swiftc line and runs each consumer it owns over `UnicodeFixtures.all`,
// so the same awkward inputs reach transforms, automations, filters and search.
import Foundation

enum UnicodeFixtures {
    /// Woman technologist, medium skin tone: four scalars joined by ZWJ, one character.
    static let zwjEmoji = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"
    /// The same letter spelled precomposed (NFC) and as base plus combining mark (NFD).
    static let nfc = "\u{E9}", nfd = "e\u{301}"
    /// MATHEMATICAL SCRIPT CAPITAL A: a letter outside the Basic Multilingual Plane.
    static let astralLetter = "\u{1D49C}"
    /// Characters Swift's `isNewline` and NSString line APIs treat as line breaks.
    /// TextTank's line model is CR, LF and CRLF only, so none of these ends a line.
    static let nonBreakingSeparators = ["\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}"]
    static let mixedEndings = "one\r\ntwo\rthree\nfour"
    /// The number of CR, LF and CRLF breaks in `text`, counted on bytes.
    static func lineBreaks(in text: String) -> Int {
        var count = 0, previousCR = false
        for byte in text.utf8 {
            if byte == 13 { count += 1; previousCR = true; continue }
            if byte == 10 && !previousCR { count += 1 }
            previousCR = false
        }
        return count
    }
    static let all: [(name: String, text: String)] = [
        ("ZWJ emoji", "b \(zwjEmoji)\na \(zwjEmoji)\n"),
        ("base plus combining mark", "\(nfd)b\n\(nfd)a\n"),
        ("NFC and NFD spellings", "\(nfd)\n\(nfc)\n\(nfd)\n"),
        ("mixed CRLF, CR and LF", mixedEndings),
        ("separators that are not line breaks", "b\u{2028}y\u{2029}\u{85}\na\u{0B}x\u{0C}"),
        ("embedded NUL", "b\0b\na\0a\n"),
        ("astral letter", "\(astralLetter)b\n\(astralLetter)a\n"),
    ]
}
