import TextTankCore
import AppKit
import ObjectiveC
import EditorBridge

/// A marker stays with an editor after close, so a retained editor can never become a live
/// standalone target merely because its document or presentation was released.
@MainActor enum EditorLifetime {
    private final class Binding {
        weak var document: TextDocument?
        weak var presentation: EditorWindowController?
        var retired = false
        init(_ document: TextDocument, _ presentation: EditorWindowController?) {
            self.document = document
            self.presentation = presentation
        }
    }
    private static var key: UInt8 = 0
    private static func binding(_ editor: TTEditor) -> Binding? { objc_getAssociatedObject(editor, &key) as? Binding }
    static func bind(_ editor: TTEditor, to document: TextDocument, presentation: EditorWindowController? = nil) {
        objc_setAssociatedObject(editor, &key, Binding(document, presentation), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func retire(_ editor: TTEditor) { binding(editor)?.retired = true }
    static func document(for editor: TTEditor) -> TextDocument? {
        guard let b = binding(editor), !b.retired, let doc = b.document, doc.isOpen else { return nil }
        return doc
    }
    static func isOpen(_ editor: TTEditor) -> Bool {
        if let b = binding(editor) { return !b.retired && b.document?.isOpen == true }
        // Detached native fixtures are not documents. Their existing window-lifetime boundary stays.
        return editor.window != nil
    }
    static func isVisible(_ editor: TTEditor?) -> Bool {
        guard let editor else { return false }
        if binding(editor) != nil {
            return document(for: editor) != nil && binding(editor)?.presentation?.isPresented == true
        }
        return editor.window?.isVisible == true
    }
    static func activate(_ editor: TTEditor, focus: Bool = true) {
        guard isOpen(editor) else { return }
        if let presentation = binding(editor)?.presentation, document(for: editor) != nil {
            presentation.host.activate(presentation, focus: focus)
            presentation.hostWindow?.makeKeyAndOrderFront(nil)
            if focus { presentation.hostWindow?.makeFirstResponder(editor) }
        } else {
            editor.window?.makeKeyAndOrderFront(nil)
            if focus { editor.window?.makeFirstResponder(editor) }
        }
    }
    static func title(_ editor: TTEditor?) -> String {
        guard let editor else { return "Document" }
        return document(for: editor)?.displayName ?? editor.window?.title ?? "Document"
    }
}

/// One main-thread capture. The long-running job owns bytes and weak identities, never a view.
@MainActor final class AutomationDocumentTarget {
    let value: DocumentTarget?
    private weak var document: TextDocument?
    private weak var origin: TTEditor?
    private let revision: UInt
    let selections: [SessionSelection]
    let text: String
    let name: String
    init?(_ editor: TTEditor?) {
        guard let editor, EditorLifetime.isOpen(editor) else { return nil }
        origin = editor
        revision = editor.revision
        selections = editor.selectionRanges.map { SessionSelection(anchorByte: $0.anchor, caretByte: $0.caret) }
        text = editor.text
        name = EditorLifetime.title(editor)
        if let document = EditorLifetime.document(for: editor) {
            self.document = document
            value = DocumentTarget(
                documentID: document.runtimeID, revision: revision,
                loadEpoch: document.loadEpoch, byteLength: editor.byteLength, selections: selections)
        } else {
            value = nil
        }
    }
    func resolve() throws -> TTEditor {
        let editor: TTEditor
        if let value {
            guard let document, document.isOpen,
                value.isCurrent(
                    documentID: document.runtimeID, revision: document.editor.revision,
                    loadEpoch: document.loadEpoch)
            else { throw changed() }
            editor = document.editor
        } else {
            guard let origin, EditorLifetime.isOpen(origin), origin.revision == revision else { throw changed() }
            editor = origin
        }
        if let origin, EditorLifetime.isOpen(origin) {
            let current = origin.selectionRanges.map { SessionSelection(anchorByte: $0.anchor, caretByte: $0.caret) }
            guard current == selections else { throw changed() }
        }
        return editor
    }
    func requireWritable() throws {
        let editor = try resolve()
        guard !editor.readOnly else { throw AutomationError.invalid("“\(name)” is read-only. Nothing was replaced.") }
    }
    func apply(_ outputs: [String], wholeDocument: Bool) throws {
        try requireWritable()
        let editor = try resolve()
        let applied: Bool
        if wholeDocument {
            applied = outputs.count == 1 && editor.replaceDocumentText(outputs[0], expectedRevision: revision)
        } else if let origin, EditorLifetime.isOpen(origin) {
            applied = origin.replaceSelections(outputs, expectedRevision: revision)
        } else {
            let edits = zip(selections, outputs).map { range, text in
                TTTextEdit(
                    range: TTByteRange(
                        location: min(range.anchorByte, range.caretByte),
                        length: abs(range.caretByte - range.anchorByte)), text: text)
            }
            applied =
                selections.count == outputs.count
                && editor.applyEdits(
                    edits, expectedRevision: revision,
                    expectedLength: text.utf8.count)
        }
        guard applied else { throw changed() }
    }
    func selectionTexts() throws -> [String] {
        let bytes = Data(text.utf8)
        return try selections.map { range in
            let lo = min(range.anchorByte, range.caretByte), hi = max(range.anchorByte, range.caretByte)
            guard lo >= 0, hi <= bytes.count, lo < hi,
                let text = String(data: bytes.subdata(in: lo..<hi), encoding: .utf8)
            else {
                throw AutomationError.invalid("Select text in every selection before running this automation.")
            }
            return text
        }
    }
    private func changed() -> AutomationError {
        .invalid(
            "“\(name)” changed, its selection changed, or it closed. Nothing was replaced. Run the automation again with the current text."
        )
    }
}
