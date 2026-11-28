import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    var firstLaunchProfile = false
    var helpResourceDirectory = Bundle.main.resourceURL
    private var defaultDocumentLaunch = false
    private var automaticSession: AutomaticSession?
    var smokeFile: URL?
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
        case #selector(actualSize(_:)): return CompareController.key != nil || currentEditor != nil
        case #selector(newDocument(_:)), #selector(clearLocalHistory(_:)): return !CompareCommandScope.blocksWorkspace
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
        // The chooser lists first what the document's name and first line suggest, and is a
        // sheet on the workspace window.
        controller.detectedLanguage = { [weak self, weak controller] in
            guard let document = self?.currentDocument else { return nil }
            // Only a "#!" first line is read from the text. A document too large to copy for
            // that on the main thread is detected by its name alone.
            let editor = document.editor
            let sample =
                editor.byteLength <= 1_048_576 ? String(decoding: editor.utf8Data.prefix(512), as: UTF8.self) : ""
            return controller?.detect(filename: document.fileURL?.lastPathComponent ?? "", text: sample)
        }
        controller.chooserParent = { [weak self] in self?.currentDocumentController?.hostWindow }
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
        controller.sharedFlagsChanged = {
            for case let document as TextDocument in NSDocumentController.shared.documents {
                document.presentations.forEach { $0.acceptSharedFindFlags() }
            }
        }
        controller.writeFindText = { text in EditorWindowController.findPasteboardText = text }
        // DS-35, one Find: text typed in the window or in any find bar is shown by all the others.
        controller.sharedTextChanged = { source in
            for case let document as TextDocument in NSDocumentController.shared.documents {
                document.presentations.forEach { if $0 !== source { $0.acceptSharedFindText() } }
            }
        }
        controller.historyChanged = {
            for case let document as TextDocument in NSDocumentController.shared.documents {
                document.presentations.forEach { $0.refreshFindHistory() }
            }
        }
        controller.adoptFindPasteboard()
        controller.currentEditor = { [weak self] in self?.currentEditor }
        // One view per document, and the one the person last worked in: Find Next compares
        // these with the current editor, and a replace reads that view's selection.
        controller.openEditors = {
            NSDocumentController.shared.documents.compactMap { ($0 as? TextDocument)?.activeEditor }
        }
        return controller
    }()
    private var reviewingTermination = false
    private weak var initializedCompare: CompareService?
    @MainActor lazy var compare: CompareService = {
        let value = CompareService()
        initializedCompare = value
        value.prepareSelectedChange = { [weak self] destination in
            self?.macros.prepareUnrecordedChange(
                in: destination,
                reason: "Applying selected comparison changes cannot be recorded. No partial macro will be saved.")
        }
        value.currentEditor = { [weak self] in self?.currentEditor }
        value.visibleEditors = { [weak self] in self?.knownWorkspace?.visibleComparisonEditors }
        return value
    }()
    @MainActor lazy var macros = MacroController(editorProvider: { [weak self] in self?.currentEditor })
    let commandDiscovery = CommandDiscovery()
    @MainActor lazy var automations: AutomationController = {
        let controller = AutomationController(
            editorProvider: { [weak self] in self?.currentEditor }, newDocument: AppDelegate.openAutomationOutput)
        controller.commandDiscovery = { [weak self] in
            self?.commandDiscovery.show(editor: { [weak self] in self?.currentEditor })
        }
        controller.onQuietExportResult = { [weak self] message in
            let window = self?.currentDocumentController
            window?.showTransientStatus(
                message,
                compactMessage: Strings.text(
                    "status.remindersAdded", "Items were added in Reminders. Editor Undo does not remove them."),
                seconds: 8, announce: false)
        }
        controller.comparisonService = { [weak self] in self?.compare }
        controller.prepareTransformedPaste = { [weak self] editor in
            self?.macros.prepareUnrecordedChange(in: editor, reason: "Paste Through changed the recorded document.")
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
    func applicationDidBecomeActive(_ notification: Notification) {
        startForegroundInterfaceIfNeeded()
        let front = currentDocument
        front?.externalFile.setApplicationActive(true)
        front?.externalFile.check(prioritized: true)
        for case let document as TextDocument in NSDocumentController.shared.documents where document !== front {
            document.externalFile.setApplicationActive(true)
            document.externalFile.check()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        for case let document as TextDocument in NSDocumentController.shared.documents {
            document.externalFile.setApplicationActive(false)
        }
    }

    private var replacementRetentionTimer: DispatchSourceTimer?
    private func startReplacementRetention() {
        let cleanup = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "TextTank.folder-replacement-retention", qos: .utility))
        cleanup.schedule(deadline: .now() + 2, repeating: .seconds(86_400), leeway: .seconds(120))
        cleanup.setEventHandler {
            do {
                if try FolderReplacementHistory.prune().needsReview != 0 {
                    NSLog("Some private folder replacement backups could not be cleaned up.")
                }
            } catch { NSLog("Folder replacement backup cleanup needs review in Find in Folder.") }
        }
        replacementRetentionTimer = cleanup
        cleanup.resume()
    }
    private lazy var commandLine = CommandLineController { [weak self] in self?.compare }
    @objc func handleCommandLine(_ notice: Notification) {
        guard let raw = notice.userInfo?["request"] as? String,
            let id = UUID(uuidString: raw)
        else { return }
        Task { await commandLine.accept(id) }
    }
    @objc func installCommandLine(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Install the tt Command-Line Tool"
        panel.message = "Choose a folder you own for a link to TextTank’s tt tool."
        panel.prompt = "Install"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let path = try CommandLineController.install(
                    helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tt"), in: url)
                self?.knownWorkspace?.showTabMessage("Installed tt at " + path.path)
            } catch { TTAlert.present(error) }
        }
    }
    private lazy var textServices = TextServices(newDocument: Self.openAutomationOutput)

    func installTextServices() { NSApp.servicesProvider = textServices }

    func applicationWillFinishLaunching(_ notification: Notification) {
        installTextServices()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleCommandLine(_:)),
            name: TTInvocation.wakeName, object: String(ProcessInfo.processInfo.processIdentifier),
            suspensionBehavior: .deliverImmediately)
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenTextURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }
    @objc func handleOpenTextURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        do {
            guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
                throw TextOpenRequest.invalidURL
            }
            _ = try TextOpenRequest(raw).open()
        } catch {
            reply.setParam(NSAppleEventDescriptor(int32: Int32(paramErr)), forKeyword: keyErrorNumber)
            reply.setParam(NSAppleEventDescriptor(string: error.localizedDescription), forKeyword: keyErrorString)
            knownWorkspace?.showTabMessage(error.localizedDescription)
        }
    }
    private enum LaunchInterface { case waitingForLaunch, waitingForForeground, started }
    private var launchInterface = LaunchInterface.waitingForLaunch

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard launchInterface == .waitingForLaunch else { return }
        defaultDocumentLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true
        launchInterface = .waitingForForeground
        if smokeFile != nil || NSApp.isActive { startForegroundInterfaceIfNeeded() }
    }

    /// A background App Intent can finish entirely inside the app's normal process without
    /// displaying startup alerts, restoring tabs, seeding manager presets or starting a session timer.
    private func startForegroundInterfaceIfNeeded() {
        guard launchInterface == .waitingForForeground else { return }
        launchInterface = .started
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
        if let message = settings.value.unavailableFontNotice {
            Announce.say(message)
            lastDocumentController?.showTransientStatus(message, seconds: 8, announce: false)
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
        if let smokeFile {
            openSmokeDocument(smokeFile)
            return
        }
        startReplacementRetention()
        // Local history's thirty-day limit also holds for a file that is not saved again.
        LocalHistory.pruneAtLaunch()
        TextDocument.recovery.scanForLaunch { [weak self] result in
            self?.launchInventory = result
            self?.deliverLaunchInventory()
        }
    }
    private var launchInventory: Result<RecoveryInventory, Error>?
    private var launchReviewSuspended = false
    private func deliverLaunchInventory() {
        guard !launchReviewSuspended, !reviewingTermination,
            (NSDocumentController.shared as? TextDocumentController)?.isReviewingOpenDocuments != true,
            let result = launchInventory
        else { return }
        launchInventory = nil
        var sessionNotices: [String] = []
        restoreLaunchDocuments(
            createUntitledIfEmpty: !CommandLine.arguments.contains("--texttank-external-request"),
            welcomeIfEmpty: firstLaunchProfile && defaultDocumentLaunch,
            recovery: try? result.get(),
            review: { originals in self.restoreRecovery(result, originals: originals) }
        ) {
            sessionNotices.append(contentsOf: $0)
        }
        showSessionNotices(sessionNotices)
    }
    /// Restore and recovery review finish before reporting skipped paths in their workspace.
    func showSessionNotices(_ notices: [String]) {
        guard !notices.isEmpty, let window = workspaceWindow.window else { return }
        let alert = TTAlert()
        alert.messageText = "Some session items need review"
        alert.informativeText =
            notices.prefix(12).joined(separator: "\n")
            + (notices.count > 12 ? "\n…and \(notices.count - 12) more." : "")
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }
    /// `recovery` is the launch scan of the recovery folder. With "Keep unsaved untitled
    /// documents when quitting" on (DS-D9), the untitled copies in it reopen here without a
    /// question: those the session names in their saved tab, group and pin position, and any
    /// others (a crash, or a session file that could not be written) as tabs after them. A copy
    /// that cannot be opened stays in the folder and reaches `review`, which asks as before.
    func restoreLaunchDocuments(
        createUntitledIfEmpty: Bool = true, welcomeIfEmpty: Bool = false, recovery: RecoveryInventory? = nil,
        review: ([URL: TextDocument]) -> Void, report: ([String]) -> Void
    ) {
        let session = AutomaticSession()
        session.keepsUntitled = { [weak self] document, quitting in
            quitting
                ? document.isHeldForQuit
                : self?.settings.value.keepsUntitledOnQuit == true && document.isEditedUntitled
        }
        automaticSession = session
        var originals = [URL: TextDocument]()
        let keeps = settings.value.keepsUntitledOnQuit
        var copies = [UUID: RecoveryHeader]()
        if keeps, let recovery {
            let live = Set(NSDocumentController.shared.documents.compactMap { ($0 as? TextDocument)?.recoveryID })
            for header in recovery.headers where !live.contains(header.id) { copies[header.id] = header }
        }
        var restoredUntitled = 0
        func reopenUntitled(_ id: UUID, language: String? = nil, lineEnding: String? = nil) -> TextDocument? {
            guard let header = copies.removeValue(forKey: id),
                let snapshot = try? TextDocument.recovery.load(listed: header),
                let document = try? TextDocument.openKeptUntitled(
                    snapshot, language: language, lineEnding: lineEnding.flatMap(LineEnding.init(rawValue:)))
            else { return nil }
            restoredUntitled += 1
            return document
        }
        do {
            if var state = try session.read() {
                // The sidebar is part of the window, like its frame: it comes back whether or
                // not last session's documents do. An older file has no sidebar keys and
                // leaves it hidden.
                workspaceWindow.applySidebar(from: state.layout)
                if !settings.value.reopensLastSession { state = try state.untitledOnly() }
                if settings.value.reopensLastSession || (keeps && state.untitled != nil) {
                    let result = session.reopen(state, in: workspaceWindow) {
                        reopenUntitled($0.id.rawValue, language: $0.language, lineEnding: $0.lineEnding)
                    }
                    originals = result.files
                    if !result.notices.isEmpty { report(result.notices) }
                }
            }
        } catch {
            if settings.value.reopensLastSession { report([error.localizedDescription]) }
        }
        // Untitled copies no session placed. A copy that names a file is a draft of that file
        // and keeps the Recover question.
        let unplaced = copies.values.filter { $0.originalURL == nil }.sorted { $0.savedAt < $1.savedAt }
        let appended = unplaced.compactMap { reopenUntitled($0.id) }
        if knownWorkspace?.active == nil { appended.last?.showWindows() }
        if let active = knownWorkspace?.active {
            active.showWindow(nil)
        } else {
            for doc in NSDocumentController.shared.documents {
                if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
                doc.showWindows()
            }
        }
        review(originals)
        let controller = NSDocumentController.shared
        if createUntitledIfEmpty, controller.documents.isEmpty,
            (controller as? TextDocumentController)?.largeOpens.isEmpty != false
        {
            if welcomeIfEmpty {
                do { try openHelpDocument(welcome: true) } catch {
                    newDocument(nil)
                    report([error.localizedDescription])
                }
            } else {
                newDocument(nil)
            }
        }
        if restoredUntitled > 0 {
            // DS-40: a quiet status message, announced, never an alert.
            knownWorkspace?.showTabMessage(Self.restoredUntitledNotice(restoredUntitled))
        }
        session.start { [weak self] in self?.checkpointSession() }
    }
    nonisolated static func restoredUntitledNotice(_ count: Int) -> String {
        count == 1
            ? "Restored 1 untitled document with unsaved text. It is still unsaved."
            : "Restored \(count) untitled documents with unsaved text. They are still unsaved."
    }
    func checkpointSession() {
        automaticSession?.checkpoint(knownWorkspace) { [weak self] error in
            self?.knownWorkspace?.showTabMessage("The last session could not be saved. " + error.localizedDescription)
        }
    }
    private func commitSession() {
        do {
            if try automaticSession?.commit(knownWorkspace) == false {
                knownWorkspace?.showTabMessage("The existing last-session file was preserved.")
            }
        } catch {
            let alert = TTAlert()
            alert.messageText = "The last session could not be confirmed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
        }
    }
    /// Exercise the production document controller and create the document's real window offscreen.
    private func openSmokeDocument(_ file: URL) {
        let controller = NSDocumentController.shared
        controller.openDocument(withContentsOf: file, display: false) { document, _, error in
            guard let document = document as? TextDocument, let opened = document.fileURL,
                opened.standardizedFileURL.resolvingSymlinksInPath() == file.resolvingSymlinksInPath(),
                controller.documents.contains(document),
                let presentation = document.presentation, presentation.hostWindow != nil
            else {
                TextTankApplication.smokeFailure(
                    error?.localizedDescription ?? "No file-backed editor window.",
                    cleanup: AppStorage.supportDirectory)
            }
            struct Status: Encodable {
                let file: String
                let editorBytes: Int
                let windowCreated: Bool
            }
            do {
                let status = Status(
                    file: opened.path, editorBytes: Int(document.editor.byteLength), windowCreated: true)
                var data = try JSONEncoder().encode(status)
                data.append(0x0A)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                TextTankApplication.smokeFailure(error.localizedDescription, cleanup: AppStorage.supportDirectory)
            }
            document.close()
            NSApp.stop(nil)
            // Wake AppKit if this completion arrived from a dispatched callback.
            if let event = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0,
                data1: 0, data2: 0)
            {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
    /// Installation is explicit and follows TextDocumentController construction in main.
    /// Weak providers preserve the lazy feature graph without retaining a discarded composition root.
    @MainActor func installEditorServices() {
        if let controller = NSDocumentController.shared as? TextDocumentController {
            // AppKit reviews and closes the documents itself before it asks this delegate about
            // quitting, so the untitled documents are held here, before that review looks (DS-D9).
            controller.willReviewOpenDocuments = { [weak self] in
                self?.initializedCompare?.cancelPendingSavedComparisons()
                self?.holdUntitledForQuit()
                self?.automaticSession?.beginReview(self?.knownWorkspace)
            }
            controller.didReviewOpenDocuments = { [weak self] accepted in
                if !accepted { self?.releaseQuitHolds() }
                self?.automaticSession?.nativeReviewEnded(accepted: accepted)
                DispatchQueue.main.async { [weak self] in self?.deliverLaunchInventory() }
            }
            controller.didRegisterDocument = { [weak self] in self?.automaticSession?.documentOpened() }
        }
        var services = EditorServices()
        services.activePresentationProvider = { [weak self] in self?.currentDocumentController }
        services.workspaceHostProvider = { [weak self] in self?.workspaceWindow }
        services.workspaceBrowserProvider = { [weak self] in self?.workspaceBrowser }
        services.isAvailable = { [weak self] in self != nil }
        services.settingsProvider = { [weak self] in self?.settings }
        services.languagesProvider = { [weak self] in self?.languages }
        services.macrosProvider = { [weak self] in self?.macros }
        services.automationsProvider = { [weak self] in self?.automations }
        services.reviewingTermination = { [weak self] in
            self?.reviewingTermination == true
                || (NSDocumentController.shared as? TextDocumentController)?.isReviewingOpenDocuments == true
        }
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
    /// Compare › Clear Local History… (DS-D10): for the current file, or for everything, after a
    /// confirmation sheet. It deletes private copies only.
    @objc func clearLocalHistory(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        LocalHistory.clear(for: currentDocument, in: workspaceWindow)
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
        // Documents that AppKit's review already "closed" are still open here.
        var documents = NSDocumentController.shared.documents
        for noted in TextDocument.takeDeferredQuitCloses() + quitHeld where !documents.contains(noted) {
            documents.append(noted)
        }
        quitHeld = []
        TextDocument.quitIsCertain = true
        defer { TextDocument.quitIsCertain = false }
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
    /// DS-D9, owner decision of 23 November 2026: quitting does not ask about an edited untitled
    /// document. Each one's recovery copy is written, confirmed on storage and read back first;
    /// a document whose copy cannot be verified, or that is beyond the documented bounds, is
    /// left edited so the ordinary review asks about it. Tab order decides who fits the bounds.
    private func holdUntitledForQuit() {
        guard settings.value.keepsUntitledOnQuit else { return }
        let limits = keptUntitledLimits
        var count = 0, bytes = 0
        var documents = knownWorkspace?.presentations.compactMap { $0.document as? TextDocument } ?? []
        for case let document as TextDocument in NSDocumentController.shared.documents
        where !documents.contains(where: { $0 === document }) { documents.append(document) }
        var seen = Set<ObjectIdentifier>()
        // A document the review already asked about (its close is only noted) is not offered again.
        for document in documents
        where seen.insert(ObjectIdentifier(document)).inserted && document.isEditedUntitled
            && (document.isHeldForQuit || !document.quitCloseDeferred)
        {
            let size = document.editor.byteLength
            guard count < limits.count, size <= limits.bytes - bytes else {
                document.releaseQuitHold()
                continue
            }
            if document.holdForQuit() {
                count += 1
                bytes += size
                if !quitHeld.contains(document) { quitHeld.append(document) }
            }
        }
    }
    /// How many untitled documents one quit keeps, and how many bytes of text in all. Each
    /// document is also bounded by the automatic-recovery ceiling. A property so that a check
    /// can reach the bounds with small documents.
    var keptUntitledLimits = (
        count: SizePolicy.standard.keptUntitledCount, bytes: SizePolicy.standard.keptUntitledTotal
    )
    /// The untitled documents this quit is holding. AppKit's review takes them for clean and
    /// "closes" them before the person can still cancel; they stay here, open and untouched,
    /// until the quit is certain or cancelled.
    private var quitHeld: [TextDocument] = []
    /// The quit was cancelled: every held document is registered again and edited again, in
    /// its tab, as it was.
    private func releaseQuitHolds() {
        let held = quitHeld
        quitHeld = []
        TextDocument.cancelDeferredQuitCloses()
        held.forEach { $0.releaseQuitHold() }
        for case let document as TextDocument in NSDocumentController.shared.documents { document.releaseQuitHold() }
    }
    /// Just before the documents close: every held copy is still the document's text, or is
    /// written and verified again now. False means one could not be, and nothing may close.
    private func confirmQuitHolds() -> Bool {
        for document in quitHeld where document.isHeldForQuit {
            guard document.holdForQuit() else { return false }
        }
        return true
    }
    /// Takes the holds again for the text as it is now. False when a document this quit was
    /// holding is no longer held (it grew past a bound) or its newer copy cannot be verified.
    private func renewQuitHolds() -> Bool {
        let before = quitHeld
        holdUntitledForQuit()
        if before.contains(where: { !$0.isHeldForQuit && !$0.isClosed && $0.fileURL == nil }) { return false }
        return confirmQuitHolds()
    }
    /// An edited untitled document that is open and registered, with the setting on, and not held.
    private var hasUnkeptUntitledDocument: Bool {
        guard settings.value.keepsUntitledOnQuit else { return false }
        return NSDocumentController.shared.documents.contains {
            guard let document = $0 as? TextDocument else { return false }
            return document.isEditedUntitled && !document.isHeldForQuit
        }
    }
    static let unkeptTextNotice =
        "TextTank did not quit: an untitled document's unsaved text could not be kept. Save it, then quit again."
    private func refuseQuitForUnkeptText() {
        automaticSession?.cancelReview()
        releaseQuitHolds()
        launchReviewSuspended = false
        knownWorkspace?.showTabMessage(Self.unkeptTextNotice)
        DispatchQueue.main.async { [weak self] in self?.deliverLaunchInventory() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        launchReviewSuspended = true
        // AppKit's own review may already have been accepted, with every close noted. A held
        // document whose text changed since and cannot be written and verified again, or no
        // longer fits a bound, must not be closed on the strength of its earlier copy: the quit
        // is refused, everything is open again, and that earlier copy is still on disk.
        if !reviewingTermination, !renewQuitHolds() {
            refuseQuitForUnkeptText()
            return .terminateCancel
        }
        if NSDocumentController.shared.documents.allSatisfy({ !$0.isDocumentEdited }) {
            commitSession()
            closeAllForTermination()
            return .terminateNow
        }
        guard !reviewingTermination else { return .terminateLater }
        reviewingTermination = true
        initializedCompare?.cancelPendingSavedComparisons()
        automaticSession?.beginReview(knownWorkspace)
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
        var didReviewAll = didReviewAll
        // Defence in depth for a review that says every document was reviewed: the holds are
        // taken again, and an edited untitled document that is still registered (so nobody was
        // asked about it) and is not held is never closed. The quit is refused instead.
        if didReviewAll, !(renewQuitHolds() && !hasUnkeptUntitledDocument) {
            didReviewAll = false
            knownWorkspace?.showTabMessage(Self.unkeptTextNotice)
        }
        if didReviewAll {
            commitSession()
            closeAllForTermination()
        } else {
            automaticSession?.cancelReview()
            releaseQuitHolds()
        }
        reviewingTermination = false
        replyToTerminate(didReviewAll)
        if !didReviewAll {
            launchReviewSuspended = false
            DispatchQueue.main.async { [weak self] in self?.deliverLaunchInventory() }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        Self.updateHistoryTitles(in: menu, responder: (NSApp.modalWindow ?? NSApp.keyWindow)?.firstResponder)
    }
    static func updateHistoryTitles(in menu: NSMenu, responder: NSResponder?) {
        var view = responder as? NSView
        while let current = view, !(current is TTEditor) { view = current.superview }
        let editor = view as? TTEditor
        for item in menu.items {
            guard let id = item.representedObject as? String, id == "undo" || id == "redo" else { continue }
            let redo = id == "redo", base = redo ? EditorCommand.redo.title : EditorCommand.undo.title
            if let name = editor?.historyName(redo: redo) {
                item.title = base + " " + name
            } else if editor == nil, let manager = responder?.undoManager {
                item.title = redo ? manager.redoMenuItemTitle : manager.undoMenuItemTitle
            } else {
                item.title = base
            }
        }
    }
    @discardableResult func openHelpDocument(welcome: Bool) throws -> TextDocument {
        let name = welcome ? "TextTank-Welcome" : "TextTank-User-Guide"
        guard let url = helpResourceDirectory?.appendingPathComponent(name + ".txt") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try DocumentFactory.makeUntitled(
            prepare: { document in
                try document.read(from: data, ofType: TextDocument.plainTextType)
                document.displayName = welcome ? "Welcome to TextTank" : "TextTank User Guide"
            },
            // Help is prose in long paragraphs; it is read wrapped whatever the wrap setting is.
            populate: { $0.editor.wrap = true })
    }
    @objc func openUserGuide(_ sender: Any?) {
        do { try openHelpDocument(welcome: false) } catch { TTAlert.present(error) }
    }
    @objc func openWelcome(_ sender: Any?) {
        do { try openHelpDocument(welcome: true) } catch { TTAlert.present(error) }
    }
    /// The optional online project page.
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
    @objc func actualSize(_ sender: Any?) {
        if let comparison = CompareController.key {
            comparison.resetComparisonZoom()
        } else {
            currentEditor?.resetZoomLevel()
        }
    }
    @objc func nextDocumentTab(_ sender: Any?) { cycleDocumentTab(1) }
    @objc func previousDocumentTab(_ sender: Any?) { cycleDocumentTab(-1) }
    private func cycleDocumentTab(_ direction: Int) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        WorkspaceWindowController.current.cycle(direction)
    }
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
        return recoveryPromptText(count: snapshots.count, listed: listed)
    }
    nonisolated static func recoveryPromptText(headers: [RecoveryHeader], limit: Int = 12) -> String {
        let listed = headers.prefix(limit).map { header in
            "• " + SnapshotLabel.line(originalURL: header.originalURL, saved: header.savedAt)
        }
        return recoveryPromptText(count: headers.count, listed: listed)
    }
    nonisolated private static func recoveryPromptText(count: Int, listed: [String]) -> String {
        let more = count > listed.count ? ["…and \(count - listed.count) more"] : []
        return
            "Found \(count) recovery snapshot\(count == 1 ? "" : "s"). Recovered content opens as new unsaved documents; original files are not changed. Later keeps the snapshots and asks again at the next launch.\n\n"
            + (listed + more).joined(separator: "\n")
    }
    /// The Recover branch of the launch prompt. Documents are opened one at a time, so the
    /// snapshots before one that fails stay open when the error is shown.
    @discardableResult func openRecovered(_ snapshots: [RecoverySnapshot], originals: [URL: TextDocument] = [:]) throws
        -> [TextDocument]
    {
        var opened = [TextDocument]()
        for snapshot in snapshots {
            var group: String?
            if let url = SnapshotLabel.origin(of: snapshot)?.standardizedFileURL,
                let original = originals[url], original.isOpen, let host = original.presentation?.host,
                let pane = host.presentation(for: original.runtimeID)
            {
                host.activate(pane, focus: false, explicit: false)
                group = host.groupLabel(host.model.focusedGroup)
            }
            opened.append(try TextDocument.openRecovered(snapshot, originalGroup: group))
        }
        return opened
    }
    private func restoreRecovery(_ result: Result<RecoveryInventory, Error>, originals: [URL: TextDocument]) {
        do {
            let scan = try result.get()
            let live = Set(NSDocumentController.shared.documents.compactMap { ($0 as? TextDocument)?.recoveryID })
            let headers = scan.headers.filter { !live.contains($0.id) }
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
            guard !headers.isEmpty else { return }
            let alert = TTAlert()
            alert.messageText = "Recover unsaved documents?"
            alert.informativeText = Self.recoveryPromptText(headers: headers)
            alert.addButton(withTitle: "Recover")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Discard…")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                for header in headers {
                    try openRecovered([TextDocument.recovery.load(listed: header)], originals: originals)
                }
            case .alertThirdButtonReturn:
                let confirm = TTAlert()
                confirm.alertStyle = .warning
                confirm.messageText = "Discard \(headers.count) recovery snapshots?"
                confirm.informativeText =
                    "The unsaved text in these snapshots will be permanently deleted. Original files are not changed. This cannot be undone."
                confirm.addButton(withTitle: "Cancel", role: .cancel)
                confirm.addButton(withTitle: "Discard")
                confirm.buttons.last?.hasDestructiveAction = true
                guard confirm.runModal() == .alertSecondButtonReturn else { return }
                // Only the snapshots listed above, at the revision that was scanned.
                let kept = TextDocument.recovery.discard(listed: headers)
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
