// SPDX-License-Identifier: GPL-3.0-or-later
// Audit package 11: split view and one definition of the current editor. These sections run
// inside document-checks after the sections in DocumentPinningChecks.swift and share its
// support directory. The check process has no main window, so "the document window focused
// last" is set directly on the application delegate, as the pinning checks do.
import AppKit

extension DocumentChecks {
    @MainActor static func splitViewAndCurrentEditor(root: URL, app: NSApplication, section: SectionRunner) {
        let zoom: UInt32 = 2374, viewWhitespace: UInt32 = 2020, styleFore: UInt32 = 2481, lexer: UInt32 = 4002
        /// Foreground of every lexer style in one view; views that agree show the same colours.
        @MainActor func palette(_ editor: TTEditor) -> [Int] { (0..<32).map { sci(editor, styleFore, UInt($0)) } }
        @MainActor func opened(_ name: String, _ text: String) throws -> (
            TextDocument, EditorWindowController, NSWindow
        ) {
            let url = root.appendingPathComponent("package-11", isDirectory: true).appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            let document = TextDocument()
            document.fileURL = url
            document.fileType = "Plain Text"
            NSDocumentController.shared.addDocument(document)
            try document.read(from: Data(text.utf8), ofType: "Plain Text")
            document.makeWindowControllers()
            document.showWindows()
            let controller = try requireValue(
                document.windowControllers.first as? EditorWindowController, "fixture: editor window controller")
            return (document, controller, try requireValue(controller.window, "fixture: window"))
        }
        @MainActor func recordOneStep(_ delegate: AppDelegate, in editor: TTEditor) throws {
            delegate.macros.startRecording()
            _ = editor.setSelectionAnchor(0, caret: 0)
            editor.executeCommand("newLine")
        }
        /// Finishes the recording and undoes its one step, so each case starts from the same text.
        @MainActor func finishes(_ delegate: AppDelegate, in editor: TTEditor) -> Bool {
            let macro = try? delegate.macros.finishRecording()
            editor.executeCommand("undo")
            return macro?.steps.isEmpty == false
        }

        // F275, F302, F278
        section("one current editor for every controller", #line) {
            let delegate = AppDelegate()
            app.delegate = delegate
            let (document, controller, _) = try opened("current.txt", "- **2 eggs**\n- plain text\n")
            try require(
                !(NSApp.mainWindow?.windowController is EditorWindowController),
                "fixture: no document window is main in the check process")
            delegate.lastDocumentController = nil
            check(
                delegate.currentEditor == nil && delegate.currentDocument == nil,
                "with no document window focused there is no current editor")
            delegate.lastDocumentController = controller
            check(
                delegate.currentEditor === document.editor && delegate.currentDocument === document
                    && delegate.currentDocumentController === controller,
                "while another window is main, the document window focused last supplies the current editor")
            check(
                delegate.searchController.currentEditor() === document.editor
                    && delegate.utilities.activeEditor() === document.editor
                    && delegate.runner.editor() === document.editor
                    && delegate.workspaceBrowser.currentDocument() === document,
                "search, utilities, Run and the workspace browser resolve the same current editor")
            try recordOneStep(delegate, in: document.editor)
            check(
                finishes(delegate, in: document.editor),
                "Start Recording records in the current editor while another window is main")
            try delegate.automations.persistLibrary(AutomationLibrary(workflows: [.example]))
            try delegate.automations.runSavedAutomation(id: AutomationDefinition.example.id)
            check(
                document.editor.text == "2 eggs\nplain text\n",
                "an editor-output automation runs on the current editor while another window is main")
            document.editor.executeCommand("undo")
            let session = try delegate.workspace.capture(name: "current")
            check(
                session.activeDocumentID == document.recoveryID,
                "a saved session marks the current document as active while another window is main")
            let stray = TextDocument()
            let isolated = WorkspaceController()
            isolated.activeDocument = { stray }
            check(
                try isolated.capture(name: "stray").activeDocumentID == nil,
                "a session never names an active document that is not one of its documents")
            stray.close()

            // Asking for the editor, a failed guard and an export leave a recording alone.
            try recordOneStep(delegate, in: document.editor)
            _ = delegate.utilities.activeEditor()
            _ = delegate.runner.editor()
            _ = try delegate.utilities.exportData(format: "html")
            _ = document.editor.setSelectionAnchor(0, caret: 0)
            rejects("fixture: a text utility without a selection is refused") {
                try delegate.utilities.apply(.base64Encode)
            }
            check(
                finishes(delegate, in: document.editor),
                "asking for the editor, a styled export and a refused utility do not discard a macro recording")
            // Each committed, unrecorded change still does.
            try recordOneStep(delegate, in: document.editor)
            _ = document.editor.setSelectionAnchor(1, caret: 4)
            try delegate.utilities.apply(.base64Encode)
            check(
                !finishes(delegate, in: document.editor),
                "a text utility that changes the document discards the recording")
            document.editor.executeCommand("undo")
            try recordOneStep(delegate, in: document.editor)
            try delegate.automations.runSavedAutomation(id: AutomationDefinition.example.id)
            check(!finishes(delegate, in: document.editor), "running an automation discards the recording")
            document.editor.executeCommand("undo")
            try require(
                document.editor.text == "- **2 eggs**\n- plain text\n", "fixture: the text is back to its start")
            @MainActor func applyButton() throws -> NSButton {
                try requireValue(
                    NSApp.windows.flatMap { ($0.contentView as? NSStackView)?.views ?? [] }.compactMap {
                        $0 as? NSButton
                    }.last { $0.identifier?.rawValue == "run.apply" },
                    "fixture: the Run result window has an Apply button")
            }
            let output = RunResult(
                stdout: Data("RUN OUTPUT".utf8), stderr: Data(), status: 0, cancelled: false, truncated: false)
            try recordOneStep(delegate, in: document.editor)
            delegate.runner.show(
                .success(output), command: .uppercaseSample, target: document.editor,
                revision: document.editor.revision, selection: false, anchor: 0, caret: 0)
            let apply = try applyButton()
            delegate.runner.apply(apply)
            check(
                document.editor.text == "RUN OUTPUT" && !finishes(delegate, in: document.editor),
                "applying a Run extension result discards the recording")
            apply.window?.close()

            document.close()
            check(
                delegate.currentEditor == nil && delegate.currentDocument == nil,
                "after the focused document closes there is no current editor")
            delegate.macros.startRecording()
            check(
                (try? delegate.macros.finishRecording()) == nil, "Start Recording does nothing without a current editor"
            )
            rejects(
                "an editor-output automation without a current editor reports it", message: "requires an open editor"
            ) {
                try delegate.automations.runSavedAutomation(id: AutomationDefinition.example.id)
            }
            check(
                try delegate.workspace.capture(name: "empty").activeDocumentID == nil,
                "a session saved after the focused document closed names no active document")
        }

        // F21, F83, G335, G336, G339, G341
        section("split view keeps document state and copies view state", #line) {
            let delegate = AppDelegate()
            app.delegate = delegate
            var global = EditorSettings()
            global.tabWidth = 8
            global.useTabs = false
            global.wrap = false
            try delegate.settings.save(global)
            defer { try? delegate.settings.save(EditorSettings()) }
            let originalCatalog = try requireValue(delegate.languages.catalog, "fixture: language catalog")
            defer { try? delegate.languages.persist(originalCatalog) }
            let (document, controller, window) = try opened("split.py", "import os\nvalue = 42  # note\n")
            try require(document.languageIdentifier == "python", "fixture: the file opens as Python")
            delegate.lastDocumentController = controller
            // Choices made for this document and this view after it opened.
            document.editor.configureTabWidth(2, useTabs: true)
            for _ in 0..<3 { document.editor.executeCommand("zoomIn") }
            document.editor.executeCommand("showWhitespace")
            document.editor.wrap = true
            let revision = document.editor.revision
            let closeItem = NSMenuItem(
                title: "", action: #selector(EditorWindowController.closeSplit(_:)), keyEquivalent: "")
            let cloneItem = NSMenuItem(
                title: "", action: #selector(EditorWindowController.clone(_:)), keyEquivalent: "")
            check(
                controller.validateMenuItem(cloneItem) && !controller.validateMenuItem(closeItem),
                "without a split, Clone in Split View is enabled and Close Split View is not")
            controller.showFind(nil)
            let findResponder = window.firstResponder
            controller.closeSplit(nil)
            check(
                window.firstResponder === findResponder
                    && (findResponder as? NSView)?.isDescendant(of: document.editor) != true,
                "Close Split View with no split leaves keyboard focus where it was")
            _ = window.makeFirstResponder(document.editor)

            controller.clone(nil)
            let clone = try requireValue(controller.secondary, "fixture: clone view")
            check(
                !controller.validateMenuItem(cloneItem) && controller.validateMenuItem(closeItem),
                "with a split, Close Split View is enabled and Clone in Split View is not")
            check(
                document.editor.statusInfo["tabWidth"]?.intValue == 2
                    && document.editor.statusInfo["useTabs"]?.boolValue == true
                    && clone.statusInfo["tabWidth"]?.intValue == 2 && clone.statusInfo["useTabs"]?.boolValue == true,
                "clone does not reset per-document indentation")
            check(
                sci(clone, zoom) == 3 && sci(document.editor, zoom) == 3 && sci(clone, viewWhitespace) == 1
                    && clone.wrap,
                "a new clone opens with the source view's zoom, whitespace visibility and wrap")
            check(palette(clone) == palette(document.editor), "a new clone shows the source view's syntax colours")
            check(
                document.editor.revision == revision && clone.revision == revision && !document.isDocumentEdited,
                "cloning does not edit the document")
            check(clone.menu != nil, "a new clone has the automation context menu")
            check(
                document.activeEditor === clone && delegate.currentEditor === clone,
                "the focused clone is the document's active view and the current editor")
            check(
                delegate.searchController.openEditors().filter { $0.sharesDocument(with: document.editor) }.count == 1
                    && delegate.searchController.openEditors().contains { $0 === clone },
                "All open documents search receives one view per document: the active one")

            // A language chosen with the clone focused reaches both panes.
            let python = palette(document.editor)
            let cppItem = try requireValue(
                delegate.languages.menu().items.first { ($0.representedObject as? String) == "cpp" },
                "fixture: a C++ item in the Language menu")
            check(
                NSApp.sendAction(cppItem.action!, to: cppItem.target, from: cppItem)
                    && document.languageIdentifier == "cpp",
                "choosing a language with the clone focused sets the document's language")
            check(
                palette(clone) != python && palette(document.editor) == palette(clone),
                "a language chosen in one pane restyles the other pane as well")
            check(
                document.editor.revision == revision && !document.isDocumentEdited,
                "changing the language does not edit the document")
            let rawItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            rawItem.representedObject = "python"
            controller.language(rawItem)
            check(
                palette(document.editor) == palette(clone) && sci(clone, lexer) == sci(document.editor, lexer),
                "a lexer chosen by name in one pane restyles the other pane as well")
            NSApp.sendAction(cppItem.action!, to: cppItem.target, from: cppItem)

            // A style edit reaches every view of every document on that profile, and no other.
            let (sameLanguage, _, _) = try opened("other.cpp", "int other = 1;\n")
            let (otherLanguage, _, _) = try opened("other.py", "import sys\n")
            try require(
                sameLanguage.languageIdentifier == "cpp" && otherLanguage.languageIdentifier == "python",
                "fixture: one more C++ document and one Python document")
            delegate.lastDocumentController = controller
            let untouched = palette(otherLanguage.editor), untouchedLexer = sci(otherLanguage.editor, lexer)
            let otherRevision = otherLanguage.editor.revision
            var edited = originalCatalog
            let profile = try requireValue(edited.profiles.firstIndex { $0.id == "cpp" }, "fixture: C++ profile")
            let style = try requireValue(
                edited.profiles[profile].styles.firstIndex { $0.id == 5 }, "fixture: C++ keyword style")
            edited.profiles[profile].styles[style].foreground = "123456"
            edited.profiles[profile].styles[style].useCustomColor = true
            try delegate.languages.persist(edited)
            delegate.languages.reapply(["cpp"])
            check(
                sci(document.editor, styleFore, 5) == 0x563412 && sci(clone, styleFore, 5) == 0x563412,
                "a saved style change reaches both panes of the current document")
            check(
                sci(sameLanguage.editor, styleFore, 5) == 0x563412,
                "a saved style change reaches other open documents that use the profile")
            check(
                palette(otherLanguage.editor) == untouched && sci(otherLanguage.editor, lexer) == untouchedLexer
                    && otherLanguage.editor.revision == otherRevision,
                "a document on another profile keeps its lexer and styles")
            check(
                !document.isDocumentEdited && !sameLanguage.isDocumentEdited && !otherLanguage.isDocumentEdited
                    && document.editor.revision == revision,
                "re-applying a profile never edits a document")
            sameLanguage.close()
            otherLanguage.close()

            // G337 through the real wiring: a recording started in the clone ends with a reload.
            delegate.lastDocumentController = controller
            _ = window.makeFirstResponder(clone)
            delegate.macros.startRecording()
            clone.executeCommand("newLine")
            try document.reload(using: .utf8, discard: true)
            rejects("reloading the document discards a recording started in its clone", message: "reloaded") {
                _ = try delegate.macros.finishRecording()
            }

            controller.closeSplit(nil)
            check(
                document.activeEditor === document.editor && delegate.searchController.openEditors().count == 1
                    && delegate.searchController.openEditors().first === document.editor,
                "after the split closes the primary view is the document's active view")
            document.close()
        }

        // G338, G342
        section("results captured through a clone survive Close Split View", #line) {
            let delegate = AppDelegate()
            app.delegate = delegate
            let (document, controller, window) = try opened(
                "deferred.py", "def one():\n    pass\n\ndef two():\n    pass\n")
            delegate.lastDocumentController = controller
            // G342: the first view taken out of a document window stays allocated until that window
            // is deallocated. It was reproduced with a bare NSView and no TextTank code in the path
            // (the extra retain is made inside -[NSView _setWindow:]), and the last check of this
            // section shows the view goes with the window. One split is opened and closed first, so
            // the release check below measures only TextTank's own references to a closed clone.
            controller.clone(nil)
            controller.closeSplit(nil)
            @MainActor func applyButton() throws -> NSButton {
                try requireValue(
                    NSApp.windows.flatMap { ($0.contentView as? NSStackView)?.views ?? [] }.compactMap {
                        $0 as? NSButton
                    }.last { $0.identifier?.rawValue == "run.apply" },
                    "fixture: the Run result window has an Apply button")
            }
            let output = RunResult(
                stdout: Data("def three():\n    pass\n".utf8), stderr: Data(), status: 0, cancelled: false,
                truncated: false)
            weak var released: TTEditor?
            var functions: LanguageFunctionController?
            try autoreleasepool {
                controller.clone(nil)
                let clone = try requireValue(controller.secondary, "fixture: clone view")
                released = clone
                let text = clone.text
                let profile = try requireValue(delegate.languages.profile(identifier: "python"), "fixture: profile")
                let symbols = try LanguageFunctions.symbols(text: text, profile: profile)
                try require(symbols.count == 2, "fixture: two functions listed")
                functions = LanguageFunctionController(
                    editor: clone, text: text, revision: clone.revision, symbols: symbols)
                delegate.runner.show(
                    .success(output), command: .uppercaseSample, target: clone, revision: clone.revision,
                    selection: false, anchor: 0, caret: 0)
                controller.closeSplit(nil)
                check(
                    functions?.editor === document.editor,
                    "a Function List opened from the clone follows the document to the primary view")
                let symbol = symbols[1]
                check(
                    LanguageFunctionController.navigate(
                        symbol, text: text, revision: clone.revision, editor: document.editor)
                        && document.editor.selectedText == "two",
                    "a Function List entry captured through the clone still navigates after the split closes")
            }
            let apply = try applyButton()
            check(apply.isEnabled, "a whole-document Run result captured through the clone stays applicable")
            delegate.runner.apply(apply)
            check(
                document.editor.text == "def three():\n    pass\n",
                "Apply Extension Result reaches the document after the split it was captured in closed")
            document.editor.executeCommand("undo")
            apply.window?.close()
            // A result for a selection belongs to the closed view's selection and is dropped.
            try autoreleasepool {
                controller.clone(nil)
                let clone = try requireValue(controller.secondary, "fixture: second clone view")
                _ = clone.setSelectionAnchor(0, caret: 3)
                delegate.runner.show(
                    .success(output), command: .uppercaseSample, target: clone, revision: clone.revision,
                    selection: true, anchor: 0, caret: 3)
                controller.closeSplit(nil)
            }
            let selectionApply = try applyButton()
            let before = document.editor.text
            check(!selectionApply.isEnabled, "a selection Run result captured through the clone is withdrawn")
            delegate.runner.apply(selectionApply)
            check(document.editor.text == before, "a withdrawn selection result changes nothing")
            selectionApply.window?.close()
            functions = nil
            for _ in 0..<10 where released != nil {
                autoreleasepool {
                    window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            check(released == nil, "no controller keeps a closed clone view alive")
            // The whole graph goes when the document closes, including a split closed earlier.
            weak var lateClone: TTEditor?
            weak var lateWindow: NSWindow?
            weak var lateDocument: TextDocument?
            autoreleasepool {
                let other = TextDocument()
                NSDocumentController.shared.addDocument(other)
                other.makeWindowControllers()
                other.showWindows()
                if let otherController = other.windowControllers.first as? EditorWindowController {
                    otherController.clone(nil)
                    lateClone = otherController.secondary
                    otherController.closeSplit(nil)
                    lateWindow = otherController.window
                }
                lateDocument = other
                other.close()
            }
            for _ in 0..<10 where lateClone != nil || lateWindow != nil || lateDocument != nil {
                autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            }
            check(
                lateClone == nil && lateWindow == nil && lateDocument == nil,
                "closing a document releases its window, its views and a clone closed earlier")
            document.close()
        }
    }
}
