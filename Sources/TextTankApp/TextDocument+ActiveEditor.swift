import AppKit

extension TextDocument {
    /// The view of this document the person last worked in: the focused pane of a split view,
    /// otherwise the primary view. Exactly one view per document.
    var activeEditor: TTEditor { (windowControllers.first as? EditorWindowController)?.activeEditor ?? editor }
}
