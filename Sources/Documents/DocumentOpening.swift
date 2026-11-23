import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The explicit encoding choice offered when a file cannot be decoded automatically.
/// Detection stays strict and nothing is guessed: the person picks, the same strict codec
/// decodes, and a wrong pick fails with the codec's error instead of substituting bytes.
/// Only interactive opens ask. `TextDocument.read(from:ofType:)` and every caller that
/// opens without a person watching still get the error and never a modal.
enum EncodingChoice {
    static let titles: [(FileEncoding, String)] = FileEncoding.allCases.map { ($0, $0.displayName) }
    /// The decode failure inside `error`, if that is what it is. AppKit may hand back the
    /// thrown error wrapped, so the underlying errors are searched as well.
    static func codecError(in error: Error) -> FileCodecError? {
        var current: Error? = error
        for _ in 0..<8 {
            guard let candidate = current else { return nil }
            if let failure = candidate as? FileCodecError {
                switch failure {
                case .invalidBytes, .unsupportedUTF32: return failure
                case .unrepresentable, .unsupportedBOM, .invalidConversionTarget: return nil
                }
            }
            current = (candidate as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return nil
    }
    /// The encodings worth offering after `error`, with the one to preselect. The encoding
    /// that has just failed is left out.
    static func offered(after error: Error) -> (encodings: [FileEncoding], preferred: FileEncoding) {
        var failed: FileEncoding?
        var preferred = FileEncoding.windows1252
        switch codecError(in: error) {
        case .invalidBytes(let encoding): failed = encoding
        case .unsupportedUTF32: preferred = .utf16LE
        default: break
        }
        let encodings = titles.map(\.0).filter { $0 != failed }
        if failed == preferred { preferred = .latin1 }
        return (encodings, preferred)
    }
    @MainActor static func popUp(after error: Error) -> NSPopUpButton {
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        let offer = offered(after: error)
        for (encoding, title) in titles where offer.encodings.contains(encoding) {
            choice.addItem(withTitle: title)
            choice.lastItem?.representedObject = encoding.rawValue
        }
        choice.selectItem(at: offer.encodings.firstIndex(of: offer.preferred) ?? 0)
        choice.setAccessibilityLabel("Encoding to open the file with")
        choice.identifier = .init("open.encoding")
        return choice
    }
    @MainActor static func selection(of choice: NSPopUpButton) -> FileEncoding? {
        (choice.selectedItem?.representedObject as? String).flatMap(FileEncoding.init(rawValue:))
    }
    /// The chooser itself. Returns nil when the person cancels.
    @MainActor static func present(_ url: URL, _ failure: Error) -> FileEncoding? {
        let alert = TTAlert()
        alert.messageText = "Choose an encoding for “\(url.lastPathComponent)”"
        alert.informativeText =
            failure.localizedDescription
            + "\n\nThe file is read with the encoding you choose and is not changed on disk. If the text looks wrong, close it without saving and choose another encoding."
        let choice = popUp(after: failure)
        alert.accessoryView = choice
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return selection(of: choice)
    }
    /// Asks until an encoding decodes the file or the person cancels (nil). An error that is
    /// not a decode failure is thrown as it is, without asking.
    @MainActor static func retry(
        _ url: URL, after failure: Error, choose: (URL, Error) -> FileEncoding?,
        open: (FileEncoding) throws -> TextDocument
    ) throws -> TextDocument? {
        var failure = failure
        while codecError(in: failure) != nil {
            guard let encoding = choose(url, failure) else { return nil }
            do { return try open(encoding) } catch { failure = error }
        }
        throw failure
    }
}

/// The application's document controller. File > Open, Open Recent and Finder opens all go
/// through `openDocument(withContentsOf:display:completionHandler:)`; this adds the two things
/// the stock controller cannot do there. Create it before anything touches
/// `NSDocumentController.shared`.
final class TextDocumentController: NSDocumentController {
    var willReviewOpenDocuments: (() -> Void)?
    var didReviewOpenDocuments: ((Bool) -> Void)?
    var didRegisterDocument: (() -> Void)?
    private var nativeReviewDepth = 0
    var isReviewingOpenDocuments: Bool { nativeReviewDepth > 0 }

    /// AppKit can close the documents before it asks its application delegate about quitting.
    /// Its stock review may nest a close-all callback. Capture once around the outer operation.
    override func reviewUnsavedDocuments(
        withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
        didReviewAllSelector selector: Selector?, contextInfo: UnsafeMutableRawPointer?
    ) {
        guard tracksApplicationReview(delegate) else {
            super.reviewUnsavedDocuments(
                withAlertTitle: title, cancellable: cancellable, delegate: delegate,
                didReviewAllSelector: selector, contextInfo: contextInfo)
            return
        }
        let callback = beginNativeReview(delegate, selector: selector, info: contextInfo)
        super.reviewUnsavedDocuments(
            withAlertTitle: title, cancellable: cancellable, delegate: self,
            didReviewAllSelector: #selector(nativeReviewCompleted(_:accepted:contextInfo:)), contextInfo: callback)
    }
    override func closeAllDocuments(
        withDelegate delegate: Any?, didCloseAllSelector selector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard tracksApplicationReview(delegate) else {
            super.closeAllDocuments(withDelegate: delegate, didCloseAllSelector: selector, contextInfo: contextInfo)
            return
        }
        let callback = beginNativeReview(delegate, selector: selector, info: contextInfo)
        super.closeAllDocuments(
            withDelegate: self, didCloseAllSelector: #selector(nativeReviewCompleted(_:accepted:contextInfo:)),
            contextInfo: callback)
    }
    private func tracksApplicationReview(_ object: Any?) -> Bool {
        guard willReviewOpenDocuments != nil, let target = object as AnyObject? else { return false }
        return nativeReviewDepth > 0 || target === self || target === NSApp || target === NSApp.delegate
    }
    private final class NativeReviewCallback {
        let target: AnyObject?
        let selector: Selector?
        let info: UnsafeMutableRawPointer?
        init(_ target: Any?, _ selector: Selector?, _ info: UnsafeMutableRawPointer?) {
            self.target = target as AnyObject?
            self.selector = selector
            self.info = info
        }
        @MainActor func forward(_ controller: NSDocumentController, accepted: Bool) {
            guard let target, let selector, let cls = object_getClass(target),
                let implementation = class_getMethodImplementation(cls, selector)
            else { return }
            // NSDocumentController.h specifies the same BOOL/context signature for both callbacks.
            typealias Reply =
                @convention(c) (AnyObject, Selector, NSDocumentController, ObjCBool, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(implementation, to: Reply.self)(target, selector, controller, ObjCBool(accepted), info)
        }
    }
    private func beginNativeReview(_ target: Any?, selector: Selector?, info: UnsafeMutableRawPointer?)
        -> UnsafeMutableRawPointer
    {
        nativeReviewDepth += 1
        if nativeReviewDepth == 1 { willReviewOpenDocuments?() }
        return Unmanaged.passRetained(NativeReviewCallback(target, selector, info)).toOpaque()
    }
    @objc private func nativeReviewCompleted(
        _ controller: NSDocumentController, accepted: Bool, contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let contextInfo else { return }
        let callback = Unmanaged<NativeReviewCallback>.fromOpaque(contextInfo).takeRetainedValue()
        nativeReviewDepth -= 1
        if nativeReviewDepth == 0 { didReviewOpenDocuments?(accepted) }
        callback.forward(controller, accepted: accepted)
    }

    var recordsRecentDocuments = true
    override func noteNewRecentDocumentURL(_ url: URL) {
        if recordsRecentDocuments { super.noteNewRecentDocumentURL(url) }
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if CompareCommandScope.blocksWorkspace,
            [#selector(openDocument(_:)), #selector(newDocument(_:)), #selector(saveAllDocuments(_:))].contains(
                item.action)
        {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }
    override func openDocument(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        super.openDocument(sender)
    }
    override func newDocument(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        super.newDocument(sender)
    }
    override func saveAllDocuments(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        super.saveAllDocuments(sender)
    }
    override func addDocument(_ document: NSDocument) {
        super.addDocument(document)
        didRegisterDocument?()
        (document as? TextDocument)?.makeWindowControllers()
    }
    var chooseEncoding: @MainActor (URL, Error) -> FileEncoding? = EncodingChoice.present
    /// A session snapshot is restored through its own review prompt, never opened as editable JSON.
    var openSessionFile: (URL) -> Void = { url in EditorServices.current?.openSessionFile(url) }
    override func openDocument(
        withContentsOf url: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        if displayDocument, url.pathExtension.lowercased() == WorkspaceStore.sessionFileExtension {
            openSessionFile(url)
            // The snapshot was handled; there is no document and nothing to report.
            completionHandler(nil, false, CocoaError(.userCancelled))
            return
        }
        let delivery = OpenDelivery(self, url: url, display: displayDocument, completion: completionHandler)
        super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
            delivery.receive(document, alreadyOpen, error)
        }
    }
    /// The framework completion transports this actor-owned callback; it never weak-loads the
    /// UI controller on a worker. Alive owners retain the original main-direct/Dispatch.main
    /// ordering. Released owners also deliver on main so caller UI captures stay actor-owned.
    @MainActor final class OpenDelivery {
        private weak var controller: TextDocumentController?
        private let url: URL, display: Bool
        private let completion: (NSDocument?, Bool, Error?) -> Void
        init(
            _ controller: TextDocumentController?, url: URL, display: Bool,
            completion: @escaping (NSDocument?, Bool, Error?) -> Void
        ) {
            self.controller = controller
            self.url = url
            self.display = display
            self.completion = completion
        }
        nonisolated func receive(_ document: NSDocument?, _ alreadyOpen: Bool, _ error: Error?) {
            let finish: @MainActor @Sendable () -> Void = { self.finish(document, alreadyOpen, error) }
            if Thread.isMainThread {
                MainActor.assumeIsolated { finish() }
            } else {
                DispatchQueue.main.async(execute: finish)
            }
        }
        private func finish(_ document: NSDocument?, _ alreadyOpen: Bool, _ error: Error?) {
            guard let controller else {
                completion(document, alreadyOpen, error)
                return
            }
            controller.finishOpen(url, display: display, document, alreadyOpen, error, completionHandler: completion)
        }
    }
    /// What happens to the stock open's answer. Only a displayed open that failed to decode is
    /// answered with the chooser; everything else is passed on as it came. `presenting` false
    /// opens the chosen document without showing its window.
    func finishOpen(
        _ url: URL, display displayDocument: Bool, presenting: Bool = true, _ document: NSDocument?,
        _ alreadyOpen: Bool, _ error: Error?, completionHandler: (NSDocument?, Bool, Error?) -> Void
    ) {
        guard displayDocument, document == nil, let error, EncodingChoice.codecError(in: error) != nil else {
            completionHandler(document, alreadyOpen, error)
            return
        }
        do {
            if let opened = try openChoosingEncoding(url, after: error, display: presenting) {
                completionHandler(opened, false, nil)
            } else {
                completionHandler(nil, false, CocoaError(.userCancelled))
            }
        } catch { completionHandler(nil, false, error) }
    }
    /// The interactive answer to a decode failure on open. Cancel creates no document.
    func openChoosingEncoding(_ url: URL, after failure: Error, display: Bool = true) throws -> TextDocument? {
        try EncodingChoice.retry(url, after: failure, choose: chooseEncoding) { encoding in
            let type = (try? self.typeForContents(of: url)) ?? TextDocument.plainTextType
            let document = try TextDocument.open(url, as: encoding, ofType: type, display: display)
            self.noteNewRecentDocumentURL(url)
            return document
        }
    }
}

/// How a retained snapshot is described to the person: what it is a draft of and when it
/// was written. For display only; nothing here opens, reads or writes the original path.
enum SnapshotLabel {
    static func savedAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    static func origin(of snapshot: RecoverySnapshot) -> URL? {
        guard let text = snapshot.originalURL, let url = URL(string: text), url.isFileURL else { return nil }
        return url
    }
    static func originName(of snapshot: RecoverySnapshot) -> String? { origin(of: snapshot)?.lastPathComponent }
    /// One line of the launch prompt: name, folder and time.
    static func line(for snapshot: RecoverySnapshot) -> String {
        line(originalURL: snapshot.originalURL, saved: snapshot.savedAt)
    }
    static func line(originalURL: String?, saved: Date) -> String {
        guard let text = originalURL, let url = URL(string: text), url.isFileURL else {
            return "Untitled, saved \(savedAt(saved))"
        }
        return "\(url.lastPathComponent) in \(url.deletingLastPathComponent().path), saved \(savedAt(saved))"
    }
    /// The status line of a recovered draft.
    static func status(for snapshot: RecoverySnapshot) -> String {
        let name = originName(of: snapshot).map { "Recovered draft of \($0)" } ?? "Recovered untitled draft"
        return "\(name) · saved \(savedAt(snapshot.savedAt)) · original file not changed · Save As to keep"
    }
}

/// The URL scheme has exactly one operation: present an explicitly named local text file.
struct TextOpenRequest {
    static let invalidURL = WorkspaceError.invalid(
        "Use texttank://open with an absolute local path and optional positive line and column.")
    let file: URL
    let line: Int?
    let column: Int?
    init(_ raw: String) throws {
        guard let parts = URLComponents(string: raw, encodingInvalidCharacters: false),
            parts.scheme?.lowercased() == "texttank", parts.percentEncodedHost?.lowercased() == "open",
            parts.user == nil, parts.password == nil, parts.port == nil, parts.path.isEmpty, parts.fragment == nil,
            let items = parts.queryItems
        else { throw Self.invalidURL }
        var fields = [String: String]()
        for item in items {
            guard ["path", "line", "column"].contains(item.name), fields[item.name] == nil,
                let value = item.value, !value.isEmpty
            else { throw Self.invalidURL }
            fields[item.name] = value
        }
        guard let path = fields["path"], path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\0") else {
            throw Self.invalidURL
        }
        func coordinate(_ key: String) throws -> Int? {
            guard let raw = fields[key] else { return nil }
            guard raw.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(raw), n > 0 else {
                throw Self.invalidURL
            }
            return n
        }
        file = URL(fileURLWithPath: path).standardizedFileURL
        line = try coordinate("line")
        column = try coordinate("column")
    }
    init(path: String, line: Int?) throws {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\0"), line.map({ $0 > 0 }) ?? true else {
            throw Self.invalidURL
        }
        self.file = URL(fileURLWithPath: path).standardizedFileURL
        self.line = line
        self.column = nil
    }
    static func localFile(_ file: URL) throws -> URL {
        let folder = file.deletingLastPathComponent().resolvingSymlinksInPath()
        let url = folder.appendingPathComponent(file.lastPathComponent)
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .volumeIsLocalKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true, properties.volumeIsLocal == true
        else {
            throw WorkspaceError.invalid("Choose a regular text file on a local volume.")
        }
        return url
    }
    /// The document decoder enforces the encoding. Reject binary control bytes before registering a document.
    static func textFile(_ file: URL) throws -> CapturedFileRead {
        let captured = try WorkspaceStore.captureRegularFile(file, maximumBytes: Int.max)
        let bytes = captured.data
        let le = bytes.starts(with: [0xff, 0xfe]), be = bytes.starts(with: [0xfe, 0xff])
        let binary = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            if le || be {
                var i = 2
                while i + 1 < raw.count {
                    let word = le ? UInt16(raw[i]) | UInt16(raw[i + 1]) << 8 : UInt16(raw[i]) << 8 | UInt16(raw[i + 1])
                    if word < 32 && !(9...13).contains(word) { return true }
                    i += 2
                }
                return false
            }
            return raw.contains { $0 < 32 && !(9...13).contains($0) }
        }
        guard !binary else { throw WorkspaceError.invalid("The requested file contains binary control bytes.") }
        return captured
    }
    @MainActor @discardableResult func open() throws -> TextDocument {
        let url = try Self.localFile(file)
        let document: TextDocument
        if let existing = NSDocumentController.shared.document(for: url) as? TextDocument {
            document = existing
            existing.showWindows()
        } else {
            document = try DocumentFactory.openCaptured(Self.textFile(url), from: url)
        }
        if line != nil || column != nil {
            let editor = document.presentation?.activeEditor ?? document.editor
            // A line was asked for: a tab that shows Preview alone (its format may open that
            // way) puts the source beside it and gives the editor the keyboard, as Go to Line does.
            if let presentation = document.presentation, presentation.viewMode == .preview {
                presentation.revealSource()
                if presentation.isActiveTab { presentation.hostWindow?.makeFirstResponder(editor) }
            }
            editor.show(line: line ?? 1, column: column ?? 1)
        }
        return document
    }
}
