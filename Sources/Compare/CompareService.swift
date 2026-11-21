// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import EditorBridge

@MainActor protocol CompareWindowScope: AnyObject {}
@MainActor enum CompareCommandScope {
    static var blocksWorkspace: Bool {
        var window = NSApp?.keyWindow
        while let candidate = window {
            if candidate.windowController is any CompareWindowScope { return true }
            window = candidate.sheetParent
        }
        return false
    }
}
@MainActor final class CompareDocumentInput {
    let capture: ReviewDocumentCapture
    weak var origin: TTEditor?
    let selection: Range<Int>?
    let wasEdited: Bool
    let insertionMode: TTLineEndingMode
    let wasReadOnly: Bool
    init(_ editor: TTEditor, selection: Bool = false) throws {
        capture = try ReviewSnapshotCapture.document(editor)
        origin = editor
        insertionMode = editor.statusInfo.eol
        wasReadOnly = editor.readOnly
        let (doc, _) = try capture.resolve()
        wasEdited = doc.isDocumentEdited || editor.modified || doc.format != doc.savedFormat
        if selection {
            guard !editor.selectionIsRectangular, let values = capture.snapshot.document?.selections,
                values.count == 1, let first = values.first, first.anchorByte != first.caretByte
            else { throw CompareOpenFailure.selection }
            self.selection = min(first.anchorByte, first.caretByte)..<max(first.anchorByte, first.caretByte)
        } else {
            self.selection = nil
        }
    }
    /// Known post-application extent; unlike the public picker this may be empty.
    init(capture: ReviewDocumentCapture, origin: TTEditor?, range: Range<Int>?) throws {
        self.capture = capture
        self.origin = origin
        selection = range
        let (doc, editor) = try capture.resolve()
        if let range {
            guard range.lowerBound >= 0, range.upperBound <= capture.snapshot.bytes.count,
                let origin, EditorLifetime.document(for: origin) === doc
            else { throw CompareOpenFailure.originClosed }
        }
        insertionMode = editor.statusInfo.eol
        wasReadOnly = editor.readOnly
        wasEdited = doc.isDocumentEdited || editor.modified || doc.format != doc.savedFormat
    }
    func validateMetadata() throws {
        try capture.validateCurrent()
        let (doc, editor) = try capture.resolve()
        guard doc.format == capture.snapshot.format, editor.statusInfo.eol == insertionMode,
            editor.readOnly == wasReadOnly
        else { throw ReviewRejection.bytesChanged }
    }
    var canRefresh: Bool {
        guard let (doc, _) = try? capture.resolve() else { return false }
        if selection != nil { return origin.map { EditorLifetime.document(for: $0) === doc } == true }
        return true
    }
    func refreshInput() throws -> CompareInput {
        let (doc, editor) = try capture.resolve()
        if selection != nil {
            guard let origin, EditorLifetime.document(for: origin) === doc else {
                throw CompareOpenFailure.originClosed
            }
            return .document(try CompareDocumentInput(origin, selection: true))
        }
        return .document(try CompareDocumentInput(editor))
    }
}
/// The disk side of Tab and Saved File remains bound to that exact document's pinned
/// saved location. A Save As or save-state change invalidates it without reading disk.
@MainActor final class CompareSavedFileInput {
    let parent: CompareDocumentInput
    let url: URL, encoding: FileEncoding
    let overrideEncoding: FileEncoding?
    let expectedIdentity: FileSignature?
    private let edited: Bool
    private let savedFormat: FileFormat
    private let savedFingerprint: String?
    init(_ parent: CompareDocumentInput, encoding: FileEncoding? = nil, expecting identity: FileSignature? = nil) throws
    {
        let (doc, editor) = try parent.capture.resolve()
        guard let url = doc.diskURL ?? doc.fileURL else { throw ReviewRejection.closed }
        self.parent = parent
        expectedIdentity = identity
        self.url = url
        self.overrideEncoding = encoding
        self.encoding = encoding ?? doc.savedFormat.encoding
        self.savedFormat = doc.savedFormat
        self.savedFingerprint = doc.originalDiskFingerprint
        edited = doc.isDocumentEdited || editor.modified || doc.format != doc.savedFormat
    }
    func validate() throws {
        try parent.validateMetadata()
        let (doc, editor) = try parent.capture.resolve()
        guard (doc.diskURL ?? doc.fileURL) == url, doc.savedFormat == savedFormat,
            doc.originalDiskFingerprint == savedFingerprint,
            (doc.isDocumentEdited || editor.modified || doc.format != doc.savedFormat) == edited
        else {
            throw ReviewRejection.bytesChanged
        }
    }
    func reboundAfterKnownApply(_ fresh: CompareDocumentInput) throws -> CompareSavedFileInput {
        let (doc, editor) = try fresh.capture.resolve()
        guard parent.capture.snapshot.document?.documentID == fresh.capture.snapshot.document?.documentID,
            parent.capture.snapshot.document?.loadEpoch == fresh.capture.snapshot.document?.loadEpoch,
            (doc.diskURL ?? doc.fileURL) == url, doc.savedFormat == savedFormat,
            doc.originalDiskFingerprint == savedFingerprint
        else { throw ReviewRejection.bytesChanged }
        let whole = try CompareDocumentInput(capture: fresh.capture, origin: editor, range: nil)
        return try CompareSavedFileInput(whole, encoding: overrideEncoding)
    }
    func refreshInput() throws -> CompareInput {
        let (_, editor) = try parent.capture.resolve()
        return .savedFile(try CompareSavedFileInput(CompareDocumentInput(editor), encoding: overrideEncoding))
    }
}
@MainActor enum CompareInput {
    case snapshot(TextSnapshot)
    case automationResult(TextSnapshot)
    case document(CompareDocumentInput)
    case file(URL, encoding: FileEncoding? = nil)
    case savedFile(CompareSavedFileInput)
    case clipboard
    var boundDocument: DocumentID? {
        if case .document(let input) = self { return input.capture.snapshot.document?.documentID }
        return nil
    }
}
enum CompareOpenFailure: Error { case sameDocument, limit, selection, originClosed, clipboard }
@MainActor final class CompareSource {
    let snapshot: TextSnapshot
    let input: CompareInput
    let clipboardChange: Int?
    init(snapshot: TextSnapshot, input: CompareInput, clipboardChange: Int? = nil) {
        self.snapshot = snapshot
        self.input = input
        self.clipboardChange = clipboardChange
    }
    func validate() throws {
        if case .document(let source) = input { try source.validateMetadata() }
        if case .savedFile(let source) = input { try source.validate() }
    }
    var isStale: Bool {
        if case .savedFile(let source) = input { return (try? source.validate()) == nil }
        guard case .document(let source) = input else { return false }
        guard (try? source.validateMetadata()) != nil, let (doc, _) = try? source.capture.resolve() else {
            return true
        }
        return doc.format != source.capture.snapshot.format
    }
    var canRefresh: Bool {
        switch input {
        case .snapshot, .automationResult: return false
        case .document(let d): return d.canRefresh
        case .file, .clipboard: return true
        case .savedFile(let source): return (try? source.parent.capture.resolve()) != nil
        }
    }
    var canRetainForRefresh: Bool {
        if case .snapshot = input { return true }
        return canRefresh
    }
    var refreshReason: String? {
        switch input {
        case .document(let source) where !source.canRefresh:
            return source.selection == nil
                ? "The source document closed. Choose its source again."
                : "The selection's original view closed. Choose its source again."
        case .automationResult: return "Run the automation again to compare with a new document revision."
        case .snapshot: return "This is captured text without a live source."
        default: return nil
        }
    }
    func refreshInput() throws -> CompareInput {
        if case .automationResult = input { throw ReviewRejection.revisionChanged }
        if case .document(let source) = input { return try source.refreshInput() }
        if case .savedFile(let source) = input { return try source.refreshInput() }
        // Fixed value inputs remain fixed when the other live source is explicitly refreshed.
        return input
    }
    var displayName: String {
        if case .document(let source) = input, let (doc, _) = try? source.capture.resolve() {
            return doc.displayName + (source.selection == nil ? "" : " selection")
        }
        return snapshot.label
    }
    var label: String {
        var title = snapshot.label
        if case .document(let source) = input {
            if let (doc, editor) = try? source.capture.resolve() {
                title = doc.displayName + (source.selection == nil ? "" : " selection")
                if doc.isDocumentEdited || editor.modified || doc.format != doc.savedFormat { title += " · Edited" }
            } else if source.wasEdited {
                title += " · Edited when captured"
            }
            if let stamp = source.capture.snapshot.document { title += " · revision \(stamp.revision)" }
        } else {
            title += " · captured text"
        }
        if let f = snapshot.format {
            title += " · " + f.encoding.displayName + (f.bom ? " · byte-order mark" : " · no byte-order mark")
        }
        if snapshot.bytes.isEmpty {
            title += " · Empty text"
        } else if snapshot.bytes.last == 10 {
            title +=
                snapshot.bytes.count > 1 && snapshot.bytes[snapshot.bytes.count - 2] == 13
                ? " · Ends with CRLF" : " · Ends with LF"
        } else if snapshot.bytes.last == 13 {
            title += " · Ends with CR"
        } else {
            title += " · Missing final newline"
        }
        if isStale { title += " · Out of date" }
        return title
    }
}
@MainActor private final class CompareTabInvocation: NSObject {
    let mark: Bool
    let editor: () -> TTEditor?
    init(mark: Bool, editor: @escaping () -> TTEditor?) {
        self.mark = mark
        self.editor = editor
    }
}
@MainActor enum CompareSourceCommand: CaseIterable {
    case choose, mark, compare
    var title: String {
        switch self {
        case .choose: return "Compare Text…"
        case .mark: return "Select for Compare"
        case .compare: return "Compare with Selected"
        }
    }
    var action: Selector {
        switch self {
        case .choose: return #selector(CompareService.showPicker(_:))
        case .mark: return #selector(CompareService.markCurrent(_:))
        case .compare: return #selector(CompareService.compareCurrent(_:))
        }
    }
}
@MainActor final class CompareService: NSObject, NSMenuItemValidation {
    let engine: any ReviewDiffing
    private(set) var windows: [CompareController] = []
    private var admissions = 0
    private var active: UUID?
    var hasActivePipeline: Bool { active != nil }
    private var waiting: [CompareController] = []
    private struct AuxiliaryJob {
        let id: UUID
        let start: @MainActor (@escaping @MainActor () -> Void) -> Void
    }
    private var auxiliary: [AuxiliaryJob] = []
    private(set) var marked: CompareDocumentInput?
    private var picker: CompareSourcePicker?
    private var savedPickers: [DocumentID: CompareSourcePicker] = [:]
    var currentEditor: () -> TTEditor? = { nil }
    var visibleEditors: () -> (TTEditor, TTEditor)? = { nil }
    var prepareSelectedChange: ReviewChangePreparation?
    var allEditors: () -> [TTEditor] = {
        NSDocumentController.shared.documents.compactMap { ($0 as? TextDocument)?.activeEditor }
    }
    var readClipboard: () throws -> (Data, Int) = {
        guard let board = RuntimeEnvironment.current.generalPasteboard(), let text = board.string(forType: .string)
        else {
            throw CompareOpenFailure.clipboard
        }
        let bytes = Data(text.utf8)
        guard bytes.count <= 8 * 1024 * 1024 else { throw ReviewRejection.budgetExceeded }
        return (bytes, board.changeCount)
    }
    var fileSnapshot: @Sendable (URL, FileEncoding?) async throws -> TextSnapshot = { url, encoding in
        try await ReviewSnapshotCapture.file(url, as: encoding)
    }
    var showWindows = true
    init(engine: any ReviewDiffing = FirstPartyReviewDiff()) {
        self.engine = engine
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentsChanged(_:)), name: .textTankDocumentsDidChange, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func documentsChanged(_ note: Notification) {
        if let marked, (try? marked.capture.resolve()) == nil { self.marked = nil }
    }
    static func budgetMessage(_ reason: ReviewBudgetReason) -> String {
        switch reason {
        case .input: return "One source exceeds the text size limit."
        case .lines: return "One source has too many lines."
        case .work: return "The comparison work limit was reached."
        case .time: return "The comparison time limit was reached."
        case .workspace: return "The comparison exceeded its memory allowance."
        case .output: return "The comparison has too many changes or display rows."
        case .span, .tokens: return "A changed span is too large to display safely."
        case .invalidInput: return "The source could not be compared safely."
        case .mainThread: return "The comparison could not start in the background. Try again."
        case .notAttempted: return "Some comparison detail was not computed."
        }
    }
    private func report(_ error: Error) {
        let text = Self.message(error)
        if let host = EditorServices.current?.workspaceHost { host.showTabMessage(text) } else { Announce.say(text) }
    }
    static func message(_ error: Error) -> String {
        switch error {
        case is CancellationError: return "Comparison cancelled. No document was changed."
        case CompareOpenFailure.sameDocument:
            return "Choose two different documents. Two views of one document share the same text."
        case CompareOpenFailure.limit: return "Two comparisons are already open. Close one before starting another."
        case CompareOpenFailure.selection:
            return "Choose one nonempty text selection. Rectangular and multiple selections cannot be compared."
        case CompareOpenFailure.originClosed:
            return "The selection's original view has closed. Choose its source again to refresh."
        case CompareOpenFailure.clipboard:
            return "The clipboard has no available text. Copy text, then choose Compare again."
        case CompareFailure.cancelled, ReviewRejection.cancelled:
            return "Comparison cancelled. No document was changed."
        case CompareFailure.invalid:
            return "The selected range does not follow text boundaries. Choose a complete text selection and try again."
        case CompareFailure.budget(let reason): return budgetMessage(reason) + " No document was changed."
        case ReviewRejection.budgetExceeded: return "One source exceeds the 8 MiB text limit. No document was changed."
        case ReviewRejection.closed, ReviewRejection.revisionChanged, ReviewRejection.reloaded,
            ReviewRejection.bytesChanged:
            return "The source changed or closed. Choose it again or refresh explicitly."
        default:
            return "The comparison could not read this source. \(error.localizedDescription) No document was changed."
        }
    }
    func capture(_ input: CompareInput, token: ReviewCancellation) async throws -> CompareSource {
        try Task.checkCancellation()
        let snapshot: TextSnapshot, change: Int?
        switch input {
        case .snapshot(let value), .automationResult(let value):
            guard value.label.utf8.count <= 1024 else { throw CompareFailure.invalid }
            snapshot = try TextSnapshot(
                bytes: value.bytes, source: value.source, label: value.label, document: value.document,
                format: value.format, capturedFileIdentity: value.capturedFileIdentity)
            change = nil
        case .document(let doc):
            try doc.capture.validateCurrent()
            let original = doc.capture.snapshot
            if let range = doc.selection {
                snapshot = try await CompareSelection.slice(original, range: range, token: token)
            } else {
                snapshot = try TextSnapshot(
                    bytes: original.bytes, source: original.source, label: original.label, document: original.document,
                    format: original.format)
            }
            try doc.capture.validateCurrent()
            change = nil
        case .file(let url, let encoding):
            snapshot = try await fileSnapshot(url, encoding)
            change = nil
        case .savedFile(let file):
            try file.validate()
            snapshot = try await fileSnapshot(file.url, file.encoding)
            if let expected = file.expectedIdentity, snapshot.capturedFileIdentity != expected {
                throw ReviewRejection.bytesChanged
            }
            try file.validate()
            change = nil
        case .clipboard:
            let (bytes, count) = try readClipboard()
            snapshot = try ReviewSnapshotCapture.clipboard { bytes }
            change = count
        }
        try Task.checkCancellation()
        guard !token.isCancelled else { throw CompareFailure.cancelled }
        return CompareSource(snapshot: snapshot, input: input, clipboardChange: change)
    }
    func capturePair(_ original: CompareInput, _ modified: CompareInput, token: ReviewCancellation) async throws -> (
        CompareSource, CompareSource
    ) {
        if let a = original.boundDocument, a == modified.boundDocument { throw CompareOpenFailure.sameDocument }
        let a = try await capture(original, token: token), b = try await capture(modified, token: token)
        try a.validate()
        try b.validate()
        return (a, b)
    }
    /// The sole comparison-opening entry. Caller document inputs are already captured before awaits.
    func open(original: CompareInput, modified: CompareInput, destination: CompareSide? = nil) async throws -> CompareController {
        guard windows.count + admissions < 2 else { throw CompareOpenFailure.limit }
        admissions += 1
        defer { admissions -= 1 }
        let cancellation = ReviewCancellation()
        let pair = try await withTaskCancellationHandler {
            try await capturePair(original, modified, token: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        let controller = CompareController(service: self, original: pair.0, modified: pair.1, destination: destination)
        windows.append(controller)
        if showWindows {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
        }
        enqueue(controller)
        return controller
    }
    func enqueue(_ controller: CompareController) {
        waiting.removeAll { $0 === controller }
        waiting.append(controller)
        controller.showQueued()
        pump()
    }
    private func pump() {
        guard active == nil else { return }
        waiting.removeAll { $0.isClosed }
        guard !waiting.isEmpty else {
            guard !auxiliary.isEmpty else { return }
            let job = auxiliary.removeFirst()
            active = job.id
            job.start { [weak self] in
                guard let self, self.active == job.id else { return }
                self.active = nil
                self.pump()
            }
            return
        }
        let controller = waiting.removeFirst(), job = UUID()
        active = job
        controller.run(job: job, engine: engine) { [weak self] in
            guard let self, self.active == job else { return }
            self.active = nil
            self.pump()
        }
    }
    func enqueueAuxiliary(_ id: UUID, start: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void) {
        auxiliary.append(.init(id: id, start: start))
        pump()
    }
    func cancelAuxiliary(_ id: UUID) { auxiliary.removeAll { $0.id == id } }
    func cancelQueued(_ controller: CompareController) { waiting.removeAll { $0 === controller } }
    func closed(_ controller: CompareController) {
        waiting.removeAll { $0 === controller }
        windows.removeAll { $0 === controller }
    }
    func mark(_ editor: TTEditor) throws {
        marked = try CompareDocumentInput(editor)
        EditorServices.current?.workspaceHost?.tabStrips.forEach { $0.refresh() }
        Announce.say("\(marked!.capture.snapshot.label) selected for comparison.")
    }
    func isMarked(_ document: DocumentID) -> Bool {
        guard let marked else { return false }
        if (try? marked.capture.resolve()) == nil {
            self.marked = nil
            return false
        }
        return marked.capture.snapshot.document?.documentID == document
    }
    func canCompare(_ editor: TTEditor?) -> (Bool, String?) {
        guard let marked else { return (false, "Select another tab for comparison first.") }
        guard (try? marked.capture.validateCurrent()) != nil else {
            return (false, "The selected source changed or closed. Select it again for comparison.")
        }
        guard let editor, let doc = EditorLifetime.document(for: editor), doc.isOpen else {
            return (false, "There is no open document to compare.")
        }
        guard editor.byteLength <= 8 * 1024 * 1024 else {
            return (false, "This text exceeds the 8 MiB comparison limit.")
        }
        guard marked.capture.snapshot.document?.documentID != doc.runtimeID else {
            return (false, "Choose a different document; clone views share the same text.")
        }
        return (
            windows.count + admissions < 2,
            windows.count + admissions >= 2 ? "Close a comparison before starting another." : nil
        )
    }
    @objc func showPicker(_ sender: Any?) {
        if let picker {
            picker.showWindow(nil)
            picker.window?.makeKeyAndOrderFront(nil)
            return
        }
        let value = CompareSourcePicker(service: self, preferred: currentEditor())
        picker = value
        value.onClose = { [weak self] in self?.picker = nil }
        value.showWindow(nil)
        value.window?.makeKeyAndOrderFront(nil)
    }
    func cancelPendingSavedComparisons() {
        Array(savedPickers.values).forEach { $0.window?.close() }
    }
    func hasSavedSource(_ document: TextDocument) -> Bool {
        EditorServices.current?.reviewingTermination() != true && document.isOpen && document.diskURL != nil
            && document.editor.byteLength <= ReviewDiffPolicy.default.maximumInputBytes
    }
    func canCompareSaved(_ document: TextDocument) -> Bool {
        hasSavedSource(document) && (savedPickers[document.runtimeID] != nil || windows.count + admissions < 2)
    }
    func compareSaved(_ document: TextDocument, expecting identity: FileSignature? = nil) {
        guard hasSavedSource(document) else { return }
        guard canCompareSaved(document) else {
            report(CompareOpenFailure.limit)
            return
        }
        let id = document.runtimeID
        if let pending = savedPickers[id] {
            if identity == nil {
                pending.showWindow(nil)
                pending.window?.makeKeyAndOrderFront(nil)
                return
            }
            // A new notice click is bound to its own observed inode.
            pending.window?.close()
        }
        let value = CompareSourcePicker(service: self, preferred: document.activeEditor)
        savedPickers[id] = value
        value.onClose = { [weak self] in self?.savedPickers.removeValue(forKey: id) }
        value.showWindow(nil)
        value.window?.makeKeyAndOrderFront(nil)
        value.beginWithSavedVersion(expecting: identity)
    }

    @objc func markCurrent(_ sender: Any?) {
        guard let editor = currentEditor() else { return }
        do { try mark(editor) } catch { report(error) }
    }
    private func visiblePair() -> (TTEditor, TTEditor)? {
        guard !CompareCommandScope.blocksWorkspace, windows.count + admissions < 2,
            let (first, second) = visibleEditors(),
            let left = EditorLifetime.document(for: first), let right = EditorLifetime.document(for: second),
            left.isOpen, right.isOpen, left !== right,
            first.byteLength <= 8 * 1024 * 1024, second.byteLength <= 8 * 1024 * 1024
        else { return nil }
        return (first, second)
    }
    @objc func compareVisibleTabs(_ sender: Any?) {
        guard let (first, second) = visiblePair() else { return }
        do {
            let original = try CompareDocumentInput(first), modified = try CompareDocumentInput(second)
            Task { [weak self] in
                guard let self else { return }
                do { _ = try await open(original: .document(original), modified: .document(modified)) }
                catch { report(error) }
            }
        } catch { report(error) }
    }
    @objc func compareCurrent(_ sender: Any?) {
        guard let editor = currentEditor() else { return }
        compare(editor)
    }
    func compare(_ editor: TTEditor) {
        guard canCompare(editor).0, let marked else { return }
        do {
            let target = try CompareDocumentInput(editor)
            Task { [weak self] in
                guard let self else { return }
                do { _ = try await self.open(original: .document(marked), modified: .document(target)) } catch {
                    report(error)
                }
            }
        } catch { report(error) }
    }
    func addMainItems(to menu: NSMenu) {
        for command in CompareSourceCommand.allCases {
            menu.addItem(title: command.title, action: command.action, target: self)
        }
    }
    func addTabItems(to menu: NSMenu, editor: @escaping () -> TTEditor?) {
        menu.addItem(.separator())
        for marking in [true, false] {
            let item = menu.addItem(
                title: marking ? CompareSourceCommand.mark.title : CompareSourceCommand.compare.title,
                action: #selector(invokeTab(_:)), target: self,
                representedObject: CompareTabInvocation(mark: marking, editor: editor))
            item.isEnabled = validateMenuItem(item)
        }
    }
    @objc private func invokeTab(_ item: NSMenuItem) {
        guard validateMenuItem(item), let call = item.representedObject as? CompareTabInvocation,
            let editor = call.editor()
        else { return }
        if call.mark { do { try mark(editor) } catch { report(error) } } else { compare(editor) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let call = item.representedObject as? CompareTabInvocation {
            if call.mark {
                return call.editor().map {
                    EditorLifetime.document(for: $0)?.isOpen == true && $0.byteLength <= 8 * 1024 * 1024
                } ?? false
            }
            let state = canCompare(call.editor())
            item.toolTip = state.1
            return state.0
        }

        switch item.action {
        case #selector(compareVisibleTabs(_:)): return visiblePair() != nil
        case #selector(showPicker(_:)): return windows.count + admissions < 2
        case #selector(markCurrent(_:)):
            let editor = currentEditor()
            item.toolTip =
                editor?.byteLength ?? 0 > 8 * 1024 * 1024 ? "This text exceeds the 8 MiB comparison limit." : nil
            return editor != nil && editor!.byteLength <= 8 * 1024 * 1024
        case #selector(compareCurrent(_:)):
            let state = canCompare(currentEditor())
            item.toolTip = state.1
            return state.0
        default: return CompareController.key?.validateMenuItem(item) ?? false
        }
    }
}
