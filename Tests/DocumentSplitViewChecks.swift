@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
// Audit package 11: split view and one definition of the current editor. These sections run
// inside document-checks after the sections in DocumentPinningChecks.swift and share its
// support directory. The check process has no main window, so "the document window focused
// last" is set directly on the application delegate, as the pinning checks do.
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

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
            return (document, controller, try requireValue(controller.hostWindow, "fixture: window"))
        }
        @MainActor func recordOneStep(_ delegate: AppDelegate, in editor: TTEditor) throws {
            delegate.macros.startRecording()
            _ = editor.setSelectionAnchor(0, caret: 0)
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "newLine"))
        }
        /// Finishes the recording and undoes its one step, so each case starts from the same text.
        @MainActor func finishes(_ delegate: AppDelegate, in editor: TTEditor) -> Bool {
            let macro = try? delegate.macros.finishRecording()
            editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            return macro?.steps.isEmpty == false
        }

        /// Runs a command that opens app-modal dialogs and answers them in order. Each answer
        /// receives the dialog's views and returns the button to press. A dialog that is not
        /// expected, or not answered within ten seconds, is aborted. True when every answer was used.
        @MainActor func answeringDialogs(
            _ answers: [@MainActor @Sendable ([NSView]) -> NSButton?], _ command: () -> Void
        ) -> Bool {
            var pending = answers
            weak var answered: NSWindow?
            let deadline = Date().addingTimeInterval(10)
            let tick: @MainActor @Sendable () -> Void = {
                guard let modal = presentedFormWindow, modal !== answered || Date() > deadline else { return }
                guard Date() <= deadline, let answer = pending.first, let content = modal.contentView,
                    let button = answer(descendants(content))
                else {
                    NSApp.abortModal()
                    return
                }
                pending.removeFirst()
                answered = modal
                button.performClick(nil)
            }
            let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated { tick() }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            command()
            waitForModelessForms()
            timer.invalidate()
            return pending.isEmpty
        }
        @MainActor func button(_ title: String) -> @MainActor @Sendable ([NSView]) -> NSButton? {
            { views in views.compactMap { $0 as? NSButton }.first { $0.title == title } }
        }

        // F275, F302, F278
        section("one current editor for every controller", #line) {
            let delegate = AppDelegate()
            delegate.installEditorServices()
            let (document, controller, _) = try opened("current.txt", "- **2 eggs**\n- plain text\n")
            // The case F275 is about: an auxiliary titled window (Find and Replace, a Run result)
            // is main. A document window that has just been shown is main whenever the check
            // process happens to be the active application, so the case is set up here and not
            // assumed.
            let auxiliary = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            auxiliary.isReleasedWhenClosed = false
            auxiliary.title = "Auxiliary window"
            defer { auxiliary.close() }
            auxiliary.makeKeyAndOrderFront(nil)
            auxiliary.makeMain()
            try require(
                !(NSApp.mainWindow?.windowController is EditorWindowController),
                "fixture: no document window is main while the auxiliary window is in front")
            delegate.noteActive(nil)
            check(
                delegate.currentEditor === document.editor && delegate.currentDocument === document,
                "the active workspace tab remains current while an auxiliary window is main")
            delegate.noteActive(controller)
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
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            let session = try delegate.workspace.capture(name: "current")
            check(
                session.activeDocumentID == document.recoveryID,
                "a saved session marks the current document as active while another window is main")
            let longName = String(repeating: "s", count: 230)
            let filename = root.appendingPathComponent(longName + "." + WorkspaceStore.sessionFileExtension)
            let longSession = try delegate.workspace.capture(name: filename.deletingPathExtension().lastPathComponent)
            check(
                longSession.name == String(longName.prefix(200)) && longSession.activeDocumentID == document.recoveryID,
                "G358 a valid long session filename yields a 200-character display name without losing document identity"
            )
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
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            try recordOneStep(delegate, in: document.editor)
            try delegate.automations.runSavedAutomation(id: AutomationDefinition.example.id)
            check(!finishes(delegate, in: document.editor), "running an automation discards the recording")
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
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
                stdout: Data("RUN OUTPUT".utf8), stderr: Data(), status: 0, reason: .finished)
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
            delegate.installEditorServices()
            var global = EditorSettings()
            global.tabWidth = 8
            global.useTabs = false
            global.wrap = false
            try delegate.settings.save(global)
            defer { _ = try? delegate.settings.save(EditorSettings()) }
            let originalCatalog = try requireValue(delegate.languages.catalog, "fixture: language catalog")
            defer { try? delegate.languages.persist(originalCatalog) }
            let (document, controller, window) = try opened("split.py", "import os\nvalue = 42  # note\n")
            try require(document.languageIdentifier == "python", "fixture: the file opens as Python")
            // F302: a document window that becomes main is the document window focused last.
            delegate.noteActive(nil)
            window.becomeMain()
            check(
                delegate.lastDocumentController === controller,
                "a document window that becomes main is recorded as the document window focused last")
            if NSApp.mainWindow !== window { window.resignMain() }
            delegate.noteActive(controller)
            let indentTitles = controller.statusOptionsMenu("indent")?.items.map(\.title) ?? []
            let zoomTitles = controller.statusOptionsMenu("font")?.items.map(\.title) ?? []
            check(
                indentTitles.first == "Indentation for this document"
                    && !indentTitles.contains { $0.localizedCaseInsensitiveContains("view") },
                "the status menu says indentation belongs to the document, not to a view")
            check(
                zoomTitles.contains("Text size for this view"),
                "the status menu still says text size belongs to the view")
            // Choices made for this document and this view after it opened.
            document.editor.configureTabWidth(2, useTabs: true)
            for _ in 0..<3 { document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "zoomIn")) }
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "showWhitespace"))
            document.editor.wrap = true
            let revision = document.editor.revision
            let closeItem = NSMenuItem(
                title: "", action: #selector(EditorWindowController.closeSplit(_:)), keyEquivalent: "")
            let cloneItem = NSMenuItem(
                title: "", action: #selector(EditorWindowController.clone(_:)), keyEquivalent: "")
            check(
                controller.validateMenuItem(cloneItem) && cloneItem.state == .off
                    && !controller.validateMenuItem(closeItem),
                "without a split, Clone is enabled and unchecked and Close Split View is disabled")
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
                controller.validateMenuItem(cloneItem) && cloneItem.state == .on
                    && controller.validateMenuItem(closeItem),
                "with a split, Clone stays enabled and checked and Close Split View is enabled")
            check(
                document.editor.statusInfo.tabWidth == 2
                    && document.editor.statusInfo.useTabs == true
                    && clone.statusInfo.tabWidth == 2 && clone.statusInfo.useTabs == true,
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
            let pythonItem = try requireValue(
                delegate.languages.menu().items.first { ($0.representedObject as? String) == "python" },
                "fixture: a Python item in the Language menu")
            check(
                NSApp.sendAction(pythonItem.action!, to: pythonItem.target, from: pythonItem)
                    && document.languageIdentifier == "python", "choosing Python uses the real Language menu path")
            check(
                palette(document.editor) == palette(clone) && sci(clone, lexer) == sci(document.editor, lexer),
                "a language chosen from the menu in one pane restyles the other pane as well")
            NSApp.sendAction(cppItem.action!, to: cppItem.target, from: cppItem)
            let cpp = palette(document.editor)

            // A style edit reaches every view of every document on that profile, and no other.
            let (sameLanguage, _, _) = try opened("other.cpp", "int other = 1;\n")
            let (otherLanguage, _, _) = try opened("other.py", "import sys\n")
            try require(
                sameLanguage.languageIdentifier == "cpp" && otherLanguage.languageIdentifier == "python",
                "fixture: one more C++ document and one Python document")
            delegate.noteActive(controller)
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

            // F83: the dialogs that save a catalog change re-apply it the same way. Each case first
            // gives the clone and the other C++ document a foreign palette, then saves in the dialog.
            document.showWindows()
            delegate.noteActive(controller)
            try require(
                delegate.currentDocument === document && document.languageIdentifier == "cpp",
                "fixture: the split C++ document is the current document")
            @MainActor func scramble() throws {
                clone.adoptSyntaxStyles(from: otherLanguage.editor)
                sameLanguage.editor.adoptSyntaxStyles(from: otherLanguage.editor)
                try require(
                    palette(clone) != palette(document.editor)
                        && palette(sameLanguage.editor) != palette(document.editor),
                    "fixture: the clone and the other C++ document show a foreign palette")
            }
            @MainActor func restyled() -> Bool {
                palette(clone) == palette(document.editor) && palette(sameLanguage.editor) == palette(document.editor)
                    && palette(otherLanguage.editor) == untouched && document.editor.revision == revision
                    && !document.isDocumentEdited && !sameLanguage.isDocumentEdited
            }
            try scramble()
            let styleSaved = answeringDialogs([
                button("Edit"),
                { views in
                    let fields = views.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
                    guard fields.count == 2 else { return nil }
                    fields[0].stringValue = "Menlo"
                    fields[1].stringValue = "13"
                    return button("Save")(views)
                }
            ]) { delegate.languages.styleSettings() }
            check(
                styleSaved && restyled(),
                "Syntax Style Settings, saved, restyles both panes and the other documents on the profile")
            try scramble()
            let profilesSaved = answeringDialogs([button("Save")]) { delegate.languages.configure() }
            check(
                profilesSaved && restyled(),
                "Language Profiles, saved, restyles both panes and the other documents on a changed profile")
            try scramble()
            let profilesCancelled = answeringDialogs([button("Cancel")]) { delegate.languages.configure() }
            check(
                profilesCancelled && palette(clone) != palette(document.editor),
                "Language Profiles, cancelled, re-applies nothing")
            delegate.languages.reapply(["cpp"])
            try require(restyled(), "fixture: the panes agree again")
            var withUDL = try requireValue(delegate.languages.catalog, "fixture: the saved catalog")
            let user = try UserDefinedLanguage(
                name: "Package 11 UDL", extensions: "p11", version: "2.1",
                global: ["caseIgnored": "yes", "forcePureLC": "0", "decimalSeparator": "0"], prefix: [:],
                keywords: ["Keywords1": "int other", "Comments": "00// 01 02 03/* 04*/"],
                styles: [
                    .init(name: "DEFAULT", attributes: ["fgColor": "000000", "fontStyle": "0"]),
                    .init(name: "KEYWORDS1", attributes: ["fgColor": "0000FF", "fontStyle": "1"]),
                    .init(name: "COMMENTS", attributes: ["fgColor": "008000", "fontStyle": "2"])
                ]
            ).profile()
            withUDL.profiles.append(user)
            try delegate.languages.persist(withUDL)
            for target in [document, sameLanguage] {
                try require(
                    delegate.languages.applyToDocument(identifier: user.id, through: target.editor),
                    "fixture: the user-defined language applies")
                target.noteAppliedLanguage(user.id)
            }
            try scramble()
            let editUDL = try requireValue(
                delegate.languages.menu().items.first { $0.title == "Edit Current UDL…" },
                "fixture: the Edit Current UDL command")
            let udlSaved = answeringDialogs([button("Save")]) {
                _ = NSApp.sendAction(editUDL.action!, to: editUDL.target, from: editUDL)
            }
            check(
                udlSaved && restyled(),
                "Edit Current UDL, saved, restyles both panes and the other documents on that language")
            sameLanguage.close()
            otherLanguage.close()

            // G337 through the real wiring: a recording started in the clone ends with a reload.
            delegate.noteActive(controller)
            _ = window.makeFirstResponder(clone)
            delegate.macros.startRecording()
            clone.executeCommand(TTEditorCommandIdentifier(rawValue: "newLine"))
            try document.reload(using: .utf8, discard: true)
            rejects("reloading the document discards a recording started in its clone", message: "reloaded") {
                _ = try delegate.macros.finishRecording()
            }
            // G373: a reload keeps the language the document was set to instead of detecting again,
            // so there is no newly detected language to carry to the clone (F21); the panes still agree.
            check(
                document.languageIdentifier == user.id && palette(document.editor) != cpp
                    && palette(clone) == palette(document.editor),
                "a reload keeps the chosen language and both panes still agree")

            // G341: recording across views is not supported, so closing the split ends a recording
            // started in the clone, and the closed clone no longer reports focus.
            delegate.noteActive(controller)
            _ = window.makeFirstResponder(clone)
            try require(delegate.currentEditor === clone, "fixture: the clone is the current editor")
            delegate.macros.startRecording()
            clone.executeCommand(TTEditorCommandIdentifier(rawValue: "newLine"))
            controller.closeSplit(nil)
            rejects("closing the split discards a recording started in the clone") {
                _ = try delegate.macros.finishRecording()
            }
            check(clone.onFocus == nil, "a closed clone no longer reports focus")
            check(
                document.activeEditor === document.editor && delegate.searchController.openEditors().count == 1
                    && delegate.searchController.openEditors().first === document.editor,
                "after the split closes the primary view is the document's active view")
            document.close()
        }

        // G338, G342
        section("results captured through a clone survive Close Split View", #line) {
            let delegate = AppDelegate()
            delegate.installEditorServices()
            let (document, controller, window) = try opened(
                "deferred.py", "def one():\n    pass\n\ndef two():\n    pass\n")
            delegate.noteActive(controller)
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
                stdout: Data("def three():\n    pass\n".utf8), stderr: Data(), status: 0, reason: .finished)
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
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
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
            weak var latePresentation: EditorWindowController?
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
                    lateWindow = otherController.hostWindow
                    latePresentation = otherController
                }
                lateDocument = other
                other.close()
            }
            for _ in 0..<10 where lateClone != nil || lateWindow != nil || lateDocument != nil {
                autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            }
            check(
                lateClone == nil && latePresentation == nil && lateWindow === controller.hostWindow
                    && lateDocument == nil,
                "closing a document releases its document and Clone while retaining the shared workspace window")
            document.close()
        }
    }
}
