import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

final class EditorWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation,
    NSMenuItemValidation, NSSearchFieldDelegate, NSSplitViewDelegate
{
    let split = NSSplitView()
    /// Holds `split` and, for Preview and Both, the preview pane beside it. The mode logic is in
    /// EditorWindowController+Preview.swift, which is the only writer of the three properties below.
    private(set) lazy var viewContainer = DocumentViewContainer(source: split)
    /// What this tab shows of its document. Every tab starts with Source.
    var viewMode = DocumentViewMode.source
    /// Present only while the tab shows Preview or Both; it owns the preview pane's work.
    var previewCoordinator: PreviewCoordinator?
    let findField = NSSearchField()
    /// Announced: a count or “No matches” that only changes this label is otherwise silent (DS-36).
    let findCount = AnnouncingLabel(labelWithString: "")
    private var findPreview: InlineFindPreview?
    let replaceField = NSTextField()
    let caseBox = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let wordBox = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    let regexBox = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    let findNavigation = NSSegmentedControl(
        labels: ["Previous", "Next"], trackingMode: .momentary, target: nil, action: nil)
    let replaceMatchButton = NSButton(title: "Replace", target: nil, action: nil)
    let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
    private(set) var findBar: NSView?
    private var splitBelowFindBar: NSLayoutConstraint?
    private var splitBelowTabs: NSLayoutConstraint?
    var findBarVisible: Bool { findBar?.isHidden == false }
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private var fullStatusText = "Ready"
    private var compactStatusText = "Ready"
    private var recoveryStatusFailed = false
    var statusText: String { fullStatusText }
    var status: NSTextField { statusLabel }
    func setStatusMessage(_ message: String) {
        guard !recoveryStatusFailed else { return }
        applyStatusMessage(message)
    }
    private func applyStatusMessage(_ message: String, compactMessage: String? = nil) {
        fullStatusText = message
        compactStatusText =
            compactMessage
            ?? StatusMessageSummary.leadingWords(
                message, font: statusLabel.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize))
        updateLeadingStatus()
    }
    func appendStatusMessage(_ suffix: String) { setStatusMessage(fullStatusText + suffix) }
    private func updateLeadingStatus() {
        let compact = compactStatusText
        statusDetails.setLeadingStatus(statusLabel, fullText: fullStatusText, compactText: compact)
        if recoveryStatusFailed {
            statusLabel.toolTip =
                "\(fullStatusText)\n\nSave the document to keep your work. This message clears when a recovery copy is written again."
        } else {
            statusLabel.toolTip = fullStatusText == compact ? nil : fullStatusText
        }
    }
    private let statusDetails = StatusBadgeRow()
    func configureExternalReload() {
        guard let doc = document as? TextDocument else { return }
        statusDetails.setExternalAction(for: doc.externalFile)
    }

    let host: WorkspaceWindowController
    let presentationRoot: NSView
    var hostWindow: NSWindow? { host.window }
    var isActiveTab: Bool { host.active === self }
    var isPresented: Bool {
        !isRetired && host.isPresented(self) && presentationRoot.window === hostWindow && hostWindow?.isVisible == true
            && hostWindow?.isMiniaturized != true
    }
    private var statusTimer: Timer?
    /// Nil when the caller supplies timer ticks itself. The normal hostWindow polls every 0.2 s;
    /// checks can drive the exact same tick path without depending on run-loop scheduling speed.
    var statusTimerInterval: TimeInterval? = 0.2
    /// True while the recurring refresh is scheduled, which is only while the hostWindow is on screen.
    var statusTimerActive: Bool { statusTimer != nil }
    /// Stop the recurring refresh without changing visibility.
    func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
    private(set) var statusClosed = false
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
    private var statusSummaryItems: [StatusItem] = []
    private(set) var secondary: TTEditor?
    private var pendingSplitLayout: WorkspaceLayoutState.Tab?
    /// The pane focused last. Written when the hostWindow's first responder moves into a pane, by
    /// each view's onFocus (see `wire`) and by closeSplit.
    private(set) weak var lastEditor: TTEditor?
    /// Scintilla reports focus only while the hostWindow is key and the application active, so the
    /// first responder is observed as well: a pane chosen in a background hostWindow still counts.
    private(set) var focusObservation: NSKeyValueObservation?
    private(set) var isRetired = false
    private(set) var tabID: TabID?
    func bindTab(_ id: TabID) {
        tabID = id
        if let doc = document as? TextDocument {
            views.forEach { EditorLifetime.bind($0, to: doc, presentation: self) }
        }
    }
    let primaryEditor: TTEditor
    /// The primary view and, while the hostWindow is split, the clone.
    var views: [TTEditor] { [primaryEditor] + (secondary.map { [$0] } ?? []) }
    /// The pane that holds the first responder, otherwise the pane focused last (focus may be
    /// in the find field or another hostWindow). A pure read.
    var activeEditor: TTEditor {
        if let responder = hostWindow?.firstResponder as? NSView,
            let focused = views.last(where: { responder.isDescendant(of: $0) })
        {
            return focused
        }
        return lastEditor ?? primaryEditor
    }
    /// Per-view wiring shared by the primary view and a clone.
    private func wire(_ editor: TTEditor) {
        editor.onFocus = { [weak self, weak editor] in
            // App activation can deliver late focus notifications from hidden or sibling
            // views. Only the mounted editor owning the actual native responder may route.
            guard let self, !self.isRetired, !self.host.isMutatingGroups, self.isPresented,
                let editor, editor.window === self.hostWindow,
                let responder = self.hostWindow?.firstResponder as? NSView,
                responder.isDescendant(of: editor)
            else { return }
            if self.host.active !== self { self.host.tabCommands.cancelReopen() }
            self.host.activate(self, focus: false, explicit: false, preserveSelection: true)
            self.lastEditor = editor
            self.resumeVisibleFindPreview()
            self.updateInlineFindValidation()
            let app = EditorServices.current
            app?.noteActiveController(self)
            app?.macros?.editorDidFocus(editor)
        }
        editor.menu = EditorServices.current?.automations?.contextMenu()
    }
    /// Reading currentEditor never creates the window's shared field editor.
    private func ownsFindFieldEditor(_ responder: NSResponder) -> Bool {
        let fields: [NSTextField] = [findField, replaceField]
        return fields.contains { field in
            guard let current = field.currentEditor() else { return false }
            return current === responder
        }
    }
    @discardableResult private func focusPresentationChrome(explicit: Bool = true) -> Bool {
        guard !isRetired, !statusClosed, !host.isMutatingGroups, !host.tabCommands.isBusy,
            hostWindow?.attachedSheet == nil
        else { return false }
        if host.active !== self { host.tabCommands.cancelReopen() }
        let responder = hostWindow?.firstResponder
        let ownsResponder =
            responder.map {
                ($0 as? NSView)?.isDescendant(of: presentationRoot) == true || ownsFindFieldEditor($0)
            } ?? false
        // The preview, not the hidden source, while the tab shows Preview alone: putting the
        // keyboard in the source would make the tab show Both.
        let typingTarget = keyboardFocusView
        host.activate(self, focus: false, explicit: explicit, preserveSelection: true)
        guard host.active === self else { return false }
        // Keep an existing local field editor or keyboard control. A click in sibling chrome
        // otherwise must move both command routing and the native typing target together.
        return ownsResponder || hostWindow?.makeFirstResponder(typingTarget) == true
    }
    /// Copies the active pane's syntax styles to the other pane after a language or style
    /// change. The lexer itself belongs to the shared document and is never applied twice.
    func syncPaneStyles(from source: TTEditor) {
        for view in views where view !== source { view.adoptSyntaxStyles(from: source) }
    }
    init(document: TextDocument, editor: TTEditor? = nil) {
        primaryEditor = editor ?? document.editor
        host = WorkspaceWindowController.current
        presentationRoot = NSView()
        super.init(window: nil)
        let hostWindow = host.window!
        lastEditor = primaryEditor
        wire(primaryEditor)
        primaryEditor.onReadOnlyAttempt = { [weak document] in document?.noteReadOnlyAttempt() }
        focusObservation = hostWindow.observe(\.firstResponder) { [weak self] hostWindow, _ in
            precondition(Thread.isMainThread)
            MainActor.assumeIsolated {

                guard let self, !self.isRetired, !self.host.isMutatingGroups, self.isPresented,
                    let responder = hostWindow.firstResponder
                else { return }
                let view = responder as? NSView
                let pane = view.flatMap { value in self.views.last(where: { value.isDescendant(of: $0) }) }
                let belongs =
                    view?.isDescendant(of: self.presentationRoot) == true || self.ownsFindFieldEditor(responder)
                guard pane != nil || belongs else { return }
                if let pane {
                    if self.host.active !== self { self.host.tabCommands.cancelReopen() }
                    self.host.activate(self, focus: false, explicit: false, preserveSelection: true)
                    self.lastEditor = pane
                    // Something put the keyboard in the source while only the preview shows
                    // (a search result, a jump): show the source so typing is never invisible.
                    self.revealSource()
                    self.resumeVisibleFindPreview()
                } else {
                    _ = self.focusPresentationChrome(explicit: false)
                }
                self.updateInlineFindValidation()

            }
        }
        if editor == nil {
            EditorServices.current?.settings?.apply(to: primaryEditor)
            if document.deferredLargeFileLanguage != nil { primaryEditor.wrap = false }
        }
        let root = presentationRoot
        split.delegate = self
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(primaryEditor)
        findField.placeholderString = "Find"
        findCount.identifier = .init("editor.find.count")
        findCount.setAccessibilityLabel("Find matches in document")
        findCount.lineBreakMode = .byTruncatingTail
        replaceField.placeholderString = "Replace with"
        findNavigation.target = self
        findNavigation.action = #selector(navigateFromBar(_:))
        findNavigation.setAccessibilityLabel("Navigate matches in document")
        replaceMatchButton.target = self
        replaceMatchButton.action = #selector(replaceSelection(_:))
        replaceMatchButton.setAccessibilityLabel("Replace selected match and find next")
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllFromBar(_:))
        replaceAllButton.setAccessibilityLabel("Replace all matches in current document")
        let doneButton = NSButton(title: "Done", target: self, action: #selector(hideFind(_:)))
        doneButton.setAccessibilityLabel("Close Find in document")
        caseBox.setAccessibilityLabel("Match case in document search")
        wordBox.setAccessibilityLabel("Match whole words in document")
        regexBox.setAccessibilityLabel("Use regular expressions in document")
        let more = NSButton(title: "More…", target: self, action: #selector(showMoreFindOptions(_:)))
        more.setAccessibilityLabel("Open Find and Replace with these options")
        let search = EditorFindBar(
            find: findField, replace: replaceField, navigation: findNavigation,
            count: findCount, flags: [caseBox, wordBox, regexBox],
            replaceActions: [replaceMatchButton, replaceAllButton], more: more, done: doneButton)
        // Return in the field finds the next match, Shift-Return the previous one, Escape closes.
        findField.delegate = self
        replaceField.delegate = self
        for option in [caseBox, wordBox, regexBox] {
            option.target = self
            option.action = #selector(inlineFindOptionsChanged(_:))
        }
        findField.target = self
        findField.action = #selector(findFieldAction(_:))
        findField.sendsWholeSearchString = true
        findField.setAccessibilityLabel("Find in document")
        replaceField.setAccessibilityLabel("Replace selection with")
        // The bar is out of the way until Find is chosen, so the text is the hostWindow's main surface.
        search.isHidden = true
        findBar = search
        // The source split sits inside the container that can place a preview beside it.
        let content = viewContainer
        [search, content, statusDetails].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        NSLayoutConstraint.activate([
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: statusDetails.topAnchor, constant: -2),
            statusDetails.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            statusDetails.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            statusDetails.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -2)
        ])
        splitBelowFindBar = content.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 4)
        splitBelowTabs = content.topAnchor.constraint(equalTo: root.topAnchor)
        splitBelowTabs?.isActive = true
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byClipping
        applyStatusMessage(
            document.currentSaveStateStatus,
            compactMessage: document.compactPausedRecoveryStatus
                ?? (document.recoveredOrigin == nil
                    ? document.currentSaveStateStatus : "Recovered copy — Save As to keep"))
        configureExternalReload()
        statusDetails.largeFileButton.target = self
        statusDetails.largeFileButton.action = #selector(enableLargeFileEditing(_:))
        statusDetails.bindRecorder(EditorServices.current?.macros)
        statusDetails.menuProvider = { [weak self] field in
            guard let self, self.focusPresentationChrome(explicit: false) else { return nil }
            EditorServices.current?.noteActiveController(self)
            self.lastEditor = self.activeEditor
            return self.statusOptionsMenu(field)
        }
        // Editor events make the bar follow an edit or a selection change in the same turn of
        // the run loop; the timer started by visibilityChanged() covers state no event reports.
        stateObserver = NotificationCenter.default.addObserver(
            forName: .TTEditorStateDidChange, object: nil, queue: nil
        ) { [weak self] note in
            precondition(Thread.isMainThread)
            let changed = note.object as? TTEditor
            MainActor.assumeIsolated {
                guard let self, !self.statusClosed, let editor = changed else { return }
                if editor === self.primaryEditor || editor === self.secondary {
                    self.updateInlineFindValidation()
                    if let preview = self.findPreview, preview.editor === editor, preview.revision != editor.revision {
                        self.scheduleFindPreview()
                    }
                    if self.isPresented { self.refreshStatusDetails(source: .editorEvent) }
                }
                // Another tab's view of the same document changes this tab's preview too.
                if let preview = self.previewCoordinator,
                    editor === self.primaryEditor || editor.sharesDocument(with: self.primaryEditor)
                {
                    preview.documentStateChanged()
                }

            }
        }
        // Minimising and restoring a hostWindow changes isVisible without any order call.
        visibilityObservers = [
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification
        ].map {
            NotificationCenter.default.addObserver(forName: $0, object: hostWindow, queue: nil) { [weak self] _ in
                precondition(Thread.isMainThread)
                MainActor.assumeIsolated {

                    self?.visibilityChanged()

                }
            }
        }
        visibilityChanged()
        refreshStatusDetails(for: document)
        updateInlineFindValidation()
        // The first document hostWindow opens where the last one was left. A later tab takes the
        // frame of the visible tab when it is shown, which replaces whatever is applied here.
        // This comes last: the title bar and toolbar set up above change the hostWindow's height.
    }
    private func removeVisibilityObservers() {
        visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
        visibilityObservers = []
    }
    /// Starts the recurring status refresh when the hostWindow comes on screen and stops it when the
    /// hostWindow leaves, so a hidden tab has no timer at all.
    func visibilityChanged() {
        previewVisibilityChanged()
        if !isActiveTab && findPreview != nil { endFindPreview() }
        let visible = isPresented && !statusClosed && statusTimerInterval != nil
        if !visible {
            statusTimer?.invalidate()
            statusTimer = nil
            return
        }
        guard statusTimer == nil else { return }
        let timer = Timer(timeInterval: statusTimerInterval ?? 0.2, repeats: true) { [weak self] _ in
            precondition(Thread.isMainThread)
            MainActor.assumeIsolated {

                self?.statusTimerTick()

            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .default)
        statusTimer = timer
    }
    /// One polling tick. Kept separate from Timer so checks can insert an edit before every tick
    /// and an idle tick after the last edit, even on a busy runner.
    func statusTimerTick() {
        guard isPresented else {
            visibilityChanged()
            return
        }
        refreshStatusDetails(source: .pollingTick)
        statusTickRevision = (document as? TextDocument)?.editor.revision
    }
    /// A failed recovery write is shown in red with a tooltip as well as in words, and stays
    /// until the document reports a successful write.
    private var transientStatus: (message: String, id: UUID)?
    /// Says why something the person just did had no effect, in the status line for a few seconds
    /// and to assistive technology, then shows the save state again. A standing recovery failure
    /// is never replaced.
    func showTransientStatus(
        _ message: String, compactMessage: String? = nil, seconds: TimeInterval = 4, announce: Bool = true
    ) {
        guard transientStatus?.message != message else { return }
        if announce { Announce.say(message, from: hostWindow) }
        guard let doc = document as? TextDocument, doc.lastRecoveryError == nil, !recoveryStatusFailed else { return }
        let id = UUID()
        transientStatus = (message, id)
        applyStatusMessage(message, compactMessage: compactMessage)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak doc] in
            guard let self, self.transientStatus?.id == id else { return }
            self.transientStatus = nil
            if let doc, doc.lastRecoveryError == nil {
                self.showRecoveryStatus(doc.currentSaveStateStatus, failed: false)
            }
        }
    }
    func showRecoveryStatus(
        _ message: String, failed: Bool, failureSummary: String = "⚠︎ Recovery copy not written",
        preservingTransient: Bool = false
    ) {
        // The expiry handler reads the latest save state. A completed recovery copy
        // need not cut short feedback from the command the person just performed.
        if preservingTransient && !failed && transientStatus != nil { return }
        transientStatus = nil
        recoveryStatusFailed = failed
        if failed, fullStatusText != message { Announce.say(message, from: hostWindow) }
        let doc = document as? TextDocument
        let compact =
            doc?.compactPausedRecoveryStatus
            ?? (doc?.recoveredOrigin == nil ? message : "Recovered copy — Save As to keep")
        applyStatusMessage(message, compactMessage: failed ? failureSummary : compact)
        // The failure is carried by the words and the symbol; full-strength label colour keeps it
        // readable in both appearances, where small red text was not.
        statusLabel.textColor = failed ? .labelColor : .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: failed ? .semibold : .regular)
        updateLeadingStatus()
    }
    enum StatusRefreshSource {
        case explicit, editorEvent, pollingTick
    }
    /// Updates the cheap badges immediately. Only a polling tick can recognize an idle interval;
    /// a queued editor event after the tick observed an edit is not an idle observation (V32-01).
    /// Explicit action refreshes keep their immediate metrics capture.
    func refreshStatusDetails(for suppliedDocument: TextDocument? = nil, source: StatusRefreshSource = .explicit) {
        guard let doc = suppliedDocument ?? document as? TextDocument else { return }
        statusDetails.showsLargeFileAction = doc.deferredLargeFileLanguage != nil
        statusRefreshCount += 1
        // Any refresh in a hostWindow on screen restarts a missing timer, the editor-event path included.
        if statusTimer == nil { visibilityChanged() }
        let editor = activeEditor, info = editor.statusInfo
        let revision = doc.editor.revision
        let allowsMetricsCapture =
            isPresented && (source == .explicit || (source == .pollingTick && statusTickRevision == revision))
        if statusRevision != revision && !statusMetricsPending && allowsMetricsCapture {
            // Capture the authoritative bytes in one copy on main; the scan happens off-main.
            // One in-flight task bounds work for rapid edits.
            let bytes = doc.editor.utf8Data
            statusMetricsPending = true
            statusMetricsCaptureCount += 1
            let deliver: @MainActor @Sendable (Int, String) -> Void = { [weak self, weak doc] count, eol in
                guard let self else { return }
                self.statusMetricsPending = false
                guard let doc, self.document === doc, doc.editor.revision == revision else { return }
                self.cachedCharacterCount = count
                self.cachedEndings = eol
                self.statusRevision = revision
                if self.isPresented { self.refreshStatusDetails() }
            }
            DispatchQueue.global(qos: .utility).async {
                let (count, eol) = StatusMetrics.scan(bytes)
                DispatchQueue.main.async { deliver(count, eol) }
            }
        }
        let language =
            EditorServices.current?.languages?.profile(identifier: doc.languageIdentifier)?.title
            ?? (doc.languageIdentifier == LanguageProfile.plainTextID ? "Plain Text" : doc.languageIdentifier)
        let eol =
            cachedEndings.isEmpty ? ([0: "CRLF", 1: "CR", 2: "LF"][info.eol.rawValue] ?? "LF") : cachedEndings
        let indentation =
            (info.useTabs == true ? "Tabs" : "Spaces") + ": \(info.tabWidth)"
        // VoiceOver names each text area after its document, and after its pane in a split view.
        for (index, pane) in views.enumerated() {
            let name =
                (doc.displayName ?? "Untitled")
                + (views.count > 1 ? (index == 0 ? ", first pane" : ", second pane") : "")
            if pane.accessibilityDocumentName != name { pane.accessibilityDocumentName = name }
        }
        var items: [StatusItem] = [
            .init(field: .document, text: doc.displayName + (doc.isDocumentEdited ? " *" : "")),
            .init(field: .bookmarks, text: Strings.count(doc.editor.bookmarkCount, .bookmark)),
            .init(field: .language, text: language),
            .init(
                field: .position,
                text:
                    "Ln \(Strings.number(info.line)), Col \(Strings.number(info.column))"
            ),
            .init(field: .characters, text: Strings.count(cachedCharacterCount, .character)),
            .init(field: .lines, text: Strings.count(info.lines, .line))
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
        if cachedSelectedCount > 0 {
            items.append(.init(field: .selectedCharacters, text: Strings.count(cachedSelectedCount, .character)))
        }
        if editor.selectionCount > 1 {
            items.append(.init(field: .selections, text: Strings.count(editor.selectionCount, .selection)))
        }
        items += [
            .init(
                field: .font,
                text: String(
                    format: Strings.text("status.textSize", "Text size %@ pt"),
                    Strings.points(info.fontSize))),
            .init(field: .indent, text: indentation),
            .init(field: .encoding, text: doc.format.encoding.displayName + (doc.format.bom ? " BOM" : "")),
            .init(field: .eol, text: eol), .init(field: .wrap, text: editor.wrap ? "Wrap" : "No Wrap")
        ]
        if editor.readOnly { items.append(.init(field: .readOnly, text: "Read Only")) }
        statusSummaryItems = items
        let rowOrder: [StatusField] = [.position, .selectedCharacters, .selections, .language, .indent, .encoding, .eol]
        statusDetails.update(rowOrder.compactMap { field in items.first { $0.field == field } })
    }
    /// The menu a status bar field opens, for the active pane. Building it changes nothing, so
    /// its wording can be checked without showing it.
    @objc private func showBulkChanges(_ sender: Any?) {
        guard let receipt = (document as? TextDocument)?.bulkReceipt, let before = receipt.before,
            let after = receipt.after, let compare = EditorServices.current?.compare else { return }
        Task { [weak self] in
            do {
                let pair = try await Task.detached {
                    try (TextSnapshot(bytes: before, source: .freeText(UUID()), label: receipt.name + " — Before"),
                         TextSnapshot(bytes: after, source: .freeText(UUID()), label: receipt.name + " — After"))
                }.value
                _ = try await compare.open(original: .snapshot(pair.0), modified: .snapshot(pair.1))
            } catch { self?.showTransientStatus(error.localizedDescription) }
        }
    }
    func statusOptionsMenu(_ key: String) -> NSMenu? {
        let field =
            key == "count"
            ? StatusField.characters : (key == "selection" ? .selectedCharacters : StatusField(rawValue: key))
        guard let field else { return nil }
        return statusOptionsMenu(field)
    }
    func statusOptionsMenu(_ key: StatusField) -> NSMenu? {
        guard let doc = document as? TextDocument else { return nil }
        let editor = activeEditor, info = editor.statusInfo
        let app = EditorServices.current
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(
            _ title: String, _ action: Selector, _ target: AnyObject, _ value: String? = nil, _ checked: Bool = false,
            _ enabled: Bool = true
        ) {
            let item = menu.addItem(
                title: title, action: action, target: target, representedObject: value,
                isEnabled: enabled, state: checked ? .on : .off)
            if let value, let command = EditorCommand(rawValue: value) {
                item.keyEquivalent =
                    command.isShortcutAssignable
                    ? app?.settings?.value.shortcut(for: value) ?? command.defaultMenuShortcut
                    : command.defaultMenuShortcut
                item.isEnabled =
                    enabled && (!TTEditor.commandModifiesText(command.nativeIdentifier) || !editor.readOnly)
                if command.isToggle { item.state = isChecked(command, in: editor) ? .on : .off }
            }
        }
        func command(_ value: EditorCommand) { add(value.title, #selector(statusOption(_:)), self, value.rawValue) }
        func heading(_ title: String) {
            menu.addItem(title: title, action: nil, isEnabled: false)
        }
        switch key {
        case .encoding:
            heading("Reload using encoding…")
            for encoding in FileEncoding.allCases {
                add(
                    encoding.displayName, #selector(TextDocument.reloadEncoding(_:)), doc, encoding.rawValue,
                    doc.format.encoding == encoding, doc.fileURL != nil)
            }
            menu.addItem(.separator())
            heading("Convert document encoding (save separately)")
            for target in FileFormat.convertTargets {
                add(
                    target.title, #selector(TextDocument.convertEncoding(_:)), doc, target.code,
                    doc.format == target.format, !editor.readOnly)
            }
        case .indent:
            heading("Indentation for this document")
            add("Tabs", #selector(statusOption(_:)), self, "tabs", info.useTabs == true)
            add("Spaces", #selector(statusOption(_:)), self, "spaces", info.useTabs == false)
            menu.addItem(.separator())
            for n in [2, 3, 4, 8] {
                add("Width: \(n)", #selector(statusOption(_:)), self, "width.\(n)", info.tabWidth == n)
            }
            if let settings = app?.settings {
                menu.addItem(.separator())
                add("Default Editor Settings…", #selector(SettingsController.showSettings(_:)), settings)
            }
        case .eol:
            heading("Convert document line endings")
            for (name, code) in [("LF — Unix / macOS", "LF"), ("CRLF — Windows", "CRLF"), ("CR — Classic Mac", "CR")] {
                let current =
                    cachedEndings.isEmpty ? [0: "CRLF", 1: "CR", 2: "LF"][info.eol.rawValue] : cachedEndings
                add(name, #selector(convertEOL(_:)), self, code, current == code, !editor.readOnly)
            }
        case .wrap:
            add("Wrap Lines", #selector(statusOption(_:)), self, "wrap.on", editor.wrap)
            add("No Wrap", #selector(statusOption(_:)), self, "wrap.off", !editor.wrap)
        case .font:
            heading("Text size for this view")
            command(.zoomIn)
            command(.zoomOut)
            if let languages = app?.languages {
                menu.addItem(.separator())
                menu.addItem(languages.styleSettingsMenuItem())
            }
        case .language:
            if let languages = app?.languages {
                for item in languages.languageMenuItems() {
                    item.state = (item.representedObject as? String) == doc.languageIdentifier ? .on : .off
                    menu.addItem(item)
                }
            }
        case .bookmarks:
            for value: EditorCommand in [.bookmarkToggle, .bookmarkNext, .bookmarkPrevious] { command(value) }
        case .position:
            add("Go to Line…", #selector(statusOption(_:)), self, "goToLine")
            menu.addItem(.separator())
            for item in statusSummaryItems
            where [.bookmarks, .characters, .lines, .font, .wrap, .readOnly].contains(item.field) {
                heading(item.text)
            }
            for item in statusSummaryItems where [.selectedCharacters, .selections].contains(item.field) {
                heading(String(format: Strings.text("status.fieldValue", "%@: %@"), item.field.displayName, item.text))
            }
            command(.selectAll)
            add("Clear Selection", #selector(statusOption(_:)), self, "clearSelection")
            for field: StatusField in [.bookmarks, .font, .wrap, .language, .indent, .encoding, .eol] {
                guard let submenu = statusOptionsMenu(field) else { continue }
                let item = NSMenuItem(title: field.displayName, action: nil, keyEquivalent: "")
                item.submenu = submenu
                menu.addItem(item)
            }
        case .document, .readOnly:
            if let receipt = doc.bulkReceipt {
                heading(receipt.summary)
                add("Show Changes", #selector(showBulkChanges(_:)), self, nil, false, receipt.before != nil)
                menu.addItem(.separator())
            }
            add("Save", #selector(NSDocument.save(_:)), doc)
            add("Save As…", #selector(NSDocument.saveAs(_:)), doc)
            add("Read Only", #selector(TextDocument.toggleReadOnly(_:)), doc, nil, editor.readOnly)
        case .characters, .lines, .selectedCharacters, .selections:
            command(.selectAll)
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
        case "tabs", "spaces": editor.configureTabWidth(info.tabWidth, useTabs: id == "tabs")
        case "wrap.on", "wrap.off": editor.wrap = id == "wrap.on"
        case "clearSelection": Self.clearSelection(in: editor, macros: EditorServices.current?.macros)
        case "goToLine": goToLine(sender)
        default:
            if id.hasPrefix("width."), let width = Int(id.dropFirst(6)) {
                editor.configureTabWidth(width, useTabs: info.useTabs)
            } else {
                do { try perform(command: id) } catch is EditorCommandFailure {
                    reportCommandFailure(EditorCommandFailure.unsupported.localizedDescription)
                } catch { TTAlert.explain(error) }
            }
        }
        refreshStatusDetails()
    }
    /// Search > Go to Line… and the position field of the status bar.
    private var linePanel: FormPanel?
    @objc func goToLine(_ sender: Any?) {
        guard !statusClosed else { return }
        revealSource()
        if let linePanel {
            linePanel.window.makeKeyAndOrderFront(nil)
            return
        }
        let editor = activeEditor
        let revision = editor.revision
        let macros = EditorServices.current?.macros
        let form = FormPanel(
            title: "Go to Line", identifier: "TextTank.GoToLine", size: NSSize(width: 480, height: 300))
        linePanel = form
        form.onClose = { [weak self] in self?.linePanel = nil }
        let input = form.field(
            "Line number", value: String(editor.statusInfo.line), identifier: "goToLine.line")
        NumericInput.configure(input)
        form.button("Go", identifier: "goToLine.go") { [weak self, weak editor] in
            guard let self, form.commitEditing() else { return }
            do {
                guard !self.statusClosed, let editor, EditorLifetime.isOpen(editor), editor.revision == revision else {
                    throw FormFailure.documentChanged
                }
                guard let line = NumericInput.integer(input, signed: true),
                    Self.goToLine(line, in: editor, macros: macros)
                else {
                    throw GoToLineFailure(last: editor.statusInfo.lines)
                }
                form.close()
                EditorLifetime.activate(editor)
                self.refreshStatusDetails()
            } catch { form.showValidation(error, field: input) }
        }.keyEquivalent = "\r"
        form.button("Cancel", identifier: "goToLine.cancel", cancel: true) { form.close() }
        form.window.initialFirstResponder = input
        form.show()
    }
    /// Puts the caret at the start of a line, counted from 1, on the engine's own line model.
    /// False, with nothing changed, for a line the document does not have or a view that has
    /// left its hostWindow. Does not touch a macro recording; the dialog passes the recorder.
    static func goToLine(_ line: Int, in editor: TTEditor) -> Bool {
        guard EditorLifetime.isOpen(editor) else { return false }
        return goToLine(line, in: editor, macros: nil)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        EditorToolbarCommand.allCases.map(\.identifier) + [.flexibleSpace, .init("TextTank.Automations")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The tab strip keeps its close controls; New has one toolbar home.
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar: Bool
    ) -> NSToolbarItem? {
        if let command = EditorToolbarCommand(rawValue: identifier.rawValue) { return command.makeItem() }
        guard identifier.rawValue == "TextTank.Automations" else { return nil }
        return EditorServices.current?.automations?.makeToolbarItem()
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let menu = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
        let enabled = validateMenuItem(menu)
        if item.action == #selector(clone(_:)) {
            item.menuFormRepresentation?.state = menu.state
            let help =
                secondary == nil
                ? EditorToolbarCommand.split.scope
                : Strings.text("toolbar.split.close.help", "Return this tab to one view of the document.")
            if item.toolTip != help {
                item.toolTip = help
                item.image = NSImage(
                    systemSymbolName: secondary == nil ? EditorToolbarCommand.split.symbol : "checkmark.rectangle",
                    accessibilityDescription: help)
                if let hostWindow { EditorToolbarAccessibility.apply(to: hostWindow) }
            }
        }
        return enabled
    }
    private func refreshCloneToolbar() { host.validateToolbar() }
    func toolbarWillAddItem(_ notification: Notification) { host.toolbarWillAddItem(notification) }
    func toolbarDidRemoveItem(_ notification: Notification) { host.toolbarDidRemoveItem(notification) }
    func saveToolbarArrangement() { host.saveToolbarArrangement() }
    func refreshAutomationToolbar() { host.refreshAutomationToolbar() }
    nonisolated override func responds(to selector: Selector!) -> Bool {
        let inherited = super.responds(to: selector)
        guard !inherited, Thread.isMainThread else { return inherited }
        return MainActor.assumeIsolated {
            guard let doc = document as? TextDocument, doc.isOpen else { return false }
            return doc.responds(to: selector)
        }
    }
    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if Thread.isMainThread {
            let target: TextDocument? = MainActor.assumeIsolated {
                guard let doc = document as? TextDocument, doc.isOpen, doc.responds(to: selector) else { return nil }
                return doc
            }
            if let target { return target }
        }
        return super.forwardingTarget(for: selector)
    }
    override func showWindow(_ sender: Any?) { host.show(self, sender: sender) }
    override func close() { presentationRoot.removeFromSuperview() }
    override func synchronizeWindowTitleWithDocumentName() { host.metadataChanged() }
    override func setDocumentEdited(_ dirtyFlag: Bool) { host.metadataChanged() }
    func retireTab(inFavorOf successor: TTEditor) {
        guard !isRetired else { return }
        isRetired = true
        let retiring = views
        // Invalidate every pane before forms, macro hooks or retirement notifications
        // can synchronously query another pane in this retiring tab.
        retiring.forEach { EditorLifetime.retire($0) }
        prepareForClose()
        // Detach the whole native root before removing its children: AppKit may retain the
        // first removed container, but it must not retain retired editors or this adapter.
        presentationRoot.removeFromSuperview()
        for view in retiring {
            EditorServices.current?.macros?.editorWillRetire(view)
            view.retire(inFavorOf: successor)
            view.onMacroStep = nil
            view.onChange = nil
            view.menu = nil
            view.removeFromSuperview()
        }
        secondary = nil
        lastEditor = nil
        presentationRoot.subviews.forEach { $0.removeFromSuperview() }
    }
    func prepareForClose() {
        tearDownPreview()
        linePanel?.close()
        saveToolbarArrangement()
        endFindPreview(restore: false)
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
        guard !CompareCommandScope.blocksWorkspace else { return }
        guard let id = sender.representedObject as? String else { return }
        if (NSApp.modalWindow ?? NSApp.keyWindow)?.firstResponder is NSTextView {
            // Native editing selectors reach the field directly; this is only the custom-command path.
            reportCommandFailure(
                "This command is unavailable while a text field is being edited. Return to the document, then try again."
            )
            return
        }
        do { try perform(command: id) } catch is EditorCommandFailure {
            reportCommandFailure(EditorCommandFailure.unsupported.localizedDescription)
        } catch { TTAlert.present(error) }
    }
    private func reportCommandFailure(_ message: String) {
        NSSound.beep()
        showTransientStatus(
            message,
            compactMessage: Strings.text("status.commandUnavailable", "This editor command is unavailable."))
    }
    /// The full error can begin with an arbitrarily long file name. The failure stays visible.
    func showSearchFailure(_ error: Error, seconds: TimeInterval = 4, announce: Bool = true) {
        showTransientStatus(
            error.localizedDescription,
            compactMessage: Strings.text("status.searchFailed", "Search could not complete."), seconds: seconds,
            announce: announce)
    }
    /// Runs one editor command on the active editor. A command that edits text is refused with the
    /// read-only reason before anything else happens, so a macro recording is left as it was.
    func perform(command id: String) throws {
        guard !CompareCommandScope.blocksWorkspace else { throw EditorCommandFailure.unsupported }
        let editor = activeEditor
        if id.hasPrefix("transform."), let transform = EditorTransform(rawValue: String(id.dropFirst(10))) {
            try editor.requireWritable()
            EditorServices.current?.macros?.invalidateRecording(
                reason: "This text transform is not yet recorded.")
            let capture = BulkChangeCapture(editor, name: transform.title)
            try transform.apply(to: editor)
            capture?.finish()
            return
        }
        guard let command = EditorCommand(rawValue: id) else { throw EditorCommandFailure.unsupported }
        if TTEditor.commandModifiesText(command.nativeIdentifier) { try editor.requireWritable() }
        let recorder = EditorServices.current?.macros
        if let preference = command.viewPreference, let settings = EditorServices.current?.settings {
            // One stored choice for every editor view; the settings write applies it to all of them.
            recorder?.willExecuteCommand(id, on: editor)
            settings.toggle(preference)
            return
        }
        let finishing: ((Bool) -> Void)?
        if command == .bookmarkCutLines || command == .bookmarkDeleteLines {
            finishing = recorder?.prepareUnrecordedChange(
                in: editor, reason: "The command ‘\(command.title)’ cannot be recorded. No partial macro will be saved."
            )
        } else {
            recorder?.willExecuteCommand(id, on: editor)
            finishing = nil
        }
        let before = editor.revision
        let usesClipboard = command == .bookmarkCutLines || command == .bookmarkCopyLines
        let board = usesClipboard ? RuntimeEnvironment.current.generalPasteboard() : nil
        let priorName = editor.exchangeNextUndoName(command.title)
        let accepted = editor.executeCommand(command.nativeIdentifier, using: board)
        _ = editor.exchangeNextUndoName(priorName)
        finishing?(accepted && editor.revision != before)
        guard accepted else { throw EditorCommandFailure.unsupported }
    }
    /// A toggle's checkmark. The three stored View choices show the Editor Settings value, which
    /// every view has; the other toggles show the given view's own state.
    private func isChecked(_ command: EditorCommand, in editor: TTEditor) -> Bool {
        if let preference = command.viewPreference, let settings = EditorServices.current?.settings {
            return settings.isEnabled(preference)
        }
        return editor.commandIsChecked(command.nativeIdentifier)
    }
    deinit {
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated {

            statusTimer?.invalidate()
            focusObservation?.invalidate()
            if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
            visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }

        }
    }
    private func setFindBar(visible: Bool) {
        guard let findBar, findBar.isHidden == visible else { return }
        splitBelowTabs?.isActive = !visible
        findBar.isHidden = !visible
        splitBelowFindBar?.isActive = visible
    }
    /// The text other apps and the Find and Replace hostWindow last searched for.
    static var findPasteboardText: String {
        get { RuntimeEnvironment.current.readFindText() }
        set { RuntimeEnvironment.current.writeFindText(newValue) }
    }
    /// The advanced hostWindow and inline bar share the query without scheduling another search.
    func acceptSharedFindText(_ text: String) {
        endFindPreview()
        cancelInlineSearch()
        findField.stringValue = text
        updateInlineFindValidation()
    }
    func endFindPreview(restore: Bool = true) {
        let ending = findPreview
        findPreview = nil
        ending?.cancel(restore: restore)
        findCount.stringValue = ""
        findCount.toolTip = nil
        findCount.setAccessibilityHelp(nil)
    }
    func resumeVisibleFindPreview() {
        if findBarVisible && findPreview?.editor !== activeEditor {
            syncFindFlags()
            scheduleFindPreview()
        }
    }
    private func syncFindFlags() {
        guard let search = EditorServices.current?.searchController else { return }
        let flags = search.sharedOptions(query: "", replacement: "")
        caseBox.state = flags.matchCase ? .on : .off
        wordBox.state = flags.wholeWord ? .on : .off
        regexBox.state = flags.mode == .regularExpression ? .on : .off
    }
    func acceptSharedFindFlags() {
        guard findBarVisible || inlineSearchPending else { return }
        syncFindFlags()
        cancelInlineSearch()
        if findBarVisible && isActiveTab { scheduleFindPreview() }
    }
    private func inlineOptions(replacement: String = "") -> SearchOptions {
        EditorServices.current?.searchController?.sharedOptions(query: findField.stringValue, replacement: replacement)
            ?? SearchOptions(query: findField.stringValue, replacement: replacement)
    }
    private func scheduleFindPreview() {
        guard findBarVisible, isActiveTab, !statusClosed, let document = document as? TextDocument, document.isOpen
        else {
            endFindPreview()
            return
        }
        let editor = activeEditor
        if findPreview?.editor !== editor || findPreview?.revision != editor.revision {
            endFindPreview()
            findPreview = InlineFindPreview(editor)
        }
        let options = inlineOptions()
        findCount.stringValue = ""
        findCount.toolTip = nil
        findCount.setAccessibilityHelp(nil)
        findPreview?.search(
            options: options,
            isCurrent: { [weak self, weak editor] in
                guard let self, let editor else { return false }
                return self.findBarVisible && self.isActiveTab && self.activeEditor === editor
                    && !self.statusClosed && self.findField.stringValue.utf8.elementsEqual(options.query.utf8)
                    && self.inlineOptions() == options
            },
            publish: { [weak self] message, detail in
                self?.findCount.stringValue = message
                self?.findCount.toolTip = detail ?? message
                self?.findCount.setAccessibilityHelp(detail)
            })
    }
    @objc func showFind(_ sender: Any?) {
        guard (document as? TextDocument)?.isOpen == true else { return }
        revealSource()
        host.activate(self, focus: false)
        cancelInlineSearch()
        // Remember the pane the find bar acts on before focus leaves it.
        lastEditor = activeEditor
        setFindBar(visible: true)
        syncFindFlags()
        endFindPreview()
        findPreview = InlineFindPreview(activeEditor)
        if findField.stringValue.isEmpty { findField.stringValue = Self.findPasteboardText }
        hostWindow?.makeFirstResponder(findField)
        findField.selectText(nil)
        updateInlineFindValidation()
        scheduleFindPreview()
    }
    @objc func hideFind(_ sender: Any?) { closeFindBar(returningKeyboard: true) }
    /// Closes the find bar. `returningKeyboard` is false when the bar is closed for a tab that
    /// does not hold the keyboard (its mode was changed from its tab while another tab is in
    /// use): the first responder must then stay where it is.
    func closeFindBar(returningKeyboard: Bool) {
        endFindPreview()
        cancelInlineSearch()
        let editor = activeEditor
        setFindBar(visible: false)
        if returningKeyboard { hostWindow?.makeFirstResponder(editor) }
    }
    /// Command-E: the selected text becomes the text to find, here and in other apps.
    @objc func useSelectionForFind(_ sender: Any?) {
        endFindPreview(restore: false)
        cancelInlineSearch()
        let selected = activeEditor.selectedText
        guard !selected.isEmpty, !selected.contains(where: \.isNewline) else {
            NSSound.beep()
            showTransientStatus("Select text on one line to use it for Find.")
            return
        }
        findField.stringValue = selected
        Self.findPasteboardText = selected
        EditorServices.current?.searchController?.queryField.stringValue = selected
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
    func controlTextDidBeginEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === findField || field === replaceField {
            _ = focusPresentationChrome()
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === findField || field === replaceField {
            _ = focusPresentationChrome()
            cancelInlineSearch()
            if field === findField { scheduleFindPreview() }
        }
    }
    @objc private func inlineFindOptionsChanged(_ sender: Any?) {
        guard let button = sender as? NSButton else { return }
        let enabled = button.state == .on
        guard focusPresentationChrome(), let search = EditorServices.current?.searchController else { return }
        let flag: SearchController.InlineFlag =
            button === regexBox ? .regex : (button === wordBox ? .wholeWord : .matchCase)
        search.setInlineFlag(flag, enabled: enabled)
    }
    @objc private func navigateFromBar(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        performFind(backwards: sender.selectedSegment == 0)
    }
    @objc private func showMoreFindOptions(_ sender: Any?) {
        guard focusPresentationChrome(), let search = EditorServices.current?.searchController else { return }
        hideFind(nil)
        search.showFromInline(query: findField.stringValue, replacement: replaceField.stringValue, sender: sender)
    }
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
    @objc func replaceAllFromBar(_ sender: Any?) {
        guard focusPresentationChrome() else { return }
        let editor = activeEditor
        guard !editor.readOnly else {
            (document as? TextDocument)?.noteReadOnlyAttempt()
            return
        }
        guard editor.selectionCount == 1 else {
            showTransientStatus("Use a single selection before replacing all matches.")
            return
        }
        beginInlineSearch(action: "replaceAll", focusEditor: true)
    }
    /// Replacing is strict: a caret, several selections or text that is not a match is never inserted into.
    func replaceSelectionFromBar() throws {
        guard focusPresentationChrome() else { return }
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
        findNavigation.isEnabled = ready
        let canReplace =
            ready && !editor.readOnly && editor.selectionCount == 1
            && replaceField.stringValue.utf16.prefix(1_048_577).count <= 1_048_576
        replaceMatchButton.isEnabled = canReplace && editor.selectionStart < editor.selectionEnd
        replaceAllButton.isEnabled = canReplace
    }
    private func cancelInlineSearch() {
        inlineCancellation?.cancel()
        inlineCancellation = nil
        inlineSearchGeneration = UUID()
        inlineSearchPending = false
        updateInlineFindValidation()
    }
    /// Only scheduling and feedback belong to the bar. SearchController owns engine, navigation and replacement.
    private func beginInlineSearch(action: String, focusEditor: Bool, afterReplacement: Bool = false) {
        guard focusPresentationChrome() else { return }
        let editor = activeEditor
        // Menu/button actions commit the field editor and restore typing to the document. Return
        // keeps the field editor, so repeated Return and Shift-Return continue to work (DS-35).
        if focusEditor { hostWindow?.makeFirstResponder(editor) }
        let replacing = action == "replaceOne" || action == "replaceAll"
        let options = inlineOptions(replacement: replacing ? replaceField.stringValue : "")
        cancelInlineSearch()
        guard !options.query.isEmpty, let delegate = EditorServices.current,
            let search = delegate.searchController, let capturedWindow = hostWindow
        else {
            return
        }
        findPreview?.cancel(restore: false)
        findCount.stringValue = ""
        if !afterReplacement {
            Self.findPasteboardText = options.query
            search.queryField.stringValue = options.query
        }
        let token = inlineSearchGeneration, flag = TTSearchCancellation()
        inlineCancellation = flag
        inlineSearchPending = true
        updateInlineFindValidation()
        search.performInline(
            options: options, action: action, on: editor, cancellation: flag,
            isCurrent: { [weak self, weak editor, weak capturedWindow] in
                guard let self, let editor, let capturedWindow else { return false }
                return !self.statusClosed && self.isActiveTab && self.inlineSearchGeneration == token
                    && self.hostWindow === capturedWindow
                    && self.activeEditor === editor && self.findField.stringValue.utf8.elementsEqual(options.query.utf8)
                    && self.inlineOptions(replacement: options.replacement) == options
                    && (!replacing
                        || self.replaceField.stringValue.utf8.elementsEqual(options.replacement.utf8))
            },
            completion: { [weak self, weak editor] result in
                guard let self, self.inlineSearchGeneration == token else { return }
                self.inlineSearchPending = false
                self.inlineCancellation = nil
                self.updateInlineFindValidation()
                switch result {
                case .applied, .replacedAll:
                    self.endFindPreview(restore: false)
                    if self.findBarVisible { self.findPreview = InlineFindPreview(self.activeEditor) }
                    guard let editor else { return }
                    delegate.macros?.recordSearch(.init(options: options, action: action), editor: editor)
                    if case .replacedAll(let count) = result {
                        self.showTransientStatus(
                            count == 1
                                ? "Replaced 1 match. Undo restores it."
                                : "Replaced \(count) matches. Undo restores them.")
                    } else if action == "replaceOne" {
                        // Record the accepted edit now. Cancellation or a stale next result may
                        // leave just this legacy step in the macro, as in the advanced window.
                        self.showTransientStatus("Replaced the selected match. Undo restores it.")
                        self.beginInlineSearch(action: "next", focusEditor: false, afterReplacement: true)
                    } else if afterReplacement {
                        self.showTransientStatus("Replaced the selected match and selected the next match.")
                    }
                case .noMatch:
                    if afterReplacement {
                        self.showTransientStatus("Replaced the selected match. No further match.")
                    } else if action == "replaceAll" {
                        self.showTransientStatus("Replaced 0 matches.")
                    } else if action == "replaceOne" {
                        self.showTransientStatus("Select one match of the Find text before replacing it.")
                    } else {
                        NSSound.beep()
                        let query = options.query
                        self.showTransientStatus(
                            "No matches for “\(query.count > 60 ? String(query.prefix(60)) + "…" : query)”.")
                    }
                case .stale:
                    self.showTransientStatus(
                        afterReplacement
                            ? "Replaced the selected match. The document, selection or Find text changed before the next match."
                            : "The document, selection or Find text changed. Search again.")
                case .cancelled: break
                case .failed(let error):
                    if afterReplacement {
                        self.showTransientStatus(
                            "Replaced the selected match. Find Next failed. " + error.localizedDescription)
                    } else {
                        self.showSearchFailure(error)
                    }
                }
            })
    }
    @objc func clone(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        guard !statusClosed, (document as? TextDocument)?.isOpen == true else { return }
        host.activate(self, focus: false)
        if secondary != nil {
            closeSplit(sender)
            return
        }
        let clone = addClone()
        hostWindow?.makeFirstResponder(clone)
        refreshCloneToolbar()
    }
    private func addClone() -> TTEditor {
        let source = primaryEditor
        let clone = TTEditor(frame: split.bounds)
        // Everything document-level (text, read-only, tab settings, lexer and keyword lists,
        // undo) arrives with the shared document and is not written again here. The new pane
        // copies only what a view owns, from the pane it was cloned from.
        clone.shareDocument(with: source)
        clone.adoptViewState(from: source)
        if let doc = document as? TextDocument { EditorLifetime.bind(clone, to: doc, presentation: self) }
        wire(clone)
        clone.onReadOnlyAttempt = { [weak self] in (self?.document as? TextDocument)?.noteReadOnlyAttempt() }
        secondary = clone
        split.addArrangedSubview(clone)
        split.adjustSubviews()
        split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        clone.layoutSubtreeIfNeeded()
        return clone
    }
    func sessionTab(documentID: DocumentID, pinned: Bool) -> WorkspaceLayoutState.Tab {
        let active = activeEditor
        var state = WorkspaceLayoutState.Tab(
            documentID: documentID, isPinned: pinned, anchorByte: active.selectionAnchor,
            caretByte: active.selectionCaret, firstVisibleLine: active.firstVisibleLine)
        if let secondary {
            let other = active === secondary ? primaryEditor : secondary
            let available = split.bounds.width - split.dividerThickness
            if var pending = pendingSplitLayout, var geometry = pending.split {
                // An unmounted tab has no final pane width. A checkpoint of it
                // must retain the last real viewport until it can be restored.
                pending.isPinned = pinned
                pending.documentID = documentID
                let savedActive = geometry.secondaryActive ? secondary : primaryEditor
                let savedOther = geometry.secondaryActive ? primaryEditor : secondary
                pending.anchorByte = savedActive.selectionAnchor
                pending.caretByte = savedActive.selectionCaret
                geometry.otherAnchorByte = savedOther.selectionAnchor
                geometry.otherCaretByte = savedOther.selectionCaret
                pending.split = geometry
                return recordingViewMode(in: pending)
            }
            let fraction = available > 0 ? primaryEditor.frame.width / available : 0.5
            state.split = .init(
                otherAnchorByte: other.selectionAnchor, otherCaretByte: other.selectionCaret,
                otherFirstVisibleLine: other.firstVisibleLine, otherHorizontalOffset: other.horizontalScrollOffset,
                activeHorizontalOffset: active.horizontalScrollOffset, secondaryActive: active === secondary,
                primaryFraction: min(1, max(0, fraction)))
            state.split?.activeWrapping = wrapping(of: active)
            state.split?.otherWrapping = wrapping(of: other)
        }
        return recordingViewMode(in: state)
    }
    private func wrapping(of editor: TTEditor) -> WorkspaceLayoutState.PaneWrapping {
        editor.wrap ? .wrapped(documentLine: editor.sessionTopDocumentLine, subline: editor.sessionTopSubline)
            : .unwrapped
    }
    func restoreSessionTab(_ tab: WorkspaceLayoutState.Tab) {
        var active = primaryEditor
        pendingSplitLayout = nil
        if let state = tab.split {
            let clone = secondary ?? addClone()
            active = state.secondaryActive ? clone : primaryEditor
            let other = state.secondaryActive ? primaryEditor : clone
            // Establish live, byte-clamped selections immediately, even when the
            // tab is hidden. Only geometry waits for the split's mounted width.
            other.restoreClosedTabView(anchor: state.otherAnchorByte, caret: state.otherCaretByte, firstVisibleLine: 0)
            active.restoreClosedTabView(anchor: tab.anchorByte, caret: tab.caretByte, firstVisibleLine: 0)
            pendingSplitLayout = tab
            applyRestoredSplitIfMounted()
        } else {
            if let clone = secondary { removeClone(clone) }
            active.restoreClosedTabView(anchor: tab.anchorByte, caret: tab.caretByte, firstVisibleLine: tab.firstVisibleLine)
        }
        lastEditor = active
        restoreViewMode(from: tab)
    }
    func applyRestoredSplitIfMounted() {
        guard let tab = pendingSplitLayout, let state = tab.split, let secondary, split.window != nil else { return }
        let available = split.bounds.width - split.dividerThickness
        guard available >= 200 else { return }
        pendingSplitLayout = nil
        split.setPosition(max(100, min(available - 100, available * state.primaryFraction)), ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        let active = state.secondaryActive ? secondary : primaryEditor
        let other = state.secondaryActive ? primaryEditor : secondary
        let deferred = (document as? TextDocument)?.deferredLargeFileLanguage != nil
        func restore(_ pane: TTEditor, _ wrap: WorkspaceLayoutState.PaneWrapping?, _ row: Int, _ x: Int) {
            if let wrap {
                let enabled = !deferred && wrap != .unwrapped
                if pane.wrap != enabled { pane.wrap = enabled }
            }
            if case let .wrapped(line, subline) = wrap {
                pane.scrollTo(documentLine: line, subline: pane.wrap ? subline : 0)
            } else {
                pane.restoreClosedTabView(anchor: pane.selectionAnchor, caret: pane.selectionCaret, firstVisibleLine: row)
            }
            pane.horizontalScrollOffset = x
        }
        restore(other, state.otherWrapping, state.otherFirstVisibleLine, state.otherHorizontalOffset)
        restore(active, state.activeWrapping, tab.firstVisibleLine, state.activeHorizontalOffset)
    }
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat { max(100, proposedMinimumPosition) }
    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat { min(proposedMaximumPosition, splitView.bounds.width - 101) }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.subviews.count == 2 else {
            splitView.subviews.first?.frame = splitView.bounds
            return
        }
        let available = max(0, splitView.bounds.width - splitView.dividerThickness)
        let left =
            available >= 200
            ? max(
                100,
                min(available - 100, splitView.subviews[0].frame.width + (splitView.bounds.width - oldSize.width) / 2))
            : available / 2
        splitView.subviews[0].frame = NSRect(x: 0, y: 0, width: left, height: splitView.bounds.height)
        splitView.subviews[1].frame = NSRect(
            x: left + splitView.dividerThickness, y: 0, width: available - left, height: splitView.bounds.height)
    }
    @objc func closeSplit(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        guard let clone = secondary else { return }
        lastEditor = primaryEditor
        hostWindow?.makeFirstResponder(primaryEditor)
        // Recording across views is not supported; say so even if no focus event was sent.
        EditorServices.current?.macros?.editorDidFocus(primaryEditor)
        removeClone(clone)
        refreshCloneToolbar()
    }
    private func removeClone(_ clone: TTEditor) {
        clone.onFocus = nil
        pendingSplitLayout = nil
        // Deferred results that do not depend on the clone's selection move to the primary view.
        EditorLifetime.retire(clone)
        clone.retire(inFavorOf: primaryEditor)
        clone.removeFromSuperview()
        secondary = nil
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard !statusClosed, !CompareCommandScope.blocksWorkspace else { return false }
        switch item.action {
        case #selector(clone(_:)):
            item.state = secondary == nil ? .off : .on
            return true
        case #selector(closeSplit(_:)): return secondary != nil
        case #selector(setDocumentViewMode(_:)): return validateDocumentViewMode(item)
        case #selector(toggleDocumentPreview(_:)): return validateToggleDocumentPreview(item)
        case #selector(command(_:)):
            if (NSApp.modalWindow ?? NSApp.keyWindow)?.firstResponder is NSTextView { return false }
            guard let id = item.representedObject as? String else { return false }
            if id.hasPrefix("transform."), EditorTransform(rawValue: String(id.dropFirst(10))) != nil {
                return !activeEditor.readOnly
            }
            guard let command = EditorCommand(rawValue: id) else { return false }
            switch command {
            case .bookmarkClearAll, .bookmarkCopyLines, .bookmarkCutLines, .bookmarkDeleteLines:
                guard activeEditor.hasBookmarks else { return false }
            default: break
            }
            item.state = command.isToggle && isChecked(command, in: activeEditor) ? .on : .off
            return !TTEditor.commandModifiesText(command.nativeIdentifier) || !activeEditor.readOnly
        case #selector(toggleWrap(_:)):
            // Wrapping belongs to the view, as the status bar's Wrap field shows it.
            item.state = activeEditor.wrap ? .on : .off
            return true
        default:
            if let doc = document as? TextDocument, let action = item.action, doc.responds(to: action) {
                return doc.validateMenuItem(item)
            }
            return true
        }
    }
    @objc private func enableLargeFileEditing(_ sender: Any?) {
        guard focusPresentationChrome() else { return }
        (document as? TextDocument)?.enableLargeFileEditing()
    }
    @objc func toggleWrap(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        activeEditor.wrap.toggle()
    }
    @objc func comment(_ sender: NSMenuItem) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        guard let raw = sender.representedObject as? String, let command = CommentCommand(rawValue: raw),
            let app = EditorServices.current, let document = document as? TextDocument
        else { return }
        guard let profile = app.languages?.profile(identifier: document.languageIdentifier) else {
            TTAlert.explain(
                "Comments are not available for this language",
                detail: "Choose a language with comment syntax in the Language menu, then try again.")
            return
        }
        do {
            try activeEditor.requireWritable()
            app.macros?.invalidateRecording(reason: "Language-specific comments are not yet recorded.")
            try command.apply(to: activeEditor, profile: profile)
        } catch { TTAlert.present(error) }
    }
    @objc func columnInsert(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
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
        text.setAccessibilityLabel("Text to insert into each selection")
        number.setAccessibilityLabel("Insert sequential numbers into each selection")
        start.setAccessibilityLabel("Starting column number")
        step.setAccessibilityLabel("Column number increment")
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
        EditorServices.current?.macros?.invalidateRecording(reason: "Column insertion is not yet recorded.")
        if !Self.applyColumn(values, to: editor, revision: revision, selections: selections) {
            let error = TTAlert()
            error.messageText = "Selections changed or are not writable"
            error.informativeText = "No column insertion was applied."
            error.runModal()
        }
    }
    static func applyColumn(_ values: [String], to editor: TTEditor, revision: UInt, selections: [TTSelectionRange])
        -> Bool
    {
        guard EditorLifetime.isOpen(editor), editor.selectionRanges == selections else { return false }
        return editor.replaceSelections(values, expectedRevision: revision)
    }
    @objc func convertEOL(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String, let mode = LineEnding(rawValue: identifier) else {
            return
        }
        do { try convertLineEndings(to: mode.nativeMode) } catch { TTAlert.explain(error) }
    }
    /// Refused with the read-only reason before a macro recording is touched.
    func convertLineEndings(to mode: TTLineEndingMode) throws {
        let editor = activeEditor
        try editor.requireWritable()
        EditorServices.current?.macros?.invalidateRecording(
            reason: "Line-ending conversion is not yet recorded.")
        guard editor.convertLineEndings(mode) else {
            throw DocumentActionError.lineEndingsRejected
        }
    }
}

private struct GoToLineFailure: LocalizedError {
    let last: Int
    var errorDescription: String? {
        "Enter a whole line number from 1 to \(Strings.number(last)). The document has not been changed."
    }
}
