import AppKit

extension CommentCommand {
    func apply(to editor: TTEditor, profile: LanguageProfile) throws {
        guard editor.window != nil else {
            throw LanguageError.invalid("The comment command requires an open document.")
        }
        try editor.requireWritable()
        let original = editor.text, revision = editor.revision, selections = editor.selectionRanges
        let proposed = try plan(
            text: original, selections: selections.map { EditorSelection(anchor: $0.anchor, caret: $0.caret) },
            profile: profile)
        guard proposed.text != original else { return }
        guard editor.revision == revision, editor.selectionRanges == selections else {
            throw LanguageError.invalid("The document changed; comments were not applied.")
        }
        // Only the changed byte ranges are replaced, so bookmarks, folds and the viewport survive.
        // The bridge rechecks revision and length and validates every offset before the first edit.
        let edits = proposed.edits.map {
            TTTextEdit(range: TTByteRange(location: $0.start, length: $0.end - $0.start), text: $0.text)
        }
        guard editor.applyEdits(edits, expectedRevision: revision, expectedLength: original.utf8.count) else {
            throw LanguageError.invalid("The document changed; comments were not applied.")
        }
        // Selections that the edit collapsed onto one position cannot be restored as planned; the
        // selections Scintilla carried through the edits are then already in place.
        if !editor.setSelectionRanges(proposed.selections.map { TTSelectionRange(anchor: $0.anchor, caret: $0.caret) })
        {
            let caret = editor.selectionCaret
            _ = editor.setSelectionAnchor(caret, caret: caret)
        }
        editor.scrollCaretIntoView()
    }
}
