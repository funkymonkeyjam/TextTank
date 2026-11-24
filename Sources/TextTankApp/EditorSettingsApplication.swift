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
        if previous?.fontName != value.fontName || previous?.basePointSize != value.basePointSize
            || previous?.initialZoom != value.initialZoom
        {
            for comparison in EditorServices.current?.compare?.windows ?? [] {
                comparison.applyFontSettings(value)
            }
        }
        if let menu = NSApp.mainMenu { applyShortcuts(value, to: menu) }
    }
    static func applyShortcuts(_ value: EditorSettings, to menu: NSMenu) { ShortcutCatalog.apply(value, to: menu) }
}
