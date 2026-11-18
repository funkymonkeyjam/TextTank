import AppKit
import ObjectiveC
import EditorBridge

/// A marker stays with an editor after close, so a retained editor can never become a live
/// standalone target merely because its document or presentation was released.
@MainActor enum EditorLifetime {
    private final class Binding {
        weak var document: TextDocument?
        var retired = false
        init(_ document: TextDocument) { self.document = document }
    }
    private static var key: UInt8 = 0
    private static func binding(_ editor: TTEditor) -> Binding? { objc_getAssociatedObject(editor, &key) as? Binding }
    static func bind(_ editor: TTEditor, to document: TextDocument) {
        objc_setAssociatedObject(editor, &key, Binding(document), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
        if binding(editor) != nil { return document(for: editor)?.presentation?.isPresented == true }
        return editor.window?.isVisible == true
    }
    static func activate(_ editor: TTEditor, focus: Bool = true) {
        guard isOpen(editor) else { return }
        if let presentation = document(for: editor)?.presentation {
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
