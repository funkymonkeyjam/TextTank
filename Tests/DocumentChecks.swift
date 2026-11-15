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
            // F148: there is no bundle here, so the suite names the bundled language catalog itself.
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankDocumentChecks-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            setenv("TEXTTANK_SUPPORT_DIRECTORY", root.appendingPathComponent("support").path, 1)
            defer { try? FileManager.default.removeItem(at: root) }
            // As in the app: the first document controller created becomes the shared one.
            let documentController = TextDocumentController()
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
                // Audit package 22 (F231): the byte-scanning, keyed implementation must give the
                // same bytes as the per-character one it replaced, which is kept as the reference.
                check(
                    EditorTransform.sortAscending.transform("b\r\na\rc\nA") == "A\r\na\rb\nc",
                    "sorting keeps CRLF, CR and LF separators in their positions")
                check(
                    EditorTransform.sortCaseInsensitive.transform("b\r\nA\na\rB") == "A\r\na\nb\rB",
                    "case-insensitive sorting is stable for rows that differ only in case")
                check(
                    EditorTransform.sortLength.transform("ccc\r\ne\u{301}\n\u{1F469}\u{1F3FD}\rbb\n")
                        == "e\u{301}\r\n\u{1F469}\u{1F3FD}\nbb\rccc\n",
                    "sorting by length counts characters, not bytes, and is stable")
                check(
                    EditorTransform.reverseLines.transform("1\r\n2\r3\n\n") == "\r\n3\r2\n1\n",
                    "reversing keeps mixed separators in place and treats an empty row as a row")
                check(
                    EditorTransform.trimLeading.transform(" \t a \r\n\t\tb\r \n") == "a \r\nb\r\n",
                    "leading trim keeps trailing whitespace and every separator")
                check(
                    EditorTransform.removeEmptyLines.transform("\r\na\r\r\n\nb\n\r") == "a\rb\n",
                    "removing empty rows keeps the separators of the rows that remain")
                check(
                    EditorTransform.uniqueLines.transform("a\r\na\ra\n") == "a\r\n",
                    "duplicate removal compares content, not separators")
                var transformState: UInt64 = 0x9E37_79B9_7F4A_7C15
                func transformDraw() -> Int {
                    transformState ^= transformState << 13
                    transformState ^= transformState >> 7
                    transformState ^= transformState << 17
                    return Int(transformState >> 33)
                }
                let pieces = [
                    "a", "B", "b", "A", " ", "  ", "\t", "\n", "\r", "\r\n", "\n", "\r\n", "", "e\u{301}", "\u{E9}",
                    "\u{301}", "\u{1F469}\u{1F3FD}", "\u{2028}", "\u{85}", "\0", "zz", "Z", "\u{DF}", "ss", "\u{FEFF}",
                    "\u{200D}", " \u{301}", "10", "9"
                ]
                let lineTransforms: [EditorTransform] = [
                    .sortAscending, .sortDescending, .sortCaseInsensitive, .sortLength, .reverseLines, .uniqueLines,
                    .removeEmptyLines, .trimLeading, .trimBoth
                ]
                var transformMismatches: [String] = []
                for _ in 0..<1500 {
                    var input = ""
                    for _ in 0..<(transformDraw() % 14) { input += pieces[transformDraw() % pieces.count] }
                    for transform in lineTransforms {
                        let expected = referenceLineTransform(transform, input), actual = transform.transform(input)
                        if !actual.utf8.elementsEqual(expected.utf8) && transformMismatches.count < 5 {
                            transformMismatches.append(
                                "\(transform.rawValue) \(input.debugDescription): \(actual.debugDescription) is not \(expected.debugDescription)"
                            )
                        }
                    }
                }
                check(
                    transformMismatches.isEmpty,
                    "1500 pseudo-random inputs give the reference bytes for every line transform \(transformMismatches)"
                )
                // Invert Case takes ASCII without a property lookup; every ASCII scalar must come out
                // as the Unicode case mapping gives it.
                let ascii = String(String.UnicodeScalarView((0..<128).map { Unicode.Scalar(UInt8($0)) }))
                let asciiByProperties = String(
                    String.UnicodeScalarView(
                        ascii.unicodeScalars.map { scalar -> Unicode.Scalar in
                            let original = String(scalar), upper = scalar.properties.uppercaseMapping
                            let mapped = upper == original ? scalar.properties.lowercaseMapping : upper
                            return mapped.unicodeScalars.first!
                        }))
                check(
                    EditorTransform.invertCase.transform(ascii + "\u{E9}\u{DF}Z" + ascii) == asciiByProperties
                        + "\u{C9}\u{DF}z" + asciiByProperties,
                    "Invert Case maps all 128 ASCII scalars as the Unicode case mapping does, around non-ASCII text")
                // Quadratic before: each removed character shifted the rest of the row.
                let indentedRow = String(repeating: " ", count: 300_000) + "x\n"
                let trimStarted = ProcessInfo.processInfo.systemUptime
                let trimmedRow = EditorTransform.trimLeading.transform(indentedRow)
                let trimSeconds = ProcessInfo.processInfo.systemUptime - trimStarted
                let budgetScale =
                    max(1, Double(ProcessInfo.processInfo.environment["TEXTTANK_PERF_BUDGET_SCALE"] ?? "") ?? 1)
                print("TRANSFORM_TIMING trimLeading 300000 leading spaces \(trimSeconds) s")
                check(
                    trimmedRow == "x\n" && trimSeconds <= 0.25 * budgetScale,
                    "trimming a row of 300,000 leading spaces is linear (within 0.25 s)")
                let manyRows = (0..<60_000).map { "row \(($0 * 7919) % 60_000) Mixed Case text" }.joined(
                    separator: "\n")
                let sortStarted = ProcessInfo.processInfo.systemUptime
                let byCase = EditorTransform.sortCaseInsensitive.transform(manyRows)
                let byLength = EditorTransform.sortLength.transform(manyRows)
                let sortSeconds = ProcessInfo.processInfo.systemUptime - sortStarted
                print("TRANSFORM_TIMING sortCaseInsensitive and sortLength of 60000 rows \(sortSeconds) s")
                check(
                    byCase.utf8.count == manyRows.utf8.count && byLength.utf8.count == manyRows.utf8.count
                        && byCase.hasPrefix("row 0 Mixed Case text\nrow 1 Mixed"),
                    "keyed sorts of 60,000 rows keep every byte")
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
                    controller.focusObservation == nil && controller.automationObserver == nil
                        && document.editor.onFocus == nil,
                    "close removes callbacks before document detaches")
                check(
                    controller.activeEditor === document.editor,
                    "late retained controller access does not force-cast detached document")
                check(window.standardWindowButton(.closeButton)?.isHidden == false, "native close control is visible")
                // The toolbar no longer repeats the tab's own close button.
                check(
                    !controller.toolbarDefaultItemIdentifiers(NSToolbar(identifier: "test")).contains {
                        $0.rawValue == "TextTank.CloseTab"
                    }, "the toolbar has no Close Tab item; each tab closes from its own button or Command-W")
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
            section("disk baseline is a digest, with metadata as a shortcut only when it is safe") {
                // F227: no second copy of the file; metadata stands in for the hash only once settled.
                let baselineURL = root.appendingPathComponent("baseline.txt")
                let baselineBytes = Data("baseline bytes \u{1F98B}\n".utf8)
                try baselineBytes.write(to: baselineURL)
                let kept = TextDocument()
                kept.fileURL = baselineURL
                try kept.read(from: baselineURL, ofType: "Plain Text")
                func retainsFileBytes(_ document: TextDocument) -> Bool {
                    var mirror: Mirror? = Mirror(reflecting: document)
                    while let current = mirror {
                        if current.children.contains(where: { !(($0.value as? Data)?.isEmpty ?? true) }) { return true }
                        mirror = current.superclassMirror
                    }
                    return false
                }
                check(!retainsFileBytes(kept), "an open document keeps no copy of its file's bytes")
                check(
                    kept.originalDiskFingerprint == WorkspaceStore.fingerprint(baselineBytes),
                    "the session fingerprint is still the SHA-256 of the bytes read")
                check(
                    try !kept.hasSettledDiskSignature && kept.diskState() == .unchanged
                        && !kept.hasSettledDiskSignature,
                    "a file written a moment ago is always hashed, never trusted by its metadata")
                spinUntil("the file's timestamps to settle") {
                    try WorkspaceStore.sample(ofRegularFileAt: baselineURL).signature != nil
                }
                check(
                    try kept.diskState() == .unchanged && kept.hasSettledDiskSignature,
                    "an explicit check that hashed a settled file records its metadata")
                let settledOpen = TextDocument()
                settledOpen.fileURL = baselineURL
                try settledOpen.read(from: baselineURL, ofType: "Plain Text")
                check(
                    settledOpen.hasSettledDiskSignature && settledOpen.editor.text == "baseline bytes \u{1F98B}\n",
                    "opening a settled file records the metadata of the bytes read")
                try settledOpen.reload(using: .utf8)
                check(settledOpen.hasSettledDiskSignature, "reload records the metadata of the bytes it read")
                settledOpen.close()
                // Same size, same inode, modification time put back: only the change time and the bytes differ.
                var statBefore = stat()
                try require(stat(baselineURL.path, &statBefore) == 0, "fixture: stat the baseline file")
                var rewritten = baselineBytes
                rewritten[0] = UInt8(ascii: "B")
                let rewriter = try FileHandle(forWritingTo: baselineURL)
                try rewriter.write(contentsOf: rewritten)
                try rewriter.close()
                try require(
                    utimensat(AT_FDCWD, baselineURL.path, [statBefore.st_atimespec, statBefore.st_mtimespec], 0) == 0,
                    "fixture: put the modification time back")
                var statAfter = stat()
                try require(stat(baselineURL.path, &statAfter) == 0, "fixture: stat the rewritten file")
                fixtureCheck(
                    statAfter.st_size == statBefore.st_size && statAfter.st_ino == statBefore.st_ino
                        && statAfter.st_mtimespec.tv_sec == statBefore.st_mtimespec.tv_sec
                        && statAfter.st_mtimespec.tv_nsec == statBefore.st_mtimespec.tv_nsec,
                    "the rewrite kept size, inode and the exact modification time")
                kept.editor.text = "our edit"
                rejects(
                    "save refuses a same-size rewrite whose modification time was put back",
                    message: "The file changed outside TextTank"
                ) { try kept.writeSafely(to: baselineURL, ofType: "Plain Text", for: .saveOperation) }
                check(
                    try Data(contentsOf: baselineURL) == rewritten && kept.editor.text == "our edit",
                    "the refused save leaves the external bytes and the edit alone")
                check(try kept.diskState() == .changed, "the explicit check reports the same rewrite as changed")
                try baselineBytes.write(to: baselineURL, options: .atomic)
                try kept.writeSafely(to: baselineURL, ofType: "Plain Text", for: .saveOperation)
                check(
                    try Data(contentsOf: baselineURL) == Data("our edit".utf8) && !kept.hasSettledDiskSignature
                        && !retainsFileBytes(kept)
                        && kept.originalDiskFingerprint == WorkspaceStore.fingerprint(Data("our edit".utf8)),
                    "a save over an atomically restored file succeeds, and its baseline is the digest of what was submitted"
                )
                try FileManager.default.removeItem(at: baselineURL)
                check(try kept.diskState() == .missing, "a deleted file is reported missing")
                kept.close()
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
                // N1: the save state is truthful at once, before any recovery write.
                check(
                    failing.isDocumentEdited && failingStatus.stringValue.hasPrefix("Edited ·")
                        && !failingStatus.stringValue.contains("Saved"),
                    "an edit reads Edited in the status line immediately, never Saved")
                failing.flushRecovery()
                check(
                    failing.lastRecoveryError == nil && failingStatus.textColor == .secondaryLabelColor
                        && failingStatus.toolTip == nil
                        && failingStatus.stringValue.hasPrefix("Edited — recovery copy kept"),
                    "successful recovery write shows the ordinary status and names the recovery copy")
                try corruptSnapshot.write(to: failingFile)
                failing.editor.text = "ab"
                failing.flushRecovery()
                check(
                    failing.lastRecoveryError != nil
                        && failingStatus.stringValue.hasPrefix("⚠︎ Recovery copy not written:")
                        && failingStatus.textColor == .labelColor && failingStatus.toolTip?.isEmpty == false,
                    "failed recovery write is visibly distinct in the status line")
                check(notices == 0, "one recovery failure does not raise a notice")
                failing.editor.text = "abc"
                check(
                    failingStatus.stringValue.hasPrefix("⚠︎ Recovery copy not written:"),
                    "a later edit does not hide a standing recovery failure")
                failing.flushRecovery()
                check(notices == 1, "second consecutive recovery failure raises one notice")
                failing.editor.text = "abcd"
                failing.flushRecovery()
                check(
                    notices == 1 && failingStatus.textColor == .labelColor,
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
            // Audit package 22 (F218, F287): the status bar keeps its timer but copies the document
            // only when it has stopped changing, and follows editor events in between.
            section("status bar follows the editor without per-tick copies") {
                /// The implementation StatusMetrics.scan replaced: a Swift String scan.
                func previousMetrics(_ text: String) -> (Int, String) {
                    let count = text.unicodeScalars.count
                    var cr = false, lf = false, crlf = false, priorCR = false
                    for byte in text.utf8 {
                        if byte == 13 {
                            if priorCR { cr = true }
                            priorCR = true
                        } else {
                            if byte == 10 {
                                if priorCR { crlf = true } else { lf = true }
                            } else if priorCR {
                                cr = true
                            }
                            priorCR = false
                        }
                    }
                    if priorCR { cr = true }
                    let endings = [crlf ? "CRLF" : nil, lf ? "LF" : nil, cr ? "CR" : nil].compactMap { $0 }
                    return (count, endings.count > 1 ? "Mixed EOL" : endings.first ?? "")
                }
                var fixtures = [
                    "", "plain", "a\r\nb\nc\u{1F600}", "one\rtwo\r", "x\r\n", "\r\r\n\n", "\n\r", "\r", "tail\r",
                    "\u{FEFF}bom\0nul\u{10FFFF}", UnicodeFixtures.mixedEndings,
                    UnicodeFixtures.zwjEmoji + UnicodeFixtures.nfd,
                    UnicodeFixtures.nonBreakingSeparators.joined(separator: "x") + UnicodeFixtures.astralLetter
                ]
                let fixtureDirectory = TestPaths.repoRoot.appendingPathComponent("Tests/Fixtures")
                for name in try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path).sorted()
                where name.hasSuffix(".txt") {
                    let text = try FileCodec.decode(Data(contentsOf: fixtureDirectory.appendingPathComponent(name)))
                        .text
                    fixtures.append(text)
                    fixtures.append(text.replacingOccurrences(of: "\n", with: "\r\n") + "\rlast")
                }
                try require(fixtures.count >= 20, "fixture: the repository's text fixtures are present")
                check(
                    fixtures.allSatisfy { StatusMetrics.scan(Data($0.utf8)) == previousMetrics($0) },
                    "the byte scan gives the previous implementation's character count and line endings for \(fixtures.count) fixture documents"
                )
                let hidden = TextDocument(), visible = TextDocument()
                for doc in [hidden, visible] {
                    NSDocumentController.shared.addDocument(doc)
                    doc.makeWindowControllers()
                    doc.showWindows()
                }
                let controller = visible.windowControllers[0] as! EditorWindowController
                let hiddenController = hidden.windowControllers[0] as! EditorWindowController
                let buttons = { descendants(controller.window!.contentView!).compactMap { $0 as? NSButton } }
                let badges = {
                    buttons().filter { $0.identifier?.rawValue.hasPrefix("status.") == true }.map(\.title)
                }
                let badge = { (identifier: String) in buttons().first { $0.identifier?.rawValue == identifier }?.title }
                try require(
                    controller.window!.isVisible && !hiddenController.window!.isVisible,
                    "fixture: one tab on screen, one hidden")
                check(
                    controller.statusTimerActive && !hiddenController.statusTimerActive,
                    "only the tab on screen has a recurring status timer")
                // From here on nothing calls refreshStatusDetails: the timer and editor events do.
                var badgeMismatches: [String] = []
                for fixture in fixtures.prefix(13) {
                    visible.editor.text = fixture
                    let (count, endings) = previousMetrics(fixture)
                    let shown = spinUntil("the badges for \(fixture.debugDescription)") {
                        badges().contains("\(count) chars")
                            && badge("status.eol.0") == (endings.isEmpty ? "LF" : endings)
                    }
                    if !shown { badgeMismatches.append("\(fixture.debugDescription): \(badges())") }
                }
                check(
                    badgeMismatches.isEmpty,
                    "the chars and line-ending badges reach the previous implementation's values with no explicit refresh \(badgeMismatches)"
                )
                visible.editor.text = "a\r\nb\nc\u{1F600}"
                spinUntil("exact character count and Mixed EOL") {
                    badges().contains("7 chars") && badges().contains("Mixed EOL")
                }
                check(
                    badges().contains("7 chars") && badges().contains("Mixed EOL"),
                    "a CRLF and LF document with a non-BMP scalar shows the exact count and Mixed EOL")
                _ = visible.editor.setSelectionAnchor(0, caret: 3)
                spinUntil("the selection badge") { badges().contains("3 selected") }
                check(badges().contains("3 selected"), "a selection-only change shows the selected count")
                _ = visible.editor.setSelectionAnchor(0, caret: 0)
                spinUntil("the selection badge to go") { !badges().contains { $0.hasSuffix("selected") } }
                check(
                    !badges().contains { $0.hasSuffix("selected") },
                    "collapsing the selection removes the selected count")
                _ = visible.editor.setSelectionRanges([["anchor": 0, "caret": 1], ["anchor": 4, "caret": 5]])
                spinUntil("the multi-selection badges") {
                    badges().contains("2 selected") && badges().contains("2 selections")
                }
                _ = visible.editor.setSelectionRanges([["anchor": 0, "caret": 1], ["anchor": 3, "caret": 5]])
                spinUntil("a changed additional selection") { badges().contains("3 selected") }
                check(
                    badges().contains("3 selected") && badges().contains("2 selections"),
                    "changing only an additional selection updates the selected count")
                _ = visible.editor.setSelectionAnchor(0, caret: 0)
                // Earlier sections change the default settings, so wrap may start either way.
                let wrapBadge = controller.activeEditor.wrap ? "No Wrap" : "Wrap"
                controller.toggleWrap(nil)
                visible.editor.executeCommand("bookmarkToggle")
                visible.editor.readOnly = true
                spinUntil("wrap, bookmark and read-only badges") {
                    badges().contains(wrapBadge) && badges().contains("1 Bookmarks") && badges().contains("Read Only")
                }
                check(
                    badges().contains(wrapBadge) && badges().contains("1 Bookmarks") && badges().contains("Read Only"),
                    "wrap, bookmark and read-only changes reach the badges with no explicit refresh \(badges())")
                visible.editor.readOnly = false
                controller.toggleWrap(nil)
                let hiddenTabTitle = {
                    buttons().first { $0.toolTip == hidden.windowControllers[0].window!.title }?.title
                }
                try require(hiddenTabTitle()?.hasSuffix("•") == false, "fixture: the hidden tab starts unedited")
                _ = hidden.editor.replaceSelection("edited while hidden")
                spinUntil("the hidden tab's edited marker") { hiddenTabTitle()?.hasSuffix("•") == true }
                check(
                    hiddenTabTitle()?.hasSuffix("•") == true,
                    "editing a hidden document marks its tab in the visible window's tab strip")
                let idleRefreshes = controller.statusRefreshCount, hiddenRefreshes = hiddenController.statusRefreshCount
                spinUntil("idle recurring refreshes") { controller.statusRefreshCount >= idleRefreshes + 2 }
                check(
                    controller.statusRefreshCount >= idleRefreshes + 2
                        && hiddenController.statusRefreshCount == hiddenRefreshes,
                    "the visible tab's safety-net timer keeps running while idle and the hidden tab's does not run")
                // Continuous typing: an edit every 50 ms for a second, across five timer ticks.
                spinUntil("the bar to settle before typing") { badges().contains("7 chars") }
                let captures = controller.statusMetricsCaptureCount
                let typingUntil = Date().addingTimeInterval(1.0)
                var typed = 0
                while Date() < typingUntil {
                    _ = visible.editor.replaceSelection("k")
                    typed += 1
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
                check(
                    typed >= 5 && controller.statusMetricsCaptureCount == captures,
                    "continuous typing starts no whole-document capture (\(typed) edits, \(controller.statusMetricsCaptureCount - captures) captures)"
                )
                spinUntil("the count after typing stops") { badges().contains("\(7 + typed) chars") }
                check(
                    badges().contains("\(7 + typed) chars") && controller.statusMetricsCaptureCount == captures + 1,
                    "one capture after typing stops brings the character count up to date")
                // Minimising takes the window off screen without any order call, and restoring it
                // brings it back the same way.
                controller.window!.miniaturize(nil)
                spinUntil("the minimised window to leave the screen") { !controller.window!.isVisible }
                spinUntil("the minimised tab's timer to stop") { !controller.statusTimerActive }
                check(!controller.statusTimerActive, "a minimised window has no recurring status timer")
                controller.window!.deminiaturize(nil)
                spinUntil("the restored window to be on screen") { controller.window!.isVisible }
                spinUntil(timeout: 3, "the restored tab's timer") { controller.statusTimerActive }
                check(controller.statusTimerActive, "restoring a minimised window restarts its recurring status timer")
                let restoredRefreshes = controller.statusRefreshCount
                spinUntil(timeout: 3, "recurring refreshes after the restore") {
                    controller.statusRefreshCount >= restoredRefreshes + 2
                }
                _ = visible.editor.replaceSelection("mm")
                spinUntil(timeout: 3, "the count after typing in the restored window") {
                    badges().contains("\(9 + typed) chars")
                }
                check(
                    badges().contains("\(9 + typed) chars"),
                    "typing after minimise and restore updates the character count \(badges())")
                // The editor-event path alone also restarts a timer that was lost while on screen.
                controller.stopStatusTimerForChecks()
                _ = visible.editor.replaceSelection("n")
                spinUntil(timeout: 3, "the timer after an editor event") { controller.statusTimerActive }
                check(
                    controller.statusTimerActive,
                    "an editor event in a window on screen restarts a missing status timer")
                hiddenController.window!.makeKeyAndOrderFront(nil)
                check(
                    hiddenController.statusTimerActive && !controller.statusTimerActive,
                    "switching tabs moves the recurring timer to the tab now on screen")
                hidden.close()
                check(
                    !hiddenController.statusTimerActive && controller.statusTimerActive,
                    "closing a tab stops its timer and the tab shown next gets one")
                visible.close()
                check(!controller.statusTimerActive, "a closed tab has no status timer")
            }
            section("recovery while an undo group stays open across run-loop turns") {
                // Interactive macro playback holds one undo group open under a modal panel for
                // the whole playback; the document must still be marked edited and snapshotted.
                let doc = TextDocument()
                doc.automaticRecoveryDelay = 0.05
                doc.maximumRecoveryDelay = 0.2
                try require(!doc.isDocumentEdited, "fixture: the document starts clean")
                doc.editor.beginUndoGroup()
                let playbackUntil = Date().addingTimeInterval(1.0)
                var steps = 0
                // Steps keep arriving faster than the idle delay, as in playback, so only the
                // deadline timer can fire; the loop runs in the modal-panel mode playback uses.
                while Date() < playbackUntil {
                    _ = doc.editor.replaceSelection("step \(steps)\n")
                    steps += 1
                    RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.01))
                }
                let groupOpenText = doc.editor.text
                check(
                    steps >= 5 && doc.isDocumentEdited,
                    "a document edited inside a group held open across run-loop turns is marked edited before the group ends"
                )
                var midGroup: RecoverySnapshot?
                spinUntil(timeout: 3, "the recovery snapshot written during the open group") {
                    midGroup = try? TextDocument.recovery.load(id: doc.recoveryID)
                    return midGroup != nil
                }
                check(
                    midGroup.map { !$0.text.isEmpty && groupOpenText.hasPrefix($0.text) } == true,
                    "the deadline recovery snapshot is written while the group is still open")
                doc.editor.endUndoGroup()
                doc.editor.executeCommand("undo")
                check(doc.editor.text.isEmpty, "the group held open across turns is still one Undo step")
                doc.close()
            }
            section("large-document print warning and pagination") {
                let doc = TextDocument()
                doc.editor.text = (1...400).map { "printed line \($0)" }.joined(separator: "\n")
                var asked: [String] = []
                doc.confirmLargePrint = { message, detail in
                    asked.append(message + "|" + detail)
                    return false
                }
                check(
                    doc.largePrintWarning() == nil && doc.shouldBeginPrinting() && asked.isEmpty,
                    "an ordinary document prints without a size warning")
                let operation = try doc.printOperation(withSettings: [:])
                let pageHeight =
                    operation.printInfo.paperSize.height - operation.printInfo.topMargin
                    - operation.printInfo.bottomMargin
                let printed = operation.view as? NSTextView
                check(
                    printed?.string == doc.editor.text && (printed?.frame.height ?? 0) > 3 * pageHeight
                        && (printed?.frame.height ?? 0) < 12 * pageHeight,
                    "a 400-line document is laid out over several pages with its exact text")
                if let printed, let layout = printed.layoutManager, let container = printed.textContainer {
                    let glyphs = layout.glyphRange(for: container)
                    let lastRect = layout.lineFragmentRect(
                        forGlyphAt: max(0, NSMaxRange(glyphs) - 1), effectiveRange: nil)
                    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                    check(
                        NSMaxRange(characters) == (doc.editor.text as NSString).length
                            && lastRect.maxY <= printed.frame.height + 1 && lastRect.maxY > printed.frame.height - 40,
                        "the last line of the document is on the last printed page")
                }
                let threshold = TextDocument.largePrintBytes
                defer { TextDocument.largePrintBytes = threshold }
                check(threshold == 4 * 1024 * 1024, "the print warning starts at 4 MiB")
                TextDocument.largePrintBytes = doc.editor.byteLength
                let revision = doc.editor.revision
                let warning = doc.largePrintWarning()
                check(
                    warning?.message.contains("large") == true && warning?.detail.contains("not changed") == true,
                    "a document at the threshold gets a warning that says what will happen")
                check(
                    !doc.shouldBeginPrinting() && asked.count == 1,
                    "declining the warning cancels the print before anything is laid out")
                doc.confirmLargePrint = { _, _ in true }
                check(doc.shouldBeginPrinting(), "accepting the warning lets the print go ahead")
                TextDocument.largePrintBytes = doc.editor.byteLength + 1
                check(doc.largePrintWarning() == nil, "a document one byte under the threshold gets no warning")
                check(doc.editor.revision == revision, "the print warning does not touch the document")
                doc.close()
            }
            pinning(root: root, app: app, sessionDelegate: sessionDelegate) { name, line, body in
                section(name, line: line, body)
            }
            openSaveRecovery(root: root, documents: documentController) { name, line, body in
                section(name, line: line, body)
            }
            splitViewAndCurrentEditor(root: root, app: app) { name, line, body in section(name, line: line, body) }
            windowMenuAndKeyboard(root: root, app: app, sessionDelegate: sessionDelegate) { name, line, body in
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

/// The per-character line transforms that EditorTransform.transform replaced (audit package 22,
/// F231), kept only as the reference its output is compared with.
private func referenceLineTransform(_ transform: EditorTransform, _ text: String) -> String {
    var rows: [(String, String)] = []
    var content = ""
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c == "\r\n" || c == "\r" || c == "\n" {
            rows.append((content, String(c)))
            content = ""
        } else {
            content.append(c)
        }
        i = text.index(after: i)
    }
    if !content.isEmpty || rows.isEmpty { rows.append((content, "")) }
    switch transform {
    case .trimLeading, .trimBoth:
        rows = rows.map { row in
            var s = row.0
            while s.first == " " || s.first == "\t" { s.removeFirst() }
            if transform == .trimBoth { while s.last == " " || s.last == "\t" { s.removeLast() } }
            return (s, row.1)
        }
    case .removeEmptyLines: rows = rows.filter { !$0.0.isEmpty }
    case .uniqueLines:
        let unterminated = rows.last?.1.isEmpty == true
        var seen = Set<Data>()
        rows = rows.filter { seen.insert(Data($0.0.utf8)).inserted }
        if unterminated, !rows.isEmpty { rows[rows.count - 1].1 = "" }
    default:
        let values = rows.enumerated().map { ($0.offset, $0.element.0) }
        let sorted: [(Int, String)]
        switch transform {
        case .reverseLines: sorted = Array(values.reversed())
        case .sortDescending: sorted = values.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        case .sortCaseInsensitive:
            sorted = values.sorted {
                let a = $0.1.lowercased(), b = $1.1.lowercased()
                return a == b ? $0.0 < $1.0 : a < b
            }
        case .sortLength:
            sorted = values.sorted { $0.1.count == $1.1.count ? $0.0 < $1.0 : $0.1.count < $1.1.count }
        default: sorted = values.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        }
        rows = zip(sorted, rows).map { ($0.0.1, $0.1.1) }
    }
    return rows.map { $0.0 + $0.1 }.joined()
}
