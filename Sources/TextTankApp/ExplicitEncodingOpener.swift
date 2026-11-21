import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// Recovery attempter for a file whose bytes need an explicit encoding choice. It only
/// decodes and opens; nothing on disk is changed.
@MainActor final class ExplicitEncodingOpener: NSObject {
    let url: URL, typeName: String, encoding: FileEncoding
    nonisolated init(url: URL, typeName: String, encoding: FileEncoding) {
        self.url = url
        self.typeName = typeName
        self.encoding = encoding
    }
    nonisolated func error() -> NSError {
        NSError(
            domain: "TextTank", code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "“\(url.lastPathComponent)” begins with bytes that are either a UTF-32 signature or UTF-16 LE text whose first character is NUL.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "UTF-32 is not supported. If this is a UTF-16 LE file, for example one saved by TextTank, open it as UTF-16 LE. Opening does not change the file.",
                NSLocalizedRecoveryOptionsErrorKey: ["Open as UTF-16 LE", "Cancel"],
                NSRecoveryAttempterErrorKey: self,
                NSURLErrorKey: url
            ])
    }
    @discardableResult func open(display: Bool = true) throws -> TextDocument {
        try TextDocument.open(url, as: encoding, ofType: typeName, display: display)
    }
    override func attemptRecovery(fromError error: Error, optionIndex recoveryOptionIndex: Int) -> Bool {
        precondition(Thread.isMainThread)
        return MainActor.assumeIsolated {

            guard recoveryOptionIndex == 0 else { return false }
            do {
                try open()
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                return true
            } catch {
                TTAlert.present(error)
                return false
            }

        }
    }
    override func attemptRecovery(
        fromError error: Error, optionIndex recoveryOptionIndex: Int, delegate: Any?, didRecoverSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        precondition(Thread.isMainThread)
        // Only the Bool crosses the synchronous UI boundary. Raw Objective-C callback
        // identity/context remain on this actual main-thread entry, with no actor transfer.
        let recovered = attemptRecovery(fromError: error, optionIndex: recoveryOptionIndex)
        ErrorRecoveryReply.send(recovered, to: delegate, selector: didRecoverSelector, contextInfo: contextInfo)
    }
}

enum ErrorRecoveryReply {
    static func send(
        _ recovered: Bool, to delegate: Any?, selector didRecoverSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let target = delegate as AnyObject?, let didRecoverSelector,
            let method = class_getInstanceMethod(type(of: target), didRecoverSelector)
        else { return }
        // - (void)didPresentErrorWithRecovery:(BOOL)didRecover contextInfo:(void *)contextInfo
        typealias Callback = @convention(c) (AnyObject, Selector, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(method_getImplementation(method), to: Callback.self)(
            target, didRecoverSelector, recovered, contextInfo)
    }
}
