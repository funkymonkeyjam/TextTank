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
    static func popUp(after error: Error) -> NSPopUpButton {
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
    static func selection(of choice: NSPopUpButton) -> FileEncoding? {
        (choice.selectedItem?.representedObject as? String).flatMap(FileEncoding.init(rawValue:))
    }
    /// The chooser itself. Returns nil when the person cancels.
    static func present(_ url: URL, _ failure: Error) -> FileEncoding? {
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
    static func retry(
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
    var chooseEncoding: (URL, Error) -> FileEncoding? = EncodingChoice.present
    /// A session snapshot is restored through its own review prompt, never opened as editable JSON.
    var openSessionFile: (URL) -> Void = { url in (NSApp.delegate as? AppDelegate)?.workspace.openSession(at: url) }
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
        super.openDocument(withContentsOf: url, display: displayDocument) { [weak self] document, alreadyOpen, error in
            guard let self else {
                completionHandler(document, alreadyOpen, error)
                return
            }
            let finish = {
                self.finishOpen(
                    url, display: displayDocument, document, alreadyOpen, error, completionHandler: completionHandler)
            }
            if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
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
        guard let url = origin(of: snapshot) else { return "Untitled, saved \(savedAt(snapshot.savedAt))" }
        return "\(url.lastPathComponent) in \(url.deletingLastPathComponent().path), saved \(savedAt(snapshot.savedAt))"
    }
    /// The status line of a recovered draft.
    static func status(for snapshot: RecoverySnapshot) -> String {
        let name = originName(of: snapshot).map { "Recovered draft of \($0)" } ?? "Recovered untitled draft"
        return "\(name) · saved \(savedAt(snapshot.savedAt)) · original file not changed · Save As to keep"
    }
}
