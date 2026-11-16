import AppKit

#if !TESTING
    @main
    struct TextTankMain {
        static func main() {
            // The first document controller created becomes the shared one, so this comes first.
            let documents = TextDocumentController()
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = AppDelegate()
            app.delegate = delegate
            if NSDocumentController.shared !== documents {
                NSLog("TextTank: the document controller was created early; encoding choice on open is unavailable")
            }
            app.run()
            withExtendedLifetime(delegate) {}
        }
    }

#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var workspace: WorkspaceController = {
        let controller = WorkspaceController()
        controller.activeDocument = { [weak self] in self?.currentDocument }
        return controller
    }()
    lazy var workspaceBrowser: WorkspaceBrowserController = {
        let controller = WorkspaceBrowserController()
        controller.currentDocument = { [weak self] in self?.currentDocument }
        return controller
    }()
    let settings = SettingsController()
    let recentDocumentsMenu = RecentDocumentsMenu()
    lazy var folderSearch: FolderSearchController = {
        let controller = FolderSearchController()
        controller.workspaceRoots = { [weak self] in self?.workspaceBrowser.store.state.folders ?? [] }
        return controller
    }()
    /// The document window focused last. Written where focus changes (a view's onFocus, a
    /// document window becoming main, the status menu); never by a getter.
    weak var lastDocumentController: EditorWindowController?
    /// The one definition of "current" for every controller: the main window when it is a
    /// document window, otherwise the document window focused last, because Find and Replace,
    /// a Run result or another auxiliary window may be main. Nil once that document has closed.
    var currentDocumentController: EditorWindowController? {
        let controller = (NSApp.mainWindow?.windowController as? EditorWindowController) ?? lastDocumentController
        return controller?.document == nil ? nil : controller
    }
    var currentDocument: TextDocument? { currentDocumentController?.document as? TextDocument }
    var currentEditor: TTEditor? { currentDocumentController?.activeEditor }
    lazy var languages: LanguageController = {
        let controller = LanguageController(
            editorProvider: { [weak self] in self?.currentEditor },
            languageProvider: { [weak self] in
                self?.currentDocument?.languageIdentifier ?? LanguageProfile.plainTextID
            },
            setLanguage: { [weak self] id in self?.currentDocument?.languageIdentifier = id })
        controller.siblingViews = { editor in
            for document in NSDocumentController.shared.documents {
                for case let window as EditorWindowController in document.windowControllers
                where window.views.contains(where: { $0 === editor }) {
                    return window.views.filter { $0 !== editor }
                }
            }
            return []
        }
        controller.openDocuments = {
            NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }.map {
                ($0.languageIdentifier, $0.editor)
            }
        }
        return controller
    }()
    // The providers below only answer "which editor". A macro recording is invalidated where
    // an action is committed, through each controller's hook, never by asking for the editor.
    lazy var runner: RunController = {
        let controller = RunController()
        controller.editor = { [weak self] in self?.currentEditor }
        controller.onUnrecordableAction = { [weak self] in
            self?.macros.invalidateRecording(reason: "External execution is never recorded in macros.")
        }
        controller.file = { [weak self] in self?.currentDocument?.fileURL }
        return controller
    }()
    lazy var utilities: UtilityController = {
        let controller = UtilityController(activeEditor: { [weak self] in self?.currentEditor })
        controller.onUnrecordableEdit = { [weak self] in
            self?.macros.invalidateRecording(reason: "Text utilities are not recorded in macros yet.")
        }
        return controller
    }()
    lazy var searchController: SearchController = {
        let controller = SearchController()
        controller.readFindText = { EditorWindowController.findPasteboardText }
        controller.writeFindText = { [weak self] text in
            EditorWindowController.findPasteboardText = text
            self?.currentDocumentController?.acceptSharedFindText(text)
        }
        controller.currentEditor = { [weak self] in self?.currentEditor }
        // One view per document, and the one the person last worked in: Find Next compares
        // these with the current editor, and a replace reads that view's selection.
        controller.openEditors = {
            NSDocumentController.shared.documents.compactMap { ($0 as? TextDocument)?.activeEditor }
        }
        return controller
    }()
    lazy var macros = MacroController(editorProvider: { [weak self] in self?.currentEditor })
    lazy var automations: AutomationController = {
        let controller = AutomationController(
            editorProvider: { [weak self] in self?.currentEditor }, newDocument: AppDelegate.openAutomationOutput)
        controller.onQuietExportResult = { [weak self] message in
            let window = (NSApp.mainWindow?.windowController as? EditorWindowController) ?? self?.lastDocumentController
            window?.showTransientStatus(message, seconds: 8, announce: false)
        }
        controller.onInvocation = { [weak self] in
            self?.macros.invalidateRecording(
                reason: "An automation was invoked during macro recording. Automation side effects are not recorded.")
        }
        return controller
    }()
    private static func openAutomationOutput(_ text: String) {
        let doc = TextDocument()
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.editor.text = text
        doc.editor.setLineEndingMode(LineEnding.detect(in: text).rawValue)
        doc.showWindows()
        doc.windowControllers.first?.window?.makeFirstResponder(doc.editor)
    }
    /// The reason often arrives inside an editor callback, and for a click while the button is
    /// still down. A modal alert then would swallow the mouse-up and leave the editor dragging,
    /// so the alert waits for a later turn with no button pressed.
    private func explainDiscardedRecording(_ reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard NSEvent.pressedMouseButtons == 0 else {
                self?.explainDiscardedRecording(reason)
                return
            }
            TTAlert.explain(
                "Macro recording was discarded",
                detail: reason + " Choose Stop Recording, then Start Recording to record again."
                    + " The previous recording is kept.")
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        settings.apply()
        searchController.onCommand = { [weak self] options, action, editor in
            self?.macros.recordSearch(.init(options: options, action: action), editor: editor)
        }
        searchController.onUnrecordableCommand = { [weak self] reason in
            self?.macros.invalidateRecording(reason: reason)
        }
        folderSearch.onUnrecordableCommand = { [weak self] reason in
            self?.macros.invalidateRecording(reason: reason)
        }
        languages.onUnrecordableCommand = { [weak self] reason in
            self?.macros.invalidateRecording(reason: reason)
        }
        // F67: the person hears and reads at once that the recording can no longer be saved.
        macros.onInvalidated = { [weak self] reason in
            NSSound.beep()
            self?.explainDiscardedRecording(reason)
        }
        macros.searchPlayback = { [weak self] search, editor in
            guard let self else { throw MacroError.invalid("Search controller unavailable.") }
            var options = SearchOptions()
            options.query = search.query
            options.replacement = search.replacement
            options.mode = SearchOptions.Mode(rawValue: search.mode) ?? .normal
            options.matchCase = search.matchCase
            options.wholeWord = search.wholeWord
            options.dotMatchesNewline = search.dotMatchesNewline
            options.wrap = search.wrap
            try self.searchController.playRecorded(options: options, action: search.action, on: editor)
        }
        if let message = settings.loadFailureMessage {
            let alert = TTAlert()
            alert.alertStyle = .warning
            alert.messageText = "Settings could not be read"
            alert.informativeText = message
            _ = alert.runModal()
        }
        if let message = languages.loadFailureMessage {
            let alert = TTAlert()
            alert.alertStyle = .warning
            alert.messageText = "Language profiles could not be read"
            alert.informativeText = message
            _ = alert.runModal()
        }
        NSApp.activate()
        if NSDocumentController.shared.documents.isEmpty {
            newDocument(nil)
        } else {
            for document in NSDocumentController.shared.documents {
                if document.windowControllers.isEmpty { document.makeWindowControllers() }
                document.showWindows()
            }
        }
        restoreRecovery()
    }
    @objc func newDocument(_ sender: Any?) {
        let doc = TextDocument()
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        doc.windowControllers.first?.window?.makeFirstResponder(doc.editor)
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    /// Saved window state is decoded with secure coding only.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    /// Closes every document once quitting is certain, never while the review can still be
    /// cancelled. The tab windows are taken off screen first: closing a visible tab shows the
    /// tab that takes its place, and at quit that would show and lay out each remaining document.
    func closeAllForTermination() {
        let documents = NSDocumentController.shared.documents
        DocumentTabWindow.documents.forEach { $0.orderOut(nil) }
        for document in documents { document.close() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if NSDocumentController.shared.documents.allSatisfy({ !$0.isDocumentEdited }) {
            closeAllForTermination()
            return .terminateNow
        }
        DispatchQueue.main.async { self.requestUnsavedReview(self) }
        return .terminateLater
    }
    /// Runs once the quit is committed, never while the unsaved-documents review can still be
    /// cancelled. A running Run command is a scoped job: its process group is stopped here, with
    /// a bounded wait, instead of being left to run on after TextTank has gone.
    func applicationWillTerminate(_ notification: Notification) { _ = runner.cancelAndWait(timeout: 1.0) }
    /// The two AppKit calls of the dirty-quit path. They are properties only so that a check
    /// can observe the request and the reply without presenting the review or ending the process.
    var requestUnsavedReview: (AppDelegate) -> Void = { delegate in
        NSDocumentController.shared.reviewUnsavedDocuments(
            withAlertTitle: "Quit TextTank?", cancellable: true, delegate: delegate,
            didReviewAllSelector: #selector(AppDelegate.reviewed(_:didReviewAll:contextInfo:)), contextInfo: nil)
    }
    var replyToTerminate: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    @objc func reviewed(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if didReviewAll { closeAllForTermination() }
        replyToTerminate(didReviewAll)
    }
    func buildMenus() {
        let bar = NSMenu()
        NSApp.mainMenu = bar
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            item.title = title
            let m = NSMenu(title: title)
            item.submenu = m
            bar.addItem(item)
            return m
        }
        let app = menu("TextTank")
        app.addItem(title: "About TextTank", action: #selector(about))
        app.addItem(
            title: "Settings…", action: #selector(SettingsController.showSettings(_:)), keyEquivalent: ",",
            target: settings)
        app.addItem(.separator())
        // The standard application items. AppKit fills the Services menu.
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        app.addItem(servicesItem)
        app.addItem(.separator())
        app.addItem(title: "Hide TextTank", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h",
            modifiers: [.command, .option])
        app.addItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        app.addItem(title: "Quit TextTank", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = menu("File")
        file.addItem(title: "New", action: #selector(newDocument(_:)), keyEquivalent: "n")
        file.addItem(title: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = recentDocumentsMenu
        recentItem.submenu = recentMenu
        file.addItem(recentItem)
        file.addItem(title: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(title: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        file.addItem(title: "Save Copy…", action: #selector(TextDocument.saveCopy(_:)))
        file.addItem(title: "Save All", action: #selector(NSDocumentController.saveAllDocuments(_:)))
        file.addItem(title: "Revert to Saved…", action: #selector(NSDocument.revertToSaved(_:)))
        file.addItem(title: "Check for External Changes", action: #selector(TextDocument.checkExternalChanges(_:)))
        file.addItem(title: "Read Only", action: #selector(TextDocument.toggleReadOnly(_:)))
        file.addItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(.separator())
        file.addItem(title: "Page Setup…", action: #selector(NSDocument.runPageLayout(_:)))
        file.addItem(title: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        file.addItem(
            title: "Save Session Snapshot…", action: #selector(WorkspaceController.saveSession(_:)), target: workspace)
        file.addItem(
            title: "Open Session Snapshot…", action: #selector(WorkspaceController.openSession(_:)), target: workspace)
        let workspaceRoot = NSMenuItem()
        workspaceRoot.title = "Workspace"
        workspaceRoot.submenu = workspaceBrowser.menu()
        bar.addItem(workspaceRoot)
        let encoding = menu("Encoding")
        for (title, code) in [
            ("UTF-8", "utf8"), ("UTF-8 with BOM", "utf8bom"), ("UTF-16 LE with BOM", "utf16LE"),
            ("UTF-16 BE with BOM", "utf16BE"), ("Windows-1252", "windows1252"), ("ISO-8859-1", "latin1")
        ] {
            encoding.addItem(
                title: "Convert to \(title)", action: #selector(TextDocument.convertEncoding(_:)),
                representedObject: code)
        }
        encoding.addItem(.separator())
        // The same names as the Convert items above, never the stored identifier.
        let encodingNames: [FileEncoding: String] = [
            .utf8: "UTF-8", .utf16LE: "UTF-16 LE", .utf16BE: "UTF-16 BE", .windows1252: "Windows-1252",
            .latin1: "ISO-8859-1"
        ]
        for value in FileEncoding.allCases {
            encoding.addItem(
                title: "Reload as \(encodingNames[value] ?? value.rawValue)…",
                action: #selector(TextDocument.reloadEncoding(_:)), representedObject: value.rawValue)
        }
        let edit = menu("Edit")
        // Grouped by what the command acts on. Every item keeps its command identifier as its
        // represented object, so shortcuts, macros and validation find it wherever it sits.
        func group(_ title: String) -> NSMenu {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            parent.submenu = child
            edit.addItem(parent)
            return child
        }
        func command(_ m: NSMenu, _ title: String, _ id: String, _ key: String = "") {
            m.addItem(
                title: title, action: #selector(EditorWindowController.command(_:)), keyEquivalent: key,
                representedObject: id)
        }
        func transform(_ m: NSMenu, _ value: EditorTransform) {
            command(m, value.title, "transform." + value.rawValue)
        }
        edit.addItem(
            title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z", representedObject: "undo")
        edit.addItem(
            title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z", representedObject: "redo")
        edit.addItem(.separator())
        edit.addItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x", representedObject: "cut")
        edit.addItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c", representedObject: "copy")
        edit.addItem(
            title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v", representedObject: "paste")
        edit.addItem(
            title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a",
            representedObject: "selectAll")
        edit.addItem(.separator())
        let lines = group("Lines")
        command(lines, "Duplicate Line", "duplicateLine", "d")
        command(lines, "Delete Line", "deleteLine")
        command(lines, "Transpose Lines", "transposeLine")
        command(lines, "Move Line Up", "moveLineUp")
        command(lines, "Move Line Down", "moveLineDown")
        command(lines, "Join Selected Lines", "joinLines")
        lines.addItem(.separator())
        for value: EditorTransform in [
            .sortAscending, .sortDescending, .sortCaseInsensitive, .sortLocalized, .sortLength
        ] { transform(lines, value) }
        lines.addItem(.separator())
        for value: EditorTransform in [.reverseLines, .uniqueLines, .removeEmptyLines] { transform(lines, value) }
        let whitespace = group("Indentation and Whitespace")
        command(whitespace, "Indent", "indent", "]")
        command(whitespace, "Unindent", "unindent", "[")
        whitespace.addItem(.separator())
        transform(whitespace, .trimLeading)
        command(whitespace, "Trim Trailing Whitespace", "trimTrailing")
        transform(whitespace, .trimBoth)
        let letterCase = group("Convert Case")
        command(letterCase, "Uppercase", "upper")
        command(letterCase, "Lowercase", "lower")
        transform(letterCase, .titleCase)
        transform(letterCase, .invertCase)
        let comments = group("Comment")
        for comment in CommentCommand.allCases {
            comments.addItem(
                title: comment.title, action: #selector(EditorWindowController.comment(_:)),
                representedObject: comment.rawValue)
        }
        let selection = group("Selection")
        for (title, id) in [
            ("Rectangular Selection", "rectangularSelection"), ("Stream Selection", "streamSelection"),
            ("Add Next Occurrence", "addNextOccurrence"), ("Select All Occurrences", "selectAllOccurrences"),
            ("Clear Additional Selections", "clearAdditionalSelections"), ("Duplicate Selection", "duplicateSelection")
        ] { command(selection, title, id) }
        selection.addItem(.separator())
        selection.addItem(title: "Column Insert / Number…", action: #selector(EditorWindowController.columnInsert(_:)))
        let deletion = group("Delete")
        for (title, id) in [
            ("Delete Word Left", "deleteWordLeft"), ("Delete Word Right", "deleteWordRight"),
            ("Delete to Line Start", "deleteLineLeft"), ("Delete to Line End", "deleteLineRight")
        ] { command(deletion, title, id) }
        let endings = group("Line Endings")
        for mode in ["LF", "CRLF", "CR"] {
            endings.addItem(
                title: "Convert to \(mode)", action: #selector(EditorWindowController.convertEOL(_:)),
                representedObject: mode)
        }
        edit.addItem(.separator())
        command(edit, "Toggle Overtype", "toggleOvertype")
        // Every transform has a place above; a new case must be given one.
        assert(
            Set(EditorTransform.allCases).isSubset(of: [
                .sortAscending, .sortDescending, .sortCaseInsensitive, .sortLocalized, .sortLength, .reverseLines,
                .uniqueLines, .removeEmptyLines, .trimLeading, .trimBoth, .titleCase, .invertCase
            ]), "an EditorTransform has no Edit menu item")
        let search = menu("Search")
        // One Find. Command-F opens the find bar in the document window; Find Next, Find Previous
        // and Use Selection for Find share its text with the system find pasteboard. Find and
        // Replace is the window with scopes, regular expressions and results.
        search.addItem(title: "Find…", action: #selector(EditorWindowController.showFind(_:)), keyEquivalent: "f")
        search.addItem(
            title: "Find and Replace…", action: #selector(SearchController.showSearch(_:)), keyEquivalent: "f",
            modifiers: [.command, .option], target: searchController)
        for (title, action, key) in [
            ("Find Next", #selector(findNextShared(_:)), "g"), ("Find Previous", #selector(findPreviousShared(_:)), "G")
        ] {
            search.addItem(title: title, action: action, keyEquivalent: key, target: self)
        }
        search.addItem(
            title: "Use Selection for Find", action: #selector(EditorWindowController.useSelectionForFind(_:)),
            keyEquivalent: "e")
        search.addItem(
            title: "Find in Folder…", action: #selector(FolderSearchController.showSearch(_:)), keyEquivalent: "F",
            target: folderSearch)
        search.addItem(title: "Go to Line…", action: #selector(EditorWindowController.goToLine(_:)), keyEquivalent: "l")
        for (label, id) in [
            ("Matching Brace", "gotoMatchingBrace"), ("Select to Matching Brace", "selectMatchingBrace"),
            ("Toggle Bookmark", "bookmarkToggle"), ("Next Bookmark", "bookmarkNext"),
            ("Previous Bookmark", "bookmarkPrevious")
        ] { search.addItem(title: label, action: #selector(EditorWindowController.command(_:)), representedObject: id) }
        let runRoot = NSMenuItem()
        runRoot.title = "Run"
        runRoot.submenu = runner.makeMenu()
        bar.addItem(runRoot)
        let utilityRoot = NSMenuItem()
        utilityRoot.title = "Text Utilities"
        utilityRoot.submenu = utilities.makeMenu()
        bar.addItem(utilityRoot)
        let view = menu("View")
        view.addItem(title: "Clone in Split View", action: #selector(EditorWindowController.clone(_:)))
        view.addItem(title: "Close Split View", action: #selector(EditorWindowController.closeSplit(_:)))
        view.addItem(title: "Wrap Lines", action: #selector(EditorWindowController.toggleWrap(_:)))
        view.addItem(
            title: "Zoom In", action: #selector(EditorWindowController.command(_:)), keyEquivalent: "+",
            representedObject: "zoomIn")
        view.addItem(
            title: "Zoom Out", action: #selector(EditorWindowController.command(_:)), keyEquivalent: "-",
            representedObject: "zoomOut")
        for (label, id) in [
            ("Fold All", "foldAll"), ("Unfold All", "unfoldAll"), ("Show Whitespace", "showWhitespace"),
            ("Show Line Endings", "toggleEOL"), ("Show Line Numbers", "toggleLineNumbers")
        ] { view.addItem(title: label, action: #selector(EditorWindowController.command(_:)), representedObject: id) }
        let languageRoot = NSMenuItem()
        languageRoot.title = "Language"
        languageRoot.submenu = languages.menu()
        bar.addItem(languageRoot)
        let macroRoot = NSMenuItem()
        macroRoot.title = "Macros"
        macroRoot.submenu = macros.menu()
        bar.addItem(macroRoot)
        let automationRoot = NSMenuItem()
        automationRoot.title = "Automations"
        automationRoot.submenu = automations.menu()
        bar.addItem(automationRoot)
        // The palette's one menu entry, with Shift-Command-P, is in the Automations menu.
        let window = menu("Window")
        NSApp.windowsMenu = window
        window.addItem(
            title: "Next Tab", action: #selector(nextDocumentTab(_:)), keyEquivalent: "\t", modifiers: [.control],
            target: self)
        window.addItem(
            title: "Previous Tab", action: #selector(previousDocumentTab(_:)), keyEquivalent: "\t",
            modifiers: [.control, .shift], target: self)
        window.addItem(title: "Open Documents…", action: #selector(showDocumentTabs(_:)))
        window.addItem(.separator())
        window.addItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        window.addItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)))
        // AppKit puts its search field in the Help menu; it finds any command in the menus above.
        let help = menu("Help")
        NSApp.helpMenu = help
        help.addItem(title: "TextTank Help (Online)", action: #selector(openOnlineHelp(_:)), keyEquivalent: "?")
    }
    /// The project page, which carries the review guide and where each command lives. There is no
    /// bundled help book yet.
    @objc func openOnlineHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/funkymonkeyjam/TextTank#readme") { NSWorkspace.shared.open(url) }
    }
    /// Find Next and Find Previous act on whichever Find the person is using: the Find and Replace
    /// window while it is open, otherwise the find bar of the current document window.
    @objc func findNextShared(_ sender: Any?) { findShared(backwards: false) }
    @objc func findPreviousShared(_ sender: Any?) { findShared(backwards: true) }
    private func findShared(backwards: Bool) {
        if searchController.isWindowLoaded, searchController.window?.isVisible == true {
            if backwards { searchController.previous(nil) } else { searchController.next(nil) }
        } else {
            let controller =
                (NSApp.mainWindow?.windowController as? EditorWindowController) ?? lastDocumentController
            controller?.findFromMenu(backwards: backwards)
        }
    }
    @objc func nextDocumentTab(_ sender: Any?) { cycleDocumentTab(1) }
    @objc func previousDocumentTab(_ sender: Any?) { cycleDocumentTab(-1) }
    private func cycleDocumentTab(_ direction: Int) {
        let windows = DocumentTabWindow.documents
        guard !windows.isEmpty else { return }
        let index = windows.firstIndex(where: { $0.isVisible }) ?? 0
        windows[(index + direction + windows.count) % windows.count].makeKeyAndOrderFront(nil)
    }
    @objc func showDocumentTabs(_ sender: Any?) {
        let windows = DocumentTabWindow.documents
        guard !windows.isEmpty else { return }
        let alert = TTAlert()
        alert.messageText = "Open Documents"
        let choice = documentTabChoices(windows)
        choice.selectItem(at: windows.firstIndex(where: { $0.isVisible }) ?? 0)
        alert.accessoryView = choice
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        guard alert.runModal() == .alertFirstButtonReturn, let index = choice.selectedItem?.tag,
            windows.indices.contains(index), DocumentTabWindow.documents.contains(where: { $0 === windows[index] })
        else { return }
        windows[index].makeKeyAndOrderFront(nil)
    }
    func documentTabChoices(_ windows: [NSWindow]) -> NSPopUpButton {
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 30))
        for (index, window) in windows.enumerated() {
            let path = (window.windowController?.document as? NSDocument)?.fileURL?.deletingLastPathComponent().path
            let title = window.title + (window.isDocumentEdited ? " •" : "") + (path.map { " — \($0)" } ?? "")
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = index
            choice.menu?.addItem(item)
        }
        return choice
    }
    /// Full paths, because the Recovery folder is inside the hidden Library folder.
    static func recoveryIssueText(_ issues: [RecoveryIssue]) -> String {
        "These files were left untouched and are not recovered automatically.\n\n"
            + issues.map { $0.url.path + "\n" + $0.message }.joined(separator: "\n\n")
    }
    /// The launch prompt's text: what each snapshot is a draft of and when it was written, so the
    /// person can tell the drafts apart before recovering or discarding them. Display only.
    static func recoveryPromptText(_ snapshots: [RecoverySnapshot], limit: Int = 12) -> String {
        let listed = snapshots.prefix(limit).map { "• " + SnapshotLabel.line(for: $0) }
        let more = snapshots.count > limit ? ["…and \(snapshots.count - limit) more"] : []
        return
            "Found \(snapshots.count) recovery snapshot\(snapshots.count == 1 ? "" : "s"). Recovered content opens as new unsaved documents; original files are not changed. Later keeps the snapshots and asks again at the next launch.\n\n"
            + (listed + more).joined(separator: "\n")
    }
    /// The Recover branch of the launch prompt. Documents are opened one at a time, so the
    /// snapshots before one that fails stay open when the error is shown.
    @discardableResult func openRecovered(_ snapshots: [RecoverySnapshot]) throws -> [TextDocument] {
        var opened = [TextDocument]()
        for snapshot in snapshots { opened.append(try TextDocument.openRecovered(snapshot)) }
        return opened
    }
    private func restoreRecovery() {
        do {
            let scan = try TextDocument.recovery.scan()
            let snapshots = scan.snapshots
            if !scan.issues.isEmpty {
                let warning = TTAlert()
                warning.messageText = "Some recovery files need review"
                warning.informativeText = Self.recoveryIssueText(scan.issues)
                warning.addButton(withTitle: "OK")
                warning.addButton(withTitle: "Reveal in Finder")
                if warning.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting(scan.issues.map(\.url))
                }
            }
            guard !snapshots.isEmpty else { return }
            let alert = TTAlert()
            alert.messageText = "Recover unsaved documents?"
            alert.informativeText = Self.recoveryPromptText(snapshots)
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Discard…")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                try openRecovered(snapshots)
            case .alertThirdButtonReturn:
                let confirm = TTAlert()
                confirm.alertStyle = .warning
                confirm.messageText = "Discard \(snapshots.count) recovery snapshots?"
                confirm.informativeText =
                    "The unsaved text in these snapshots will be permanently deleted. Original files are not changed. This cannot be undone."
                confirm.addButton(withTitle: "Cancel", role: .cancel)
                confirm.addButton(withTitle: "Discard")
                confirm.buttons.last?.hasDestructiveAction = true
                guard confirm.runModal() == .alertSecondButtonReturn else { return }
                // Only the snapshots listed above, at the revision that was scanned.
                let kept = TextDocument.recovery.discard(snapshots)
                if !kept.isEmpty {
                    let summary = TTAlert()
                    summary.messageText = "\(kept.count) recovery snapshots were not discarded"
                    summary.informativeText = Self.recoveryIssueText(kept)
                    summary.addButton(withTitle: "OK")
                    summary.addButton(withTitle: "Reveal in Finder")
                    if summary.runModal() == .alertSecondButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting(kept.map(\.url))
                    }
                }
            default: return
            }
        } catch { TTAlert.present(error) }
    }
    /// The About panel's options. The name, version, build and copyright come from the bundle,
    /// so they cannot disagree with Finder's Get Info; only the preview notice is added to the
    /// version. The credits are the bundled Credits.rtf, in the label colour so that they stay
    /// readable in dark mode. Without that file the panel shows its standard contents.
    static func aboutOptions(info: [String: Any]?, credits: URL?) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            options[.applicationVersion] = version + " — INCOMPLETE PREVIEW"
        }
        if let credits, let data = try? Data(contentsOf: credits),
            let text = NSMutableAttributedString(rtf: data, documentAttributes: nil)
        {
            text.addAttribute(
                .foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: text.length))
            options[.credits] = text
        }
        return options
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(
            options: Self.aboutOptions(
                info: Bundle.main.infoDictionary,
                credits: Bundle.main.url(forResource: "Credits", withExtension: "rtf")))
    }
}

/// The Objective-C name is fixed, so `NSDocumentClass` in Info.plist does not depend on the
/// name of the Swift module.
@objc(TextDocument) final class TextDocument: NSDocument {
    /// The type name used where a document has none of its own. Reading ignores the type.
    static let plainTextType = "public.plain-text"
    /// No File Format pop-up in the Save panel. Every content type in Info.plist is a writable
    /// type and nearly all are named "Plain Text"; choosing one would only switch the type name
    /// and, for some, add that type's extension. The text is written the same way for all.
    override var shouldRunSavePanelWithAccessoryView: Bool { false }
    static let recovery = RecoveryStore(directory: AppStorage.url(.recovery))
    var recoveryID = UUID()
    /// Offset for recovery metadata changes; adding the editor revision gives the store revision.
    var recoveryBase: UInt64 = 0
    /// One notice per app session about repeated recovery-write failures.
    static var recoveryFailureNoticeShown = false
    #if TESTING
        static var recoveryFailureNoticeForTesting: ((TextDocument, Error) -> Void)?
    #endif
    private var recoveryFailures = RecoveryFailureTracker()
    /// The failure of the most recent recovery write or cleanup; nil after a success.
    private(set) var lastRecoveryError: Error?
    private var recoveryTimer: Timer?
    private var recoveryDeadlineTimer: Timer?
    private let recoveryWriter = RecoveryWriter()
    /// Invalidates completion callbacks whenever recovery is rescheduled, flushed or closed.
    private var recoveryGeneration = 0
    /// Terminal once close starts: no timer or late completion may enqueue another copy.
    private var recoveryClosed = false
    private static let defaultAutomaticRecoveryDelay: TimeInterval = 0.5
    private static let defaultMaximumRecoveryDelay: TimeInterval = 5
    #if TESTING
        var automaticRecoveryDelay = TextDocument.defaultAutomaticRecoveryDelay
        var maximumRecoveryDelay = TextDocument.defaultMaximumRecoveryDelay
    #else
        private let automaticRecoveryDelay = TextDocument.defaultAutomaticRecoveryDelay
        private let maximumRecoveryDelay = TextDocument.defaultMaximumRecoveryDelay
    #endif
    let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    /// Encoding/BOM checkpoint paired with the save point from the latest completed read or save.
    var savedFormat = FileFormat(encoding: .utf8, bom: false)
    var format = FileFormat(encoding: .utf8, bom: false) {
        didSet {
            if !loading && format != oldValue {
                recoveryBase += 1
                updateChangeCount(hasUnsavedState ? .changeDone : .changeCleared)
            }
        }
    }
    /// SHA-256 of the bytes last read or saved. No copy of the file is kept.
    private var diskDigest: String?
    /// Settled metadata of a file known to hold those bytes, when there is one. While the file
    /// still has exactly this metadata it need not be read again; nil means read and hash.
    private var diskSignature: FileSignature?
    /// A sample taken by a caller that read the bytes through its own descriptor.
    private var capturedSample: FileSample?
    /// Immutable bytes captured before a coordinated write; only data(ofType:) reads them during that write.
    private var savePayload: Data?
    /// False if edits arrived during a save, so Scintilla's save point no longer identifies the disk bytes.
    private var savepointMatchesDisk = true
    /// Ordinary dirty state shared by editor-change and format-change callbacks.
    private var hasUnsavedState: Bool { editor.modified || format != savedFormat || !savepointMatchesDisk }
    /// Recovery also keeps an untouched restored document: its framework dirty flag is independent
    /// of the freshly loaded editor's save point and format checkpoint. Keep this broader rule distinct.
    private var shouldKeepRecoveryCopy: Bool { isDocumentEdited || editor.modified || format != savedFormat }
    private var recoveryRevision: UInt64 { recoveryBase + UInt64(editor.revision) }
    #if TESTING
        var afterWriteForTesting: (() throws -> Void)?
        /// Runs while NSDocument is inside an in-progress write, as the bytes are produced.
        var duringWriteForTesting: (() -> Void)?
        var hasSettledDiskSignature: Bool { diskSignature != nil }
    #endif
    var originalDiskFingerprint: String? { diskDigest }
    var languageIdentifier = LanguageProfile.plainTextID { didSet { languageResolved = true } }
    /// False until the first load has chosen a language, or the person or a restored session has.
    /// Reload and Revert then keep that choice instead of detecting again.
    private var languageResolved = false
    /// Status-line text for a recovered draft: what it is a draft of and when it was written.
    /// Cleared when the draft is saved under a name of its own.
    private(set) var recoveredOrigin: String?
    /// Suppresses ordinary edit/recovery callbacks while a read or restore establishes its checkpoints.
    private var loading = false
    /// Set only while an explicit open-with-encoding is reading the file.
    private var openEncoding: FileEncoding?
    private var readingURL: URL?
    /// A snapshot records the file it belongs to. A moved or renamed file is new snapshot
    /// metadata at the same text revision, so it needs a later recovery revision.
    ///
    /// While an in-place save is inside NSDocument, the getter answers with the resolved
    /// location being written. NSDocument's safe save replaces the item at `fileURL`, not at the
    /// URL it is handed: with a link as `fileURL` it fails, and with the two differing it can
    /// remove the original and then fail. Answering with the destination keeps them equal.
    /// Only the main thread, which does the write, is answered that way: NSDocument also reads
    /// `fileURL` from its file-presenter queue, and every other thread keeps the opened path.
    /// `inPlaceWriteURL` is therefore read and written on the main thread alone.
    override var fileURL: URL? {
        get {
            if Thread.isMainThread, let inPlaceWriteURL { return inPlaceWriteURL }
            return super.fileURL
        }
        set {
            let oldValue = super.fileURL
            super.fileURL = newValue
            guard newValue != oldValue else { return }
            diskURL = newValue.map(Self.canonicalDiskURL)
            if Thread.isMainThread {
                recoveryBase += 1
                // Saved under a name of its own: no longer a recovered draft. Setting the URL has
                // already replaced the "Recovered …" display name with the file's name.
                recoveredOrigin = nil
            } else {
                DispatchQueue.main.async { [weak self] in self?.recoveryBase += 1 }
            }
        }
    }
    /// Where the file really is: `fileURL` with symbolic links resolved once, when `fileURL` is
    /// set. The no-follow reads and the in-place write use it, so a document reached through a
    /// link can be checked and saved, and a link swapped in later is still refused because this
    /// is not resolved again. `fileURL` itself keeps the path the person opened.
    private(set) var diskURL: URL?
    private var inPlaceWriteURL: URL?
    /// realpath(3) of the file; for a name that does not exist yet, of its folder. Falls back
    /// to the URL as given.
    static func canonicalDiskURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        func resolved(_ path: String) -> String? {
            guard let pointer = realpath(path, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        if let path = resolved(url.path) { return URL(fileURLWithPath: path, isDirectory: false) }
        if let folder = resolved(url.deletingLastPathComponent().path) {
            return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(
                url.lastPathComponent, isDirectory: false)
        }
        return url
    }
    /// Runs a no-follow read of the document's own file at its resolved location. ELOOP and
    /// ENOTDIR mean the resolved path has since become a link, or its folder is no longer a
    /// real folder.
    private func onDiskFile<T>(_ read: (URL) throws -> T) throws -> T {
        guard let url = diskURL else {
            throw DocumentActionError.notSaved
        }
        do { return try read(url) } catch let error as POSIXError
            where error.code == .ELOOP || error.code == .ENOTDIR
        {
            throw DocumentActionError.unsafeDiskPath(url, underlying: error)
        }
    }
    enum DiskState: Equatable {
        case unchanged, changed, missing
        var alertText: (title: String, detail: String) {
            let title: String
            switch self {
            case .unchanged: title = "File is unchanged"
            case .missing: title = "File is missing"
            case .changed: title = "File changed outside TextTank"
            }
            let detail =
                self == .unchanged
                ? "The on-disk bytes match the last read or save."
                : "Your editor contents are preserved. Use Save As to keep your edits, or Revert to Saved to reload the disk version."
            return (title: title, detail: detail)
        }
    }
    func diskState() throws -> DiskState {
        try diskState(trustingSettledMetadata: false)
    }
    /// The state of the document's own file at its resolved location. An explicit check always
    /// hashes the file, in steps, without holding it in memory. A save may instead trust settled
    /// metadata that is unchanged since the bytes were last read: that is the file last read.
    /// Right after a save the metadata is too new to rely on, so the hash still runs.
    private func diskState(trustingSettledMetadata: Bool) throws -> DiskState {
        guard fileURL != nil, let diskDigest else { return .unchanged }
        do {
            return try onDiskFile { url -> DiskState in
                if trustingSettledMetadata, let diskSignature,
                    try WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max) == diskSignature
                {
                    return .unchanged
                }
                let sample = try WorkspaceStore.sample(ofRegularFileAt: url, maximumBytes: Int.max)
                guard sample.digest == diskDigest else { return .changed }
                diskSignature = sample.signature
                return .unchanged
            }
        } catch  where error.isFileNotFound { return .missing }
    }
    @objc func toggleReadOnly(_ sender: NSMenuItem) {
        // Read-only belongs to the Scintilla document, so this covers a split view's other pane.
        // The checkmark is set when a menu is validated, for the document that menu acts on.
        editor.readOnly.toggle()
    }
    /// Everything NSDocument validates itself (Save, Revert to Saved and the rest) is left to it.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleReadOnly(_:)) {
            (item as? NSMenuItem)?.state = editor.readOnly ? .on : .off
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
    @objc func checkExternalChanges(_ sender: Any?) {
        do {
            let state = try diskState()
            let alert = TTAlert()
            let text = state.alertText
            alert.messageText = text.title
            alert.informativeText = text.detail
            alert.runModal()
        } catch { presentError(error) }
    }
    /// Explicit reinterpretation is a reload, not encoding conversion. Unsaved edits
    /// require a native confirmation before this method is called with discard=true.
    func reload(using encoding: FileEncoding, discard: Bool = false) throws {
        guard fileURL != nil else {
            throw DocumentActionError.notSaved
        }
        if isDocumentEdited && !discard {
            throw DocumentActionError.unsavedChanges
        }
        let (bytes, sample) = try onDiskFile { try WorkspaceStore.readRegularFileSample($0, maximumBytes: Int.max) }
        let decoded = try FileCodec.decode(bytes, encoding: encoding)
        loadDecoded(decoded, sample: sample)
        updateChangeCount(.changeCleared)
        flushRecovery()
    }
    @objc func reloadEncoding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let encoding = FileEncoding(rawValue: raw) else { return }
        if isDocumentEdited {
            let alert = TTAlert()
            alert.messageText = "Discard unsaved changes and reload?"
            alert.informativeText =
                "The disk bytes will be interpreted as \(raw). Use Convert to change the save encoding while keeping your text."
            alert.addButton(withTitle: "Cancel", role: .cancel)
            alert.addButton(withTitle: "Discard and Reload").hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do { try reload(using: encoding, discard: true) } catch { presentError(error) }
    }
    override init() {
        super.init()
        hasUndoManager = false
        // Typing or a key command that Scintilla refuses in a read-only document; the status bar
        // shows Read Only. Menu commands state the reason in words before they reach the engine.
        editor.onReadOnlyAttempt = { [weak self] in self?.noteReadOnlyAttempt() }
        editor.onChange = { [weak self] in
            guard let self, !self.loading else { return }
            self.updateChangeCount(self.hasUnsavedState ? .changeDone : .changeCleared)
            self.showSaveState(recoveryCopyKept: false)
            self.recoveryTimer?.invalidate()
            self.recoveryGeneration += 1
            self.recoveryTimer = self.scheduleRecoveryTimer(after: self.automaticRecoveryDelay)
            if self.recoveryDeadlineTimer == nil {
                self.recoveryDeadlineTimer = self.scheduleRecoveryTimer(after: self.maximumRecoveryDelay)
            }
        }
    }
    /// Common modes include modal panels and event tracking, so the idle and deadline
    /// snapshots still happen while an alert, a menu or interactive macro playback is up.
    /// The timer only captures an immutable snapshot; it never edits the document.
    private func scheduleRecoveryTimer(after delay: TimeInterval) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.enqueueRecovery() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
    private func cancelRecoveryTimers() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recoveryDeadlineTimer?.invalidate()
        recoveryDeadlineTimer = nil
    }
    private func recoveryOperation() -> () throws -> Void {
        let store = Self.recovery, id = recoveryID, revision = recoveryRevision
        if shouldKeepRecoveryCopy {
            let snapshot = RecoverySnapshot(
                id: id, text: editor.text, format: format, originalURL: fileURL?.absoluteString, revision: revision)
            return { try store.save(snapshot) }
        }
        return { try store.remove(id: id, throughRevision: revision) }
    }
    /// The words for this document's save state. An edited document never reads "Saved": it reads
    /// "Edited" from the moment of the change, and says so about the recovery copy only once that
    /// copy has been written.
    func saveStateStatus(recoveryCopyKept: Bool) -> String {
        if let recoveredOrigin { return recoveredOrigin }
        let status: String
        if isDocumentEdited {
            status = recoveryCopyKept ? "Edited — recovery copy kept" : "Edited"
        } else if fileURL == nil {
            status = "Ready"
        } else {
            status = "Saved"
        }
        return status + " · Incomplete preview"
    }
    /// Whether the last recovery write since the latest edit succeeded.
    private var recoveryCopyKept = false
    /// The save-state words as they stand now, for a view that showed something else for a moment.
    var currentSaveStateStatus: String { saveStateStatus(recoveryCopyKept: recoveryCopyKept) }
    /// Typing or a key command that the engine refused because the document is read-only: the
    /// alert sound alone says nothing to someone who cannot hear it or does not know why.
    func noteReadOnlyAttempt() {
        NSSound.beep()
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach {
            $0.showTransientStatus(
                "Read Only is on, so this document cannot be edited. Choose File > Read Only to turn it off.")
        }
    }
    /// Shows the save state now. A recovery failure stays on screen until a later write succeeds.
    private func showSaveState(recoveryCopyKept: Bool) {
        self.recoveryCopyKept = recoveryCopyKept
        guard lastRecoveryError == nil else { return }
        let message = saveStateStatus(recoveryCopyKept: recoveryCopyKept)
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach {
            $0.showRecoveryStatus(message, failed: false)
        }
    }
    private func reportRecovery(_ error: Error?) {
        lastRecoveryError = error
        let controllers = windowControllers.compactMap { $0 as? EditorWindowController }
        guard let error else {
            recoveryFailures.recordSuccess()
            showSaveState(recoveryCopyKept: true)
            return
        }
        // The status line stays in its failure state until a later recovery write succeeds.
        controllers.forEach {
            $0.showRecoveryStatus("⚠︎ Recovery copy not written: \(error.localizedDescription)", failed: true)
        }
        let escalate = recoveryFailures.recordFailure(sessionAlreadyNotified: Self.recoveryFailureNoticeShown)
        if recoveryFailures.consecutiveFailures == 1 {
            NSLog(
                "TextTank: recovery snapshot %@ could not be written: %@", recoveryID.uuidString,
                error.localizedDescription)
        }
        if escalate { Self.recoveryFailureNoticeShown = presentRecoveryFailureNotice(error) }
    }
    /// A sheet, never an app-modal alert: this runs from the recovery timer and must not
    /// interrupt typing. Returns false when there was nowhere to show it, so a later failure retries.
    private func presentRecoveryFailureNotice(_ error: Error) -> Bool {
        #if TESTING
            Self.recoveryFailureNoticeForTesting?(self, error)
            return Self.recoveryFailureNoticeForTesting != nil
        #else
            guard let window = windowControllers.compactMap({ $0.window }).first(where: { $0.isVisible }) else {
                return false
            }
            let alert = TTAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unsaved changes are not being backed up"
            alert.informativeText =
                "TextTank could not write the crash-recovery copy of “\(displayName ?? "this document")” more than once in a row. If the app quit unexpectedly now, recent edits could be lost. The document itself is unchanged; save it to keep your work.\n\nReason: \(error.localizedDescription)\n\nThis notice appears once per session. The status line keeps showing the failure until a recovery copy is written again."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return true
        #endif
    }
    private func enqueueRecovery() {
        guard !recoveryClosed else { return }
        cancelRecoveryTimers()
        let generation = recoveryGeneration, operation = recoveryOperation()
        recoveryWriter.submit { [weak self] in
            let error: Error?
            do {
                try operation()
                error = nil
            } catch let failure { error = failure }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.recoveryClosed, self.recoveryGeneration == generation else { return }
                self.reportRecovery(error)
            }
        }
    }
    func flushRecovery() {
        guard !recoveryClosed else { return }
        cancelRecoveryTimers()
        recoveryGeneration += 1
        do {
            try recoveryWriter.finish(recoveryOperation())
            reportRecovery(nil)
        } catch { reportRecovery(error) }
    }
    override func close() {
        (NSApp.delegate as? AppDelegate)?.macros.editorWillReset(editor, reason: "The recording document was closed.")
        cancelRecoveryTimers()
        recoveryGeneration += 1
        recoveryClosed = true
        editor.onReadOnlyAttempt = nil
        editor.readOnly = true
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.prepareForClose() }
        // NSDocument only reaches close after the user has chosen Save or Discard.
        let store = Self.recovery, id = recoveryID, revision = recoveryRevision
        // Never block or prompt here: close runs once per document on the quit path. A snapshot
        // that could not be removed is found by the next launch's scan and offered or listed there.
        do { try recoveryWriter.finish { try store.remove(id: id, throughRevision: revision) } } catch {
            lastRecoveryError = error
            NSLog(
                "TextTank: recovery snapshot %@ could not be removed at close: %@", id.uuidString,
                error.localizedDescription)
        }
        super.close()
    }
    override class var autosavesInPlace: Bool { false }
    override func makeWindowControllers() { addWindowController(EditorWindowController(document: self)) }
    override func read(from url: URL, ofType typeName: String) throws {
        readingURL = url
        defer { readingURL = nil }
        // AppKit reads the file itself. Settled metadata that is the same on both sides of
        // that read belongs to the bytes it read; anything else leaves the next check to hash.
        let now = WorkspaceStore.currentSecond()
        let before = try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max)
        try super.read(from: url, ofType: typeName)
        if let before, before.isSettled(at: now),
            (try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max)) == before
        {
            diskSignature = before
        }
    }
    /// Reads bytes the caller captured from `url` through the regular-file descriptor guard.
    /// Naming the file lets a UTF-32-looking signature offer the explicit UTF-16 LE open.
    /// `encoding` is the person's explicit choice, as in `read(from:ofType:as:)`.
    func read(
        captured data: Data, sample: FileSample, from url: URL, ofType typeName: String,
        as encoding: FileEncoding? = nil
    ) throws {
        let outerEncoding = openEncoding
        readingURL = url
        capturedSample = sample
        if let encoding { openEncoding = encoding }
        defer {
            readingURL = nil
            capturedSample = nil
            openEncoding = outerEncoding
        }
        try read(from: data, ofType: typeName)
    }
    override func read(from data: Data, ofType typeName: String) throws {
        let decoded: DecodedFile
        if let openEncoding {
            decoded = try FileCodec.decode(data, encoding: openEncoding)
        } else {
            do { decoded = try FileCodec.decode(data) } catch FileCodecError.unsupportedUTF32 {
                // FF FE 00 00 is also what UTF-16 LE with a BOM looks like when the text starts
                // with NUL, which TextTank itself can save. Detection stays strict; the user is
                // offered the explicit choice the codec's message asks for.
                guard let readingURL, data.starts(with: [0xFF, 0xFE, 0, 0]) else {
                    throw FileCodecError.unsupportedUTF32
                }
                throw ExplicitEncodingOpener(url: readingURL, typeName: typeName, encoding: .utf16LE).error()
            }
        }
        loadDecoded(
            decoded, sample: capturedSample ?? FileSample(digest: WorkspaceStore.fingerprint(data), signature: nil))
    }
    /// The same strict decode with an encoding the person chose, for callers that already hold
    /// the bytes. A failure throws the codec's error and loads nothing.
    func read(from data: Data, ofType typeName: String, as encoding: FileEncoding) throws {
        openEncoding = encoding
        defer { openEncoding = nil }
        try read(from: data, ofType: typeName)
    }
    /// Explicit open-with-encoding. An already open document is reloaded from disk instead;
    /// that only happens from Revert to Saved, where discarding edits was already confirmed.
    @discardableResult static func open(
        _ url: URL, as encoding: FileEncoding, ofType typeName: String = TextDocument.plainTextType,
        display: Bool = true
    ) throws -> TextDocument {
        if let existing = NSDocumentController.shared.document(for: url) as? TextDocument {
            try existing.reload(using: encoding, discard: true)
            return existing
        }
        let doc = TextDocument()
        doc.fileURL = url
        doc.fileType = typeName
        doc.openEncoding = encoding
        defer { doc.openEncoding = nil }
        try doc.read(from: url, ofType: typeName)
        doc.fileModificationDate =
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        NSDocumentController.shared.addDocument(doc)
        if display {
            doc.makeWindowControllers()
            doc.showWindows()
        }
        return doc
    }
    /// NSDocument's revert discards the edits but schedules no recovery work, because loading
    /// suppresses change handling. Remove the discarded draft's snapshot now. If the revert
    /// throws, the buffer is still dirty and its snapshot must survive.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        flushRecovery()
    }
    /// Loads recovered or session text as a new unsaved document. Undo cannot cross this
    /// boundary (as for open and revert), and the document stays edited until a real save:
    /// the engine's save point is this text, which is not a disk state.
    func loadUnsavedSnapshot(text: String, format snapshotFormat: FileFormat) {
        loading = true
        format = snapshotFormat
        // A new document: writable and empty, so the load cannot be refused.
        _ = editor.loadDocumentText(text)
        editor.setLineEndingMode(LineEnding.detect(in: text).rawValue)
        editor.resetUndoHistory()
        savepointMatchesDisk = false
        loading = false
        updateChangeCount(.changeDone)
    }
    /// Opens one recovery snapshot as a new unsaved document that keeps the snapshot's identity.
    @discardableResult static func openRecovered(_ snapshot: RecoverySnapshot) throws -> TextDocument {
        let (base, overflow) = snapshot.revision.addingReportingOverflow(1)
        guard !overflow else { throw RecoveryError.invalidSnapshot }
        let doc = TextDocument()
        doc.recoveryID = snapshot.id
        doc.recoveryBase = base
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.loadUnsavedSnapshot(text: snapshot.text, format: snapshot.format)
        // Display only: the original path is never opened, read or written by recovery.
        doc.recoveredOrigin = SnapshotLabel.status(for: snapshot)
        if let name = SnapshotLabel.originName(of: snapshot) { doc.displayName = "Recovered " + name }
        doc.showWindows()
        doc.flushRecovery()
        return doc
    }
    private func loadDecoded(_ decoded: DecodedFile, sample: FileSample) {
        (NSApp.delegate as? AppDelegate)?.macros.editorWillReset(editor, reason: "The recording document was reloaded.")
        loading = true
        let locked = editor.readOnly
        editor.readOnly = false
        // One minimal-span edit: bookmarks, folds and the caret outside the changed bytes survive a
        // reload. An empty buffer (first open) takes this as a plain insert.
        // No undo record is kept: the history is emptied below, as for every open and reload.
        _ = editor.loadDocumentText(decoded.text)
        editor.setLineEndingMode(LineEnding.detect(in: decoded.text).rawValue)
        editor.resetUndoHistory()
        format = decoded.format
        savedFormat = format
        diskDigest = sample.digest
        diskSignature = sample.signature
        savepointMatchesDisk = true
        editor.setSavePoint()
        editor.readOnly = locked
        loading = false
        guard !languageResolved else { return }
        languageResolved = true
        if let app = NSApp.delegate as? AppDelegate,
            let id = app.languages.detect(filename: fileURL?.lastPathComponent ?? "", text: decoded.text),
            app.languages.applyToDocument(identifier: id, through: editor)
        {
            languageIdentifier = id
        }
    }
    /// The source's own extension; ".txt" only for an untitled document, nothing for a name without one.
    var suggestedCopyName: String {
        guard let fileURL else { return "Untitled-copy.txt" }
        let type = fileURL.pathExtension
        return fileURL.deletingPathExtension().lastPathComponent + "-copy" + (type.isEmpty ? "" : "." + type)
    }
    /// Save Copy to a chosen location. Choosing the document's own file (the panel has already
    /// asked to replace it) is an ordinary Save, with its conflict check and bookkeeping, so
    /// the external-change baseline cannot fall behind what TextTank itself wrote.
    func writeCopy(to url: URL, completion: @escaping (Error?) -> Void) {
        if let fileURL, let diskURL, Self.canonicalDiskURL(url) == diskURL {
            save(to: fileURL, ofType: fileType ?? Self.plainTextType, for: .saveOperation) { error in
                // NSDocument wraps the failure in a bare "could not be saved"; report the reason itself.
                completion(error.map { ($0 as NSError).userInfo[NSUnderlyingErrorKey] as? Error ?? $0 })
            }
            return
        }
        do {
            try writeSafely(to: url, ofType: fileType ?? Self.plainTextType, for: .saveToOperation)
            completion(nil)
        } catch { completion(error) }
    }
    @objc func saveCopy(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedCopyName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeCopy(to: url) { [weak self] error in if let error { self?.presentError(error) } }
    }
    @objc func convertEncoding(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        do { try convertEncoding(to: code) } catch { presentError(error) }
    }
    /// A read-only document keeps its format, as the status-bar menu already promises.
    func convertEncoding(to code: String) throws {
        try editor.requireWritable()
        let target: FileFormat
        switch code {
        case "utf8bom": target = FileFormat(encoding: .utf8, bom: true)
        case "utf16LE": target = FileFormat(encoding: .utf16LE, bom: true)
        case "utf16BE": target = FileFormat(encoding: .utf16BE, bom: true)
        case "windows1252": target = FileFormat(encoding: .windows1252, bom: false)
        case "latin1": target = FileFormat(encoding: .latin1, bom: false)
        default: target = FileFormat(encoding: .utf8, bom: false)
        }
        _ = try FileCodec.encode(editor.text, format: target)
        format = target
        flushRecovery()
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.refreshStatusDetails() }
    }
    /// Printing lays the whole document out on the main thread before the print panel appears.
    /// At and above this many UTF-8 bytes the person is told so first and can cancel.
    static var largePrintBytes = 4 * 1024 * 1024
    /// Asks whether to go on with a slow print; returns false to cancel. Replaced in checks.
    var confirmLargePrint: (_ message: String, _ detail: String) -> Bool = { message, detail in
        let alert = TTAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Print")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// The warning shown before printing a large document, or nil when none is needed. Reads only
    /// the document's size.
    func largePrintWarning() -> (message: String, detail: String)? {
        let bytes = editor.byteLength
        guard bytes >= Self.largePrintBytes else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return (
            "This document is large (\(size)). Preparing it for printing can take a while.",
            "TextTank will not respond until the pages are laid out, and the print panel appears only after that. The document itself is not changed. To print part of it, copy that part into a new document."
        )
    }
    /// False when the person cancelled a large print. Nothing has been laid out by then.
    func shouldBeginPrinting() -> Bool {
        guard let warning = largePrintWarning() else { return true }
        return confirmLargePrint(warning.message, warning.detail)
    }
    override func printDocument(_ sender: Any?) {
        guard shouldBeginPrinting() else { return }
        super.printDocument(sender)
    }
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation
    {
        let settings = printInfo.copy() as! NSPrintInfo
        settings.dictionary().addEntries(from: printSettings)
        settings.horizontalPagination = .fit
        settings.verticalPagination = .automatic
        settings.isHorizontallyCentered = false
        settings.isVerticallyCentered = false
        let width = max(72, settings.paperSize.width - settings.leftMargin - settings.rightMargin)
        // A static print representation, never a second editable document model.
        let printable = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        printable.isRichText = false
        printable.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        printable.textColor = .black
        printable.backgroundColor = .white
        printable.textContainerInset = .zero
        printable.isHorizontallyResizable = false
        printable.isVerticallyResizable = true
        printable.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        printable.textContainer?.widthTracksTextView = true
        printable.string = editor.text
        if let container = printable.textContainer, let layout = printable.layoutManager {
            layout.ensureLayout(for: container)
            printable.setFrameSize(NSSize(width: width, height: max(1, ceil(layout.usedRect(for: container).height))))
        }
        let operation = NSPrintOperation(view: printable, printInfo: settings)
        operation.jobTitle = displayName
        return operation
    }
    override func data(ofType typeName: String) throws -> Data {
        #if TESTING
            duringWriteForTesting?()
        #endif
        if let savePayload { return savePayload }
        return try FileCodec.encode(editor.text, format: format)
    }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType)
        throws
    {
        // A write to the document's own file goes to its resolved location, so the bytes checked
        // and the bytes replaced are the same file and a link in the path stays a link.
        let inPlace = fileURL != nil && url == fileURL
        let destination = inPlace ? diskURL ?? url : url
        // A missing file is simply written again. A changed one is refused, except for Save As:
        // there the save panel has already asked the person to replace that file. Any other
        // failure (the path became a link, a folder or unreadable) still stops the save.
        if inPlace, diskDigest != nil, try diskState(trustingSettledMetadata: true) == .changed,
            saveOperation != .saveAsOperation
        {
            throw DocumentActionError.diskChanged
        }
        let submitted = try FileCodec.encode(editor.text, format: format), submittedFormat = format,
            submittedRevision = editor.revision
        savePayload = submitted
        defer { savePayload = nil }
        do {
            inPlaceWriteURL = inPlace && Thread.isMainThread ? destination : nil
            defer { inPlaceWriteURL = nil }
            try super.writeSafely(to: destination, ofType: typeName, for: saveOperation)
        }
        #if TESTING
            try afterWriteForTesting?()
        #endif
        if saveOperation != .saveToOperation {
            // The baseline is what was submitted. The file's metadata is not recorded here:
            // another writer may already have replaced it, and only a hash can tell.
            diskDigest = WorkspaceStore.fingerprint(submitted)
            diskSignature = nil
            savedFormat = submittedFormat
            if editor.revision == submittedRevision && format == submittedFormat {
                savepointMatchesDisk = true
                editor.setSavePoint()
                updateChangeCount(.changeCleared)
            } else {
                savepointMatchesDisk = false
                updateChangeCount(.changeDone)
            }
            flushRecovery()
        }
    }

}

/// Recovery attempter for a file whose bytes need an explicit encoding choice. It only
/// decodes and opens; nothing on disk is changed.
final class ExplicitEncodingOpener: NSObject {
    let url: URL, typeName: String, encoding: FileEncoding
    init(url: URL, typeName: String, encoding: FileEncoding) {
        self.url = url
        self.typeName = typeName
        self.encoding = encoding
    }
    func error() -> NSError {
        NSError(
            domain: "TextTank", code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "“\(url.lastPathComponent)” begins with bytes that are either a UTF-32 signature or UTF-16 LE text whose first character is NUL.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "UTF-32 is not supported. If this is a UTF-16 LE file, for example one saved by TextTank, open it as UTF-16 LE. Opening does not change the file.",
                NSLocalizedRecoveryOptionsErrorKey: ["Open as UTF-16 LE", "Cancel"],
                NSRecoveryAttempterErrorKey: self,
                NSURLErrorKey: url
            ])
    }
    @discardableResult func open(display: Bool = true) throws -> TextDocument {
        try TextDocument.open(url, as: encoding, ofType: typeName, display: display)
    }
    override func attemptRecovery(fromError error: Error, optionIndex recoveryOptionIndex: Int) -> Bool {
        guard recoveryOptionIndex == 0 else { return false }
        do {
            try open()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            TTAlert.present(error)
            return false
        }
    }
    override func attemptRecovery(
        fromError error: Error, optionIndex recoveryOptionIndex: Int, delegate: Any?, didRecoverSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let recovered = attemptRecovery(fromError: error, optionIndex: recoveryOptionIndex)
        guard let target = delegate as AnyObject?, let didRecoverSelector,
            let method = class_getInstanceMethod(type(of: target), didRecoverSelector)
        else { return }
        // - (void)didPresentErrorWithRecovery:(BOOL)didRecover contextInfo:(void *)contextInfo
        typealias Callback = @convention(c) (AnyObject, Selector, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(method_getImplementation(method), to: Callback.self)(
            target, didRecoverSelector, recovered, contextInfo)
    }
}

/// Borderless native buttons preserve keyboard and accessibility activation.
/// What the status bar shows about the whole text: its Unicode scalar count and the line endings
/// it contains ("" for none, "Mixed EOL" for more than one kind). One pass over the UTF-8 bytes,
/// safe on any queue; the bytes are valid UTF-8, so every byte that is not a continuation byte
/// starts one scalar.
enum StatusMetrics {
    static func scan(_ utf8: Data) -> (characters: Int, endings: String) {
        var count = 0, cr = false, lf = false, crlf = false, priorCR = false
        utf8.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                if byte & 0xC0 != 0x80 { count += 1 }
                if byte == 13 {
                    if priorCR { cr = true }
                    priorCR = true
                } else {
                    if byte == 10 { if priorCR { crlf = true } else { lf = true } } else if priorCR { cr = true }
                    priorCR = false
                }
            }
        }
        if priorCR { cr = true }
        let endings = [crlf ? "CRLF" : nil, lf ? "LF" : nil, cr ? "CR" : nil].compactMap { $0 }
        return (count, endings.count > 1 ? "Mixed EOL" : endings.first ?? "")
    }
}

private final class StatusBadge: NSButton {
    var activate: ((StatusBadge) -> Void)?
    init(_ text: String) {
        super.init(frame: .zero)
        title = text
        isBordered = false
        bezelStyle = .regularSquare
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        contentTintColor = .secondaryLabelColor
        toolTip = text + " — click for options"
        setButtonType(.momentaryChange)
        target = self
        action = #selector(showOptions)
    }
    @objc private func showOptions() { activate?(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    var preferredWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: font!]).width) + 20 }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.10 : 0.035).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        super.draw(dirtyRect)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class StatusBadgeRow: NSView {
    var onActivate: ((String, NSView) -> Void)?
    private var values: [String] = []
    private var badges: [StatusBadge] = []
    private var identities: [String] = []
    private var measuredWidth: CGFloat = -1
    override var isFlipped: Bool { true }
    func update(_ fields: [String], keys: [String]) {
        var counts: [String: Int] = [:]
        let ids = keys.map { key -> String in
            let n = counts[key, default: 0]
            counts[key] = n + 1
            return "\(key).\(n)"
        }
        guard fields != values || ids != identities else { return }
        let existing = Dictionary(uniqueKeysWithValues: zip(identities, badges))
        let updated = zip(zip(fields, keys), ids).map { entry, id -> StatusBadge in
            let (text, key) = entry
            let badge = existing[id] ?? StatusBadge(text)
            badge.title = text
            badge.toolTip = text + " — click for options"
            badge.identifier = NSUserInterfaceItemIdentifier("status." + id)
            badge.activate = { [weak self] button in self?.onActivate?(key, button) }
            if badge.superview == nil { addSubview(badge) }
            return badge
        }
        for (id, badge) in existing where !ids.contains(id) { badge.removeFromSuperview() }
        values = fields
        identities = ids
        badges = updated
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    private func rows() -> [[StatusBadge]] {
        let width = max(1, bounds.width)
        var result: [[StatusBadge]] = [], row: [StatusBadge] = []
        var used: CGFloat = 0
        for badge in badges {
            let size = min(width, badge.preferredWidth)
            if !row.isEmpty && used + 6 + size > width {
                result.append(row)
                row = []
                used = 0
            }
            if !row.isEmpty { used += 6 }
            row.append(badge)
            used += size
        }
        if !row.isEmpty { result.append(row) }
        return result
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(max(1, rows().count)) * 26 - 4)
    }
    override func layout() {
        super.layout()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        for (index, row) in rows().enumerated() {
            let width =
                row.reduce(CGFloat(0)) { $0 + min(bounds.width, $1.preferredWidth) } + CGFloat(max(0, row.count - 1))
                * 6
            var x = bounds.width - width
            for badge in row {
                let size = min(bounds.width, badge.preferredWidth)
                badge.frame = NSRect(x: x, y: CGFloat(index) * 26, width: size, height: 22)
                x += size + 6
            }
        }
    }
}

/// Each document retains its native window and save lifecycle; only the selected tab is visible.
private final class DocumentTabWindow: NSWindow {
    static var documents: [NSWindow] {
        NSDocumentController.shared.documents.flatMap { $0.windowControllers.compactMap { $0.window } }.filter {
            $0 is DocumentTabWindow
        }
    }
    override func becomeMain() {
        super.becomeMain()
        if let controller = windowController as? EditorWindowController {
            (NSApp.delegate as? AppDelegate)?.lastDocumentController = controller
        }
    }
    // The tabs look like one window, so its red close button closes that whole window: it quits
    // the app, with the usual review of unsaved documents. Closing one tab is the tab's own close
    // button, File > Close and Command-W, which all arrive through performClose.
    private var closingTab = false
    private weak var standardCloseTarget: AnyObject?
    private var standardCloseAction: Selector?
    /// Takes over the red close button once; the button's own behaviour is kept for closing a tab.
    func routeCloseButtonToQuit() {
        guard standardCloseAction == nil, let button = standardWindowButton(.closeButton) else { return }
        standardCloseTarget = button.target
        standardCloseAction = button.action
        button.target = self
        button.action = #selector(closeButtonPressed(_:))
        button.toolTip = "Quit TextTank. Documents with unsaved changes are reviewed first."
    }
    /// True when a press of the red close button quits; false while one tab is being closed.
    var closeButtonQuits: Bool { standardCloseAction != nil && !closingTab }
    @objc private func closeButtonPressed(_ sender: Any?) {
        if closingTab {
            // performClose presses this button on the window's behalf: close just this tab.
            if let action = standardCloseAction { NSApp.sendAction(action, to: standardCloseTarget, from: sender) }
        } else {
            NSApp.terminate(sender)
        }
    }
    override func performClose(_ sender: Any?) {
        closingTab = true
        defer { closingTab = false }
        super.performClose(sender)
    }
    /// The tab to show again when this one closes: set when a background tab is brought forward
    /// only to be closed from its close button, so closing it returns to the tab that was active.
    weak var returnTo: NSWindow?
    override func makeKeyAndOrderFront(_ sender: Any?) {
        // Selecting this tab for any reason ends an earlier, cancelled close-from-background.
        returnTo = nil
        let others = Self.documents.filter { $0 !== self }
        let sharedFrame = others.first(where: { $0.isVisible })?.frame
        others.forEach { $0.orderOut(nil) }
        super.makeKeyAndOrderFront(sender)
        contentView?.layoutSubtreeIfNeeded()
        if let sharedFrame { setFrame(sharedFrame, display: true) }
        (windowController as? EditorWindowController)?.visibilityChanged()
        (windowController as? EditorWindowController)?.refreshStatusDetails()
        if let controller = windowController as? EditorWindowController { makeFirstResponder(controller.activeEditor) }
    }
    override func sendEvent(_ event: NSEvent) {
        // A cancelled close-from-background leaves this tab showing. Once the person works in it
        // (a key or a click that reaches the tab itself, not its review sheet) it is simply the
        // active tab, and closing it later goes to its neighbour.
        if returnTo != nil, attachedSheet == nil,
            [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        {
            returnTo = nil
        }
        super.sendEvent(event)
    }
    // The recurring status refresh runs only while the tab is on screen.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        (windowController as? EditorWindowController)?.visibilityChanged()
    }
    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        (windowController as? EditorWindowController)?.visibilityChanged()
    }
    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        (windowController as? EditorWindowController)?.visibilityChanged()
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        (windowController as? EditorWindowController)?.visibilityChanged()
    }
    override func close() {
        let wasVisible = isVisible
        let closingFrame = frame
        // The tab that was active before a close-from-background, otherwise the neighbour: the
        // next tab, or the previous one when this is the last.
        let all = Self.documents
        var next = all.first { $0 !== self }
        if let returnTo, returnTo !== self, all.contains(where: { $0 === returnTo }) {
            next = returnTo
        } else if let index = all.firstIndex(where: { $0 === self }) {
            next = index + 1 < all.count ? all[index + 1] : index > 0 ? all[index - 1] : nil
        }
        returnTo = nil
        super.close()
        if wasVisible {
            next?.makeKeyAndOrderFront(nil)
            // Ordering a hidden window can apply AppKit's screen constraints.
            // Restore the shared frame after that layout transition, as on tab selection.
            next?.contentView?.layoutSubtreeIfNeeded()
            next?.setFrame(closingFrame, display: true)
        }
    }
}
private final class DocumentTabButton: NSButton {
    weak var documentWindow: NSWindow?
}
private final class DocumentTabBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: isFlipped ? bounds.height - 3 : 0, width: bounds.width, height: 3).fill()
    }
}

private final class DocumentTabStrip: NSView {
    private let scroll = NSScrollView()
    private let row = NSView()
    private var signature = ""
    weak var owner: NSWindow?
    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = row
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    override func layout() {
        super.layout()
        scroll.frame = bounds
    }
    func refresh() {
        guard let owner else { return }
        let windows = DocumentTabWindow.documents
        let key = windows.map { "\(ObjectIdentifier($0)):\($0.title):\($0.isDocumentEdited):\($0 === owner)" }.joined(
            separator: "|")
        guard key != signature else { return }
        signature = key
        row.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        var activeRect = NSRect.zero
        for window in windows {
            let title = window.title + (window.isDocumentEdited ? "  •" : "")
            let width = min(
                220,
                max(
                    130,
                    ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 66))
            let button = DocumentTabButton(title: title, target: self, action: #selector(selectTab(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: window === owner ? .semibold : .regular)
            button.alignment = .left
            button.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = window.title
            button.setAccessibilityLabel(
                window.title + (window.isDocumentEdited ? ", edited" : "")
                    + (window === owner ? ", active tab" : ", tab"))
            button.documentWindow = window
            button.frame = NSRect(x: x + 8, y: 0, width: width - 34, height: 36)
            // The highlighted area includes the close control.
            if window === owner {
                let cell = DocumentTabBackground(frame: NSRect(x: x, y: 0, width: width, height: 36))
                activeRect = cell.frame
                row.addSubview(cell)
            }
            row.addSubview(button)
            let close = DocumentTabButton(
                image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(window.title)")!,
                target: self, action: #selector(closeTab(_:)))
            close.isBordered = false
            close.documentWindow = window
            close.frame = NSRect(x: x + width - 26, y: 7, width: 22, height: 22)
            close.toolTip = "Close \(window.title)"
            row.addSubview(close)
            x += width
        }
        let add = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")!, target: self,
            action: #selector(newTab(_:)))
        add.isBordered = false
        add.contentTintColor = .controlAccentColor
        add.toolTip = "New tab (⌘N)"
        add.identifier = NSUserInterfaceItemIdentifier("tab.new")
        add.frame = NSRect(x: x + 4, y: 3, width: 32, height: 30)
        row.addSubview(add)
        row.frame = NSRect(x: 0, y: 0, width: x + 40, height: 36)
        row.scrollToVisible(activeRect)
    }
    @objc private func selectTab(_ sender: NSButton) {
        guard owner != nil else { return }
        let windows = DocumentTabWindow.documents
        guard let target = (sender as? DocumentTabButton)?.documentWindow, windows.contains(where: { $0 === target })
        else { return }
        target.makeKeyAndOrderFront(nil)
    }
    @objc private func closeTab(_ sender: NSButton) {
        guard owner != nil else { return }
        let windows = DocumentTabWindow.documents
        guard let target = (sender as? DocumentTabButton)?.documentWindow,
            windows.contains(where: { $0 === target })
        else { return }
        // A background tab is brought forward first, so that unsaved changes are reviewed on a
        // visible window; once it has closed, the tab that was active is shown again.
        let active = target === owner ? nil : owner
        target.makeKeyAndOrderFront(nil)
        (target as? DocumentTabWindow)?.returnTo = active
        target.performClose(sender)
    }
    @objc private func newTab(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.newDocument(sender) }
}

extension TextDocument {
    /// The view of this document the person last worked in: the focused pane of a split view,
    /// otherwise the primary view. Exactly one view per document.
    var activeEditor: TTEditor { (windowControllers.first as? EditorWindowController)?.activeEditor ?? editor }
}

/// File > Open Recent, filled from the system's recent-documents list each time it opens.
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        // Two files with the same name are told apart by their folder.
        let names = Dictionary(grouping: urls, by: \.lastPathComponent)
        for url in urls {
            let duplicate = (names[url.lastPathComponent]?.count ?? 0) > 1
            let item = NSMenuItem(
                title: url.lastPathComponent
                    + (duplicate ? " — \(url.deletingLastPathComponent().lastPathComponent)" : ""),
                action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(
            title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = NSDocumentController.shared
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }
    /// No item here has a key equivalent, so a key press never needs the list rebuilt.
    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool { false }
    @objc func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error, (error as NSError).code != NSUserCancelledError { NSApp.presentError(error) }
        }
    }
}

final class EditorWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation, NSSearchFieldDelegate {
    let split = NSSplitView()
    let findField = NSSearchField()
    let replaceField = NSTextField()
    let caseBox = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let findNextButton = NSButton(title: "Next", target: nil, action: nil)
    let replaceMatchButton = NSButton(title: "Replace Selection", target: nil, action: nil)
    private(set) var findBar: NSView?
    private var splitBelowFindBar: NSLayoutConstraint?
    private var splitBelowTabs: NSLayoutConstraint?
    var findBarVisible: Bool { findBar?.isHidden == false }
    let status = NSTextField(labelWithString: "Ready · Incomplete preview")
    private let statusDetails = StatusBadgeRow()
    private let documentTabs = DocumentTabStrip()
    private var statusTimer: Timer?
    /// Nil when the caller supplies timer ticks itself. The normal window polls every 0.2 s;
    /// checks can drive the exact same tick path without depending on run-loop scheduling speed.
    var statusTimerInterval: TimeInterval? = 0.2
    /// True while the recurring refresh is scheduled, which is only while the window is on screen.
    var statusTimerActive: Bool { statusTimer != nil }
    #if TESTING
        /// Drops the timer without any visibility change, as a lost timer would look.
        func stopStatusTimerForChecks() {
            statusTimer?.invalidate()
            statusTimer = nil
        }
    #endif
    private var statusClosed = false
    private var inlineSearchGeneration = UUID()
    private var inlineCancellation: TTSearchCancellation?
    private(set) var inlineSearchPending = false
    private var stateObserver: NSObjectProtocol?
    private var visibilityObservers: [NSObjectProtocol] = []
    private(set) var statusRefreshCount = 0
    /// Whole-document captures started for the character count and line-ending badges.
    private(set) var statusMetricsCaptureCount = 0
    private var statusRevision: UInt?
    /// The revision the previous timer tick saw; a recurring refresh captures the document only
    /// once the revision has stayed the same for a whole tick.
    private var statusTickRevision: UInt?
    private var statusMetricsPending = false
    private var cachedCharacterCount = 0
    private struct SelectionKey: Equatable {
        let editor: ObjectIdentifier
        let revision: UInt, generation: UInt
        let count: Int, anchor: Int, caret: Int
    }
    private var cachedSelectionKey: SelectionKey?
    private var cachedSelectedCount = 0
    private var cachedEndings = "LF"
    var secondary: TTEditor?
    /// The pane focused last. Written when the window's first responder moves into a pane, by
    /// each view's onFocus (see `wire`) and by closeSplit.
    weak var lastEditor: TTEditor?
    /// Scintilla reports focus only while the window is key and the application active, so the
    /// first responder is observed as well: a pane chosen in a background window still counts.
    var focusObservation: NSKeyValueObservation?
    var automationObserver: NSObjectProtocol?
    let primaryEditor: TTEditor
    /// The primary view and, while the window is split, the clone.
    var views: [TTEditor] { [primaryEditor] + (secondary.map { [$0] } ?? []) }
    /// The pane that holds the first responder, otherwise the pane focused last (focus may be
    /// in the find field or another window). A pure read.
    var activeEditor: TTEditor {
        if let responder = window?.firstResponder as? NSView,
            let focused = views.last(where: { responder.isDescendant(of: $0) })
        {
            return focused
        }
        return lastEditor ?? primaryEditor
    }
    /// Per-view wiring shared by the primary view and a clone.
    private func wire(_ editor: TTEditor) {
        editor.onFocus = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.lastEditor = editor
            self.updateInlineFindValidation()
            let app = NSApp.delegate as? AppDelegate
            app?.lastDocumentController = self
            app?.macros.editorDidFocus(editor)
        }
        editor.menu = (NSApp.delegate as? AppDelegate)?.automations.contextMenu()
    }
    /// Copies the active pane's syntax styles to the other pane after a language or style
    /// change. The lexer itself belongs to the shared document and is never applied twice.
    func syncPaneStyles(from source: TTEditor) {
        for view in views where view !== source { view.adoptSyntaxStyles(from: source) }
    }
    init(document: TextDocument) {
        primaryEditor = document.editor
        let window = DocumentTabWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        lastEditor = document.editor
        wire(document.editor)
        focusObservation = window.observe(\.firstResponder) { [weak self] window, _ in
            guard let self, let responder = window.firstResponder as? NSView,
                let pane = self.views.last(where: { responder.isDescendant(of: $0) })
            else { return }
            self.lastEditor = pane
            self.updateInlineFindValidation()
        }
        if let app = NSApp.delegate as? AppDelegate {
            app.settings.apply(to: document.editor)
            let toolbar = NSToolbar(identifier: "TextTankToolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            automationObserver = NotificationCenter.default.addObserver(
                forName: .textTankAutomationsDidChange, object: app.automations, queue: .main
            ) { [weak self] _ in self?.refreshAutomationToolbar() }
        }
        window.title = "TextTank"
        window.center()
        window.tabbingMode = .disallowed
        // Tabs are separate windows of which one is shown. A full-screen window cannot be
        // swapped for another that way, so the tab windows do not enter full screen.
        window.collectionBehavior.insert(.fullScreenNone)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = false
        }
        window.routeCloseButtonToQuit()
        window.contentMinSize = NSSize(width: 800, height: 500)
        let root = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        window.contentView = root
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(document.editor)
        findField.placeholderString = "Find literal text"
        replaceField.placeholderString = "Replace with"
        findNextButton.target = self
        findNextButton.action = #selector(findNext(_:))
        findNextButton.setAccessibilityLabel("Find next match in document")
        replaceMatchButton.target = self
        replaceMatchButton.action = #selector(replaceSelection(_:))
        replaceMatchButton.setAccessibilityLabel("Replace selected match in document")
        let doneButton = NSButton(title: "Done", target: self, action: #selector(hideFind(_:)))
        let search = NSStackView(views: [
            findField, replaceField, caseBox, findNextButton, replaceMatchButton, doneButton
        ])
        search.spacing = 8
        // Return in the field finds the next match, Shift-Return the previous one, Escape closes.
        findField.delegate = self
        replaceField.delegate = self
        caseBox.target = self
        caseBox.action = #selector(inlineFindOptionsChanged(_:))
        findField.target = self
        findField.action = #selector(findFieldAction(_:))
        findField.sendsWholeSearchString = true
        findField.setAccessibilityLabel("Find in document")
        replaceField.setAccessibilityLabel("Replace selection with")
        // The bar is out of the way until Find is chosen, so the text is the window's main surface.
        search.isHidden = true
        findBar = search
        documentTabs.owner = window
        [documentTabs, search, split, status, statusDetails].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            documentTabs.topAnchor.constraint(equalTo: root.topAnchor),
            documentTabs.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            documentTabs.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            documentTabs.heightAnchor.constraint(equalToConstant: 36),
            search.topAnchor.constraint(equalTo: documentTabs.bottomAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            replaceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusDetails.topAnchor, constant: -5),
            statusDetails.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusDetails.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusDetails.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -2),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
        splitBelowFindBar = split.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10)
        splitBelowTabs = split.topAnchor.constraint(equalTo: documentTabs.bottomAnchor)
        splitBelowTabs?.isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        statusDetails.onActivate = { [weak self] key, view in self?.showStatusOptions(key, at: view) }
        // Editor events make the bar follow an edit or a selection change in the same turn of
        // the run loop; the timer started by visibilityChanged() covers state no event reports.
        stateObserver = NotificationCenter.default.addObserver(
            forName: .TTEditorStateDidChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, !self.statusClosed, let editor = note.object as? TTEditor else { return }
            if editor === self.primaryEditor || editor === self.secondary {
                self.updateInlineFindValidation()
                if self.window?.isVisible == true { self.refreshStatusDetails(source: .editorEvent) }
            } else if self.window?.isVisible == true {
                // Another document changed: only its title in this window's tab strip can differ.
                self.documentTabs.refresh()
            }
        }
        // Minimising and restoring a window changes isVisible without any order call.
        visibilityObservers = [
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification
        ].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: nil) { [weak self] _ in
                self?.visibilityChanged()
            }
        }
        visibilityChanged()
        refreshStatusDetails(for: document)
        updateInlineFindValidation()
        // The first document window opens where the last one was left. A later tab takes the
        // frame of the visible tab when it is shown, which replaces whatever is applied here.
        // This comes last: the title bar and toolbar set up above change the window's height.
        WindowFrames.track(window, as: "TextTank.Document")
    }
    private func removeVisibilityObservers() {
        visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
        visibilityObservers = []
    }
    /// Starts the recurring status refresh when the window comes on screen and stops it when the
    /// window leaves, so a hidden tab has no timer at all.
    func visibilityChanged() {
        let visible = window?.isVisible == true && !statusClosed && statusTimerInterval != nil
        if !visible {
            statusTimer?.invalidate()
            statusTimer = nil
            return
        }
        guard statusTimer == nil else { return }
        let timer = Timer(timeInterval: statusTimerInterval ?? 0.2, repeats: true) { [weak self] _ in
            self?.statusTimerTick()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .default)
        statusTimer = timer
    }
    /// One polling tick. Kept separate from Timer so checks can insert an edit before every tick
    /// and an idle tick after the last edit, even on a busy runner.
    func statusTimerTick() {
        guard window?.isVisible == true else {
            visibilityChanged()
            return
        }
        refreshStatusDetails(source: .pollingTick)
        statusTickRevision = (document as? TextDocument)?.editor.revision
    }
    /// A failed recovery write is shown in red with a tooltip as well as in words, and stays
    /// until the document reports a successful write.
    private var transientStatus: String?
    /// Says why something the person just did had no effect, in the status line for a few seconds
    /// and to assistive technology, then shows the save state again. A standing recovery failure
    /// is never replaced.
    func showTransientStatus(_ message: String, seconds: TimeInterval = 4, announce: Bool = true) {
        guard transientStatus != message else { return }
        if announce { Announce.say(message, from: window) }
        guard let doc = document as? TextDocument, doc.lastRecoveryError == nil else { return }
        transientStatus = message
        status.stringValue = message
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak doc] in
            guard let self, self.transientStatus == message else { return }
            self.transientStatus = nil
            if let doc, doc.lastRecoveryError == nil { self.status.stringValue = doc.currentSaveStateStatus }
        }
    }
    func showRecoveryStatus(_ message: String, failed: Bool) {
        transientStatus = nil
        if failed, status.stringValue != message { Announce.say(message, from: window) }
        status.stringValue = message
        // The failure is carried by the words and the symbol; full-strength label colour keeps it
        // readable in both appearances, where small red text was not.
        status.textColor = failed ? .labelColor : .secondaryLabelColor
        status.font = failed ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
        status.toolTip =
            failed
            ? "Crash-recovery copies of this document are not being written. Save the document to keep your work. This message clears when a recovery copy is written again."
            : nil
    }
    enum StatusRefreshSource {
        case explicit, editorEvent, pollingTick
    }
    /// Updates the cheap badges immediately. Only a polling tick can recognize an idle interval;
    /// a queued editor event after the tick observed an edit is not an idle observation (V32-01).
    /// Explicit action refreshes keep their immediate metrics capture.
    func refreshStatusDetails(for suppliedDocument: TextDocument? = nil, source: StatusRefreshSource = .explicit) {
        guard let doc = suppliedDocument ?? document as? TextDocument else { return }
        statusRefreshCount += 1
        // Any refresh in a window on screen restarts a missing timer, the editor-event path included.
        if statusTimer == nil { visibilityChanged() }
        documentTabs.refresh()
        let editor = activeEditor, info = editor.statusInfo
        let revision = doc.editor.revision
        let allowsMetricsCapture =
            source == .explicit || (source == .pollingTick && statusTickRevision == revision)
        if statusRevision != revision && !statusMetricsPending && allowsMetricsCapture {
            // Capture the authoritative bytes in one copy on main; the scan happens off-main.
            // One in-flight task bounds work for rapid edits.
            let bytes = doc.editor.utf8Data
            statusMetricsPending = true
            statusMetricsCaptureCount += 1
            DispatchQueue.global(qos: .utility).async { [weak self, weak doc] in
                let (count, eol) = StatusMetrics.scan(bytes)
                DispatchQueue.main.async { [weak self, weak doc] in
                    guard let self else { return }
                    self.statusMetricsPending = false
                    guard let doc, self.document === doc, doc.editor.revision == revision else { return }
                    self.cachedCharacterCount = count
                    self.cachedEndings = eol
                    self.statusRevision = revision
                    if self.window?.isVisible == true { self.refreshStatusDetails() }
                }
            }
        }
        let encoding: [FileEncoding: String] = [
            .utf8: "UTF-8", .utf16LE: "UTF-16 LE", .utf16BE: "UTF-16 BE", .windows1252: "Windows-1252",
            .latin1: "Latin-1"
        ]
        let language =
            (NSApp.delegate as? AppDelegate)?.languages.profile(identifier: doc.languageIdentifier)?.title
            ?? (doc.languageIdentifier == LanguageProfile.plainTextID ? "Plain Text" : doc.languageIdentifier)
        let eol =
            cachedEndings.isEmpty ? ([0: "CRLF", 1: "CR", 2: "LF"][info["eol"]?.intValue ?? 2] ?? "LF") : cachedEndings
        let indentation =
            (info["useTabs"]?.boolValue == true ? "Tabs" : "Spaces") + ": \(info["tabWidth"]?.intValue ?? 4)"
        // VoiceOver names each text area after its document, and after its pane in a split view.
        for (index, pane) in views.enumerated() {
            let name =
                (doc.displayName ?? "Untitled")
                + (views.count > 1 ? (index == 0 ? ", first pane" : ", second pane") : "")
            if pane.accessibilityDocumentName != name { pane.accessibilityDocumentName = name }
        }
        var fields = [
            doc.displayName + (doc.isDocumentEdited ? " *" : ""), "\(doc.editor.bookmarkCount) Bookmarks",
            language,
            "Ln \(info["line"]?.intValue ?? 1), Col \(info["column"]?.intValue ?? 1)", "\(cachedCharacterCount) chars",
            "\(info["lines"]?.intValue ?? 1) lines"
        ]
        // The generation changes with every edit, every bridge call that can move a selection
        // and every selection update Scintilla reports; the main range is compared as well.
        let selectionKey = SelectionKey(
            editor: ObjectIdentifier(editor), revision: revision, generation: editor.selectionGeneration,
            count: editor.selectionCount, anchor: editor.selectionAnchor, caret: editor.selectionCaret)
        if cachedSelectionKey != selectionKey {
            cachedSelectedCount = editor.selectedCharacterCount
            cachedSelectionKey = selectionKey
        }
        var keys = ["document", "bookmarks", "language", "position", "count", "count"]
        if cachedSelectedCount > 0 {
            fields.append("\(cachedSelectedCount) selected")
            keys.append("selection")
        }
        if editor.selectionCount > 1 {
            fields.append("\(editor.selectionCount) selections")
            keys.append("selection")
        }
        fields += [
            String(format: "Base %g pt", info["fontSize"]?.doubleValue ?? 14), indentation,
            (encoding[doc.format.encoding] ?? "UTF-8") + (doc.format.bom ? " BOM" : ""), eol,
            editor.wrap ? "Wrap" : "No Wrap"
        ]
        keys += ["font", "indent", "encoding", "eol", "wrap"]
        if editor.readOnly {
            fields.append("Read Only")
            keys.append("document")
        }
        statusDetails.update(fields, keys: keys)
    }
    private func showStatusOptions(_ key: String, at view: NSView) {
        let editor = activeEditor
        (NSApp.delegate as? AppDelegate)?.lastDocumentController = self
        lastEditor = editor
        guard let menu = statusOptionsMenu(key) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
        refreshStatusDetails()
    }
    /// The menu a status bar field opens, for the active pane. Building it changes nothing, so
    /// its wording can be checked without showing it.
    func statusOptionsMenu(_ key: String) -> NSMenu? {
        guard let doc = document as? TextDocument else { return nil }
        let editor = activeEditor, info = editor.statusInfo
        let app = NSApp.delegate as? AppDelegate
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(
            _ title: String, _ action: Selector, _ target: AnyObject, _ value: String? = nil, _ checked: Bool = false,
            _ enabled: Bool = true
        ) {
            menu.addItem(
                title: title, action: action, target: target, representedObject: value,
                isEnabled: enabled, state: checked ? .on : .off)
        }
        func heading(_ title: String) {
            menu.addItem(title: title, action: nil, isEnabled: false)
        }
        switch key {
        case "encoding":
            heading("Re-read using encoding…")
            let options: [(String, String)] = [
                ("UTF-8", "utf8"), ("UTF-16 LE", "utf16LE"), ("UTF-16 BE", "utf16BE"), ("Latin-1", "latin1"),
                ("Windows-1252", "windows1252")
            ]
            for (name, code) in options {
                add(
                    name, #selector(TextDocument.reloadEncoding(_:)), doc, code, doc.format.encoding.rawValue == code,
                    doc.fileURL != nil)
            }
            menu.addItem(.separator())
            heading("Convert document encoding (save separately)")
            for (name, code) in [
                ("UTF-8", "utf8"), ("UTF-8 with BOM", "utf8bom"), ("UTF-16 LE with BOM", "utf16LE"),
                ("UTF-16 BE with BOM", "utf16BE"), ("Latin-1", "latin1"), ("Windows-1252", "windows1252")
            ] {
                let current = doc.format.encoding == .utf8 && doc.format.bom ? "utf8bom" : doc.format.encoding.rawValue
                add(name, #selector(TextDocument.convertEncoding(_:)), doc, code, current == code, !editor.readOnly)
            }
        case "indent":
            heading("Indentation for this document")
            add("Tabs", #selector(statusOption(_:)), self, "tabs", info["useTabs"]?.boolValue == true)
            add("Spaces", #selector(statusOption(_:)), self, "spaces", info["useTabs"]?.boolValue == false)
            menu.addItem(.separator())
            for n in [2, 3, 4, 8] {
                add("Width: \(n)", #selector(statusOption(_:)), self, "width.\(n)", info["tabWidth"]?.intValue == n)
            }
            if let settings = app?.settings {
                menu.addItem(.separator())
                add("Default Editor Settings…", #selector(SettingsController.showSettings(_:)), settings)
            }
        case "eol":
            heading("Convert document line endings")
            for (name, code) in [("LF — Unix / macOS", "LF"), ("CRLF — Windows", "CRLF"), ("CR — Classic Mac", "CR")] {
                let current =
                    cachedEndings.isEmpty ? [0: "CRLF", 1: "CR", 2: "LF"][info["eol"]?.intValue ?? 2] : cachedEndings
                add(name, #selector(convertEOL(_:)), self, code, current == code, !editor.readOnly)
            }
        case "wrap":
            add("Wrap Lines", #selector(statusOption(_:)), self, "wrap.on", editor.wrap)
            add("No Wrap", #selector(statusOption(_:)), self, "wrap.off", !editor.wrap)
        case "font":
            heading("Text size for this view")
            add("Larger", #selector(statusOption(_:)), self, "zoomIn")
            add("Smaller", #selector(statusOption(_:)), self, "zoomOut")
            if let languages = app?.languages {
                menu.addItem(.separator())
                menu.addItem(languages.styleSettingsMenuItem())
            }
        case "language":
            if let languages = app?.languages {
                for item in languages.languageMenuItems() {
                    item.state = (item.representedObject as? String) == doc.languageIdentifier ? .on : .off
                    menu.addItem(item)
                }
            }
        case "bookmarks":
            for (name, code) in [
                ("Toggle Bookmark on Current Line", "bookmarkToggle"), ("Next Bookmark", "bookmarkNext"),
                ("Previous Bookmark", "bookmarkPrevious")
            ] { add(name, #selector(statusOption(_:)), self, code) }
        case "position":
            add("Go to Line…", #selector(statusOption(_:)), self, "goToLine")
        case "document":
            add("Save…", #selector(NSDocument.save(_:)), doc)
            add("Save As…", #selector(NSDocument.saveAs(_:)), doc)
            add("Read Only", #selector(TextDocument.toggleReadOnly(_:)), doc, nil, editor.readOnly)
        default:
            add("Select All", #selector(statusOption(_:)), self, "selectAll")
            add("Clear Selection", #selector(statusOption(_:)), self, "clearSelection")
        }
        return menu
    }
    /// F277: neither jump has a recordable step, so a recording is discarded when the caret or the
    /// selection actually moves, and not for a cancelled dialog, a line that does not exist or a
    /// selection that was already empty.
    static func goToLine(_ line: Int, in editor: TTEditor, macros: MacroController?) -> Bool {
        guard let macros else { return editor.goToLine(line) }
        return macros.unrecordedJump(in: editor, reason: "Go to Line is not recorded in macros yet.") {
            editor.goToLine(line)
        }
    }
    @discardableResult static func clearSelection(in editor: TTEditor, macros: MacroController?) -> Bool {
        let clear = { editor.setSelectionAnchor(editor.selectionCaret, caret: editor.selectionCaret) }
        guard let macros else { return clear() }
        return macros.unrecordedJump(
            in: editor, reason: "Clear Selection is not recorded in macros yet.", clear)
    }
    @objc private func statusOption(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let editor = activeEditor, info = editor.statusInfo
        switch id {
        case "tabs", "spaces": editor.configureTabWidth(info["tabWidth"]?.intValue ?? 4, useTabs: id == "tabs")
        case "wrap.on", "wrap.off": editor.wrap = id == "wrap.on"
        case "clearSelection": Self.clearSelection(in: editor, macros: (NSApp.delegate as? AppDelegate)?.macros)
        case "goToLine": goToLine(sender)
        default:
            if id.hasPrefix("width."), let width = Int(id.dropFirst(6)) {
                editor.configureTabWidth(width, useTabs: info["useTabs"]?.boolValue ?? true)
            } else {
                do { try perform(command: id) } catch { TTAlert.explain(error) }
            }
        }
        refreshStatusDetails()
    }
    /// Search > Go to Line… and the position field of the status bar.
    @objc func goToLine(_ sender: Any?) {
        let editor = activeEditor
        let alert = TTAlert()
        alert.messageText = "Go to Line"
        let input = NSTextField(string: String(editor.statusInfo["line"]?.intValue ?? 1))
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        input.identifier = NSUserInterfaceItemIdentifier("goToLine.line")
        input.setAccessibilityLabel("Line number")
        alert.accessoryView = input
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The engine's own line model decides which lines exist; a folded target is revealed.
        guard editor.window != nil else { return }
        guard let line = Int(input.stringValue),
            Self.goToLine(line, in: editor, macros: (NSApp.delegate as? AppDelegate)?.macros)
        else {
            TTAlert.explain(
                Int(input.stringValue) == nil
                    ? "Enter a whole line number" : "There is no line \(input.stringValue)",
                detail: "Enter a line number from 1 to \(editor.statusInfo["lines"]?.intValue ?? 1).")
            return
        }
        window?.makeFirstResponder(editor)
        refreshStatusDetails()
    }
    /// Puts the caret at the start of a line, counted from 1, on the engine's own line model.
    /// False, with nothing changed, for a line the document does not have or a view that has
    /// left its window. Does not touch a macro recording; the dialog passes the recorder.
    static func goToLine(_ line: Int, in editor: TTEditor) -> Bool {
        guard editor.window != nil else { return false }
        return goToLine(line, in: editor, macros: nil)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // No Close Tab item: every tab has its own close button, and Command-W closes the current one.
        [.flexibleSpace, .init("TextTank.Automations")]
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar: Bool
    ) -> NSToolbarItem? {
        guard let automations = (NSApp.delegate as? AppDelegate)?.automations else { return nil }
        return identifier.rawValue == "TextTank.Automations"
            ? automations.makeToolbarItem() : automations.makeToolbarItem(identifier: identifier)
    }
    func refreshAutomationToolbar() {
        guard let toolbar = window?.toolbar else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, id) in toolbarDefaultItemIdentifiers(toolbar).enumerated() {
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
    }
    func prepareForClose() {
        cancelInlineSearch()
        statusClosed = true
        updateInlineFindValidation()
        statusTimer?.invalidate()
        statusTimer = nil
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
            self.stateObserver = nil
        }
        removeVisibilityObservers()
        if let automationObserver {
            NotificationCenter.default.removeObserver(automationObserver)
            self.automationObserver = nil
        }
        focusObservation?.invalidate()
        focusObservation = nil
        // TextDocument.close has already made the shared document read-only for both panes.
        primaryEditor.onFocus = nil
        secondary?.onFocus = nil
        primaryEditor.onReadOnlyAttempt = nil
        secondary?.onReadOnlyAttempt = nil
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    @objc func command(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if (NSApp.modalWindow ?? NSApp.keyWindow)?.firstResponder is NSTextView {
            // Native editing selectors reach the field directly; this is only the custom-command path.
            NSSound.beep()
            return
        }
        do { try perform(command: id) } catch { TTAlert.present(error) }
    }
    /// Runs one editor command on the active editor. A command that edits text is refused with the
    /// read-only reason before anything else happens, so a macro recording is left as it was.
    func perform(command id: String) throws {
        let editor = activeEditor
        if id.hasPrefix("transform."), let transform = EditorTransform(rawValue: String(id.dropFirst(10))) {
            try editor.requireWritable()
            (NSApp.delegate as? AppDelegate)?.macros.invalidateRecording(
                reason: "This text transform is not yet recorded.")
            try transform.apply(to: editor)
            return
        }
        if TTEditor.commandModifiesText(id) { try editor.requireWritable() }
        (NSApp.delegate as? AppDelegate)?.macros.willExecuteCommand(id, on: editor)
        editor.executeCommand(id)
    }
    deinit {
        statusTimer?.invalidate()
        focusObservation?.invalidate()
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let automationObserver { NotificationCenter.default.removeObserver(automationObserver) }
    }
    private func setFindBar(visible: Bool) {
        guard let findBar, findBar.isHidden == visible else { return }
        splitBelowTabs?.isActive = !visible
        findBar.isHidden = !visible
        splitBelowFindBar?.isActive = visible
    }
    /// The text other apps and the Find and Replace window last searched for.
    #if TESTING
        /// Checks never read or write the Mac's shared find pasteboard.
        static var findPasteboardText = ""
    #else
        static var findPasteboardText: String {
            get { NSPasteboard(name: .find).string(forType: .string) ?? "" }
            set {
                let board = NSPasteboard(name: .find)
                board.clearContents()
                board.setString(newValue, forType: .string)
            }
        }
    #endif
    /// The advanced window and inline bar share the query without scheduling another search.
    func acceptSharedFindText(_ text: String) {
        cancelInlineSearch()
        findField.stringValue = text
        updateInlineFindValidation()
    }
    @objc func showFind(_ sender: Any?) {
        cancelInlineSearch()
        // Remember the pane the find bar acts on before focus leaves it.
        lastEditor = activeEditor
        setFindBar(visible: true)
        if findField.stringValue.isEmpty { findField.stringValue = Self.findPasteboardText }
        window?.makeFirstResponder(findField)
        findField.selectText(nil)
        updateInlineFindValidation()
    }
    @objc func hideFind(_ sender: Any?) {
        cancelInlineSearch()
        let editor = activeEditor
        setFindBar(visible: false)
        window?.makeFirstResponder(editor)
    }
    /// Command-E: the selected text becomes the text to find, here and in other apps.
    @objc func useSelectionForFind(_ sender: Any?) {
        cancelInlineSearch()
        let selected = activeEditor.selectedText
        guard !selected.isEmpty, !selected.contains(where: \.isNewline) else {
            NSSound.beep()
            showTransientStatus("Select text on one line to use it for Find.")
            return
        }
        findField.stringValue = selected
        Self.findPasteboardText = selected
        (NSApp.delegate as? AppDelegate)?.searchController.queryField.stringValue = selected
        updateInlineFindValidation()
    }
    /// Find Next and Find Previous from the menu. With nothing to find yet, the bar opens instead.
    func findFromMenu(backwards: Bool) {
        if findField.stringValue.isEmpty { findField.stringValue = Self.findPasteboardText }
        guard !findField.stringValue.isEmpty else {
            showFind(nil)
            return
        }
        performFind(backwards: backwards)
    }
    @objc func findFieldAction(_ sender: Any?) {
        // The search field also sends its action when its text is cleared.
        guard !findField.stringValue.isEmpty else { return }
        performFind(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true, focusEditor: false)
    }
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === findField || field === replaceField {
            cancelInlineSearch()
        }
    }
    @objc private func inlineFindOptionsChanged(_ sender: Any?) { cancelInlineSearch() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === findField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hideFind(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            findFieldAction(nil)
            return true
        }
        return false
    }
    @objc func findNext(_ sender: Any?) { performFind(backwards: false) }
    func performFind(backwards: Bool, focusEditor: Bool = true) {
        beginInlineSearch(action: backwards ? "previous" : "next", focusEditor: focusEditor)
    }
    @objc func replaceSelection(_ sender: Any?) {
        do { try replaceSelectionFromBar() } catch { TTAlert.explain(error) }
    }
    /// Replacing is strict: a caret, several selections or text that is not a match is never inserted into.
    func replaceSelectionFromBar() throws {
        let editor = activeEditor
        try editor.requireWritable()
        guard editor.selectionCount == 1, editor.selectionStart < editor.selectionEnd else {
            cancelInlineSearch()
            showTransientStatus("Select one match of the Find text before replacing it.")
            return
        }
        beginInlineSearch(action: "replaceOne", focusEditor: true)
    }
    /// Only metadata and bounded field prefixes are read here; validation never captures document text
    /// or runs a search. A selected range can still fail the worker's exact-match/revision checks.
    private func updateInlineFindValidation() {
        let editor = activeEditor
        let query = findField.stringValue
        let ready =
            !statusClosed && !inlineSearchPending && !query.isEmpty && query.utf16.prefix(65_537).count <= 65_536
        findNextButton.isEnabled = ready
        replaceMatchButton.isEnabled =
            ready && !editor.readOnly && editor.selectionCount == 1
            && editor.selectionStart < editor.selectionEnd
            && replaceField.stringValue.utf16.prefix(1_048_577).count <= 1_048_576
    }
    private func cancelInlineSearch() {
        inlineCancellation?.cancel()
        inlineCancellation = nil
        inlineSearchGeneration = UUID()
        inlineSearchPending = false
        updateInlineFindValidation()
    }
    /// Only scheduling and feedback belong to the bar. SearchController owns engine, navigation and replacement.
    private func beginInlineSearch(action: String, focusEditor: Bool) {
        let editor = activeEditor
        // Menu/button actions commit the field editor and restore typing to the document. Return
        // keeps the field editor, so repeated Return and Shift-Return continue to work (DS-35).
        if focusEditor { window?.makeFirstResponder(editor) }
        var captured = SearchOptions()
        captured.query = findField.stringValue
        captured.replacement = action == "replaceOne" ? replaceField.stringValue : ""
        captured.matchCase = caseBox.state == .on
        let options = captured
        cancelInlineSearch()
        guard !options.query.isEmpty, let delegate = NSApp.delegate as? AppDelegate, let capturedWindow = window else {
            return
        }
        Self.findPasteboardText = options.query
        delegate.searchController.queryField.stringValue = options.query
        let token = inlineSearchGeneration, flag = TTSearchCancellation()
        inlineCancellation = flag
        inlineSearchPending = true
        updateInlineFindValidation()
        delegate.searchController.performInline(
            options: options, action: action, on: editor, cancellation: flag,
            isCurrent: { [weak self, weak editor, weak capturedWindow] in
                guard let self, let editor, let capturedWindow else { return false }
                return !self.statusClosed && self.inlineSearchGeneration == token && self.window === capturedWindow
                    && self.activeEditor === editor && self.findField.stringValue.utf8.elementsEqual(options.query.utf8)
                    && (self.caseBox.state == .on) == options.matchCase
                    && (action != "replaceOne"
                        || self.replaceField.stringValue.utf8.elementsEqual(options.replacement.utf8))
            },
            completion: { [weak self, weak editor] result in
                guard let self, self.inlineSearchGeneration == token else { return }
                self.inlineSearchPending = false
                self.inlineCancellation = nil
                self.updateInlineFindValidation()
                switch result {
                case .applied:
                    guard let editor else { return }
                    delegate.macros.recordSearch(.init(options: options, action: action), editor: editor)
                    if action == "replaceOne" {
                        self.showTransientStatus("Replaced the selected match. Undo restores it.")
                    }
                case .noMatch:
                    NSSound.beep()
                    if action == "replaceOne" {
                        self.showTransientStatus("Select one match of the Find text before replacing it.")
                    } else {
                        let query = options.query
                        self.showTransientStatus(
                            "No matches for “\(query.count > 60 ? String(query.prefix(60)) + "…" : query)”.")
                    }
                case .stale:
                    self.showTransientStatus("The document, selection or Find text changed. Search again.")
                case .cancelled: break
                case .failed(let error): self.showTransientStatus(error.localizedDescription)
                }
            })
    }
    @objc func clone(_ sender: Any?) {
        guard secondary == nil else { return }
        let source = primaryEditor
        let clone = TTEditor(frame: split.bounds)
        // Everything document-level (text, read-only, tab settings, lexer and keyword lists,
        // undo) arrives with the shared document and is not written again here. The new pane
        // copies only what a view owns, from the pane it was cloned from.
        clone.shareDocument(with: source)
        clone.adoptViewState(from: source)
        wire(clone)
        clone.onReadOnlyAttempt = { [weak self] in (self?.document as? TextDocument)?.noteReadOnlyAttempt() }
        secondary = clone
        split.addArrangedSubview(clone)
        split.adjustSubviews()
        split.layoutSubtreeIfNeeded()
        clone.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(clone)
    }
    @objc func closeSplit(_ sender: Any?) {
        guard let clone = secondary else { return }
        clone.onFocus = nil
        lastEditor = primaryEditor
        window?.makeFirstResponder(primaryEditor)
        // Recording across views is not supported; say so even if no focus event was sent.
        (NSApp.delegate as? AppDelegate)?.macros.editorDidFocus(primaryEditor)
        // Deferred results that do not depend on the clone's selection move to the primary view.
        clone.retire(inFavorOf: primaryEditor)
        clone.removeFromSuperview()
        secondary = nil
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(clone(_:)): return secondary == nil
        case #selector(closeSplit(_:)): return secondary != nil
        case #selector(toggleWrap(_:)):
            // Wrapping belongs to the view, as the status bar's Wrap field shows it.
            item.state = activeEditor.wrap ? .on : .off
            return true
        default: return true
        }
    }
    @objc func toggleWrap(_ sender: Any?) { activeEditor.wrap.toggle() }
    @objc func comment(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = CommentCommand(rawValue: raw),
            let app = NSApp.delegate as? AppDelegate, let document = document as? TextDocument
        else { return }
        guard let profile = app.languages.profile(identifier: document.languageIdentifier) else {
            TTAlert.explain(
                "Comments are not available for this language",
                detail: "Choose a language with comment syntax in the Language menu, then try again.")
            return
        }
        do {
            try activeEditor.requireWritable()
            app.macros.invalidateRecording(reason: "Language-specific comments are not yet recorded.")
            try command.apply(to: activeEditor, profile: profile)
        } catch { TTAlert.present(error) }
    }
    @objc func columnInsert(_ sender: Any?) {
        let editor = activeEditor
        do { try editor.requireWritable() } catch {
            TTAlert.explain(error)
            return
        }
        let revision = editor.revision, selections = editor.selectionRanges
        let alert = TTAlert()
        alert.messageText = "Insert into Each Selection"
        alert.informativeText =
            "Use Option-drag for a rectangle or add multiple carets. Text replaces each selected range; numbering follows selection order."
        let text = NSTextField(string: "")
        text.placeholderString = "Text to insert"
        let number = NSButton(checkboxWithTitle: "Insert sequential numbers", target: nil, action: nil)
        let start = NSTextField(string: "1"), step = NSTextField(string: "1")
        let stack = NSStackView(views: [
            text, number, NSTextField(labelWithString: "Start"), start, NSTextField(labelWithString: "Increment"), step
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: 180)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Insert").identifier = NSUserInterfaceItemIdentifier("column.insert")
        alert.addButton(withTitle: "Cancel", role: .cancel).identifier = NSUserInterfaceItemIdentifier("column.cancel")
        for (control, name) in [(text as NSView, "text"), (number, "number"), (start, "start"), (step, "step")] {
            control.identifier = NSUserInterfaceItemIdentifier("column." + name)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var values = Array(repeating: text.stringValue, count: editor.selectionCount)
        if number.state == .on {
            guard let first = Int(start.stringValue), let increment = Int(step.stringValue) else {
                TTAlert.explain(
                    "Start and Increment must be whole numbers", detail: "No column insertion was applied.")
                return
            }
            values = []
            var value = first
            for i in 0..<editor.selectionCount {
                values.append(String(value))
                if i + 1 < editor.selectionCount {
                    let (next, overflow) = value.addingReportingOverflow(increment)
                    guard !overflow else {
                        TTAlert.explain(
                            "The number sequence is too large", detail: "No column insertion was applied.")
                        return
                    }
                    value = next
                }
            }
        }
        (NSApp.delegate as? AppDelegate)?.macros.invalidateRecording(reason: "Column insertion is not yet recorded.")
        if !Self.applyColumn(values, to: editor, revision: revision, selections: selections) {
            let error = TTAlert()
            error.messageText = "Selections changed or are not writable"
            error.informativeText = "No column insertion was applied."
            error.runModal()
        }
    }
    static func applyColumn(_ values: [String], to editor: TTEditor, revision: UInt, selections: [[String: NSNumber]])
        -> Bool
    {
        guard editor.window != nil, editor.selectionRanges == selections else { return false }
        return editor.replaceSelections(values, expectedRevision: revision)
    }
    @objc func convertEOL(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        do { try convertLineEndings(to: mode) } catch { TTAlert.explain(error) }
    }
    /// Refused with the read-only reason before a macro recording is touched.
    func convertLineEndings(to mode: String) throws {
        let editor = activeEditor
        try editor.requireWritable()
        (NSApp.delegate as? AppDelegate)?.macros.invalidateRecording(
            reason: "Line-ending conversion is not yet recorded.")
        guard editor.convertLineEndings(mode) else {
            throw DocumentActionError.lineEndingsRejected
        }
    }
}
