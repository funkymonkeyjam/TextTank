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
    #endif
    static func main() {
        Checks.run("MacroChecks") {
            let id = UUID()
            var macro = RecordedMacro(
                id: id, name: "My edit",
                steps: [
                    .init(kind: .insertText, text: "½ café 👩🏽‍💻\0\r\n"),
                    .init(kind: .command, command: "charLeft"),
                    .init(kind: .findLiteral, text: "$()", matchCase: true, backwards: true),
                    .init(kind: .replaceSelection, text: "2 eggs")
                ])
            let library = MacroLibrary(macros: [macro])
            let data = try library.encoded()
            check(try MacroLibrary.decode(data) == library, "capture data exact Unicode/NUL and find params roundtrip")
            macro.name = "Renamed"
            check(
                try MacroLibrary.decode(MacroLibrary(macros: [macro]).encoded()).macros[0].id == id,
                "rename retains stable ID")
            let json = String(data: data, encoding: .utf8)!
            rejects("unknown command cannot launch shell", message: "Unrecognized or unsafe macro command") {
                _ = try MacroLibrary.decode(Data(json.replacingOccurrences(of: "charLeft", with: "executeShell").utf8))
            }
            rejects("unknown step kind", where: { $0 is DecodingError }) {
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
            invalid.steps = [.init(kind: .command, command: "undo")]
            rejects("undo command cannot escape grouped replay", message: "Unrecognized or unsafe macro command") {
                try invalid.validate()
            }
            invalid.steps = [.init(kind: .findLiteral, text: "", matchCase: false, backwards: false)]
            rejects("empty find") { try invalid.validate() }
            invalid.steps = [.init(kind: .findLiteral, text: "needle")]
            rejects("missing captured find parameters") { try invalid.validate() }
            invalid.steps = [.init(kind: .insertText, text: "x", command: "cut")]
            rejects("incompatible parameters") { try invalid.validate() }
            rejects("duplicate macro ID", message: "duplicate IDs") {
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
                        .init(kind: .findLiteral, text: "egg", matchCase: true, backwards: false),
                        .init(kind: .replaceSelection, text: "milk")
                    ])
                try controller.play(edit, on: editor, repeats: 2)
                check(editor.text == "café milk milk 👩🏽‍💻", "native literal find/replace repeat captures parameters")
                editor.executeCommand("undo")
                check(editor.text == original, "native repeated macro is one Undo group")
                editor.executeCommand("selectAll")
                let failing = RecordedMacro(
                    id: UUID(), name: "Stop on missing search",
                    steps: [
                        .init(kind: .insertText, text: "changed"),
                        .init(kind: .findLiteral, text: "absent", matchCase: false, backwards: false)
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
                    id: UUID(), name: "Replace", steps: [.init(kind: .replaceSelection, text: "x")])
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
                if editor.replaceSelection("never") { controller.recordReplace(text: "never", editor: editor) }
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
                    id: UUID(), name: "Advance", steps: [.init(kind: .command, command: "charRight")])
                try controller.play(advance, on: editor, untilEnd: true)
                check(editor.selectionCaret == editor.text.utf8.count, "until-end playback reaches document boundary")
                _ = editor.setSelectionAnchor(0, caret: 0)
                let stalled = RecordedMacro(
                    id: UUID(), name: "No movement", steps: [.init(kind: .command, command: "home")])
                rejects("until-end no-progress guard") { try controller.play(stalled, on: editor, untilEnd: true) }
                editor.text = "original"
                editor.resetUndoHistory()
                _ = editor.setSelectionAnchor(0, caret: 0)
                let typing = RecordedMacro(id: UUID(), name: "Typing", steps: [.init(kind: .insertText, text: "x")])
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
                    id: UUID(), name: "Captured search", steps: [.init(kind: .search, search: search)])
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
                    steps: [.init(kind: .search, search: findNext), .init(kind: .command, command: "deleteLine")])
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
                Checks.section("Macros menu save and playback") {
                    try menuFlowChecks(editor: editor, support: isolatedSupport.url)
                }
            #endif
            Checks.summary {
                "PASS MacroChecks: \(Checks.count) assertions; persistence/security checks; native integration only when TEXTTANK_NATIVE_MACRO_TEST is defined"
            }
        }
    }
}
