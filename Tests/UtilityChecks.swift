@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch
import zlib
@MainActor private final class UtilityDialogState {
    var remaining: [String]
    var timedOut = false
    init(_ answers: [String]) { remaining = answers }
}
@MainActor private final class UtilityHexState { var stage = 0, draftKept = false }

@main struct UtilityChecks {
    @MainActor static func main() {
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
            // F89: a soft line break is "=" followed by CRLF, LF or CR, as found in an LF document.
            check(try TextUtility.quotedPrintableDecode.apply("caf=C3=\n=A9=3D") == "café=", "QP LF soft break")
            check(try TextUtility.quotedPrintableDecode.apply("caf=C3=\r=A9=3D") == "café=", "QP CR soft break")
            for ending in ["\n", "\r", "\r\n"] {
                check(
                    try TextUtility.quotedPrintableDecode.apply("abc=" + ending) == "abc",
                    "QP soft break \(ending.debugDescription) at the end of the input")
            }
            check(
                try TextUtility.quotedPrintableDecode.apply("a=\r\n\nb") == "a\nb",
                "QP CRLF is one soft break; the LF after it stays literal")
            for x in ["=\n=G", "a=", "=\nG=", "=\r=4"] { rejectsMalformed(.quotedPrintableDecode, x) }
            let longLine = String(repeating: "a", count: 80)
            check(
                try TextUtility.quotedPrintableEncode.apply(longLine)
                    == String(repeating: "a", count: 75) + "=\r\n" + String(repeating: "a", count: 5),
                "QP encoder keeps its CRLF soft break at 76 columns")
            check(
                try TextUtility.quotedPrintableEncode.apply("a \tb\n\u{7f}\0=é")
                    == "a \tb\n=7F=00=3D=C3=A9", "QP encoder byte classes are unchanged")
            // F100: any XML root is accepted, directly or deflated; the bytes come back unchanged.
            func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
            func rawDeflate(_ bytes: [UInt8]) throws -> Data {
                var stream = z_stream()
                try require(
                    deflateInit2_(
                        &stream, Z_BEST_SPEED, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                        Int32(MemoryLayout<z_stream>.size)) == Z_OK, "fixture: deflate starts")
                defer { deflateEnd(&stream) }
                var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(bytes.count))))
                var input = bytes
                let (status, produced): (Int32, Int) = input.withUnsafeMutableBufferPointer { source in
                    output.withUnsafeMutableBufferPointer { destination in
                        stream.next_in = source.baseAddress
                        stream.avail_in = uInt(source.count)
                        stream.next_out = destination.baseAddress
                        stream.avail_out = uInt(destination.count)
                        let status = deflate(&stream, Z_FINISH)
                        return (status, destination.count - Int(stream.avail_out))
                    }
                }
                try require(status == Z_STREAM_END, "fixture: deflate finishes")
                return Data(output.prefix(produced))
            }
            let response = "<Response xmlns=\"urn:oasis:names:tc:SAML:2.0:protocol\"/>"
            for xml in [response, "<ns2:AuthnRequest/>", "<md:EntityDescriptor/>"] {
                check(try TextUtility.samlDecode.apply(base64(xml)) == xml, "SAML direct \(xml.prefix(12)) root")
            }
            check(
                try TextUtility.samlDecode.apply(rawDeflate(Array(response.utf8)).base64EncodedString()) == response,
                "SAML deflated default-namespace root")
            let padded = "\u{feff}\n <saml:Status>C</saml:Status>"
            check(try TextUtility.samlDecode.apply(base64(padded)) == padded, "SAML keeps a leading BOM and whitespace")
            check(
                try TextUtility.samlDecode.apply(rawDeflate(Array(padded.utf8)).base64EncodedString()) == padded,
                "SAML deflated payload keeps a leading BOM and whitespace")
            rejectsMalformed(.samlDecode, (try rawDeflate(Array(response.utf8)) + Data([0])).base64EncodedString())
            rejectsMalformed(.samlDecode, try rawDeflate(Array("abc".utf8)).base64EncodedString())
            rejectsMalformed(.samlDecode, Data([0x3C, 0xFF]).base64EncodedString())
            rejectsMalformed(.samlDecode, try rawDeflate([0x3C, 0xFF]).base64EncodedString())
            let limit = 16 * 1024 * 1024
            let atLimit = [UInt8(60)] + [UInt8](repeating: 97, count: limit - 1)
            check(
                try TextUtility.samlDecode.apply(rawDeflate(atLimit).base64EncodedString()).utf8.count == limit,
                "SAML inflate accepts exactly 16 MiB")
            rejects("SAML inflate rejects 16 MiB + 1") {
                _ = try TextUtility.samlDecode.apply(rawDeflate(atLimit + [97]).base64EncodedString())
            }
            // F101: the table encoders give the bytes the per-byte format calls gave.
            let everyByte =
                String(decoding: (0..<128).map { UInt8($0) }, as: UTF8.self) + "é👩🏽‍💻\u{feff}\r\n" + "\u{7ff}\u{ffff}"
            func formatted(_ format: String, _ text: String, keep: (UInt8) -> Bool = { _ in false }) -> String {
                text.utf8.map { keep($0) ? String(UnicodeScalar($0)) : String(format: format, $0) }.joined()
            }
            let rfc1738 = Set("<>\"#%{}|\\^~[]`;/?:@=& ".utf8), extended = rfc1738.union("!*'()+$,".utf8)
            func literal(_ reserved: Set<UInt8>, lines: Bool) -> (UInt8) -> Bool {
                { b in (lines && (b == 10 || b == 13)) || !(b < 32 || b >= 127 || reserved.contains(b)) }
            }
            for (utility, keep): (TextUtility, (UInt8) -> Bool) in [
                (.urlEncode, literal(rfc1738, lines: false)), (.urlEncodeLines, literal(rfc1738, lines: true)),
                (.urlEncodeExtended, literal(extended, lines: false)),
                (.urlEncodeExtendedLines, literal(extended, lines: true)), (.urlEncodeFull, { _ in false }),
                (.urlEncodeFullLines, { $0 == 10 || $0 == 13 })
            ] {
                check(
                    try utility.apply(everyByte) == formatted("%%%02X", everyByte, keep: keep),
                    "\(utility) is byte-identical for every byte value")
            }
            check(try TextUtility.hexEncode.apply(everyByte) == formatted("%02X", everyByte), "hex encode every byte")
            check(
                try HexEncodingOptions(uppercase: false, bytesPerLine: 0).encode(everyByte)
                    == formatted("%02x", everyByte), "lowercase hex encode every byte")
            check(
                try TextUtility.quotedPrintableDecode.apply(TextUtility.quotedPrintableEncode.apply(everyByte))
                    == everyByte, "QP roundtrip for every byte value")
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
            check(
                try alphabet.enumerated().allSatisfy { index, symbol in
                    try TextUtility.base64Decode.apply("AAA" + String(symbol))
                        == "\0\0" + String(UnicodeScalar(UInt8(index)))
                }, "Base64 decode table gives every symbol its value")
            check(
                try TextUtility.base64Decode.apply(TextUtility.base64Encode.apply(everyByte)) == everyByte
                    && TextUtility.base64DecodeLines.apply("Zg\tZm8 -") == "f\tfo -",
                "permissive Base64 keeps roundtrips and literal separators")
            let bulk = String(repeating: "caf\u{e9} \u{1F98B}\n", count: 48 * 1024)
            func seconds(_ work: () throws -> Void) rethrows -> Double {
                let start = ProcessInfo.processInfo.systemUptime
                try work()
                return ProcessInfo.processInfo.systemUptime - start
            }
            var reference = "", produced = ""
            let slow = seconds { reference = formatted("%02X", bulk) }
            let fast = try seconds { produced = try TextUtility.hexEncode.apply(bulk) }
            check(produced == reference, "bulk hex encode matches the per-byte reference")
            check(
                fast * 3 < slow,
                "hex encode of \(bulk.utf8.count) bytes does not make one format call per byte (\(fast) s against \(slow) s)"
            )
            // F102: separators go between bytes; a completed line keeps its line ending.
            check(
                try HexEncodingOptions(insertSpaces: true, bytesPerLine: 0).encode("AB") == "41 42",
                "hex with spaces has no trailing space")
            check(
                try HexEncodingOptions(insertSpaces: true, bytesPerLine: 2, lineEnding: "\n").encode("ABC")
                    == "41 42\n43", "hex with spaces has no trailing space on a partial last line")
            check(
                try TextUtility.hexDecode.apply(
                    HexEncodingOptions(insertSpaces: true, bytesPerLine: 3, lineEnding: "\r\n").encode(everyByte))
                    == everyByte, "spaced and wrapped hex still decodes to the same text")
            for (value, expected) in [("255\n", "FF"), (" 255\r\n", "FF"), ("\t10 ", "A")] {
                check(
                    try RadixConversion.convert(value, from: 10, to: 16) == expected,
                    "number conversion ignores surrounding whitespace in \(value.debugDescription)")
            }
            for value in ["2 5", "\n", "25\n5"] {
                rejects("radix conversion rejects \(value.debugDescription)") {
                    _ = try RadixConversion.convert(value, from: 10, to: 16)
                }
            }
            check(
                UtilityController.numberConversionNote.contains("Insert into Editor")
                    && !UtilityController.numberConversionNote.contains("does not change"),
                "the number conversion note agrees with its Insert button")
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
            let runtimeSupport = try IsolatedSupportDirectory("UtilityChecksRuntime")
            defer { runtimeSupport.restore() }
            NativeFixtureEnvironment.install()
            defer { NativeFixtureEnvironment.restore() }
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
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
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
                editor.setSelectionRanges([TTSelectionRange(anchor: 0, caret: 3), TTSelectionRange(anchor: 4, caret: 7)]
                ),
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
            @MainActor func buttons(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? [] + view.subviews.flatMap(buttons)
            }
            @MainActor func choose(_ title: String, _ answers: [String]) -> Bool {
                let dialog = UtilityDialogState(answers)
                let deadline = Date().addingTimeInterval(20)
                let timer = Timer(timeInterval: 0.005, repeats: true) { _ in
                    precondition(Thread.isMainThread)
                    MainActor.assumeIsolated {
                        guard let content = NSApp.modalWindow?.contentView else { return }
                        if Date() > deadline {
                            dialog.timedOut = true
                            NSApp.abortModal()
                            return
                        }
                        guard let next = dialog.remaining.first,
                            let button = buttons(content).first(where: { $0.title == next })
                        else { return }
                        dialog.remaining.removeFirst()
                        button.performClick(nil)
                    }
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                defer { timer.invalidate() }
                guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else {
                    return false
                }
                return NSApp.sendAction(action, to: item.target, from: item) && dialog.remaining.isEmpty
                    && !dialog.timedOut
            }
            @MainActor func load(_ text: String) -> UInt {
                editor.text = text
                editor.resetUndoHistory()
                editor.setSavePoint()
                editor.executeCommand(TTEditorCommandIdentifier(rawValue: "selectAll"))
                return editor.revision
            }
            // Only disposable PRIVATE boards participate in these explicit clipboard actions.
            // The pre-repair direct-general branches are a source-only red: never execute them.
            let ownedBoard = NSPasteboard.withUniqueName()
            defer { ownedBoard.releaseGlobally() }
            let previousEffects = RuntimeEnvironment.dependencies
            var ownedEffects = RuntimeEnvironment.current
            ownedEffects.generalPasteboard = { ownedBoard }
            RuntimeEnvironment.dependencies = ownedEffects
            defer { RuntimeEnvironment.dependencies = previousEffects }
            let copyRevision = load("café")
            let copyRecording = unrecordableEdits
            check(
                choose("Copy Styled Text as HTML", []),
                "F269 styled-copy menu dispatch uses the owned clipboard capability")
            check(
                ownedBoard.string(forType: .string) == "café" && ownedBoard.data(forType: .html) != nil,
                "F269 actual styled-copy action writes HTML and exact plain text to the private board")
            check(
                editor.revision == copyRevision && !editor.modified && unrecordableEdits == copyRecording,
                "F269 styled clipboard export leaves document and recording state unchanged")
            _ = load("255")
            check(
                choose("Number Conversion…", ["Convert", "Copy"]) && ownedBoard.string(forType: .string) == "FF",
                "F269 actual radix Copy writes only the explicitly owned private board")
            var deniedEffects = ownedEffects
            deniedEffects.generalPasteboard = { nil }
            RuntimeEnvironment.dependencies = deniedEffects
            let sentinel = ownedBoard.string(forType: .string), beforeDenial = ownedBoard.changeCount
            rejects("F269 nil clipboard capability refuses radix copy before clearing or writing") {
                try controller.copyConvertedNumber("denied")
            }
            rejects("F269 nil clipboard capability refuses styled copy before clearing or writing") {
                try controller.copyStyledToClipboard(format: "html")
            }
            check(
                ownedBoard.string(forType: .string) == sentinel && ownedBoard.changeCount == beforeDenial,
                "F269 refused clipboard actions preserve every private-board write boundary")
            RuntimeEnvironment.dependencies = ownedEffects
            var dialogRevision = load("abc")
            check(
                choose("UTF-8 to Hex with Options…", ["Cancel"]) && editor.text == "abc"
                    && editor.revision == dialogRevision && unrecordableEdits == 1,
                "Cancel in Hex Encoding Options changes nothing and reports no unrecordable edit")
            let hex = UtilityHexState()
            let hexDeadline = Date().addingTimeInterval(10)
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let hexRetry = Timer(timeInterval: 0.01, repeats: true) { _ in
                precondition(Thread.isMainThread)
                MainActor.assumeIsolated {
                    guard let content = NSApp.modalWindow?.contentView else { return }
                    let views = descendants(content)
                    if Date() > hexDeadline {
                        NSApp.abortModal()
                        return
                    }
                    guard let width = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
                        let apply = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Apply" })
                    else {
                        views.compactMap { $0 as? NSButton }.first?.performClick(nil)
                        return
                    }
                    if hex.stage == 0 {
                        width.stringValue = "invalid width"
                        hex.stage = 1
                        apply.performClick(nil)
                    } else if hex.stage == 1 {
                        hex.draftKept = width.stringValue == "invalid width"
                        views.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }?.performClick(nil)
                        hex.stage = 2
                    }
                }
            }
            RunLoop.main.add(hexRetry, forMode: .modalPanel)
            let hexItem = menu.items.first { $0.title == "UTF-8 to Hex with Options…" }!
            _ = NSApp.sendAction(hexItem.action!, to: hexItem.target, from: hexItem)
            hexRetry.invalidate()
            check(hex.stage == 2 && hex.draftKept, "F214 invalid Hex options retain their input for correction")
            check(
                editor.text == "abc" && editor.revision == dialogRevision && unrecordableEdits == 1,
                "F214 cancelling invalid Hex options preserves text revision and recording state")
            check(
                choose("UTF-8 to Hex with Options…", ["Apply"]) && editor.text.hasPrefix("616263")
                    && unrecordableEdits == 2,
                "Apply in Hex Encoding Options replaces the selection and reports one unrecordable edit")
            dialogRevision = load("255")
            check(
                choose("Number Conversion…", ["Cancel"]) && choose("Number Conversion…", ["Convert", "Done"])
                    && editor.text == "255" && editor.revision == dialogRevision && unrecordableEdits == 2,
                "opening, converting and cancelling Number Conversion changes nothing and reports no unrecordable edit")
            check(
                choose("Number Conversion…", ["Convert", "Insert into Editor"]) && editor.text.uppercased() == "FF"
                    && unrecordableEdits == 3,
                "Insert into Editor from Number Conversion reports one unrecordable edit")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
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
