import TextTankCore
import EditorBridge
import NativeSearch
import AppKit
import UniformTypeIdentifiers

/// The Objective-C name is fixed, so `NSDocumentClass` in Info.plist does not depend on the
/// name of the Swift module.
@objc(TextDocument) final class TextDocument: NSDocument {
    let runtimeID = DocumentID()
    var bulkReceipt: BulkChangeReceipt?
    private(set) var loadEpoch: UInt = 0
    private(set) var isClosed = false
    private var opened = false
    var isOpen: Bool { opened && !isClosed }
    var presentations: [EditorWindowController] {
        windowControllers.compactMap { $0 as? EditorWindowController }.filter { !$0.isRetired }
    }
    var presentation: EditorWindowController? {
        guard let first = presentations.first else { return nil }
        return first.host.presentation(for: runtimeID) ?? first
    }
    private var lastSaveConflict: SavedVersionDecision?
    private var tabClosePending = false
    override var windowForSheet: NSWindow? { isClosed ? nil : presentation?.hostWindow }
    private func revealForNativeAction() {
        guard !isClosed else { return }
        if presentation == nil { makeWindowControllers() }
        if let presentation { presentation.host.activate(presentation, explicit: false) }
    }
    override func canClose(
        withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?
    ) {
        revealForNativeAction()
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }
    override func willPresentError(_ error: Error) -> Error {
        let presented = super.willPresentError(error) as NSError
        guard let conflict = lastSaveConflict, conflict.allowsComparison,
            (error as NSError).userInfo[DocumentActionError.saveConflictAttemptKey] as? String == conflict.id.uuidString
        else { return presented }
        var info = presented.userInfo
        info[NSLocalizedRecoveryOptionsErrorKey] = ["Cancel", "Compare…"]
        info[NSLocalizedRecoverySuggestionErrorKey] =
            "The file changed outside TextTank. Compare it with your edits, or use Save As to keep a separate copy."
        info[NSRecoveryAttempterErrorKey] = conflict
        return NSError(domain: presented.domain, code: presented.code, userInfo: info)
    }
    override func save(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        revealForNativeAction()
        // AppKit asks whether to overwrite before it calls writeSafely. A proved
        // byte conflict already prevents TextTank from writing this saved document.
        if let window = windowForSheet, window.attachedSheet == nil, let conflict = conflictForSaveCommand() {
            presentError(conflict, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            return
        }
        super.save(sender)
    }
    private func conflictForSaveCommand() -> DocumentActionError? {
        guard isDocumentEdited, let url = diskURL, let diskDigest,
            presentation?.host.tabCommands.isBusy != true,
            EditorServices.current?.compare?.canCompareSaved(self) == true
        else { return nil }
        let limit = ReviewDiffPolicy.default.maximumInputBytes
        guard let identity = try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: limit),
            identity != diskSignature,
            let sample = try? WorkspaceStore.sample(ofRegularFileAt: url, maximumBytes: limit, matching: identity)
        else { return nil }
        guard sample.digest != diskDigest else {
            diskSignature = sample.signature
            return nil
        }
        return saveConflict(at: url, identity: identity)
    }
    private func saveConflict(at url: URL, identity: FileSignature? = nil) -> DocumentActionError {
        let decision = SavedVersionDecision(self, at: url, observed: identity)
        lastSaveConflict = decision
        return .diskChanged(decision.id)
    }
    override func saveAs(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        revealForNativeAction()
        super.saveAs(sender)
    }
    override func revertToSaved(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        revealForNativeAction()
        super.revertToSaved(sender)
    }
    override func runPageLayout(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        revealForNativeAction()
        super.runPageLayout(sender)
    }
    func requestTabClose(_ sender: Any?) {
        guard isOpen, !tabClosePending else { return }
        tabClosePending = true
        if isDocumentEdited, let url = diskURL, let window = windowForSheet, window.attachedSheet == nil,
            EditorServices.current?.compare?.canCompareSaved(self) == true
        {
            let decision = SavedVersionDecision(self, at: url)
            if decision.allowsComparison {
                reviewSingleTabClose(decision, in: window)
                return
            }
        }
        canClose(
            withDelegate: self, shouldClose: #selector(tabCloseReviewed(_:shouldClose:contextInfo:)), contextInfo: nil)
    }
    /// Only the last view of one explicitly closed tab uses this review. AppKit owns
    /// application quit; the existing bulk tab command collects its own separate decisions.
    private func reviewSingleTabClose(_ decision: SavedVersionDecision, in window: NSWindow) {
        let alert = TTAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: "Save changes to “%@” before closing?", displayName)
        alert.informativeText = "Review Changes keeps this document open and compares your edits with the saved file."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel", role: .cancel)
        alert.addButton(withTitle: "Review Changes…")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.tabClosePending = false
            guard decision.isCurrent, EditorServices.current?.reviewingTermination() != true else { return }
            switch TTAlert.Result(response) {
            case .button(0):
                self.tabClosePending = true
                TabSaveReply.save(self) { [weak self] error in
                    guard let self else { return }
                    self.tabClosePending = false
                    if error == nil, decision.sameEditorState, !self.isDocumentEdited, !self.hasUnsavedState,
                        EditorServices.current?.reviewingTermination() != true
                    {
                        self.close()
                    }
                }
            case .button(1):
                if decision.diskStillMatches {
                    self.close()
                } else {
                    self.presentation?.showTransientStatus(
                        "The saved file changed during review. The document remains open.")
                }
            case .button(3):
                decision.compareAfterDismissal()
            default: break
            }
        }
    }
    @objc private func tabCloseReviewed(
        _ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        tabClosePending = false
        if shouldClose, document === self, isOpen { close() }
    }
    override var displayName: String! { didSet { presentation?.host.metadataChanged() } }
    /// The type name used where a document has none of its own. Reading ignores the type.
    nonisolated static let plainTextType = "public.plain-text"
    /// No File Format pop-up in the Save panel. Every content type in Info.plist is a writable
    /// type and nearly all are named "Plain Text"; choosing one would only switch the type name
    /// and, for some, add that type's extension. The text is written the same way for all.
    override var shouldRunSavePanelWithAccessoryView: Bool { false }
    static let recovery = RecoveryStore(directory: AppStorage.url(.recovery))
    private(set) var recoveryID = UUID()
    /// Offset for recovery metadata changes; adding the editor revision gives the store revision.
    private(set) var recoveryBase: UInt64 = 0
    /// One notice per app session about repeated recovery-write failures.
    static var recoveryFailureNoticeShown = false
    private var recoveryFailures = RecoveryFailureTracker()
    /// The failure of the most recent recovery write or cleanup; nil after a success.
    private(set) var lastRecoveryError: Error?
    private var recoveryTimer: Timer?
    private var recoveryDeadlineTimer: Timer?
    private let recoveryWriter = RecoveryWriter()
    /// One immutable capture can be preparing. A timer that fires meanwhile requests one fresh
    /// capture after preparation, without copying bytes or waiting for validation or disk I/O.
    private var preparingRecoveryGeneration: Int?
    private var deferredRecoveryCapture = false
    /// Invalidates completion callbacks whenever recovery is rescheduled, flushed or closed.
    private var recoveryGeneration = 0
    /// Terminal once close starts: no timer or late completion may enqueue another copy.
    private var recoveryClosed = false
    var dependencies: DocumentDependencies
    private var recoveryBurstStart: TimeInterval?
    private var scheduledDeadline: TimeInterval?
    static func automaticRecoveryScale(byteCount: Int) -> Double? {
        let limits = SizePolicy.standard
        switch byteCount {
        case ...limits.recoverySmall: return 1
        case ...limits.recoveryMedium: return 2
        case ...limits.recoveryLarge: return 4
        case ...limits.automaticRecovery: return 8
        default: return nil
        }
    }
    var automaticRecoveryPaused: Bool { Self.automaticRecoveryScale(byteCount: editor.byteLength) == nil }
    var compactPausedRecoveryStatus: String? {
        guard automaticRecoveryPaused else { return nil }
        return shouldKeepRecoveryCopy
            ? "Recovery paused · Save" : (fileURL == nil ? "Recovery paused" : "Saved · Recovery paused")
    }
    private(set) var editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    /// Encoding/BOM checkpoint paired with the save point from the latest completed read or save.
    private(set) var savedFormat = FileFormat(encoding: .utf8, bom: false)
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
    lazy var externalFile = ExternalFileObservation(document: self)
    var savedDiskSample: FileSample? { diskDigest.map { FileSample(digest: $0, signature: diskSignature) } }
    /// Used only after a renewed comparison with the visible notice's file, bytes and editor state.
    func acceptExternalRead(_ read: CapturedFileRead, from url: URL) throws {
        try self.read(
            captured: read.data, sample: read.sample, from: url, ofType: fileType ?? Self.plainTextType,
            as: revertEncoding)
        fileModificationDate = read.modificationDate
        updateChangeCount(.changeCleared)
        flushRecovery()
    }

    func externalNoticeChanged() {
        showSaveState(recoveryCopyKept: recoveryCopyKept)
        for p in presentations { p.configureExternalReload() }
        presentation?.host.metadataChanged()
        if let notice = externalFile.notice, lastRecoveryError == nil, let visible = presentation,
            visible.isActiveTab, visible.isPresented, visible.hostWindow?.isKeyWindow == true
        {
            Announce.say(notice, from: visible.hostWindow)
        }
    }

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
    var hasSettledDiskSignature: Bool { diskSignature != nil }
    var originalDiskFingerprint: String? { diskDigest }
    private(set) var languageIdentifier = LanguageProfile.plainTextID { didSet { languageResolved = true } }
    /// State notification after LanguageController already installed the lexer and view styles.
    /// Never applies a profile again: menu/style callbacks use this path.
    private(set) var deferredLargeFileLanguage: String?
    func noteAppliedLanguage(_ identifier: String) {
        languageIdentifier = identifier
        deferredLargeFileLanguage = nil
    }
    func enableLargeFileEditing() {
        guard let identifier = deferredLargeFileLanguage else { return }
        if identifier == LanguageProfile.plainTextID {
            usePlainTextLanguage()
        } else if !applyLanguage(identifier, using: EditorServices.current?.languages) {
            presentations.forEach { $0.showTransientStatus("The saved language profile is unavailable. Choose a language.") }
            return
        }
        for view in presentations.flatMap(\.views) { view.wrap = EditorServices.current?.settings?.value.wrap ?? false }
        presentations.forEach { $0.refreshStatusDetails() }
    }
    /// Explicit document-level language intent for loads/restores; metadata changes only after success.
    @discardableResult func applyLanguage(_ identifier: String, using controller: LanguageController?) -> Bool {
        guard let controller, controller.applyToDocument(identifier: identifier, through: editor) else { return false }
        noteAppliedLanguage(identifier)
        return true
    }
    func usePlainTextLanguage() {
        noteAppliedLanguage(LanguageProfile.plainTextID)
        editor.setLanguage("null")
    }
    /// False until the first load has chosen a language, or the person or a restored session has.
    /// Reload and Revert then keep that choice instead of detecting again.
    private var languageResolved = false
    /// Status-line text for a recovered draft: what it is a draft of and when it was written.
    /// Cleared when the draft is saved under a name of its own.
    private(set) var recoveredOrigin: String?
    private var recoveredOriginalURL: String?
    /// Suppresses ordinary edit/recovery callbacks while a read or restore establishes its checkpoints.
    private var loading = false
    /// A transient decoder override for one read; nil keeps automatic detection.
    private var openEncoding: FileEncoding?
    /// Explicit interpretation of the last successful disk baseline, independent of unsaved conversion.
    private(set) var revertEncoding: FileEncoding?
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
            // File-presenter reads must never wait for main, which can be waiting for them.
            if Thread.isMainThread {
                if let destination = MainActor.assumeIsolated({ inPlaceWriteURL }) { return destination }
            }
            return super.fileURL
        }
        set {
            let oldValue = super.fileURL
            super.fileURL = newValue
            guard newValue != oldValue else { return }
            diskLocation.set(newValue.map(Self.canonicalDiskURL))
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    recoveryBase += 1
                    externalFile.invalidate()
                    // Only the existing main-thread setter route clears the recovered label.
                    recoveredOrigin = nil
                    recoveredOriginalURL = nil
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.recoveryBase += 1
                    self?.externalFile.invalidate()
                }
            }
        }
    }
    /// Where the file really is: `fileURL` with symbolic links resolved once, when `fileURL` is
    /// set. The no-follow reads and the in-place write use it, so a document reached through a
    /// link can be checked and saved, and a link swapped in later is still refused because this
    /// is not resolved again. `fileURL` itself keeps the path the person opened.
    nonisolated private let diskLocation = DocumentDiskLocation()
    nonisolated var diskURL: URL? { diskLocation.get() }
    private var inPlaceWriteURL: URL?
    /// realpath(3) of the file; for a name that does not exist yet, of its folder. Falls back
    /// to the URL as given.
    nonisolated static func canonicalDiskURL(_ url: URL) -> URL {
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
        guard !CompareCommandScope.blocksWorkspace else { return }
        // Read-only belongs to the Scintilla document, so this covers a split view's other pane.
        // The checkmark is set when a menu is validated, for the document that menu acts on.
        editor.readOnly.toggle()
    }
    /// Everything NSDocument validates itself (Save, Revert to Saved and the rest) is left to it.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard !CompareCommandScope.blocksWorkspace else { return false }
        if item.action == #selector(compareWithSavedVersion(_:)) {
            return EditorServices.current?.compare?.canCompareSaved(self) == true
        }
        if item.action == #selector(checkExternalChanges(_:)) { return fileURL != nil }
        if item.action == #selector(toggleReadOnly(_:)) {
            (item as? NSMenuItem)?.state = editor.readOnly ? .on : .off
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
    @objc func compareWithSavedVersion(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        EditorServices.current?.compare?.compareSaved(self)
    }
    @objc func checkExternalChanges(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
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
    func reload(using encoding: FileEncoding, discard: Bool = false, rememberEncoding: Bool = true) throws {
        guard fileURL != nil else {
            throw DocumentActionError.notSaved
        }
        if isDocumentEdited && !discard {
            throw DocumentActionError.unsavedChanges
        }
        let (bytes, sample) = try onDiskFile { try WorkspaceStore.readRegularFileSample($0, maximumBytes: Int.max) }
        try loadFile(bytes, as: encoding, sample: sample, explicitEncoding: rememberEncoding ? encoding : revertEncoding)
        updateChangeCount(.changeCleared)
        flushRecovery()
    }
    @objc func reloadEncoding(_ sender: NSMenuItem) {
        guard !CompareCommandScope.blocksWorkspace else { return }
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
    override convenience init() {
        self.init(dependencies: RuntimeEnvironment.current.document())
    }
    init(dependencies: DocumentDependencies) {
        self.dependencies = dependencies
        super.init()
        EditorLifetime.bind(editor, to: self)
        hasUndoManager = false
        // Typing or a key command that Scintilla refuses in a read-only document; the status bar
        // shows Read Only. Menu commands state the reason in words before they reach the engine.
        editor.onReadOnlyAttempt = { [weak self] in self?.noteReadOnlyAttempt() }
        installChangeObserver()
    }
    private func installChangeObserver() {
        editor.onChange = { [weak self] in
            guard let self, !self.loading else { return }
            self.updateChangeCount(self.hasUnsavedState ? .changeDone : .changeCleared)
            self.showSaveState(recoveryCopyKept: false)
            self.rescheduleRecovery()
        }
    }
    private func rescheduleRecovery() {
        recoveryGeneration += 1
        let scale = Self.automaticRecoveryScale(byteCount: editor.byteLength)
        guard scale != nil || !shouldKeepRecoveryCopy else {
            cancelRecoveryTimers()
            deferredRecoveryCapture = false
            return
        }
        // Undo back to a saved state still removes its obsolete draft, regardless of size.
        let multiplier = scale ?? 1
        let now = ProcessInfo.processInfo.systemUptime
        let start = recoveryBurstStart ?? now
        recoveryBurstStart = start
        recoveryTimer?.invalidate()
        recoveryTimer = scheduleRecoveryTimer(after: dependencies.automaticRecoveryDelay * multiplier)
        let deadline = dependencies.maximumRecoveryDelay * multiplier
        if scheduledDeadline != deadline || recoveryDeadlineTimer == nil {
            recoveryDeadlineTimer?.invalidate()
            scheduledDeadline = deadline
            recoveryDeadlineTimer = scheduleRecoveryTimer(after: max(0, deadline - (now - start)))
        }
    }
    func promoteEditor(from retired: EditorWindowController, to survivor: EditorWindowController) {
        guard editor === retired.primaryEditor else { return }
        precondition(editor.sharesDocument(with: survivor.primaryEditor))
        editor.onChange = nil
        editor = survivor.primaryEditor
        installChangeObserver()
    }
    /// Common modes include modal panels and event tracking, so the idle and deadline
    /// snapshots still happen while an alert, a menu or interactive macro playback is up.
    /// The timer only captures an immutable snapshot; it never edits the document.
    private func scheduleRecoveryTimer(after delay: TimeInterval) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            precondition(Thread.isMainThread)
            MainActor.assumeIsolated { self?.enqueueRecovery() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
    private func cancelRecoveryTimers() {
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        recoveryDeadlineTimer?.invalidate()
        recoveryDeadlineTimer = nil
        recoveryBurstStart = nil
        scheduledDeadline = nil
    }
    /// Editor bytes are content. A leading U+FEFF is text even when the eventual file has a BOM.
    private nonisolated static func capturedText(from bytes: Data?) throws -> String {
        guard let bytes else { throw EditorCaptureError.incomplete }
        guard let text = bytes.withUnsafeBytes(FileCodec.decodeUTF8Content) else {
            throw EditorCaptureError.invalidUTF8
        }
        return text
    }
    private func recoveryPreparation() -> RecoveryWriter.Prepare {
        let store = Self.recovery, id = recoveryID, revision = recoveryRevision
        if shouldKeepRecoveryCopy {
            let bytes = editor.checkedUTF8Data, capturedFormat = format,
                originalURL = fileURL?.absoluteString ?? recoveredOriginalURL
            let capturedAt = Date()
            return {
                let snapshot = try RecoverySnapshot(
                    id: id, text: Self.capturedText(from: bytes), format: capturedFormat,
                    originalURL: originalURL, revision: revision, savedAt: capturedAt)
                return { try store.save(snapshot) }
            }
        }
        return { { try store.remove(id: id, throughRevision: revision) } }
    }
    /// The words for this document's save state. An edited document never reads "Saved": it reads
    /// "Edited" from the moment of the change, and says so about the recovery copy only once that
    /// copy has been written.
    func saveStateStatus(recoveryCopyKept: Bool) -> String {
        var status: String
        if let recoveredOrigin {
            status = recoveredOrigin
        } else if isDocumentEdited {
            status = recoveryCopyKept ? "Edited — recovery copy kept" : "Edited"
        } else if fileURL == nil {
            status = "Ready"
        } else {
            status = "Saved"
        }
        if automaticRecoveryPaused {
            status += " · Automatic recovery paused above \(SizePolicy.describe(SizePolicy.standard.automaticRecovery))."
                + (shouldKeepRecoveryCopy ? " Save to keep changes." : "")
        }
        return externalFile.notice.map { status + " — " + $0 } ?? status
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
        if let error = lastRecoveryError {
            showRecoveryFailure(error)
            return
        }
        let message = saveStateStatus(recoveryCopyKept: recoveryCopyKept)
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach {
            $0.showRecoveryStatus(message, failed: false)
        }
    }
    private func showRecoveryFailure(_ error: Error) {
        let summary = error is PublishedFileSyncFailure ? "⚠︎ Recovery copy unconfirmed" : "⚠︎ Recovery copy not written"
        let paused = automaticRecoveryPaused
        let message =
            (paused ? "Automatic recovery paused above \(SizePolicy.describe(SizePolicy.standard.automaticRecovery)). Save to keep changes. " : "")
            + summary + ": " + error.localizedDescription
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach {
            $0.showRecoveryStatus(message, failed: true, failureSummary: paused ? "Recovery paused · Save" : summary)
        }
    }
    private func reportRecovery(_ error: Error?) {
        lastRecoveryError = error
        guard let error else {
            recoveryFailures.recordSuccess()
            showSaveState(recoveryCopyKept: true)
            return
        }
        // The status line stays in its failure state until a later recovery write succeeds.
        recoveryCopyKept = false
        showRecoveryFailure(error)
        let escalate = recoveryFailures.recordFailure(sessionAlreadyNotified: Self.recoveryFailureNoticeShown)
        if recoveryFailures.consecutiveFailures == 1 {
            NSLog(
                "TextTank: recovery snapshot %@ could not be confirmed: %@", recoveryID.uuidString,
                error.localizedDescription)
        }
        if escalate { Self.recoveryFailureNoticeShown = presentRecoveryFailureNotice(error) }
    }
    /// A sheet, never an app-modal alert: this runs from the recovery timer and must not
    /// interrupt typing. Returns false when there was nowhere to show it, so a later failure retries.
    private func presentRecoveryFailureNotice(_ error: Error) -> Bool {
        if let notice = dependencies.recoveryFailureNotice { return notice(self, error) }
        guard let presentation, presentation.isPresented, let window = presentation.hostWindow else {
            return false
        }
        let alert = TTAlert()
        alert.alertStyle = .warning
        alert.messageText = "TextTank could not confirm the recovery copy"
        alert.informativeText =
            "TextTank could not confirm the crash-recovery copy of “\(displayName ?? "this document")” more than once in a row. If the app quit unexpectedly now, recent edits could be lost. The document itself is unchanged; save it to keep your work.\n\nReason: \(error.localizedDescription)\n\nThis notice appears once per session. The status line keeps showing the failure until a recovery copy is written again."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
        return true
    }
    private func enqueueRecovery() {
        guard !recoveryClosed else { return }
        cancelRecoveryTimers()
        guard !automaticRecoveryPaused || !shouldKeepRecoveryCopy else {
            deferredRecoveryCapture = false
            return
        }
        guard preparingRecoveryGeneration == nil else {
            deferredRecoveryCapture = true
            return
        }
        let generation = recoveryGeneration
        preparingRecoveryGeneration = generation
        deferredRecoveryCapture = false
        let resume: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.preparingRecoveryGeneration == generation else { return }
            self.preparingRecoveryGeneration = nil
            if self.deferredRecoveryCapture { self.enqueueRecovery() }
        }
        let deliver: @MainActor @Sendable (Error?) -> Void = { [weak self] error in
            guard let self, !self.recoveryClosed, self.recoveryGeneration == generation else { return }
            self.reportRecovery(error)
        }
        recoveryWriter.submitPrepared(
            recoveryPreparation(), didPrepare: { DispatchQueue.main.async { resume() } },
            completion: { error in DispatchQueue.main.async { deliver(error) } })
    }
    func flushRecovery() {
        guard !recoveryClosed else { return }
        cancelRecoveryTimers()
        recoveryGeneration += 1
        preparingRecoveryGeneration = nil
        deferredRecoveryCapture = false
        if automaticRecoveryPaused && shouldKeepRecoveryCopy {
            recoveryWriter.waitForPendingWrites()
            showSaveState(recoveryCopyKept: false)
            return
        }
        do {
            try recoveryWriter.finishPrepared {
                let prepare = recoveryPreparation()
                return try prepare()
            }
            reportRecovery(nil)
        } catch { reportRecovery(error) }
    }
    override func close() {
        guard !isClosed else { return }
        presentation?.host.tabCommands.willClose(self)
        isClosed = true
        bulkReceipt = nil
        externalFile.invalidate()
        EditorServices.current?.macros?.editorWillReset(editor, reason: "The recording document was closed.")
        cancelRecoveryTimers()
        recoveryGeneration += 1
        recoveryClosed = true
        preparingRecoveryGeneration = nil
        deferredRecoveryCapture = false
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
        for p in presentations { p.host.unregister(p, document: self) }
        super.close()
        for controller in windowControllers { removeWindowController(controller) }
        NSDocumentController.shared.removeDocument(self)
        NotificationCenter.default.post(name: .textTankDocumentsDidChange, object: self)
    }
    override class var autosavesInPlace: Bool { false }
    override func makeWindowControllers() {
        guard !isClosed, presentation == nil else { return }
        opened = true
        let adapter = EditorWindowController(document: self)
        addWindowController(adapter)
        adapter.host.register(adapter, document: self)
        externalFile.setApplicationActive(NSApp.isActive)
        NotificationCenter.default.post(name: .textTankDocumentsDidChange, object: self)
    }
    override func read(from url: URL, ofType typeName: String) throws {
        precondition(Thread.isMainThread)
        try MainActor.assumeIsolated { try readURLOnMain(from: url, ofType: typeName) }
    }
    private func readURLOnMain(from url: URL, ofType typeName: String) throws {
        readingURL = url
        defer { readingURL = nil }
        // AppKit reads the file itself. Settled metadata that is the same on both sides of
        // that read belongs to the bytes it read; anything else leaves the next check to hash.
        let now = WorkspaceStore.currentSecond()
        let before = try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max)
        if let before, try readInitialUTF8IfEligible(from: url, signature: before, ofType: typeName) { return }
        // AppKit may autorelease the source data. Release that read's temporaries before
        // document registration and window construction need their own working storage.
        try autoreleasepool { try super.read(from: url, ofType: typeName) }
        if let before, before.isSettled(at: now),
            (try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max)) == before
        {
            diskSignature = before
        }
    }
    /// Only a first open of a regular, large UTF-8 file uses a staged native document. Other
    /// formats and all existing editing sessions retain their exact ordinary read/reload paths.
    func readInitialUTF8IfEligible(from url: URL, signature: FileSignature, ofType type: String,
                                   isCancelled: () -> Bool = { false }) throws -> Bool {
        guard signature.size >= SizePolicy.standard.streamedImportThreshold, signature.size <= Int32.max,
              let contentType = UTType(type),
              contentType.conforms(to: .plainText) || contentType == .json || contentType == .xml,
              openEncoding == nil || openEncoding == .utf8,
              !opened, !languageResolved, presentations.isEmpty, editor.byteLength == 0, editor.revision == 0,
              !editor.readOnly else { return false }
        let stream = InitialFileStream(capacity: UInt(signature.size), detectsEncoding: openEncoding == nil)
        do {
            let sample = try WorkspaceStore.readChunks(of: url, maximumBytes: Int.max, matching: signature,
                                                       isCancelled: isCancelled) { bytes in
                try autoreleasepool { try stream.consume(Data(bytes)) }
            }
            try stream.finish()
            if isCancelled() { throw CancellationError() }
            guard !opened, !languageResolved, presentations.isEmpty, editor.revision == 0, editor.byteLength == 0,
                  !editor.readOnly else { throw CocoaError(.userCancelled) }
            guard let loader = stream.loader else { throw CocoaError(.fileReadUnknown) }
            try applyFile(.stream(loader, stream.lineEnding ?? .lf, stream.languageSample),
                          format: .init(encoding: .utf8, bom: stream.bom), baseline: sample, explicitEncoding: openEncoding)
            return true
        } catch InitialFileStream.OrdinaryRead.required {
            return false
        }
    }

    private final class InitialFileStream {
        enum OrdinaryRead: Error { case required }
        private(set) var loader: TTInitialUTF8Load?
        let capacity: UInt
        let detectsEncoding: Bool
        private var pending = Data()
        private var started = false
        private var pendingCR = false
        private var sampleComplete = false
        private(set) var bom = false
        private(set) var lineEnding: LineEnding?
        private(set) var languageSample = ""
        init(capacity: UInt, detectsEncoding: Bool) {
            self.capacity = capacity
            self.detectsEncoding = detectsEncoding
        }
        func consume(_ chunk: Data) throws {
            pending.append(chunk)
            if !started {
                guard pending.count >= 4 else { return }
                if detectsEncoding, (try? FileCodec.detectedEncoding(pending)) != .utf8 { throw OrdinaryRead.required }
                bom = pending.starts(with: [0xEF, 0xBB, 0xBF])
                if bom { pending.removeFirst(3) }
                loader = TTInitialUTF8Load(byteCount: capacity - (bom ? 3 : 0))
                guard loader != nil else { throw CocoaError(.fileReadUnknown) }
                started = true
            }
            // Retain at most three trailing bytes so independent native validations never split a scalar.
            var end = pending.endIndex - min(3, pending.count)
            while end < pending.endIndex && pending[end] & 0xC0 == 0x80 { end += 1 }
            try append(pending[..<end])
            pending = Data(pending[end...])
        }
        func finish() throws {
            try append(pending)
            if pendingCR { lineEnding = .cr }
        }
        private func append(_ data: Data) throws {
            guard !data.isEmpty else { return }
            guard let checked = TTDocumentUTF8(data: data) else { throw FileCodecError.invalidBytes(.utf8) }
            guard loader?.appendContent(checked) == true else { throw CocoaError(.fileReadUnknown) }
            if lineEnding == nil {
                if pendingCR {
                    lineEnding = data.first == 10 ? .crlf : .cr
                    pendingCR = false
                } else if let i = data.withUnsafeBytes({ bytes -> Int? in
                    guard let base = bytes.baseAddress else { return nil }
                    let lf = memchr(base, 10, bytes.count).map { base.distance(to: $0) }
                    let cr = memchr(base, 13, lf ?? bytes.count).map { base.distance(to: $0) }
                    return (cr ?? lf).map { data.startIndex + $0 }
                }) {
                    let next = data.index(after: i)
                    if data[i] == 10 { lineEnding = .lf }
                    else if next == data.endIndex { pendingCR = true }
                    else { lineEnding = data[next] == 10 ? .crlf : .cr }
                }
            }
            guard !sampleComplete else { return }
            if languageSample.isEmpty && data.first != 35 {
                sampleComplete = true
                return
            }
            languageSample.append(String(decoding: data, as: UTF8.self))
            if languageSample != "#" && !languageSample.hasPrefix("#!") {
                languageSample = ""
                sampleComplete = true
                return
            }
            if languageSample.contains(where: \.isNewline) || languageSample.count > 513 {
                languageSample = String(languageSample.prefix(513))
                sampleComplete = true
            } else if languageSample.utf8.count > 131072 {
                // Extremely long grapheme clusters retain ordinary shebang recognition semantics.
                throw OrdinaryRead.required
            }
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
        precondition(Thread.isMainThread)
        try MainActor.assumeIsolated { try readDataOnMain(from: data, ofType: typeName) }
    }
    private func readDataOnMain(from data: Data, ofType typeName: String) throws {
        do {
            try loadFile(data, as: openEncoding,
                         sample: capturedSample ?? FileSample(digest: WorkspaceStore.fingerprint(data), signature: nil),
                         explicitEncoding: openEncoding)
        } catch FileCodecError.unsupportedUTF32 {
            // A UTF-16 LE file with a leading NUL shares this marker. Keep the explicit recovery offer.
            guard openEncoding == nil, let readingURL, data.starts(with: [0xFF, 0xFE, 0, 0]) else {
                throw FileCodecError.unsupportedUTF32
            }
            throw ExplicitEncodingOpener(url: readingURL, typeName: typeName, encoding: .utf16LE).error()
        }
    }
    /// The same strict decode with an encoding the person chose, for callers that already hold
    /// the bytes. A failure throws the codec's error and loads nothing.
    func read(from data: Data, ofType typeName: String, as encoding: FileEncoding) throws {
        let previous = openEncoding
        openEncoding = encoding
        defer { openEncoding = previous }
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
        // Resolve an initial alias once, as fileURL does, then refuse replacement links.
        // Explicit encoding retains the existing addressable-data capacity; browser opens keep their own cap.
        let read = try WorkspaceStore.captureRegularFile(canonicalDiskURL(url), maximumBytes: Int.max)
        return try DocumentFactory.openCaptured(read, from: url, as: encoding, ofType: typeName, display: display)
    }
    /// NSDocument's revert discards the edits but schedules no recovery work, because loading
    /// suppresses change handling. Remove the discarded draft's snapshot now. If the revert
    /// throws, the buffer is still dirty and its snapshot must survive.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        let previous = openEncoding
        openEncoding = revertEncoding
        defer { openEncoding = previous }
        try super.revert(toContentsOf: url, ofType: typeName)
        flushRecovery()
    }
    /// Loads recovered or session text as a new unsaved document. Undo cannot cross this
    /// boundary (as for open and revert), and the document stays edited until a real save:
    /// the engine's save point is this text, which is not a disk state.
    func loadUnsavedSnapshot(text: String, format snapshotFormat: FileFormat) {
        bulkReceipt = nil
        loadEpoch &+= 1
        loading = true
        format = snapshotFormat
        // A new document: writable and empty, so the load cannot be refused.
        _ = editor.loadDocumentText(text)
        editor.setLineEndingMode(LineEnding.detect(in: text).nativeMode)
        editor.resetUndoHistory()
        savepointMatchesDisk = false
        loading = false
        updateChangeCount(.changeDone)
    }
    /// Opens one recovery snapshot as a new unsaved document that keeps the snapshot's identity.
    @discardableResult static func openRecovered(_ snapshot: RecoverySnapshot, originalGroup: String? = nil) throws
        -> TextDocument
    {
        let (base, overflow) = snapshot.revision.addingReportingOverflow(1)
        guard !overflow else { throw RecoveryError.invalidSnapshot }
        let doc = DocumentFactory.makeUntitled(
            display: false, focus: false,
            prepare: { document in
                document.recoveryID = snapshot.id
                document.recoveryBase = base
            },
            populate: { document in
                document.loadUnsavedSnapshot(text: snapshot.text, format: snapshot.format)
                // Display only: recovery never opens or writes the original path.
                document.recoveredOrigin =
                    SnapshotLabel.status(for: snapshot)
                    + (originalGroup.map { " · Original open in " + $0 } ?? "")
                document.recoveredOriginalURL = SnapshotLabel.origin(of: snapshot)?.absoluteString
                if let name = SnapshotLabel.originName(of: snapshot) { document.displayName = "Recovered " + name }
            })
        doc.showWindows()
        doc.flushRecovery()
        return doc
    }
    private enum FileContent {
        case utf8(TTDocumentUTF8)
        case text(String)
        case stream(TTInitialUTF8Load, LineEnding, String)

        var lineEnding: LineEnding {
            switch self {
            case .stream(_, let eol, _): return eol
            case .text(let text): return .detect(in: text)
            case .utf8(let content): return content.data.withUnsafeBytes { LineEnding.detect(inUTF8: $0) }
            }
        }

        // Language detection consults at most the first 512 Characters and only for a shebang.
        var languageSample: String {
            switch self {
            case .stream(_, _, let sample): return sample
            case .text(let text): return text
            case .utf8(let content):
                let data = content.data
                guard data.starts(with: [35, 33]) else { return "" }
                var length = min(2048, data.count)
                while true {
                    let prefix = String(decoding: data.prefix(length), as: UTF8.self)
                    if length == data.count || prefix.contains(where: \.isNewline) || prefix.count > 513 {
                        return prefix
                    }
                    length += min(length, data.count - length)
                }
            }
        }
    }

    private func loadFile(_ source: Data, as selected: FileEncoding?, sample: @autoclosure () -> FileSample,
                          explicitEncoding: FileEncoding?) throws {
        let encoding = try selected ?? FileCodec.detectedEncoding(source)
        let content: FileContent, diskFormat: FileFormat
        if encoding == .utf8 {
            let bom = source.starts(with: [0xEF, 0xBB, 0xBF])
            guard let checked = TTDocumentUTF8(data: source.dropFirst(bom ? 3 : 0)) else {
                throw FileCodecError.invalidBytes(.utf8)
            }
            content = .utf8(checked)
            diskFormat = .init(encoding: .utf8, bom: bom)
        } else {
            let decoded = try FileCodec.decode(source, encoding: encoding)
            content = .text(decoded.text)
            diskFormat = decoded.format
        }
        try applyFile(content, format: diskFormat, baseline: sample(), explicitEncoding: explicitEncoding)
    }
    private func applyFile(_ content: FileContent, format diskFormat: FileFormat, baseline: FileSample,
                           explicitEncoding: FileEncoding?) throws {
        loading = true
        let locked = editor.readOnly
        if case let .stream(staged, _, _) = content {
            guard editor.adoptInitialUTF8Load(staged) else {
                loading = false
                throw CocoaError(.userCancelled)
            }
        }
        bulkReceipt = nil
        loadEpoch &+= 1
        EditorServices.current?.macros?.editorWillReset(editor, reason: "The recording document was reloaded.")
        editor.readOnly = false
        // Reload the existing document with a minimal-span edit so unaffected bookmarks, folds
        // and the caret survive. A streamed first open has already adopted its finished buffer.
        switch content {
        case .stream: break
        case .utf8(let bytes): _ = editor.loadDocumentUTF8(bytes)
        case .text(let text): _ = editor.loadDocumentText(text)
        }
        editor.setLineEndingMode(content.lineEnding.nativeMode)
        editor.resetUndoHistory()
        format = diskFormat
        savedFormat = format
        revertEncoding = explicitEncoding
        diskDigest = baseline.digest
        diskSignature = baseline.signature
        externalFile.invalidate()
        savepointMatchesDisk = true
        editor.setSavePoint()
        editor.readOnly = locked
        loading = false
        guard !languageResolved else { return }
        languageResolved = true
        let languages = EditorServices.current?.languages
        let detected = languages?.detect(filename: fileURL?.lastPathComponent ?? "", text: content.languageSample)
        if editor.byteLength >= SizePolicy.standard.largeDocumentThreshold
            || editor.hasLineLongerThan(UInt(SizePolicy.standard.largeLineThreshold)) {
            // A newly opened editor has no installed lexer. Keep the detected choice for the opt-in action.
            deferredLargeFileLanguage = detected ?? LanguageProfile.plainTextID
            editor.wrap = false
        } else if let detected {
            _ = applyLanguage(detected, using: languages)
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
        guard !CompareCommandScope.blocksWorkspace else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedCopyName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeCopy(to: url) { [weak self] error in if let error { self?.presentError(error) } }
    }
    @objc func convertEncoding(_ sender: NSMenuItem) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        guard let code = sender.representedObject as? String else { return }
        do { try convertEncoding(to: code) } catch { presentError(error) }
    }
    /// A read-only document keeps its format, as the status-bar menu already promises.
    func convertEncoding(to code: String) throws {
        try editor.requireWritable()
        guard let target = FileFormat.convertTargets.first(where: { $0.code == code })?.format else {
            throw FileCodecError.invalidConversionTarget
        }
        _ = try FileCodec.encode(Self.capturedText(from: editor.checkedUTF8Data), format: target)
        format = target
        flushRecovery()
        windowControllers.compactMap { $0 as? EditorWindowController }.forEach { $0.refreshStatusDetails() }
    }
    /// Printing lays the whole document out on the main thread before the print panel appears.
    /// At and above this many UTF-8 bytes the person is told so first and can cancel.
    static var largePrintBytes = SizePolicy.standard.printConfirmation
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
        revealForNativeAction()
        guard shouldBeginPrinting() else { return }
        super.printDocument(sender)
    }
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation
    {
        let text = try Self.capturedText(from: editor.checkedUTF8Data)
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
        printable.string = text
        if let container = printable.textContainer, let layout = printable.layoutManager {
            layout.ensureLayout(for: container)
            printable.setFrameSize(NSSize(width: width, height: max(1, ceil(layout.usedRect(for: container).height))))
        }
        let operation = NSPrintOperation(view: printable, printInfo: settings)
        operation.jobTitle = displayName
        return operation
    }
    override func data(ofType typeName: String) throws -> Data {
        precondition(Thread.isMainThread)
        return try MainActor.assumeIsolated { try dataOnMain(ofType: typeName) }
    }
    private func dataOnMain(ofType typeName: String) throws -> Data {
        dependencies.duringWrite?()
        if let savePayload { return savePayload }
        return try FileCodec.encode(Self.capturedText(from: editor.checkedUTF8Data), format: format)
    }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType)
        throws
    {
        precondition(Thread.isMainThread)
        try MainActor.assumeIsolated { try writeSafelyOnMain(to: url, ofType: typeName, for: saveOperation) }
    }
    private func writeSafelyOnMain(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) throws {
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
            throw saveConflict(at: destination)
        }
        let submitted = try FileCodec.encode(Self.capturedText(from: editor.checkedUTF8Data), format: format),
            submittedFormat = format,
            submittedRevision = editor.revision
        savePayload = submitted
        defer { savePayload = nil }
        do {
            inPlaceWriteURL = inPlace && Thread.isMainThread ? destination : nil
            defer { inPlaceWriteURL = nil }
            try super.writeSafely(to: destination, ofType: typeName, for: saveOperation)
        }
        try dependencies.afterWrite?()
        if saveOperation != .saveToOperation {
            // The baseline is what was submitted. The file's metadata is not recorded here:
            // another writer may already have replaced it, and only a hash can tell.
            diskDigest = WorkspaceStore.fingerprint(submitted)
            diskSignature = nil
            externalFile.invalidate()
            // A successful conversion changes the baseline Revert will read from disk.
            if revertEncoding != nil || submittedFormat.encoding != savedFormat.encoding {
                revertEncoding = submittedFormat.encoding
            }
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

/// Only the canonical URL snapshot crosses NSDocument's file-presenter boundary. The complete
/// mutable state is lock-protected; super/AppKit/editor access and callbacks never run under it.
private final class DocumentDiskLocation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    func get() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set(_ next: URL?) {
        lock.lock()
        let displaced = value
        value = next
        lock.unlock()
        withExtendedLifetime(displaced) {}
    }
}

