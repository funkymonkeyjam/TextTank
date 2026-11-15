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
            // F278, F302: the hook that discards a macro recording fires when a utility changes
            // the document and at no other time.
            var unrecordableEdits = 0
            controller.onUnrecordableEdit = { unrecordableEdits += 1 }
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
            check(unrecordableEdits == 1, "a utility that changes the document reports one unrecordable edit")
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
            rejects("empty selection is rejected by the native command", expecting: UtilityFailure.selectionRequired) {
                try controller.apply(.hexEncode)
            }
            check(unrecordableEdits == 1, "a refused utility reports no unrecordable edit")
            // G397: each refusal names the precondition that actually failed, and changes nothing.
            editor.text = "one two"
            editor.resetUndoHistory()
            editor.setSavePoint()
            try require(
                editor.setSelectionRanges([["anchor": 0, "caret": 3], ["anchor": 4, "caret": 7]]),
                "fixture: two selections")
            let multiRevision = editor.revision
            rejects(
                "several selections are named as the reason a utility refuses",
                expecting: UtilityFailure.multipleSelections
            ) { try controller.apply(.hexEncode) }
            rejects(
                "several selections are named as the reason styled export refuses",
                expecting: UtilityFailure.multipleSelections
            ) { _ = try controller.exportData(format: "rtf") }
            check(
                editor.text == "one two" && editor.revision == multiRevision && !editor.modified
                    && editor.selectionCount == 2,
                "refusals for several selections leave text, revision and selections unchanged")
            // The recheck after a dialog reports what changed while it was open.
            _ = editor.setSelectionAnchor(0, caret: 3)
            let captured = editor.selectionRanges, capturedRevision = editor.revision
            check(
                try UtilityController.recheck(editor, captured: editor, revision: capturedRevision, selection: captured)
                    === editor, "an unchanged editor passes the recheck after a dialog")
            _ = editor.setSelectionAnchor(4, caret: 4)
            let caretOnly = editor.selectionRanges
            check(
                try UtilityController.recheck(
                    editor, captured: editor, revision: capturedRevision, selection: caretOnly)
                    === editor, "the recheck allows an empty single selection, for insertion at the caret")
            rejects("a moved selection is reported as a changed document", expecting: UtilityFailure.documentChanged) {
                _ = try UtilityController.recheck(
                    editor, captured: editor, revision: capturedRevision, selection: captured)
            }
            let other = TTEditor(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            rejects(
                "a different active editor is reported as a changed document", expecting: UtilityFailure.documentChanged
            ) {
                _ = try UtilityController.recheck(
                    editor, captured: other, revision: capturedRevision, selection: caretOnly)
            }
            rejects("a detached editor is reported as no open document", expecting: UtilityFailure.noDocument) {
                _ = try UtilityController.recheck(other, captured: other, revision: other.revision, selection: nil)
            }
            rejects("no editor at all is reported as no open document", expecting: UtilityFailure.noDocument) {
                _ = try UtilityController.recheck(
                    nil, captured: editor, revision: capturedRevision, selection: captured)
            }
            editor.readOnly = true
            rejects(
                "Read Only switched on during a dialog is reported as read-only", message: "This document is read-only"
            ) {
                _ = try UtilityController.recheck(
                    editor, captured: editor, revision: capturedRevision, selection: caretOnly)
            }
            editor.readOnly = false
            editor.replaceSelection("x")
            rejects(
                "an edit made during a dialog is reported as a changed document",
                expecting: UtilityFailure.documentChanged
            ) {
                _ = try UtilityController.recheck(
                    editor, captured: editor, revision: capturedRevision, selection: editor.selectionRanges)
            }
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
            check(unrecordableEdits == 1, "a styled export reports no unrecordable edit")
            let htmlText = String(data: html, encoding: .utf8)!
            check(htmlText.contains("&lt;script&gt;") && !htmlText.contains("// <script>"), "HTML escapes user markup")
            check(editor.revision == exportRevision && !editor.modified, "styled export leaves editor unchanged")
            _ = editor.setSelectionAnchor(4, caret: 9)
            let (_, selectionPlain) = try controller.exportData(format: "rtf")
            check(selectionPlain == "café", "styled export selection boundary")
            // The two dialog utilities. In each modal the menu item presents, the next named
            // button is clicked; a dialog still open after 20 s is aborted and reported.
            func buttons(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? [] + view.subviews.flatMap(buttons)
            }
            func choose(_ title: String, _ answers: [String]) -> Bool {
                var remaining = answers, timedOut = false
                let deadline = Date().addingTimeInterval(20)
                let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
                    guard let content = NSApp.modalWindow?.contentView else { return }
                    if Date() > deadline {
                        timedOut = true
                        NSApp.abortModal()
                        return
                    }
                    guard let next = remaining.first, let button = buttons(content).first(where: { $0.title == next })
                    else { return }
                    remaining.removeFirst()
                    button.performClick(nil)
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                defer { timer.invalidate() }
                guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
                    return false
                }
                return NSApp.sendAction(action, to: item.target, from: item) && remaining.isEmpty && !timedOut
            }
            func load(_ text: String) -> UInt {
                editor.text = text
                editor.resetUndoHistory()
                editor.setSavePoint()
                editor.executeCommand("selectAll")
                return editor.revision
            }
            var dialogRevision = load("abc")
            check(
                choose("UTF-8 to Hex with Options…", ["Cancel"]) && editor.text == "abc"
                    && editor.revision == dialogRevision && unrecordableEdits == 1,
                "Cancel in Hex Encoding Options changes nothing and reports no unrecordable edit")
            check(
                choose("UTF-8 to Hex with Options…", ["Apply"]) && editor.text.hasPrefix("616263")
                    && unrecordableEdits == 2,
                "Apply in Hex Encoding Options replaces the selection and reports one unrecordable edit")
            dialogRevision = load("255")
            check(
                choose("Number Conversion…", ["Cancel"]) && choose("Number Conversion…", ["Convert", "Cancel"])
                    && editor.text == "255" && editor.revision == dialogRevision && unrecordableEdits == 2,
                "opening, converting and cancelling Number Conversion changes nothing and reports no unrecordable edit")
            check(
                choose("Number Conversion…", ["Convert", "Insert into Editor"]) && editor.text.uppercased() == "FF"
                    && unrecordableEdits == 3,
                "Insert into Editor from Number Conversion reports one unrecordable edit")
            editor.executeCommand("undo")
            check(editor.text == "255" && !editor.modified, "the inserted conversion is one Undo")
            editor.readOnly = true
            let lockedRevision = editor.revision
            rejects("read-only editor rejects the native command as read-only", message: "This document is read-only") {
                try controller.apply(.hexEncode)
            }
            _ = editor.setSelectionAnchor(0, caret: 0)
            rejects("read-only is reported before an empty selection", message: "This document is read-only") {
                try controller.apply(.hexEncode)
            }
            check(
                editor.revision == lockedRevision && !editor.modified,
                "a utility refused as read-only leaves revision and save point unchanged")
            check(
                (try? controller.exportData(format: "rtf")) != nil,
                "styled export of a read-only document still works, as it changes nothing")
            editor.readOnly = false
            window.contentView = nil
            rejects(
                "detached editor rejects the native command as no open document", expecting: UtilityFailure.noDocument
            ) { try controller.apply(.hexEncode) }
            rejects("detached editor rejects styled export as no open document", expecting: UtilityFailure.noDocument) {
                _ = try controller.exportData(format: "rtf")
            }
            Checks.summary { "UtilityChecks: \(Checks.count) assertions passed" }
        }
    }
}
