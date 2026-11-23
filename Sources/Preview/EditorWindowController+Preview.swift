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

    // MARK: Commands

    /// View > Source, Preview, Both. The item's represented object is the mode's raw value.
    @objc func setDocumentViewMode(_ sender: NSMenuItem) {
        guard !CompareCommandScope.blocksWorkspace, let raw = sender.representedObject as? String,
            let mode = DocumentViewMode(rawValue: raw)
        else { return }
        if mode == viewMode {
            moveFocusWithinCurrentMode()
        } else {
            setViewMode(mode)
        }
    }

    /// Checkmark on the mode that is showing (DS-22); all three are disabled for a document that
    /// has no preview (DS-21).
    func validateDocumentViewMode(_ item: NSMenuItem) -> Bool {
        let mode = (item.representedObject as? String).flatMap(DocumentViewMode.init(rawValue:))
        item.state = mode == viewMode ? .on : .off
        return previewKind != nil
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
        // The find bar acts on the source, which Preview hides.
        if mode == .preview, findBarVisible { hideFind(nil) }

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
            })
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
