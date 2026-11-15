// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@main struct DocumentChecks {
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor static func inspectGeometry(_ editor: TTEditor, label: String) {
        for view in descendants(editor) {
            print(
                "GEOMETRY \(label) \(type(of:view)) frame=\(view.frame) bounds=\(view.bounds) visible=\(view.visibleRect)"
            )
        }
        fflush(stdout)
        let contents = descendants(editor).compactMap { ($0 as? NSScrollView)?.documentView }
        check(contents.count == 1, "\(label) one Scintilla content view")
        guard let content = contents.first else { return }
        check(
            content.visibleRect.width > 100 && content.visibleRect.height > 100,
            "\(label) content viewport has visible area")
        check(content.frame.minY >= 0 && content.frame.minX >= 0, "\(label) content origin not offscreen")
        if let scroll = descendants(editor).first(where: { $0 is NSScrollView }) as? NSScrollView {
            check(
                scroll.contentView.bounds.minY >= 0 && scroll.contentView.bounds.minY < content.frame.height,
                "\(label) clip origin inside content")
        }
    }
    @MainActor static func main() {
        Checks.run("DocumentChecks") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankDocumentChecks-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            setenv("TEXTTANK_SUPPORT_DIRECTORY", root.appendingPathComponent("support").path, 1)
            defer { try? FileManager.default.removeItem(at: root) }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            print("SCREENS \(NSScreen.screens.map { $0.frame })")
            fflush(stdout)
            // Sections run in this order and share one process, one support directory and the
            // shared document controller. Each section ends by restoring the application delegate
            // it started with and by closing any document it left registered; leaving one behind
            // on a normal finish is itself reported, so a missing close cannot hide.
            @MainActor func section(_ name: String, line: UInt = #line, _ body: () throws -> Void) {
                let delegate = app.delegate
                Checks.section(name, line: line) {
                    var finished = false
                    defer {
                        let left = NSDocumentController.shared.documents
                        if finished && !left.isEmpty {
                            Checks.fail(
                                "section '\(name)' left \(left.count) document(s) open", file: #filePath, line: line)
                        }
                        left.forEach { $0.close() }
                        app.delegate = delegate
                    }
                    try body()
                    finished = true
                }
            }
            // Written by the single-document section and read by the session and recovery section.
            let saved = root.appendingPathComponent("saved-as.txt")
            section("automation configuration and settings") {
                let automation = AutomationController(
                    editorProvider: { nil }, newDocument: { _ in fatalError("Saving must not run a workflow") })
                let configuration = AutomationLibrary(workflows: [.example])
                try automation.persistLibrary(configuration)
                let support = root.appendingPathComponent("support"),
                    configurationURL = support.appendingPathComponent("Automations.json")
                let supportMode =
                    (try FileManager.default.attributesOfItem(atPath: support.path)[.posixPermissions] as! NSNumber)
                    .intValue
                let configMode =
                    (try FileManager.default.attributesOfItem(atPath: configurationURL.path)[.posixPermissions]
                    as! NSNumber).intValue
                check(supportMode == 0o700 && configMode == 0o600, "automation configuration private at creation")
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configurationURL.path)
                try automation.persistLibrary(configuration)
                let replacedConfigMode =
                    (try FileManager.default.attributesOfItem(atPath: configurationURL.path)[.posixPermissions]
                    as! NSNumber).intValue
                check(replacedConfigMode == 0o600, "automation atomic replacement restores private metadata")
                let configBytes = try Data(contentsOf: configurationURL)
                check(
                    try AutomationLibrary.decode(configBytes) == configuration,
                    "private automation save retains exact definition")
                try FileManager.default.removeItem(at: configurationURL)
                let alternate = root.appendingPathComponent("untouched-config.json")
                try configBytes.write(to: alternate)
                try FileManager.default.createSymbolicLink(at: configurationURL, withDestinationURL: alternate)
                rejects("automation persistence rejects symlink target", message: "must be a regular file") {
                    try automation.persistLibrary(configuration)
                }
                check(try Data(contentsOf: alternate) == configBytes, "automation symlink target unchanged")
                try FileManager.default.removeItem(at: configurationURL)
                let settings = SettingsController(url: root.appendingPathComponent("Settings.json"))
                var configured = EditorSettings()
                configured.tabWidth = 8
                configured.useTabs = false
                configured.wrap = true
                configured.shortcuts = ["upper": "u"]
                try settings.save(configured)
                check(
                    SettingsController(url: settings.url).value == configured,
                    "versioned settings persist across controller restart")
                var conflict = configured
                conflict.shortcuts = ["upper": "d"]
                rejects("shortcut conflicts with default command binding") { try settings.save(conflict) }
                conflict.shortcuts = ["upper": ","]
                rejects("shortcut cannot steal Settings") { try settings.save(conflict) }
                conflict.shortcuts = ["upper": "u", "lower": "u"]
                rejects("duplicate custom shortcuts rejected") { try settings.save(conflict) }
                check(
                    SettingsController(url: settings.url).value == configured,
                    "rejected settings retain prior on-disk configuration")
                conflict.version = 99
                rejects("future settings version rejected") { try settings.save(conflict) }
                // F199: a settings file that failed to load is never overwritten without explicit confirmation.
                var futureSettings = configured
                futureSettings.version = 2
                var reservedSettings = configured
                reservedSettings.shortcuts = ["upper": "s"]
                let futureJSON = String(decoding: try JSONEncoder().encode(futureSettings), as: UTF8.self),
                    reservedJSON = String(decoding: try JSONEncoder().encode(reservedSettings), as: UTF8.self)
                for (label, contents) in [
                    ("future version", futureJSON), ("reserved shortcut", reservedJSON), ("malformed JSON", "{not json")
                ] {
                    let folder = root.appendingPathComponent("unreadable-settings-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let unreadableURL = folder.appendingPathComponent("Settings.json"),
                        unreadableBytes = Data(contents.utf8)
                    try unreadableBytes.write(to: unreadableURL)
                    let unreadable = SettingsController(url: unreadableURL)
                    check(
                        unreadable.loadError != nil && unreadable.value == EditorSettings(),
                        "\(label): unreadable settings load as defaults with an error")
                    check(
                        unreadable.loadFailureMessage?.contains("default settings are in use") == true
                            && unreadable.loadFailureMessage?.contains("has not been changed") == true
                            && unreadable.loadFailureMessage?.contains(unreadableURL.path) == true,
                        "\(label): launch message says defaults are in use and the file is unchanged")
                    rejects("\(label): unconfirmed save over unreadable settings refused") {
                        try unreadable.save(configured)
                    }
                    check(
                        try Data(contentsOf: unreadableURL) == unreadableBytes
                            && FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Settings.json"],
                        "\(label): refused save leaves the unreadable file byte-identical")
                    check(
                        unreadable.loadError != nil && unreadable.value == EditorSettings(),
                        "\(label): refused save keeps the load failure")
                    var invalid = configured
                    invalid.tabWidth = 99
                    rejects("\(label): confirmed save still validates") {
                        try unreadable.save(invalid, replacingUnreadable: true)
                    }
                    check(
                        try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Settings.json"],
                        "\(label): invalid confirmed save moves nothing aside")
                    let backupURL = try unreadable.save(configured, replacingUnreadable: true)
                    let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
                        $0 != "Settings.json"
                    }
                    check(
                        siblings.count == 1 && siblings[0].hasPrefix("Settings.unreadable-")
                            && backupURL?.lastPathComponent == siblings[0],
                        "\(label): confirmed replacement keeps exactly one backup sibling")
                    check(
                        try Data(contentsOf: folder.appendingPathComponent(siblings[0])) == unreadableBytes,
                        "\(label): backup holds the original bytes")
                    check(
                        unreadable.loadError == nil && unreadable.loadFailureMessage == nil
                            && SettingsController(url: unreadableURL).value == configured,
                        "\(label): confirmed replacement persists and clears the load failure")
                    check(
                        try unreadable.save(EditorSettings()) == nil
                            && FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2,
                        "\(label): later saves need no confirmation and make no further backups")
                }
                let linkFolder = root.appendingPathComponent("linked-settings")
                try FileManager.default.createDirectory(at: linkFolder, withIntermediateDirectories: true)
                let linkTarget = linkFolder.appendingPathComponent("elsewhere.json"),
                    linkBytes = Data("{\"version\":2}".utf8)
                try linkBytes.write(to: linkTarget)
                let linkedURL = linkFolder.appendingPathComponent("Settings.json")
                try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: linkTarget)
                let linked = SettingsController(url: linkedURL)
                check(linked.loadError != nil, "symlinked settings are not read")
                rejects(
                    "confirmed save refuses a symlinked settings entry",
                    where: {
                        if case WorkspaceError.unsafeLocation = $0 { return true }
                        return false
                    }
                ) { try linked.save(configured, replacingUnreadable: true) }
                check(
                    try Data(contentsOf: linkTarget) == linkBytes
                        && FileManager.default.contentsOfDirectory(atPath: linkFolder.path).sorted() == [
                            "Settings.json", "elsewhere.json"
                        ] && FileManager.default.destinationOfSymbolicLink(atPath: linkedURL.path) == linkTarget.path,
                    "symlinked settings entry and its target are left untouched")
                let missing = SettingsController(
                    url: root.appendingPathComponent("missing-settings").appendingPathComponent("Settings.json"))
                check(
                    missing.loadError == nil && missing.loadFailureMessage == nil,
                    "missing settings file is not a load failure")
                check(
                    try missing.save(configured) == nil && SettingsController(url: missing.url).value == configured,
                    "missing settings file saves without confirmation or backup")
            }
            section("line transforms and byte-order marks") {
                check(
                    EditorTransform.sortAscending.transform("b\r\na\n") == "a\r\nb\n",
                    "line sorting retains mixed separator positions")
                check(EditorTransform.reverseLines.transform("a\nb") == "b\na", "reverse retains absence of final EOL")
                check(
                    EditorTransform.uniqueLines.transform("a\na\nb\n") == "a\nb\n",
                    "duplicate removal preserves kept row separators")
                check(
                    EditorTransform.trimBoth.transform(" \tα  \r\n b\t") == "α\r\nb", "trim preserves Unicode and EOL")
                check(
                    EditorTransform.uniqueLines.transform("é\ne\u{301}\n").utf8.elementsEqual("é\ne\u{301}\n".utf8),
                    "duplicate removal preserves canonically equivalent distinct bytes")
                // F11: a duplicate final row without a line ending must not leave one behind.
                func bytesEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
                let unique = EditorTransform.uniqueLines, invert = EditorTransform.invertCase,
                    title = EditorTransform.titleCase
                check(
                    bytesEqual(unique.transform("a\nb\na"), "a\nb"),
                    "duplicate removal adds no line ending when the unterminated last row is a duplicate")
                check(bytesEqual(unique.transform("a\na"), "a"), "duplicate removal of two equal rows leaves one row")
                check(
                    bytesEqual(unique.transform("a\nb"), "a\nb"),
                    "duplicate removal keeps an unterminated last row that is not a duplicate")
                check(
                    bytesEqual(unique.transform("a\r\na\nb\r"), "a\r\nb\r"),
                    "duplicate removal moves each separator with its kept row")
                check(
                    bytesEqual(unique.transform("a\r\nb\na"), "a\r\nb"),
                    "duplicate removal with mixed endings adds no line ending for a duplicate last row")
                check(
                    bytesEqual(EditorTransform.removeEmptyLines.transform("a\n\nb"), "a\nb")
                        && bytesEqual(EditorTransform.removeEmptyLines.transform("a\n\n"), "a\n"),
                    "empty-line removal is unchanged for unterminated and terminated input")
                // G348: Invert Case maps scalar for scalar; Title Case is deliberately left as it is.
                check(bytesEqual(invert.transform("aB1 "), "Ab1 "), "invert case swaps ASCII letters only")
                check(
                    bytesEqual(invert.transform("\u{E9}"), "\u{C9}")
                        && bytesEqual(invert.transform("e\u{301}"), "E\u{301}"),
                    "invert case handles precomposed and decomposed letters without recomposing")
                check(
                    bytesEqual(invert.transform("\u{3A3}\u{3C3}"), "\u{3C3}\u{3A3}")
                        && bytesEqual(invert.transform("\u{3C2}"), "\u{3A3}"),
                    "invert case still inverts Greek sigma, including final sigma")
                check(bytesEqual(invert.transform("aB\r\nc"), "Ab\r\nC"), "invert case leaves line endings alone")
                let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{1F600}"
                check(bytesEqual(invert.transform(family), family), "invert case returns emoji sequences unchanged")
                check(bytesEqual(title.transform("hello wORLD"), "Hello World"), "title case capitalizes each word")
                check(
                    bytesEqual(title.transform("don't x_y a1b"), "Don't X_y A1b"),
                    "title case keeps Foundation's word boundaries")
                check(
                    bytesEqual(title.transform("\u{DF}-stra\u{DF}e"), "Ss-Stra\u{DF}e"),
                    "title case is unchanged for a word-initial expanding letter")
                for (scalar, name) in [
                    ("\u{DF}", "sharp s"), ("\u{FB01}", "the fi ligature"), ("\u{130}", "dotted capital I"),
                    ("\u{1C5}", "a titlecase digraph")
                ] {
                    check(bytesEqual(invert.transform(scalar), scalar), "invert case leaves \(name) unchanged")
                }
                check(
                    bytesEqual(invert.transform(invert.transform("stra\u{DF}e")), "stra\u{DF}e"),
                    "invert case applied twice restores text containing sharp s")
                let mixed = "Stra\u{DF}e \u{FB01}nal \u{130}\u{1C5} \u{3C2}\u{3A3} e\u{301} \u{1F600}\r\n"
                check(
                    invert.transform(mixed).unicodeScalars.count == mixed.unicodeScalars.count,
                    "invert case preserves the scalar count of mixed text")
                let inverted = TextDocument()
                inverted.editor.text = "Stra\u{DF}e\nabc\n"
                inverted.editor.resetUndoHistory()
                inverted.editor.setSavePoint()
                try EditorTransform.invertCase.apply(to: inverted.editor)
                check(bytesEqual(inverted.editor.text, "sTRA\u{DF}E\nABC\n"), "invert case edits the document buffer")
                inverted.editor.executeCommand("undo")
                check(
                    bytesEqual(inverted.editor.text, "Stra\u{DF}e\nabc\n") && !inverted.editor.modified,
                    "invert case is one Undo back to the save point")
                inverted.close()
                let transformed = TextDocument()
                transformed.editor.text = "b\na\n"
                transformed.editor.resetUndoHistory()
                try EditorTransform.sortAscending.apply(to: transformed.editor)
                check(transformed.editor.text == "a\nb\n", "native line sorting changes authoritative buffer")
                transformed.editor.executeCommand("undo")
                check(transformed.editor.text == "b\na\n", "native line sorting one Undo")
                // G368: a whole-document transform keeps bookmarks and the caret line.
                let indented = (0..<60).map { "  row \($0)\n" }.joined()
                transformed.editor.text = indented
                transformed.editor.resetUndoHistory()
                try require(transformed.editor.setBookmarks([7, 40]), "fixture: bookmarks before a transform")
                try require(transformed.editor.goToLine(41), "fixture: caret on line 41 before a transform")
                try EditorTransform.trimLeading.apply(to: transformed.editor)
                check(
                    transformed.editor.text == indented.replacingOccurrences(of: "  row", with: "row")
                        && transformed.editor.bookmarkLines == [7, 40]
                        && transformed.editor.statusInfo["line"]?.intValue == 41,
                    "whole-document transform keeps bookmarks and the caret line")
                transformed.editor.executeCommand("undo")
                check(
                    transformed.editor.text == indented && transformed.editor.statusInfo["line"]?.intValue == 41,
                    "whole-document transform is one Undo, which also returns the caret to its line")
                // Scintilla's Undo deletes and reinserts the replaced span, and undo history does not
                // record markers, so bookmarks inside a span that covers every line collapse on Undo.
                knownDefect(
                    "G368", "bookmarks inside a transform that changed every line survive its Undo",
                    fixed: transformed.editor.bookmarkLines == [7, 40])
                transformed.close()
                let bomDocument = TextDocument()
                let doubleBOM = Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x61])
                try bomDocument.read(from: doubleBOM, ofType: "Plain Text")
                check(
                    bomDocument.editor.text == "\u{FEFF}a", "file BOM stripped once, content FEFF preserved in editor")
                check(
                    try bomDocument.data(ofType: "Plain Text") == doubleBOM,
                    "native document double BOM exact byte roundtrip")
                bomDocument.close()
            }
            section("single-document lifecycle, save conflicts and split view") {
                let original = root.appendingPathComponent("document.txt")
                let initial = Data("first\r\nsecond\n👩🏽‍💻\0\r".utf8)
                try initial.write(to: original)
                let document = TextDocument()
                document.fileURL = original
                document.fileType = "Plain Text"
                NSDocumentController.shared.addDocument(document)
                try document.read(from: initial, ofType: "Plain Text")
                check(try document.data(ofType: "Plain Text") == initial, "native document exact bytes roundtrip")
                // F126: the insertion ending follows the file's first line break; loading never edits.
                check(
                    document.editor.statusInfo["eol"]?.intValue == 0, "mixed file inserts its first line ending (CRLF)")
                check(
                    document.editor.text.utf8.elementsEqual(String(decoding: initial, as: UTF8.self).utf8)
                        && !document.editor.modified && !document.isDocumentEdited,
                    "setting the line-ending mode on load leaves text and dirty state untouched")
                let eolDocument = TextDocument()
                try eolDocument.read(from: Data("a\r\nb".utf8), ofType: "Plain Text")
                _ = eolDocument.editor.setSelectionAnchor(4, caret: 4)
                eolDocument.editor.executeCommand("newLine")
                check(
                    eolDocument.editor.text.utf8.elementsEqual("a\r\nb\r\n".utf8),
                    "Return in a CRLF file inserts CRLF, not a bare LF")
                eolDocument.editor.convertLineEndings("LF")
                check(
                    eolDocument.editor.statusInfo["eol"]?.intValue == 2,
                    "explicit conversion switches the insertion ending")
                for (bytes, mode, label) in [
                    ("x\ry\n", 1, "CR"), ("p\nq\r\n", 2, "LF"), ("a\r\nb\n", 0, "CRLF"),
                    ("no line break", 2, "LF fallback")
                ] {
                    try eolDocument.read(from: Data(bytes.utf8), ofType: "Plain Text")
                    check(
                        eolDocument.editor.statusInfo["eol"]?.intValue == mode && !eolDocument.editor.modified,
                        "reload into the same document follows the loaded file: \(label)")
                    check(
                        try eolDocument.data(ofType: "Plain Text") == Data(bytes.utf8),
                        "untouched \(label) file saves byte-identically")
                }
                eolDocument.close()
                document.makeWindowControllers()
                print("OBSERVED controllers=\(document.windowControllers.count) windows=\(NSApp.windows.count)")
                fflush(stdout)
                check(document.windowControllers.count == 1, "NSDocument owns one window controller")
                let
                    controller = try requireValue(
                        document.windowControllers.first as? EditorWindowController,
                        "fixture: the document has its editor window controller"),
                    window = try requireValue(controller.window, "fixture: the controller has a window")
                check(
                    controller.document === document && window.windowController === controller,
                    "native controller document/window ownership")
                let columnRevision = document.editor.revision, columnSelections = document.editor.selectionRanges
                _ = document.editor.setSelectionAnchor(0, caret: 1)
                check(
                    !EditorWindowController.applyColumn(
                        ["X"], to: document.editor, revision: columnRevision, selections: columnSelections),
                    "column dialog stale selection cannot edit different range")
                check(
                    document.editor.text.utf8.elementsEqual(String(decoding: initial, as: UTF8.self).utf8),
                    "rejected column leaves original bytes unchanged")
                document.showWindows()
                window.orderFront(nil)
                check(window.isVisible, "native window visible after showWindows")
                check(
                    window.contentView != nil && document.editor.window === window,
                    "editor attached to visible document window")
                document.editor.executeCommand("selectAll")
                document.editor.replaceSelection("local edits 😀\r\n")
                check(
                    document.editor.modified && document.isDocumentEdited, "editing marks engine and NSDocument dirty")
                document.flushRecovery()
                check(
                    try TextDocument.recovery.load(id: document.recoveryID).text == document.editor.text,
                    "native edits flush exact recovery snapshot")
                try Data("external edit".utf8).write(to: original)
                rejects("external conflict refuses overwrite", message: "The file changed outside TextTank") {
                    try document.writeSafely(to: original, ofType: "Plain Text", for: .saveOperation)
                }
                check(
                    try Data(contentsOf: original) == Data("external edit".utf8),
                    "external bytes preserved after conflict")
                check(document.editor.modified && document.isDocumentEdited, "failed save remains dirty")
                check(document.editor.text == "local edits 😀\r\n", "failed save retains local edits")
                let blocked = root.appendingPathComponent("blocked")
                try Data("not a directory".utf8).write(to: blocked)
                rejects("native save denied path") {
                    try document.writeSafely(
                        to: blocked.appendingPathComponent("child.txt"), ofType: "Plain Text", for: .saveAsOperation)
                }
                check(document.editor.modified && document.isDocumentEdited, "denied-path save remains dirty")
                try document.writeSafely(to: saved, ofType: "Plain Text", for: .saveAsOperation)
                check(
                    try Data(contentsOf: saved) == Data("local edits 😀\r\n".utf8),
                    "native Save As writes exact editor bytes")
                check(
                    !document.editor.modified && !document.isDocumentEdited,
                    "successful save clears engine/document dirty state")
                document.fileURL = saved
                document.editor.executeCommand("selectAll")
                document.editor.replaceSelection("copy-only text")
                let copy = root.appendingPathComponent("copy.txt")
                try document.writeSafely(to: copy, ofType: "Plain Text", for: .saveToOperation)
                check(try Data(contentsOf: copy) == Data("copy-only text".utf8), "Save Copy writes exact bytes")
                check(document.editor.modified && document.isDocumentEdited, "Save Copy retains source dirty state")
                check(
                    try Data(contentsOf: saved) == Data("local edits 😀\r\n".utf8), "Save Copy does not overwrite source"
                )
                document.editor.executeCommand("undo")
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: saved.path)
                document.editor.executeCommand("selectAll")
                document.editor.replaceSelection("normal save")
                try document.writeSafely(to: saved, ofType: "Plain Text", for: .saveOperation)
                check(try Data(contentsOf: saved) == Data("normal save".utf8), "normal Save writes existing file")
                let mode =
                    (try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as! NSNumber)
                    .intValue
                check(mode == 0o640, "native Save preserves file permission metadata")
                document.editor.executeCommand("selectAll")
                document.editor.replaceSelection("local edits 😀\r\n")
                try document.writeSafely(to: saved, ofType: "Plain Text", for: .saveOperation)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                print(
                    "APP-GEOMETRY window=\(window.frame) root=\(String(describing:window.contentView?.frame)) split=\(controller.split.frame) rootAmbiguous=\(window.contentView?.hasAmbiguousLayout ?? false)"
                )
                fflush(stdout)
                inspectGeometry(document.editor, label: "before-clone")
                let priorDelegate = app.delegate
                let cloneDelegate = AppDelegate()
                app.delegate = cloneDelegate
                var cloneSettings = EditorSettings()
                cloneSettings.wrap = true
                cloneSettings.tabWidth = 8
                cloneSettings.useTabs = false
                try cloneDelegate.settings.save(cloneSettings)
                controller.clone(nil)
                check(
                    controller.secondary?.wrap == true && controller.secondary?.menu != nil,
                    "new clone inherits persisted view settings and automation context")
                app.delegate = priorDelegate
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let clone = try requireValue(controller.secondary, "fixture: the split view has a clone editor")
                inspectGeometry(document.editor, label: "source-after-clone")
                inspectGeometry(clone, label: "clone")
                if let content = window.contentView,
                    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
                {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        // Diagnostic output only: a screenshot that cannot be written is noted, never a failure.
                        let shot = TestPaths.artifacts.appendingPathComponent("document-clone.png")
                        do { try png.write(to: shot) } catch {
                            print("NOTE screenshot not written to \(shot.path): \(error.localizedDescription)")
                        }
                    }
                }
                clone.executeCommand("selectAll")
                clone.replaceSelection("clone changed shared document")
                check(document.editor.text == clone.text, "clone changes authoritative shared bytes")
                check(document.isDocumentEdited && document.editor.modified, "clone notifications mark owner dirty")
                controller.closeSplit(nil)
                check(
                    controller.secondary == nil && document.editor.text == "clone changed shared document",
                    "closing clone preserves owner buffer")
                document.editor.executeCommand("undo")
                check(document.editor.text == "local edits 😀\r\n", "shared undo survives closing clone")
                document.editor.executeCommand("selectAll")
                document.editor.replaceSelection("unsaved before read")
                try document.read(from: Data("reloaded".utf8), ofType: "Plain Text")
                document.editor.executeCommand("undo")
                check(
                    document.editor.text == "reloaded" && !document.editor.modified,
                    "read resets undo history and engine dirty state")
                document.editor.executeCommand("selectAll")
                document.editor.replaceSelection("unsaved before actual revert")
                // F7: the discarded draft's snapshot must not outlive Revert to Saved.
                document.flushRecovery()
                check(
                    try TextDocument.recovery.loadAll().contains {
                        $0.id == document.recoveryID && $0.text == "unsaved before actual revert"
                    }, "dirty draft has a recovery snapshot before revert")
                try Data([0xC3]).write(to: saved)
                rejects(
                    "revert of undecodable disk bytes fails",
                    where: {
                        if case FileCodecError.invalidBytes(.utf8) = $0 { return true }
                        return false
                    }
                ) { try document.revert(toContentsOf: saved, ofType: "Plain Text") }
                check(
                    document.editor.text == "unsaved before actual revert" && document.isDocumentEdited,
                    "failed revert keeps the dirty buffer")
                check(
                    try TextDocument.recovery.loadAll().contains { $0.id == document.recoveryID },
                    "failed revert keeps the recovery snapshot")
                try Data("reverted from disk".utf8).write(to: saved)
                try document.revert(toContentsOf: saved, ofType: "Plain Text")
                check(
                    try !TextDocument.recovery.loadAll().contains { $0.id == document.recoveryID },
                    "revert removes discarded recovery snapshot")
                document.editor.executeCommand("undo")
                check(
                    document.editor.text == "reverted from disk",
                    "actual NSDocument revert replaces text and clears undo")
                check(
                    !document.editor.modified && !document.isDocumentEdited,
                    "actual NSDocument revert clears both dirty states")
                document.editor.replaceSelection("unsaved")
                rejects(
                    "reinterpretation refuses dirty editor without discard",
                    message: "Reload would discard unsaved changes"
                ) { try document.reload(using: .latin1) }
                let protectedText = document.editor.text
                try Data([0xC3]).write(to: saved)
                rejects(
                    "invalid explicit reload preserves buffer",
                    where: {
                        if case FileCodecError.invalidBytes(.utf8) = $0 { return true }
                        return false
                    }
                ) { try document.reload(using: .utf8, discard: true) }
                check(
                    document.editor.text == protectedText && document.isDocumentEdited,
                    "failed reload preserves dirty text")
                check(try document.diskState() == .changed, "external byte changes detected")
                try Data([0x63, 0x61, 0x66, 0xE9]).write(to: saved)
                try document.reload(using: .latin1, discard: true)
                check(
                    document.editor.text == "café" && document.format.encoding == .latin1,
                    "explicit encoding reinterpretation reads disk bytes")
                check(!document.isDocumentEdited && !document.editor.modified, "successful reload resets dirty state")
                check(try document.diskState() == .unchanged, "reload updates external-change baseline")
                // G368: a reload after a small external change keeps bookmarks and the caret line.
                let monitored = (0..<60).map { "row \($0)\n" }.joined()
                try Data(monitored.utf8).write(to: saved)
                try document.reload(using: .utf8, discard: true)
                try require(document.editor.setBookmarks([5, 40]), "fixture: bookmarks on the reloaded text")
                try require(document.editor.goToLine(41), "fixture: caret on line 41")
                let externallyEdited = monitored.replacingOccurrences(of: "row 10\n", with: "row 1X\n")
                try Data(externallyEdited.utf8).write(to: saved)
                check(try document.diskState() == .changed, "fixture: one character changed on disk")
                try document.reload(using: .utf8, discard: true)
                check(
                    document.editor.text == externallyEdited && document.editor.bookmarkLines == [5, 40]
                        && document.editor.statusInfo["line"]?.intValue == 41,
                    "reload after a one-character disk change keeps bookmarks and the caret line")
                check(
                    try !document.editor.modified && !document.isDocumentEdited && document.diskState() == .unchanged,
                    "bookmark-preserving reload still resets dirty state and the disk baseline")
                document.editor.executeCommand("undo")
                check(document.editor.text == externallyEdited, "bookmark-preserving reload still clears undo")
                document.editor.readOnly = true
                try Data("locked reload".utf8).write(to: saved)
                try document.reload(using: .utf8)
                check(
                    document.editor.text == "locked reload" && document.editor.readOnly,
                    "explicit reload works while retaining read-only flag")
                document.close()
                check(!window.isVisible, "closing document hides its native window")
                NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
                app.updateWindows()
                check(
                    controller.focusObserver == nil && controller.automationObserver == nil,
                    "close removes callbacks before document detaches")
                check(
                    controller.activeEditor === document.editor,
                    "late retained controller access does not force-cast detached document")
                check(window.standardWindowButton(.closeButton)?.isHidden == false, "native close control is visible")
                let closeControl = controller.toolbar(
                    NSToolbar(identifier: "test"), itemForItemIdentifier: .init("TextTank.CloseTab"),
                    willBeInsertedIntoToolbar: true)
                check(
                    (closeControl?.view as? NSButton)?.title == "Close Tab",
                    "explicit close button remains accessible outside titlebar")
                check(
                    (closeControl?.view as? NSButton)?.identifier?.rawValue == "tab.close",
                    "close-tab control carries a stable identifier")
            }
            // The delegate installed here is deliberately left in place for every later section:
            // NSApp.delegate is weak, and the tab, status and navigation paths checked below reach
            // the application delegate. It is declared at this level so that it stays alive.
            let sessionDelegate = AppDelegate()
            app.delegate = sessionDelegate
            section("session restore and crash recovery") {
                let snapshotText = "\u{FEFF}café😀\n2 eggs\0"
                let snapshot = SessionDocument(
                    id: UUID(), originalURL: saved, text: snapshotText,
                    format: FileFormat(encoding: .utf16LE, bom: true), isDirty: true,
                    selection: SessionSelection(anchorByte: snapshotText.utf8.count, caretByte: 3), bookmarks: [1],
                    language: "python", originalSHA256: WorkspaceStore.fingerprint(try Data(contentsOf: saved)))
                let session = WorkspaceSession(
                    id: UUID(), name: "Native session regression", documents: [snapshot], activeDocumentID: snapshot.id)
                if !FileManager.default.fileExists(atPath: saved.path) {
                    try Data("locked reload".utf8).write(to: saved)
                }
                let originalBytes = try Data(contentsOf: saved)
                let restored = try WorkspaceController().restore(session)
                check(
                    restored.count == 1 && restored[0].editor.text == snapshotText,
                    "session restores Unicode FEFF NUL snapshot into native editor")
                check(
                    restored[0].fileURL == nil && restored[0].isDocumentEdited,
                    "session snapshot is unsaved and detached from original")
                check(try Data(contentsOf: saved) == originalBytes, "session restore never overwrites original file")
                check(
                    restored[0].editor.selectionAnchor == snapshotText.utf8.count
                        && restored[0].editor.selectionCaret == 3, "session restores reversed byte selection")
                check(restored[0].editor.bookmarkLines.map(\.intValue) == [1], "session restores bookmark lines")
                check(
                    restored[0].format == snapshot.format && restored[0].languageIdentifier == "python",
                    "session restores encoding and language metadata")
                let recoveredSession = try TextDocument.recovery.loadAll().first { $0.id == restored[0].recoveryID }
                check(recoveredSession?.text == snapshotText, "restored session has durable recovery snapshot")
                let recaptured = try WorkspaceController().capture(name: "Captured native documents")
                check(
                    recaptured.documents.contains { $0.text == snapshotText && $0.selection == snapshot.selection },
                    "session capture reads authoritative editor selection and contents")
                let printRevision = restored[0].editor.revision
                let printOperation = try restored[0].printOperation(withSettings: [:])
                check(
                    (printOperation.view as? NSTextView)?.string == snapshotText,
                    "native print view contains exact authoritative Unicode text")
                check(
                    restored[0].editor.revision == printRevision && restored[0].isDocumentEdited,
                    "preparing print does not change editor or dirty state")
                let emptySnapshot = SessionDocument(
                    id: UUID(), text: "", format: FileFormat(encoding: .utf8, bom: false), isDirty: true,
                    selection: SessionSelection(anchorByte: 0, caretByte: 0))
                let emptySession = WorkspaceSession(
                    id: UUID(), name: "Empty restored document", documents: [emptySnapshot])
                let emptyRestored = try WorkspaceController().restore(emptySession)
                let emptyRecovery = try TextDocument.recovery.loadAll().first { $0.id == emptyRestored[0].recoveryID }
                check(
                    emptyRestored[0].isDocumentEdited && emptyRecovery?.text == "",
                    "empty dirty session restoration retains a recovery snapshot")
                emptyRestored[0].editor.replaceSelection("x")
                emptyRestored[0].editor.executeCommand("undo")
                check(
                    emptyRestored[0].editor.text.isEmpty && emptyRestored[0].isDocumentEdited,
                    "type-then-undo cannot make an empty restored document clean")
                emptyRestored.forEach { $0.close() }
                // F125: default-format UTF-8 is the case the UTF-16 fixture above cannot expose.
                let plainText = "first line\nsecond 😀"
                let plainSnapshot = SessionDocument(
                    id: UUID(), text: plainText, format: FileFormat(encoding: .utf8, bom: false), isDirty: true,
                    selection: SessionSelection(anchorByte: 0, caretByte: 0))
                let plain = try WorkspaceController().restore(
                    WorkspaceSession(id: UUID(), name: "Plain UTF-8 restored document", documents: [plainSnapshot]))[0]
                plain.editor.executeCommand("undo")
                plain.flushRecovery()
                check(
                    plain.editor.text == plainText && plain.isDocumentEdited,
                    "Undo cannot empty a restored session document or mark it clean")
                check(
                    try TextDocument.recovery.load(id: plain.recoveryID).text == plainText,
                    "Undo after session restore keeps the recovery snapshot")
                plain.editor.replaceSelection("x")
                plain.editor.executeCommand("undo")
                plain.flushRecovery()
                check(
                    plain.editor.text == plainText && !plain.editor.modified && plain.isDocumentEdited,
                    "restored document stays edited at the engine save point")
                check(
                    try TextDocument.recovery.load(id: plain.recoveryID).text == plainText,
                    "edit-then-undo keeps the restored document's recovery snapshot")
                let plainURL = root.appendingPathComponent("restored-then-saved.txt")
                try plain.writeSafely(to: plainURL, ofType: "Plain Text", for: .saveAsOperation)
                check(
                    try Data(contentsOf: plainURL) == Data(plainText.utf8) && !plain.isDocumentEdited,
                    "real Save clears a restored document's edited state")
                check(
                    try !TextDocument.recovery.loadAll().contains { $0.id == plain.recoveryID },
                    "real Save removes the restored document's recovery snapshot")
                plain.close()
                let crashedID = UUID(), crashedText = "recovered\r\nwork 😀"
                try TextDocument.recovery.save(
                    RecoverySnapshot(
                        id: crashedID, text: crashedText, format: FileFormat(), originalURL: saved.absoluteString,
                        revision: 7))
                let recovered = try TextDocument.openRecovered(try TextDocument.recovery.load(id: crashedID))
                check(
                    recovered.recoveryID == crashedID && recovered.editor.text == crashedText
                        && recovered.fileURL == nil && recovered.isDocumentEdited,
                    "crash recovery opens the snapshot as a new unsaved document")
                check(
                    recovered.editor.statusInfo["eol"]?.intValue == 0, "recovered document inserts its own line ending")
                recovered.automaticRecoveryDelay = 0.02
                recovered.maximumRecoveryDelay = 0.02
                recovered.editor.executeCommand("undo")
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                recovered.flushRecovery()
                check(
                    recovered.editor.text == crashedText && recovered.isDocumentEdited,
                    "one Undo cannot empty a recovered document or mark it clean")
                let rewritten = try TextDocument.recovery.load(id: crashedID)
                check(
                    rewritten.text == crashedText && rewritten.revision > 7,
                    "Undo after recovery keeps the only on-disk copy")
                recovered.editor.replaceSelection("x")
                recovered.editor.executeCommand("undo")
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                recovered.flushRecovery()
                check(
                    try recovered.isDocumentEdited && TextDocument.recovery.load(id: crashedID).text == crashedText,
                    "edit-then-undo keeps the recovered document edited and its snapshot on disk")
                check(try Data(contentsOf: saved) == originalBytes, "recovery never writes the original file")
                recovered.close()
                check(
                    try !TextDocument.recovery.loadAll().contains { $0.id == crashedID },
                    "closing a recovered document discards its snapshot")
                rejects("recovery revision overflow rejected before opening", expecting: RecoveryError.invalidSnapshot)
                {
                    _ = try TextDocument.openRecovered(
                        RecoverySnapshot(
                            id: UUID(), text: "x", format: FileFormat(), originalURL: nil, revision: UInt64.max))
                }
                restored.forEach { $0.close() }
            }
            section("compact tabs") {
                let tabA = TextDocument(), tabB = TextDocument()
                for doc in [tabA, tabB] {
                    NSDocumentController.shared.addDocument(doc)
                    doc.makeWindowControllers()
                    doc.showWindows()
                }
                let winA = tabA.windowControllers[0].window!, winB = tabB.windowControllers[0].window!
                check(!winA.isVisible && winB.isVisible, "only selected compact tab is visible")
                winB.setFrame(NSRect(x: 150, y: 150, width: 900, height: 650), display: true)
                winA.makeKeyAndOrderFront(nil)
                check(winA.isVisible && !winB.isVisible, "switching tabs changes visible document")
                if !NSScreen.screens.isEmpty {
                    print("TAB_GEOMETRY", winA.frame, winB.frame)
                    fflush(stdout)
                    check(winA.frame == winB.frame, "switching tabs preserves window geometry")
                } else {
                    print("SKIP window geometry: no screen in native test process")
                }
                let tabsController = tabA.windowControllers[0] as! EditorWindowController
                tabsController.refreshStatusDetails()
                let buttons = descendants(winA.contentView!).compactMap { $0 as? NSButton }
                let closeB = buttons.first { $0.toolTip == "Close \(winB.title)" }!
                let plus = buttons.first { $0.identifier?.rawValue == "tab.new" }!
                check(plus.frame.minX < 500, "new-tab button follows compact tabs rather than window edge")
                check(winA.tabbingMode == .disallowed, "native full-width tab strip disabled")
                let heldFrame = winA.frame
                tabA.close()
                check(winB.isVisible, "closing active tab reveals next")
                if !NSScreen.screens.isEmpty {
                    check(winB.frame == heldFrame, "closing active tab preserves window geometry")
                }
                tabB.close()
                let remaining = NSDocumentController.shared.documents.count
                closeB.performClick(nil)
                check(
                    NSDocumentController.shared.documents.count == remaining,
                    "stale tab close cannot retarget another document")
            }
            section("save baseline under concurrent change") {
                // Save baseline must describe our submitted bytes, even if an external
                // noncooperating writer changes the destination immediately after save.
                let raceURL = root.appendingPathComponent("post-save-race.txt")
                try Data("original".utf8).write(to: raceURL)
                let race = TextDocument()
                race.fileURL = raceURL
                try race.read(from: Data("original".utf8), ofType: "Plain Text")
                race.editor.text = "our save"
                race.afterWriteForTesting = { try Data("external edit".utf8).write(to: raceURL) }
                try race.writeSafely(to: raceURL, ofType: "Plain Text", for: .saveOperation)
                check(try race.diskState() == .changed, "post-save external writer cannot become acknowledged baseline")
                race.afterWriteForTesting = nil
                race.editor.text = "our second save"
                rejects("later save rejects post-save external edit", message: "The file changed outside TextTank") {
                    try race.writeSafely(to: raceURL, ofType: "Plain Text", for: .saveOperation)
                }
                check(
                    try String(contentsOf: raceURL, encoding: .utf8) == "external edit",
                    "conflict rejection preserves external bytes")
                race.close()
                let changed = TextDocument(), changedURL = root.appendingPathComponent("during-save.txt")
                changed.fileURL = changedURL
                try changed.read(from: Data("old".utf8), ofType: "Plain Text")
                try Data("old".utf8).write(to: changedURL)
                changed.editor.text = "submitted"
                changed.format = FileFormat(encoding: .utf16LE, bom: true)
                changed.afterWriteForTesting = {
                    changed.format = FileFormat(encoding: .utf8, bom: false)
                    changed.editor.executeCommand("undo")
                }
                try changed.writeSafely(to: changedURL, ofType: "Plain Text", for: .saveOperation)
                check(
                    changed.isDocumentEdited && changed.format.encoding == .utf8,
                    "change during Save retains newer format and dirty state")
                changed.editor.replaceSelection("x")
                changed.editor.executeCommand("undo")
                check(changed.isDocumentEdited, "old engine savepoint cannot clear dirty state after stale save")
                check(
                    try FileCodec.decode(Data(contentsOf: changedURL)).text == "submitted",
                    "Save writes captured text despite later editor changes")
                changed.afterWriteForTesting = nil
                changed.close()

            }
            section("recovery timing and failure reporting") {
                let recoveryDoc = TextDocument()
                recoveryDoc.automaticRecoveryDelay = 0.25
                recoveryDoc.maximumRecoveryDelay = 0.08
                let deadline = Date().addingTimeInterval(0.24)
                while Date() < deadline {
                    recoveryDoc.editor.text += "x"
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                // The maximum-delay timer has already fired during the edits; only the background write
                // can still be in flight. Wait for the file without servicing the run loop, so that the
                // quiet-interval timer cannot fire and satisfy this check in its place.
                var written: RecoverySnapshot?
                let writeDeadline = Date().addingTimeInterval(10)
                while written == nil && Date() < writeDeadline {
                    written = try? TextDocument.recovery.load(id: recoveryDoc.recoveryID)
                    if written == nil { usleep(5000) }
                }
                let liveSnapshot = try requireValue(
                    written, "timed out after 10 s waiting for the bounded recovery snapshot to be written")
                check(
                    !liveSnapshot.text.isEmpty && liveSnapshot.text.count <= recoveryDoc.editor.text.count,
                    "continuous edits receive bounded recovery before quiet interval")
                recoveryDoc.close()
                check(
                    try !TextDocument.recovery.scan().snapshots.contains { $0.id == recoveryDoc.recoveryID },
                    "close drains queued recovery before removing discarded snapshot")
                // F119: the recovery timers must fire while only a modal or tracking run-loop mode is serviced.
                for (mode, label) in [
                    (RunLoop.Mode.modalPanel, "modal"), (RunLoop.Mode.eventTracking, "event-tracking")
                ] {
                    let modalDoc = TextDocument()
                    modalDoc.automaticRecoveryDelay = 0.05
                    modalDoc.maximumRecoveryDelay = 0.05
                    modalDoc.editor.text = "typed just before a \(label) loop"
                    let modalDeadline = Date().addingTimeInterval(1)
                    var modalSnapshot: RecoverySnapshot?
                    while Date() < modalDeadline && modalSnapshot == nil {
                        _ = RunLoop.current.run(mode: mode, before: Date().addingTimeInterval(0.02))
                        usleep(5000)
                        modalSnapshot = try? TextDocument.recovery.load(id: modalDoc.recoveryID)
                    }
                    check(
                        modalSnapshot?.text == "typed just before a \(label) loop",
                        "recovery snapshot is written while a \(label) run-loop mode is active")
                    modalDoc.close()
                    check(
                        try !TextDocument.recovery.scan().snapshots.contains { $0.id == modalDoc.recoveryID },
                        "closing after a \(label)-mode snapshot removes it")
                }
                // F202: a metadata-only change is a new snapshot revision, not a spurious failure.
                let meta = TextDocument()
                meta.editor.text = "metadata"
                meta.flushRecovery()
                check(
                    try TextDocument.recovery.load(id: meta.recoveryID).format
                        == FileFormat(encoding: .utf8, bom: false) && meta.lastRecoveryError == nil,
                    "fixture: dirty document has a flushed snapshot")
                meta.format = FileFormat(encoding: .utf16BE, bom: true)
                meta.flushRecovery()
                check(
                    try TextDocument.recovery.load(id: meta.recoveryID).format == meta.format
                        && meta.lastRecoveryError == nil,
                    "format change without a text edit rewrites the snapshot without a failure")
                let movedURL = root.appendingPathComponent("moved-while-dirty.txt")
                meta.fileURL = movedURL
                meta.flushRecovery()
                check(
                    try TextDocument.recovery.load(id: meta.recoveryID).originalURL == movedURL.absoluteString
                        && meta.lastRecoveryError == nil,
                    "file location change without a text edit rewrites the snapshot without a failure")
                meta.close()
                // F202: failures are sticky and distinct in the status line, escalate once, and reset on success.
                var notices = 0
                defer {
                    TextDocument.recoveryFailureNoticeForTesting = nil
                    TextDocument.recoveryFailureNoticeShown = false
                }
                TextDocument.recoveryFailureNoticeShown = false
                TextDocument.recoveryFailureNoticeForTesting = { _, _ in notices += 1 }
                let failing = TextDocument()
                NSDocumentController.shared.addDocument(failing)
                failing.makeWindowControllers()
                let failingStatus = (failing.windowControllers[0] as! EditorWindowController).status
                let failingFile = TextDocument.recovery.fileURL(for: failing.recoveryID),
                    corruptSnapshot = Data("{corrupt".utf8)
                failing.editor.text = "a"
                failing.flushRecovery()
                check(
                    failing.lastRecoveryError == nil && failingStatus.textColor == .secondaryLabelColor
                        && failingStatus.toolTip == nil, "successful recovery write shows the ordinary status")
                try corruptSnapshot.write(to: failingFile)
                failing.editor.text = "ab"
                failing.flushRecovery()
                check(
                    failing.lastRecoveryError != nil && failingStatus.stringValue.hasPrefix("Recovery failed:")
                        && failingStatus.textColor == .systemRed && failingStatus.toolTip?.isEmpty == false,
                    "failed recovery write is visibly distinct in the status line")
                check(notices == 0, "one recovery failure does not raise a notice")
                failing.editor.text = "abc"
                failing.flushRecovery()
                check(notices == 1, "second consecutive recovery failure raises one notice")
                failing.editor.text = "abcd"
                failing.flushRecovery()
                check(
                    notices == 1 && failingStatus.textColor == .systemRed,
                    "further failures stay in the status line without another notice")
                check(
                    try Data(contentsOf: failingFile) == corruptSnapshot,
                    "failed recovery writes never overwrite the unreadable snapshot")
                try FileManager.default.removeItem(at: failingFile)
                failing.editor.text = "abcde"
                failing.flushRecovery()
                check(
                    try failing.lastRecoveryError == nil && failingStatus.textColor == .secondaryLabelColor
                        && failingStatus.toolTip == nil
                        && TextDocument.recovery.load(id: failing.recoveryID).text == "abcde",
                    "next successful recovery write clears the failure state")
                // F202: a failed cleanup at close is recorded, never blocks, and leaves the file for the next launch's review.
                try corruptSnapshot.write(to: failingFile)
                failing.close()
                check(
                    !NSDocumentController.shared.documents.contains(failing) && failing.lastRecoveryError != nil,
                    "close returns and releases the document when snapshot cleanup fails")
                check(
                    try Data(contentsOf: failingFile) == corruptSnapshot
                        && TextDocument.recovery.scan().issues.contains {
                            $0.url.lastPathComponent == failingFile.lastPathComponent
                        }, "snapshot that could not be removed stays listed for review")
                check(
                    AppDelegate.recoveryIssueText(try TextDocument.recovery.scan().issues).contains(failingFile.path),
                    "recovery review lists the full path of each file")
                try FileManager.default.removeItem(at: failingFile)
                TextDocument.recoveryFailureNoticeForTesting = nil
                TextDocument.recoveryFailureNoticeShown = false
            }
            section("explicit encoding choice") {
                // G353: a UTF-16 LE file TextTank wrote with a leading NUL can be reopened by explicit choice.
                let nulURL = root.appendingPathComponent("leading-nul-utf16.txt"),
                    nulFormat = FileFormat(encoding: .utf16LE, bom: true)
                let nulDoc = TextDocument()
                nulDoc.editor.text = "\0hello"
                nulDoc.format = nulFormat
                try nulDoc.writeSafely(to: nulURL, ofType: "Plain Text", for: .saveAsOperation)
                let nulBytes = try Data(contentsOf: nulURL)
                check(
                    nulBytes == (try FileCodec.encode("\0hello", format: nulFormat))
                        && nulBytes.starts(with: [0xFF, 0xFE, 0, 0]),
                    "leading-NUL UTF-16 LE save is neither refused nor altered")
                nulDoc.close()
                let plainRead = TextDocument()
                rejects(
                    "automatic detection still rejects an apparent UTF-32 signature",
                    where: {
                        if case FileCodecError.unsupportedUTF32 = $0 { return true }
                        return false
                    }
                ) { try plainRead.read(from: nulBytes, ofType: "Plain Text") }
                var openFailure: NSError?
                do { try plainRead.read(from: nulURL, ofType: "Plain Text") } catch { openFailure = error as NSError }
                plainRead.close()
                let opener = try requireValue(
                    openFailure?.recoveryAttempter as? ExplicitEncodingOpener,
                    "opening the file offers an explicit UTF-16 LE choice (got \(String(describing:openFailure)))")
                check(
                    openFailure?.localizedRecoveryOptions == ["Open as UTF-16 LE", "Cancel"]
                        && opener.encoding == .utf16LE && opener.url == nulURL,
                    "open failure offers an explicit UTF-16 LE choice")
                check(
                    !opener.attemptRecovery(fromError: openFailure!, optionIndex: 1)
                        && NSDocumentController.shared.document(for: nulURL) == nil,
                    "declining the explicit encoding opens nothing")
                let reopened = try opener.open(display: false)
                check(
                    reopened.editor.text == "\0hello" && reopened.format == nulFormat && reopened.fileURL == nulURL
                        && !reopened.isDocumentEdited, "explicit UTF-16 LE open restores the exact text and format")
                check(
                    try reopened.diskState() == .unchanged && reopened.data(ofType: "Plain Text") == nulBytes,
                    "explicitly opened file has an exact save baseline")
                reopened.editor.text = "\0hello again"
                try reopened.writeSafely(to: nulURL, ofType: "Plain Text", for: .saveOperation)
                check(
                    try Data(contentsOf: nulURL) == (try FileCodec.encode("\0hello again", format: nulFormat))
                        && !reopened.isDocumentEdited, "explicitly opened file saves back byte-exactly")
                reopened.editor.replaceSelection("unsaved")
                var revertFailure: NSError?
                do { try reopened.revert(toContentsOf: nulURL, ofType: "Plain Text") } catch {
                    revertFailure = error as NSError
                }
                let reverter = try requireValue(
                    revertFailure?.recoveryAttempter as? ExplicitEncodingOpener,
                    "revert offers the explicit UTF-16 LE choice")
                check(reopened.isDocumentEdited, "failed automatic revert keeps the edited buffer")
                check(
                    try reverter.open(display: false) === reopened && reopened.editor.text == "\0hello again"
                        && !reopened.isDocumentEdited, "explicit choice completes the revert on the open document")
                reopened.close()
                let bigEndianURL = root.appendingPathComponent("utf32-be-signature.bin")
                try Data([0, 0, 0xFE, 0xFF, 0, 0, 0, 0x41]).write(to: bigEndianURL)
                let bigEndian = TextDocument()
                var bigEndianFailure: NSError?
                do { try bigEndian.read(from: bigEndianURL, ofType: "Plain Text") } catch {
                    bigEndianFailure = error as NSError
                }
                check(
                    bigEndianFailure != nil && bigEndianFailure?.recoveryAttempter == nil,
                    "UTF-32 BE signature is rejected without an encoding offer")
                bigEndian.close()
                // G353 (b): a BOM-less UTF-16 reload keeps the file BOM-less on save, by the exact-bytes contract.
                let bomlessURL = root.appendingPathComponent("bomless-utf16.txt"),
                    bomlessFormat = FileFormat(encoding: .utf16LE, bom: false)
                let bomlessBytes = try FileCodec.encode("hi", format: bomlessFormat)
                try bomlessBytes.write(to: bomlessURL)
                let bomless = TextDocument()
                bomless.fileURL = bomlessURL
                try bomless.read(from: bomlessBytes, ofType: "Plain Text")
                try bomless.reload(using: .utf16LE)
                check(
                    bomless.editor.text == "hi" && bomless.format == bomlessFormat,
                    "BOM-less UTF-16 LE reload keeps the format BOM-less")
                bomless.editor.text = "hi!"
                try bomless.writeSafely(to: bomlessURL, ofType: "Plain Text", for: .saveOperation)
                check(
                    try Data(contentsOf: bomlessURL) == (try FileCodec.encode("hi!", format: bomlessFormat)),
                    "saving after a BOM-less UTF-16 reload adds no BOM")
                bomless.close()

            }
            section("status refresh and tab navigation") {
                let first = TextDocument(), second = TextDocument()
                for doc in [first, second] {
                    NSDocumentController.shared.addDocument(doc)
                    doc.makeWindowControllers()
                    doc.showWindows()
                }
                let firstController = first.windowControllers[0] as! EditorWindowController
                let secondController = second.windowControllers[0] as! EditorWindowController
                // Wait for the visible tab's recurring refresh to run twice, which proves the 0.2 s
                // timers fired in this interval, and only then require that the hidden tab did nothing.
                let hiddenRefreshes = firstController.statusRefreshCount,
                    visibleRefreshes = secondController.statusRefreshCount
                spinUntil("two recurring status refreshes of the visible tab") {
                    secondController.statusRefreshCount >= visibleRefreshes + 2
                }
                check(
                    firstController.statusRefreshCount == hiddenRefreshes,
                    "hidden tabs perform no recurring status refresh")
                secondController.refreshStatusDetails()
                let eolBefore = descendants(secondController.window!.contentView!).compactMap { $0 as? NSButton }.first
                { $0.identifier?.rawValue == "status.eol.0" }!
                second.editor.text = "new text"
                secondController.refreshStatusDetails()
                let eolAfter = descendants(secondController.window!.contentView!).compactMap { $0 as? NSButton }.first {
                    $0.identifier?.rawValue == "status.eol.0"
                }!
                check(eolBefore === eolAfter, "unrelated status changes retain existing control identity")
                check(eolAfter.title == "LF", "the line-ending badge found by identifier shows the document's ending")
                let navigation = AppDelegate()
                navigation.previousDocumentTab(nil)
                check(
                    firstController.window!.isVisible && !secondController.window!.isVisible,
                    "previous-tab command selects hidden document")
                let sameA = NSWindow(), sameB = NSWindow()
                sameA.title = "same.txt"
                sameB.title = "same.txt"
                let choices = navigation.documentTabChoices([sameA, sameB])
                check(
                    choices.numberOfItems == 2 && choices.itemArray.map(\.tag) == [0, 1],
                    "document chooser preserves same-title document identities")
                navigation.nextDocumentTab(nil)
                check(
                    secondController.window!.isVisible && !firstController.window!.isVisible,
                    "next-tab command restores document visibility")
                first.close()
                second.close()
            }
            pinning(root: root, app: app, sessionDelegate: sessionDelegate) { name, line, body in
                section(name, line: line, body)
            }
            section("clean quit") {
                let termination = AppDelegate().applicationShouldTerminate(app)
                check(termination == .terminateNow, "clean application quit does not wait for async reply")
                check(NSDocumentController.shared.documents.isEmpty, "clean quit leaves no owned documents")
            }
            withExtendedLifetime(sessionDelegate) {}
            Checks.summary {
                "PASS DocumentChecks: \(Checks.count) assertions; native AppKit/Scintilla and isolated scratch files"
            }
        }
    }
}
