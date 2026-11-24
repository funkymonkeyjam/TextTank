@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
// Audit package 4: behaviour pinned before refactoring. These sections run inside
// document-checks, after the sections in DocumentChecks.swift, and share its
// support directory, application delegate and document controller.
//
// Expected values here were written from the code's documented intent and then
// compared with what the build does. A `knownDefect` line marks behaviour the audit
// confirmed as wrong: it is not pinned as correct, and it fails when it is repaired.
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

@MainActor private final class ColumnExplanation { var text = "" }

extension DocumentChecks {
    typealias SectionRunner = (_ name: String, _ line: UInt, _ body: () throws -> Void) -> Void

    /// Sends a Scintilla message by number to the engine view inside a TTEditor.
    @MainActor static func sci(_ editor: TTEditor, _ message: UInt32, _ w: UInt = 0, _ l: Int = 0) -> Int {
        typealias Message = @convention(c) (AnyObject, Selector, UInt32, UInt, Int) -> Int
        let native = editor.subviews.first!, selector = NSSelectorFromString("message:wParam:lParam:")
        return unsafeBitCast(native.method(for: selector), to: Message.self)(native, selector, message, w, l)
    }
    static func rows(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = [], content = ""
        for character in text {
            if character == "\r\n" || character == "\r" || character == "\n" {
                result.append((content, String(character)))
                content = ""
            } else {
                content.append(character)
            }
        }
        if !content.isEmpty || result.isEmpty { result.append((content, "")) }
        return result
    }
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// DS-23: the menu levels that list more than twenty items, as "path (count)". Separators and
    /// hidden shortcut aliases are not listed items. Lists of the person's own content are exempt,
    /// because their length is the person's: Open Recent and Reopen Recent File, saved macros,
    /// automations and Run commands (items whose represented object is a UUID), and the windows
    /// AppKit adds to the Window menu. The system fills Services.
    @MainActor static func menuLevelsOverTwenty(_ bar: NSMenu) -> [String] {
        func userContent(_ item: NSMenuItem) -> Bool {
            item.representedObject is URL
                || (item.representedObject as? String).flatMap(UUID.init(uuidString:)) != nil
                || item.action == #selector(NSWindow.makeKeyAndOrderFront(_:))
        }
        func crowded(_ menu: NSMenu, _ path: String) -> [String] {
            guard menu !== NSApp.servicesMenu, !(menu.delegate is RecentDocumentsMenu) else { return [] }
            let listed = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && !userContent($0) }
            return (listed.count > 20 ? ["\(path) (\(listed.count))"] : [])
                + menu.items.flatMap { item in item.submenu.map { crowded($0, path + " > " + item.title) } ?? [] }
        }
        return crowded(bar, "Menu bar")
    }

    @MainActor static func pinning(root: URL, app: NSApplication, sessionDelegate: AppDelegate, section: SectionRunner)
    {
        // F252
        section("every line and case transform", #line) {
            let table: [(EditorTransform, String, String, String)] = [
                (
                    .sortAscending, "b\r\na\nc", "a\r\nb\nc",
                    "ascending sort keeps each separator in place and adds no final line ending"
                ),
                (.sortDescending, "b\r\na\nc", "c\r\nb\na", "descending sort keeps each separator in place"),
                (
                    .sortCaseInsensitive, "b\nA\na\nB\n", "A\na\nb\nB\n",
                    "case-insensitive sort keeps input order between rows that differ only in case"
                ),
                (
                    .sortLength, "ccc\ne\u{301}e\u{301}\nz\n", "z\nccc\ne\u{301}e\u{301}\n",
                    "length sort counts Unicode scalars, consistent with native character counts"
                ),
                (.reverseLines, "a\r\nb\rc\n", "c\r\nb\ra\n", "reverse keeps the separator sequence"),
                (
                    .uniqueLines, "a\nA\na\r\nb", "a\nA\nb",
                    "duplicate removal is case-sensitive and drops the later row with its separator"
                ),
                (
                    .removeEmptyLines, "a\n\nb\r\n\r\n \nc", "a\nb\r\n \nc",
                    "empty rows go with their separators; a whitespace-only row is not empty"
                ),
                (
                    .trimLeading, " \ta \n\tb", "a \nb",
                    "leading trim removes spaces and tabs only at the start of each row"
                ),
                (
                    .trimBoth, "\u{3000}a \n b\t\r\n", "\u{3000}a\nb\r\n",
                    "trim removes ASCII space and tab only, not other Unicode spaces"
                ),
                (
                    .invertCase, "Hello W\u{F6}rld 1 \u{1F600}\r\n", "hELLO w\u{D6}RLD 1 \u{1F600}\r\n",
                    "invert case swaps cased letters and leaves digits, emoji and line endings"
                ),
                (
                    .titleCase, "hello wORLD\r\nsecond line", "Hello World\r\nSecond Line",
                    "title case capitalizes each word and keeps line endings"
                ),
                (
                    .sortLocalized, "item 10\r\nZucchini\n\u{C9}clairs\napples\nitem 9",
                    "apples\r\n\u{C9}clairs\nitem 9\nitem 10\nZucchini",
                    "locale sort puts accents and case second, numbers by value, and keeps each separator in place"
                )
            ]
            check(
                Set(table.map { $0.0 }) == Set(EditorTransform.allCases),
                "the transform table covers every EditorTransform case")
            for (transform, input, expected, label) in table {
                let output = transform.transform(input)
                if !check(same(output, expected), "\(transform.rawValue): \(label)") {
                    print("NOTE \(transform.rawValue) produced \(output.debugDescription)")
                }
            }
            check(
                same(EditorTransform.sortAscending.transform("e\u{301}\n\u{E9}\n"), "e\u{301}\n\u{E9}\n")
                    && same(EditorTransform.sortAscending.transform("\u{E9}\ne\u{301}\n"), "\u{E9}\ne\u{301}\n"),
                "canonically equivalent rows sort as equal and keep their input order and bytes")
            check(
                same(EditorTransform.removeEmptyLines.transform("\n\n"), "")
                    && same(EditorTransform.sortAscending.transform(""), "")
                    && same(EditorTransform.reverseLines.transform("only"), "only"),
                "transforms accept empty, all-empty and single-row input")
            // apply(to:) paths
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: .titled, backing: .buffered,
                defer: false)
            let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            window.contentView = editor
            editor.text = "c\nb\na\nz\ny\n"
            editor.resetUndoHistory()
            editor.setSavePoint()
            _ = editor.setSelectionAnchor(0, caret: 6)
            try EditorTransform.sortAscending.apply(to: editor)
            check(editor.text == "a\nb\nc\nz\ny\n", "a transform with a selection changes only the selected rows")
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                editor.text == "c\nb\na\nz\ny\n" && !editor.modified,
                "selection transform is one Undo back to the save point")
            _ = editor.setSelectionAnchor(6, caret: 6)
            editor.text = "a\nb\n"
            editor.resetUndoHistory()
            editor.setSavePoint()
            let sortedRevision = editor.revision
            try EditorTransform.sortAscending.apply(to: editor)
            check(
                editor.revision == sortedRevision && !editor.modified, "a transform that changes nothing makes no edit")
            editor.text = "b\na\n"
            editor.resetUndoHistory()
            editor.setSavePoint()
            editor.readOnly = true
            let lockedRevision = editor.revision
            rejects("transform refuses a read-only document", message: "This document is read-only") {
                try EditorTransform.sortAscending.apply(to: editor)
            }
            check(
                editor.text == "b\na\n" && editor.revision == lockedRevision,
                "refused read-only transform leaves text and revision unchanged")
            editor.readOnly = false
            try require(
                editor.setSelectionRanges([TTSelectionRange(anchor: 0, caret: 1), TTSelectionRange(anchor: 2, caret: 3)]
                ),
                "fixture: two selections")
            rejects("transform refuses multiple selections", message: "This command works on a single selection") {
                try EditorTransform.reverseLines.apply(to: editor)
            }
            check(
                editor.text == "b\na\n" && editor.revision == lockedRevision && editor.selectionCount == 2,
                "refused multi-selection transform leaves text, revision and selections unchanged")
            let oversize = String(repeating: "a", count: 16 * 1024 * 1024 + 1)
            editor.text = oversize
            editor.resetUndoHistory()
            _ = editor.setSelectionAnchor(0, caret: 0)
            let oversizeRevision = editor.revision
            rejects("transform refuses more than 16 MiB", message: "Select at most 16 MiB") {
                try EditorTransform.invertCase.apply(to: editor)
            }
            check(
                editor.revision == oversizeRevision && editor.text.utf8.count == oversize.utf8.count,
                "refused oversize transform leaves the buffer unchanged")
            editor.text = ""
        }
        // G354
        section("shared Unicode fixtures", #line) {
            let idempotent: [EditorTransform] = [
                .sortAscending, .sortDescending, .sortCaseInsensitive, .sortLength, .uniqueLines, .removeEmptyLines,
                .trimLeading, .trimBoth, .titleCase
            ]
            let reordering: [EditorTransform] = [
                .sortAscending, .sortDescending, .sortCaseInsensitive, .sortLength, .reverseLines
            ]
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: .titled, backing: .buffered,
                defer: false)
            let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            window.contentView = editor
            for (name, text) in UnicodeFixtures.all {
                let before = rows(text)
                check(
                    idempotent.allSatisfy { same($0.transform($0.transform(text)), $0.transform(text)) },
                    "\(name): every sorting, filtering, trimming and title transform is stable when repeated")
                check(
                    reordering.allSatisfy { transform in
                        let after = rows(transform.transform(text))
                        return after.map { $0.1 } == before.map { $0.1 }
                            && after.map { Data($0.0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
                                == before.map { Data($0.0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
                    }, "\(name): reordering transforms keep every row's exact bytes and the separator sequence")
                check(
                    same(EditorTransform.reverseLines.transform(EditorTransform.reverseLines.transform(text)), text),
                    "\(name): reversing twice restores the exact bytes")
                editor.text = text
                check(
                    same(editor.text, text)
                        && editor.statusInfo.lines == UnicodeFixtures.lineBreaks(in: text) + 1,
                    "\(name): the editor keeps the exact bytes and counts only CR, LF and CRLF as line breaks")
                // The status bar's position at the end of the text: the line is counted in CR, LF and
                // CRLF breaks, the column in Unicode scalars after the last break (current behaviour:
                // a ZWJ emoji is four columns and a combining mark is its own column).
                let lastRow =
                    text.unicodeScalars.split(
                        omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" }
                    ).last?.count ?? 0
                check(
                    editor.setSelectionAnchor(text.utf8.count, caret: text.utf8.count)
                        && editor.statusInfo.line == UnicodeFixtures.lineBreaks(in: text) + 1
                        && editor.statusInfo.column == lastRow + 1,
                    "\(name): the status line and column at the end of the text count CR/LF breaks and scalars")
            }
            // The line model is CR, LF and CRLF only. Swift's isNewline and NSString's line
            // APIs also break on these characters, so a rewrite on top of them would change this.
            let single = "b" + UnicodeFixtures.nonBreakingSeparators.joined(separator: "a") + "c"
            check(
                EditorTransform.allCases.filter { $0 != .invertCase && $0 != .titleCase }.allSatisfy {
                    same($0.transform(single), single)
                }, "U+2028, U+2029, U+0085, VT and FF are not line breaks for any line transform")
            check(
                rows(single).count == 1 && UnicodeFixtures.lineBreaks(in: single) == 0,
                "fixture: the separator row has no CR or LF")
            var automation = AutomationDefinition.recipeFixture
            automation.steps = [.init(kind: .sortLines)]
            check(
                same(try automation.transform("b\u{2028}y\na\u{85}x\n"), "a\u{85}x\nb\u{2028}y\n"),
                "automation sort does not split rows at U+2028 or U+0085")
            automation.steps = [.init(kind: .removeBlankLines)]
            check(
                same(try automation.transform("a\u{2028}\u{2029}\n\nb\n"), "a\u{2028}\u{2029}\nb\n"),
                "automation blank-line removal does not treat U+2028 or U+2029 as a row")
            automation.steps = [.init(kind: .trimWhitespace)]
            check(
                same(
                    try automation.transform(" \(UnicodeFixtures.zwjEmoji) \n\t\(UnicodeFixtures.nfd)\0 \n"),
                    "\(UnicodeFixtures.zwjEmoji)\n\(UnicodeFixtures.nfd)\0\n"),
                "automation trim keeps ZWJ emoji, combining marks and NUL intact")
            automation.steps = [.init(kind: .clearLinesContaining, find: "needle")]
            check(
                same(
                    try automation.transform(
                        "\(UnicodeFixtures.astralLetter) needle\n\(UnicodeFixtures.astralLetter) keep\n"),
                    "\n\(UnicodeFixtures.astralLetter) keep\n"),
                "automation contains-filter empties the matching row beside an astral letter and keeps its separator")
            automation.steps = [.init(kind: .clearLinesStartingWith, find: UnicodeFixtures.zwjEmoji)]
            check(
                same(
                    try automation.transform("\(UnicodeFixtures.zwjEmoji) gone\nkept \(UnicodeFixtures.zwjEmoji)\n"),
                    "\nkept \(UnicodeFixtures.zwjEmoji)\n"),
                "automation starts-with filter matches a whole ZWJ emoji prefix and keeps the row separator")
            let wide = "\(UnicodeFixtures.zwjEmoji)\(UnicodeFixtures.nfd)"
            editor.text = wide
            check(
                editor.setSelectionAnchor(wide.utf8.count, caret: wide.utf8.count)
                    && editor.statusInfo.column == 7,
                "the status column after a ZWJ emoji and a combining pair counts six scalars, not two characters")
            automation.steps = [.init(kind: .clearLinesEqualTo, find: UnicodeFixtures.zwjEmoji)]
            check(
                same(
                    try automation.transform(
                        "\(UnicodeFixtures.zwjEmoji)\r\n\(UnicodeFixtures.zwjEmoji) kept\r\n\u{1F469}\r\n"),
                    "\r\n\(UnicodeFixtures.zwjEmoji) kept\r\n\u{1F469}\r\n"),
                "automation equal-to filter empties only the row that is the whole ZWJ emoji and keeps its separator")
            automation.steps = [.init(kind: .clearLinesEqualTo, find: "a\0a")]
            check(
                same(try automation.transform("b\0b\na\0a\n"), "b\0b\n\n"),
                "automation equal-to filter compares across an embedded NUL")
            // Confirmed defects (G354 and the findings it lists). Each states the repaired behaviour.
            automation.steps = [.init(kind: .clearLinesEqualTo, find: UnicodeFixtures.nfc)]
            check(
                same(
                    try automation.transform("\(UnicodeFixtures.nfc)\n\(UnicodeFixtures.nfd)\n"),
                    "\n\(UnicodeFixtures.nfd)\n"),
                "automation equal-to filter keeps a canonically equivalent row whose bytes differ")
            // CR, CRLF and LF in one text: the classic result of a botched conversion. The guard that
            // promises "Mixed endings were not changed" has to refuse it.
            automation.steps = [.init(kind: .sortLines)]
            check(
                (try? automation.transform(UnicodeFixtures.mixedEndings)) == nil,
                "automation sort refuses the mixed CRLF, CR and LF fixture")
            check(
                (try? automation.transform("a\r\r\n\nb")) == nil,
                "automation sort refuses a text whose CR, CRLF and LF run together")
            automation.steps = [.init(kind: .deduplicateLines)]
            check(
                same(
                    try automation.transform("\(UnicodeFixtures.nfc)\n\(UnicodeFixtures.nfd)\n"),
                    "\(UnicodeFixtures.nfc)\n\(UnicodeFixtures.nfd)\n"),
                "automation dedupe keeps canonically equivalent rows whose bytes differ, as Remove Duplicate Lines does"
            )
            check(
                same(
                    EditorTransform.invertCase.transform(EditorTransform.invertCase.transform("stra\u{DF}e")),
                    "stra\u{DF}e"), "Invert Case applied twice restores the original text for \u{DF}")
            // Repaired by G344: this was a G354 known-defect line.
            check(
                FolderSearchFilters.matches("caf\(UnicodeFixtures.nfd).txt", "caf\(UnicodeFixtures.nfc).*"),
                "a filename glob typed precomposed matches a decomposed file name")
            var word = SearchOptions()
            word.query = "cat"
            word.wholeWord = true
            word.matchCase = true
            // Repaired by G349: both were G354 known-defect lines.
            check(
                try SearchCore.search("\(UnicodeFixtures.astralLetter)cat cat", options: word).hits.count == 1,
                "literal whole-word search does not match inside a word that continues with an astral letter")
            word.mode = .regularExpression
            check(
                try SearchCore.search("\(UnicodeFixtures.astralLetter)cat cat", options: word).hits.count == 1,
                "regex whole-word search does not match inside a word that continues with an astral letter")
            var half = SearchOptions()
            half.query = "\\uD83D"
            half.mode = .extended
            half.matchCase = true
            // The search engine refuses the query outright; it must not come back as "no matches".
            rejects(
                "an extended-mode escape for half a surrogate pair is rejected, not searched for inside a character",
                message: "surrogate"
            ) { _ = try SearchCore.search("a\u{1F600}b", options: half) }
        }
        // F243
        section("launch recovery and dirty quit", #line) {
            let namedURL = root.appendingPathComponent("recovery-original.txt"), originalBytes = Data("on disk".utf8)
            try originalBytes.write(to: namedURL)
            let namedFormat = FileFormat(encoding: .utf16LE, bom: true), namedText = "named \u{1F600}\r\nwork",
                untitledText = "untitled work\n"
            let named = RecoverySnapshot(
                id: UUID(), text: namedText, format: namedFormat, originalURL: namedURL.absoluteString, revision: 41)
            let untitled = RecoverySnapshot(
                id: UUID(), text: untitledText, format: FileFormat(encoding: .utf8, bom: false), originalURL: nil,
                revision: 3)
            try TextDocument.recovery.save(named)
            try TextDocument.recovery.save(untitled)
            let original = try DocumentFactory.openCaptured(
                WorkspaceStore.captureRegularFile(namedURL), from: namedURL, display: false)
            original.editor.replaceSelection("unsaved original ")
            let originalDraft = original.editor.checkedUTF8Data
            let opened = try sessionDelegate.openRecovered([named, untitled])
            try require(opened.count == 2, "fixture: both snapshots opened")
            check(
                opened[0].recoveryID == named.id && opened[0].editor.text == namedText
                    && opened[0].format == namedFormat && opened[0].isDocumentEdited && opened[0].fileURL == nil,
                "launch recovery maps a named UTF-16 snapshot to an unsaved untitled document with its id, text and format"
            )
            check(
                opened[1].recoveryID == untitled.id && opened[1].editor.text == untitledText
                    && opened[1].format == untitled.format && opened[1].isDocumentEdited && opened[1].fileURL == nil,
                "launch recovery maps an untitled UTF-8 snapshot the same way")
            check(
                opened.allSatisfy {
                    NSDocumentController.shared.documents.contains($0) && $0.windowControllers.count == 1
                }, "recovered documents are registered and have a window controller")
            // A recovered draft keeps its original location as metadata and acquires no save destination.
            opened[0].flushRecovery()
            let firstWrite = try TextDocument.recovery.load(id: named.id)
            check(
                opened[0].lastRecoveryError == nil && firstWrite.revision > 41 && firstWrite.originalURL == named.originalURL
                    && opened[0].fileURL == nil
                    && firstWrite.text == namedText && firstWrite.format == namedFormat,
                "first flush advances the revision and keeps the original association on an unsaved recovered document"
            )
            opened[0].editor.replaceSelection("edited ")
            opened[0].flushRecovery()
            let secondWrite = try TextDocument.recovery.load(id: named.id)
            check(
                secondWrite.revision > firstWrite.revision && secondWrite.text == opened[0].editor.text
                    && opened[0].lastRecoveryError == nil,
                "an edit after recovery is flushed at a higher revision with the edited text")
            // An empty snapshot is the case where setting the text does not advance the editor's
            // own revision, so only the +1 on the snapshot revision makes the first write later.
            let emptyNamed = RecoverySnapshot(
                id: UUID(), text: "", format: FileFormat(), originalURL: namedURL.absoluteString, revision: 9)
            try TextDocument.recovery.save(emptyNamed)
            let emptyOpened = try sessionDelegate.openRecovered([emptyNamed])
            let emptyWrite = try TextDocument.recovery.load(id: emptyNamed.id)
            check(
                emptyOpened[0].lastRecoveryError == nil && emptyWrite.revision > 9 && emptyWrite.originalURL == emptyNamed.originalURL
                    && emptyOpened[0].fileURL == nil && emptyWrite.text.isEmpty
                    && emptyOpened[0].isDocumentEdited,
                "an empty named snapshot is rewritten at a later revision on recovery, not rejected as stale")
            check(
                original.fileURL == namedURL && original.isDocumentEdited && originalDraft != nil
                    && original.editor.checkedUTF8Data == originalDraft,
                "recovered drafts and their flushes preserve the registered original document and its unsaved edits")
            check(try Data(contentsOf: namedURL) == originalBytes, "launch recovery never writes the original file")
            let good = RecoverySnapshot(
                id: UUID(), text: "before the bad one", format: FileFormat(), originalURL: nil, revision: 1)
            let overflowing = RecoverySnapshot(
                id: UUID(), text: "x", format: FileFormat(), originalURL: nil, revision: UInt64.max)
            let never = RecoverySnapshot(
                id: UUID(), text: "after the bad one", format: FileFormat(), originalURL: nil, revision: 1)
            let openBefore = NSDocumentController.shared.documents.count
            rejects(
                "a snapshot whose revision cannot advance stops launch recovery",
                expecting: RecoveryError.invalidSnapshot
            ) { _ = try sessionDelegate.openRecovered([good, overflowing, never]) }
            let survivors = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
            check(
                NSDocumentController.shared.documents.count == openBefore + 1
                    && survivors.contains { $0.recoveryID == good.id && $0.editor.text == "before the bad one" }
                    && !survivors.contains { $0.recoveryID == never.id || $0.recoveryID == overflowing.id },
                "snapshots opened before a failing one stay open; the failing one and those after it are not opened")
            survivors.forEach { $0.close() }
            check(
                try !TextDocument.recovery.loadAll().contains { [named.id, untitled.id, good.id].contains($0.id) },
                "closing recovered documents removes their snapshots")
            // Dirty quit: the review request and the reply are observed, never presented or sent.
            let quitting = AppDelegate()
            var reviews = 0, replies: [Bool] = []
            quitting.requestUnsavedReview = { delegate in if delegate === quitting { reviews += 1 } }
            quitting.replyToTerminate = { replies.append($0) }
            // A file: since DS-D9 an untitled document's unsaved text is kept, not reviewed, at quit.
            let dirtyURL = root.appendingPathComponent("unsaved-at-quit.txt")
            try Data().write(to: dirtyURL)
            let dirty = TextDocument()
            dirty.fileURL = dirtyURL
            NSDocumentController.shared.addDocument(dirty)
            dirty.editor.text = "unsaved at quit"
            let clean = TextDocument()
            NSDocumentController.shared.addDocument(clean)
            check(
                quitting.applicationShouldTerminate(app) == .terminateLater && reviews == 0
                    && NSDocumentController.shared.documents.count == 2,
                "quit with an unsaved document waits for the review and closes nothing yet")
            spinUntil("the unsaved-documents review to be requested") { reviews == 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            check(
                reviews == 1 && replies.isEmpty,
                "the unsaved-documents review is requested exactly once and nothing is replied before it finishes")
            quitting.reviewed(NSDocumentController.shared, didReviewAll: false, contextInfo: nil)
            check(
                replies == [false] && NSDocumentController.shared.documents.count == 2
                    && dirty.editor.text == "unsaved at quit" && dirty.isDocumentEdited,
                "a cancelled review replies false and leaves every document open with its text")
            quitting.reviewed(NSDocumentController.shared, didReviewAll: true, contextInfo: nil)
            check(
                replies == [false, true] && NSDocumentController.shared.documents.isEmpty,
                "a completed review closes every document and replies true")
        }
        // G342
        section("split view focus and per-view state", #line) {
            let priorServices = EditorServices.current, splitDelegate = AppDelegate()
            splitDelegate.installEditorServices()
            defer { EditorServices.current = priorServices }
            var viewSettings = EditorSettings()
            viewSettings.tabWidth = 8
            viewSettings.useTabs = false
            try splitDelegate.settings.save(viewSettings)
            defer { _ = try? splitDelegate.settings.save(EditorSettings()) }
            let url = root.appendingPathComponent("split-view.txt")
            try Data("zero\none\ntwo\n".utf8).write(to: url)
            let document = TextDocument()
            document.fileURL = url
            document.fileType = "Plain Text"
            NSDocumentController.shared.addDocument(document)
            try document.read(from: try Data(contentsOf: url), ofType: "Plain Text")
            document.makeWindowControllers()
            document.showWindows()
            let
                controller = try requireValue(
                    document.windowControllers.first as? EditorWindowController, "fixture: editor window controller"),
                window = try requireValue(controller.hostWindow, "fixture: window")
            let primaryStatus = document.editor.statusInfo
            check(
                primaryStatus.tabWidth == 8 && primaryStatus.useTabs == false,
                "the primary view takes the saved tab settings")
            weak var released: TTEditor?
            try autoreleasepool {
                controller.clone(nil)
                let clone = try requireValue(controller.secondary, "fixture: clone view")
                released = clone
                check(
                    controller.activeEditor === clone && controller.lastEditor === clone,
                    "a new clone becomes the active editor")
                let cloneStatus = clone.statusInfo
                check(
                    cloneStatus.tabWidth == 8 && cloneStatus.useTabs == false
                        && document.editor.statusInfo.tabWidth == 8
                        && document.editor.statusInfo.useTabs == false,
                    "the clone takes the saved tab settings and the primary view keeps its own")
                clone.configureTabWidth(2, useTabs: true)
                // Scintilla keeps tab width and tabs-or-spaces in the document, so a clone cannot
                // differ from the primary view, although the status menu calls them view settings.
                check(
                    document.editor.statusInfo.tabWidth == 2
                        && document.editor.statusInfo.useTabs == true
                        && clone.statusInfo.tabWidth == 2,
                    "tab settings changed through the clone apply to the shared document and so to both views")
                clone.configureTabWidth(8, useTabs: false)
                check(
                    window.makeFirstResponder(document.editor) && controller.activeEditor === document.editor
                        && controller.lastEditor === document.editor,
                    "focusing the primary view makes it the active editor")
                check(
                    window.makeFirstResponder(clone) && controller.activeEditor === clone,
                    "focusing the clone makes it the active editor again")
                window.makeFirstResponder(nil)
                check(controller.activeEditor === clone, "with no editor focused the last focused view stays active")
                let cloneRevision = clone.revision, primaryRevision = document.editor.revision
                _ = clone.setSelectionAnchor(0, caret: 0)
                clone.replaceSelection("c")
                _ = document.editor.setSelectionAnchor(0, caret: 0)
                document.editor.replaceSelection("p")
                check(
                    document.editor.text == "pczero\none\ntwo\n" && clone.text == document.editor.text,
                    "edits from either view land in the one shared buffer")
                check(
                    clone.revision > cloneRevision && document.editor.revision > primaryRevision
                        && clone.revision - cloneRevision == document.editor.revision - primaryRevision,
                    "both views' revision counters advance by the same amount for edits from either side")
                check(clone.revision == document.editor.revision, "the two views report the same revision")
                document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                clone.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(
                    document.editor.text == "zero\none\ntwo\n" && !document.isDocumentEdited,
                    "undo from each view returns the shared buffer to its save point")
                // The search, utility and language controllers ask the application delegate for the
                // current editor; menu commands go to the window controller's active editor.
                // The check process has no main window, so the delegate is told which window is frontmost.
                splitDelegate.noteActive(controller)
                check(
                    window.makeFirstResponder(clone) && splitDelegate.currentEditor === clone,
                    "with the clone focused it is the current editor the search, utility and language controllers receive"
                )
                _ = document.editor.setSelectionAnchor(5, caret: 8)
                _ = clone.setSelectionAnchor(0, caret: 4)
                let upper = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                upper.representedObject = "upper"
                controller.command(upper)
                check(
                    document.editor.text == "ZERO\none\ntwo\n" && document.editor.selectionStart == 5
                        && document.editor.selectionEnd == 8,
                    "a menu command with the clone active uses the clone's selection and leaves the primary view's selection alone"
                )
                clone.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
                check(
                    document.editor.text == "zero\none\ntwo\n" && !document.isDocumentEdited,
                    "the command sent through the clone is one Undo in the shared history")
                check(
                    window.makeFirstResponder(document.editor) && splitDelegate.currentEditor === document.editor,
                    "with the primary view focused it is the current editor again")
                let indicatorAllOnFor: UInt32 = 2506, searchIndicator = 1 << 20
                check(
                    document.editor.setSearchHighlights([TTByteRange(location: 0, length: 4)])
                        && sci(clone, indicatorAllOnFor, 1) & searchIndicator != 0
                        && sci(clone, indicatorAllOnFor, 5) & searchIndicator == 0,
                    "a search highlight set through the primary view is present in the clone")
                clone.clearSearchHighlights()
                check(
                    sci(document.editor, indicatorAllOnFor, 1) & searchIndicator == 0,
                    "clearing highlights through the clone clears them in the primary view")
                clone.replaceSelection("dirty before reload")
                try Data("reloaded with a clone open\n".utf8).write(to: url)
                try document.reload(using: .utf8, discard: true)
                check(
                    document.editor.text == "reloaded with a clone open\n" && clone.text == document.editor.text
                        && !document.isDocumentEdited && !clone.modified,
                    "reload with a clone open replaces the text in both views and clears the dirty state")
                check(
                    clone.revision == document.editor.revision, "the two views report the same revision after a reload")
                document.editor.readOnly = true
                let item = NSMenuItem(title: "Read Only", action: nil, keyEquivalent: "")
                document.toggleReadOnly(item)
                check(
                    !document.editor.readOnly && !clone.readOnly && item.state == .off,
                    "Read Only toggles both views together")
                check(
                    window.makeFirstResponder(clone) && controller.activeEditor === clone,
                    "fixture: the clone is active before the split closes")
                controller.closeSplit(nil)
                check(
                    controller.secondary == nil && controller.activeEditor === document.editor
                        && controller.lastEditor === document.editor,
                    "closing the split returns the active editor to the primary view")
                check(
                    splitDelegate.currentEditor === document.editor,
                    "after the split closes the controllers receive the primary view, never the detached clone")
            }
            for _ in 0..<10 where released != nil {
                autoreleasepool {
                    window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            // A bare TTEditor, one sharing this document and one removed from a split view in a
            // plain window are all released (probed while writing this check); the clone made by
            // EditorWindowController.clone is not. Package 11 traced it: the first view removed
            // from a document window, a bare NSView included, keeps one retain made inside
            // -[NSView _setWindow:] until the window itself is deallocated, and later clones in
            // the same window are released at once. No TextTank object refers to the view. See
            // "results captured through a clone survive Close Split View" for the checks on
            // TextTank's own references and on release when the document closes.
            weak var bare: TTEditor?
            autoreleasepool {
                let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
                editor.shareDocument(with: document.editor)
                bare = editor
            }
            check(bare == nil, "a view that shared the document and was dropped is released")
            knownDefect("G342", "the closed clone view is released", fixed: released == nil)
            check(
                document.editor.text == "reloaded with a clone open\n" && !document.isDocumentEdited,
                "closing the split keeps the buffer and its clean state")
            document.close()
        }
        // G355: one committed file per persisted format, written by the build of 15 November 2026
        // through the production writers. Each must keep decoding, through the production
        // reader, to exactly these values. Adding a non-optional field to a persisted type
        // without a decoder for old files fails here. TEXTTANK_WRITE_PERSISTENCE_FIXTURES=1
        // rewrites the files; do that only for a deliberate, versioned format change.
        section("persisted format golden fixtures", #line) {
            let folder = TestPaths.fixtures.appendingPathComponent("persistence", isDirectory: true)
            let writing = ProcessInfo.processInfo.environment["TEXTTANK_WRITE_PERSISTENCE_FIXTURES"] != nil
            let scratch = root.appendingPathComponent("persistence-scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            if writing { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            func golden(_ name: String, _ produce: () throws -> Data) throws -> Data {
                let url = folder.appendingPathComponent(name)
                if writing {
                    try produce().write(to: url)
                    print("WROTE \(url.path)")
                }
                return try Data(contentsOf: url)
            }
            func copy(_ data: Data, _ name: String) throws -> URL {
                let url = scratch.appendingPathComponent(name)
                try data.write(to: url)
                return url
            }
            let stamp = Date(timeIntervalSinceReferenceDate: 784_000_000),
                idA = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                idB = UUID(uuidString: "66666666-7777-4888-9999-AAAAAAAAAAAA")!
            let suiteName = "TextTankPersistenceFixtures-" + UUID().uuidString
            let defaults = try requireValue(UserDefaults(suiteName: suiteName), "fixture: isolated defaults suite")
            defer { defaults.removePersistentDomain(forName: suiteName) }

            var settings = EditorSettings()
            settings.tabWidth = 8
            settings.useTabs = false
            settings.wrap = true
            settings.appearance = "dark"
            settings.shortcuts = ["upper": "u", "joinLines": "J"]
            let settingsBytes = try golden("Settings.json") {
                let url = scratch.appendingPathComponent("write-Settings.json")
                try SettingsController(url: url).save(settings)
                return try Data(contentsOf: url)
            }
            let settingsReader = SettingsController(url: try copy(settingsBytes, "Settings.json"))
            check(
                try EditorSettings.decode(settingsBytes) == settings && settingsReader.value == settings
                    && settingsReader.loadError == nil, "golden Settings.json decodes to the recorded editor settings")

            var search = SearchOptions()
            search.query = "([a-z]+)=(\\d+)"
            search.replacement = "$1:$2"
            search.mode = .regularExpression
            search.matchCase = true
            search.wholeWord = true
            search.dotMatchesNewline = true
            search.wrap = false
            let searchBytes = try golden("SearchOptions.json") {
                // The legacy defaults fixture remains byte/schema compatible. New Find files
                // wrap these unchanged options in a versioned FindPreferences envelope.
                try JSONEncoder().encode(search)
            }
            defaults.set(searchBytes, forKey: "TextTank.Search.v1")
            let finder = SearchController(defaults: defaults)
            check(
                try JSONDecoder().decode(SearchOptions.self, from: searchBytes) == search
                    && finder.caseButton.state == .on && finder.wordButton.state == .on && finder.dotButton.state == .on
                    && finder.wrapButton.state == .off,
                "golden Find options decode and restore every Find-window option flag")
            // V3: the text and the Regex mode an older file would have restored are offered as
            // history; a new launch starts in Normal mode with both fields empty.
            check(
                finder.queryField.stringValue.isEmpty && finder.replacementField.stringValue.isEmpty
                    && finder.mode.indexOfSelectedItem == 0 && finder.findHistory.queries == [search.query]
                    && finder.findHistory.replacements == [search.replacement],
                "golden Find options start a launch in Normal mode, with their text offered as history")

            var folderSettings = FolderSearchSettings()
            folderSettings.folder = URL(fileURLWithPath: "/Users/Shared/TextTank Fixture/project", isDirectory: true)
            folderSettings.workspaceScope = true
            folderSettings.recursive = false
            folderSettings.includeHidden = true
            folderSettings.extensions = "txt, swift"
            folderSettings.filters = "*.swift !*Tests* !+\\build"
            folderSettings.options = search
            let folderBytes = try golden("FolderSearchSettings.json") {
                try folderSettings.save(defaults)
                return try requireValue(
                    defaults.data(forKey: "TextTank.FolderSearch.v1"), "fixture: folder settings saved")
            }
            defaults.set(folderBytes, forKey: "TextTank.FolderSearch.v1")
            check(
                try FolderSearchSettings.load(defaults) == folderSettings,
                "golden Find-in-Folder settings decode to the recorded values")

            var browser = WorkspaceBrowserState()
            browser.folders = [
                URL(fileURLWithPath: "/Users/Shared/TextTank Fixture/project", isDirectory: true),
                URL(fileURLWithPath: "/Users/Shared/TextTank Fixture/notes", isDirectory: true)
            ]
            browser.recent = [URL(fileURLWithPath: "/Users/Shared/TextTank Fixture/project/caf\u{E9} \u{1F600}.txt")]
            let browserBytes = try golden("WorkspaceBrowser.json") {
                let url = scratch.appendingPathComponent("write-WorkspaceBrowser.json")
                try WorkspaceBrowserStore(url: url).save(browser)
                return try Data(contentsOf: url)
            }
            let browserReader = WorkspaceBrowserStore(url: try copy(browserBytes, "WorkspaceBrowser.json"))
            check(
                browserReader.loadError == nil && browserReader.state == browser,
                "golden workspace browser state decodes to the recorded folders and recent files")

            let runs = [
                ConfiguredRun(id: idA, name: "Word count", executable: "/usr/bin/wc", arguments: ["-w", "{file}"]),
                ConfiguredRun(
                    id: idB, name: "Shell filter", executable: "/bin/zsh", arguments: ["-c", "sort | uniq"],
                    shellMode: true),
                ConfiguredRun(
                    id: UUID(uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF")!, name: "Extension",
                    executable: "/usr/local/bin/texttank-extension", arguments: ["{selection}"], extensionMode: true)
            ]
            let runBytes = try golden("RunLibrary.json") { try ConfiguredRun.encodeLibrary(runs) }
            check(
                try ConfiguredRun.decodeLibrary(runBytes) == runs,
                "golden Run library decodes to the recorded commands, including shell and extension modes")

            let sessionText = "\u{FEFF}caf\u{E9}\u{1F600}\r\n2 eggs\0"
            let sessionDocument = SessionDocument(
                id: idA, originalURL: URL(fileURLWithPath: "/Users/Shared/TextTank Fixture/project/list.txt"),
                text: sessionText, format: FileFormat(encoding: .utf16LE, bom: true), isDirty: true,
                selection: SessionSelection(anchorByte: sessionText.utf8.count, caretByte: 3), bookmarks: [0, 1],
                language: "python", originalSHA256: String(repeating: "ab", count: 32))
            var session = WorkspaceSession(
                id: idB, name: "Golden session", documents: [sessionDocument], activeDocumentID: idA)
            session.savedAt = stamp
            let sessionBytes = try golden("Session.texttanksession") {
                let url = scratch.appendingPathComponent("write.texttanksession")
                try WorkspaceStore.save(session, to: url)
                return try Data(contentsOf: url)
            }
            check(
                try WorkspaceStore.load(from: copy(sessionBytes, "Session.texttanksession")) == session,
                "golden session file decodes to the recorded dirty document with bookmarks, selection and format")

            var snapshot = RecoverySnapshot(
                id: idA, text: sessionText, format: FileFormat(encoding: .windows1252, bom: false),
                originalURL: "file:///Users/Shared/TextTank%20Fixture/project/list.txt", revision: 42)
            snapshot.savedAt = stamp
            let layoutBytes = try Data(contentsOf: folder.appendingPathComponent("SessionLayout.texttanksession"))
            let layoutSession = try WorkspaceStore.load(from: copy(layoutBytes, "SessionLayout.texttanksession"))
            check(
                layoutSession.documents.count == 2 && layoutSession.layoutState?.groups.count == 4,
                "golden multi-group shared pinned session decodes through production file reader")
            // This fixture records the v1 whole-text wire format; the current store writes a v2 pair.
            let snapshotBytes = try golden("RecoverySnapshot.json") { try JSONEncoder().encode(snapshot) }
            let recoveryReader = RecoveryStore(
                directory: scratch.appendingPathComponent("read-recovery", isDirectory: true))
            try FileManager.default.createDirectory(
                at: recoveryReader.fileURL(for: idA).deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try snapshotBytes.write(to: recoveryReader.fileURL(for: idA))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: recoveryReader.fileURL(for: idA).path)
            let scanned = try recoveryReader.scan()
            if !check(
                scanned.issues.isEmpty && scanned.snapshots == [snapshot],
                "golden recovery snapshot is found by a scan and decodes to the recorded text, format and revision")
            {
                print("NOTE recovery scan issues \(scanned.issues.map(\.message))")
            }

            let batch = ReminderBatch(
                id: idA, destinationID: "calendar-1", destinationTitle: "Groceries", destinationSource: "iCloud",
                rows: [
                    ReminderRow(id: idB, title: "2 eggs", status: .confirmed, reminderID: "reminder-9", message: nil),
                    ReminderRow(
                        id: idA, title: "\u{BD} cup flour", status: .uncertain, reminderID: nil,
                        message: "Save was interrupted")
                ], createdAt: stamp)
            let batchBytes = try golden("ReminderBatch.json") { try RemindersConnector.encodedJournal(batch) }
            let decodedBatch = try JSONDecoder().decode(ReminderBatch.self, from: batchBytes)
            check(
                decodedBatch.schemaVersion == 1 && decodedBatch.id == idA && decodedBatch.destinationID == "calendar-1"
                    && decodedBatch.destinationTitle == "Groceries" && decodedBatch.destinationSource == "iCloud"
                    && decodedBatch.createdAt == stamp && decodedBatch.rows.map(\.id) == [idB, idA]
                    && decodedBatch.rows.map(\.title) == ["2 eggs", "\u{BD} cup flour"]
                    && decodedBatch.rows.map(\.status) == [.confirmed, .uncertain]
                    && decodedBatch.rows.map(\.reminderID) == ["reminder-9", nil]
                    && decodedBatch.rows.map(\.message) == [nil, "Save was interrupted"],
                "golden reminder journal decodes to the recorded batch and row states")

            let macro = RecordedMacro(
                id: idA, name: "Golden macro",
                steps: [
                    .insertText("caf\u{E9}"), .command("lineEnd"),
                    .findLiteral(text: "x", matchCase: true, backwards: false),
                    .replaceSelection("y"),
                    .search(
                        .init(
                            query: "a+", replacement: "b", mode: 2, matchCase: true, wholeWord: false,
                            dotMatchesNewline: false, wrap: true, action: "replaceAll"))
                ])
            let macros = MacroLibrary(macros: [macro])
            let macroBytes = try golden("MacroLibrary.json") { try macros.encoded() }
            check(
                try MacroLibrary.decode(macroBytes) == macros,
                "golden macro library decodes to the recorded steps of every kind")

            var definition = AutomationDefinition(
                id: idA, name: "Golden automation", input: .selection,
                steps: [
                    .init(kind: .clearLinesMatching, find: "^#"),
                    .init(
                        kind: .replaceLiteral, find: "a", replacement: "b", askForFind: true, askForReplacement: false),
                    .init(kind: .trimWhitespace)
                ], output: .newDocument, previewBeforeApply: true, pinToToolbar: true)
            definition.shortcut = "g"
            definition.destinationID = "list-1"
            let automations = AutomationLibrary(workflows: [definition])
            let automationBytes = try golden("Automations.json") { try automations.encoded() }
            check(
                try AutomationLibrary.decode(automationBytes) == automations,
                "golden automation library decodes to the recorded definition with every optional field")
            // This historical file comes from the pre-flag encoder, so never regenerate it with golden().
            let legacyBytes = try Data(contentsOf: folder.appendingPathComponent("Automations-before-flags.json"))
            let legacyLibrary = try AutomationLibrary.decode(legacyBytes)
            let legacyWorkflow = try requireValue(legacyLibrary.workflows.first, "historical automation")
            check(
                legacyLibrary.workflows.count == 1 && legacyWorkflow.id == idA
                    && legacyWorkflow.shortcut == "" && legacyWorkflow.previewBeforeApply == nil
                    && legacyWorkflow.pinToToolbar == nil,
                "the pre-flag automation library preserves its empty shortcut and absent flags")

            let language = UserDefinedLanguage(
                name: "Golden language", extensions: "gold", version: "2.1",
                global: ["caseIgnored": "yes", "forcePureLC": "0", "decimalSeparator": "0"],
                prefix: ["Keywords1": "yes"], keywords: ["Keywords1": "alpha beta", "Comments": "00// 01 02 03/* 04*/"],
                styles: [
                    .init(name: "DEFAULT", attributes: ["fgColor": "000000", "fontStyle": "0"]),
                    .init(name: "KEYWORDS1", attributes: ["fgColor": "0000FF", "fontStyle": "1"])
                ])
            let catalogBytes = try golden("LanguageCatalog.json") {
                try LanguageCatalog(
                    sourceCommit: "golden-fixture", sourceHashes: ["LanguageProfiles.json": "00ff"],
                    limitations: ["fixture only"], profiles: [try language.profile()]
                ).encoded()
            }
            let catalog = try LanguageCatalog.decode(catalogBytes)
            check(
                catalog.version == 1 && catalog.sourceCommit == "golden-fixture"
                    && catalog.sourceHashes == ["LanguageProfiles.json": "00ff"]
                    && catalog.limitations == ["fixture only"] && catalog.profiles.count == 1
                    && catalog.profiles[0].title == "Golden language" && catalog.profiles[0].lexer == "user"
                    && catalog.profiles[0].id.hasPrefix("udl.") && catalog.profiles[0].extensions == ["gold"]
                    && catalog.profiles[0].keywordLists["7"] == "alpha beta"
                    && catalog.profiles[0].properties["userDefine.prefixKeywords1"] == "1"
                    && catalog.profiles[0].properties["userDefine.isCaseIgnored"] == "1"
                    && catalog.profiles[0].styles.map(\.name) == ["DEFAULT", "KEYWORDS1"]
                    && catalog.profiles[0].udl == language,
                "golden language catalog decodes to the recorded user-defined profile")
            // Audit package 18: the user's LanguageProfiles.json now holds only changes to the bundled
            // catalog. The full-copy fixture above stays, because files in that form are still read.
            let goldenOverrides = LanguageOverrides(
                basedOnSourceCommit: "golden-fixture",
                changed: [
                    .init(
                        id: "python", title: "Golden Python", extensions: ["py", "gold"],
                        styles: [
                            .init(
                                id: 5, name: "KEYWORDS", foreground: "123456", fontStyle: 3, useCustomColor: true,
                                fontName: "Menlo-Regular", fontSize: 13.5)
                        ], cleared: ["comments"])
                ], added: [try language.profile()], removed: ["cobol"], order: [try language.profile().id, "python"])
            let overridesBytes = try golden("LanguageOverrides.json") { try goldenOverrides.encoded() }
            let base = LanguageCatalog(
                sourceCommit: "base", sourceHashes: [:], limitations: [],
                profiles: ["cobol", "python", "ruby"].map {
                    LanguageProfile(
                        id: $0, title: $0, lexer: $0, extensions: [$0], keywordLists: ["0": "keyword"],
                        referenceKeywordClasses: [:], properties: [:], styles: [], functionPattern: nil, udl: nil,
                        comments: .init(line: "#", blockOpen: nil, blockClose: nil))
                })
            let overlaid = try LanguageCatalog.load(stored: overridesBytes, over: base),
                storedOverrides = try JSONDecoder().decode(LanguageOverrides.self, from: overridesBytes)
            let goldenID = "udl.1d20011f4d4db78bc77f4d6d"
            check(
                storedOverrides.overridesVersion == 1 && storedOverrides.basedOnSourceCommit == "golden-fixture"
                    && storedOverrides.changed == goldenOverrides.changed && storedOverrides.removed == ["cobol"]
                    && storedOverrides.order == [goldenID, "python"] && storedOverrides.added.map(\.id) == [goldenID]
                    && storedOverrides.added[0].udl == language
                    && storedOverrides.added[0].keywordLists["7"] == "alpha beta",
                "golden language overrides decode to the recorded changes")
            check(
                overlaid.profiles.map(\.id) == [goldenID, "python", "ruby"]
                    && overlaid.profiles[1].title == "Golden Python"
                    && overlaid.profiles[1].extensions == ["py", "gold"]
                    && overlaid.profiles[1].styles == goldenOverrides.changed[0].styles
                    && overlaid.profiles[1].comments == nil && overlaid.profiles[1].keywordLists == ["0": "keyword"]
                    && overlaid.profiles[0] == storedOverrides.added[0] && overlaid.profiles[2] == base.profiles[2]
                    && overlaid.sourceCommit == "base",
                "golden language overrides merge over a bundled catalog: changed, cleared, removed, added and ordered")
            let futureRecovery = RecoveryStore(directory: scratch.appendingPathComponent("reader-gated-recovery"))
            try FileManager.default.createDirectory(
                at: futureRecovery.fileURL(for: idA).deletingLastPathComponent(), withIntermediateDirectories: true)
            let readers: [(String, String, Data, (Data) throws -> Void)] = [
                ("Settings", "version", settingsBytes, { _ = try EditorSettings.decode($0) }),
                (
                    "Find", "version", try FindPreferences(options: search).encoded(),
                    { _ = try FindPreferences.decode($0) }
                ),
                ("Folder", "version", folderBytes, { _ = try FolderSearchSettings.decode($0) }),
                (
                    "Browser", "version", browserBytes,
                    { data in
                        let store = WorkspaceBrowserStore(url: try copy(data, "reader-browser.json"))
                        if let error = store.loadError { throw error }
                    }
                ),
                ("Run", "version", runBytes, { _ = try ConfiguredRun.decodeLibrary($0) }),
                ("Session", "schemaVersion", sessionBytes, { _ = try WorkspaceSession.decode($0) }),
                (
                    "Recovery", "schemaVersion", snapshotBytes,
                    { data in
                        try data.write(to: futureRecovery.fileURL(for: idA))
                        _ = try futureRecovery.load(id: idA)
                    }
                ),
                (
                    "Reminder", "schemaVersion", batchBytes,
                    { data in
                        _ = try ReminderJournal.read(copy(data, "reader-reminder.json"), id: idA)
                    }
                ),
                ("Macro", "version", macroBytes, { _ = try MacroLibrary.decode($0) }),
                ("Automation", "version", automationBytes, { _ = try AutomationLibrary.decode($0) }),
                ("Language", "version", catalogBytes, { _ = try LanguageCatalog.decode($0) }),
                (
                    "Overrides", "overridesVersion", overridesBytes,
                    { _ = try LanguageCatalog.load(stored: $0, over: base) }
                )
            ]
            for (name, versionKey, bytes, read) in readers {
                // Edit only envelope bytes. JSONSerialization's object bridge drops a leading
                // FEFF inside a string on this macOS; it must never rewrite snapshot payloads.
                func metadata(_ minimum: Int) throws -> Data {
                    var result = bytes
                    let opening = try requireValue(result.firstIndex(of: 0x7B), "fixture: JSON object opening")
                    result.insert(contentsOf: Data("\"minimumReaderVersion\":\(minimum),".utf8), at: opening + 1)
                    return result
                }
                let future = try metadata(2)
                rejects("G356 \(name) production reader refuses newer minimum reader metadata") { try read(future) }
                try read(metadata(1))
                check(true, "G356 \(name) accepts reader 1 metadata without a schema migration")
                var missing = bytes
                let key = Data("\"\(versionKey)\"".utf8)
                let field = try requireValue(
                    missing.range(of: key, options: .backwards), "fixture: required version key")
                var lower = field.lowerBound, upper = field.upperBound
                func space(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }
                while upper < missing.count && (space(missing[upper]) || missing[upper] == 0x3A) { upper += 1 }
                try require(missing[upper] == 0x31, "fixture: recorded schema version is 1")
                upper += 1
                while upper < missing.count && space(missing[upper]) { upper += 1 }
                if missing[upper] == 0x2C {
                    upper += 1
                } else {
                    while lower > 0 && space(missing[lower - 1]) { lower -= 1 }
                    if lower > 0 && missing[lower - 1] == 0x2C { lower -= 1 }
                }
                missing.removeSubrange(lower..<upper)
                rejects("G356 \(name) never defaults a missing required schema version") { try read(missing) }
            }
            let present = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
            check(
                present == [
                    // Settings-v2.json is decoded value by value in SettingsShortcutValidationChecks.versionStep.
                    "Settings.json", "Settings-v2.json", "SearchOptions.json", "FolderSearchSettings.json",
                    "WorkspaceBrowser.json",
                    "RunLibrary.json", "Session.texttanksession", "SessionLayout.texttanksession",
                    "RecoverySnapshot.json", "ReminderBatch.json", "LastSession.json", "LastSession-untitled.json",
                    "MacroLibrary.json", "Automations.json", "Automations-before-flags.json", "LanguageCatalog.json",
                    "LanguageOverrides.json"
                ], "every committed persistence fixture is decoded by a check")
            check(!writing, "persistence fixtures were not rewritten by this run")
        }
        // F251
        section("menu and command wiring", #line) {
            let document = TextDocument()
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            let
                controller = try requireValue(
                    document.windowControllers.first as? EditorWindowController, "fixture: editor window controller"),
                window = try requireValue(controller.hostWindow, "fixture: window")
            sessionDelegate.buildMenus()
            let bar = try requireValue(NSApp.mainMenu, "fixture: buildMenus installs a main menu")
            func walk(_ menu: NSMenu, _ path: String) -> [(String, NSMenuItem)] {
                menu.items.flatMap { item -> [(String, NSMenuItem)] in
                    let here = path.isEmpty ? item.title : path + " > " + item.title
                    return (item.action == nil || item.hasSubmenu ? [] : [(here, item)])
                        + (item.submenu.map { walk($0, here) } ?? [])
                }
            }
            func snapshot(_ menu: NSMenu, path: [Int] = []) -> [[String: String]] {
                menu.items.enumerated().flatMap { index, item -> [[String: String]] in
                    let position = path + [index]
                    let row: [String: String] = [
                        "position": position.map(String.init).joined(separator: "."),
                        "title": item.title,
                        "action": item.action.map(NSStringFromSelector) ?? "",
                        "key": item.keyEquivalent,
                        "modifiers": String(item.keyEquivalentModifierMask.rawValue),
                        "target": item.target == nil ? "responder" : "explicit",
                        "object": item.representedObject.map { String(describing: $0) } ?? ""
                    ]
                    return [row] + (item.submenu.map { snapshot($0, path: position) } ?? [])
                }
            }
            let menuSnapshot = snapshot(bar)
            var chords = Set<String>(), conflicts: [String] = []
            for (path, item) in walk(bar, "") where !item.keyEquivalent.isEmpty {
                var key = item.keyEquivalent, flags = item.keyEquivalentModifierMask
                if key.count == 1 && key != key.lowercased() {
                    key = key.lowercased()
                    flags.insert(.shift)
                }
                if key == "{" || key == "}" {
                    key = key == "{" ? "[" : "]"
                    flags.insert(.shift)
                }
                if !chords.insert("\(flags.rawValue)/\(key)").inserted { conflicts.append(path) }
            }
            check(
                conflicts.isEmpty,
                "assigned menu keys, including hidden aliases and automations, are unique: \(conflicts)")
            // One golden file for the whole nine-menu tree. TEXTTANK_WRITE_MENU_FIXTURE=1 rewrites it;
            // do that only for a reviewed change to the menu map (DS-D4).
            let menuFixture = TestPaths.fixtures.appendingPathComponent("menu-tree.json")
            if ProcessInfo.processInfo.environment["TEXTTANK_WRITE_MENU_FIXTURE"] != nil {
                try JSONSerialization.data(withJSONObject: menuSnapshot, options: [.sortedKeys, .prettyPrinted])
                    .write(to: menuFixture)
                print("WROTE \(menuFixture.path)")
            }
            let expectedMenu =
                try JSONSerialization.jsonObject(with: Data(contentsOf: menuFixture)) as! [[String: String]]
            if !check(
                menuSnapshot == expectedMenu,
                "F191 the complete menu tree preserves order, titles, actions, shortcuts, dispatch roles and represented objects"
            ) {
                let known = Set(expectedMenu), actual = Set(menuSnapshot)
                print("NOTE menu rows not in the fixture: \(menuSnapshot.filter { !known.contains($0) }.prefix(12))")
                print("NOTE fixture rows not in the menu: \(expectedMenu.filter { !actual.contains($0) }.prefix(12))")
            }
            // The redesign moved commands; it removed none. Every command of the fourteen-menu bar
            // is still listed exactly as often, with its action, represented object, shortcut and
            // dispatch role. A deliberate removal or addition is named here with its reason, and
            // a removal must be a row of the fixture, so nothing can be left out of it silently.
            func identities(_ rows: [[String: String]]) -> [String] {
                rows.filter { $0["action"] != "" && $0["action"] != "submenuAction:" }.map { row in
                    ["action", "object", "key", "modifiers", "target"].map { row[$0] ?? "" }.joined(separator: "\u{1F}")
                }.sorted()
            }
            let formerCommands =
                try JSONSerialization.jsonObject(
                    with: Data(
                        contentsOf: TestPaths.fixtures.appendingPathComponent(
                            "menu-command-identities-before-nine-menus.json"))) as! [[String: String]]
            // Removed: built-in recipe automation retired. The fourteen-menu bar listed the
            // installed "Clean up recipe list" automation twice: once to paste with it and once
            // to run it. The application no longer installs it.
            let retiredRecipeAutomation = "A931733F-310A-4EBF-9C48-38C59202D586"
            let deliberatelyRemoved: [[String: String]] = [
                [
                    "action": "pasteAction:", "object": retiredRecipeAutomation, "key": "", "modifiers": "1048576",
                    "target": "explicit",
                ],
                [
                    "action": "runAction:", "object": retiredRecipeAutomation, "key": "", "modifiers": "1572864",
                    "target": "explicit",
                ],
            ]
            // Added with the nine-menu bar: the Source, Preview and Both views of a document.
            let deliberatelyAdded: [[String: String]] = ["source", "preview", "both"].map {
                [
                    "action": "setDocumentViewMode:", "object": $0, "key": "", "modifiers": "1048576",
                    "target": "responder",
                ]
            }
            // Added on 23 November 2026: View > Toggle Preview, Shift-Command-V, one command
            // for the same per-tab mode. Nothing was removed for it.
            let togglePreviewAdded: [[String: String]] = [
                [
                    "action": "toggleDocumentPreview:", "object": "", "key": "V", "modifiers": "1048576",
                    "target": "responder",
                ]
            ]
            // Given a key on 23 November 2026: File > Quick Open… is the same command with a default
            // shortcut, Shift-Command-O. Its row without a key is replaced by its row with one.
            let quickOpenWithoutKey: [[String: String]] = [
                ["action": "quickOpen:", "object": "", "key": "", "modifiers": "1048576", "target": "explicit"]
            ]
            let quickOpenWithKey: [[String: String]] = [
                ["action": "quickOpen:", "object": "", "key": "O", "modifiers": "1048576", "target": "explicit"]
            ]
            // Added on 23 November 2026 (DS-D10, local history): Compare > Compare with Earlier
            // Version… and Compare > Clear Local History…. Nothing was removed for them.
            let localHistoryAdded: [[String: String]] = [
                [
                    "action": "compareWithEarlierVersion:", "object": "", "key": "", "modifiers": "1048576",
                    "target": "responder",
                ],
                [
                    "action": "clearLocalHistory:", "object": "", "key": "", "modifiers": "1048576",
                    "target": "explicit",
                ],
            ]
            // Added on 23 November 2026 (DS-73): Window > Move Focus > Move Focus to Next Area and
            // Move Focus to Previous Area, F6 and Shift-F6, each listed once more as a hidden item
            // for its second key, Option-Command-` and Shift-Option-Command-`. Nothing was removed.
            let moveFocusAdded: [[String: String]] = [
                ("moveFocusToNextArea:", "\u{f709}", "0"), ("moveFocusToPreviousArea:", "\u{f709}", "131072"),
                ("moveFocusToNextArea:", "`", "1572864"), ("moveFocusToPreviousArea:", "~", "1572864"),
            ].map { ["action": $0.0, "object": "", "key": $0.1, "modifiers": $0.2, "target": "explicit"] }
            // Merged on 23 November 2026 (DS-D13): View > Close Split View has no row of its own.
            // View > Split Tab View is the one toggle that splits and closes; `closeSplit:` is
            // still an action. This is the only command the regrouped View menu stopped listing.
            let closeSplitMerged: [[String: String]] = [
                ["action": "closeSplit:", "object": "", "key": "", "modifiers": "1048576", "target": "responder"]
            ]
            // Added with it: View > Preview > Sync Scrolling in Both (the stored setting, on the
            // active tab's validation), View > Show > Change Bars and View > Centered Text Column.
            let viewRegroupAdded: [[String: String]] = [
                [
                    "action": "toggleSyncPreviewScrolling:", "object": "", "key": "", "modifiers": "1048576",
                    "target": "responder",
                ],
                ["action": "toggleChangeBars:", "object": "", "key": "", "modifiers": "1048576", "target": "explicit"],
                [
                    "action": "toggleCenteredColumn:", "object": "", "key": "", "modifiers": "1048576",
                    "target": "explicit",
                ],
            ]
            // Added on 23 November 2026: View > Syntax Highlighting > Choose Language…, the
            // filterable chooser the status bar's language field also opens. Nothing was removed.
            let chooseLanguageAdded: [[String: String]] = [
                ["action": "chooseLanguage:", "object": "", "key": "", "modifiers": "1048576", "target": "explicit"]
            ]
            var accounted = identities(
                formerCommands + deliberatelyAdded + togglePreviewAdded + quickOpenWithKey + localHistoryAdded
                    + viewRegroupAdded + chooseLanguageAdded + moveFocusAdded)
            var removedRowsInFixture = 0
            for removed in identities(deliberatelyRemoved + quickOpenWithoutKey + closeSplitMerged) {
                if let index = accounted.firstIndex(of: removed) {
                    accounted.remove(at: index)
                    removedRowsInFixture += 1
                }
            }
            let current = identities(menuSnapshot)
            check(
                formerCommands.count == 338
                    && removedRowsInFixture == deliberatelyRemoved.count + quickOpenWithoutKey.count
                        + closeSplitMerged.count,
                "DS-D4 the fixture lists all 338 commands of the fourteen-menu bar, the two rows of the retired recipe automation and Close Split View's row among them")
            if !check(
                current == accounted.sorted(),
                "DS-D4 every command of the fourteen-menu bar is listed exactly once more in the nine-menu bar, apart from the removals named")
            {
                func show(_ id: String) -> String { id.replacingOccurrences(of: "\u{1F}", with: "|") }
                var missing = accounted, extra = current
                for id in current { if let index = missing.firstIndex(of: id) { missing.remove(at: index) } }
                for id in accounted { if let index = extra.firstIndex(of: id) { extra.remove(at: index) } }
                print("NOTE commands no longer listed: \(missing.map(show)); newly listed: \(extra.map(show))")
            }
            let crowded = menuLevelsOverTwenty(bar)
            check(crowded.isEmpty, "DS-23 no menu level lists more than twenty items: \(crowded)")
            try Audit29IntentChecks.checkMenuTargets(bar, composition: sessionDelegate)
            let helperMenu = NSMenu()
            let helperItem = helperMenu.addItem(
                title: "Fixture command", action: #selector(EditorWindowController.command(_:)),
                keyEquivalent: "j", modifiers: [.control, .shift], target: controller,
                representedObject: "upper", isEnabled: false, state: .on)
            check(
                helperMenu.items.count == 1 && helperMenu.items.first === helperItem
                    && helperItem.title == "Fixture command"
                    && helperItem.action == #selector(EditorWindowController.command(_:))
                    && helperItem.keyEquivalent == "j" && helperItem.keyEquivalentModifierMask == [.control, .shift]
                    && helperItem.target === controller && helperItem.representedObject as? String == "upper"
                    && !helperItem.isEnabled && helperItem.state == .on,
                "F191 the shared menu helper preserves explicit dispatch, shortcut, identity and validation metadata")
            let helperDefault = helperMenu.addItem(title: "Fixture heading", action: nil)
            check(
                helperDefault.target == nil && helperDefault.action == nil && helperDefault.keyEquivalent.isEmpty
                    && helperDefault.keyEquivalentModifierMask == .command && helperDefault.representedObject == nil
                    && helperDefault.isEnabled && helperDefault.state == .off,
                "F191 the shared menu helper keeps NSMenuItem defaults when options are omitted")
            let items = walk(bar, "")
            check(
                bar.items.map(\.title) == [
                    "TextTank", "File", "Edit", "Find", "View", "Compare", "Tools", "Window", "Help"
                ], "DS-D4 the menu bar has the nine top-level menus in order")
            // Items without a target go to the first responder. The chain is walked here from the
            // editor that would be focused, so the check does not depend on the test process
            // being allowed to hold the key window.
            var chain: [NSObject] = []
            var responder: NSResponder? = document.editor.subviews.first
            while let current = responder {
                chain.append(current)
                responder = current.nextResponder
            }
            chain += [window, controller, document, NSApp, sessionDelegate, NSDocumentController.shared]
            let innermost = descendants(document.editor).filter { $0.acceptsFirstResponder }
            chain = innermost + chain
            var dead: [String] = []
            for (path, item) in items {
                guard let action = item.action else { continue }
                if let target = item.target {
                    if (target as? NSObject)?.responds(to: action) != true { dead.append(path) }
                } else if !chain.contains(where: { $0.responds(to: action) }) {
                    dead.append(path)
                }
            }
            if !check(dead.isEmpty, "every menu item with an action reaches an object that implements it") {
                print("NOTE dead menu items: \(dead)")
            }
            check(items.count >= 100, "the walk reaches the whole menu tree (\(items.count) items with actions)")
            func represented(_ action: Selector) -> [String] {
                items.filter { $0.1.action == action }.compactMap { $0.1.representedObject as? String }
            }
            // The reviewed menu fixtures own expected placement, selector and exact multiplicity.
            // The native command table owns what the editor can actually execute.
            let commandSelector = #selector(EditorWindowController.command(_:))
            let expectedCommands = expectedMenu.compactMap { row in
                row["action"] == NSStringFromSelector(commandSelector) ? row["object"] : nil
            }.sorted()
            let commands = represented(commandSelector)
            let native = Set(TTEditor.supportedCommandIdentifiers().map(\.rawValue))
            let unknown = commands.filter { id in
                if id.hasPrefix("transform.") { return EditorTransform(rawValue: String(id.dropFirst(10))) == nil }
                guard let command = EditorCommand(rawValue: id) else { return true }
                return !native.contains(command.nativeIdentifier.rawValue)
            }
            if !check(
                unknown.isEmpty && expectedCommands.count >= 40 && commands.sorted() == expectedCommands,
                "every editor command menu item names a transform or a command the bridge dispatches")
            {
                print("NOTE unknown command names: \(unknown); missing: \(Set(expectedCommands).subtracting(commands).sorted()); extra: \(Set(commands).subtracting(expectedCommands).sorted()); actual/expected counts: \(commands.count)/\(expectedCommands.count)")
            }
            check(
                Set(commands.filter { $0.hasPrefix("transform.") }.map { String($0.dropFirst(10)) })
                    == Set(EditorTransform.allCases.map(\.rawValue)), "every EditorTransform case has a menu item")
            let comments = represented(#selector(EditorWindowController.comment(_:)))
            check(
                Set(comments) == Set(CommentCommand.allCases.map(\.rawValue))
                    && comments.count == CommentCommand.allCases.count, "every comment menu item names a CommentCommand"
            )
            let reloads = represented(#selector(TextDocument.reloadEncoding(_:)))
            check(
                Set(reloads) == Set(FileEncoding.allCases.map(\.rawValue))
                    && reloads.allSatisfy { FileEncoding(rawValue: $0) != nil },
                "every Reload-as item names a FileEncoding")
            check(
                represented(#selector(EditorWindowController.convertEOL(_:))) == ["LF", "CRLF", "CR"],
                "line-ending conversion items carry LF, CRLF and CR")
            // Convert-to-encoding: each code maps to the format its title promises.
            let expectedFormats: [String: FileFormat] = [
                "utf8": FileFormat(encoding: .utf8, bom: false), "utf8bom": FileFormat(encoding: .utf8, bom: true),
                "utf16LE": FileFormat(encoding: .utf16LE, bom: true),
                "utf16BE": FileFormat(encoding: .utf16BE, bom: true),
                "windows1252": FileFormat(encoding: .windows1252, bom: false),
                "latin1": FileFormat(encoding: .latin1, bom: false)
            ]
            let conversions = items.filter { $0.1.action == #selector(TextDocument.convertEncoding(_:)) }.map { $0.1 }
            check(
                Set(conversions.compactMap { $0.representedObject as? String }) == Set(expectedFormats.keys)
                    && conversions.count == expectedFormats.count,
                "Convert-to items carry exactly the known encoding codes")
            let sample = "caf\u{E9} text\r\n"
            for item in conversions.reversed() {
                guard let code = item.representedObject as? String, let expected = expectedFormats[code] else {
                    continue
                }
                let converting = TextDocument()
                converting.editor.text = sample
                converting.editor.resetUndoHistory()
                let revision = converting.editor.revision
                converting.format = FileFormat(encoding: code == "latin1" ? .utf8 : .latin1, bom: false)
                converting.convertEncoding(item)
                check(
                    converting.format == expected && converting.editor.text == sample
                        && converting.editor.revision == revision
                        && converting.isDocumentEdited == (expected != converting.savedFormat),
                    "Convert to \(code) changes the format, keeps the text and marks the document edited unless that is its saved format"
                )
                check(
                    try converting.data(ofType: "Plain Text") == FileCodec.encode(sample, format: expected),
                    "Convert to \(code) saves the bytes FileCodec produces for that format")
                converting.close()
            }
            // Line-ending conversion and wrap through the real actions.
            document.editor.text = "a\r\nb\rc\n"
            document.editor.resetUndoHistory()
            for (mode, expected, eol) in [
                ("CRLF", "a\r\nb\r\nc\r\n", 0), ("CR", "a\rb\rc\r", 1), ("LF", "a\nb\nc\n", 2)
            ] {
                let item = try requireValue(
                    items.first {
                        $0.1.action == #selector(EditorWindowController.convertEOL(_:))
                            && $0.1.representedObject as? String == mode
                    }?.1, "fixture: \(mode) menu item")
                controller.convertEOL(item)
                check(
                    same(document.editor.text, expected) && document.editor.statusInfo.eol.rawValue == eol,
                    "Convert Line Endings to \(mode) rewrites every ending and switches the insertion ending")
            }
            let wrapped = controller.activeEditor.wrap
            controller.toggleWrap(nil)
            check(controller.activeEditor.wrap == !wrapped, "Wrap Lines toggles the active view")
            controller.toggleWrap(nil)
            let upper = try requireValue(
                items.first { $0.1.representedObject as? String == "upper" }?.1, "fixture: Uppercase menu item")
            document.editor.text = "abc def"
            _ = document.editor.setSelectionAnchor(0, caret: 3)
            controller.command(upper)
            check(
                document.editor.text == "ABC def", "an editor command menu item runs its command on the active editor")
            let sort = try requireValue(
                items.first { $0.1.representedObject as? String == "transform.sortAscending" }?.1,
                "fixture: sort menu item")
            document.editor.text = "b\na\n"
            controller.command(sort)
            check(document.editor.text == "a\nb\n", "a transform menu item runs its transform on the active editor")
            // G369: every command that edits text states the one read-only reason first and changes nothing.
            document.editor.text = "b\r\na\n"
            document.editor.resetUndoHistory()
            document.editor.setSavePoint()
            _ = document.editor.setSelectionAnchor(0, caret: 1)
            let lockedFormat = document.format, lockedRevision = document.editor.revision,
                lockedEdited = document.isDocumentEdited
            document.editor.readOnly = true
            let unchangedWhileLocked = { () -> Bool in
                same(document.editor.text, "b\r\na\n") && document.editor.revision == lockedRevision
                    && !document.editor.modified && document.format == lockedFormat
                    && document.isDocumentEdited == lockedEdited
                    && document.editor.selectionAnchor == 0 && document.editor.selectionCaret == 1
            }
            for id in ["upper", "deleteLine", "paste", "undo", "trimTrailing", "joinLines", "transform.sortAscending"] {
                rejects(
                    "the \(id) command states that the document is read-only", message: "This document is read-only"
                ) { try controller.perform(command: id) }
            }
            check(unchangedWhileLocked(), "editing commands refused as read-only change nothing")
            try controller.perform(command: "selectAll")
            check(
                document.editor.selectionStart == 0 && document.editor.selectionEnd == 5,
                "a command that edits nothing still runs in a read-only document")
            _ = document.editor.setSelectionAnchor(0, caret: 1)
            rejects("Convert Line Endings states that the document is read-only", message: "This document is read-only")
            { try controller.convertLineEndings(to: .lf) }
            check(
                unchangedWhileLocked() && document.editor.statusInfo.eol.rawValue == 2,
                "a refused line-ending conversion changes neither the text nor the insertion ending")
            rejects(
                "Convert to an encoding states that the document is read-only", message: "This document is read-only"
            ) { try document.convertEncoding(to: "utf16LE") }
            check(
                unchangedWhileLocked(), "a refused encoding conversion keeps the format and does not dirty the document"
            )
            controller.replaceField.stringValue = "forbidden"
            rejects(
                "Replace Selection in the bar states that the document is read-only",
                message: "This document is read-only"
            ) { try controller.replaceSelectionFromBar() }
            check(unchangedWhileLocked(), "a refused Replace Selection changes neither the text nor the selection")
            document.editor.readOnly = false
            controller.findField.stringValue = "b"
            try controller.replaceSelectionFromBar()
            spinUntil("the strict inline replacement to finish") { !controller.inlineSearchPending }

            check(
                same(document.editor.text, "forbidden\r\na\n"),
                "Replace Selection in the bar replaces the selection once the document is writable")
            try controller.convertLineEndings(to: .lf)
            check(
                same(document.editor.text, "forbidden\na\n"),
                "Convert Line Endings converts once the document is writable")
            rejects("an unknown native line-ending code is refused with a reason", message: "could not be converted") {
                try controller.convertLineEndings(to: TTLineEndingMode(rawValue: -1)!)
            }
            // Column insert: the success path of applyColumn, with one Undo.
            document.editor.text = "x\nx\nx\n"
            document.editor.resetUndoHistory()
            document.editor.setSavePoint()
            try require(
                document.editor.setSelectionRanges([
                    TTSelectionRange(anchor: 0, caret: 1), TTSelectionRange(anchor: 2, caret: 3),
                    TTSelectionRange(anchor: 4, caret: 4)
                ]), "fixture: three column selections")
            let columnRevision = document.editor.revision, columnSelections = document.editor.selectionRanges
            check(
                EditorWindowController.applyColumn(
                    ["1", "2", "3"], to: document.editor, revision: columnRevision, selections: columnSelections)
                    && document.editor.text == "1\n2\n3x\n",
                "column insertion replaces each selection with its own value in selection order")
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                document.editor.text == "x\nx\nx\n" && !document.editor.modified,
                "column insertion is one Undo back to the save point")
            check(
                !EditorWindowController.applyColumn(
                    ["1", "2", "3"], to: document.editor, revision: columnRevision, selections: columnSelections),
                "a column insertion captured before an edit is refused afterwards")
            // Insert into Each Selection through its real dialog: plain text, then sequential numbers.
            // F207: a dialog that cannot do what was asked says why in a second alert. The helpers
            // below answer the dialog, then record that alert's text here and dismiss it.
            let explanation = ColumnExplanation()
            let dismissExplanation: @MainActor @Sendable (NSWindow, NSWindow?) -> Void = { modal, dialog in
                guard modal !== dialog, let content = modal.contentView,
                    let ok = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "OK" })
                else { return }
                explanation.text = descendants(content).compactMap { ($0 as? NSTextField)?.stringValue }.joined(
                    separator: "\n")
                ok.performClick(nil)
            }
            @MainActor func columnDialog(
                text: String, numbered: Bool, start: String, step: String, confirm: Bool = true
            ) -> Bool {
                var acted = false, timedOut = false
                var dialog: NSWindow?
                explanation.text = ""
                let deadline = Date().addingTimeInterval(10)
                let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard let modal = NSApp.modalWindow, let content = modal.contentView else { return }
                        if Date() > deadline {
                            timedOut = true
                            NSApp.abortModal()
                            return
                        }
                        guard !acted else {
                            dismissExplanation(modal, dialog)
                            return
                        }
                        let views = descendants(content)
                        @MainActor func find<T: NSView>(_ identifier: String, _ type: T.Type) -> T? {
                            views.compactMap { $0 as? T }.first { $0.identifier?.rawValue == identifier }
                        }
                        guard let textField = find("column.text", NSTextField.self),
                            let number = find("column.number", NSButton.self),
                            let startField = find("column.start", NSTextField.self),
                            let stepField = find("column.step", NSTextField.self),
                            let press = find(confirm ? "column.insert" : "column.cancel", NSButton.self)
                        else { return }
                        acted = true
                        dialog = modal
                        textField.stringValue = text
                        number.state = numbered ? .on : .off
                        startField.stringValue = start
                        stepField.stringValue = step
                        press.performClick(nil)
                    }
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                controller.columnInsert(nil)
                timer.invalidate()
                return acted && !timedOut
            }
            @MainActor func threeSelections() throws -> UInt {
                document.editor.text = "x\nx\nx\n"
                document.editor.resetUndoHistory()
                document.editor.setSavePoint()
                try require(
                    document.editor.setSelectionRanges([
                        TTSelectionRange(anchor: 0, caret: 1), TTSelectionRange(anchor: 2, caret: 3),
                        TTSelectionRange(anchor: 4, caret: 5)
                    ]), "fixture: three selected columns")
                return document.editor.revision
            }
            _ = try threeSelections()
            check(
                columnDialog(text: "ab", numbered: false, start: "1", step: "1")
                    && document.editor.text == "ab\nab\nab\n",
                "Insert into Each Selection puts the typed text in every selection")
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                document.editor.text == "x\nx\nx\n" && !document.editor.modified,
                "the dialog's insertion is one Undo back to the save point")
            _ = try threeSelections()
            check(
                columnDialog(text: "ignored", numbered: true, start: "8", step: "-4")
                    && document.editor.text == "8\n4\n0\n",
                "sequential numbers start at Start and add Increment per selection, in selection order")
            _ = try threeSelections()
            check(
                columnDialog(text: "", numbered: true, start: "007", step: "0") && document.editor.text == "7\n7\n7\n",
                "a zero increment repeats the start value, written without leading zeros")
            var untouched = try threeSelections()
            check(
                columnDialog(text: "", numbered: true, start: "one", step: "1") && document.editor.text == "x\nx\nx\n"
                    && document.editor.revision == untouched, "a start value that is not a whole number inserts nothing"
            )
            check(
                explanation.text.contains("Start and Increment must be whole numbers"),
                "a start value that is not a whole number is explained instead of a beep")
            untouched = try threeSelections()
            check(
                columnDialog(text: "", numbered: true, start: String(Int.max), step: "1")
                    && document.editor.text == "x\nx\nx\n" && document.editor.revision == untouched,
                "a sequence that would overflow inserts nothing")
            check(
                explanation.text.contains("The number sequence is too large"),
                "a sequence that would overflow is explained instead of a beep")
            untouched = try threeSelections()
            check(
                columnDialog(text: "ab", numbered: false, start: "1", step: "1", confirm: false)
                    && document.editor.text == "x\nx\nx\n" && document.editor.revision == untouched,
                "Cancel in Insert into Each Selection inserts nothing")
            check(explanation.text.isEmpty, "Cancel in Insert into Each Selection shows no explanation")
            // F12: Go to Line through its real inline field, on the engine's own line model.
            @MainActor func goToLineDialog(_ entry: String, confirm: Bool = true) -> Bool {
                explanation.text = ""
                let item = NSMenuItem(title: "Go to Line…", action: nil, keyEquivalent: "")
                item.representedObject = "goToLine"
                controller.perform(NSSelectorFromString("statusOption:"), with: item)
                let bar = controller.goToLineBar, field = bar.field
                guard controller.goToLineBarVisible, presentedFormWindow == nil else { return false }
                field.stringValue = entry
                controller.controlTextDidChange(
                    Notification(name: NSControl.textDidChangeNotification, object: field))
                guard confirm else {
                    bar.cancelButton.performClick(nil)
                    return !controller.goToLineBarVisible
                }
                bar.goButton.performClick(nil)
                if controller.goToLineBarVisible {
                    // Invalid input remains in this same inline field, instead of an alert.
                    explanation.text = bar.message.stringValue
                    check(
                        field.stringValue == entry && field.accessibilityHelp() != nil,
                        "DG Go to Line keeps and marks the rejected input")
                    bar.cancelButton.performClick(nil)
                }
                return !controller.goToLineBarVisible
            }
            document.editor.text = "é\r\nbb\rccc\n"
            document.editor.resetUndoHistory()
            document.editor.setSavePoint()
            let goRevision = document.editor.revision
            check(
                goToLineDialog("3") && document.editor.selectionCaret == 7 && document.editor.selectionAnchor == 7,
                "Go to Line places the caret at the start of the one-based line across CRLF and CR")
            check(
                goToLineDialog("4") && document.editor.selectionCaret == 11 && explanation.text.isEmpty,
                "Go to Line reaches the empty line after the final line break, with nothing to explain")
            for entry in ["5", "0", "two", "-1"] {
                check(
                    goToLineDialog(entry) && document.editor.selectionCaret == 11
                        && explanation.text.contains("Lines are 1–4."),
                    "Go to Line \(entry) says that line does not exist and names the valid range")
            }
            check(
                goToLineDialog("5") && goToLineDialog("0") && goToLineDialog("two") && goToLineDialog("-1")
                    && document.editor.selectionCaret == 11,
                "Go to Line leaves the caret alone for lines that do not exist and for non-numbers")
            check(
                goToLineDialog("1", confirm: false) && document.editor.selectionCaret == 11,
                "Cancel in Go to Line leaves the caret alone")
            check(
                goToLineDialog("1") && document.editor.selectionCaret == 0 && document.editor.revision == goRevision
                    && !document.editor.modified, "Go to Line never edits the document")
            // F277: Go to Line and Clear Selection have no recordable step. A macro recording is
            // discarded when one of them moves the caret or the selection, and only then.
            let recorder = MacroController(editorProvider: { document.editor })
            var discarded: [String] = []
            recorder.onInvalidated = { discarded.append($0) }
            document.editor.text = "one\ntwo\nthree\n"
            document.editor.resetUndoHistory()
            document.editor.setSavePoint()
            _ = document.editor.setSelectionAnchor(0, caret: 0)
            recorder.startRecording()
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "charRight"))
            check(
                !EditorWindowController.goToLine(9, in: document.editor, macros: recorder)
                    && EditorWindowController.clearSelection(in: document.editor, macros: recorder)
                    && discarded.isEmpty && document.editor.selectionCaret == 1,
                "a line that does not exist and an already empty selection leave a recording alone")
            check(
                try recorder.finishRecording()?.steps.count == 1,
                "the recording is still saveable after a refused Go to Line and a no-op Clear Selection")
            recorder.startRecording()
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "charRightExtend"))
            check(
                EditorWindowController.clearSelection(in: document.editor, macros: recorder)
                    && document.editor.selectionAnchor == document.editor.selectionCaret
                    && discarded == ["Clear Selection is not recorded in macros yet."],
                "Clear Selection of a real selection discards the recording when it clears")
            rejects("Clear Selection cannot silently save a partial recording", message: "Clear Selection") {
                _ = try recorder.finishRecording()
            }
            recorder.startRecording()
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "charRight"))
            check(
                EditorWindowController.goToLine(3, in: document.editor, macros: recorder)
                    && document.editor.selectionCaret == 8 && discarded.count == 2
                    && discarded.last?.contains("Go to Line") == true,
                "Go to Line discards the recording when the caret moves")
            rejects("Go to Line cannot silently save a partial recording", message: "Go to Line") {
                _ = try recorder.finishRecording()
            }
            check(
                EditorWindowController.goToLine(1, in: document.editor, macros: nil)
                    && document.editor.selectionCaret == 0 && discarded.count == 2,
                "Go to Line outside a recording moves the caret and reports nothing")
            document.editor.text = ""
            document.close()
        }
    }
}
