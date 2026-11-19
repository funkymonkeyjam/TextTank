import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor final class WorkspaceController: NSObject, NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool { !CompareCommandScope.blocksWorkspace }
    /// The document a saved session marks as active. The application supplies its one
    /// definition of the current document; a controller made on its own asks the main window.
    var activeDocument: () -> TextDocument? = { EditorServices.current?.activePresentation?.document as? TextDocument }
    func capture(name: String) throws -> WorkspaceSession {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
        let snapshots = documents.map { document -> SessionDocument in
            let editor = document.activeEditor
            return SessionDocument(
                id: document.recoveryID, originalURL: document.fileURL, text: document.editor.text,
                format: document.format, isDirty: document.isDocumentEdited,
                selection: SessionSelection(anchorByte: editor.selectionAnchor, caretByte: editor.selectionCaret),
                bookmarks: editor.bookmarkLines.map(\.intValue), language: document.languageIdentifier,
                originalSHA256: document.originalDiskFingerprint)
        }
        // A session names an active document only when that document is in the session:
        // validate() rejects an unknown identifier, and that must never fail a save.
        let active = activeDocument().flatMap { current in
            documents.contains { $0 === current } ? current.recoveryID : nil
        }
        let session = WorkspaceSession(
            id: UUID(), name: String(name.prefix(200)), documents: snapshots, activeDocumentID: active,
            layoutState: WorkspaceWindowController.current.captureSessionLayout())
        try session.validate()
        return session
    }
    @objc func saveSession(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TextTank-session." + WorkspaceStore.sessionFileExtension
        panel.title = "Save Session Snapshot"
        panel.message =
            "Save open documents, including unsaved text, encoding, bookmarks, tabs and editor layout. This file contains the document contents."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try WorkspaceStore.save(capture(name: url.deletingPathExtension().lastPathComponent), to: url) } catch {
            TTAlert.present(error)
        }
    }
    @objc func openSession(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Session Snapshot"
        // Not filtered by type: earlier snapshots were saved under arbitrary names.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openSession(at: url)
    }
    /// What the restore prompt says: when the snapshot was saved and, for each document, the
    /// state of its original file and whether it had unsaved edits when captured.
    /// The originals' states are there only once they have been checked (`inspections`).
    nonisolated static func restorePromptText(_ session: WorkspaceSession, _ inspections: [SessionFileInspection]?)
        -> String
    {
        session.restorePrompt(
            inspections: inspections, savedLabel: SnapshotLabel.savedAt(session.savedAt), showsDirtyState: true
        ).detail
    }
    enum RestoreLayoutPolicy: Equatable {
        case legacy, saved(WorkspaceLayoutState), merge, fallback(String)
        var explanation: String {
            switch self {
            case .legacy: return "No saved layout is present. Snapshots will open in the focused group."
            case .saved: return "The saved editor layout, groups and tabs will be applied."
            case .merge:
                return
                    "The saved layout will not be applied. Existing tabs and layout are kept; snapshots will be added to the focused group."
            case .fallback(let reason):
                return "The saved layout will not be applied: " + reason
                    + " Snapshots will open once each in Single Group."
            }
        }
    }
    func restoreLayoutPolicy(_ session: WorkspaceSession, availableContent: TabGroupExtent? = nil)
        -> RestoreLayoutPolicy
    {
        let host = WorkspaceWindowController.current
        if case .absent = session.layoutStatus { return .legacy }
        if !host.model.groups.flatMap(\.tabs).isEmpty { return .merge }
        switch session.layoutStatus {
        case .absent: return .legacy
        case .invalid: return .fallback("the layout data is invalid.")
        case .valid(let state):
            return host.canFitSessionLayout(state.layout, availableContent: availableContent)
                ? .saved(state)
                : .fallback("this screen cannot fit it.")
        }
    }
    /// The review-and-restore prompt for one snapshot file. Also reached when a snapshot is
    /// opened from Finder or File > Open, so it is never shown as an editable JSON document.
    func openSession(at url: URL) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        do {
            let session = try WorkspaceStore.load(from: url)
            // The first prompt is built from the session alone. The files it names are read
            // only if the person asks, off the main thread, and the same prompt then returns
            // with one status line per document.
            var inspections: [SessionFileInspection]?
            while true {
                let policy = restoreLayoutPolicy(session)
                let prompt = session.restorePrompt(inspections: inspections)
                let alert = TTAlert()
                alert.messageText = prompt.message
                alert.informativeText = Self.restorePromptText(session, inspections) + "\n\n" + policy.explanation
                alert.addButton(withTitle: "Restore Snapshots")
                if inspections == nil { alert.addButton(withTitle: "Check Originals…") }
                alert.addButton(withTitle: "Cancel", role: .cancel)
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Nested modal work can change the workspace. Confirm the actual policy.
                    guard policy == restoreLayoutPolicy(session) else { continue }
                    _ = try restore(session)
                    return
                }
                guard inspections == nil, response == .alertSecondButtonReturn else { return }
                guard let checked = Self.checkOriginals(of: session) else { continue }
                inspections = checked
            }
        } catch { TTAlert.present(error) }
    }
    /// Inspects the session's originals on a utility queue behind a Cancel prompt. Returns nil
    /// when cancelled; the work stops at the next file or 64 KiB step and its result is dropped.
    static func checkOriginals(of session: WorkspaceSession) -> [SessionFileInspection]? {
        let cancellation = SessionCheckCancellation()
        let outcome = SessionInspectionOutcome()
        let progress = TTAlert()
        progress.messageText = "Checking Original Files…"
        progress.informativeText =
            "Each original is compared with the fingerprint saved in the session. Nothing is changed."
        progress.addButton(withTitle: "Cancel", role: .cancel)
        let deliver: @MainActor @Sendable ([SessionFileInspection]) -> Void = { inspections in
            guard !cancellation.isCancelled else { return }
            outcome.result = inspections
            NSApp.abortModal()
        }
        DispatchQueue.global(qos: .utility).async {
            let inspections = session.inspectReferencedFiles(isCancelled: { cancellation.isCancelled })
            // Delivered inside the modal session below; main-queue work runs in modal mode.
            // abortModal, not stopModal: this is not code responding to an event.
            DispatchQueue.main.async { deliver(inspections) }
        }
        _ = progress.runModal()
        if outcome.result == nil { cancellation.cancel() }
        return outcome.result
    }
    /// All snapshots are validated before opening any document. A session cannot execute code
    /// or overwrite originals, even if file fingerprints no longer match.
    @discardableResult func restore(_ session: WorkspaceSession, availableContent: TabGroupExtent? = nil) throws
        -> [TextDocument]
    {
        try session.validate()
        let policy = restoreLayoutPolicy(session, availableContent: availableContent)
        let host = WorkspaceWindowController.current
        let destination = host.model.focusedGroup
        var mapping: [DocumentID: TextDocument] = [:]
        var restored = [TextDocument]()
        var active: TextDocument?
        for snapshot in session.documents {
            host.focusGroup(destination)
            let document = DocumentFactory.makeUntitled(
                display: false, focus: false,
                populate: { document in
                    document.loadUnsavedSnapshot(text: snapshot.text, format: snapshot.format)
                })
            // Sessions written before the single plain-text identifier say "null" or nothing.
            let requestedLanguage = LanguageProfile.canonicalID(snapshot.language)
            if !document.applyLanguage(requestedLanguage, using: EditorServices.current?.languages) {
                document.usePlainTextLanguage()
            }
            _ = document.editor.setBookmarks(snapshot.bookmarks.map { NSNumber(value: $0) })
            _ = document.editor.setSelectionAnchor(snapshot.selection.anchorByte, caret: snapshot.selection.caretByte)
            (document.windowControllers.first as? EditorWindowController)?.setStatusMessage(
                "Session snapshot · \(snapshot.originalURL?.lastPathComponent ?? "Untitled") · Save As to keep separately"
            )
            document.flushRecovery()
            if requestedLanguage != document.languageIdentifier {
                (document.windowControllers.first as? EditorWindowController)?.appendStatusMessage(
                    " · Language profile unavailable; using Plain Text")
            }
            mapping[DocumentID(snapshot.id)] = document
            restored.append(document)
            if snapshot.id == session.activeDocumentID { active = document }
        }
        switch policy {
        case .saved(let state):
            guard host.restoreSessionLayout(state, documents: mapping) else {
                // A reentrant addition must never be rearranged by this snapshot.
                host.showTabMessage("The workspace changed. Snapshots were added; the saved layout was not applied.")
                return restored
            }
            host.window?.makeKeyAndOrderFront(nil)
            host.showTabMessage("Restored session snapshots and saved editor layout.")
        case .fallback:
            let state = WorkspaceLayoutState(
                layout: .single, focusedGroup: .first,
                groups: [
                    WorkspaceLayoutState.Group(
                        slot: .first,
                        activeTabIndex: session.documents.firstIndex { $0.id == session.activeDocumentID }
                            ?? (restored.isEmpty ? nil : 0),
                        tabs: session.documents.map { snapshot in
                            WorkspaceLayoutState.Tab(
                                documentID: DocumentID(snapshot.id), isPinned: false,
                                anchorByte: snapshot.selection.anchorByte, caretByte: snapshot.selection.caretByte,
                                firstVisibleLine: 0)
                        })
                ])
            guard host.restoreSessionLayout(state, documents: mapping) else {
                host.showTabMessage("The workspace changed. Snapshots were added; the saved layout was not applied.")
                return restored
            }
            host.window?.makeKeyAndOrderFront(nil)
            host.showTabMessage(policy.explanation)
        case .merge, .legacy:
            active?.showWindows()
            if active == nil { restored.last?.showWindows() }
            host.showTabMessage(
                policy == .merge ? policy.explanation : "Restored session snapshots in the focused group.")
        }
        return restored
    }
}

/// The modal caller and its synchronous main-queue delivery own this result.
@MainActor private final class SessionInspectionOutcome { var result: [SessionFileInspection]? }

/// Set on the main thread, read by the inspection running on a utility queue.
final class SessionCheckCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
