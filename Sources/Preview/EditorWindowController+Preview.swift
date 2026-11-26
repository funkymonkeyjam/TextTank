// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
import TextTankCore

/// Source, Preview and Both for one tab.
///
/// A mode change only rearranges views. It never closes the clone split, shares or reloads the
/// document, or touches Undo: the editor views stay as they are, hidden in Preview, so the
/// selection, scroll position, Undo history and file identity are the same in every mode.
extension EditorWindowController {
    /// The preview that applies to this tab's document now, or nil when it has none.
    var previewKind: PreviewKind? {
        guard let document = document as? TextDocument else { return nil }
        let fileExtension = document.fileURL?.pathExtension ?? ""
        return PreviewKind.kind(
            languageID: document.languageIdentifier, fileExtension: fileExtension.isEmpty ? nil : fileExtension)
    }

    /// True while the keyboard focus is inside the preview pane.
    var previewHasFocus: Bool {
        guard let pane = previewCoordinator?.pane, let responder = hostWindow?.firstResponder as? NSView
        else { return false }
        return responder.isDescendant(of: pane)
    }

    /// The view that should take the keyboard when this tab is activated: the preview when the
    /// source is hidden, otherwise the editor pane used last.
    var keyboardFocusView: NSView {
        if viewMode == .preview, let pane = previewCoordinator?.pane { return pane.focusView }
        return activeEditor
    }

    /// The view that takes the keyboard when a session layout has just been restored: the pane
    /// the session recorded as the one in use, which `restoreSessionTab` left in `lastEditor`.
    /// `keyboardFocusView` would be wrong here: it prefers the pane that holds the keyboard at
    /// this moment, and after the documents are opened that is the tab's first pane, so a saved
    /// clone pane would never get the keyboard back.
    var restoredKeyboardFocusView: NSView {
        if viewMode == .preview, let pane = previewCoordinator?.pane { return pane.focusView }
        return lastEditor ?? primaryEditor
    }

    // MARK: Commands

