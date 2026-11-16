import AppKit

/// The Objective-C name is fixed, so `NSDocumentClass` in Info.plist does not depend on the
/// name of the Swift module.
@objc(TextDocument) final class TextDocument: NSDocument {
    /// The type name used where a document has none of its own. Reading ignores the type.
    static let plainTextType = "public.plain-text"
    /// No File Format pop-up in the Save panel. Every content type in Info.plist is a writable
    /// type and nearly all are named "Plain Text"; choosing one would only switch the type name
    /// and, for some, add that type's extension. The text is written the same way for all.
    override var shouldRunSavePanelWithAccessoryView: Bool { false }
    static let recovery = RecoveryStore(directory: AppStorage.url(.recovery))
    var recoveryID = UUID()
    /// Offset for recovery metadata changes; adding the editor revision gives the store revision.
    var recoveryBase: UInt64 = 0
    /// One notice per app session about repeated recovery-write failures.
    static var recoveryFailureNoticeShown = false
    #if TESTING
        static var recoveryFailureNoticeForTesting: ((TextDocument, Error) -> Void)?
    #endif
    private var recoveryFailures = RecoveryFailureTracker()
    /// The failure of the most recent recovery write or cleanup; nil after a success.
    private(set) var lastRecoveryError: Error?
    private var recoveryTimer: Timer?
    private var recoveryDeadlineTimer: Timer?
    private let recoveryWriter = RecoveryWriter()
    /// Invalidates completion callbacks whenever recovery is rescheduled, flushed or closed.
    private var recoveryGeneration = 0
    /// Terminal once close starts: no timer or late completion may enqueue another copy.
    private var recoveryClosed = false
    private static let defaultAutomaticRecoveryDelay: TimeInterval = 0.5
    private static let defaultMaximumRecoveryDelay: TimeInterval = 5
    #if TESTING
        var automaticRecoveryDelay = TextDocument.defaultAutomaticRecoveryDelay
        var maximumRecoveryDelay = TextDocument.defaultMaximumRecoveryDelay
    #else
        private let automaticRecoveryDelay = TextDocument.defaultAutomaticRecoveryDelay
        private let maximumRecoveryDelay = TextDocument.defaultMaximumRecoveryDelay
    #endif
    let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    /// Encoding/BOM checkpoint paired with the save point from the latest completed read or save.
    var savedFormat = FileFormat(encoding: .utf8, bom: false)
    var format = FileFormat(encoding: .utf8, bom: false) {
        didSet {
            if !loading && format != oldValue {
                recoveryBase += 1
                updateChangeCount(hasUnsavedState ? .changeDone : .changeCleared)
            }
        }
    }
    /// SHA-256 of the bytes last read or saved. No copy of the file is kept.
    private var diskDigest: String?
    /// Settled metadata of a file known to hold those bytes, when there is one. While the file
    /// still has exactly this metadata it need not be read again; nil means read and hash.
    private var diskSignature: FileSignature?
    /// A sample taken by a caller that read the bytes through its own descriptor.
    private var capturedSample: FileSample?
    /// Immutable bytes captured before a coordinated write; only data(ofType:) reads them during that write.
    private var savePayload: Data?
    /// False if edits arrived during a save, so Scintilla's save point no longer identifies the disk bytes.
    private var savepointMatchesDisk = true
    /// Ordinary dirty state shared by editor-change and format-change callbacks.
    private var hasUnsavedState: Bool { editor.modified || format != savedFormat || !savepointMatchesDisk }
    /// Recovery also keeps an untouched restored document: its framework dirty flag is independent
    /// of the freshly loaded editor's save point and format checkpoint. Keep this broader rule distinct.
    private var shouldKeepRecoveryCopy: Bool { isDocumentEdited || editor.modified || format != savedFormat }
    private var recoveryRevision: UInt64 { recoveryBase + UInt64(editor.revision) }
    #if TESTING
        var afterWriteForTesting: (() throws -> Void)?
        /// Runs while NSDocument is inside an in-progress write, as the bytes are produced.
        var duringWriteForTesting: (() -> Void)?
        var hasSettledDiskSignature: Bool { diskSignature != nil }
    #endif
    var originalDiskFingerprint: String? { diskDigest }
    var languageIdentifier = LanguageProfile.plainTextID { didSet { languageResolved = true } }
    /// False until the first load has chosen a language, or the person or a restored session has.
    /// Reload and Revert then keep that choice instead of detecting again.
    private var languageResolved = false
    /// Status-line text for a recovered draft: what it is a draft of and when it was written.
    /// Cleared when the draft is saved under a name of its own.
    private(set) var recoveredOrigin: String?
    /// Suppresses ordinary edit/recovery callbacks while a read or restore establishes its checkpoints.
    private var loading = false
    /// Set only while an explicit open-with-encoding is reading the file.
    private var openEncoding: FileEncoding?
    private var readingURL: URL?
    /// A snapshot records the file it belongs to. A moved or renamed file is new snapshot
    /// metadata at the same text revision, so it needs a later recovery revision.
    ///
    /// While an in-place save is inside NSDocument, the getter answers with the resolved
    /// location being written. NSDocument's safe save replaces the item at `fileURL`, not at the
    /// URL it is handed: with a link as `fileURL` it fails, and with the two differing it can
    /// remove the original and then fail. Answering with the destination keeps them equal.
    /// Only the main thread, which does the write, is answered that way: NSDocument also reads
    /// `fileURL` from its file-presenter queue, and every other thread keeps the opened path.
    /// `inPlaceWriteURL` is therefore read and written on the main thread alone.
    override var fileURL: URL? {
        get {
            if Thread.isMainThread, let inPlaceWriteURL { return inPlaceWriteURL }
            return super.fileURL
        }
        set {
            let oldValue = super.fileURL
            super.fileURL = newValue
            guard newValue != oldValue else { return }
            diskURL = newValue.map(Self.canonicalDiskURL)
            if Thread.isMainThread {
                recoveryBase += 1
                // Saved under a name of its own: no longer a recovered draft. Setting the URL has
                // already replaced the "Recovered …" display name with the file's name.
                recoveredOrigin = nil
            } else {
                DispatchQueue.main.async { [weak self] in self?.recoveryBase += 1 }
            }
        }
    }
    /// Where the file really is: `fileURL` with symbolic links resolved once, when `fileURL` is
    /// set. The no-follow reads and the in-place write use it, so a document reached through a
    /// link can be checked and saved, and a link swapped in later is still refused because this
    /// is not resolved again. `fileURL` itself keeps the path the person opened.
    private(set) var diskURL: URL?
    private var inPlaceWriteURL: URL?
    /// realpath(3) of the file; for a name that does not exist yet, of its folder. Falls back
    /// to the URL as given.
    static func canonicalDiskURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        func resolved(_ path: String) -> String? {
            guard let pointer = realpath(path, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        if let path = resolved(url.path) { return URL(fileURLWithPath: path, isDirectory: false) }
        if let folder = resolved(url.deletingLastPathComponent().path) {
            return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(
                url.lastPathComponent, isDirectory: false)
        }
        return url
    }
    /// Runs a no-follow read of the document's own file at its resolved location. ELOOP and
    /// ENOTDIR mean the resolved path has since become a link, or its folder is no longer a
    /// real folder.
    private func onDiskFile<T>(_ read: (URL) throws -> T) throws -> T {
        guard let url = diskURL else {
            throw DocumentActionError.notSaved
        }
        do { return try read(url) } catch let error as POSIXError
            where error.code == .ELOOP || error.code == .ENOTDIR
        {
            throw DocumentActionError.unsafeDiskPath(url, underlying: error)
        }
    }
    enum DiskState: Equatable {
        case unchanged, changed, missing
        var alertText: (title: String, detail: String) {
            let title: String
            switch self {
            case .unchanged: title = "File is unchanged"
            case .missing: title = "File is missing"
            case .changed: title = "File changed outside TextTank"
            }
            let detail =
                self == .unchanged
                ? "The on-disk bytes match the last read or save."
                : "Your editor contents are preserved. Use Save As to keep your edits, or Revert to Saved to reload the disk version."
            return (title: title, detail: detail)
        }
    }
    func diskState() throws -> DiskState {
        try diskState(trustingSettledMetadata: false)
    }
    /// The state of the document's own file at its resolved location. An explicit check always
    /// hashes the file, in steps, without holding it in memory. A save may instead trust settled
    /// metadata that is unchanged since the bytes were last read: that is the file last read.
    /// Right after a save the metadata is too new to rely on, so the hash still runs.
    private func diskState(trustingSettledMetadata: Bool) throws -> DiskState {
        guard fileURL != nil, let diskDigest else { return .unchanged }
        do {
            return try onDiskFile { url -> DiskState in
                if trustingSettledMetadata, let diskSignature,
                    try WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max) == diskSignature
                {
                    return .unchanged
                }
                let sample = try WorkspaceStore.sample(ofRegularFileAt: url, maximumBytes: Int.max)
                guard sample.digest == diskDigest else { return .changed }
                diskSignature = sample.signature
                return .unchanged
            }
        } catch  where error.isFileNotFound { return .missing }
    }
    @objc func toggleReadOnly(_ sender: NSMenuItem) {
        // Read-only belongs to the Scintilla document, so this covers a split view's other pane.
        // The checkmark is set when a menu is validated, for the document that menu acts on.
        editor.readOnly.toggle()
    }
    /// Everything NSDocument validates itself (Save, Revert to Saved and the rest) is left to it.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(checkExternalChanges(_:)) { return fileURL != nil }
        if item.action == #selector(toggleReadOnly(_:)) {
            (item as? NSMenuItem)?.state = editor.readOnly ? .on : .off
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
    @objc func checkExternalChanges(_ sender: Any?) {
        guard fileURL != nil else { return }
        do {
            let state = try diskState()
            let alert = TTAlert()
            let text = state.alertText
            alert.messageText = text.title
            alert.informativeText = text.detail
            alert.runModal()
        } catch { presentError(error) }
    }
    /// Explicit reinterpretation is a reload, not encoding conversion. Unsaved edits
    /// require a native confirmation before this method is called with discard=true.
    func reload(using encoding: FileEncoding, discard: Bool = false) throws {
        guard fileURL != nil else {
            throw DocumentActionError.notSaved
        }
        if isDocumentEdited && !discard {
            throw DocumentActionError.unsavedChanges
        }
        let (bytes, sample) = try onDiskFile { try WorkspaceStore.readRegularFileSample($0, maximumBytes: Int.max) }
        let decoded = try FileCodec.decode(bytes, encoding: encoding)
        loadDecoded(decoded, sample: sample)
        updateChangeCount(.changeCleared)
        flushRecovery()
    }
    @objc func reloadEncoding(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let encoding = FileEncoding(rawValue: raw) else { return }
        if isDocumentEdited {
            let alert = TTAlert()
            alert.messageText = "Discard unsaved changes and reload?"
            alert.informativeText =
                "The disk bytes will be interpreted as \(encoding.displayName). Use Convert to change the save encoding while keeping your text."
            alert.addButton(withTitle: "Cancel", role: .cancel)
            alert.addButton(withTitle: "Discard and Reload").hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do { try reload(using: encoding, discard: true) } catch { presentError(error) }
    }
    override init() {
        super.init()
        hasUndoManager = false
        // Typing or a key command that Scintilla refuses in a read-only document; the status bar
        // shows Read Only. Menu commands state the reason in words before they reach the engine.
        editor.onReadOnlyAttempt = { [weak self] in self?.noteReadOnlyAttempt() }
        editor.onChange = { [weak self] in
            guard let self, !self.loading else { return }
            self.updateChangeCount(self.hasUnsavedState ? .changeDone : .changeCleared)
            self.showSaveState(recoveryCopyKept: false)
            self.recoveryTimer?.invalidate()
            self.recoveryGeneration += 1
            self.recoveryTimer = self.scheduleRecoveryTimer(after: self.automaticRecoveryDelay)
            if self.recoveryDeadlineTimer == nil {
                self.recoveryDeadlineTimer = self.scheduleRecoveryTimer(after: self.maximumRecoveryDelay)
            }
        }
    }
    /// Common modes include modal panels and event tracking, so the idle and deadline
    /// snapshots still happen while an alert, a menu or interactive macro playback is up.
    /// The timer only captures an immutable snapshot; it never edits the document.
    private func scheduleRecoveryTimer(after delay: TimeInterval) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.enqueueRecovery() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
    private func cancelRecoveryTimers() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recoveryDeadlineTimer?.invalidate()
        recoveryDeadlineTimer = nil
    }
    private func recoveryOperation() -> () throws -> Void {
        let store = Self.recovery, id = recoveryID, revision = recoveryRevision
        if shouldKeepRecoveryCopy {
            let snapshot = RecoverySnapshot(
                id: id, text: editor.text, format: format, originalURL: fileURL?.absoluteString, revision: revision)
            return { try store.save(snapshot) }
        }
        return { try store.remove(id: id, throughRevision: revision) }
    }
    /// The words for this document's save state. An edited document never reads "Saved": it reads
    /// "Edited" from the moment of the change, and says so about the recovery copy only once that
    /// copy has been written.
    func saveStateStatus(recoveryCopyKept: Bool) -> String {
        if let recoveredOrigin { return recoveredOrigin }
        let status: String
        if isDocumentEdited {
            status = recoveryCopyKept ? "Edited — recovery copy kept" : "Edited"
        } else if fileURL == nil {
            status = "Ready"
        } else {
            status = "Saved"
        }
        return status
    }
    /// Whether the last recovery write since the latest edit succeeded.
    private var recoveryCopyKept = false
    /// The save-state words as they stand now, for a view that showed something else for a moment.
    var currentSaveStateStatus: String { saveStateStatus(recoveryCopyKept: recoveryCopyKept) }
    /// Typing or a key command that the engine refused because the document is read-only: the
    /// alert sound alone says nothing to someone who cannot hear it or does not know why.
    func noteReadOnlyAttempt() {
        NSSound.beep()
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach {
            $0.showTransientStatus(
                "Read Only is on, so this document cannot be edited. Choose File > Read Only to turn it off.")
        }
    }
    /// Shows the save state now. A recovery failure stays on screen until a later write succeeds.
    private func showSaveState(recoveryCopyKept: Bool) {
        self.recoveryCopyKept = recoveryCopyKept
        guard lastRecoveryError == nil else { return }
        let message = saveStateStatus(recoveryCopyKept: recoveryCopyKept)
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach {
            $0.showRecoveryStatus(message, failed: false)
        }
    }
    private func reportRecovery(_ error: Error?) {
        lastRecoveryError = error
        let controllers = windowControllers.compactMap { $0 as? EditorWindowController }
        guard let error else {
            recoveryFailures.recordSuccess()
            showSaveState(recoveryCopyKept: true)
            return
        }
        // The status line stays in its failure state until a later recovery write succeeds.
        controllers.forEach {
            $0.showRecoveryStatus("⚠︎ Recovery copy not written: \(error.localizedDescription)", failed: true)
        }
        let escalate = recoveryFailures.recordFailure(sessionAlreadyNotified: Self.recoveryFailureNoticeShown)
        if recoveryFailures.consecutiveFailures == 1 {
            NSLog(
                "TextTank: recovery snapshot %@ could not be written: %@", recoveryID.uuidString,
                error.localizedDescription)
        }
        if escalate { Self.recoveryFailureNoticeShown = presentRecoveryFailureNotice(error) }
    }
    /// A sheet, never an app-modal alert: this runs from the recovery timer and must not
    /// interrupt typing. Returns false when there was nowhere to show it, so a later failure retries.
    private func presentRecoveryFailureNotice(_ error: Error) -> Bool {
        #if TESTING
            Self.recoveryFailureNoticeForTesting?(self, error)
            return Self.recoveryFailureNoticeForTesting != nil
        #else
            guard let window = windowControllers.compactMap({ $0.window }).first(where: { $0.isVisible }) else {
                return false
            }
            let alert = TTAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unsaved changes are not being backed up"
            alert.informativeText =
                "TextTank could not write the crash-recovery copy of “\(displayName ?? "this document")” more than once in a row. If the app quit unexpectedly now, recent edits could be lost. The document itself is unchanged; save it to keep your work.\n\nReason: \(error.localizedDescription)\n\nThis notice appears once per session. The status line keeps showing the failure until a recovery copy is written again."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return true
        #endif
    }
    private func enqueueRecovery() {
        guard !recoveryClosed else { return }
        cancelRecoveryTimers()
        let generation = recoveryGeneration, operation = recoveryOperation()
        recoveryWriter.submit { [weak self] in
            let error: Error?
            do {
                try operation()
                error = nil
            } catch let failure { error = failure }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.recoveryClosed, self.recoveryGeneration == generation else { return }
                self.reportRecovery(error)
            }
        }
    }
    func flushRecovery() {
        guard !recoveryClosed else { return }
        cancelRecoveryTimers()
        recoveryGeneration += 1
        do {
            try recoveryWriter.finish(recoveryOperation())
            reportRecovery(nil)
        } catch { reportRecovery(error) }
    }
    override func close() {
        EditorServices.current?.macros?.editorWillReset(editor, reason: "The recording document was closed.")
        cancelRecoveryTimers()
        recoveryGeneration += 1
        recoveryClosed = true
        editor.onReadOnlyAttempt = nil
        editor.readOnly = true
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.prepareForClose() }
        // NSDocument only reaches close after the user has chosen Save or Discard.
        let store = Self.recovery, id = recoveryID, revision = recoveryRevision
        // Never block or prompt here: close runs once per document on the quit path. A snapshot
        // that could not be removed is found by the next launch's scan and offered or listed there.
        do { try recoveryWriter.finish { try store.remove(id: id, throughRevision: revision) } } catch {
            lastRecoveryError = error
            NSLog(
                "TextTank: recovery snapshot %@ could not be removed at close: %@", id.uuidString,
                error.localizedDescription)
        }
        super.close()
    }
    override class var autosavesInPlace: Bool { false }
    override func makeWindowControllers() { addWindowController(EditorWindowController(document: self)) }
    override func read(from url: URL, ofType typeName: String) throws {
        readingURL = url
        defer { readingURL = nil }
        // AppKit reads the file itself. Settled metadata that is the same on both sides of
        // that read belongs to the bytes it read; anything else leaves the next check to hash.
        let now = WorkspaceStore.currentSecond()
        let before = try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max)
        try super.read(from: url, ofType: typeName)
        if let before, before.isSettled(at: now),
            (try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max)) == before
        {
            diskSignature = before
        }
    }
    /// Reads bytes the caller captured from `url` through the regular-file descriptor guard.
    /// Naming the file lets a UTF-32-looking signature offer the explicit UTF-16 LE open.
    /// `encoding` is the person's explicit choice, as in `read(from:ofType:as:)`.
    func read(
        captured data: Data, sample: FileSample, from url: URL, ofType typeName: String,
        as encoding: FileEncoding? = nil
    ) throws {
        let outerEncoding = openEncoding
        readingURL = url
        capturedSample = sample
        if let encoding { openEncoding = encoding }
        defer {
            readingURL = nil
            capturedSample = nil
            openEncoding = outerEncoding
        }
        try read(from: data, ofType: typeName)
    }
    override func read(from data: Data, ofType typeName: String) throws {
        let decoded: DecodedFile
        if let openEncoding {
            decoded = try FileCodec.decode(data, encoding: openEncoding)
        } else {
            do { decoded = try FileCodec.decode(data) } catch FileCodecError.unsupportedUTF32 {
                // FF FE 00 00 is also what UTF-16 LE with a BOM looks like when the text starts
                // with NUL, which TextTank itself can save. Detection stays strict; the user is
                // offered the explicit choice the codec's message asks for.
                guard let readingURL, data.starts(with: [0xFF, 0xFE, 0, 0]) else {
                    throw FileCodecError.unsupportedUTF32
                }
                throw ExplicitEncodingOpener(url: readingURL, typeName: typeName, encoding: .utf16LE).error()
            }
        }
        loadDecoded(
            decoded, sample: capturedSample ?? FileSample(digest: WorkspaceStore.fingerprint(data), signature: nil))
    }
    /// The same strict decode with an encoding the person chose, for callers that already hold
    /// the bytes. A failure throws the codec's error and loads nothing.
    func read(from data: Data, ofType typeName: String, as encoding: FileEncoding) throws {
        openEncoding = encoding
        defer { openEncoding = nil }
        try read(from: data, ofType: typeName)
    }
    /// Explicit open-with-encoding. An already open document is reloaded from disk instead;
    /// that only happens from Revert to Saved, where discarding edits was already confirmed.
    @discardableResult static func open(
        _ url: URL, as encoding: FileEncoding, ofType typeName: String = TextDocument.plainTextType,
        display: Bool = true
    ) throws -> TextDocument {
        if let existing = NSDocumentController.shared.document(for: url) as? TextDocument {
            try existing.reload(using: encoding, discard: true)
            return existing
        }
        let doc = TextDocument()
        doc.fileURL = url
        doc.fileType = typeName
        doc.openEncoding = encoding
        defer { doc.openEncoding = nil }
        try doc.read(from: url, ofType: typeName)
        doc.fileModificationDate =
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        NSDocumentController.shared.addDocument(doc)
        if display {
            doc.makeWindowControllers()
            doc.showWindows()
        }
        return doc
    }
    /// NSDocument's revert discards the edits but schedules no recovery work, because loading
    /// suppresses change handling. Remove the discarded draft's snapshot now. If the revert
    /// throws, the buffer is still dirty and its snapshot must survive.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        flushRecovery()
    }
    /// Loads recovered or session text as a new unsaved document. Undo cannot cross this
    /// boundary (as for open and revert), and the document stays edited until a real save:
    /// the engine's save point is this text, which is not a disk state.
    func loadUnsavedSnapshot(text: String, format snapshotFormat: FileFormat) {
        loading = true
        format = snapshotFormat
        // A new document: writable and empty, so the load cannot be refused.
        _ = editor.loadDocumentText(text)
        editor.setLineEndingMode(LineEnding.detect(in: text).rawValue)
        editor.resetUndoHistory()
        savepointMatchesDisk = false
        loading = false
        updateChangeCount(.changeDone)
    }
    /// Opens one recovery snapshot as a new unsaved document that keeps the snapshot's identity.
    @discardableResult static func openRecovered(_ snapshot: RecoverySnapshot) throws -> TextDocument {
        let (base, overflow) = snapshot.revision.addingReportingOverflow(1)
        guard !overflow else { throw RecoveryError.invalidSnapshot }
        let doc = TextDocument()
        doc.recoveryID = snapshot.id
        doc.recoveryBase = base
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.loadUnsavedSnapshot(text: snapshot.text, format: snapshot.format)
        // Display only: the original path is never opened, read or written by recovery.
        doc.recoveredOrigin = SnapshotLabel.status(for: snapshot)
        if let name = SnapshotLabel.originName(of: snapshot) { doc.displayName = "Recovered " + name }
        doc.showWindows()
        doc.flushRecovery()
        return doc
    }
    private func loadDecoded(_ decoded: DecodedFile, sample: FileSample) {
        EditorServices.current?.macros?.editorWillReset(editor, reason: "The recording document was reloaded.")
        loading = true
        let locked = editor.readOnly
        editor.readOnly = false
        // One minimal-span edit: bookmarks, folds and the caret outside the changed bytes survive a
        // reload. An empty buffer (first open) takes this as a plain insert.
        // No undo record is kept: the history is emptied below, as for every open and reload.
        _ = editor.loadDocumentText(decoded.text)
        editor.setLineEndingMode(LineEnding.detect(in: decoded.text).rawValue)
        editor.resetUndoHistory()
        format = decoded.format
        savedFormat = format
        diskDigest = sample.digest
        diskSignature = sample.signature
        savepointMatchesDisk = true
        editor.setSavePoint()
        editor.readOnly = locked
        loading = false
        guard !languageResolved else { return }
        languageResolved = true
        if let app = EditorServices.current,
            let id = app.languages?.detect(filename: fileURL?.lastPathComponent ?? "", text: decoded.text),
            app.languages?.applyToDocument(identifier: id, through: editor) == true
        {
            languageIdentifier = id
        }
    }
    /// The source's own extension; ".txt" only for an untitled document, nothing for a name without one.
    var suggestedCopyName: String {
        guard let fileURL else { return "Untitled-copy.txt" }
        let type = fileURL.pathExtension
        return fileURL.deletingPathExtension().lastPathComponent + "-copy" + (type.isEmpty ? "" : "." + type)
    }
    /// Save Copy to a chosen location. Choosing the document's own file (the panel has already
    /// asked to replace it) is an ordinary Save, with its conflict check and bookkeeping, so
    /// the external-change baseline cannot fall behind what TextTank itself wrote.
    func writeCopy(to url: URL, completion: @escaping (Error?) -> Void) {
        if let fileURL, let diskURL, Self.canonicalDiskURL(url) == diskURL {
            save(to: fileURL, ofType: fileType ?? Self.plainTextType, for: .saveOperation) { error in
                // NSDocument wraps the failure in a bare "could not be saved"; report the reason itself.
                completion(error.map { ($0 as NSError).userInfo[NSUnderlyingErrorKey] as? Error ?? $0 })
            }
            return
        }
        do {
            try writeSafely(to: url, ofType: fileType ?? Self.plainTextType, for: .saveToOperation)
            completion(nil)
        } catch { completion(error) }
    }
    @objc func saveCopy(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedCopyName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeCopy(to: url) { [weak self] error in if let error { self?.presentError(error) } }
    }
    @objc func convertEncoding(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        do { try convertEncoding(to: code) } catch { presentError(error) }
    }
    /// A read-only document keeps its format, as the status-bar menu already promises.
    func convertEncoding(to code: String) throws {
        try editor.requireWritable()
        guard let target = FileFormat.convertTargets.first(where: { $0.code == code })?.format else {
            throw FileCodecError.invalidConversionTarget
        }
        _ = try FileCodec.encode(editor.text, format: target)
        format = target
        flushRecovery()
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.refreshStatusDetails() }
    }
    /// Printing lays the whole document out on the main thread before the print panel appears.
    /// At and above this many UTF-8 bytes the person is told so first and can cancel.
    static var largePrintBytes = 4 * 1024 * 1024
    /// Asks whether to go on with a slow print; returns false to cancel. Replaced in checks.
    var confirmLargePrint: (_ message: String, _ detail: String) -> Bool = { message, detail in
        let alert = TTAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Print")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// The warning shown before printing a large document, or nil when none is needed. Reads only
    /// the document's size.
    func largePrintWarning() -> (message: String, detail: String)? {
        let bytes = editor.byteLength
        guard bytes >= Self.largePrintBytes else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return (
            "This document is large (\(size)). Preparing it for printing can take a while.",
            "TextTank will not respond until the pages are laid out, and the print panel appears only after that. The document itself is not changed. To print part of it, copy that part into a new document."
        )
    }
    /// False when the person cancelled a large print. Nothing has been laid out by then.
    func shouldBeginPrinting() -> Bool {
        guard let warning = largePrintWarning() else { return true }
        return confirmLargePrint(warning.message, warning.detail)
    }
    override func printDocument(_ sender: Any?) {
        guard shouldBeginPrinting() else { return }
        super.printDocument(sender)
    }
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation
    {
        let settings = printInfo.copy() as! NSPrintInfo
        settings.dictionary().addEntries(from: printSettings)
        settings.horizontalPagination = .fit
        settings.verticalPagination = .automatic
        settings.isHorizontallyCentered = false
        settings.isVerticallyCentered = false
        let width = max(72, settings.paperSize.width - settings.leftMargin - settings.rightMargin)
        // A static print representation, never a second editable document model.
        let printable = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        printable.isRichText = false
        printable.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        printable.textColor = .black
        printable.backgroundColor = .white
        printable.textContainerInset = .zero
        printable.isHorizontallyResizable = false
        printable.isVerticallyResizable = true
        printable.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        printable.textContainer?.widthTracksTextView = true
        printable.string = editor.text
        if let container = printable.textContainer, let layout = printable.layoutManager {
            layout.ensureLayout(for: container)
            printable.setFrameSize(NSSize(width: width, height: max(1, ceil(layout.usedRect(for: container).height))))
        }
        let operation = NSPrintOperation(view: printable, printInfo: settings)
        operation.jobTitle = displayName
        return operation
    }
    override func data(ofType typeName: String) throws -> Data {
        #if TESTING
            duringWriteForTesting?()
        #endif
        if let savePayload { return savePayload }
        return try FileCodec.encode(editor.text, format: format)
    }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType)
        throws
    {
        // A write to the document's own file goes to its resolved location, so the bytes checked
        // and the bytes replaced are the same file and a link in the path stays a link.
        let inPlace = fileURL != nil && url == fileURL
        let destination = inPlace ? diskURL ?? url : url
        // A missing file is simply written again. A changed one is refused, except for Save As:
        // there the save panel has already asked the person to replace that file. Any other
        // failure (the path became a link, a folder or unreadable) still stops the save.
        if inPlace, diskDigest != nil, try diskState(trustingSettledMetadata: true) == .changed,
            saveOperation != .saveAsOperation
        {
            throw DocumentActionError.diskChanged
        }
        let submitted = try FileCodec.encode(editor.text, format: format), submittedFormat = format,
            submittedRevision = editor.revision
        savePayload = submitted
        defer { savePayload = nil }
        do {
            inPlaceWriteURL = inPlace && Thread.isMainThread ? destination : nil
            defer { inPlaceWriteURL = nil }
            try super.writeSafely(to: destination, ofType: typeName, for: saveOperation)
        }
        #if TESTING
            try afterWriteForTesting?()
        #endif
        if saveOperation != .saveToOperation {
            // The baseline is what was submitted. The file's metadata is not recorded here:
            // another writer may already have replaced it, and only a hash can tell.
            diskDigest = WorkspaceStore.fingerprint(submitted)
            diskSignature = nil
            savedFormat = submittedFormat
            if editor.revision == submittedRevision && format == submittedFormat {
                savepointMatchesDisk = true
                editor.setSavePoint()
                updateChangeCount(.changeCleared)
            } else {
                savepointMatchesDisk = false
                updateChangeCount(.changeDone)
            }
            flushRecovery()
        }
    }

}
