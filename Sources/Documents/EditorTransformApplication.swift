import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

extension EditorTransform {
    @MainActor func apply(to editor: TTEditor) throws {
        try editor.requireWritable()
        guard editor.selectionCount == 1 else {
            throw DocumentActionError.multipleSelections
        }
        let selection = editor.selectionStart != editor.selectionEnd
        let source = selection ? editor.selectedText : editor.text
        guard source.utf8.count <= 16 * 1024 * 1024 else {
            throw DocumentActionError.selectionTooLarge
        }
        let output = transform(source)
        guard output != source else { return }
        editor.beginUndoGroup(named: title)
        defer { editor.endUndoGroup() }
        // The whole-document case replaces only the span that differs, keeping bookmarks and the caret line.
        guard selection ? editor.replaceSelection(output) : editor.replaceDocumentText(output) else {
            throw DocumentActionError.changeRejected
        }
    }
}
