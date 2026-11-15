// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@main struct UtilityChecks {
    static func main() {
        Checks.run("UtilityChecks") {
            func rejectsMalformed(_ op: TextUtility, _ value: String, line: UInt = #line) {
                rejects("\(op) rejects malformed \(value.debugDescription)", line: line) { _ = try op.apply(value) }
            }
            check(try TextUtility.base64Encode.apply("f") == "Zg", "unpadded")
            check(try TextUtility.base64EncodePadded.apply("f") == "Zg==", "padded")
            for value in ["", "f", "fo", "foo", "\u{feff}leading", "café 👩🏽‍💻", "\0\u{feff}\r\n"] {
                check(
                    try TextUtility.base64DecodeStrict.apply(TextUtility.base64Encode.apply(value)) == value,
                    "base64 roundtrip")
                check(try TextUtility.urlDecode.apply(TextUtility.urlEncode.apply(value)) == value, "URL roundtrip")
                check(try TextUtility.hexDecode.apply(TextUtility.hexEncode.apply(value)) == value, "hex roundtrip")
            }
            check(try TextUtility.urlEncode.apply("a b+c~") == "a%20b+c%7E", "RFC1738 reserved")
            check(try TextUtility.urlEncodeExtended.apply("a+b") == "a%2Bb", "extended")
            check(try TextUtility.urlEncodeFull.apply("a\n") == "%61%0A", "full")
            check(try TextUtility.urlEncodeLines.apply("a b\r\nc d") == "a%20b\r\nc%20d", "by-line EOL")
            check(try TextUtility.urlDecode.apply("a+b") == "a+b", "plus is literal")
            check(try TextUtility.hexDecode.apply("41 42\n43\t44") == "ABCD", "pair whitespace")
            check(
                try TextUtility.base64EncodeUnix.apply(String(repeating: "a", count: 60)).split(separator: "\n").map(
                    \.count) == [64, 16], "64-column wrapping")
            for x in ["A", "Zg=", "Zg===", "Z=g=", "Zh==", "@@", "////"] { rejectsMalformed(.base64DecodeStrict, x) }
            for x in ["%", "%2", "%GG", "%FF"] { rejectsMalformed(.urlDecode, x) }
            for x in ["0", "0 0", "GG", "FF"] { rejectsMalformed(.hexDecode, x) }
            check(try TextUtility.base64EncodeLines.apply("f\r\nfo\n") == "Zg\r\nZm8\n", "base64 lines")
            check(try TextUtility.base64DecodeLines.apply("Zg\r\nZm8\n") == "f\r\nfo\n", "base64 decode lines")
            check(
                try TextUtility.base64Decode.apply("TWFyeQ==.aGFk.YQ.bGl0dGxl.bGFtYg==") == "Mary.had.a.little.lamb",
                "permissive segments")
            check(try TextUtility.quotedPrintableEncode.apply("café=\r\n") == "caf=C3=A9=3D\r\n", "QP UTF8")
            check(try TextUtility.quotedPrintableDecode.apply("caf=C3=\r\n=A9=3D") == "café=", "QP soft wrap")
            check(
                try TextUtility.quotedPrintableDecode.apply(
                    TextUtility.quotedPrintableEncode.apply(String(repeating: "é", count: 100)))
                    == String(repeating: "é", count: 100), "QP wrapping roundtrip")
            check(
                try TextUtility.samlDecode.apply("sylOzM2xCi5JLCkttnO20UfmAgA=") == "<saml:Status>C</saml:Status>",
                "SAML deflate")
            check(
                try TextUtility.samlDecode.apply(Data("<saml:Status>C</saml:Status>".utf8).base64EncodedString())
                    == "<saml:Status>C</saml:Status>", "SAML direct XML")
            for x in ["=", "=A", "=GG", "=FF"] { rejectsMalformed(.quotedPrintableDecode, x) }
            for x in ["%", "!!!", "YWJj", "sylOzM2xC04sySy2c9bRL4Zx7AA"] { rejectsMalformed(.samlDecode, x) }
            check(try RadixConversion.convert("4294967295", from: 10, to: 16) == "FFFFFFFF", "32-bit upper bound")
            check(try RadixConversion.convert("101010", from: 2, to: 8) == "52", "binary octal")
            for value in ["-1", "4294967296", "12x", ""] {
                rejects("radix conversion rejects \(value.debugDescription)") {
                    _ = try RadixConversion.convert(value, from: 10, to: 16)
                }
            }
            check(
                try HexEncodingOptions(insertSpaces: true, uppercase: false, bytesPerLine: 2, lineEnding: "\r\n")
                    .encode("aéb") == "61 c3\r\na9 62\r\n", "hex options encode bytes not characters")
            check(try HexEncodingOptions(bytesPerLine: 0).encode("café") == "636166C3A9", "hex unwrapped option")
            _ = NSApplication.shared
            let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = editor
            let controller = UtilityController(activeEditor: { editor })
            editor.text = "before café after"
            editor.resetUndoHistory()
            editor.setSavePoint()
            check(editor.setSelectionAnchor(7, caret: 12), "native Unicode selection")
            let menu = controller.makeMenu()
            let item = try requireValue(
                menu.items.first { ($0.representedObject as? String) == TextUtility.base64EncodePadded.rawValue },
                "fixture: padded Base64 menu item exists")
            check(NSApplication.shared.sendAction(item.action!, to: item.target, from: item), "menu dispatch")
            check(editor.text == "before Y2Fmw6k= after", "menu changes selected UTF8")
            editor.executeCommand("undo")
            check(editor.text == "before café after", "one Undo restores exact text")
            editor.text = "bad %GG"
            editor.resetUndoHistory()
            editor.setSavePoint()
            _ = editor.setSelectionAnchor(4, caret: 7)
            let revision = editor.revision
            rejects("malformed selection is rejected by the native command") { try controller.apply(.urlDecode) }
            check(
                editor.text == "bad %GG" && editor.revision == revision && !editor.modified,
                "failure preserves native bytes revision dirty")
            _ = editor.setSelectionAnchor(0, caret: 0)
            rejects("empty selection is rejected by the native command") { try controller.apply(.hexEncode) }
            editor.text = "int café = 42; // <script>&\n"
            editor.setLanguage("cpp")
            editor.resetUndoHistory()
            editor.setSavePoint()
            _ = editor.setSelectionAnchor(0, caret: 0)
            let exportRevision = editor.revision
            let (rtf, plain) = try controller.exportData(format: "rtf")
            let restored = try NSAttributedString(
                data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            check(restored.string == editor.text && plain == editor.text, "RTF Unicode content roundtrip")
            check(
                restored.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil, "RTF style attributes survive")
            let (html, _) = try controller.exportData(format: "html")
            let htmlText = String(data: html, encoding: .utf8)!
            check(htmlText.contains("&lt;script&gt;") && !htmlText.contains("// <script>"), "HTML escapes user markup")
            check(editor.revision == exportRevision && !editor.modified, "styled export leaves editor unchanged")
            _ = editor.setSelectionAnchor(4, caret: 9)
            let (_, selectionPlain) = try controller.exportData(format: "rtf")
            check(selectionPlain == "café", "styled export selection boundary")
            editor.readOnly = true
            rejects("read-only editor rejects the native command") { try controller.apply(.hexEncode) }
            editor.readOnly = false
            window.contentView = nil
            rejects("detached editor rejects the native command") { try controller.apply(.hexEncode) }
            rejects("detached editor rejects styled export") { _ = try controller.exportData(format: "rtf") }
            Checks.summary { "UtilityChecks: \(Checks.count) assertions passed" }
        }
    }
}
