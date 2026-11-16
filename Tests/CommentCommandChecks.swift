// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@main struct CommentCommandChecks {
    static func main() {
        Checks.run("CommentCommandChecks") {
            let catalog = try LanguageCatalog.decode(
                Data(contentsOf: TestPaths.resources.appendingPathComponent("LanguageProfiles.json")))
            func profile(_ id: String) throws -> LanguageProfile {
                try requireValue(catalog.profiles.first { $0.id == id }, "fixture: \(id) profile exists")
            }
            let python = try profile("python"), cpp = try profile("cpp"), html = try profile("html")
            func selection(_ a: Int, _ c: Int) -> [EditorSelection] {
                [EditorSelection(anchor: a, caret: c)]
            }
            let text = "  café 🥑\r\n\tvalue\r\nlast"
            let end = "  café 🥑\r\n\tvalue\r\n".utf8.count
            let first = try CommentCommand.toggleLine.plan(text: text, selections: selection(end, 0), profile: python)
            check(
                first.text == "  # café 🥑\r\n\t# value\r\nlast",
                "indent Unicode CRLF preserved; line-start endpoint excludes next line")
            check(
                first.selections[0].anchor > first.selections[0].caret,
                "reverse selection direction preserved")
            let restored = try CommentCommand.toggleLine.plan(
                text: first.text, selections: first.selections, profile: python)
            check(restored.text == text, "toggle roundtrip with adjusted selection")
            let mixed = try CommentCommand.toggleLine.plan(
                text: "# first\nsecond\n\n", selections: selection(0, 15), profile: python)
            check(
                mixed.text == "first\n# second\n\n",
                "reference toggle treats each line independently and skips empty lines")
            let absent = try CommentCommand.lineUncomment.plan(
                text: "plain", selections: selection(0, 0), profile: python)
            check(absent.text == "plain", "uncomment plain text is no-op")
            let block = try CommentCommand.blockComment.plan(
                text: "café + 🥑", selections: selection(0, "café + 🥑".utf8.count), profile: cpp)
            check(block.text == "/* café + 🥑 */", "block comment wraps exact Unicode selection")
            check(
                try CommentCommand.blockUncomment.plan(text: block.text, selections: block.selections, profile: cpp)
                    .text == "café + 🥑", "block removal immediately after wrapping uses preserved inner selection")
            let unblocked = try CommentCommand.blockUncomment.plan(
                text: block.text, selections: selection(0, block.text.utf8.count), profile: cpp)
            check(unblocked.text == "café + 🥑", "block removal exact")
            let interior = try CommentCommand.blockUncomment.plan(
                text: "before /* inner */ after", selections: selection(12, 12), profile: cpp)
            check(interior.text == "before inner after", "caret inside enclosing block removes only delimiters")
            let xml = try CommentCommand.toggleLine.plan(text: "<node/>\n", selections: selection(0, 0), profile: html)
            check(xml.text == "<!-- <node/> -->\n", "line operation falls back to paired language delimiters")
            rejects("overlapping block selections reject before mutation") {
                _ = try CommentCommand.blockComment.plan(
                    text: "abcdef", selections: selection(0, 4) + selection(2, 6), profile: cpp)
            }
            rejects("closing delimiter prevents invalid nested wrapping") {
                _ = try CommentCommand.blockComment.plan(text: "a */ b", selections: selection(0, 6), profile: cpp)
            }
            rejects("missing block marker rejected") {
                _ = try CommentCommand.blockComment.plan(text: "x", selections: selection(0, 1), profile: python)
            }
            rejects("split UTF8 rejected") {
                _ = try CommentCommand.toggleLine.plan(text: "🥑", selections: selection(1, 2), profile: python)
            }
            let overlap = selection(0, 1) + selection(1, 2)
            check(
                try CommentCommand.toggleLine.plan(text: "abc\n", selections: overlap, profile: python).text
                    == "# abc\n", "shared selected line commented only once")
            // F3: a caret at the end of an unterminated last line is on that line.
            let eof = try CommentCommand.toggleLine.plan(text: "x = 1", selections: selection(5, 5), profile: python)
            check(
                eof.text == "# x = 1" && eof.selections[0].anchor == 7
                    && eof.selections[0].caret == 7,
                "toggle at end of unterminated last line comments it and maps the caret")
            check(
                try CommentCommand.lineComment.plan(text: "x = 1", selections: selection(5, 5), profile: python).text
                    == "# x = 1", "comment at end of unterminated last line")
            check(
                try CommentCommand.lineUncomment.plan(text: "# x = 1", selections: selection(7, 7), profile: python)
                    .text == "x = 1", "uncomment at end of unterminated last line")
            check(
                try CommentCommand.toggleLine.plan(text: "abc\n", selections: selection(4, 4), profile: python).text
                    == "abc\n", "caret on empty line after final LF leaves previous line alone")
            check(
                try CommentCommand.toggleLine.plan(text: "abc\r\n", selections: selection(5, 5), profile: python).text
                    == "abc\r\n", "caret on empty line after final CRLF leaves previous line alone")
            check(
                try CommentCommand.toggleLine.plan(text: "a\nb", selections: selection(1, 1), profile: python).text
                    == "# a\nb", "caret at end of terminated line touches only that line")
            // G350: block delimiters are matched as bytes, never by canonical equivalence.
            func synthetic(_ id: String, line: String? = nil, open: String? = nil, close: String? = nil)
                -> LanguageProfile
            {
                LanguageProfile(
                    id: id, title: id, lexer: "null", extensions: [], keywordLists: [:], referenceKeywordClasses: [:],
                    properties: [:], styles: [], comments: .init(line: line, blockOpen: open, blockClose: close))
            }
            func sameBytes(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }
            func repaired(_ text: String) -> Bool { text.unicodeScalars.contains("\u{FFFD}") }
            let accent = synthetic("accent", open: "\u{e9}", close: "\u{e9}")
            let decomposed = "e\u{301} body e\u{301}"
            let wrapped = try CommentCommand.toggleLine.plan(
                text: decomposed, selections: selection(0, 0), profile: accent)
            check(
                sameBytes(wrapped.text, "\u{e9} " + decomposed + " \u{e9}") && !repaired(wrapped.text),
                "a precomposed delimiter does not match decomposed text, so the line is wrapped, not cut")
            check(
                sameBytes(
                    try CommentCommand.toggleLine.plan(
                        text: wrapped.text, selections: wrapped.selections, profile: accent
                    )
                    .text, decomposed), "non-ASCII block delimiters round-trip byte-exact through toggle")
            rejects("block removal does not treat decomposed text as a precomposed delimiter") {
                _ = try CommentCommand.blockUncomment.plan(
                    text: decomposed, selections: selection(5, 5), profile: accent)
            }
            check(
                sameBytes(
                    try CommentCommand.blockUncomment.plan(
                        text: "a \u{e9} e\u{301} \u{e9} b", selections: selection(6, 6), profile: accent
                    ).text, "a e\u{301} b"), "block removal finds non-ASCII delimiters around the caret by bytes")
            rejects("closing delimiter followed by a combining mark still prevents wrapping") {
                _ = try CommentCommand.blockComment.plan(
                    text: "x*/\u{301}", selections: selection(0, "x*/\u{301}".utf8.count), profile: cpp)
            }
            rejects("line fallback rejects a closing delimiter followed by a combining mark") {
                _ = try CommentCommand.toggleLine.plan(
                    text: "a -->\u{301} b", selections: selection(0, 0), profile: html)
            }
            check(
                sameBytes(
                    try CommentCommand.blockUncomment.plan(
                        text: "/* a */\u{301} b", selections: selection(4, 4), profile: cpp
                    ).text, "a\u{301} b"), "a closing delimiter followed by a combining mark is recognised")
            // The line marker keeps its Unicode case folding, compared as bytes on a character boundary.
            let batch = try profile("batch"), fortran = try profile("fortran77")
            check(
                try CommentCommand.toggleLine.plan(text: "rem echo", selections: selection(0, 0), profile: batch).text
                    == "echo"
                    && CommentCommand.lineUncomment.plan(text: "rem echo", selections: selection(0, 0), profile: batch)
                        .text == "echo",
                "lower-case batch marker uncomments through toggle and uncomment")
            check(
                try CommentCommand.toggleLine.plan(text: "c note", selections: selection(0, 0), profile: fortran).text
                    == "note", "lower-case fortran77 marker in column 0 uncomments")
            let cyrillic = synthetic("cyrillic", line: "\u{420}\u{415}\u{41C}")
            check(
                try CommentCommand.toggleLine.plan(
                    text: "\u{440}\u{435}\u{43C} x", selections: selection(0, 0), profile: cyrillic
                ).text == "x", "non-ASCII line marker still matches case-insensitively")
            let replacementMarker = synthetic("replacement", line: "\u{FFFD}")
            check(
                sameBytes(
                    try CommentCommand.toggleLine.plan(
                        text: "\u{1F951}x", selections: selection(0, 0), profile: replacementMarker
                    ).text, "\u{FFFD} \u{1F951}x"), "a line marker never matches part of a longer UTF-8 sequence")
            let inputs = [
                text, decomposed, wrapped.text, "x*/\u{301}", "<!--\u{301} x -->", "e\u{301}", "\u{1F951}x",
                "rem \u{e9}",
                "/* caf\u{e9} */\u{301}", "\u{440}\u{435}\u{43C} x"
            ]
            var clean = true
            for input in inputs {
                for candidate in [python, cpp, html, batch, fortran, accent, cyrillic] {
                    for command in CommentCommand.allCases {
                        for chosen in [selection(0, 0), selection(0, input.utf8.count), selection(input.utf8.count, 0)]
                        {
                            if let planned = try? command.plan(text: input, selections: chosen, profile: candidate),
                                repaired(planned.text)
                            {
                                clean = false
                            }
                        }
                    }
                }
            }
            check(clean, "no comment plan introduces U+FFFD into text that had none")
            _ = NSApplication.shared
            let
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                    defer: false), editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            window.contentView = editor
            editor.text = text
            editor.resetUndoHistory()
            editor.setSavePoint()
            _ = editor.setSelectionRanges(
                selection(end, 0).map { TTSelectionRange(anchor: $0.anchor, caret: $0.caret) })
            try CommentCommand.toggleLine.apply(to: editor, profile: python)
            check(
                editor.text == first.text && editor.selectionAnchor > editor.selectionCaret,
                "native comment applies with reversed mapped selection")
            editor.executeCommand("undo")
            check(editor.text == text && !editor.modified, "one Undo restores exact original and save point")
            editor.readOnly = true
            let originalSelection = editor.selectionRanges
            rejects("read-only comment rejects") { try CommentCommand.toggleLine.apply(to: editor, profile: python) }
            check(
                editor.text == text && editor.selectionRanges == originalSelection,
                "read-only comment preserves selection and bytes")
            editor.readOnly = false
            editor.text = "x = 1"
            editor.resetUndoHistory()
            editor.setSavePoint()
            _ = editor.setSelectionAnchor(5, caret: 5)
            try CommentCommand.toggleLine.apply(to: editor, profile: python)
            check(
                editor.text == "# x = 1" && editor.selectionAnchor == 7 && editor.selectionCaret == 7,
                "native toggle at end of unterminated last line")
            editor.executeCommand("undo")
            check(editor.text == "x = 1" && !editor.modified, "native end-of-file toggle is one Undo")
            // F4: comment commands edit only the bytes they change.
            let tall = (0..<200).map { "value\($0) = \($0)\n" }.joined()
            let line1 = "value0 = 0\n".utf8.count, line4 = (0..<4).map { "value\($0) = \($0)\n" }.joined().utf8.count
            editor.text = tall
            editor.resetUndoHistory()
            editor.setSavePoint()
            check(editor.setBookmarks([0, 3, 150]), "fixture: bookmarks on lines 0, 3 and 150")
            _ = editor.setSelectionRanges(
                selection(line1, line1).map { TTSelectionRange(anchor: $0.anchor, caret: $0.caret) })
            check(editor.firstVisibleLine == 0, "fixture: the view starts at the top")
            try CommentCommand.toggleLine.apply(to: editor, profile: python)
            check(
                editor.text == tall.replacingOccurrences(of: "value1 = 1\n", with: "# value1 = 1\n"),
                "native toggle changes only the caret line")
            check(editor.bookmarkLines == [0, 3, 150], "comment toggle keeps bookmarks on their lines")
            check(editor.firstVisibleLine == 0, "comment toggle leaves the view at the caret, not at the document end")
            editor.executeCommand("undo")
            check(
                editor.text == tall && !editor.modified && editor.bookmarkLines == [0, 3, 150],
                "bookmarks survive the Undo of a comment toggle")
            let three = selection(line4, line1)
            _ = editor.setSelectionRanges(three.map { TTSelectionRange(anchor: $0.anchor, caret: $0.caret) })
            let multi = try CommentCommand.lineComment.plan(text: tall, selections: three, profile: python)
            check(multi.edits.count == 3, "plan exposes one edit per changed line")
            try CommentCommand.lineComment.apply(to: editor, profile: python)
            check(
                editor.text == multi.text
                    && editor.selectionRanges.map { EditorSelection(anchor: $0.anchor, caret: $0.caret) }
                        == multi.selections
                    && editor.bookmarkLines == [0, 3, 150],
                "three-line comment applies the planned text and selection and keeps bookmarks")
            editor.executeCommand("undo")
            check(editor.text == tall && !editor.modified, "one Undo restores a multi-line comment and the save point")
            check(
                editor.selectionRanges.map { EditorSelection(anchor: $0.anchor, caret: $0.caret) } == three,
                "Undo restores the selection the comment command started from")
            // Two carets inside one removed marker map to the same position; the edit still applies.
            editor.text = "# x"
            editor.resetUndoHistory()
            _ = editor.setSelectionRanges(
                (selection(0, 0) + selection(1, 1)).map { TTSelectionRange(anchor: $0.anchor, caret: $0.caret) })
            try CommentCommand.lineUncomment.apply(to: editor, profile: python)
            check(
                editor.text == "x" && editor.selectionCaret == 0,
                "carets that collapse onto one position still apply the comment edit")
            editor.executeCommand("undo")
            check(editor.text == "# x", "collapsed-caret comment edit is one Undo")
            Checks.summary { "PASS CommentCommandChecks: \(Checks.count) assertions" }
        }
    }
}