/// Snapshot failure is distinct from successfully capturing an empty editor.
enum EditorCaptureError: LocalizedError, Equatable {
    case incomplete, invalidUTF8
    var errorDescription: String? {
        switch self {
        case .incomplete: return "TextTank could not read the entire editor buffer."
        case .invalidUTF8: return "The editor buffer contains invalid UTF-8 text."
        }
    }
}

/// A native sheet can outlive the document state it described. Only a fresh, explicit
/// decision may compare those inputs; it never resumes a failed save or closes a document.
@MainActor private final class SavedVersionDecision: NSObject {
    let id = UUID()
    private weak var document: TextDocument?
    private let url: URL
    private let epoch: UInt
    private let revision: UInt
    private let format: FileFormat
    private let baseline: String?
    private let identity: FileSignature?
    private var handled = false
    init(_ document: TextDocument, at url: URL, observed: FileSignature? = nil) {
        self.document = document
        self.url = url
        epoch = document.loadEpoch
        revision = document.editor.revision
        format = document.format
        baseline = document.originalDiskFingerprint
        identity =
            observed
            ?? (try? WorkspaceStore.signature(
                ofRegularFileAt: url, maximumBytes: ReviewDiffPolicy.default.maximumInputBytes))
    }
    var sameEditorState: Bool {
        guard let document else { return false }
        return document.isOpen && document.diskURL == url && document.loadEpoch == epoch
            && document.editor.revision == revision && document.format == format
    }
    var isCurrent: Bool { sameEditorState && document?.originalDiskFingerprint == baseline }
    var diskStillMatches: Bool {
        guard let identity else { return false }
        return (try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int(clamping: identity.size)))
            == identity
    }
    var allowsComparison: Bool {
        guard identity != nil, isCurrent, let document, document.presentation?.host.tabCommands.isBusy != true
        else { return false }
        return EditorServices.current?.compare?.canCompareSaved(document) == true
    }
    func compareAfterDismissal() {
        guard !handled else { return }
        handled = true
        DispatchQueue.main.async { [self] in
            guard allowsComparison, let document, let identity else { return }
            EditorServices.current?.compare?.compareSaved(document, expecting: identity)
        }
    }
    override func attemptRecovery(fromError error: Error, optionIndex index: Int) -> Bool {
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated {
            if index == 1 { compareAfterDismissal() } else { handled = true }
        }
        return false
    }
    override func attemptRecovery(
        fromError error: Error, optionIndex index: Int, delegate: Any?, didRecoverSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let recovered = attemptRecovery(fromError: error, optionIndex: index)
        ErrorRecoveryReply.send(recovered, to: delegate, selector: didRecoverSelector, contextInfo: contextInfo)
    }
}
