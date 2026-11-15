// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class WorkspaceController: NSObject {
    func capture(name: String) throws -> WorkspaceSession {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
        let snapshots = documents.map { document -> SessionDocument in
            let editor = (document.windowControllers.first as? EditorWindowController)?.activeEditor ?? document.editor
            return SessionDocument(id:document.recoveryID,originalURL:document.fileURL,text:document.editor.text,
                format:document.format,isDirty:document.isDocumentEdited,
                selection:SessionSelection(anchorByte:editor.selectionAnchor,caretByte:editor.selectionCaret),
                bookmarks:editor.bookmarkLines.map(\.intValue),language:document.languageIdentifier,
                originalSHA256:document.originalDiskFingerprint)
        }
        let active = (NSApp.mainWindow?.windowController?.document as? TextDocument)?.recoveryID
        let session=WorkspaceSession(id:UUID(),name:name,documents:snapshots,activeDocumentID:active)
        try session.validate();return session
    }
    @objc func saveSession(_ sender:Any?) {
        let panel=NSSavePanel();panel.nameFieldStringValue="TextTank-session.texttanksession"
        panel.title="Save Session Snapshot"
        panel.message="Save open documents, including unsaved text, encoding, selection and bookmarks. This file contains the document contents."
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { try WorkspaceStore.save(capture(name:url.deletingPathExtension().lastPathComponent),to:url) }
        catch { NSAlert(error:error).runModal() }
    }
    @objc func openSession(_ sender:Any?) {
        let panel=NSOpenPanel();panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
        panel.title="Open Session Snapshot"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do {
            let session=try WorkspaceStore.load(from:url)
            let inspections=session.inspectReferencedFiles()
            let alert=TTAlert();alert.messageText="Restore \(session.documents.count) Documents from \(session.name)?"
            alert.informativeText="Snapshots open as new unsaved documents. Existing tabs and original files are kept.\n\n" + zip(session.documents,inspections).map { entry in
                "\(entry.0.originalURL?.lastPathComponent ?? "Untitled"): \(entry.1.status.description)"
            }.joined(separator:"\n")
            alert.addButton(withTitle:"Restore Snapshots");alert.addButton(withTitle:"Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = try restore(session)
        } catch { NSAlert(error:error).runModal() }
    }
    /// All snapshots are validated before opening any document. A session cannot execute code
    /// or overwrite originals, even if file fingerprints no longer match.
    @discardableResult func restore(_ session:WorkspaceSession) throws -> [TextDocument] {
        try session.validate()
        var restored=[TextDocument]();var active:TextDocument?
        for snapshot in session.documents {
            let document=TextDocument()
            NSDocumentController.shared.addDocument(document);document.makeWindowControllers()
            document.loadUnsavedSnapshot(text:snapshot.text,format:snapshot.format)
            let requestedLanguage=snapshot.language ?? "null"
            if let app=NSApp.delegate as? AppDelegate,app.languages.apply(identifier:requestedLanguage,to:document.editor) {
                document.languageIdentifier=requestedLanguage
            } else {
                document.languageIdentifier="null";document.editor.setLanguage("null")
            }
            _ = document.editor.setBookmarks(snapshot.bookmarks.map { NSNumber(value:$0) })
            _ = document.editor.setSelectionAnchor(snapshot.selection.anchorByte,caret:snapshot.selection.caretByte)
            document.showWindows()
            (document.windowControllers.first as? EditorWindowController)?.status.stringValue="Session snapshot · \(snapshot.originalURL?.lastPathComponent ?? "Untitled") · Save As to keep separately"
            document.flushRecovery()
            if requestedLanguage != document.languageIdentifier {
                (document.windowControllers.first as? EditorWindowController)?.status.stringValue += " · Language profile unavailable; using Plain Text"
            }
            restored.append(document)
            if snapshot.id == session.activeDocumentID { active=document }
        }
        active?.showWindows();return restored
    }
}
