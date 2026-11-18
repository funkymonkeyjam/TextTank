import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// Product-created documents share type, registration and window setup. NSDocumentController's
/// stock File/Open/Finder path still constructs its NSDocumentClass in the normal AppKit way.
@MainActor enum DocumentFactory {
    @discardableResult static func makeUntitled(
        display: Bool = true, focus: Bool = true,
        prepare: (TextDocument) -> Void = { _ in }, populate: (TextDocument) -> Void = { _ in }
    ) -> TextDocument {
        let document = TextDocument()
        document.fileType = TextDocument.plainTextType
        // Recovery identity must be installed before window wiring or the first edit.
        prepare(document)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        populate(document)
        if display { document.showWindows() }
        if display && focus { document.presentation?.hostWindow?.makeFirstResponder(document.editor) }
        return document
    }
    @discardableResult static func openCaptured(
        _ read: CapturedFileRead, from url: URL, as encoding: FileEncoding? = nil,
        ofType typeName: String = TextDocument.plainTextType, display: Bool = true
    ) throws -> TextDocument {
        let document = TextDocument()
        document.fileURL = url
        document.fileType = typeName
        try document.read(captured: read.data, sample: read.sample, from: url, ofType: typeName, as: encoding)
        document.fileModificationDate = read.modificationDate
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        if display { document.showWindows() }
        return document
    }
}
