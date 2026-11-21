@testable import TextTankCore
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch
import Darwin

@MainActor enum Audit29FactoryChecks {
    static func run(root: URL) throws {
        let previous = EditorServices.current
        defer { EditorServices.current = previous }
        let composition = AppDelegate()
        composition.installEditorServices()
        composition.newDocument(nil)
        let created = try requireValue(
            NSDocumentController.shared.documents.last as? TextDocument,
            "F301 fixture: New creates a document")
        check(
            created.fileType == TextDocument.plainTextType,
            "F301 New establishes one plain-text document type before saving")
        created.close()
        let snapshot = RecoverySnapshot(
            id: UUID(), text: "recovered", format: FileFormat(),
            originalURL: nil, revision: 11)
        let recovered = try TextDocument.openRecovered(snapshot)
        check(
            recovered.fileType == TextDocument.plainTextType && recovered.recoveryID == snapshot.id
                && recovered.recoveryBase == 12 && recovered.fileURL == nil && recovered.isDocumentEdited,
            "F301 recovery establishes type and original recovery identity before the first unsaved edit")
        recovered.close()
        let entry = SessionDocument(
            id: UUID(), originalURL: nil, text: "session", format: FileFormat(),
            isDirty: false, selection: SessionSelection(anchorByte: 0, caretByte: 0))
        let restored = try WorkspaceController().restore(
            WorkspaceSession(id: UUID(), name: "factory", documents: [entry]))
        check(
            restored.count == 1 && restored[0].fileType == TextDocument.plainTextType
                && restored[0].fileURL == nil && restored[0].isDocumentEdited,
            "F301 session restore establishes a type but retains its new unsaved document identity")
        restored.forEach { $0.close() }
        let url = root.appendingPathComponent("audit29-browser-save.txt")
        let original = Data("browser text".utf8)
        try original.write(to: url)
        let browser = WorkspaceBrowserController(
            storeURL: root.appendingPathComponent("audit29-browser.json"),
            recordsSystemRecent: false)
        let document = try browser.open(url)
        defer { document.close() }
        check(
            document.fileType == TextDocument.plainTextType && document.fileModificationDate != nil,
            "F92 browser open keeps the descriptor modification date and a nonnil document type")
        check(
            !document.hasSettledDiskSignature,
            "F92 a fresh descriptor modification date does not make unsettled metadata trusted")
        document.editor.text = "saved in place"
        var completed = false
        var failure: Error?
        document.save(to: url, ofType: document.fileType ?? TextDocument.plainTextType, for: .saveOperation) {
            failure = $0
            completed = true
        }
        spinUntil("F92 browser in-place save completion") { completed }
        check(
            completed && failure == nil && (try? Data(contentsOf: url)) == Data("saved in place".utf8)
                && !document.isDocumentEdited && !document.editor.modified,
            "F92 a browser-opened document saves in place with exact bytes and clean state")
        document.editor.text = "dirty existing document"
        let reopened = try browser.open(url)
        check(
            reopened === document && reopened.editor.text == "dirty existing document",
            "F92 reopening an existing browser document never reloads its dirty bytes")
        let capturedURL = root.appendingPathComponent("audit29-captured.txt")
        try Data("captured bytes".utf8).write(to: capturedURL)
        let capture = try WorkspaceStore.captureRegularFile(capturedURL)
        try Data("later external bytes".utf8).write(to: capturedURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: capturedURL.path)
        let captured = try DocumentFactory.openCaptured(capture, from: capturedURL, display: false)
        defer { captured.close() }
        check(
            captured.editor.text == "captured bytes" && captured.fileModificationDate == capture.modificationDate
                && captured.originalDiskFingerprint == capture.sample.digest,
            "F301 the factory uses only captured bytes and descriptor metadata after the pathname changes")
        check(
            try captured.diskState() == .changed,
            "F301 a later pathname replacement is not acknowledged as the captured document's baseline")
        let fifo = root.appendingPathComponent("audit29-pipe")
        check(mkfifo(fifo.path, 0o600) == 0, "F92 fixture: FIFO created")
        rejects("F92 the browser still rejects a FIFO without blocking") { _ = try browser.open(fifo) }
        let link = root.appendingPathComponent("audit29-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        rejects("F92 the browser still rejects a symbolic link") { _ = try browser.open(link) }
    }
}
