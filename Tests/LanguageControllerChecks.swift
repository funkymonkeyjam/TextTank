@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
import NativeSearch
/// Function-list navigation fronts the document window; these checks never put one on screen.
final class QuietListWindow: NSWindow { override func makeKeyAndOrderFront(_ sender: Any?) {} }
@main struct LanguageControllerChecks {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func editingJSON(_ controller: LanguageController, _ act: @escaping (NSWindow, [NSView]) -> Bool) -> Bool {
        var acted = false, timedOut = false
        let deadline = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            guard let window = presentedFormWindow, let content = window.contentView else { return }
            if Date() > deadline {
                timedOut = true
                NSApp.abortModal()
                return
            }
            if !acted { acted = act(window, descendants(content)) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        controller.configure()
        waitForModelessForms()
        return acted && !timedOut
    }
    static func jsonEditorChecks(bundledURL: URL) throws {
        let isolated = try IsolatedSupportDirectory("LanguageJSONChecks")
        defer { isolated.restore() }
        let path = isolated.url.appendingPathComponent("LanguageProfiles.json")
        let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.text = "import os\n"
        editor.resetUndoHistory()
        editor.setSavePoint()
        let revision = editor.revision
        let controller = LanguageController(
            editorProvider: { editor }, languageProvider: { "python" }, setLanguage: { _ in },
            bundledCatalog: bundledURL)
        let bundled = try requireValue(controller.catalog, "fixture: JSON language catalog exists")
        try controller.persist(bundled)
        _ = controller.apply(identifier: "python", to: editor)
        var reapplyCalls = 0
        controller.openDocuments = {
            reapplyCalls += 1
            return [(language: "python", editor: editor)]
        }
        var corrected = bundled
        let index = try requireValue(
            corrected.profiles.firstIndex { $0.id == "python" }, "fixture: Python profile exists")
        corrected.profiles[index].title = "Python JSON draft"
        for style in corrected.profiles[index].styles.indices {
            corrected.profiles[index].styles[style].fontSize = 21
        }
        let correctedJSON = String(decoding: try corrected.encoded(), as: UTF8.self)
        let before = try Data(contentsOf: path)
        let invalid = "{ keep this Language JSON draft"
        var stage = 0, nestedError = false, keptDraft = false, inlineError = false
        var manager: NSWindow?
        let retried = editingJSON(controller) { window, views in
            if stage == 1, window !== manager {
                nestedError = true
                NSApp.abortModal()
                return false
            }
            guard let text = views.compactMap({ $0 as? NSTextView }).first,
                let save = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Save" })
            else { return false }
            switch stage {
            case 0:
                manager = window
                text.string = invalid
                stage = 1
                save.performClick(nil)
            case 1:
                keptDraft = text.string == invalid && (try? Data(contentsOf: path)) == before && reapplyCalls == 0
                inlineError = text.accessibilityHelp()?.isEmpty == false
                text.string = correctedJSON
                stage = 2
                save.performClick(nil)
                return true
            default: break
            }
            return false
        }
        check(
            retried && stage == 2 && keptDraft,
            "F155 Language JSON retry preserves the draft, storage and current styles")
        check(!nestedError && inlineError, "F155 invalid Language JSON is marked inline without a nested error modal")
        let stored = try Data(contentsOf: path)
        struct Format: Decodable {
            var overridesVersion: Int?
            var version: Int?
        }
        let format = try JSONDecoder().decode(Format.self, from: stored)
        check(
            format.overridesVersion == 1 && format.version == nil,
            "F155 Language JSON Save still stores overrides rather than a full catalog")
        let loaded = try LanguageCatalog.load(stored: stored, over: bundled)
        check(
            PersistedValue.equal(loaded.profiles, corrected.profiles),
            "F155 full Language JSON changes roundtrip through overrides")
        let font = editor.attributedText(forSelection: false).attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        check(
            reapplyCalls == 1 && font.map { abs($0.pointSize - 21) < 0.01 } == true,
            "F155 Language JSON Save reapplies the actual changed styles to open documents")
        check(
            editor.text == "import os\n" && editor.revision == revision && !editor.modified,
            "F155 Language JSON configuration never edits document bytes or dirty state")
        var imported = corrected
        imported.profiles[index].title = "Imported Language draft"
        for style in imported.profiles[index].styles.indices { imported.profiles[index].styles[style].fontSize = 23 }
        let importData = try imported.encoded()
        let importURL = isolated.url.appendingPathComponent("language-import.json")
        let futureURL = isolated.url.appendingPathComponent("language-newer-reader.json")
        let exportURL = isolated.url.appendingPathComponent("language-export.json")
        try importData.write(to: importURL)
        var future = Data("{\"minimumReaderVersion\":2,".utf8)
        future.append(importData.dropFirst())
        try future.write(to: futureURL)
        var chosenImport = futureURL, exportNames: [String] = []
        controller.jsonFilePanels = .init(
            importURL: { chosenImport },
            exportURL: { name in
                exportNames.append(name)
                return exportURL
            })
        stage = 0
        var refusedDraft = false, importedOnlyDraft = false, exportedDraft = false
        let files = editingJSON(controller) { _, views in
            guard let text = views.compactMap({ $0 as? NSTextView }).first,
                let load = views.compactMap({ $0 as? NSButton }).first(where: {
                    $0.identifier?.rawValue == "language.json.import"
                }),
                let export = views.compactMap({ $0 as? NSButton }).first(where: {
                    $0.identifier?.rawValue == "language.json.export"
                }),
                let cancel = views.compactMap({ $0 as? NSButton }).first(where: {
                    $0.identifier?.rawValue == "language.json.cancel"
                })
            else { return false }
            switch stage {
            case 0:
                text.string = correctedJSON + "\n "
                stage = 1
                load.performClick(nil)
            case 1:
                refusedDraft =
                    text.string == correctedJSON + "\n " && text.accessibilityHelp()?.isEmpty == false
                    && (try? Data(contentsOf: path)) == stored
                chosenImport = importURL
                stage = 2
                load.performClick(nil)
            case 2:
                importedOnlyDraft =
                    text.accessibilityHelp() == nil
                    && (try? LanguageCatalog.decode(Data(text.string.utf8))) == imported
                    && (try? Data(contentsOf: path)) == stored && reapplyCalls == 1
                stage = 3
                export.performClick(nil)
            case 3:
                exportedDraft = (try? LanguageCatalog.decode(Data(contentsOf: exportURL))) == imported
                stage = 4
                cancel.performClick(nil)
                return true
            default: break
            }
            return false
        }
        check(
            files && stage == 4 && refusedDraft, "F155 newer-reader Language import is refused without losing the draft"
        )
        check(
            try Data(contentsOf: futureURL) == future && controller.loadError == nil,
            "F155 refused external Language input stays unchanged and does not poison saved profiles")
        check(
            importedOnlyDraft && exportedDraft && exportNames == ["TextTank-LanguageProfiles.json"],
            "F155 valid Language import/export uses a full-catalog draft and the documented export name")
        check(
            try Data(contentsOf: path) == stored && reapplyCalls == 1,
            "F155 Cancel after Language import/export keeps stored overrides and live styles")
        stage = 0
        let accepted = editingJSON(controller) { _, views in
            guard
                let load = views.compactMap({ $0 as? NSButton }).first(where: {
                    $0.identifier?.rawValue == "language.json.import"
                }),
                let save = views.compactMap({ $0 as? NSButton }).first(where: {
                    $0.identifier?.rawValue == "language.json.save"
                })
            else { return false }
            if stage == 0 {
                stage = 1
                load.performClick(nil)
            } else if stage == 1 {
                stage = 2
                save.performClick(nil)
                return true
            }
            return false
        }
        let importedStored = try Data(contentsOf: path)
        let importedFormat = try JSONDecoder().decode(Format.self, from: importedStored)
        let importedLoaded = try LanguageCatalog.load(stored: importedStored, over: bundled)
        check(
            accepted && importedFormat.overridesVersion == 1 && importedFormat.version == nil
                && PersistedValue.equal(importedLoaded.profiles, imported.profiles),
            "F155 imported Language Save still writes lossless overrides")
        let importedFont =
            editor.attributedText(forSelection: false).attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        check(
            reapplyCalls == 2 && importedFont.map { abs($0.pointSize - 23) < 0.01 } == true
                && editor.revision == revision && !editor.modified,
            "F155 imported Language Save reapplies styles without changing document text")
        controller.jsonFilePanels = .init(importURL: { nil }, exportURL: { _ in nil })
        stage = 0
        var cancelledChoicesKeptDraft = false
        let cancelFiles = editingJSON(controller) { _, views in
            guard let text = views.compactMap({ $0 as? NSTextView }).first,
                let load = views.compactMap({ $0 as? NSButton }).first(where: {
                    $0.identifier?.rawValue == "language.json.import"
                }),
                let export = views.compactMap({ $0 as? NSButton }).first(where: {
                    $0.identifier?.rawValue == "language.json.export"
                }),
                let cancel = views.compactMap({ $0 as? NSButton }).first(where: {
                    $0.identifier?.rawValue == "language.json.cancel"
                })
            else { return false }
            switch stage {
            case 0:
                text.string = correctedJSON + "\n "
                stage = 1
                load.performClick(nil)
            case 1:
                cancelledChoicesKeptDraft = text.string == correctedJSON + "\n "
                stage = 2
                export.performClick(nil)
            case 2:
                cancelledChoicesKeptDraft = cancelledChoicesKeptDraft && text.string == correctedJSON + "\n "
                stage = 3
                cancel.performClick(nil)
                return true
            default: break
            }
            return false
        }
        check(
            try cancelFiles && cancelledChoicesKeptDraft && Data(contentsOf: path) == importedStored
                && reapplyCalls == 2,
            "F155 cancelled Language file choices keep the draft, stored bytes and live styles")
        let corrupt = Data("{ preserve unreadable language profiles".utf8)
        try corrupt.write(to: path)
        let blocked = LanguageController(
            editorProvider: { editor }, languageProvider: { "python" }, setLanguage: { _ in },
            bundledCatalog: bundledURL)
        var recoveryOnly = false
        let declined = editingJSON(blocked) { _, views in
            guard
                let cancel = views.compactMap({ $0 as? NSButton }).first(where: {
                    $0.identifier?.rawValue == "store.recover.cancel"
                })
            else { return false }
            recoveryOnly = !views.contains { $0 is NSTextView }
            cancel.performClick(nil)
            return true
        }
        check(
            try declined && recoveryOnly && Data(contentsOf: path) == corrupt && blocked.storageDamaged,
            "F155 unreadable Language storage requires explicit recovery before the JSON editor")
    }
    static func main() {
        Checks.run("LanguageControllerChecks") {
            let isolatedSupport = try IsolatedSupportDirectory("LanguageChecks")
            defer { isolatedSupport.restore() }
            _ = NSApplication.shared
            let
                window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                    defer: false), editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            window.contentView = editor
            var selected = "python"
            // F148: the check executable has no bundle, so it names the bundled catalog itself.
            let bundledURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            let controller = LanguageController(
                editorProvider: { editor }, languageProvider: { selected }, setLanguage: { selected = $0 },
                bundledCatalog: bundledURL)
            let catalog = try requireValue(controller.catalog, "fixture: language catalog loaded")
            let text = "# café\nclass Example:\n    def work(self):\n        return 1\n"
            editor.text = text
            editor.resetUndoHistory()
            editor.setSavePoint()
            let revision = editor.revision
            check(controller.apply(identifier: "python", to: editor), "Python profile applies to live Lexilla editor")
            check(
                editor.text == text && editor.revision == revision && !editor.modified,
                "language configuration preserves bytes Undo dirty state")
            let attributed = editor.attributedText(forSelection: false)
            check(attributed.string == text, "styled export preserves exact source")
            let symbols = try LanguageFunctions.symbols(
                text: text, profile: catalog.profiles.first { $0.id == "python" }!)
            check(
                LanguageFunctionController.navigate(symbols[1], text: text, revision: revision, editor: editor)
                    && editor.selectedText == "work",
                "function navigation selects exact UTF8 symbol after Unicode prefix")
            // Package 21 (F293, G391): the Function List is a panel and a symbol opens from the keyboard.
            do {
                let list = LanguageFunctionController(editor: editor, text: text, revision: revision, symbols: symbols)
                let panel = try requireValue(list.window as? NSPanel, "the Function List window is a panel")
                // A panel is not listed in the Window menu by AppKit, and this one has no command that
                // shows it again, so it lists itself: covered by the document window it stays reachable.
                if NSApp.windowsMenu == nil { NSApp.windowsMenu = NSMenu(title: "Window") }
                panel.orderFront(nil)
                check(
                    NSApp.windowsMenu?.items.filter { $0.target === panel && $0.title == panel.title }.count == 1,
                    "the Function List panel is listed once in the Window menu while it is showing")
                panel.orderOut(nil)
                check(
                    !(NSApp.windowsMenu?.items.contains { $0.target === panel } ?? false),
                    "a hidden Function List panel leaves the Window menu")
                check(
                    !panel.canBecomeMain && !panel.hidesOnDeactivate && !panel.isFloatingPanel
                        && panel.level == .normal && panel.initialFirstResponder === list.table,
                    "the Function List panel cannot become main, does not float and starts in the list")
                check(
                    list.numberOfRows(in: list.table) == symbols.count
                        && list.table.accessibilityLabel() == "Functions and symbols",
                    "fixture: the list shows the symbols and has a VoiceOver label")
                _ = editor.setSelectionAnchor(0, caret: 0)
                list.table.selectRowIndexes([1], byExtendingSelection: false)
                check(
                    list.table.clickedRow == -1
                        && NSApp.sendAction(NSSelectorFromString("openSelected"), to: list, from: nil)
                        && editor.selectionCaret == 0,
                    "a double-click away from the rows navigates nowhere, even with a symbol selected")
                let returnKey = try requireValue(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36),
                    "fixture: a Return key event")
                list.table.keyDown(with: returnKey)
                check(editor.selectedText == "work", "Return on a selected symbol navigates to it")
                let hint = (panel.contentView as? NSStackView)?.views.compactMap { $0 as? NSTextField }.first
                check(
                    hint?.stringValue.contains("press Return") == true,
                    "the Function List says how to open a symbol from the keyboard")
                editor.replaceSelection("work2")
                list.table.selectRowIndexes([0], byExtendingSelection: false)
                list.table.keyDown(with: returnKey)
                check(
                    hint?.stringValue == "The document changed or closed. Refresh the function list.",
                    "Return on a symbol of a changed document reports that the list is stale")
            }
            editor.text = "changed"
            let selection = editor.selectionCaret
            check(
                !LanguageFunctionController.navigate(symbols[1], text: text, revision: revision, editor: editor)
                    && editor.selectionCaret == selection, "stale function list cannot move selection")
            // F277: a function-list row moves the caret with no recordable macro step, and says so.
            let quiet = QuietListWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.contentView = NSView()
            quiet.contentView = editor
            editor.text = text
            let list = LanguageFunctionController(
                editor: editor, text: text, revision: editor.revision, symbols: symbols)
            var navigated = 0
            list.onNavigate = { navigated += 1 }
            list.open(row: symbols.count)
            check(navigated == 0, "a function-list row that does not exist navigates nowhere")
            list.open(row: 1)
            check(
                navigated == 1 && editor.selectedText == "work",
                "a function-list row that moves the caret reports the jump")
            editor.text = "changed"
            list.open(row: 1)
            check(navigated == 1, "a stale function-list row reports no jump")
            quiet.contentView = NSView()
            window.contentView = editor
            let source = "if return class 123 \"text\" // comment\n"
            editor.text = source
            editor.resetUndoHistory()
            editor.setSavePoint()
            var supported = 0, missing: [String] = []
            for profile in catalog.profiles {
                if controller.apply(identifier: profile.id, to: editor) {
                    supported += 1
                    check(editor.text == source && !editor.modified, "profile \(profile.id) configures without editing")
                } else {
                    missing.append(profile.id)
                }
            }
            var custom = catalog
            custom.profiles[0].title = "My plain language"
            try controller.persist(custom)
            let restored = LanguageController(
                editorProvider: { editor }, languageProvider: { selected }, setLanguage: { selected = $0 },
                bundledCatalog: bundledURL)
            check(restored.catalog == custom, "custom profile persistence and reload exact")
            let menu = controller.menu()
            let pythonItem = menu.items.first { ($0.representedObject as? String) == "python" }!
            check(
                NSApp.sendAction(pythonItem.action!, to: pythonItem.target, from: pythonItem) && selected == "python",
                "real language menu action updates chosen profile")
            let udl = UserDefinedLanguage(
                name: "Synthetic Test", extensions: "sample", version: "2.1",
                global: ["caseIgnored": "yes", "forcePureLC": "0", "decimalSeparator": "0"], prefix: [:],
                keywords: [
                    "Keywords1": "hello world", "Comments": "00// 01 02 03/* 04*/",
                    "Delimiters": "00\" 01\\ 02\" 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23"
                ],
                styles: [
                    .init(name: "DEFAULT", attributes: ["fgColor": "000000", "fontStyle": "0"]),
                    .init(name: "KEYWORDS1", attributes: ["fgColor": "0000FF", "fontStyle": "1"]),
                    .init(name: "COMMENTS", attributes: ["fgColor": "008000", "fontStyle": "2"]),
                    .init(name: "DELIMITERS1", attributes: ["fgColor": "A05000", "fontStyle": "2"])
                ])
            let user = try udl.profile()
            custom.profiles.append(user)
            try controller.persist(custom)
            editor.text = "HELLO ordinary /* comment */ \"string\""
            editor.resetUndoHistory()
            editor.setSavePoint()
            check(controller.apply(identifier: user.id, to: editor), "ported LexUser factory applies imported UDL")
            let styled = editor.attributedText(forSelection: false)
            let keywordFont = styled.attribute(.font, at: 0, effectiveRange: nil) as! NSFont,
                ordinaryFont = styled.attribute(.font, at: 6, effectiveRange: nil) as! NSFont
            check(
                NSFontManager.shared.traits(of: keywordFont).contains(.boldFontMask)
                    && !NSFontManager.shared.traits(of: ordinaryFont).contains(.boldFontMask),
                "actual LexUser keyword case-insensitive style differs from ordinary text")
            let commentRange = (editor.text as NSString).range(of: "comment"),
                stringRange = (editor.text as NSString).range(of: "string")
            let commentFont = styled.attribute(.font, at: commentRange.location, effectiveRange: nil) as! NSFont,
                stringFont = styled.attribute(.font, at: stringRange.location, effectiveRange: nil) as! NSFont
            check(
                NSFontManager.shared.traits(of: commentFont).contains(.italicFontMask),
                "actual LexUser block comment style")
            check(
                NSFontManager.shared.traits(of: stringFont).contains(.italicFontMask), "actual LexUser delimiter style")
            check(!editor.modified, "UDL lexing never marks document dirty")
            let index = custom.profiles.firstIndex { $0.id == user.id }!,
                styleIndex = custom.profiles[index].styles.firstIndex { $0.name == "KEYWORDS1" }!
            let chosenFont = NSFont.userFixedPitchFont(ofSize: 19.25)!.fontName
            custom.profiles[index].styles[styleIndex].fontName = chosenFont
            custom.profiles[index].styles[styleIndex].fontSize = 19.25
            custom.profiles[index].styles[styleIndex].useCustomColor = true
            custom.profiles[index].styles[styleIndex].foreground = "123456"
            try controller.persist(custom)
            let beforeStyleRevision = editor.revision
            _ = controller.apply(identifier: user.id, to: editor)
            func styleMatches() -> Bool {
                let output = editor.attributedText(forSelection: false),
                    font = output.attribute(.font, at: 0, effectiveRange: nil) as! NSFont,
                    color = (output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor)
                        .usingColorSpace(.sRGB)!
                return abs(font.pointSize - 19.25) < 0.01 && abs(color.redComponent - Double(0x12) / 255) < 0.005
                    && abs(color.greenComponent - Double(0x34) / 255) < 0.005
                    && abs(color.blueComponent - Double(0x56) / 255) < 0.005
            }
            check(styleMatches(), "actual lexer export honors configured font size and RGB")
            editor.appearance = NSAppearance(named: .darkAqua)
            editor.viewDidChangeEffectiveAppearance()
            check(styleMatches(), "custom font and RGB survive appearance change")
            check(
                editor.revision == beforeStyleRevision && !editor.modified, "font and color changes never edit document"
            )
            // F21, F83: a saved style change reaches every view of every open document on that
            // profile, the lexer is installed once per document, and other documents are left alone.
            do {
                func look(_ view: TTEditor) -> (size: CGFloat, red: CGFloat) {
                    let output = view.attributedText(forSelection: false),
                        font = output.attribute(.font, at: 0, effectiveRange: nil) as! NSFont,
                        color = (output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor)
                            .usingColorSpace(.sRGB)!
                    return (font.pointSize, color.redComponent)
                }
                let pane = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                pane.shareDocument(with: editor)
                // Earlier checks deliberately put the source in Dark Aqua. Compare identical
                // appearances for propagation, then test independent appearance resolution below.
                pane.appearance = editor.effectiveAppearance
                pane.viewDidChangeEffectiveAppearance()
                let sameProfile = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                sameProfile.text = editor.text
                sameProfile.resetUndoHistory()
                sameProfile.setSavePoint()
                let otherProfile = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                otherProfile.text = "import os\n"
                otherProfile.resetUndoHistory()
                otherProfile.setSavePoint()
                check(controller.apply(identifier: "python", to: otherProfile), "fixture: a Python document")
                let otherBefore = look(otherProfile)
                var installs: [String] = []
                let fanout = LanguageController(
                    editorProvider: { pane }, languageProvider: { user.id }, setLanguage: { installs.append($0) },
                    bundledCatalog: bundledURL)
                fanout.siblingViews = { view in
                    [editor, pane].contains { $0 === view } ? [editor, pane].filter { $0 !== view } : []
                }
                fanout.openDocuments = { [(user.id, editor), (user.id, sameProfile), ("python", otherProfile)] }
                custom.profiles[index].styles[styleIndex].fontSize = 23.5
                custom.profiles[index].styles[styleIndex].foreground = "AB3456"
                try fanout.persist(custom)
                let revisions = [editor, pane, sameProfile, otherProfile].map(\.revision)
                fanout.reapply([user.id])
                let expectedRed = CGFloat(0xAB) / 255
                check(
                    [editor, pane, sameProfile].allSatisfy {
                        abs(look($0).size - 23.5) < 0.01 && abs(look($0).red - expectedRed) < 0.005
                    }, "a saved style change reaches both panes and another document on the profile")
                check(
                    look(otherProfile) == otherBefore,
                    "a document on a different profile keeps its lexer and styles after a re-apply")
                check(
                    [editor, pane, sameProfile, otherProfile].map(\.revision) == revisions
                        && ![editor, sameProfile, otherProfile].contains { $0.modified },
                    "re-applying a profile to every view never edits a document")
                // Choosing a language in one pane restyles the other pane from it.
                let chooser = fanout.menu().items.first { ($0.representedObject as? String) == "python" }!
                check(
                    NSApp.sendAction(chooser.action!, to: chooser.target, from: chooser) && installs == ["python"],
                    "fixture: Python chosen from the Language menu with the second pane current")
                check(
                    look(editor) == look(pane) && abs(look(editor).size - 23.5) > 0.01,
                    "a language chosen in one pane gives both panes the new profile's styles")
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    editor.appearance = NSAppearance(named: appearance)
                    pane.appearance = NSAppearance(named: appearance)
                    editor.viewDidChangeEffectiveAppearance()
                    pane.viewDidChangeEffectiveAppearance()
                    check(
                        look(editor) == look(pane) && abs(look(editor).size - 23.5) > 0.01,
                        "profile propagation keeps both panes' styles in \(appearance.rawValue)")
                }
                pane.appearance = NSAppearance(named: .aqua)
                pane.viewDidChangeEffectiveAppearance()
                check(
                    look(editor).size == look(pane).size && look(editor).red > look(pane).red + 0.5,
                    "a copied dynamic profile resolves its colour for each pane's own appearance")
                pane.appearance = editor.effectiveAppearance
                pane.viewDidChangeEffectiveAppearance()
                check(
                    fanout.applyToDocument(identifier: user.id, through: editor), "fixture: back on the user language")
                custom.profiles[index].styles[styleIndex].fontSize = 19.25
                custom.profiles[index].styles[styleIndex].foreground = "123456"
                try controller.persist(custom)
                _ = controller.apply(identifier: user.id, to: editor)
            }
            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 180), styleMask: [.titled], backing: .buffered,
                defer: false)
            let fontField = NSTextField(string: chosenFont), sizeField = NSTextField(string: "12")
            fontField.frame = NSRect(x: 20, y: 100, width: 300, height: 24)
            sizeField.frame = NSRect(x: 20, y: 50, width: 300, height: 24)
            settingsWindow.contentView?.addSubview(fontField)
            settingsWindow.contentView?.addSubview(sizeField)
            settingsWindow.makeFirstResponder(sizeField)
            (settingsWindow.firstResponder as? NSTextView)?.string = "21.5"
            let read = try LanguageController.readStyle(
                custom.profiles[index].styles[styleIndex], font: fontField, size: sizeField, color: .red, custom: true,
                bold: false, italic: false, window: settingsWindow)
            check(
                read.fontName == chosenFont && read.fontSize == 21.5 && read.foreground == "FF0000",
                "focused shared size field commits independently of font name")
            let styledRestored = LanguageController(
                editorProvider: { editor }, languageProvider: { user.id }, setLanguage: { _ in },
                bundledCatalog: bundledURL)
            check(styledRestored.catalog == custom, "font and color preferences persist exactly")
            // F220: applying a profile lexes the document once, with the final lists and properties.
            typealias ScintillaMessage = @convention(c) (AnyObject, Selector, UInt32, UInt, Int) -> Int
            let
                lexWindow = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                    defer: false), lexEditor = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            lexWindow.contentView = lexEditor
            let native = lexEditor.subviews.first!, messageSelector = NSSelectorFromString("message:wParam:lParam:")
            let send = unsafeBitCast(native.method(for: messageSelector), to: ScintillaMessage.self)
            func sci(_ message: UInt32, _ w: UInt = 0, _ l: Int = 0) -> Int {
                send(native, messageSelector, message, w, l)
            }
            let SCI_GETLENGTH: UInt32 = 2006, SCI_GETSTYLEAT: UInt32 = 2010, SCI_GETENDSTYLED: UInt32 = 2028,
                SCI_COLOURISE: UInt32 = 4003
            func timed(_ work: () -> Void) -> Double {
                let start = ProcessInfo.processInfo.systemUptime
                work()
                return ProcessInfo.processInfo.systemUptime - start
            }
            let lexLine = "alignas alignof value = 42; // note\n",
                lexSource = String(repeating: lexLine, count: 2 * 1024 * 1024 / lexLine.utf8.count)
            lexEditor.text = lexSource
            lexEditor.resetUndoHistory()
            lexEditor.setSavePoint()
            let lexRevision = lexEditor.revision
            lexEditor.setLanguage("cpp")
            let before = (0..<3).map { _ in timed { _ = sci(SCI_COLOURISE, 0, -1) } }.min()!
            var applied = false
            let applyTime = timed { applied = controller.apply(identifier: "cpp", to: lexEditor) }
            check(
                applied && lexEditor.text == lexSource && lexEditor.revision == lexRevision && !lexEditor.modified,
                "C++ profile applies to a 2 MiB buffer without editing it")
            check(
                sci(SCI_GETLENGTH) == lexSource.utf8.count && sci(SCI_GETENDSTYLED) == lexSource.utf8.count,
                "document is fully styled when apply returns")
            let lastLine = lexSource.utf8.count - lexLine.utf8.count
            check(
                sci(SCI_GETSTYLEAT, 0) == 16 && sci(SCI_GETSTYLEAT, 8) == 5 && sci(SCI_GETSTYLEAT, UInt(lastLine)) == 16
                    && sci(SCI_GETSTYLEAT, UInt(lastLine + 8)) == 5,
                "apply styles with the profile's final keyword lists from first line to last")
            let sample = min(lexSource.utf8.count, 200_000),
                appliedStyles = (0..<sample).map { sci(SCI_GETSTYLEAT, UInt($0)) }
            let after = (0..<3).map { _ in timed { _ = sci(SCI_COLOURISE, 0, -1) } }.min()!
            check(
                (0..<sample).map { sci(SCI_GETSTYLEAT, UInt($0)) } == appliedStyles,
                "styles after apply equal a fresh full pass with the final configuration")
            let onePass = max(before, after)
            check(
                applyTime < 3 * onePass,
                "applying a profile costs about one lexing pass (apply \(String(format:"%.3f",applyTime)) s, one pass \(String(format:"%.3f",onePass)) s)"
            )
            check(
                controller.apply(identifier: "python", to: lexEditor) && sci(SCI_GETSTYLEAT, 0) == 11
                    && sci(SCI_GETSTYLEAT, UInt(lastLine + 8)) == 11 && sci(SCI_GETENDSTYLED) == lexSource.utf8.count
                    && lexEditor.revision == lexRevision,
                "switching profile replaces the previous lexer's styles across the whole document")
            // F248: the number of profiles that load is asserted, not only printed. A Lexilla upgrade
            // that gains or loses a lexer fails here on purpose; update the literal in the same change.
            let expectedMissing: Set<String> = ["objc", "searchResult"]
            if !check(
                Set(missing) == expectedMissing && missing.count == expectedMissing.count,
                "exactly the known profiles have no linked lexer")
            {
                print("NOTE missing profiles: \(missing)")
            }
            check(
                supported == catalog.profiles.count - expectedMissing.count && catalog.profiles.count == 96,
                "every other catalog profile applies (\(supported) of \(catalog.profiles.count))")
            func message(_ target: TTEditor, _ number: UInt32, _ w: UInt = 0, _ l: Int = 0) -> Int {
                let view = target.subviews.first!
                return unsafeBitCast(view.method(for: messageSelector), to: ScintillaMessage.self)(
                    view, messageSelector, number, w, l)
            }
            func styles(_ target: TTEditor) -> [Int] {
                (0..<target.text.utf8.count).map { message(target, SCI_GETSTYLEAT, UInt($0)) }
            }
            var hosts: [NSWindow] = []
            func hostedEditor() -> TTEditor {
                let
                    host = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                        backing: .buffered, defer: false),
                    made = TTEditor(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
                host.contentView = made
                hosts.append(host)
                return made
            }
            // A keyword of each high-use language is styled differently from a plain identifier, so a
            // lexer that silently became the null lexer, or lost its keyword list, is caught.
            let families = hostedEditor()
            for (id, keyword) in [
                ("cpp", "return"), ("python", "return"), ("javascript", "return"), ("java", "if"), ("swift", "class"),
                ("rust", "as"), ("sql", "abs"), ("bash", "alias"), ("json", "true")
            ] {
                families.text = "\(keyword) zzzplain\n"
                let applied = controller.apply(identifier: id, to: families)
                let keywordStyle = message(families, SCI_GETSTYLEAT, 0),
                    plainStyle = message(families, SCI_GETSTYLEAT, UInt(keyword.utf8.count + 1))
                if !check(
                    applied && keywordStyle != plainStyle && keywordStyle != 0,
                    "\(id): a keyword is styled apart from a plain identifier")
                {
                    print("NOTE \(id) keyword style \(keywordStyle), plain style \(plainStyle)")
                }
            }
            // G330: the TextTank-authored parts of the user-defined-language lexer. Expected styles
            // are Notepad++'s UDL 2.1 behaviour: style 4 is KEYWORDS1, 13 FOLDER IN CODE1, 1 COMMENTS.
            let SCI_GETFOLDLEVEL: UInt32 = 2223, foldHeader = 0x2000, foldBase = 0x400, keyword1 = 4
            func userProfile(
                _ name: String, keywords: [String: String], prefix: [String: String] = [:],
                nesting: [String: Int] = [:]
            ) throws
                -> LanguageProfile
            {
                let language = UserDefinedLanguage(
                    name: name, extensions: "sample", version: "2.1",
                    global: ["caseIgnored": "no", "forcePureLC": "0", "decimalSeparator": "0"], prefix: prefix,
                    keywords: keywords,
                    styles: [
                        .init(name: "DEFAULT", attributes: ["fgColor": "000000", "fontStyle": "0"]),
                        .init(name: "KEYWORDS1", attributes: ["fgColor": "0000FF", "fontStyle": "1"])
                    ]
                        + nesting.sorted { $0.key < $1.key }.map {
                            .init(name: $0.key, attributes: ["fgColor": "008000", "nesting": String($0.value)])
                        })
                let made = try language.profile()
                var next = try requireValue(controller.catalog, "fixture: catalog")
                next.profiles.removeAll { $0.id == made.id }
                next.profiles.append(made)
                try controller.persist(next)
                return made
            }
            let prefixed = try userProfile("Pin prefix", keywords: ["Keywords1": "pre"], prefix: ["Keywords1": "yes"]),
                exact = try userProfile("Pin exact", keywords: ["Keywords1": "pre"])
            let udlEditor = hostedEditor()
            udlEditor.text = "prefix pre other"
            check(
                controller.apply(identifier: prefixed.id, to: udlEditor)
                    && styles(udlEditor)[0..<6].allSatisfy { $0 == keyword1 }
                    && styles(udlEditor)[7..<10].allSatisfy { $0 == keyword1 } && styles(udlEditor)[11] != keyword1,
                "prefix-mode keyword styles every word that starts with it")
            check(
                controller.apply(identifier: exact.id, to: udlEditor) && styles(udlEditor)[0] != keyword1
                    && styles(udlEditor)[7..<10].allSatisfy { $0 == keyword1 },
                "without prefix mode a keyword matches only the whole word")
            let multipart = try userProfile("Pin multi-part", keywords: ["Keywords1": "'else if'"])
            udlEditor.text = "else if x else y"
            let multipartApplied = controller.apply(identifier: multipart.id, to: udlEditor),
                multipartStyles = styles(udlEditor)
            if !check(
                multipartApplied && multipartStyles[0..<7].allSatisfy { $0 == keyword1 }
                    && multipartStyles[10..<14].allSatisfy { $0 != keyword1 },
                "a quoted multi-part keyword matches only the whole sequence, including its space")
            {
                print("NOTE multi-part styles \(multipartStyles)")
            }
            let folding = try userProfile(
                "Pin folding", keywords: ["Folders in code1, open": "begin", "Folders in code1, close": "end"])
            udlEditor.text = "begin\n  body\nend\nplain\n"
            let foldApplied = controller.apply(identifier: folding.id, to: udlEditor)
            let levels = (0..<4).map { message(udlEditor, SCI_GETFOLDLEVEL, UInt($0)) }
            if !check(
                foldApplied && levels[0] & foldHeader != 0 && levels[0] & 0xFFF == foldBase
                    && levels[1] & 0xFFF == foldBase + 1 && levels[1] & foldHeader == 0 && levels[3] & 0xFFF == foldBase
                    && levels[3] & foldHeader == 0 && styles(udlEditor)[0] == 13,
                "fold open and close keywords make a fold header and a nested body")
            {
                print("NOTE fold levels \(levels.map{String($0,radix:16)}) style \(styles(udlEditor)[0])")
            }
            // An edit followed by an incremental restyle gives the same styles as lexing the result afresh.
            let incremental = try userProfile(
                "Pin incremental",
                keywords: [
                    "Keywords1": "hello", "Comments": "00// 01 02 03/* 04*/", "Folders in code1, open": "begin",
                    "Folders in code1, close": "end"
                ])
            let live = hostedEditor(), fresh = hostedEditor()
            live.text = "hello one\nbegin /* open\nstill comment */ hello\nend hello // tail\nhello last\n"
            check(
                controller.apply(identifier: incremental.id, to: live)
                    && message(live, SCI_GETENDSTYLED) == live.text.utf8.count,
                "fixture: multi-line UDL document is fully styled")
            for (offset, insertion) in [(10, "hello "), (31, "/* reopened\n"), (0, "// "), (3, "\n")] {
                _ = live.setSelectionAnchor(offset, caret: offset)
                live.replaceSelection(insertion)
                _ = message(live, SCI_COLOURISE, UInt(message(live, SCI_GETENDSTYLED)), -1)
                fresh.text = live.text
                _ = controller.apply(identifier: incremental.id, to: fresh)
                let liveLevels = (0..<7).map { message(live, SCI_GETFOLDLEVEL, UInt($0)) },
                    freshLevels = (0..<7).map { message(fresh, SCI_GETFOLDLEVEL, UInt($0)) }
                if !check(
                    styles(live) == styles(fresh) && liveLevels == freshLevels && styles(live).contains(keyword1)
                        && styles(live).contains(1),
                    "incremental restyle after inserting \(insertion.debugDescription) at \(offset) equals a full relex"
                ) {
                    print("NOTE live \(styles(live))\nNOTE fresh \(styles(fresh))")
                }
            }
            // Two documents with different UDLs, lexed alternately, keep their own keyword lists. The
            // fixtures end with a line break on purpose: a keyword that is the very last word of a
            // document with no final line break is left unstyled. The lexing loop that decides it is
            // byte for byte the pinned upstream one (see LexUser.patch), so it is recorded as a
            // limitation in PROVENANCE.json and neither pinned nor called a port defect here.
            let alpha = try userProfile("Pin alpha", keywords: ["Keywords1": "alpha"]),
                beta = try userProfile("Pin beta", keywords: ["Keywords1": "beta"])
            let editorA = hostedEditor(), editorB = hostedEditor()
            editorA.text = "alpha beta\n"
            editorB.text = "alpha beta\n"
            check(
                controller.apply(identifier: alpha.id, to: editorA)
                    && controller.apply(identifier: beta.id, to: editorB), "fixture: two UDL lexers coexist")
            var separate = true
            for _ in 0..<3 {
                _ = message(editorA, SCI_COLOURISE, 0, -1)
                _ = message(editorB, SCI_COLOURISE, 0, -1)
                separate =
                    separate && styles(editorA)[0] == keyword1 && styles(editorA)[6] != keyword1
                    && styles(editorB)[0] != keyword1 && styles(editorB)[6] == keyword1
            }
            check(separate, "two coexisting user lexers keep separate keyword lists when lexed alternately")
            let alphaChanged = try userProfile("Pin alpha", keywords: ["Keywords1": "beta gamma"])
            check(
                alphaChanged.id == alpha.id && controller.apply(identifier: alpha.id, to: editorA)
                    && styles(editorA)[0] != keyword1 && styles(editorA)[6] == keyword1,
                "a changed keyword list restyles a live user lexer")
            _ = message(editorB, SCI_COLOURISE, 0, -1)
            check(
                styles(editorB)[0] != keyword1 && styles(editorB)[6] == keyword1 && editorA.text == "alpha beta\n",
                "changing one user lexer's keywords leaves the other lexer and the text alone")
            editorA.setLanguage("null")
            _ = message(editorB, SCI_COLOURISE, 0, -1)
            check(styles(editorB)[6] == keyword1, "releasing one user lexer leaves the other's keyword cache intact")
            // ---- Package 19: the user-defined-language lexer port ----
            // G328: a multi-part keyword goes ahead of its own prefixes in its list, on every lex.
            // `e ea else "else if"` is the order the old sort comparator contradicted itself on.
            let keyword2 = 5, SCI_POSITIONFROMLINE: UInt32 = 2167
            func settled(_ target: TTEditor) -> [Int] {
                _ = message(target, SCI_COLOURISE, UInt(message(target, SCI_GETENDSTYLED)), -1)
                return styles(target)
            }
            let orderSource = "else if x\nelse y\nelse iffy z\nfiller\nelse if q\n"
            for (mode, prefix) in [("whole-word", [String: String]()), ("prefix", ["Keywords1": "yes"])] {
                let ordered = try userProfile(
                    "Pin order \(mode)", keywords: ["Keywords1": "else \"else if\" e ea", "Keywords2": "if"],
                    prefix: prefix)
                let full = hostedEditor(), edited = hostedEditor()
                full.text = orderSource
                let fullApplied = controller.apply(identifier: ordered.id, to: full), fullStyles = styles(full)
                // Upstream's rule for a prefixed multi-part keyword: the word after it belongs to
                // the match ("else if nextWord"), so the match is nine bytes long instead of seven.
                let extent = prefix.isEmpty ? 7 : 9
                if !check(
                    fullApplied && fullStyles[0..<extent].allSatisfy { $0 == keyword1 }
                        && fullStyles[extent] != keyword1 && !fullStyles[0..<extent].contains(keyword2),
                    "\(mode): 'else if' is one multi-part KEYWORDS1 match, not a prefix and a KEYWORDS2 word")
                {
                    print("NOTE \(mode) full styles \(fullStyles)")
                }
                check(
                    fullStyles[10..<14].allSatisfy { $0 == keyword1 } && fullStyles[14] != keyword1
                        && fullStyles[15] != keyword1,
                    "\(mode): a lone 'else' is KEYWORDS1 and the word after it is not")
                // "else iffy": the second part must be the whole word "if", so only "else" matches.
                if !check(
                    fullStyles[17..<21].allSatisfy { $0 == keyword1 } && fullStyles[21] != keyword1
                        && fullStyles[22..<26].allSatisfy { $0 != keyword1 && $0 != keyword2 },
                    "\(mode): 'else iffy' is not a multi-part match")
                {
                    print("NOTE \(mode) full styles \(fullStyles)")
                }
                // The same text, reached by an edit on the last line: Scintilla relexes from that
                // line, so the lexer starts past offset 0 and must use the same keyword order.
                edited.text = "else if x\nelse y\nelse iffy z\nfiller\nelse i q\n"
                _ = controller.apply(identifier: ordered.id, to: edited)
                let lastLine = message(edited, SCI_POSITIONFROMLINE, 4)
                _ = edited.setSelectionAnchor(lastLine + 6, caret: lastLine + 6)
                edited.replaceSelection("f")
                let editedStyles = settled(edited)
                if !check(
                    edited.text == orderSource && lastLine > 0 && editedStyles == fullStyles
                        && editedStyles[lastLine..<(lastLine + extent)].allSatisfy { $0 == keyword1 },
                    "\(mode): an incremental relex of the last line orders keywords as a full lex does")
                {
                    print("NOTE \(mode) full \(fullStyles)\nNOTE \(mode) edited \(editedStyles)")
                }
            }
            // The reorder's "seen a multi-part word" flag is shared by all fifteen lists, as upstream:
            // a plain prefix pair in one list and a multi-part keyword in another both keep working.
            let crossList = try userProfile(
                "Pin cross-list order", keywords: ["Keywords1": "for foreach", "Keywords2": "end \"end if\""])
            let crossFull = hostedEditor(), crossEdited = hostedEditor()
            crossFull.text = "for foreach x\nend if y\nend z\nfor foreach end if\n"
            crossEdited.text = "for foreach x\nend if y\nend z\nfor foreach end i\n"
            let crossApplied = controller.apply(identifier: crossList.id, to: crossFull),
                crossStyles = styles(crossFull)
            _ = controller.apply(identifier: crossList.id, to: crossEdited)
            let crossEnd = crossEdited.text.utf8.count - 1
            _ = crossEdited.setSelectionAnchor(crossEnd, caret: crossEnd)
            crossEdited.replaceSelection("f")
            if !check(
                crossApplied && crossStyles[0..<3].allSatisfy { $0 == keyword1 }
                    && crossStyles[4..<11].allSatisfy { $0 == keyword1 } && crossStyles[12] != keyword1
                    && crossStyles[14..<20].allSatisfy { $0 == keyword2 } && crossStyles[21] != keyword2
                    && crossStyles[23..<26].allSatisfy { $0 == keyword2 } && settled(crossEdited) == crossStyles,
                "a prefix pair in one list and a multi-part keyword in another style alike on full and incremental lexes"
            ) {
                print("NOTE cross-list full \(crossStyles)\nNOTE cross-list edited \(styles(crossEdited))")
            }
            // G329: the lexer keeps its reordered lists between lexes, so they must follow every
            // change to a list. Keywords1 is word list 7 of the user lexer.
            let SCI_SETKEYWORDS: UInt32 = 4005, keywords1List: UInt = 7
            func setKeywords(_ target: TTEditor, _ list: UInt, _ words: String) {
                words.withCString { _ = message(target, SCI_SETKEYWORDS, list, Int(bitPattern: $0)) }
                _ = message(target, SCI_COLOURISE, 0, -1)
            }
            let liveLists = hostedEditor()
            liveLists.text = "alpha beta gamma delta\n"
            _ = controller.apply(identifier: alpha.id, to: liveLists)
            setKeywords(liveLists, keywords1List, "alpha beta delta epsilon zeta eta theta")
            let longList = styles(liveLists)
            setKeywords(liveLists, keywords1List, "gamma")
            let shortList = styles(liveLists)
            setKeywords(liveLists, keywords1List, "gamma")
            let sameList = styles(liveLists)
            setKeywords(liveLists, keywords1List, "")
            let emptyList = styles(liveLists)
            if !check(
                longList[0..<5].allSatisfy { $0 == keyword1 } && longList[6..<10].allSatisfy { $0 == keyword1 }
                    && longList[11..<16].allSatisfy { $0 != keyword1 }
                    && longList[17..<22].allSatisfy { $0 == keyword1 }
                    && shortList[0..<10].allSatisfy { $0 != keyword1 }
                    && shortList[11..<16].allSatisfy { $0 == keyword1 }
                    && shortList[17..<22].allSatisfy { $0 != keyword1 } && sameList == shortList
                    && !emptyList.contains(keyword1),
                "a live user lexer follows its keyword list when it is replaced by a shorter one, set again and emptied"
            ) {
                print("NOTE long \(longList)\nNOTE short \(shortList)\nNOTE same \(sameList)\nNOTE empty \(emptyList)")
            }
            // Lexing one line must not depend on how many keywords the language has: the lists are
            // prepared when they change, not on every lex, and the first-letter lookup is a table.
            let manyWords = (0..<10_000).map { "kw\(String($0, radix: 36))x" }.joined(separator: " "),
                bigLists = try userProfile("Pin many keywords", keywords: ["Keywords1": manyWords + " hello"]),
                smallLists = try userProfile("Pin few keywords", keywords: ["Keywords1": "hello"])
            let bigEditor = hostedEditor(), smallEditor = hostedEditor()
            let costSource = String(repeating: "zeta hello yotta\n", count: 40)
            bigEditor.text = costSource
            smallEditor.text = costSource
            let costApplied =
                controller.apply(identifier: bigLists.id, to: bigEditor)
                && controller.apply(identifier: smallLists.id, to: smallEditor)
            let costLine = UInt(message(bigEditor, SCI_POSITIONFROMLINE, 39))
            func relexCost(_ target: TTEditor) -> Double {
                (0..<3).map { _ in timed { for _ in 0..<100 { _ = message(target, SCI_COLOURISE, costLine, -1) } } }
                    .min()!
            }
            let bigCost = relexCost(bigEditor), smallCost = relexCost(smallEditor)
            check(
                costApplied && styles(bigEditor) == styles(smallEditor)
                    && styles(bigEditor)[5..<10].allSatisfy { $0 == keyword1 }
                    && bigCost < 20 * smallCost + 0.02,
                "relexing a line costs the same with 10,000 keywords as with one (\(String(format:"%.4f",bigCost)) s against \(String(format:"%.4f",smallCost)) s for 100 lexes)"
            )
            // G332: the nesting property of a style is read under the key the Swift side writes,
            // userDefine.nesting.NN, for one-digit (COMMENTS is 1) and two-digit (DELIMITERS1 is 16) ids.
            let nestingKeywords = [
                "Keywords1": "hello", "Comments": "00// 01 02 03/* 04*/",
                "Delimiters": "00\" 01\\ 02\" 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23"
            ]
            let
                nested = try userProfile(
                    "Pin nesting", keywords: nestingKeywords, nesting: ["COMMENTS": 0x400, "DELIMITERS1": 0x400]),
                flat = try userProfile("Pin no nesting", keywords: nestingKeywords)
            let nestEditor = hostedEditor()
            nestEditor.text = "/* hello there */ \"hello there\" hello\n"
            let nestedApplied = controller.apply(identifier: nested.id, to: nestEditor),
                nestedStyles = styles(nestEditor)
            let flatApplied = controller.apply(identifier: flat.id, to: nestEditor), flatStyles = styles(nestEditor)
            if !check(
                nested.properties["userDefine.nesting.01"] == "1024"
                    && nested.properties["userDefine.nesting.16"] == "1024" && nestedApplied && flatApplied
                    && nestedStyles[3..<8].allSatisfy { $0 == keyword1 } && nestedStyles[9..<14].allSatisfy { $0 == 1 }
                    && nestedStyles[19..<24].allSatisfy { $0 == keyword1 }
                    && nestedStyles[25..<30].allSatisfy { $0 == 16 } && flatStyles[3..<8].allSatisfy { $0 == 1 }
                    && flatStyles[19..<24].allSatisfy { $0 == 16 } && flatStyles[32..<37].allSatisfy { $0 == keyword1 },
                "a keyword nested in a comment and in a delimiter is styled only when that style's nesting allows it")
            {
                print("NOTE nested \(nestedStyles)\nNOTE flat \(flatStyles)")
            }
            // G334: the lexer describes itself accurately, and its property plumbing is the lexer's own.
            let SCI_GETLEXER: UInt32 = 4002, SCI_SETPROPERTY: UInt32 = 4004, SCI_GETPROPERTY: UInt32 = 4008,
                SCI_GETLEXERLANGUAGE: UInt32 = 4012, SCI_DESCRIBEKEYWORDSETS: UInt32 = 4017
            func lexerText(_ target: TTEditor, _ number: UInt32, _ key: String? = nil) -> String {
                func fetch(_ w: UInt) -> String {
                    let size = message(target, number, w, 0)
                    var buffer = [CChar](repeating: 0, count: max(size, 0) + 1)
                    return buffer.withUnsafeMutableBufferPointer {
                        _ = message(target, number, w, Int(bitPattern: $0.baseAddress))
                        return String(cString: $0.baseAddress!)
                    }
                }
                guard let key else { return fetch(0) }
                return key.withCString { fetch(UInt(bitPattern: $0)) }
            }
            func setProperty(_ target: TTEditor, _ key: String, _ value: String) {
                key.withCString { k in
                    value.withCString { v in
                        _ = message(target, SCI_SETPROPERTY, UInt(bitPattern: k), Int(bitPattern: v))
                    }
                }
            }
            let described = hostedEditor()
            described.text = "begin\n  body\nend\n"
            _ = controller.apply(identifier: folding.id, to: described)
            let wordSets = lexerText(described, SCI_DESCRIBEKEYWORDSETS).split(separator: "\n").map(String.init)
            if !check(
                wordSets.count == 15 && wordSets[7] == "Keywords1" && wordSets[14] == "Keywords8"
                    && wordSets[0] == "Operators2" && wordSets[1] == "Folders in code2, open"
                    && Set(wordSets).count == 15
                    && wordSets.allSatisfy { UserDefinedLanguage.keywordNames.contains($0) },
                "the user lexer describes its fifteen word lists by the names the UDL format gives them")
            {
                print("NOTE word list sets \(wordSets)")
            }
            if !check(
                lexerText(described, SCI_GETLEXERLANGUAGE) == "user" && message(described, SCI_GETLEXER) == 152,
                "the user lexer keeps its name and identifier")
            {
                print(
                    "NOTE lexer \(lexerText(described, SCI_GETLEXERLANGUAGE)) \(message(described, SCI_GETLEXER))")
            }
            let cacheName = lexerText(described, SCI_GETPROPERTY, "userDefine.udlName")
            setProperty(described, "userDefine.udlName", "999999")
            setProperty(described, "userDefine.currentBufferID", "999999")
            setProperty(described, "userDefine.foldCompact", "1")
            check(
                Int(cacheName) != nil && lexerText(described, SCI_GETPROPERTY, "userDefine.udlName") == cacheName
                    && lexerText(described, SCI_GETPROPERTY, "userDefine.currentBufferID") == cacheName
                    && lexerText(described, SCI_GETPROPERTY, "userDefine.foldCompact") == "1"
                    && lexerText(described, SCI_GETPROPERTY, "userDefine.isCaseIgnored") == "0"
                    && lexerText(described, SCI_GETPROPERTY, "fold") == "1",
                "user lexer properties read back, and its per-lexer cache ids cannot be overwritten")
            _ = message(described, SCI_COLOURISE, 0, -1)
            let describedLevels = (0..<3).map { message(described, SCI_GETFOLDLEVEL, UInt($0)) }
            check(
                describedLevels[0] & foldHeader != 0 && describedLevels[0] & 0xFFF == foldBase
                    && describedLevels[1] & 0xFFF == foldBase + 1 && describedLevels[1] & foldHeader == 0,
                "fold levels come from the lexing pass itself; the lexer has no separate fold pass")
            // ---- Package 18 ----
            let SCI_STYLEGETFORE: UInt32 = 2481, STYLE_DEFAULT: UInt = 32
            let bundledCatalog = try LanguageCatalog.decode(Data(contentsOf: bundledURL))
            func plainController(_ language: String = "python") -> LanguageController {
                LanguageController(
                    editorProvider: { nil }, languageProvider: { language }, setLanguage: { _ in },
                    bundledCatalog: bundledURL)
            }
            func siblings(_ support: URL) -> [String] {
                ((try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []).sorted()
            }
            func components(_ color: NSColor) -> [Double] {
                let c = color.usingColorSpace(.sRGB)!
                return [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) }
            }
            func close(_ a: [Double], _ b: [Double], _ tolerance: Double = 0.012) -> Bool {
                zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
            }
            func colors(_ target: TTEditor, at offset: Int) -> (text: [Double], back: [Double]) {
                let output = target.attributedText(forSelection: false)
                return (
                    components(output.attribute(.foregroundColor, at: offset, effectiveRange: nil) as! NSColor),
                    components(output.attribute(.backgroundColor, at: offset, effectiveRange: nil) as! NSColor)
                )
            }
            func contrast(_ a: [Double], _ b: [Double]) -> Double {
                func luminance(_ c: [Double]) -> Double {
                    let l = c.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                    return 0.2126 * l[0] + 0.7152 * l[1] + 0.0722 * l[2]
                }
                let x = luminance(a), y = luminance(b)
                return (max(x, y) + 0.05) / (min(x, y) + 0.05)
            }
            // F148: with no bundled catalog there is no silent fallback to the working directory.
            try withIsolatedSupportDirectory("LanguageNoBundle") { _ in
                let orphan = LanguageController(
                    editorProvider: { nil }, languageProvider: { "python" }, setLanguage: { _ in }, bundledCatalog: nil)
                check(
                    orphan.catalog == nil && orphan.loadError != nil && !orphan.storageDamaged
                        && FileManager.default.fileExists(atPath: "Resources/LanguageProfiles.json"),
                    "a missing bundled catalog is an error, not a read from the working directory")
                rejects("nothing is saved without a bundled catalog") { try orphan.persist(bundledCatalog) }
                rejects("there is nothing to move aside when the bundled catalog failed") {
                    try orphan.quarantineDamagedStorage()
                }
            }
            // F76: a stored file that cannot be read leaves the bundled languages working, is never
            // overwritten, and can be moved aside explicitly.
            var customCatalog = bundledCatalog
            customCatalog.profiles[0].title = "Recovered plain language"
            func damagedCase(_ name: String, _ write: (URL) throws -> Void) throws {
                try withIsolatedSupportDirectory("LanguageDamaged") { support in
                    let stored = support.appendingPathComponent("LanguageProfiles.json")
                    try write(stored)
                    let before = try? Data(contentsOf: stored)
                    let damaged = plainController()
                    let probe = hostedEditor()
                    probe.text = "import os\n"
                    check(
                        damaged.loadFailureMessage?.contains(stored.path) == true
                            && plainController("normal").loadFailureMessage != nil,
                        "\(name): the failure is reported with the file's path")
                    check(
                        damaged.catalog == bundledCatalog && damaged.storageDamaged && damaged.loadError != nil
                            && damaged.detect(filename: "a.py", text: "") == "python"
                            && damaged.apply(identifier: "python", to: probe)
                            && damaged.menu().items.contains { ($0.representedObject as? String) == "python" },
                        "\(name): the bundled languages still work")
                    rejects("\(name): persist refuses to write over the unreadable file") {
                        try damaged.persist(customCatalog)
                    }
                    check(
                        (try? Data(contentsOf: stored)) == before && siblings(support) == ["LanguageProfiles.json"],
                        "\(name): the stored file is byte for byte unchanged")
                    let moved = try damaged.quarantineDamagedStorage()
                    let names = siblings(support)
                    check(
                        names.count == 1 && names[0].hasPrefix("LanguageProfiles.damaged-")
                            && names[0] == moved.lastPathComponent && (try? Data(contentsOf: moved)) == before
                            && !damaged.storageDamaged && damaged.loadError == nil,
                        "\(name): the file is moved aside once, under a new name, with its bytes")
                    try damaged.persist(customCatalog)
                    check(
                        damaged.loadFailureMessage == nil && plainController().loadFailureMessage == nil,
                        "\(name): nothing is reported once the file is moved aside")
                    check(
                        plainController().catalog == customCatalog && siblings(support).count == 2
                            && (try? Data(contentsOf: moved)) == before,
                        "\(name): after moving aside, changes save and reload")
                    rejects("\(name): a healthy store cannot be moved aside") {
                        try damaged.quarantineDamagedStorage()
                    }
                }
            }
            try damagedCase("garbage bytes") { try Data([0x00, 0xFF, 0x7B, 0x22]).write(to: $0) }
            try damagedCase("truncated JSON") { try bundledCatalog.encoded().prefix(4000).write(to: $0) }
            try damagedCase("catalog version 2") {
                var future = bundledCatalog
                future.version = 2
                let encoder = JSONEncoder()
                try encoder.encode(future).write(to: $0)
            }
            try damagedCase("file over 16 MiB") {
                try Data(repeating: 0x20, count: 16 * 1024 * 1024 + 1).write(to: $0)
            }
            for late in ["future", "corrupt"] {
                try withIsolatedSupportDirectory("LanguageLate" + late) { support in
                    let controller = plainController(), stored = support.appendingPathComponent("LanguageProfiles.json")
                    try controller.persist(customCatalog)
                    let valid = try Data(contentsOf: stored)
                    let observed =
                        late == "future"
                        ? Data("{\"minimumReaderVersion\":2,".utf8) + valid.dropFirst()
                        : Data("retain corrupt late rewrite".utf8)
                    try observed.write(to: stored)
                    rejects("F198 a deliberate Language reread refuses a newly observed \(late) file") {
                        try controller.persist(customCatalog)
                    }
                    check(
                        try Data(contentsOf: stored) == observed && controller.loadError != nil
                            && controller.storageDamaged,
                        "F198 a newly observed \(late) Language file is retained behind the shared latch")
                }
            }
            try withIsolatedSupportDirectory("LanguageSymlink") { support in
                try withIsolatedSupportDirectory("LanguageSymlinkTarget") { elsewhere in
                    let target = elsewhere.appendingPathComponent("Real.json"),
                        stored = support.appendingPathComponent("LanguageProfiles.json")
                    let targetBytes = try customCatalog.encoded()
                    try targetBytes.write(to: target)
                    try FileManager.default.createSymbolicLink(at: stored, withDestinationURL: target)
                    setenv("TEXTTANK_SUPPORT_DIRECTORY", support.path, 1)
                    let linked = plainController()
                    check(
                        linked.storageDamaged && linked.catalog == bundledCatalog,
                        "a symbolic link in place of the stored file is not followed")
                    rejects("persist refuses to write through a symbolic link") { try linked.persist(customCatalog) }
                    let moved = try linked.quarantineDamagedStorage()
                    try linked.persist(customCatalog)
                    check(
                        (try? Data(contentsOf: target)) == targetBytes
                            && (try? FileManager.default.destinationOfSymbolicLink(atPath: moved.path)) == target.path
                            && (try? FileManager.default.attributesOfItem(atPath: stored.path)[.type]
                                as? FileAttributeType)
                                == .typeRegular,
                        "the link itself is moved aside and its target is never written")
                }
            }
            // F77, G365: what is stored is the user's changes only, and a full copy written by an
            // earlier build keeps every customisation through the move to that format.
            try withIsolatedSupportDirectory("LanguageOverrides") { support in
                let stored = support.appendingPathComponent("LanguageProfiles.json")
                var fork = try requireValue(controller.catalog, "fixture: customised catalog")
                let pythonIndex = try requireValue(fork.profiles.firstIndex { $0.id == "python" }, "fixture: python")
                fork.profiles[pythonIndex].styles[0].foreground = "654321"
                fork.profiles[pythonIndex].styles[0].useCustomColor = true
                fork.profiles[pythonIndex].functionPattern = "(?m)^custom (\\w+)"
                var expected = fork
                // A fork from before `comments` existed, and before a language the app has since gained.
                for index in fork.profiles.indices where fork.profiles[index].udl == nil {
                    fork.profiles[index].comments = nil
                }
                fork.profiles.removeAll { $0.id == "cobol" }
                try fork.encoded().write(to: stored)
                let migrated = plainController()
                check(
                    migrated.loadError == nil && !migrated.storageDamaged && migrated.catalog == expected,
                    "a full-copy LanguageProfiles.json loads with every customisation, missing comments and languages filled in"
                )
                check(
                    migrated.profile(identifier: "python")?.styles[0].foreground == "654321"
                        && migrated.profile(identifier: "python")?.comments?.line == "#"
                        && migrated.profile(identifier: user.id)?.styles.first { $0.name == "KEYWORDS1" }?.fontSize
                            == 19.25
                        && migrated.profile(identifier: "cobol") != nil
                        && migrated.catalog?.profiles[0].title == "My plain language",
                    "edited built-in profiles, imported UDLs and their styles survive migration")
                let fullSize = try Data(contentsOf: stored).count
                let loaded = try requireValue(migrated.catalog, "fixture: migrated catalog")
                try migrated.persist(loaded)
                let written = try Data(contentsOf: stored)
                let overrides = try JSONDecoder().decode(LanguageOverrides.self, from: written)
                check(
                    written.count < fullSize / 4 && overrides.changed.map(\.id) == ["normal", "python"]
                        && overrides.changed[1].keywordLists == nil && overrides.removed.isEmpty
                        && overrides.added.count == loaded.profiles.count - 96
                        && overrides.basedOnSourceCommit == bundledCatalog.sourceCommit,
                    "saving writes only the changes (\(written.count) bytes, was \(fullSize))")
                check(
                    plainController().catalog == loaded
                        && (try? FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? Int)
                            == 0o600,
                    "the changes reload as exactly the same catalog from a private file")
                expected = loaded
                expected.profiles.removeAll { $0.id == "ada" }
                expected.profiles[expected.profiles.firstIndex { $0.id == "python" }!].comments = nil
                try migrated.persist(expected)
                check(
                    plainController().catalog == expected && plainController().profile(identifier: "ada") == nil
                        && plainController().profile(identifier: "python")?.comments == nil,
                    "a deleted built-in profile and removed comment markers stay that way after a restart")
                try FileManager.default.removeItem(at: stored)
                try FileManager.default.copyItem(
                    at: TestPaths.fixtures.appendingPathComponent("persistence/LanguageCatalog.json"), to: stored)
                let goldenProfiles = try LanguageCatalog.decode(Data(contentsOf: stored)).profiles
                let golden = plainController()
                check(
                    golden.loadError == nil && golden.catalog?.profiles.count == 96 + goldenProfiles.count
                        && goldenProfiles.allSatisfy { golden.profile(identifier: $0.id) == $0 },
                    "the golden full-copy catalog loads with its profiles intact over the bundled languages")
                try golden.persist(try requireValue(golden.catalog, "fixture: golden catalog"))
                check(
                    goldenProfiles.allSatisfy { plainController().profile(identifier: $0.id) == $0 }
                        && plainController().catalog?.profiles.count == 96 + goldenProfiles.count,
                    "the golden catalog's profiles survive being saved as overrides")
            }
            // F241, F305: one decode, an indexed lookup, and a menu rebuilt only when the catalog changed.
            let languageMenu = controller.menu(), firstItems = languageMenu.items
            controller.menuNeedsUpdate(languageMenu)
            check(
                languageMenu.items.count == firstItems.count
                    && zip(languageMenu.items, firstItems).allSatisfy { $0 === $1 },
                "the Language menu is not rebuilt while the catalog is unchanged")
            var noTarget: AnyObject?, noAction: Selector?
            let keyDown = try requireValue(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                    context: nil,
                    characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40),
                "fixture: key event")
            check(
                !controller.menuHasKeyEquivalent(languageMenu, for: keyDown, target: &noTarget, action: &noAction)
                    && languageMenu.items.allSatisfy { $0.keyEquivalent.isEmpty },
                "the Language menu has no key equivalents and says so without rebuilding")
            let menuProfile = try userProfile("Pin menu refresh", keywords: ["Keywords1": "menu"])
            check(
                !languageMenu.items.contains { ($0.representedObject as? String) == menuProfile.id },
                "fixture: an open menu object is refreshed by its delegate, not behind its back")
            controller.menuNeedsUpdate(languageMenu)
            check(
                languageMenu.items.contains { ($0.representedObject as? String) == menuProfile.id }
                    && controller.languageMenuItems().map { $0.representedObject as? String }
                        == languageMenu.items.filter { $0.representedObject is String }.map {
                            $0.representedObject as? String
                        },
                "an imported language appears in the Language menu at the next update")
            let styleItem = controller.styleSettingsMenuItem()
            check(
                styleItem.target === controller && styleItem.action == #selector(LanguageController.styleSettings)
                    && styleItem.title == languageMenu.items[3].title,
                "the style settings item is made directly, not found by its title")
            check(
                controller.profile(identifier: menuProfile.id) == menuProfile
                    && controller.profile(identifier: "python")?.id == "python"
                    && controller.profile(identifier: "no-such-language") == nil,
                "profile lookup by identifier follows catalog changes")
            // F22, and the plain-text observation: a profile's lexer gets no C colours, and switching
            // to Plain Text leaves nothing of the previous language behind.
            let scoped = hostedEditor()
            scoped.text = "select zzzname from t\n"
            check(
                controller.apply(identifier: "sql", to: scoped) && message(scoped, SCI_GETSTYLEAT, 7) == 11
                    && message(scoped, SCI_STYLEGETFORE, 11) == message(scoped, SCI_STYLEGETFORE, STYLE_DEFAULT)
                    && message(scoped, SCI_STYLEGETFORE, 5) != message(scoped, SCI_STYLEGETFORE, STYLE_DEFAULT),
                "an SQL identifier has the default colour, not the C keyword colour")
            scoped.text = "def work():\n    return 'text'  # note\n"
            check(
                controller.apply(identifier: "python", to: scoped) && Set(styles(scoped)).count > 3,
                "fixture: Python styles the sample")
            let plainApplied = controller.apply(identifier: LanguageProfile.plainTextID, to: scoped)
            let plainColors = Set((0..<32).map { message(scoped, SCI_STYLEGETFORE, UInt($0)) })
            if !check(
                plainApplied && Set(styles(scoped)) == [0] && plainColors.count == 1
                    && message(scoped, SCI_GETENDSTYLED) == scoped.text.utf8.count,
                "switching to Plain Text removes the previous language's styles and colours")
            {
                print("NOTE plain styles \(Set(styles(scoped))) colours \(plainColors)")
            }
            for id in ["jsp", "json5", "asp"] {
                let sample = id == "json5" ? "{\"key\": 12}\n" : "<p class=\"x\">text</p>\n"
                scoped.text = sample
                let applied = controller.apply(identifier: id, to: scoped)
                let used = Set(styles(scoped))
                check(
                    applied
                        && used.contains {
                            message(scoped, SCI_STYLEGETFORE, UInt($0))
                                != message(scoped, SCI_STYLEGETFORE, STYLE_DEFAULT)
                        },
                    "\(id) is coloured by its own profile styles")
            }
            // F299: adaptive colours are resolved for the editor's own appearance.
            func calibrated(_ r: Double, _ g: Double, _ b: Double) -> [Double] {
                components(NSColor(calibratedRed: r, green: g, blue: b, alpha: 1))
            }
            let darkKeyword = calibrated(0.65, 0.82, 1), lightKeyword = calibrated(0.08, 0.24, 0.55)
            let adaptive = hostedEditor()
            adaptive.text = "return value;\n"
            adaptive.appearance = NSAppearance(named: .aqua)
            check(
                controller.apply(identifier: "cpp", to: adaptive) && message(adaptive, SCI_GETSTYLEAT, 0) == 5
                    && close(colors(adaptive, at: 0).text, lightKeyword),
                "an adaptive keyword colour is the light variant in a light editor")
            adaptive.appearance = NSAppearance(named: .darkAqua)
            adaptive.viewDidChangeEffectiveAppearance()
            check(
                close(colors(adaptive, at: 0).text, darkKeyword),
                "an appearance change re-resolves adaptive colours for the dark editor")
            check(
                controller.apply(identifier: "cpp", to: adaptive) && close(colors(adaptive, at: 0).text, darkKeyword),
                "applying a profile to a dark editor resolves adaptive colours as dark")
            adaptive.appearance = NSAppearance(named: .aqua)
            adaptive.viewDidChangeEffectiveAppearance()
            check(close(colors(adaptive, at: 0).text, lightKeyword), "and back to the light variant")
            // F82: an imported UDL's black default text is readable in both appearances, and its
            // real colours stay exactly as imported.
            let readable = try userProfile("Pin readable", keywords: ["Keywords1": "hello"])
            check(
                readable.styles.first { $0.name == "DEFAULT" }?.useCustomColor == nil
                    && readable.styles.first { $0.name == "KEYWORDS1" }?.useCustomColor == true,
                "fixture: black default text is adaptive, blue keywords are fixed")
            for name in [NSAppearance.Name.darkAqua, .aqua] {
                let themed = hostedEditor()
                themed.appearance = NSAppearance(named: name)
                themed.text = "hello ordinary\n"
                let applied = controller.apply(identifier: readable.id, to: themed)
                let ordinary = colors(themed, at: 6), keyword = colors(themed, at: 0)
                if !check(
                    applied && contrast(ordinary.text, ordinary.back) >= 4.5 && close(keyword.text, [0, 0, 1], 0.004),
                    "imported UDL text is readable and its blue is exact in \(name == .darkAqua ? "dark" : "light") appearance"
                ) {
                    print("NOTE contrast \(contrast(ordinary.text, ordinary.back)) keyword \(keyword.text)")
                }
            }
            // F82: a style edit that leaves "Use custom text color" off keeps an adaptive imported
            // style ordinary text. The name palette would turn this black keyword group blue.
            let monoLanguage = UserDefinedLanguage(
                name: "Pin mono", extensions: "sample", version: "2.1",
                global: ["caseIgnored": "no", "forcePureLC": "0", "decimalSeparator": "0"], prefix: [:],
                keywords: ["Keywords1": "hello"],
                styles: [
                    .init(name: "DEFAULT", attributes: ["fgColor": "000000", "fontStyle": "0"]),
                    .init(name: "KEYWORDS1", attributes: ["fgColor": "000000", "fontStyle": "0"])
                ])
            var mono = try monoLanguage.profile()
            var monoCatalog = try requireValue(controller.catalog, "fixture: catalog")
            monoCatalog.profiles.append(mono)
            try controller.persist(monoCatalog)
            let monoIndex = monoCatalog.profiles.count - 1,
                monoStyle = try requireValue(
                    mono.styles.firstIndex { $0.name == "KEYWORDS1" }, "fixture: keyword style")
            func monoColors(_ name: NSAppearance.Name) -> (keyword: [Double], ordinary: [Double], back: [Double]) {
                let themed = hostedEditor()
                themed.appearance = NSAppearance(named: name)
                themed.text = "hello ordinary\n"
                _ = controller.apply(identifier: mono.id, to: themed)
                return (colors(themed, at: 0).text, colors(themed, at: 6).text, colors(themed, at: 0).back)
            }
            check(
                mono.styles.allSatisfy { $0.useCustomColor == nil }
                    && close(monoColors(.aqua).keyword, monoColors(.aqua).ordinary),
                "fixture: an imported black keyword group is ordinary text")
            let monoSaved = try LanguageController.readStyle(
                mono.styles[monoStyle], font: NSTextField(string: ""), size: NSTextField(string: ""), color: .black,
                custom: false, bold: true, italic: false, window: settingsWindow)
            mono.styles[monoStyle] = monoSaved
            var monoUDL = try requireValue(mono.udl, "fixture: embedded UDL")
            LanguageController.mirror(monoSaved, into: &monoUDL)
            mono.udl = monoUDL
            monoCatalog.profiles[monoIndex] = mono
            try controller.persist(monoCatalog)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let seen = monoColors(name)
                if !check(
                    monoSaved.fontStyle == 1 && close(seen.keyword, seen.ordinary)
                        && contrast(seen.keyword, seen.back) >= 4.5,
                    "a style edit with custom colour off leaves an imported style as text in \(name == .darkAqua ? "dark" : "light") appearance"
                ) {
                    print("NOTE keyword \(seen.keyword) ordinary \(seen.ordinary)")
                }
            }
            mono = try UserDefinedLanguage.decode(monoUDL.encodedXML())[0].profile(preserving: mono)
            monoCatalog.profiles[monoIndex] = mono
            try controller.persist(monoCatalog)
            check(
                mono.styles[monoStyle].useCustomColor != true && mono.styles[monoStyle].fontStyle == 1
                    && close(monoColors(.aqua).keyword, monoColors(.aqua).ordinary)
                    && close(monoColors(.darkAqua).keyword, monoColors(.darkAqua).ordinary),
                "and it is still text after Edit Current UDL regenerates the profile")
            // F22: the embedded-JavaScript profile runs the cpp lexer, so its styles must be numbered
            // for that lexer. Its keyword style is bold italic; the editor's bare C defaults are not.
            let embedded = hostedEditor()
            embedded.text = "return zzzplain\n"
            let SCI_STYLEGETBOLD: UInt32 = 2483, SCI_STYLEGETITALIC: UInt32 = 2484
            check(
                controller.apply(identifier: "javascript", to: embedded) && message(embedded, SCI_GETSTYLEAT, 0) == 5
                    && message(embedded, SCI_STYLEGETBOLD, 5) == 1 && message(embedded, SCI_STYLEGETITALIC, 5) == 1
                    && message(embedded, SCI_STYLEGETBOLD, 11) == 0
                    && colors(embedded, at: 0).text != colors(embedded, at: 7).text,
                "javascript: the profile's own keyword style reaches the cpp lexer")
            // F84: a blank font or size field means "follow the editor", and can be saved and restored.
            let inherit = LanguageProfile.Style(id: 4, name: "KEYWORDS1", foreground: "0000FF", fontStyle: 0)
            func entered(_ original: LanguageProfile.Style, font: String, size: String, bold: Bool = false) throws
                -> LanguageProfile.Style
            {
                try LanguageController.readStyle(
                    original, font: NSTextField(string: font), size: NSTextField(string: size), color: .red,
                    custom: true, bold: bold, italic: false, window: settingsWindow)
            }
            let untouched = try entered(inherit, font: "", size: "", bold: true)
            check(
                untouched.fontName == nil && untouched.fontSize == nil && untouched.fontStyle == 1
                    && untouched.foreground == "FF0000",
                "saving a style with blank font fields keeps it following the editor")
            var pinned = inherit
            pinned.fontName = chosenFont
            pinned.fontSize = 19.25
            let cleared = try entered(pinned, font: "  ", size: "")
            check(
                cleared.fontName == nil && cleared.fontSize == nil,
                "clearing both fields returns a style to the editor font")
            let sizeOnly = try entered(pinned, font: "", size: "16"),
                nameOnly = try entered(pinned, font: chosenFont, size: "")
            check(
                sizeOnly.fontName == nil && sizeOnly.fontSize == 16 && nameOnly.fontName == chosenFont
                    && nameOnly.fontSize == nil, "font name and size can be set independently")
            for (font, size) in [
                ("No Such Font Installed 123", ""), ("", "5"), ("", "abc"), (chosenFont, "73"), ("", "nan")
            ] {
                rejects(
                    "style font \(font.debugDescription) size \(size.debugDescription) is rejected",
                    where: { $0 is LanguageError }
                ) { _ = try entered(pinned, font: font, size: size) }
            }
            var fonts = try requireValue(controller.catalog, "fixture: catalog for font checks")
            let fontProfile = try requireValue(fonts.profiles.firstIndex { $0.id == user.id }, "fixture: styled UDL"),
                fontStyle = try requireValue(
                    fonts.profiles[fontProfile].styles.firstIndex { $0.name == "KEYWORDS1" }, "fixture: styled keyword")
            let fontEditor = hostedEditor()
            fontEditor.text = "HELLO ordinary\n"
            _ = controller.apply(identifier: user.id, to: fontEditor)
            func pointSize(_ target: TTEditor) -> Double {
                Double(
                    (target.attributedText(forSelection: false).attribute(.font, at: 0, effectiveRange: nil) as! NSFont)
                        .pointSize)
            }
            let basePointSize = Double(
                (fontEditor.attributedText(forSelection: false).attribute(.font, at: 6, effectiveRange: nil) as! NSFont)
                    .pointSize)
            check(
                abs(pointSize(fontEditor) - 19.25) < 0.01 && abs(basePointSize - 14) < 0.01,
                "fixture: keyword pinned to 19.25 pt beside 14 pt text")
            let clearedStyle = try entered(fonts.profiles[fontProfile].styles[fontStyle], font: "", size: "")
            fonts.profiles[fontProfile].styles[fontStyle] = clearedStyle
            var mirrored = try requireValue(fonts.profiles[fontProfile].udl, "fixture: embedded UDL")
            mirrored.styles[mirrored.styles.firstIndex { $0.name == "KEYWORDS1" }!].attributes["fontName"] = chosenFont
            mirrored.styles[mirrored.styles.firstIndex { $0.name == "KEYWORDS1" }!].attributes["fontSize"] = "19.25"
            LanguageController.mirror(clearedStyle, into: &mirrored)
            fonts.profiles[fontProfile].udl = mirrored
            try controller.persist(fonts)
            check(
                controller.apply(identifier: user.id, to: fontEditor)
                    && abs(pointSize(fontEditor) - basePointSize) < 0.01,
                "a cleared style renders in the editor's own size again")
            let reimported = try UserDefinedLanguage.decode(mirrored.encodedXML())[0].profile(),
                reimportedKeyword = reimported.styles.first { $0.name == "KEYWORDS1" }
            check(
                reimportedKeyword?.fontName == nil && reimportedKeyword?.fontSize == nil
                    && reimportedKeyword?.foreground == "FF0000" && reimportedKeyword?.useCustomColor == true
                    && mirrored.styles.first { $0.name == "KEYWORDS1" }?.attributes["fontName"] == nil,
                "the cleared font and the colour choice reach the exported UDL and survive re-import")
            var blackChoice = LanguageProfile.Style(
                id: 0, name: "DEFAULT", foreground: "000000", fontStyle: 0, useCustomColor: true)
            LanguageController.mirror(blackChoice, into: &mirrored)
            check(
                try mirrored.profile().styles.first { $0.name == "DEFAULT" }?.useCustomColor == true,
                "an explicit custom black survives regenerating the profile from the UDL")
            blackChoice.useCustomColor = false
            LanguageController.mirror(blackChoice, into: &mirrored)
            check(
                try mirrored.profile().styles.first { $0.name == "DEFAULT" }?.useCustomColor == false,
                "an explicit adaptive choice survives regenerating the profile from the UDL")
            // F97: one picker row per style, in order, whatever the names are.
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28), pullsDown: false)
            LanguageController.populateStylePicker(
                picker,
                styles: ["A", "B", "A", "", ""].enumerated().map {
                    .init(id: $0.offset + 10, name: $0.element, foreground: "000000", fontStyle: 0)
                })
            check(
                picker.numberOfItems == 5 && picker.indexOfSelectedItem == 0,
                "style picker keeps duplicate and empty names as separate rows")
            picker.selectItem(at: 2)
            check(
                picker.indexOfSelectedItem == 2
                    && picker.itemTitles == ["A", "B", "A (style 12)", "Style 13", "Style 14"],
                "the selected row is the style's index (\(picker.itemTitles))")
            Checks.section("F155 Language JSON editor") { try jsonEditorChecks(bundledURL: bundledURL) }
            withExtendedLifetime(hosts) {}
            print(
                "LEXER CONFIGURATION: \(supported) available; missing \(missing). This proves loading and text integrity, not every lexical semantic."
            )
            Checks.summary { "PASS LanguageControllerChecks: \(Checks.count) native assertions" }
        }
    }
}
