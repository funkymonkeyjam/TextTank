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
                    if doc.deferredLargeFileLanguage == nil, previous.wrap != value.wrap, editor.wrap == previous.wrap { editor.wrap = value.wrap }
                } else {
                    editor.configureTabWidth(value.tabWidth, useTabs: value.useTabs)
                    if doc.deferredLargeFileLanguage == nil { editor.wrap = value.wrap }
                }
            }
        }
        if let previous, !previous.changeBarsEnabled, value.changeBarsEnabled { explainMissingChangeBars() }
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
        for doc in NSDocumentController.shared.documents.compactMap({ $0 as? TextDocument })
        where doc.deferredLargeFileLanguage == nil && !doc.editor.changeTrackingActive {
            // Said once, for the tab the person is looking at; shown in every tab it is true of.
            doc.presentations.forEach {
                $0.showTransientStatus(changeBarsPendingMessage, seconds: 8, announce: $0.host.active === $0)
            }
        }
    }
    static func applyShortcuts(_ value: EditorSettings, to menu: NSMenu) { ShortcutCatalog.apply(value, to: menu) }
}
