// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class WorkspaceController: NSObject {
    /// The document a saved session marks as active. The application supplies its one
    /// definition of the current document; a controller made on its own asks the main window.
    var activeDocument: () -> TextDocument? = { NSApp.mainWindow?.windowController?.document as? TextDocument }
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
            id: UUID(), name: String(name.prefix(200)), documents: snapshots, activeDocumentID: active)
        try session.validate()
        return session
    }
    @objc func saveSession(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "TextTank-session." + WorkspaceStore.sessionFileExtension
        panel.title = "Save Session Snapshot"
        panel.message =
            "Save open documents, including unsaved text, encoding, selection and bookmarks. This file contains the document contents."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try WorkspaceStore.save(capture(name: url.deletingPathExtension().lastPathComponent), to: url) } catch {
            TTAlert.present(error)
        }
    }
    @objc func openSession(_ sender: Any?) {
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
    static func restorePromptText(_ session: WorkspaceSession, _ inspections: [SessionFileInspection]?) -> String {
        session.restorePrompt(
            inspections: inspections, savedLabel: SnapshotLabel.savedAt(session.savedAt), showsDirtyState: true
        ).detail
    }
    /// The review-and-restore prompt for one snapshot file. Also reached when a snapshot is
    /// opened from Finder or File > Open, so it is never shown as an editable JSON document.
    func openSession(at url: URL) {
        do {
            let session = try WorkspaceStore.load(from: url)
            // The first prompt is built from the session alone. The files it names are read
            // only if the person asks, off the main thread, and the same prompt then returns
            // with one status line per document.
            var inspections: [SessionFileInspection]?
            while true {
                let prompt = session.restorePrompt(inspections: inspections)
                let alert = TTAlert()
                alert.messageText = prompt.message
                alert.informativeText = Self.restorePromptText(session, inspections)
                alert.addButton(withTitle: "Restore Snapshots")
                if inspections == nil { alert.addButton(withTitle: "Check Originals…") }
                alert.addButton(withTitle: "Cancel", role: .cancel)
                let response = alert.runModal()
                if response == .alertFirstButtonReturn { break }
                guard inspections == nil, response == .alertSecondButtonReturn else { return }
                guard let checked = Self.checkOriginals(of: session) else { continue }
                inspections = checked
            }
            _ = try restore(session)
        } catch { TTAlert.present(error) }
    }
    /// Inspects the session's originals on a utility queue behind a Cancel prompt. Returns nil
    /// when cancelled; the work stops at the next file or 64 KiB step and its result is dropped.
    static func checkOriginals(of session: WorkspaceSession) -> [SessionFileInspection]? {
        let cancellation = SessionCheckCancellation()
        var result: [SessionFileInspection]?
        let progress = TTAlert()
        progress.messageText = "Checking Original Files…"
        progress.informativeText =
            "Each original is compared with the fingerprint saved in the session. Nothing is changed."
        progress.addButton(withTitle: "Cancel", role: .cancel)
        DispatchQueue.global(qos: .utility).async {
            let inspections = session.inspectReferencedFiles(isCancelled: { cancellation.isCancelled })
            // Delivered inside the modal session below; main-queue work runs in modal mode.
            // abortModal, not stopModal: this is not code responding to an event.
            DispatchQueue.main.async {
                guard !cancellation.isCancelled else { return }
                result = inspections
                NSApp.abortModal()
            }
        }
        _ = progress.runModal()
        if result == nil { cancellation.cancel() }
        return result
    }
    /// All snapshots are validated before opening any document. A session cannot execute code
    /// or overwrite originals, even if file fingerprints no longer match.
    @discardableResult func restore(_ session: WorkspaceSession) throws -> [TextDocument] {
        try session.validate()
        var restored = [TextDocument]()
        var active: TextDocument?
        for snapshot in session.documents {
            let document = DocumentFactory.makeUntitled(
                display: false, focus: false,
                populate: { document in
                    document.loadUnsavedSnapshot(text: snapshot.text, format: snapshot.format)
                })
            // Sessions written before the single plain-text identifier say "null" or nothing.
            let requestedLanguage = LanguageProfile.canonicalID(snapshot.language)
            if let app = EditorServices.current,
                app.languages?.apply(identifier: requestedLanguage, to: document.editor) == true
            {
                document.languageIdentifier = requestedLanguage
            } else {
                document.languageIdentifier = LanguageProfile.plainTextID
                document.editor.setLanguage("null")
            }
            _ = document.editor.setBookmarks(snapshot.bookmarks.map { NSNumber(value: $0) })
            _ = document.editor.setSelectionAnchor(snapshot.selection.anchorByte, caret: snapshot.selection.caretByte)
            document.showWindows()
            (document.windowControllers.first as? EditorWindowController)?.status.stringValue =
                "Session snapshot · \(snapshot.originalURL?.lastPathComponent ?? "Untitled") · Save As to keep separately"
            document.flushRecovery()
            if requestedLanguage != document.languageIdentifier {
                (document.windowControllers.first as? EditorWindowController)?.status.stringValue +=
                    " · Language profile unavailable; using Plain Text"
            }
            restored.append(document)
            if snapshot.id == session.activeDocumentID { active = document }
        }
        active?.showWindows()
        return restored
    }
}

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
