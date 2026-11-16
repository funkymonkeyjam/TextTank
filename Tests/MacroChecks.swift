// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if TEXTTANK_NATIVE_MACRO_TEST
    import AppKit
#endif

@main struct MacroChecks {
    #if TEXTTANK_NATIVE_MACRO_TEST
        static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        static func control<T: NSView>(_ identifier: String, _ type: T.Type, in views: [NSView]) -> T? {
            views.compactMap { $0 as? T }.first { $0.identifier?.rawValue == identifier }
        }
        /// Sends a Macros menu item's own action while a timer in modal mode answers the dialog it opens.
        /// `act` is called on every tick until it returns true; a modal still open at the deadline is aborted.
        static func choosing(_ item: NSMenuItem, _ act: @escaping ([NSView]) -> Bool) -> Bool {
            var acted = false, timedOut = false
            let deadline = Date().addingTimeInterval(10)
            let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
                guard let content = NSApp.modalWindow?.contentView else { return }
                if Date() > deadline {
                    timedOut = true
                    NSApp.abortModal()
                    return
                }
                if !acted { acted = act(descendants(content)) }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            defer { timer.invalidate() }
            guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else { return false }
            return acted && !timedOut
        }
        static func item(_ selector: String, in controller: MacroController, id: UUID? = nil) -> NSMenuItem? {
            controller.menu().items.first {
                $0.action == NSSelectorFromString(selector)
                    && (id == nil || ($0.representedObject as? String) == id?.uuidString)
            }
        }
        /// F253: Save Last Recording, a restart, then playback from the Macros menu.
        static func menuFlowChecks(editor: TTEditor, support: URL) throws {
            let storage = support.appendingPathComponent("Macros.json")
            let controller = MacroController(editorProvider: { editor })
            editor.text = "ab"
            editor.resetUndoHistory()
            editor.setSavePoint()
            _ = editor.setSelectionAnchor(1, caret: 1)
            controller.startRecording()
            editor.executeCommand("newLine")
            let recording = try requireValue(try controller.finishRecording(), "fixture: a one-step recording")
            editor.executeCommand("undo")
            try require(editor.text == "ab", "fixture: the recorded edit is undone")
            func answer(_ field: String, _ value: String?, _ button: String) -> ([NSView]) -> Bool {
                { views in
                    guard let press = control(button, NSButton.self, in: views),
                        let input = control(field, NSTextField.self, in: views)
                    else { return false }
                    if let value { input.stringValue = value }
                    press.performClick(nil)
                    return true
                }
            }
            let saveItem = try requireValue(item("saveLast", in: controller), "fixture: the Save Last Recording item")
            check(saveItem.isEnabled, "Save Last Recording is enabled after a finished recording")
            check(
                choosing(saveItem, answer("macro.save.name", "Never saved", "macro.save.cancel"))
                    && !FileManager.default.fileExists(atPath: storage.path),
                "Cancel in Name Recorded Macro writes nothing")
            check(
                choosing(saveItem, answer("macro.save.name", "Blank line", "macro.save.confirm")),
                "Name Recorded Macro accepts a name and Save")
            var stored = try MacroLibrary.decode(Data(contentsOf: storage))
            check(
                stored.macros.count == 1 && stored.macros[0].id == recording.id && stored.macros[0].name == "Blank line"
                    && stored.macros[0].steps == recording.steps,
                "Save Last Recording persists the recorded steps under the chosen name")
            check(
                (try FileManager.default.attributesOfItem(atPath: storage.path)[.posixPermissions] as? NSNumber)?
                    .intValue == 0o600, "the saved macro file is private to the user")
            check(
                choosing(saveItem, answer("macro.save.name", "Blank line twice", "macro.save.confirm")),
                "saving the same recording again is accepted")
            stored = try MacroLibrary.decode(Data(contentsOf: storage))
            check(
                stored.macros.count == 1 && stored.macros[0].id == recording.id
                    && stored.macros[0].name == "Blank line twice",
                "saving the same recording again renames it and keeps one entry and its ID")
            // A new controller reads the file, as the next launch does.
            let restarted = MacroController(editorProvider: { editor })
            let savedItem = try requireValue(
                item("playSaved:", in: restarted, id: recording.id),
                "fixture: the saved macro has a menu item after restart")
            check(
                savedItem.title == "Blank line twice" && savedItem.isEnabled,
                "the saved macro is listed by its saved name after restart")
            var revision = editor.revision
            check(
                choosing(savedItem, answer("macro.play.count", nil, "macro.play.cancel")) && editor.text == "ab"
                    && editor.revision == revision && !editor.modified, "Cancel in the playback dialog changes nothing")
            check(
                choosing(savedItem, answer("macro.play.count", "3", "macro.play.confirm")),
                "a saved macro plays from its menu item with a repeat count")
            check(editor.text == "a\n\n\nb", "saved macro playback repeats the recorded edit at the caret")
            editor.executeCommand("undo")
            check(editor.text == "ab" && !editor.modified, "menu playback of a saved macro is one Undo")
            _ = editor.setSelectionAnchor(1, caret: 1)
            revision = editor.revision
            check(
                choosing(savedItem, answer("macro.play.count", "0", "macro.play.cancel")) && editor.text == "ab"
                    && editor.revision == revision, "Cancel after typing a count changes nothing")
            let lastItem = try requireValue(item("playLast", in: controller), "fixture: the Play Last Recording item")
            check(
                choosing(lastItem, answer("macro.play.count", "2", "macro.play.confirm")) && editor.text == "a\n\nb",
                "Play Last Recording replays the unsaved recording through the same dialog")
            editor.executeCommand("undo")
            check(editor.text == "ab" && !editor.modified, "Play Last Recording is one Undo")
            check(
                item("playLast", in: restarted)?.isEnabled == false
                    && item("saveLast", in: restarted)?.isEnabled == false,
                "a restarted controller has no last recording to play or save")
        }
        static func jsonManagerChecks(editor: TTEditor) throws {
            let isolated = try IsolatedSupportDirectory("MacroJSONChecks")
            defer { isolated.restore() }
            let path = isolated.url.appendingPathComponent("Macros.json")
            let macro = RecordedMacro(id: UUID(), name: "JSON manager", steps: [.insertText("é\0e\u{301}")])
            let initial = MacroLibrary(macros: [macro])
            try initial.encoded().write(to: path)
            let controller = MacroController(editorProvider: { editor })
            let manage = try requireValue(item("manage", in: controller), "fixture: the macro JSON manager item")
            let before = try Data(contentsOf: path)
            let editorText = editor.text, revision = editor.revision, modified = editor.modified
            var corrected = macro
            corrected.name = "Renamed in JSON"
            let correctedLibrary = MacroLibrary(macros: [corrected])
            let correctedJSON = String(decoding: try correctedLibrary.encoded(), as: UTF8.self)
            let invalid = "{ preserve the macro JSON draft"
            var stage = 0, nestedError = false, keptDraft = false, inlineError = false
            var manager: NSWindow?
            let retried = choosing(manage) { views in
                if stage == 1, NSApp.modalWindow !== manager {
                    nestedError = true
                    NSApp.abortModal()
                    return false
                }
                guard let text = views.compactMap({ $0 as? NSTextView }).first,
                    let save = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Save" })
                else { return false }
                switch stage {
                case 0:
                    manager = NSApp.modalWindow
                    text.string = invalid
                    stage = 1
                    save.performClick(nil)
                case 1:
                    keptDraft = text.string == invalid && (try? Data(contentsOf: path)) == before
                    inlineError = text.accessibilityHelp()?.isEmpty == false
                    text.string = correctedJSON
                    stage = 2
                    save.performClick(nil)
                    return true
                default: break
                }
                return false
            }
            check(retried && stage == 2 && keptDraft, "F155 Macro JSON retry retains the draft and saved bytes")
            check(!nestedError && inlineError, "F155 invalid Macro JSON is marked inline without a nested error modal")
            check(
                try MacroLibrary.decode(Data(contentsOf: path)) == correctedLibrary,
                "F155 explicit corrected Macro JSON Save roundtrips exact typed steps")
            let restarted = MacroController(editorProvider: { editor })
            check(
                item("playSaved:", in: restarted, id: macro.id)?.title == corrected.name,
                "F155 a JSON rename keeps the macro identity after restart")
            check(
                editor.text == editorText && editor.revision == revision && editor.modified == modified,
                "F155 editing a Macro library never executes its steps")
            var imported = corrected
            imported.name = "Imported Macro draft"
            let importedLibrary = MacroLibrary(macros: [imported])
            let source = isolated.url.appendingPathComponent("macro-import.json")
            let exported = isolated.url.appendingPathComponent("macro-export.json")
            try importedLibrary.encoded().write(to: source)
            let saved = try Data(contentsOf: path)
            var exportNames: [String] = []
            controller.jsonFilePanels = .init(
                importURL: { source },
                exportURL: { name in
                    exportNames.append(name)
                    return exported
                })
            stage = 0
            var draftOnly = false, exportedDraft = false
            let cancelled = choosing(manage) { views in
                guard let text = control("macro.json.text", NSTextView.self, in: views),
                    let load = control("macro.json.import", NSButton.self, in: views),
                    let export = control("macro.json.export", NSButton.self, in: views),
                    let cancel = control("macro.json.cancel", NSButton.self, in: views)
                else { return false }
                switch stage {
                case 0:
                    stage = 1
                    load.performClick(nil)
                case 1:
                    draftOnly =
                        (try? MacroLibrary.decode(Data(text.string.utf8))) == importedLibrary
                        && (try? Data(contentsOf: path)) == saved
                    stage = 2
                    export.performClick(nil)
                case 2:
                    exportedDraft = (try? MacroLibrary.decode(Data(contentsOf: exported))) == importedLibrary
                    stage = 3
                    cancel.performClick(nil)
                    return true
                default: break
                }
                return false
            }
            check(
                cancelled && stage == 3 && draftOnly && exportedDraft,
                "F155 Macro import and export use the draft without saving it")
            check(
                try Data(contentsOf: path) == saved, "F155 Cancel after Macro import and export preserves saved bytes")
            check(exportNames == ["TextTank-Macros.json"], "F155 Macro export keeps its documented filename")
            stage = 0
            let accepted = choosing(manage) { views in
                guard let load = control("macro.json.import", NSButton.self, in: views),
                    let save = control("macro.json.save", NSButton.self, in: views)
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
            check(
                try accepted && MacroLibrary.decode(Data(contentsOf: path)) == importedLibrary,
                "F155 explicit Save commits the imported Macro draft")
            check(
                editor.text == editorText && editor.revision == revision,
                "F155 imported Macro Save executes no recorded text")
            let corrupt = Data("{ preserve unreadable macros".utf8)
            try corrupt.write(to: path)
            let blocked = MacroController(editorProvider: { editor })
            let blockedManager = try requireValue(
                item("manage", in: blocked), "fixture: unreadable Macro manager remains recoverable")
            var recoveryOnly = false
            let declined = choosing(blockedManager) { views in
                guard let cancel = control("store.recover.cancel", NSButton.self, in: views) else { return false }
                recoveryOnly = !views.contains { $0 is NSTextView }
                cancel.performClick(nil)
                return true
            }
            check(
                try declined && recoveryOnly && Data(contentsOf: path) == corrupt && blocked.loadingError != nil,
                "F155 unreadable Macro storage requires explicit recovery before opening the JSON editor")
        }
        /// Navigation from the Find window fronts the document window; checks never put one on screen.
        final class QuietWindow: NSWindow { override func makeKeyAndOrderFront(_ sender: Any?) {} }
        /// Stands in for the system's drag information, so a real drop runs through a content view.
        final class FakeDrop: NSObject {
            @objc let draggingPasteboard = NSPasteboard.withUniqueName()
            @objc var draggingLocation = NSPoint.zero
            @objc let draggingSourceOperationMask = NSDragOperation.copy
            @objc let draggingSource: Any? = nil
        }
        /// Package 12: a recording either reproduces what was done or is discarded with a named reason.
        static func fidelityChecks(editor: TTEditor, window: NSWindow) throws {
            let controller = MacroController(editorProvider: { editor })
            var reasons: [String] = []
            controller.onInvalidated = { reasons.append($0) }
            func load(_ text: String, caret: Int = 0) {
                editor.executeCommand("streamSelection")
                editor.text = text
                editor.resetUndoHistory()
                editor.setSavePoint()
                _ = editor.setSelectionAnchor(caret, caret: caret)
            }
            let content = try requireValue(
                descendants(editor).first { $0.className == "TTContentView" }, "fixture: the editor's content view")
            let input = try requireValue(content as? NSTextInputClient, "fixture: the content view takes text input")
            func type(_ text: String) {
                input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            /// A real key event through the content view, so Scintilla's own Mac key map chooses the message.
            func key(_ scalar: Int, code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
                let characters = String(UnicodeScalar(UInt32(scalar))!)
                let event = try requireValue(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code), "fixture: a key event")
                content.keyDown(with: event)
            }
            let home = NSHomeFunctionKey, left = NSLeftArrowFunctionKey, down = NSDownArrowFunctionKey
            let pageDown = NSPageDownFunctionKey
            var clock = ProcessInfo.processInfo.systemUptime
            /// A click in the content view. Clicks are five seconds apart so none is a double click.
            func click(at point: NSPoint, in view: NSView) throws {
                clock += 5
                for (type, time) in [(NSEvent.EventType.leftMouseDown, clock), (.leftMouseUp, clock + 0.05)] {
                    let event = try requireValue(
                        NSEvent.mouseEvent(
                            with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: time,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                            pressure: 1), "fixture: a mouse event")
                    if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
                }
            }
            func commands(_ macro: RecordedMacro?) -> [String] { macro?.steps.compactMap(\.command) ?? [] }

            // G367: the canonical "prefix each line" macro, recorded with the standard Mac keys.
            let lines = "one\ntwo\nthree"
            load(lines, caret: 2)
            controller.startRecording()
            try key(home, code: 115)
            type("// ")
            try key(down, code: 125, [.numericPad, .function])
            let prefix = try requireValue(try controller.finishRecording(), "fixture: the prefix recording is saveable")
            check(
                prefix.steps.first == .command("vcHome")
                    && prefix.steps.last == .command("lineDown")
                    && prefix.steps.compactMap(\.text).joined() == "// " && editor.text == "// one\ntwo\nthree"
                    && reasons.isEmpty, "Home, typing and Down record as vcHome, the typed text and lineDown")
            load(lines, caret: 2)
            try controller.play(prefix, on: editor, repeats: 3)
            check(editor.text == "// one\n// two\n// three", "the recorded prefix macro prefixes each line on replay")
            editor.executeCommand("undo")
            check(editor.text == lines && !editor.modified, "the replayed prefix macro is one Undo")
            load("alpha beta\ngamma", caret: 10)
            controller.startRecording()
            try key(left, code: 123, [.command, .numericPad, .function])
            try key(pageDown, code: 121, [.function])
            try key(0x1B, code: 53)
            try key(0x7F, code: 51, [.option])
            check(
                commands(try controller.finishRecording()) == ["vcHome", "pageDown", "cancel", "deleteWordLeft"]
                    && reasons.isEmpty,
                "Command-Left, Page Down, Escape and Option-Delete are recorded instead of discarding the recording")
            // Parity: one allow-list, in the bridge and in the persisted format.
            let fixture = try requireValue(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("editor-commands-wave-3.json")))
                    as? [String: Any], "fixture: frozen native command contract")
            let messages = try requireValue(
                fixture["bridge_replay_messages"] as? [String: Int], "fixture: frozen recording numbers")
            check(
                TTEditor.macroCommandMessages().mapValues(\.intValue) == messages,
                "F281 canonical command names keep every exact accepted Scintilla message number")
            let supported = Set(
                try requireValue(fixture["bridge_supported"] as? [String], "fixture: supported identifiers"))
            check(
                Set(TTEditor.supportedCommandIdentifiers()) == supported
                    && supported == Set(EditorCommand.allCases.map(\.rawValue)),
                "F281 Swift catalog and full bridge dispatch support the frozen exact identifier set")
            let modifies = Set(
                try requireValue(fixture["modifies_text"] as? [String], "fixture: text modifying commands"))
            check(
                Set(supported.filter(TTEditor.commandModifiesText)) == modifies,
                "F281 read-only classification preserves the exact accepted editing subset")
            check(
                messages["indent"] == nil && messages["unindent"] == nil && messages["tab"] != nil
                    && messages["backTab"] != nil,
                "F281 playback-only indent aliases never compete for canonical Tab recording names")
            let bridgeNames = Set(TTEditor.macroCommandNames())
            check(
                bridgeNames.union(["indent", "unindent"]) == RecordedMacro.Step.commands,
                "the bridge's command table and the macro format's command list name the same commands")
            let clipboard: Set<String> = ["cut", "copy", "paste", "lineCut", "lineCopy"]
            let usePasteboard = ProcessInfo.processInfo.environment["TEXTTANK_TEST_PASTEBOARD"] != nil
            var refused: [String] = []
            for name in RecordedMacro.Step.commands.sorted() where usePasteboard || !clipboard.contains(name) {
                load("alpha beta\ngamma", caret: 3)
                if !editor.executeMacroStep(["kind": "command", "command": name]) { refused.append(name) }
            }
            if !refused.isEmpty { print("commands the bridge refused: \(refused)") }
            check(refused.isEmpty, "every command a macro file may name is accepted by the bridge")
            for name in RecordedMacro.Step.commands.sorted() {
                rejects("a \(name) step carrying text is refused by validation") {
                    let json = "{\"kind\":\"command\",\"text\":\"x\",\"command\":\"\(name)\"}"
                    _ = try JSONDecoder().decode(RecordedMacro.Step.self, from: Data(json.utf8))
                }
            }
            // No message number or parameter from a file reaches Scintilla.
            let smuggled = Data(
                #"{"version":1,"macros":[{"version":1,"id":"11111111-2222-4333-8444-555555555556","name":"n","steps":[{"kind":"command","command":"charRight","message":2004,"wParam":1,"lParam":2}]}]}"#
                    .utf8)
            let decoded = try MacroLibrary.decode(smuggled)
            check(
                !String(decoding: try decoded.encoded(), as: UTF8.self).contains("2004"),
                "a message number in a macro file is dropped on decode")
            load("keep", caret: 0)
            try controller.play(decoded.macros[0], on: editor)
            check(
                editor.text == "keep" && editor.selectionCaret == 1 && !editor.modified,
                "a step that carried SCI_CLEARALL as a number runs only its named command")
            rejects(
                "a file cannot name the bridge's unsupported marker as a step kind",
                where: { ($0 as? JSONInputFailure)?.underlying is DecodingError }
            ) {
                _ = try MacroLibrary.decode(
                    Data(
                        String(decoding: smuggled, as: UTF8.self).replacingOccurrences(
                            of: "\"command\",", with: "\"unsupported\","
                        ).utf8))
            }