    /// View > Source, Preview, Both. The item's represented object is the mode's raw value.
    @objc func setDocumentViewMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DocumentViewMode(rawValue: raw)
        else { return }
        chooseViewMode(mode)
    }

    /// The one path for a mode the person chose for this tab: the View menu, the tab's context
    /// menu, the mark on the tab and Toggle Preview all come here (DS-20). Choosing the mode that
    /// is showing moves the keyboard instead. A rendered mode is remembered for Toggle Preview.
    /// `movingFocus` is false for a tab that is not the active one, which must not take the
    /// keyboard. Returns false, with nothing changed, when the mode cannot be shown.
    @discardableResult func chooseViewMode(_ mode: DocumentViewMode, movingFocus: Bool = true) -> Bool {
        guard !CompareCommandScope.blocksWorkspace else { return false }
        if mode == viewMode {
            if movingFocus { moveFocusWithinCurrentMode() }
            return true
        }
        guard setViewMode(mode, movingFocus: movingFocus) else { return false }
        if mode != .source { EditorServices.current?.settings?.noteRenderedMode(mode) }
        return true
    }

    /// View > Toggle Preview. From Source it shows the rendered mode the person used last
    /// (Both until they have chosen one); from Preview or Both it returns to Source.
    @objc func toggleDocumentPreview(_ sender: Any?) {
        guard previewKind != nil else { return }
        chooseViewMode(viewMode == .source ? Self.toggledPreviewMode : .source)
    }

    /// Preview or Both, whichever the person chose last; Both without a settings store.
    static var toggledPreviewMode: DocumentViewMode {
        EditorServices.current?.settings?.toggledPreviewMode ?? .both
    }

    /// Checkmark on the mode that is showing (DS-22); all three are disabled for a document that
    /// has no preview (DS-21).
    func validateDocumentViewMode(_ item: NSMenuItem) -> Bool {
        let mode = (item.representedObject as? String).flatMap(DocumentViewMode.init(rawValue:))
        item.state = mode == viewMode ? .on : .off
        return previewKind != nil
    }

    /// Toggle Preview is disabled for a document that has no preview (DS-21). It carries no
    /// checkmark of its own: the three items above it show which mode is on (DS-22).
    func validateToggleDocumentPreview(_ item: NSMenuItem) -> Bool { previewKind != nil }

    /// View > Preview > Sync Scrolling in Both: the stored `syncPreviewScrolling` setting, the same
    /// value as the Settings row, so changing either shows in the other at once (DS-20).
    @objc func toggleSyncPreviewScrolling(_ sender: Any?) {
        guard previewKind != nil, !CompareCommandScope.blocksWorkspace else { return }
        EditorServices.current?.settings?.toggle(.syncPreviewScrolling, sender: sender)
    }

    /// A checkmark for the stored value (DS-22); disabled with the rest of the Preview submenu
    /// for a document that has no preview (DS-21).
    func validateSyncPreviewScrolling(_ item: NSMenuItem) -> Bool {
        item.state = (EditorServices.current?.settings?.value.syncsPreviewScrolling ?? true) ? .on : .off
        return previewKind != nil
    }

    /// Shows what Settings says a document of this format opens in. Called once, when a document
    /// read from a file gets its first tab; never for a tab restored from a session, an untitled
    /// document, or a tab that is already open (see "Opening in Preview or Both" in
    /// docs/preview-model.md). The keyboard is not moved here: the tab is activated afterwards
    /// and takes it then.
    func applyOpenDefault() {
        guard viewMode == .source, let kind = previewKind,
            let mode = EditorServices.current?.settings?.value.previewOpenMode(for: kind.format), mode != .source
        else { return }
        setViewMode(mode, movingFocus: false)
    }

    /// Choosing the mode that is already showing moves the keyboard instead: in Both it goes
    /// from the source to the preview or back, which is how the preview is reached without a
    /// pointer (DS-73). In Source and Preview it returns to the one view there is.
    private func moveFocusWithinCurrentMode() {
        guard host.active === self else { return }
        let target: NSView
        if viewMode == .both, let pane = previewCoordinator?.pane {
            target = previewHasFocus ? activeEditor : pane.focusView
        } else {
            target = keyboardFocusView
        }
        hostWindow?.makeFirstResponder(target)
    }

    // MARK: Changing mode

    /// Shows `mode`. Returns false, with nothing changed, when the tab is closed or the document
    /// has no preview. `movingFocus` is false for changes the person did not ask for directly.
    @discardableResult func setViewMode(_ mode: DocumentViewMode, movingFocus: Bool = true) -> Bool {
        guard !statusClosed, !isRetired, (document as? TextDocument)?.isOpen == true else { return false }
        guard mode == .source || previewKind != nil else { return false }
        guard mode != viewMode else { return true }

        let focusWasInPreview = previewHasFocus
        let focusWasInTab = (hostWindow?.firstResponder as? NSView)?.isDescendant(of: presentationRoot) == true
        // The find bar and Go to Line act on the source, which Preview hides. Closing one returns the
        // keyboard to the editor only when this tab holds the keyboard and the change may move it: a tab
        // changed from its own menu or mark while another is in use must not take the keyboard.
        if mode == .preview, findBarVisible || goToLineBarVisible {
            closeFindBar(returningKeyboard: movingFocus && focusWasInTab)
        }

        viewMode = mode
        if mode == .source {
            viewContainer.show(.source, preview: nil)
            tearDownPreview()
        } else {
            let coordinator = previewCoordinator ?? makePreviewCoordinator()
            viewContainer.show(mode, preview: coordinator.pane)
            connectKeyViews(to: coordinator.pane)
            coordinator.tabStateChanged()
        }
        // A restored clone split waits for the source to have its width.
        applyRestoredSplitIfMounted()

        if movingFocus, focusWasInTab, host.active === self {
            let target: NSView
            switch mode {
            case .source: target = activeEditor
            case .preview: target = keyboardFocusView
            case .both: target = focusWasInPreview ? keyboardFocusViewInPreview ?? activeEditor : activeEditor
            }
            hostWindow?.makeFirstResponder(target)
        }
        // The tab carries a mark for Preview and Both, whichever route changed the mode.
        host.tabViewModeChanged()
        return true
    }

    private var keyboardFocusViewInPreview: NSView? { previewCoordinator?.pane.focusView }

    /// Find, Find and Replace, Go to Line and Go to Error act on the source. While the tab shows
    /// Preview alone they first put the source beside it.
    func revealSource() {
        if viewMode == .preview { setViewMode(.both) }
    }

    /// The document's language or location changed. A document that no longer has a preview
    /// returns to Source and says so quietly in the status line; otherwise the preview follows.
    func previewKindMayHaveChanged() {
        // A tab in Source offers the preview on its tab only while the document has one.
        defer { host.tabViewModeChanged() }
        guard viewMode != .source else { return }
        guard previewKind != nil else {
            setViewMode(.source)
            showTransientStatus(PreviewMessages.noLongerPreviewable)
            return
        }
        previewCoordinator?.tabStateChanged()
    }

    /// The tab was shown or hidden. A hidden tab's preview does no work.
    func previewVisibilityChanged() {
        previewCoordinator?.tabStateChanged()
    }

    /// Stops the preview's work and releases its pane and web view.
    func tearDownPreview() {
        guard let coordinator = previewCoordinator else { return }
        previewCoordinator = nil
        coordinator.invalidate()
        coordinator.pane.removeFromSuperview()
    }

    private func makePreviewCoordinator() -> PreviewCoordinator {
        let pane = PreviewPane(frame: viewContainer.bounds)
        pane.onUnmappedSelection = { [weak self] in
            guard let self, self.isPresented, self.previewCoordinator?.isCurrent == true else { return }
            self.showTransientStatus(
                Strings.text("preview.selection.unmapped", "TextTank couldn’t locate this selection in Source."))
        }
        pane.onSelection = { [weak self] ranges in
            guard let self, self.isPresented, self.previewCoordinator?.isCurrent == true,
                !self.statusClosed, !self.isRetired, !ranges.isEmpty
            else { return }
            let editor = self.activeEditor
            // Native byte boundaries are validated together before any selection is changed.
            let selections = ranges.map { TTSelectionRange(anchor: $0.lowerBound, caret: $0.upperBound) }
            let select = { editor.setSelectionRanges(selections) }
            let moved =
                EditorServices.current?.macros?.unrecordedJump(
                    in: editor,
                    reason: Strings.text(
                        "preview.selection.macro", "Preview selections are not recorded in macros yet."), select)
                ?? select()
            guard moved else {
                self.previewCoordinator?.pane.onUnmappedSelection?()
                return
            }
            if self.viewMode == .preview { _ = self.setViewMode(.both, movingFocus: false) }
            self.previewCoordinator?.scrollSync.showSelection(in: editor)
            self.refreshStatusDetails()
        }
        pane.onGoToError = { [weak self] error in self?.goToPreviewError(error) }
        pane.onDocumentCommand = { [weak self] command in try? self?.perform(command: command) }
        let tab = PreviewCoordinator.Tab(
            editor: { [weak self] in self?.primaryEditor },
            kind: { [weak self] in self?.previewKind },
            isLive: { [weak self] in
                guard let self, let document = self.document as? TextDocument else { return false }
                return !self.statusClosed && !self.isRetired && self.viewMode != .source && document.isOpen
                    && self.isPresented
            },
            documentName: { [weak self] in (self?.document as? TextDocument)?.displayName ?? "" },
            documentURL: { [weak self] in
                guard let url = (self?.document as? TextDocument)?.fileURL, url.isFileURL else { return nil }
                return url
            },
            syncEditors: { [weak self] in
                guard let self, self.viewMode == .both else { return [] }
                let inUse = self.activeEditor
                return [inUse] + self.views.filter { $0 !== inUse }
            },
            wantsScrollSync: { EditorServices.current?.settings?.value.syncsPreviewScrolling ?? true })
        let coordinator = PreviewCoordinator(pane: pane, tab: tab)
        previewCoordinator = coordinator
        return coordinator
    }

    /// Tab from the table or the tree goes on to the source, and from the source's neighbours
    /// back to the preview. Tab inside the source still types a tab.
    private func connectKeyViews(to pane: PreviewPane) {
        pane.keyViewAfterPreview = primaryEditor
    }

    /// Puts the caret where the JSON stopped being valid and shows that place in the source.
    private func goToPreviewError(_ error: JSONSyntaxError) {
        guard !statusClosed else { return }
        revealSource()
        let editor = activeEditor
        let offset = min(max(0, error.byteOffset), editor.byteLength)
        let jump = { editor.setSelectionAnchor(offset, caret: offset) }
        let moved =
            EditorServices.current?.macros?.unrecordedJump(
                in: editor,
                reason: Strings.text("preview.json.goToError.macro", "Go to Error is not recorded in macros yet."),
                jump) ?? jump()
        if !moved { _ = Self.goToLine(error.line, in: editor, macros: EditorServices.current?.macros) }
        editor.scrollCaretIntoView()
        if host.active === self { hostWindow?.makeFirstResponder(editor) }
        refreshStatusDetails()
    }

    // MARK: Session

    /// Adds this tab's mode to its session record. Source is recorded by leaving the fields out.
    func recordingViewMode(in tab: WorkspaceLayoutState.Tab) -> WorkspaceLayoutState.Tab {
        var tab = tab
        tab.viewMode = viewMode == .source ? nil : viewMode
        tab.previewSourceFraction = viewMode == .source ? nil : viewContainer.sourceFraction
        return tab
    }

    /// Applies a restored mode, but only to a document that still has a preview.
    func restoreViewMode(from tab: WorkspaceLayoutState.Tab) {
        if let fraction = tab.previewSourceFraction { viewContainer.sourceFraction = fraction }
        let wanted = tab.viewMode ?? .source
        setViewMode(wanted != .source && previewKind == nil ? .source : wanted, movingFocus: false)
    }
}

/// While a saved session is being reopened, a document's tab keeps the mode the session
/// recorded for it; the Settings choice for its format is not applied first.
@MainActor enum PreviewOpenDefault {
    private(set) static var isSuspended = false
    static func suspended<Result>(_ body: () throws -> Result) rethrows -> Result {
        let before = isSuspended
        isSuspended = true
        defer { isSuspended = before }
        return try body()
    }
}
