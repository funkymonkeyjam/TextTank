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
        let session = WorkspaceSession(id: UUID(), name: name, documents: snapshots, activeDocumentID: active)
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
            NSAlert(error: error).runModal()
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
    static func restorePromptText(_ session: WorkspaceSession, _ inspections: [SessionFileInspection]) -> String {
        "Saved \(SnapshotLabel.savedAt(session.savedAt)). Snapshots open as new unsaved documents. Existing tabs and original files are kept.\n\n"
            + zip(session.documents, inspections).map { entry in
                "\(entry.0.originalURL?.lastPathComponent ?? "Untitled"): \(entry.1.status.description)"
                    + (entry.0.isDirty ? " · had unsaved edits" : " · no unsaved edits")
            }.joined(separator: "\n")
    }
    /// The review-and-restore prompt for one snapshot file. Also reached when a snapshot is
    /// opened from Finder or File > Open, so it is never shown as an editable JSON document.
    func openSession(at url: URL) {
        do {
            let session = try WorkspaceStore.load(from: url)
            let inspections = session.inspectReferencedFiles()
            let alert = TTAlert()
            alert.messageText = "Restore \(session.documents.count) Documents from \(session.name)?"
            alert.informativeText = Self.restorePromptText(session, inspections)
            alert.addButton(withTitle: "Restore Snapshots")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = try restore(session)
        } catch { NSAlert(error: error).runModal() }
    }
    /// All snapshots are validated before opening any document. A session cannot execute code
    /// or overwrite originals, even if file fingerprints no longer match.
    @discardableResult func restore(_ session: WorkspaceSession) throws -> [TextDocument] {
        try session.validate()
        var restored = [TextDocument]()
        var active: TextDocument?
        for snapshot in session.documents {
            let document = TextDocument()
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.loadUnsavedSnapshot(text: snapshot.text, format: snapshot.format)
            let requestedLanguage = snapshot.language ?? "null"
            if let app = NSApp.delegate as? AppDelegate,
                app.languages.apply(identifier: requestedLanguage, to: document.editor)
            {
                document.languageIdentifier = requestedLanguage
            } else {
                document.languageIdentifier = "null"
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
