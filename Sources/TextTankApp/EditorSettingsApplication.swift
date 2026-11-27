import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// Synchronous application effects installed by the composition root, outside the value/store layer.
@MainActor enum EditorSettingsApplication {
    static func apply(_ value: EditorSettings, replacing previous: EditorSettings?) {
        NSApp.appearance =
            value.appearance == "system" ? nil : NSAppearance(named: value.appearance == "dark" ? .darkAqua : .aqua)
        let font =
            previous?.fontName != value.fontName || previous?.basePointSize != value.basePointSize
            ? value.resolvedBaseFont : nil
        for doc in NSDocumentController.shared.documents.compactMap({ $0 as? TextDocument }) {
            if previous?.diskChangeBehavior != value.diskChangeBehavior {
                doc.externalFile.setPolicy(value.diskChangeBehavior)
            }
            let views = doc.presentations.flatMap(\.views)
            for editor in views.isEmpty ? [doc.editor] : views {
                if let font { editor.setBaseFontName(font.fontName, size: font.pointSize) }
                if previous?.initialZoom != value.initialZoom { editor.applyDefaultZoomLevel(value.initialZoom) }
                editor.autoIndentEnabled = value.autoIndentEnabled
                editor.autoPairEnabled = value.autoPairEnabled
                editor.braceHighlightEnabled = value.braceHighlightEnabled
                editor.currentLineHighlightEnabled = value.currentLineHighlightEnabled
                editor.indentGuidesEnabled = value.indentGuidesEnabled
                editor.lineNumbersVisible = value.lineNumbersEnabled
                editor.whitespaceVisible = value.showWhitespaceEnabled
                editor.lineEndingsVisible = value.showLineEndingsEnabled
                applyChangeBars(value.changeBarsEnabled, to: editor, of: doc)
                editor.centeredColumnCharacters = value.centeredColumnEnabled ? value.centeredColumnCharacters : 0
                if let previous {
                    let info = editor.statusInfo
                    if previous.tabWidth != value.tabWidth || previous.useTabs != value.useTabs,
                        info.tabWidth == previous.tabWidth, info.useTabs == previous.useTabs
                    {
                        editor.configureTabWidth(value.tabWidth, useTabs: value.useTabs)
                    }
                    if doc.deferredLargeFileLanguage == nil, previous.wrap != value.wrap, editor.wrap == previous.wrap {
                        editor.wrap = value.wrap
                    }
                } else {
                    editor.configureTabWidth(value.tabWidth, useTabs: value.useTabs)
                    if doc.deferredLargeFileLanguage == nil { editor.wrap = value.wrap }
                }
            }
        }
        if let previous, !previous.changeBarsEnabled, value.changeBarsEnabled { explainMissingChangeBars() }
        if !value.changeBarsEnabled { awaitingChangeBarsExplanation.removeAllObjects() }
        if previous?.fontName != value.fontName || previous?.basePointSize != value.basePointSize
            || previous?.initialZoom != value.initialZoom
        {
            for comparison in EditorServices.current?.compare?.windows ?? [] {
                comparison.applyFontSettings(value)
            }
        }
        if let menu = NSApp.mainMenu { applyShortcuts(value, to: menu) }
    }
    /// Change bars are never shown, and changes never recorded, for a document in large-file mode
    /// (above the highlighting limit), so typing and loading there cost what they always did.
    static func applyChangeBars(_ enabled: Bool, to editor: TTEditor, of document: TextDocument) {
        if document.deferredLargeFileLanguage != nil {
            if editor.changeBarsVisible || editor.changeTrackingActive { editor.stopChangeTracking() }
        } else {
            editor.changeBarsVisible = enabled
        }
    }
    /// What the person is told in a tab whose document cannot record changes yet.
    static let changeBarsPendingMessage =
        "This document was edited before Change Bars was turned on. Its change bars start after it is reverted or reopened."
    /// Scintilla starts a change record only while a document has no Undo history, and TextTank
    /// never clears Undo to get one. A document edited before Change Bars was turned on shows the
    /// margin with no bars; its tabs say why (DS-81), and the record starts at its next load.
    private static func explainMissingChangeBars() {
        awaitingChangeBarsExplanation.removeAllObjects()
        for doc in NSDocumentController.shared.documents.compactMap({ $0 as? TextDocument })
        where doc.deferredLargeFileLanguage == nil && !doc.editor.changeTrackingActive {
            for tab in doc.presentations {
                // A tab on screen says it now. A tab behind another keeps it for when it is next
                // shown, so the explanation is never spent where nobody can read it.
                if tab.isPresented { explainChangeBars(in: tab) } else { awaitingChangeBarsExplanation.add(tab) }
            }
        }
    }
    /// Tabs that owe the person the explanation above. Weak: a closed tab simply leaves.
    private static let awaitingChangeBarsExplanation = NSHashTable<EditorWindowController>.weakObjects()
    static func awaitsChangeBarsExplanation(_ tab: EditorWindowController) -> Bool {
        awaitingChangeBarsExplanation.contains(tab)
    }
    private static func explainChangeBars(in tab: EditorWindowController) {
        // Announced only for the tab the person is working in.
        tab.showTransientStatus(changeBarsPendingMessage, seconds: 8, announce: tab.host.active === tab)
    }
    /// Called when a tab comes on screen. Says why the tab has no change bars if that is still
    /// true: the document may have been reverted, or Change Bars turned off, in the meantime.
    static func tabWasShown(_ tab: EditorWindowController) {
        guard awaitingChangeBarsExplanation.contains(tab), tab.isPresented else { return }
        awaitingChangeBarsExplanation.remove(tab)
        guard let doc = tab.document as? TextDocument, doc.deferredLargeFileLanguage == nil,
            EditorServices.current?.settings?.value.changeBarsEnabled == true, tab.primaryEditor.changeBarsVisible,
            !tab.primaryEditor.changeTrackingActive
        else { return }
        explainChangeBars(in: tab)
    }
    /// The standing explanation, for the menu item and the Settings row (DS-85): it is there
    /// whenever the person looks, whatever happened to the status message.
    static let changeBarsHelp =
        "Marks the lines changed since each document was opened: a wide bar for a change that is not saved, a narrow bar for a saved one. A document you had already edited when this was turned on shows no bars until you revert or reopen it."
    static func applyShortcuts(_ value: EditorSettings, to menu: NSMenu) { ShortcutCatalog.apply(value, to: menu) }
}
