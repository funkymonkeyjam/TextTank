import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private weak var knownWorkspace: WorkspaceWindowController?
    lazy var workspaceWindow: WorkspaceWindowController = {
        let host = WorkspaceWindowController()
        knownWorkspace = host
        return host
    }()
    @MainActor override init() { super.init() }
    @MainActor lazy var workspace: WorkspaceController = {
        let controller = WorkspaceController()
        controller.activeDocument = { [weak self] in self?.currentDocument }
        return controller
    }()
    @MainActor lazy var workspaceBrowser: WorkspaceBrowserController = {
        let controller = WorkspaceBrowserController()
        controller.currentDocument = { [weak self] in self?.currentDocument }
        return controller
    }()
    @MainActor let settings = SettingsController(
        onApply: EditorSettingsApplication.apply,
        onStatus: { message in
            EditorServices.current?.activePresentation?.showTransientStatus(message)
        })
    let recentDocumentsMenu = RecentDocumentsMenu()
    @MainActor lazy var folderSearch: FolderSearchController = {
        let controller = FolderSearchController()
        controller.displayTabWidth = { [weak self] in self?.settings.value.tabWidth ?? 4 }
        controller.workspaceRoots = { [weak self] in self?.workspaceBrowser.store.state.folders ?? [] }
        return controller
    }()
    /// The document window focused last. Written where focus changes (a view's onFocus, a
    /// document window becoming main, the status menu); never by a getter.
    private(set) weak var lastDocumentController: EditorWindowController?
    /// The one definition of "current" for every controller: the main window when it is a
    /// document window, otherwise the document window focused last, because Find and Replace,
    /// a Run result or another auxiliary window may be main. Nil once that document has closed.
    var currentDocumentController: EditorWindowController? {
        let controller = knownWorkspace.map { $0.active } ?? lastDocumentController
        guard !CompareCommandScope.blocksWorkspace, let controller, !controller.isRetired,
            !controller.host.isMutatingGroups,
            (controller.document as? TextDocument)?.isOpen == true
        else { return nil }
        return controller
    }
    var currentDocument: TextDocument? { currentDocumentController?.document as? TextDocument }
    var currentEditor: TTEditor? { currentDocumentController?.activeEditor }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard knownWorkspace?.isMutatingGroups != true else { return false }
        switch item.action {
        case #selector(CompareController.performCompareCommand(_:)):
            return CompareController.key?.validateMenuItem(item) ?? false
        case #selector(newDocument(_:)): return !CompareCommandScope.blocksWorkspace
        case #selector(performTabCommand(_:)):
            guard let raw = item.representedObject as? String, let command = TabCommand(rawValue: raw) else {
                return false
            }
            if let host = knownWorkspace {
                return host.tabCommands.configure(item, command: command, target: host.model.activeTab?.id)
            }
            let state =
                knownWorkspace?.tabCommands.state(command, target: knownWorkspace?.model.activeTab?.id)
                ?? (
                    enabled: false,
                    reason: command == .reopen
                        ? "There are no closed file tabs to reopen." : "There is no open tab to act on."
                )
            item.toolTip = state.reason
            return state.enabled
        case #selector(findNextShared(_:)), #selector(findPreviousShared(_:)),
            #selector(nextDocumentTab(_:)), #selector(previousDocumentTab(_:)):
            return currentDocumentController != nil
        case #selector(showDocumentTabs(_:)): return knownWorkspace?.presentations.isEmpty == false
        default:
            return true
        }
    }
    @MainActor lazy var languages: LanguageController = {
        let controller = LanguageController(
            editorProvider: { [weak self] in self?.currentEditor },
            languageProvider: { [weak self] in
                self?.currentDocument?.languageIdentifier ?? LanguageProfile.plainTextID
            },
            setLanguage: { [weak self] id in self?.currentDocument?.noteAppliedLanguage(id) })
        controller.siblingViews = { editor in
            for case let document as TextDocument in NSDocumentController.shared.documents {
                let views = document.presentations.flatMap(\.views)
                if views.contains(where: { $0 === editor }) { return views.filter { $0 !== editor } }
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
    @MainActor lazy var runner: RunController = {
        let controller = RunController()
        controller.editor = { [weak self] in self?.currentEditor }
        controller.onUnrecordableAction = { [weak self] in
            self?.macros.invalidateRecording(reason: "External execution is never recorded in macros.")
        }
        controller.file = { [weak self] in self?.currentDocument?.fileURL }
        return controller
    }()
    @MainActor lazy var utilities: UtilityController = {
        let controller = UtilityController(activeEditor: { [weak self] in self?.currentEditor })
        controller.onUnrecordableEdit = { [weak self] in
            self?.macros.invalidateRecording(reason: "Text utilities are not recorded in macros yet.")
        }
        return controller
    }()
    @MainActor lazy var searchController: SearchController = {
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
    @MainActor lazy var compare: CompareService = {
        let value = CompareService()
        value.currentEditor = { [weak self] in self?.currentEditor }
        return value
    }()
    @MainActor lazy var macros = MacroController(editorProvider: { [weak self] in self?.currentEditor })
    @MainActor lazy var automations: AutomationController = {
        let controller = AutomationController(
            editorProvider: { [weak self] in self?.currentEditor }, newDocument: AppDelegate.openAutomationOutput)
        controller.onQuietExportResult = { [weak self] message in
            let window = self?.currentDocumentController
            window?.showTransientStatus(
                message,
                compactMessage: Strings.text(
                    "status.remindersAdded", "Items were added in Reminders. Editor Undo does not remove them."),
                seconds: 8, announce: false)
        }
        controller.onInvocation = { [weak self] in
            self?.macros.invalidateRecording(
                reason: "An automation was invoked during macro recording. Automation side effects are not recorded.")
        }
        return controller
    }()
    @MainActor private static func openAutomationOutput(_ text: String) {
        DocumentFactory.makeUntitled(populate: { doc in
            doc.editor.text = text
            doc.editor.setLineEndingMode(LineEnding.detect(in: text).nativeMode)
        })
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
        if settings.shortcutLoadNotice != nil {
            let message =
                "Some saved shortcuts were ignored. Other settings remain in use. Open Settings to review them; the original settings file is preserved."
            Announce.say(message)
            lastDocumentController?.showTransientStatus(message, seconds: 8, announce: false)
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
    /// Installation is explicit and follows TextDocumentController construction in main.
    /// Weak providers preserve the lazy feature graph without retaining a discarded composition root.
    @MainActor func installEditorServices() {
        var services = EditorServices()
        services.activePresentationProvider = { [weak self] in self?.currentDocumentController }
        services.workspaceHostProvider = { [weak self] in self?.workspaceWindow }
        services.isAvailable = { [weak self] in self != nil }
        services.settingsProvider = { [weak self] in self?.settings }
        services.languagesProvider = { [weak self] in self?.languages }
        services.macrosProvider = { [weak self] in self?.macros }
        services.automationsProvider = { [weak self] in self?.automations }
        services.compareProvider = { [weak self] in self?.compare }
        services.searchProvider = { [weak self] in self?.searchController }
        services.newDocument = { [weak self] in self?.newDocument($0) }
        services.noteActiveController = { [weak self] in self?.noteActive($0) }
        services.openSessionFile = { [weak self] in self?.workspace.openSession(at: $0) }
        EditorServices.current = services
    }
    func noteActive(_ controller: EditorWindowController?) {
        if let controller { knownWorkspace = controller.host }
        lastDocumentController = controller
    }
    @objc func performCompareCommand(_ sender: Any?) {
        CompareController.key?.performCompareCommand(sender)
    }
    @objc func newDocument(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        guard knownWorkspace?.isMutatingGroups != true else { return }
        DocumentFactory.makeUntitled()
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    /// Saved window state is decoded with secure coding only.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    /// Closes every document once quitting is certain, never while the review can still be
    /// cancelled. The tab windows are taken off screen first: closing a visible tab shows the
    /// tab that takes its place, and at quit that would show and lay out each remaining document.
    func closeAllForTermination() {
        let documents = NSDocumentController.shared.documents
        var hidden = Set<ObjectIdentifier>()
        for case let document as TextDocument in documents {
            if let host = document.presentation?.host, hidden.insert(ObjectIdentifier(host)).inserted {
                host.window?.orderOut(nil)
            }
        }
        let hosts = documents.compactMap { ($0 as? TextDocument)?.presentation?.host }
        hosts.forEach { $0.tabCommands.isTerminating = true }
        defer { hosts.forEach { $0.tabCommands.isTerminating = false } }
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
    var requestUnsavedReview: @MainActor (AppDelegate) -> Void = { delegate in
        NSDocumentController.shared.reviewUnsavedDocuments(
            withAlertTitle: "Quit TextTank?", cancellable: true, delegate: delegate,
            didReviewAllSelector: #selector(AppDelegate.reviewed(_:didReviewAll:contextInfo:)), contextInfo: nil)
    }
    var replyToTerminate: @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    @objc func reviewed(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if didReviewAll { closeAllForTermination() }
        replyToTerminate(didReviewAll)
    }
    @MainActor func buildMenus() {
        let bar = NSMenu()
        NSApp.mainMenu = bar
        @MainActor func menu(_ title: String) -> NSMenu {
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
        file.addItem(title: EditorToolbarCommand.new.title, action: EditorToolbarCommand.new.action, keyEquivalent: "n")
        file.addItem(
            title: EditorToolbarCommand.open.title, action: EditorToolbarCommand.open.action, keyEquivalent: "o")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = recentDocumentsMenu
        recentItem.submenu = recentMenu
        file.addItem(recentItem)
        file.addItem(
            title: EditorToolbarCommand.save.title, action: EditorToolbarCommand.save.action, keyEquivalent: "s")
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
        for target in FileFormat.convertTargets {
            let title = target.title, code = target.code
            encoding.addItem(
                title: "Convert to \(title)", action: #selector(TextDocument.convertEncoding(_:)),
                representedObject: code)
        }
        encoding.addItem(.separator())
        // The same names as the Convert items above, never the stored identifier.
        for value in FileEncoding.allCases {
            encoding.addItem(
                title: "Reload as \(value.displayName)…",
                action: #selector(TextDocument.reloadEncoding(_:)), representedObject: value.rawValue)
        }
        let edit = menu("Edit")
        // Grouped by what the command acts on. Every item keeps its command identifier as its
        // represented object, so shortcuts, macros and validation find it wherever it sits.
        @MainActor func group(_ title: String) -> NSMenu {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            parent.submenu = child
            edit.addItem(parent)
            return child
        }
        @MainActor func command(_ m: NSMenu, _ title: String, _ id: String, _ key: String = "") {
            m.addItem(
                title: title, action: #selector(EditorWindowController.command(_:)), keyEquivalent: key,
                representedObject: id)
        }
        @MainActor func command(_ menu: NSMenu, _ value: EditorCommand, _ key: String? = nil) {
            command(menu, value.title, value.rawValue, key ?? value.defaultMenuShortcut)
        }
        @MainActor func transform(_ m: NSMenu, _ value: EditorTransform) {
            command(m, value.title, "transform." + value.rawValue)
        }
        edit.addItem(
            title: EditorCommand.undo.title, action: NSSelectorFromString("undo:"),
            keyEquivalent: EditorCommand.undo.defaultMenuShortcut,
            representedObject: EditorCommand.undo.rawValue)
        edit.addItem(
            title: EditorCommand.redo.title, action: NSSelectorFromString("redo:"),
            keyEquivalent: EditorCommand.redo.defaultMenuShortcut,
            representedObject: EditorCommand.redo.rawValue)
        edit.addItem(.separator())
        edit.addItem(
            title: EditorCommand.cut.title, action: #selector(NSText.cut(_:)),
            keyEquivalent: EditorCommand.cut.defaultMenuShortcut,
            representedObject: EditorCommand.cut.rawValue)
        edit.addItem(
            title: EditorCommand.copy.title, action: #selector(NSText.copy(_:)),
            keyEquivalent: EditorCommand.copy.defaultMenuShortcut,
            representedObject: EditorCommand.copy.rawValue)
        edit.addItem(
            title: EditorCommand.paste.title, action: #selector(NSText.paste(_:)),
            keyEquivalent: EditorCommand.paste.defaultMenuShortcut,
            representedObject: EditorCommand.paste.rawValue)
        edit.addItem(
            title: EditorCommand.selectAll.title, action: #selector(NSText.selectAll(_:)),
            keyEquivalent: EditorCommand.selectAll.defaultMenuShortcut,
            representedObject: EditorCommand.selectAll.rawValue)
        edit.addItem(.separator())
        let lines = group("Lines")
        command(lines, .duplicateLine)
        command(lines, .deleteLine)
        command(lines, .transposeLine)
        command(lines, .moveLineUp)
        command(lines, .moveLineDown)
        command(lines, .joinLines)
        lines.addItem(.separator())
        for value: EditorTransform in [
            .sortAscending, .sortDescending, .sortCaseInsensitive, .sortLocalized, .sortLength
        ] { transform(lines, value) }
        lines.addItem(.separator())
        for value: EditorTransform in [.reverseLines, .uniqueLines, .removeEmptyLines] { transform(lines, value) }
        let whitespace = group("Indentation and Whitespace")
        command(whitespace, .indent)
        command(whitespace, .unindent)
        whitespace.addItem(.separator())
        transform(whitespace, .trimLeading)
        command(whitespace, .trimTrailing)
        transform(whitespace, .trimBoth)
        let letterCase = group("Convert Case")
        command(letterCase, .upper)
        command(letterCase, .lower)
        transform(letterCase, .titleCase)
        transform(letterCase, .invertCase)
        let comments = group("Comment")
        for comment in CommentCommand.allCases {
            comments.addItem(
                title: comment.title, action: #selector(EditorWindowController.comment(_:)),
                representedObject: comment.rawValue)
        }
        let selection = group("Selection")
        for value: EditorCommand in [
            .rectangularSelection, .streamSelection, .addNextOccurrence, .selectAllOccurrences,
            .clearAdditionalSelections, .duplicateSelection
        ] { command(selection, value) }
        selection.addItem(.separator())
        selection.addItem(title: "Column Insert / Number…", action: #selector(EditorWindowController.columnInsert(_:)))
        let deletion = group("Delete")
        for value: EditorCommand in [.deleteWordLeft, .deleteWordRight, .deleteLineLeft, .deleteLineRight] {
            command(deletion, value)
        }
        let endings = group("Line Endings")
        for mode in ["LF", "CRLF", "CR"] {
            endings.addItem(
                title: "Convert to \(mode)", action: #selector(EditorWindowController.convertEOL(_:)),
                representedObject: mode)
        }
        edit.addItem(.separator())
        command(edit, .toggleOvertype)
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
        search.addItem(
            title: EditorToolbarCommand.find.title, action: EditorToolbarCommand.find.action, keyEquivalent: "f")
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
        for value: EditorCommand in [
            .gotoMatchingBrace, .selectMatchingBrace, .bookmarkToggle, .bookmarkNext, .bookmarkPrevious
        ] { command(search, value) }
        let comparisons = NSMenuItem(title: "Compare", action: nil, keyEquivalent: "")
        let compareMenu = NSMenu(title: "Compare")
        compare.addMainItems(to: compareMenu)
        compareMenu.addItem(.separator())
        for command in CompareCommand.allCases where !command.isMergeCommand {
            compareMenu.addItem(
                title: command.title, action: #selector(CompareController.performCompareCommand(_:)), target: nil,
                representedObject: command.rawValue)
        }
        compareMenu.addItem(.separator())
        for (title, commands) in [
            ("Merge Changes", CompareCommand.mergeCommands), ("Patch", CompareCommand.patchCommands)
        ] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            for command in commands {
                menu.addItem(
                    title: command.title, action: #selector(CompareController.performCompareCommand(_:)), target: nil,
                    representedObject: command.rawValue)
            }
            item.submenu = menu
            compareMenu.addItem(item)
        }
        comparisons.submenu = compareMenu
        search.addItem(.separator())
        search.addItem(comparisons)

        let runRoot = NSMenuItem()
        runRoot.title = "Run"
        runRoot.submenu = runner.makeMenu()
        bar.addItem(runRoot)
        let utilityRoot = NSMenuItem()
        utilityRoot.title = "Text Utilities"
        utilityRoot.submenu = utilities.makeMenu()
        bar.addItem(utilityRoot)
        let view = menu("View")
        view.addItem(title: EditorToolbarCommand.split.title, action: EditorToolbarCommand.split.action)
        view.addItem(title: "Close Split View", action: #selector(EditorWindowController.closeSplit(_:)))
        view.addItem(title: "Wrap Lines", action: #selector(EditorWindowController.toggleWrap(_:)))
        command(view, .zoomIn)
        command(view, .zoomOut)
        for value: EditorCommand in [.foldAll, .unfoldAll, .showWhitespace, .toggleEOL, .toggleLineNumbers] {
            command(view, value)
        }
        view.addItem(.separator())
        view.addItem(
            title: Strings.text("toolbar.show", "Show Toolbar"), action: #selector(NSWindow.toggleToolbarShown(_:)))
        view.addItem(
            title: Strings.text("toolbar.customize", "Customize Toolbar…"),
            action: #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        workspaceWindow.groupCommands.install(in: view)
        view.addItem(
            title: "Auto-Indent on Return", action: #selector(SettingsController.toggleAutoIndent(_:)), target: settings
        )
        view.addItem(
            title: "Highlight Matching Braces", action: #selector(SettingsController.toggleBraceHighlight(_:)),
            target: settings)
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
        for section in TabCommandController.sections {
            window.addItem(.separator())
            for command in section {
                let item = window.addItem(
                    title: command.title, action: #selector(performTabCommand(_:)), target: self,
                    representedObject: command.rawValue)
                item.identifier = NSUserInterfaceItemIdentifier("tabs.command." + command.rawValue)
            }
        }
        window.addItem(.separator())
        window.addItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        window.addItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)))
        // AppKit puts its search field in the Help menu; it finds any command in the menus above.
        let help = menu("Help")
        NSApp.helpMenu = help
        help.addItem(title: "TextTank Help (Online)", action: #selector(openOnlineHelp(_:)), keyEquivalent: "?")
        settings.reconcileShortcuts(with: bar)
    }
    /// The project page, which carries the review guide and where each command lives. There is no
    /// bundled help book yet.
    @objc func openOnlineHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/funkymonkeyjam/TextTank#readme") { NSWorkspace.shared.open(url) }
    }
    /// Find Next and Find Previous act on whichever Find the person is using: the Find and Replace
    /// window while it is open, otherwise the find bar of the current document window.
    @MainActor @objc func findNextShared(_ sender: Any?) { findShared(backwards: false) }
    @MainActor @objc func findPreviousShared(_ sender: Any?) { findShared(backwards: true) }
    @MainActor private func findShared(backwards: Bool) {
        if searchController.isWindowLoaded, searchController.window?.isVisible == true {
            if backwards { searchController.previous(nil) } else { searchController.next(nil) }
        } else {
            let controller =
                currentDocumentController
            controller?.findFromMenu(backwards: backwards)
        }
    }
    @objc func performTabCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = TabCommand(rawValue: raw) else { return }
        knownWorkspace?.tabCommands.performSelection(command, sender: sender)
    }
    @objc func nextDocumentTab(_ sender: Any?) { cycleDocumentTab(1) }
    @objc func previousDocumentTab(_ sender: Any?) { cycleDocumentTab(-1) }
    private func cycleDocumentTab(_ direction: Int) { WorkspaceWindowController.current.cycle(direction) }
    private var documentsPanel: ChoicePanel?
    @MainActor @objc func showDocumentTabs(_ sender: Any?) {
        guard knownWorkspace?.isMutatingGroups != true else { return }
        if let documentsPanel {
            documentsPanel.refresh()
            documentsPanel.form.window.makeKeyAndOrderFront(nil)
            return
        }
        let host = WorkspaceWindowController.current
        guard !host.presentations.isEmpty else { return }
        let panel = ChoicePanel(
            title: "Open Documents", identifier: "TextTank.OpenDocuments", action: "Switch",
            filterLabel: "Filter open documents by name or path")
        documentsPanel = panel
        panel.retainController(self)
        panel.onClose = { [weak self] in self?.documentsPanel = nil }
        panel.rows = { [weak self, weak host] in self?.documentTabChoices(host?.presentations ?? []) ?? [] }
        panel.choose = { [weak host] id in
            guard let host,
                let presentation = host.presentations.first(where: {
                    $0.tabID?.rawValue.uuidString == id
                })
            else { throw FormFailure.documentChanged }
            host.show(presentation, sender: nil)
            return true
        }
        panel.show()
    }
    @MainActor func documentTabChoices(_ presentations: [EditorWindowController]) -> [ChoicePanel.Row] {
        presentations.compactMap { presentation in
            guard let document = presentation.document as? TextDocument, document.isOpen else { return nil }
            let path = document.fileURL?.deletingLastPathComponent().path
            let title = document.displayName + (document.isDocumentEdited ? " •" : "") + (path.map { " — \($0)" } ?? "")
            guard let id = presentation.tabID,
                let group = presentation.host.model.groups.first(where: { $0.tabs.contains { $0.id == id } })
            else { return nil }
            return ChoicePanel.Row(
                id: id.rawValue.uuidString, title: title + " — " + presentation.host.groupLabel(group.slot))
        }
    }
    /// Full paths, because the Recovery folder is inside the hidden Library folder.
    nonisolated static func recoveryIssueText(_ issues: [RecoveryIssue]) -> String {
        "These files were left untouched and are not recovered automatically.\n\n"
            + issues.map { $0.url.path + "\n" + $0.message }.joined(separator: "\n\n")
    }
    /// The launch prompt's text: what each snapshot is a draft of and when it was written, so the
    /// person can tell the drafts apart before recovering or discarding them. Display only.
    nonisolated static func recoveryPromptText(_ snapshots: [RecoverySnapshot], limit: Int = 12) -> String {
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
    nonisolated static func aboutOptions(info: [String: Any]?, credits: URL?) -> [NSApplication.AboutPanelOptionKey:
        Any]
    {
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