            // F67 and G367: a named reason, at once, and the previous recording survives.
            load("alpha beta", caret: 0)
            controller.startRecording()
            editor.executeCommand("charRight")
            let kept = try requireValue(try controller.finishRecording(), "fixture: a good recording to keep")
            controller.startRecording()
            check(
                controller.discardReason == nil && item("stopRecording", in: controller)?.title == "Stop Recording",
                "a live recording offers Stop Recording and has no discard reason")
            editor.executeCommand("charRight")
            editor.executeCommand("rectangularSelection")
            check(
                reasons.count == 1 && reasons[0].contains("Rectangular selection")
                    && reasons[0].contains("is not recordable yet") && controller.discardReason == reasons[0],
                "an unrecordable action is reported at the moment it happens, by name")
            check(
                item("stopRecording", in: controller)?.title == "Stop Recording (Already Discarded)"
                    && item("stopRecording", in: controller)?.isEnabled == true,
                "the menu says the recording in progress is already discarded and can still be stopped")
            editor.executeCommand("charRight")
            controller.invalidateRecording(reason: "a second reason")
            check(reasons.count == 1, "a discarded recording reports once; later reasons are not announced")
            var stopMessage = ""
            do { _ = try controller.finishRecording() } catch { stopMessage = error.localizedDescription }
            check(
                stopMessage.contains("Recording was discarded") && stopMessage.contains("Rectangular selection")
                    && !stopMessage.contains("correct format"),
                "Stop names the action that discarded the recording, not a decoding error")
            check(
                item("playLast", in: controller)?.isEnabled == true
                    && item("saveLast", in: controller)?.isEnabled == true && controller.discardReason == nil,
                "the previous recording is still offered after a discarded one")
            load("alpha beta", caret: 0)
            try controller.play(kept, on: editor)
            controller.startRecording()
            rejects("a recording with no steps is not saved", message: "No supported editing actions") {
                _ = try controller.finishRecording()
            }
            check(
                item("playLast", in: controller)?.isEnabled == true,
                "the previous recording is still offered after an empty one")
            controller.startRecording()
            editor.executeCommand("charLeft")
            let newer = try requireValue(try controller.finishRecording(), "fixture: a newer good recording")
            check(
                newer.id != kept.id && newer.steps != kept.steps, "a new successful recording replaces the previous one"
            )
            reasons = []

            // F59: the mouse.
            load("alpha beta\n  gamma delta\nlast line\n", caret: 0)
            let near = NSPoint(x: 60, y: 8), below = NSPoint(x: 30, y: 26)
            try click(at: near, in: content)
            let clicked = editor.selectionCaret
            try require(clicked > 0 && clicked < 10, "fixture: a synthesized click places the caret in the first line")
            controller.startRecording()
            editor.executeCommand("charRight")
            editor.executeCommand("charLeft")
            try click(at: near, in: content)
            check(
                try controller.finishRecording()?.steps.count == 2 && reasons.isEmpty,
                "a click that changes neither caret nor text leaves the recording saveable")
            controller.startRecording()
            editor.executeCommand("charRight")
            try click(at: below, in: content)
            check(
                reasons.count == 1 && reasons[0].contains("mouse") && editor.selectionCaret != clicked,
                "a click that moves the caret discards the recording at once and says the mouse did it")
            type("bar")
            rejects("a mouse caret move cannot silently save a partial recording", message: "mouse") {
                _ = try controller.finishRecording()
            }
            // A margin click selects a line through a view the bridge cannot subclass; the event is
            // delivered through the application so the recording's event monitor sees it.
            reasons = []
            let margin = try requireValue(
                descendants(editor).first { $0.className == "SCIMarginView" }, "fixture: the editor's margin view")
            load("alpha beta\n  gamma delta\nlast line\n", caret: 0)
            controller.startRecording()
            editor.executeCommand("charRight")
            clock += 5
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try requireValue(
                    NSEvent.mouseEvent(
                        with: type, location: margin.convert(NSPoint(x: 6, y: 26), to: nil), modifierFlags: [],
                        timestamp: clock, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: 1), "fixture: a margin mouse event")
                NSApp.postEvent(event, atStart: false)
            }
            var delivered = 0
            while delivered < 2,
                let event = NSApp.nextEvent(
                    matching: [.leftMouseDown, .leftMouseUp], until: Date().addingTimeInterval(5), inMode: .default,
                    dequeue: true)
            {
                // The application runs its event monitors and hands the event to the window, which
                // drops a mouse event while it is off screen; the margin view is given it here.
                NSApp.sendEvent(event)
                if event.type == .leftMouseDown { margin.mouseDown(with: event) } else { margin.mouseUp(with: event) }
                delivered += 1
            }
            try require(
                delivered == 2 && editor.selectionAnchor != editor.selectionCaret,
                "fixture: the margin click was delivered and selected a line")
            _ = spinUntil(timeout: 5, "the margin click to be compared") { !reasons.isEmpty }
            check(
                reasons.count == 1 && reasons[0].contains("mouse"),
                "a margin click that selects a line discards the recording")
            rejects("a margin selection cannot silently save a partial recording", message: "mouse") {
                _ = try controller.finishRecording()
            }
            // A split view shares the recorded document. Text dropped into it edits that document
            // through another view, and a drop moves no focus, so nothing else would notice.
            reasons = []
            load("alpha beta\n  gamma delta\nlast line\n", caret: 0)
            let split = TTEditor(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            let splitWindow = QuietWindow(
                contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
            splitWindow.isReleasedWhenClosed = false
            splitWindow.contentView = split
            split.shareDocument(with: editor)
            split.onFocus = { controller.editorDidFocus(split) }
            let splitContent = try requireValue(
                descendants(split).first { $0.className == "TTContentView" }, "fixture: the split view's content view")
            let drop = FakeDrop()
            drop.draggingPasteboard.declareTypes([.string], owner: nil)
            drop.draggingPasteboard.setString("DROP", forType: .string)
            defer { drop.draggingPasteboard.releaseGlobally() }
            drop.draggingLocation = splitContent.convert(near, to: nil)
            let dropInfo = unsafeBitCast(drop, to: NSDraggingInfo.self)
            controller.startRecording()
            editor.executeCommand("charRight")
            let beforeDrop = editor.revision
            _ = splitContent.draggingEntered(dropInfo)
            _ = splitContent.draggingUpdated(dropInfo)
            try require(
                splitContent.performDragOperation(dropInfo) && editor.text.contains("DROP")
                    && editor.revision != beforeDrop,
                "fixture: the drop into the split view edited the recorded document")
            check(
                reasons.count == 1 && reasons[0].contains("drag and drop"),
                "text dropped into a split view of the recorded document discards the recording at once")
            rejects("a drop into a split view cannot silently save a partial recording", message: "drag and drop") {
                _ = try controller.finishRecording()
            }
            split.onFocus = nil
            splitWindow.contentView = nil
            reasons = []
            // Audit27: the pre-consolidation accepted 65,537-unit legacy query is now bounded by
            // the shared engine. Preserve rejection state rather than silently skipping a macro step.
            let longQuery = String(repeating: "q", count: 65_537)
            load(longQuery, caret: 0)
            let beforeLimit = editor.revision
            let overLimit = RecordedMacro(
                id: UUID(), name: "Old long query",
                steps: [
                    .findLiteral(text: longQuery, matchCase: true, backwards: false)
                ])
            rejects("legacy find reports the shared 64 Ki query limit", message: "64 Ki") {
                try controller.play(overLimit, on: editor)
            }
            check(
                editor.revision == beforeLimit && editor.selectionCaret == 0
                    && editor.text.utf8.elementsEqual(longQuery.utf8),
                "a legacy query rejected by the shared limit preserves bytes, revision and selection")
            let boundaryQuery = String(repeating: "q", count: 65_536)
            load(boundaryQuery, caret: 0)
            check(
                try SearchController.playLegacyFind(text: boundaryQuery, matchCase: true, backwards: false, in: editor),
                "the shared legacy shim accepts the full 64 Ki query boundary")
            for (text, query) in [
                ("İ i", "i"), ("é e\u{301}", "é"), ("Σ σ ς", "σ"), ("Straße STRASSE", "ss"), ("alpha 🦋 alpha", "🦋")
            ] {
                load(text, caret: text.utf8.count)
                var shared = SearchOptions()
                shared.query = query
                let first = try SearchCore.search(text, options: shared).hits.first
                let bytes = first.flatMap { SearchCore.byteRange($0.range, in: text) }
                check(
                    try SearchController.playLegacyFind(text: query, matchCase: false, backwards: false, in: editor)
                        && bytes
                            == NSRange(
                                location: editor.selectionStart, length: editor.selectionEnd - editor.selectionStart),
                    "legacy Unicode navigation wraps to the same shared-engine bytes")
            }
            for (text, query, anchor, caret, backwards) in [
                ("aaa", "aa", 1, 1, false), ("aaa", "aa", 3, 3, true),
                ("ab", "ab", 1, 1, false), ("ab", "ab", 1, 1, true),
                ("aaa", "aa", 0, 2, false), ("aaa", "aa", 0, 2, true),
                ("aaa", "aa", 2, 0, true), ("aaa", "aa", 3, 1, false),
                ("😀😀😀", "😀😀", 4, 4, false)
            ] {
                load(text, caret: caret)
                _ = editor.setSelectionAnchor(anchor, caret: caret)
                let originalMatched = editor.find(query, matchCase: true, backwards: backwards)
                let originalStart = editor.selectionStart, originalEnd = editor.selectionEnd
                let originalAnchor = editor.selectionAnchor, originalCaret = editor.selectionCaret
                load(text, caret: caret)
                _ = editor.setSelectionAnchor(anchor, caret: caret)
                let sharedMatched = try SearchController.playLegacyFind(
                    text: query, matchCase: true, backwards: backwards, in: editor)
                print(
                    "CHARACTERIZE navigation \(text.debugDescription) q=\(query.debugDescription) sel=\(anchor):\(caret) back=\(backwards): native=\(originalMatched):\(originalStart):\(originalEnd) shared=\(sharedMatched):\(editor.selectionStart):\(editor.selectionEnd)"
                )
                check(
                    sharedMatched == originalMatched && editor.selectionStart == originalStart
                        && editor.selectionEnd == originalEnd,
                    "shared navigation preserves native literal overlap/interior/wrap boundaries")
                check(
                    editor.selectionAnchor == originalAnchor && editor.selectionCaret == originalCaret,
                    "shared literal navigation preserves native output anchor/caret direction")
            }
            // Application actions capture full search parameters, using the same v1 format as the Find window.
            let sharedFinder = SearchController()
            var barOptions = SearchOptions()
            barOptions.query = "egg"
            barOptions.matchCase = true
            load("egg and egg", caret: 0)
            controller.startRecording()
            try sharedFinder.playRecorded(options: barOptions, action: "next", on: editor)
            controller.recordSearch(.init(options: barOptions, action: "next"), editor: editor)
            barOptions.replacement = "milk"
            try sharedFinder.playRecorded(options: barOptions, action: "replaceOne", on: editor)
            controller.recordSearch(.init(options: barOptions, action: "replaceOne"), editor: editor)
            let literal = try controller.finishRecording()
            var findOptions = barOptions
            findOptions.replacement = ""
            check(
                literal?.steps == [
                    .search(.init(options: findOptions, action: "next")),
                    .search(.init(options: barOptions, action: "replaceOne"))
                ]
                    && editor.text == "milk and egg" && reasons.isEmpty,
                "a live recording keeps only shared search steps for Find and strict replacement")
            // F68: failed navigation is never reported to the recorder as a completed search action.
            load("alpha beta", caret: 0)
            controller.startRecording()
            editor.executeCommand("charRight")
            barOptions.query = "absent"
            rejects("a missed shared navigation reports no match", message: "did not match") {
                try sharedFinder.playRecorded(options: barOptions, action: "next", on: editor)
            }
            check(
                try controller.finishRecording()?.steps == [.command("charRight")],
                "a find that did not match is left out of the recording")
            controller.startRecording()
            rejects("an unmatched search reports failure", message: "did not match") {
                try sharedFinder.playRecorded(options: barOptions, action: "next", on: editor)
            }
            rejects("a recording of only an unmatched find saves nothing", message: "No supported editing actions") {
                _ = try controller.finishRecording()
            }

            // G371: completion and call tips.
            load("ret", caret: 3)
            controller.startRecording()
            type("x")
            editor.showCompletions(["return"])
            check(
                reasons.count == 1 && reasons[0].contains("completion list"),
                "the completion list discards the recording when it opens")
            rejects("completion popup invalidates recording", message: "completion list") {
                _ = try controller.finishRecording()
            }
            editor.executeCommand("cancel")
            reasons = []
            load("call(", caret: 0)
            controller.startRecording()
            editor.showCallTip("call(argument)")
            editor.executeCommand("charRight")
            check(
                try controller.finishRecording()?.steps.count == 1 && reasons.isEmpty,
                "a call tip leaves the recording saveable")

            // F277: application-layer caret jumps.
            load("one\ntwo\nthree", caret: 0)
            controller.startRecording()
            editor.executeCommand("newLine")
            check(
                controller.unrecordedJump(in: editor, reason: "Go to Line is not recorded in macros yet.") {
                    editor.goToLine(3)
                } && reasons.count == 1 && reasons[0].hasPrefix("Go to Line is not record"),
                "Go to Line discards the recording at the point of mutation and is named")
            rejects("Go to Line cannot silently save partial recording", message: "Go to Line") {
                _ = try controller.finishRecording()
            }
            reasons = []
            load("one\ntwo\nthree", caret: 0)
            controller.startRecording()
            editor.executeCommand("charRightExtend")
            check(
                controller.unrecordedJump(in: editor, reason: "Clear Selection is not recorded in macros yet.") {
                    editor.setSelectionAnchor(editor.selectionCaret, caret: editor.selectionCaret)
                } && reasons == ["Clear Selection is not recorded in macros yet."] && editor.selectionAnchor == 1,
                "a jump that changes the selection discards the recording with the caller's reason")
            rejects("Clear Selection cannot silently save partial recording", message: "Clear Selection") {
                _ = try controller.finishRecording()
            }
            reasons = []
            load("one\ntwo\nthree", caret: 4)
            controller.startRecording()
            editor.executeCommand("newLine")
            let caret = editor.selectionCaret
            check(
                try !controller.unrecordedJump(in: editor, reason: "unused") { editor.goToLine(99) }
                    && controller.unrecordedJump(in: editor, reason: "unused") {
                        editor.setSelectionAnchor(caret, caret: caret)
                    } && reasons.isEmpty && controller.finishRecording()?.steps.count == 1,
                "a refused jump and a jump to where the caret already is leave the recording saveable")
            load("one\ntwo\nthree", caret: 4)
            controller.startRecording()
            editor.executeCommand("newLine")
            check(
                try controller.unrecordedJump(in: editor, reason: "unused") { editor.goToLine(3) }
                    && editor.selectionCaret == caret && reasons.isEmpty
                    && controller.finishRecording()?.steps.count == 1,
                "Go to Line to the line start the caret is already on leaves the recording saveable")

            // The recorded Find-window path changes the selection outside Scintilla's recording too.
            let suite = "TextTankMacroFidelity-" + UUID().uuidString
            let defaults = try requireValue(UserDefaults(suiteName: suite), "fixture: isolated defaults suite")
            defer { defaults.removePersistentDomain(forName: suite) }
            let finder = SearchController(defaults: defaults)
            finder.currentEditor = { editor }
            finder.openEditors = { [editor] }
            finder.onCommand = { options, action, target in
                controller.recordSearch(
                    .init(
                        query: options.query, replacement: options.replacement, mode: options.mode.rawValue,
                        matchCase: options.matchCase, wholeWord: options.wholeWord,
                        dotMatchesNewline: options.dotMatchesNewline, wrap: options.wrap, action: action),
                    editor: target)
            }
            finder.onUnrecordableCommand = { controller.invalidateRecording(reason: $0) }
            let quiet = QuietWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.contentView = NSView()
            quiet.contentView = editor
            defer {
                quiet.contentView = NSView()
                window.contentView = editor
            }
            load("TODO a\nTODO b\n", caret: 0)
            finder.queryField.stringValue = "TODO"
            finder.mode.selectItem(at: 0)
            finder.scope.selectItem(at: 0)
            controller.startRecording()
            finder.next(nil)
            _ = spinUntil("the Find-window search to finish") { !finder.isSearching }
            let searched = try controller.finishRecording()
            check(
                searched?.steps.map(\.kind) == [.search] && searched?.steps[0].search?.action == "next"
                    && editor.selectedText == "TODO" && reasons.isEmpty,
                "a Find-window Next on the current document is still recorded as a search step")
            // G372: text typed while the search runs makes the result stale; nothing is recorded as done.
            load("TODO a\nTODO b\n", caret: 0)
            controller.startRecording()
            finder.next(nil)
            type("x")
            _ = spinUntil("the stale Find-window search to finish") { !finder.isSearching }
            check(
                finder.lastOutcome == .staleResult && editor.text == "xTODO a\nTODO b\n" && editor.selectionCaret == 1
                    && reasons.count == 1 && reasons[0].contains("document changed while the search was running"),
                "a search overtaken by typing moves nothing and discards the recording with that reason")
            rejects("a search overtaken by typing cannot save a partial recording") {
                _ = try controller.finishRecording()
            }
            reasons = []
            // A result row moves the caret with no recordable step.
            load("TODO a\nTODO b\n", caret: 0)
            finder.findAll(nil)
            _ = spinUntil("the Find All search to finish") { !finder.isSearching }
            controller.startRecording()
            editor.executeCommand("charRight")
            finder.open(row: 1)
            check(
                editor.selectionStart == 7 && reasons.count == 1 && reasons[0].contains("search result"),
                "opening a search result row discards the recording")
            rejects("a result-row jump cannot save a partial recording") { _ = try controller.finishRecording() }
            reasons = []

            // The package 4 golden library decodes and plays unchanged.
            let golden = try MacroLibrary.decode(
                Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/persistence/MacroLibrary.json")))
            controller.searchPlayback = { captured, target in
                var options = SearchOptions()
                options.query = captured.query
                options.replacement = captured.replacement
                options.mode = SearchOptions.Mode(rawValue: captured.mode) ?? .normal
                options.matchCase = captured.matchCase
                options.wholeWord = captured.wholeWord
                options.dotMatchesNewline = captured.dotMatchesNewline
                options.wrap = captured.wrap
                try finder.playRecorded(options: options, action: captured.action, on: target)
            }
            load("aaa x", caret: 0)
            try controller.play(try requireValue(golden.macros.first, "fixture: the golden macro"), on: editor)
            check(editor.text == "cbféb y", "the golden saved macro library decodes and plays as before")
            editor.executeCommand("undo")
            check(editor.text == "aaa x" && !editor.modified, "the golden macro replay is one Undo")

            // F222: until-end compares the caret with the byte length, never a copy of the document.
            let advance = RecordedMacro(
                id: UUID(), name: "Advance", steps: [.command("charRight")])
            load("é\n👩🏽‍💻\r\nz", caret: 0)
            try controller.play(advance, on: editor, untilEnd: true)
            check(
                editor.selectionCaret == editor.byteLength && editor.byteLength == editor.text.utf8.count
                    && editor.revision > 0, "until-end playback over non-ASCII text stops at the byte length")
            let rows = 20000
            load(String(repeating: String(repeating: "x", count: 149) + "\n", count: rows), caret: 0)
            let lineDown = RecordedMacro(
                id: UUID(), name: "Down", steps: [.command("lineDown")])
            let scale = max(1, Double(ProcessInfo.processInfo.environment["TEXTTANK_PERF_BUDGET_SCALE"] ?? "") ?? 1)
            let started = ProcessInfo.processInfo.systemUptime
            try controller.play(lineDown, on: editor, untilEnd: true)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            print(String(format: "until-end line-down over 3 MB: %.2f s", elapsed))
            check(
                editor.selectionCaret == editor.byteLength && elapsed < 20 * scale,
                "until-end playback over a 3 MB document does not copy the document every repetition")
            load("", caret: 0)
        }
    #endif
    static func main() {
        Checks.run("MacroChecks") {
            let commandFixture = try requireValue(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("editor-commands-wave-3.json")))
                    as? [String: Any], "fixture: frozen command contract")
            func frozen(_ key: String) throws -> Set<String> {
                Set(try requireValue(commandFixture[key] as? [String], "fixture: frozen " + key))
            }
            check(
                Set(EditorCommand.allCases.map(\.rawValue)) == (try frozen("bridge_supported")),
                "F281 catalog preserves every accepted command identifier, including keyboard-only commands")
            let frozenRecordable = try frozen("recordable")
            let frozenViewOnly = try frozen("view_only"), frozenAssignable = try frozen("shortcut_assignable")
            check(
                EditorCommand.recordableIdentifiers == frozenRecordable
                    && RecordedMacro.Step.commands == frozenRecordable,
                "F281 catalog keeps the exact accepted macro-safe subset")
            check(
                EditorCommand.viewOnlyIdentifiers == frozenViewOnly
                    && EditorCommand.shortcutIdentifiers == frozenAssignable,
                "F281 view-only and assignable subsets remain separate and exact")
            let id = UUID()
            var macro = RecordedMacro(
                id: id, name: "My edit",
                steps: [
                    .insertText("½ café 👩🏽‍💻\0\r\n"),
                    .command("charLeft"),
                    .findLiteral(text: "$()", matchCase: true, backwards: true),
                    .replaceSelection("2 eggs")
                ])
            for raw: [String: Any] in [
                ["kind": "command", "command": "SCI_SETDOCPOINTER"],
                ["kind": "command", "command": "undo"],
                ["kind": "command", "command": "charLeft", "text": "x"],
                ["kind": "insertText", "text": 7],
                ["kind": "insertText", "text": "x", "matchCase": false],
                ["kind": "search", "search": [:]], ["kind": "unsupported"]
            ] {
                rejects("direct captured dictionary refuses malformed or unsafe actions") {
                    _ = try RecordedMacro.Step(bridgeStep: raw)
                }
            }
            let direct = try RecordedMacro.Step(bridgeStep: ["kind": "insertText", "text": "é\0e\u{301}", "future": 7])
            check(
                direct.text?.utf8.elementsEqual("é\0e\u{301}".utf8) == true,
                "direct capture preserves composed/decomposed Unicode and NUL bytes")
            // Audit27: freeze the legacy wire bytes before replacing the optional payload model.
            let goldenBytes = try Data(
                contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/MacroLibrary.json"))
            check(
                try MacroLibrary.decode(goldenBytes).encoded() == goldenBytes,
                "legacy macro encoder preserves golden bytes")
            for json in [
                #"{"kind":"insertText","text":"x","future":17}"#,
                #"{"kind":"replaceSelection","text":""}"#,
                #"{"kind":"findLiteral","text":"é","matchCase":false,"backwards":true,"search":null}"#
            ] {
                let step = try JSONDecoder().decode(RecordedMacro.Step.self, from: Data(json.utf8))
                try step.validate()
                check(true, "legacy optional omissions, null and unknown keys stay readable")
            }
            let library = MacroLibrary(macros: [macro])
            let data = try library.encoded()
            check(try MacroLibrary.decode(data) == library, "capture data exact Unicode/NUL and find params roundtrip")
            Checks.section("F149 bounded macro libraries") {
                var large = macro
                large.steps = [.insertText(String(repeating: "x", count: 32 * 1024 * 1024))]
                let largeLibrary = MacroLibrary(macros: [large])
                let oversized = try JSONEncoder().encode(largeLibrary)
                rejects("F149 the macro reader refuses a valid library over 32 MiB", message: "32 MiB") {
                    _ = try MacroLibrary.decode(oversized)
                }
                rejects("F149 the macro writer cannot create a library its reader refuses", message: "32 MiB") {
                    _ = try largeLibrary.encoded()
                }
            }
            macro.name = "Renamed"
            check(
                try MacroLibrary.decode(MacroLibrary(macros: [macro]).encoded()).macros[0].id == id,
                "rename retains stable ID")
            let json = String(data: data, encoding: .utf8)!
            rejects("unknown command cannot launch shell", message: "Unrecognized or unsafe macro command") {
                _ = try MacroLibrary.decode(Data(json.replacingOccurrences(of: "charLeft", with: "executeShell").utf8))
            }
            rejects("unknown step kind", where: { ($0 as? JSONInputFailure)?.underlying is DecodingError }) {
                _ = try MacroLibrary.decode(Data(json.replacingOccurrences(of: "insertText", with: "reminders").utf8))
            }
            rejects("pointer step rejected", message: "Unrecognized or unsafe macro command") {
                _ = try MacroLibrary.decode(
                    Data(json.replacingOccurrences(of: "charLeft", with: "SCI_SETDOCPOINTER").utf8))
            }
            var invalid = macro
            invalid.version = 2
            rejects("unknown version", message: "requires version 1") { try invalid.validate() }
            invalid = macro
            invalid.steps = [.command("undo")]
            rejects("undo command cannot escape grouped replay", message: "Unrecognized or unsafe macro command") {
                try invalid.validate()
            }
            invalid.steps = [.findLiteral(text: "", matchCase: false, backwards: false)]
            rejects("empty find") { try invalid.validate() }
            for json in [
                #"{"kind":"findLiteral","text":"needle"}"#,
                #"{"kind":"insertText","text":"x","command":"cut"}"#
            ] {
                rejects("missing or incompatible captured parameters") {
                    _ = try JSONDecoder().decode(RecordedMacro.Step.self, from: Data(json.utf8))
                }
            }
            rejects("duplicate macro ID", message: "appears more than once") {
                try MacroLibrary(macros: [macro, macro]).validate()
            }
            var other = macro
            other.id = UUID()
            check(
                try MacroLibrary.decode(MacroLibrary(macros: [macro, other]).encoded()).macros.count == 2,
                "same names different IDs remain distinct")
            #if TEXTTANK_NATIVE_MACRO_TEST
                let isolatedSupport = try IsolatedSupportDirectory("TextTankMacroChecks")
                defer { isolatedSupport.restore() }
                _ = NSApplication.shared
                Checks.section("F149 unsafe macro storage") {
                    let originalOverride = isolatedSupport.url.path
                    defer { setenv("TEXTTANK_SUPPORT_DIRECTORY", originalOverride, 1) }
                    let valid = try MacroLibrary(macros: [macro]).encoded()
                    for kind in ["symlink", "fifo"] {
                        let directory = isolatedSupport.url.appendingPathComponent("unsafe-" + kind)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let path = directory.appendingPathComponent("Macros.json")
                        let target = directory.appendingPathComponent("original.json")
                        try valid.write(to: target)
                        var release: DispatchWorkItem?
                        if kind == "symlink" {
                            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
                        } else {
                            try require(mkfifo(path.path, 0o600) == 0, "fixture: macro FIFO exists")
                            // The old reader blocks until this writer arrives and then wrongly accepts
                            // its JSON. The fixed reader rejects the FIFO without opening the writer.
                            let writer = DispatchWorkItem {
                                let descriptor = open(path.path, O_WRONLY | O_NONBLOCK)
                                if descriptor >= 0 {
                                    _ = valid.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
                                    close(descriptor)
                                }
                            }
                            release = writer
                            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: writer)
                        }
                        setenv("TEXTTANK_SUPPORT_DIRECTORY", directory.path, 1)
                        let unsafe = MacroController(editorProvider: { nil })
                        release?.cancel()
                        check(unsafe.loadingError != nil, "F149 a refused macro \(kind) latches its load failure")
                        rejects("F149 a refused macro \(kind) cannot be overwritten") {
                            try unsafe.persist(library)
                        }
                        check(
                            !unsafe.menu().items.contains { $0.representedObject as? String == macro.id.uuidString },
                            "F149 a macro \(kind) is refused instead of loaded")
                        check(
                            try Data(contentsOf: target) == valid,
                            "F149 refusing a macro \(kind) preserves its target bytes")
                        var node = stat()
                        check(
                            lstat(path.path, &node) == 0
                                && node.st_mode & S_IFMT == (kind == "symlink" ? S_IFLNK : S_IFIFO),
                            "F149 refusing a macro \(kind) leaves the original node in place")
                    }
                    let dangling = isolatedSupport.url.appendingPathComponent("dangling-library")
                    try FileManager.default.createDirectory(at: dangling, withIntermediateDirectories: true)
                    let danglingPath = dangling.appendingPathComponent("Macros.json")
                    try FileManager.default.createSymbolicLink(
                        at: danglingPath, withDestinationURL: dangling.appendingPathComponent("absent.json"))
                    setenv("TEXTTANK_SUPPORT_DIRECTORY", dangling.path, 1)
                    let danglingController = MacroController(editorProvider: { nil })
                    check(
                        danglingController.loadingError != nil,
                        "F198 a dangling macro link is a refused entry, not a missing library")
                    let corruptDirectory = isolatedSupport.url.appendingPathComponent("corrupt-library")
                    try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
                    let corruptFile = corruptDirectory.appendingPathComponent("Macros.json")
                    let corruptBytes = Data("{preserve this unreadable library".utf8)
                    try corruptBytes.write(to: corruptFile)
                    setenv("TEXTTANK_SUPPORT_DIRECTORY", corruptDirectory.path, 1)
                    let corruptController = MacroController(editorProvider: { nil })
                    rejects("F198 the macro save boundary refuses an unreadable existing regular file") {
                        try corruptController.persist(library)
                    }
                    check(try Data(contentsOf: corruptFile) == corruptBytes, "F198 unreadable macro bytes stay exact")
                }
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                    defer: false)
                let editor = TTEditor(frame: window.contentView!.bounds)
                window.contentView = editor
                let controller = MacroController(editorProvider: { editor })
                let original = "café egg egg 👩🏽‍💻"
                editor.text = original
                editor.resetUndoHistory()
                editor.setSavePoint()
                let edit = RecordedMacro(
                    id: UUID(), name: "Literal replacement",
                    steps: [
                        .findLiteral(text: "egg", matchCase: true, backwards: false),
                        .replaceSelection("milk")
                    ])
                try controller.play(edit, on: editor, repeats: 2)
                check(editor.text == "café milk milk 👩🏽‍💻", "native literal find/replace repeat captures parameters")
                editor.executeCommand("undo")
                check(editor.text == original, "native repeated macro is one Undo group")
                editor.executeCommand("selectAll")
                let failing = RecordedMacro(
                    id: UUID(), name: "Stop on missing search",
                    steps: [
                        .insertText("changed"),
                        .findLiteral(text: "absent", matchCase: false, backwards: false)
                    ])
                rejects("native missing search aborts") { try controller.play(failing, on: editor) }
                check(editor.text == "changed", "native earlier edit retained for explicit Undo")
                editor.executeCommand("undo")
                check(editor.text == original, "native partial replay remains one Undo")
                controller.startRecording()
                editor.executeCommand("newLine")
                let captured = try controller.finishRecording()
                check(
                    captured?.steps.contains(where: { $0.kind == .insertText }) == true,
                    "actual native newline recording remains saveable")
                controller.startRecording()
                editor.executeCommand("charRight")
                controller.willExecuteCommand("trimTrailing", on: editor)
                editor.executeCommand("trimTrailing")
                rejects("target-based trim cannot silently save partial recording") {
                    _ = try controller.finishRecording()
                }
                let clone = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
                clone.shareDocument(with: editor)
                controller.startRecording()
                editor.executeCommand("charRight")
                controller.editorDidFocus(clone)
                clone.executeCommand("newLine")
                rejects("clone focus switch invalidates incomplete recording") { _ = try controller.finishRecording() }
                // G337: reload and close announce the document through its primary view; a
                // recording started in the clone belongs to the same document.
                let cloneController = MacroController(editorProvider: { clone })
                cloneController.startRecording()
                clone.executeCommand("charRight")
                cloneController.editorWillReset(editor, reason: "Reloaded")
                rejects("reload through primary invalidates clone recording", message: "Reloaded") {
                    _ = try cloneController.finishRecording()
                }
                let unrelated = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
                cloneController.startRecording()
                clone.executeCommand("newLine")
                cloneController.editorWillReset(unrelated, reason: "Another document reloaded")
                check(
                    (try cloneController.finishRecording())?.steps.isEmpty == false,
                    "a reload of another document leaves the recording saveable")
                clone.executeCommand("undo")
                controller.startRecording()
                editor.executeCommand("charRight")
                controller.invalidateRecording(reason: "Automation invoked")
                rejects("automation invocation invalidates incomplete recording") {
                    _ = try controller.finishRecording()
                }
                controller.startRecording()
                editor.executeCommand("charRight")
                controller.editorWillReset(editor, reason: "Reloaded")
                rejects("reload cannot leave saveable partial macro") { _ = try controller.finishRecording() }
                controller.startRecording()
                editor.executeCommand("newLine")
                editor.executeCommand("undo")
                rejects("native Undo cannot silently save partial recording") { _ = try controller.finishRecording() }
                controller.startRecording()
                editor.executeCommand("charRight")
                controller.willExecuteCommand("zoomIn", on: editor)
                editor.executeCommand("zoomIn")
                check(
                    try controller.finishRecording()?.steps.count == 1,
                    "view-only zoom does not invalidate valid edit recording")
                // G369: playback states the read-only reason before any dialog or step.
                editor.text = "locked"
                editor.resetUndoHistory()
                editor.setSavePoint()
                _ = editor.setSelectionAnchor(0, caret: 0)
                let lockedRevision = editor.revision
                let replacing = RecordedMacro(
                    id: UUID(), name: "Replace", steps: [.replaceSelection("x")])
                editor.readOnly = true
                rejects(
                    "playback into a read-only document states that it is read-only",
                    message: "This document is read-only"
                ) { try controller.play(replacing, on: editor) }
                rejects(
                    "the playback dialog is not offered for a read-only document", message: "This document is read-only"
                ) { _ = try controller.playbackEditor() }
                check(
                    editor.text == "locked" && editor.revision == lockedRevision && !editor.modified,
                    "refused playback leaves text, revision and save point unchanged")
                // F207: a recorded replacement is not appended when the editor refused it.
                controller.startRecording()
                editor.executeCommand("charRight")
                if editor.replaceSelection("never") {
                    controller.recordSearch(.init(options: SearchOptions(), action: "replaceOne"), editor: editor)
                }
                check(
                    try controller.finishRecording()?.steps.map(\.kind) == [.command],
                    "a replacement the read-only editor refused is not recorded as a macro step")
                editor.readOnly = false
                check(try controller.playbackEditor() === editor, "a writable document is offered for playback")
                _ = editor.setSelectionAnchor(0, caret: 0)
                try controller.play(replacing, on: editor)
                check(editor.text == "xlocked", "a recorded replacement plays once the document is writable")
                editor.text = "a\nb\nc"
                editor.resetUndoHistory()
                _ = editor.setSelectionAnchor(0, caret: 0)
                let advance = RecordedMacro(
                    id: UUID(), name: "Advance", steps: [.command("charRight")])
                try controller.play(advance, on: editor, untilEnd: true)
                check(editor.selectionCaret == editor.text.utf8.count, "until-end playback reaches document boundary")
                _ = editor.setSelectionAnchor(0, caret: 0)
                let stalled = RecordedMacro(
                    id: UUID(), name: "No movement", steps: [.command("home")])
                rejects("until-end no-progress guard") { try controller.play(stalled, on: editor, untilEnd: true) }
                editor.text = "original"
                editor.resetUndoHistory()
                _ = editor.setSelectionAnchor(0, caret: 0)
                let typing = RecordedMacro(id: UUID(), name: "Typing", steps: [.insertText("x")])
                var calls = 0
                rejects("cancel playback between steps") {
                    try controller.play(
                        typing, on: editor, repeats: 100,
                        shouldCancel: {
                            calls += 1
                            return calls > 3
                        })
                }
                check(editor.text == "xxxoriginal", "cancel retains only completed steps")
                editor.executeCommand("undo")
                check(editor.text == "original", "cancelled playback remains one Undo")
                let search = RecordedMacro.Search(
                    query: "(egg)", replacement: "$1s", mode: 2, matchCase: true, wholeWord: false,
                    dotMatchesNewline: false, wrap: true, action: "replaceAll")
                let searchMacro = RecordedMacro(
                    id: UUID(), name: "Captured search", steps: [.search(search)])
                check(
                    try MacroLibrary.decode(MacroLibrary(macros: [searchMacro]).encoded()).macros[0] == searchMacro,
                    "all regex parameters roundtrip")
                var observed: RecordedMacro.Search?
                controller.searchPlayback = { captured, target in
                    observed = captured
                    target.replaceSelection("called")
                }
                try controller.play(searchMacro, on: editor)
                check(observed == search, "search playback uses captured parameters through adapter")
                // G366: with the real Find-window playback, a recorded Next that finds nothing stops the macro
                // before the following step can edit the line the caret was left on.
                let finderSuite = "TextTankMacroChecks-" + UUID().uuidString
                let finderDefaults = try requireValue(
                    UserDefaults(suiteName: finderSuite), "fixture: isolated defaults suite")
                defer { finderDefaults.removePersistentDomain(forName: finderSuite) }
                let finder = SearchController(defaults: finderDefaults)
                controller.searchPlayback = { captured, target in
                    var options = SearchOptions()
                    options.query = captured.query
                    options.replacement = captured.replacement
                    options.mode = SearchOptions.Mode(rawValue: captured.mode) ?? .normal
                    options.matchCase = captured.matchCase
                    options.wholeWord = captured.wholeWord
                    options.dotMatchesNewline = captured.dotMatchesNewline
                    options.wrap = captured.wrap
                    try finder.playRecorded(options: options, action: captured.action, on: target)
                }
                let todoSource = "TODO a\nkeep\nTODO b\nTODO c\ntail one\ntail two\n"
                let findNext = RecordedMacro.Search(
                    query: "TODO", replacement: "", mode: 0, matchCase: true, wholeWord: false,
                    dotMatchesNewline: false, wrap: false, action: "next")
                let deleteTodo = RecordedMacro(
                    id: UUID(), name: "Delete found lines",
                    steps: [.search(findNext), .command("deleteLine")])
                for untilEnd in [false, true] {
                    let label = untilEnd ? "until-end" : "repeat-500"
                    editor.text = todoSource
                    editor.resetUndoHistory()
                    editor.setSavePoint()
                    _ = editor.setSelectionAnchor(0, caret: 0)
                    var stopped = ""
                    do {
                        try controller.play(deleteTodo, on: editor, repeats: untilEnd ? 1 : 500, untilEnd: untilEnd)
                    } catch { stopped = error.localizedDescription }
                    check(
                        stopped.contains("recorded search did not match"),
                        "\(label) playback stops at the first recorded search with no match")
                    check(
                        editor.text == "keep\ntail one\ntail two\n",
                        "\(label) playback removes exactly the matching lines and leaves the rest")
                    editor.executeCommand("undo")
                    check(editor.text == todoSource && !editor.modified, "\(label) stopped playback is one Undo")
                }
                Checks.section("Recording fidelity") { try fidelityChecks(editor: editor, window: window) }
                Checks.section("Macros menu save and playback") {
                    try menuFlowChecks(editor: editor, support: isolatedSupport.url)
                }
                Checks.section("F155 Macro JSON manager") { try jsonManagerChecks(editor: editor) }
            #endif
            Checks.summary {
                "PASS MacroChecks: \(Checks.count) assertions; persistence/security checks; native integration only when TEXTTANK_NATIVE_MACRO_TEST is defined"
            }
        }
    }
}
