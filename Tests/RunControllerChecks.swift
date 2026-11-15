import AppKit
@main struct RunControllerChecks {
    @MainActor static func main() {
        Checks.run("RunControllerChecks") {
            _ = NSApplication.shared
            let isolatedSupport = try IsolatedSupportDirectory("TextTankRunControllerChecks")
            defer { isolatedSupport.restore() }
            let document = TextDocument()
            document.makeWindowControllers()
            document.editor.text = "original"
            document.editor.resetUndoHistory()
            let controller = RunController(), sample = ConfiguredRun.uppercaseSample
            try controller.persist([sample])
            let originalConfiguration = try Data(contentsOf: controller.storage)
            let oversized = ConfiguredRun(
                name: "Too large", executable: "/usr/bin/printf",
                arguments: [String(repeating: "x", count: 600000), String(repeating: "y", count: 600000)])
            var refused = false
            do { try controller.persist([oversized]) } catch { refused = true }
            let preservedConfiguration = try Data(contentsOf: controller.storage)
            check(
                refused && preservedConfiguration == originalConfiguration,
                "oversized save preserves exact existing file")
            check(
                controller.makeMenu().items.contains { ($0.representedObject as? String) == sample.id.uuidString },
                "rejected save preserves active command identity")
            let restarted = RunController()
            check(
                restarted.makeMenu().items.contains { ($0.representedObject as? String) == sample.id.uuidString },
                "saved library restarts with original command identity")
            var boundary = ConfiguredRun(name: "Boundary", executable: "/usr/bin/printf", arguments: [""])
            let overhead = try ConfiguredRun.encodeLibrary([boundary]).count
            boundary.arguments = [String(repeating: "x", count: ConfiguredRun.maximumLibraryBytes - overhead)]
            try controller.persist([boundary])
            let boundaryRestart = RunController()
            check(
                boundaryRestart.makeMenu().items.contains {
                    ($0.representedObject as? String) == boundary.id.uuidString
                }, "exact 1 MiB saved file remains readable after restart")
            try controller.persist([sample])
            let result = RunResult(
                stdout: Data("FIRST".utf8), stderr: Data(), status: 0, reason: .finished)
            @MainActor func button() -> NSButton {
                NSApp.windows.flatMap { ($0.contentView as? NSStackView)?.views ?? [] }.compactMap { $0 as? NSButton }
                    .last { $0.identifier?.rawValue == "run.apply" }!
            }
            controller.show(
                .success(result), command: sample, target: document.editor, revision: document.editor.revision,
                selection: false, anchor: 0, caret: 0)
            let old = button()
            controller.show(
                .success(
                    RunResult(
                        stdout: Data("SECOND".utf8), stderr: Data(), status: 0, reason: .finished)),
                command: sample, target: document.editor, revision: document.editor.revision, selection: false,
                anchor: 0, caret: 0)
            let current = button()
            controller.apply(old)
            check(document.editor.text == "original" && !old.isEnabled, "old preview cannot apply a newer result")
            controller.apply(current)
            check(document.editor.text == "SECOND", "current preview applies explicit matching result")
            document.editor.executeCommand("undo")
            check(document.editor.text == "original", "extension apply one Undo")
            let special = "\u{FEFF}identity\0tail"
            controller.show(
                .success(
                    RunResult(stdout: Data(special.utf8), stderr: Data(), status: 0, reason: .finished)
                ), command: sample, target: document.editor, revision: document.editor.revision, selection: false,
                anchor: 0, caret: 0)
            controller.apply(button())
            check(
                document.editor.text.utf8.elementsEqual(special.utf8),
                "extension output preserves leading FEFF and embedded NUL")
            controller.show(
                .success(result), command: sample, target: document.editor, revision: document.editor.revision,
                selection: false, anchor: 0, caret: 0)
            let stale = button()
            document.editor.text = "new edit"
            controller.apply(stale)
            check(document.editor.text == "new edit", "stale extension result preserves newer edits")
            controller.show(
                .success(result), command: sample, target: document.editor, revision: document.editor.revision,
                selection: false, anchor: 0, caret: 0)
            let closed = button()
            document.close()
            controller.apply(closed)
            check(document.editor.text == "new edit", "detached editor cannot receive extension result")
            Checks.section("apply gating") { try applyGating(controller, sample, button) }
            Checks.section("library") { try libraryChecks(controller, sample) }
            Checks.section("explicit runs") { try explicitRunChecks(controller) }
            Checks.section("lifetime") { try lifetimeChecks(controller, sample, button) }
            Checks.summary { "PASS RunControllerChecks: \(Checks.count) assertions" }
        }
    }
    /// The text of the result window titled `title`, if it is open.
    @MainActor static func resultText(_ title: String) -> String? {
        for window in NSApp.windows where window.title == title && window.isVisible {
            guard let stack = window.contentView as? NSStackView else { continue }
            for case let scroll as NSScrollView in stack.views {
                if let text = scroll.documentView as? NSTextView { return text.string }
            }
        }
        return nil
    }
    /// Chooses the command's own menu item, which is the only way the app starts a command.
    @MainActor static func choose(_ controller: RunController, _ command: ConfiguredRun) throws {
        let item = try requireValue(
            controller.makeMenu().items.first { ($0.representedObject as? String) == command.id.uuidString },
            "the Run menu has an item for \(command.name)")
        NSApp.sendAction(try requireValue(item.action, "the item has an action"), to: item.target, from: item)
    }
    static func isGone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
    /// Waits, without running the main run loop, for a command to write its process id to `file`.
    static func processID(in file: URL) -> pid_t? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n"),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }
    @MainActor static func applyGating(
        _ controller: RunController, _ sample: ConfiguredRun, _ button: @MainActor () -> NSButton
    ) throws {
        let document = TextDocument()
        document.makeWindowControllers()
        defer { document.close() }
        document.editor.text = "kept text"
        let editor = document.editor
        @MainActor func shown(_ result: RunResult, command: ConfiguredRun? = nil, selection: Bool = false) -> NSButton {
            controller.show(
                .success(result), command: command ?? sample, target: editor, revision: editor.revision,
                selection: selection, anchor: editor.selectionAnchor, caret: editor.selectionCaret)
            return button()
        }
        let good = Data("REPLACED".utf8)
        for reason in RunTermination.allCases where reason != .finished {
            let apply = shown(RunResult(stdout: good, stderr: Data(), status: 0, reason: reason))
            controller.apply(apply)
            check(
                !apply.isEnabled && editor.text == "kept text",
                "F65 a result that ended as \(reason) cannot be applied")
            check(
                resultText(sample.name)?.contains(reason.summary) == true
                    && resultText(sample.name)?.contains("cancelled/timed out") == false,
                "F65 the result window says the run ended as \(reason)")
        }
        for status: Int32 in [1, -1] {
            let apply = shown(RunResult(stdout: good, stderr: Data(), status: status, reason: .finished))
            controller.apply(apply)
            check(
                !apply.isEnabled && editor.text == "kept text", "a result with exit status \(status) cannot be applied")
        }
        let invalid = shown(RunResult(stdout: Data([0x41, 0xFF]), stderr: Data(), status: 0, reason: .finished))
        controller.apply(invalid)
        check(!invalid.isEnabled && editor.text == "kept text", "output that is not valid UTF-8 cannot be applied")
        var plain = sample
        plain.extensionMode = false
        let ordinary = shown(RunResult(stdout: good, stderr: Data(), status: 0, reason: .finished), command: plain)
        controller.apply(ordinary)
        check(!ordinary.isEnabled && editor.text == "kept text", "an ordinary command's output cannot be applied")
        try require(editor.setSelectionAnchor(0, caret: 4), "selection set")
        let moved = shown(RunResult(stdout: good, stderr: Data(), status: 0, reason: .finished), selection: true)
        try require(editor.setSelectionAnchor(5, caret: 9), "selection set")
        controller.apply(moved)
        check(editor.text == "kept text", "a result cannot be applied after the selection changed")
        try require(editor.setSelectionAnchor(0, caret: 4), "selection set")
        let same = shown(RunResult(stdout: good, stderr: Data(), status: 0, reason: .finished), selection: true)
        check(same.isEnabled, "a finished exit-0 UTF-8 extension result can be applied")
        controller.apply(same)
        check(editor.text == "REPLACED text", "the result replaces the unchanged selection only")
    }
    @MainActor static func libraryChecks(_ controller: RunController, _ sample: ConfiguredRun) throws {
        let other = ConfiguredRun(name: "Other", executable: "/usr/bin/printf", arguments: ["%s\n", "{file}"])
        func ids(_ menu: NSMenu) -> [String] { menu.items.compactMap { $0.representedObject as? String } }
        try controller.persist([sample, other])
        let menu = controller.makeMenu()
        let titles = menu.items.map(\.title)
        let separator = try requireValue(menu.items.firstIndex { $0.isSeparatorItem }, "the Run menu has a separator")
        let manage = try requireValue(titles.firstIndex(of: "Manage Commands…"), "the Run menu has Manage Commands…")
        check(
            manage < separator && menu.items[manage].action != nil && menu.items[manage].target === controller,
            "F137 Manage Commands… is in the fixed group above the saved commands")
        check(ids(menu) == [sample.id.uuidString, other.id.uuidString], "F137 saved commands keep their order")
        for command in [sample, other] {
            let item = try requireValue(
                menu.items.first { ($0.representedObject as? String) == command.id.uuidString }, "item for command")
            check(
                item.toolTip?.contains(command.executable) == true && item.toolTip == command.summary(),
                "F137 the item for \(command.name) shows what it executes")
        }
        check(
            menu.items.first { ($0.representedObject as? String) == sample.id.uuidString }?.toolTip?.hasPrefix(
                "text extension: ") == true, "F137 a text extension is marked in its tooltip")

        // Inspect: the text shown is the whole library and saving it unchanged changes nothing.
        let text = try controller.libraryText()
        check(
            text.contains("\"/usr/bin/tr\"") && text.contains(other.id.uuidString) && text.contains("\n"),
            "F137 the managed text shows each command's executable, arguments and id")
        check(
            try ConfiguredRun.decodeLibrary(Data(text.utf8)) == [sample, other],
            "F137 the managed text is the version-1 library")
        let before = try Data(contentsOf: controller.storage)
        try controller.replaceLibrary(json: Data(text.utf8))
        check(
            try Data(contentsOf: controller.storage) == before, "F137 saving the managed text unchanged keeps the file")

        // Edit: same id, new name and arguments.
        var edited = other
        edited.name = "Renamed"
        edited.arguments = ["%s", "{selection}"]
        try controller.replaceLibrary(json: try JSONEncoder().encode([sample, edited]))
        let editedItem = RunController().makeMenu().items.first {
            ($0.representedObject as? String) == other.id.uuidString
        }
        check(
            editedItem?.title == "Renamed" && editedItem?.toolTip == edited.summary(),
            "F137 an edited command keeps its id and shows its new name after restart")

        // Delete: removing the entry removes the command, here and after restart.
        try controller.replaceLibrary(json: try JSONEncoder().encode([sample]))
        check(
            ids(controller.makeMenu()) == [sample.id.uuidString]
                && ids(RunController().makeMenu()) == [sample.id.uuidString],
            "F137 a removed command is gone from the menu and after restart")
        try controller.persist([sample, other])
        try controller.persist([sample])
        check(
            !ids(controller.makeMenu()).contains(other.id.uuidString)
                && !ids(RunController().makeMenu()).contains(other.id.uuidString), "F137 delete round-trips")

        // Rejected edits leave the file and the menu alone.
        let saved = try Data(contentsOf: controller.storage)
        rejects("F137 text that is not a library is refused") {
            try controller.replaceLibrary(json: Data("{ not json".utf8))
        }
        var relative = other
        relative.executable = "printf"
        rejects("F137 an edited command with a relative executable is refused", expecting: RunFailure.invalid) {
            try controller.replaceLibrary(json: try JSONEncoder().encode([sample, relative]))
        }
        rejects("F137 two entries with one id are refused", expecting: RunFailure.invalid) {
            try controller.replaceLibrary(json: try JSONEncoder().encode([sample, sample]))
        }
        check(
            try Data(contentsOf: controller.storage) == saved && ids(controller.makeMenu()) == [sample.id.uuidString],
            "F137 a refused edit preserves the saved file and the menu")

        // A library at the 1 MiB limit can still be opened in Manage and saved, although its
        // indented text is longer than the limit.
        var boundary = ConfiguredRun(name: "Boundary", executable: "/usr/bin/printf", arguments: [""])
        let overhead = try ConfiguredRun.encodeLibrary([boundary]).count
        boundary.arguments = [String(repeating: "x", count: ConfiguredRun.maximumLibraryBytes - overhead)]
        try controller.persist([boundary])
        let boundaryText = Data(try controller.libraryText().utf8)
        check(
            boundaryText.count > ConfiguredRun.maximumLibraryBytes, "the indented text of a full library is over 1 MiB")
        try controller.replaceLibrary(json: boundaryText)
        check(
            ids(RunController().makeMenu()) == [boundary.id.uuidString],
            "F137 a library at the limit can be saved from Manage Commands")
        check(
            (controller.makeMenu().items.last?.toolTip?.count ?? .max) <= 301,
            "F137 the tooltip is bounded for a 1 MiB argument")
        try controller.persist([sample])

        // An unreadable file is never overwritten.
        let corrupt = Data("{invalid JSON, retain me".utf8)
        try corrupt.write(to: controller.storage)
        let damaged = RunController()
        check(ids(damaged.makeMenu()).isEmpty, "an unreadable library loads no commands")
        rejects("F137 Manage Commands cannot save over an unreadable library") {
            try damaged.replaceLibrary(json: try JSONEncoder().encode([sample]))
        }
        rejects("F137 an empty library cannot replace an unreadable one") {
            try damaged.replaceLibrary(json: Data("[]".utf8))
        }
        check(
            try Data(contentsOf: damaged.storage) == corrupt,
            "F137 an unreadable RunCommands.json is left byte for byte")
        try controller.persist([sample])
        check(RunController.manageHelp.contains("never runs"), "F137 the dialog says saving runs nothing")
        try manageDialogChecks(controller, sample, other)
        check(
            RunController.configureHelp.contains("--") && RunController.configureHelp.contains("{selection}")
                && RunController.configureHelp.contains("option"),
            "F143 Configure explains a selection that begins with -")
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    /// Opens Manage Commands… from its menu item and calls `step` each time a modal window is up,
    /// with a count of the calls so far, until the dialogs are gone. False if it had to be aborted.
    @MainActor static func manage(_ controller: RunController, _ step: @escaping (Int, [NSView]) -> Void) throws -> Bool
    {
        let item = try requireValue(
            controller.makeMenu().items.first { $0.title == "Manage Commands…" }, "the Manage Commands… item")
        let deadline = Date().addingTimeInterval(8)
        var calls = 0, aborted = false
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            guard let content = NSApp.modalWindow?.contentView else { return }
            if Date() > deadline {
                aborted = true
                NSApp.abortModal()
                return
            }
            step(calls, descendants(content))
            calls += 1
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        NSApp.sendAction(try requireValue(item.action, "its action"), to: item.target, from: item)
        return !aborted
    }
    @MainActor static func manageDialogChecks(
        _ controller: RunController, _ sample: ConfiguredRun, _ other: ConfiguredRun
    ) throws {
        func editor(_ views: [NSView]) -> NSTextView? {
            views.compactMap { $0 as? NSTextView }.first { $0.identifier?.rawValue == "run.manage.text" }
        }
        func press(_ title: String, _ views: [NSView]) {
            views.compactMap { $0 as? NSButton }.first { $0.title == title && !$0.isHidden }?.performClick(nil)
        }
        func ids() -> [String] { RunController().makeMenu().items.compactMap { $0.representedObject as? String } }
        try controller.persist([sample, other])
        let both = try Data(contentsOf: controller.storage)
        let onlySample = String(decoding: try JSONEncoder().encode([sample]), as: UTF8.self)
        var opened = "", labelled = false
        let cancelled = try manage(controller) { _, views in
            guard let text = editor(views) else { return }
            opened = text.string
            labelled = text.accessibilityLabel() == "Saved Run commands as JSON" && text.isEditable
            text.string = onlySample
            press("Cancel", views)
        }
        check(
            try cancelled && opened == controller.libraryText() && labelled,
            "F137 Manage Commands… opens on the saved commands in a labelled editor")
        check(try Data(contentsOf: controller.storage) == both, "F137 Cancel in Manage Commands saves nothing")
        var keptAfterError = false
        let refused = try manage(controller) { call, views in
            if let text = editor(views) {
                if call == 0 {
                    text.string = "[ not a library"
                    press("Save", views)
                } else {
                    keptAfterError = text.string == "[ not a library"
                    press("Cancel", views)
                }
            } else {
                press("OK", views)
            }
        }
        check(
            try refused && keptAfterError && Data(contentsOf: controller.storage) == both,
            "F137 a refused Save reports the error, keeps the edited text and saves nothing")
        let saved = try manage(controller) { _, views in
            guard let text = editor(views) else { return }
            text.string = onlySample
            press("Save", views)
        }
        check(saved && ids() == [sample.id.uuidString], "F137 Save in Manage Commands deletes the removed command")
        try controller.persist([sample])
    }
    @MainActor static func explicitRunChecks(_ controller: RunController) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TextTankRunController-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = try Data(contentsOf: controller.storage)
        defer { try? controller.replaceLibrary(json: previous) }

        // No process without an explicit Run action: loading, listing, inspecting and saving a
        // library that contains a command do not execute it; choosing its menu item does.
        let marker = folder.appendingPathComponent("marker")
        let touch = ConfiguredRun(name: "Leaves a marker", executable: "/usr/bin/touch", arguments: [marker.path])
        try controller.persist([touch])
        let restarted = RunController()
        let item = restarted.makeMenu().items.last
        _ = item?.toolTip
        try restarted.replaceLibrary(json: Data(try restarted.libraryText().utf8))
        restarted.show(
            .success(RunResult(stdout: Data(), stderr: Data(), status: 0, reason: .finished)), command: touch,
            target: nil, revision: 0, selection: false, anchor: 0, caret: 0)
        let delegate = AppDelegate()
        _ = delegate.runner.makeMenu()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        check(
            !FileManager.default.fileExists(atPath: marker.path),
            "no command runs when a library is loaded, listed, inspected, saved or shown")
        NSApp.windows.filter { $0.title == touch.name }.forEach { $0.close() }
        try choose(controller, touch)
        spinUntil("the chosen command to finish") { resultText(touch.name) != nil }
        check(FileManager.default.fileExists(atPath: marker.path), "choosing the command's menu item runs it")
        check(resultText(touch.name)?.hasPrefix("Exit 0 · finished") == true, "the result window reports the exit")

        // F142: the command starts in the document's folder, or at home when there is none.
        let pwd = ConfiguredRun(name: "Where am I", executable: "/bin/pwd", arguments: [])
        try controller.persist([pwd])
        func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
        let home = FileManager.default.homeDirectoryForCurrentUser
        func ranIn() throws -> String? {
            NSApp.windows.filter { $0.title == pwd.name }.forEach { $0.close() }
            try choose(controller, pwd)
            spinUntil("pwd to finish") { resultText(pwd.name) != nil }
            return (resultText(pwd.name)?.components(separatedBy: "\n").dropFirst(2).first).map {
                resolved(URL(fileURLWithPath: $0))
            }
        }
        controller.file = { folder.appendingPathComponent("saved.txt") }
        check(try ranIn() == resolved(folder), "F142 a command starts in the saved document's folder")
        controller.file = { nil }
        check(try ranIn() == resolved(home), "F142 a command for an unsaved document starts in the home folder")
        controller.file = { folder.appendingPathComponent("removed/saved.txt") }
        check(
            try ranIn() == resolved(home),
            "F142 a command for a document whose folder is gone still launches, from the home folder")
        controller.file = { nil }
        check(
            RunController.workingDirectory(for: folder.appendingPathComponent("marker/inside.txt")).path == home.path,
            "F142 a document path under a regular file falls back to the home folder")

        // F116: the wait is signalled by the worker, so it works while the main run loop is not
        // running, which is the situation at quit.
        func sleeper(_ name: String, _ file: URL) -> ConfiguredRun {
            ConfiguredRun(
                name: name, executable: "/bin/zsh",
                arguments: ["-c", "echo $$ > '\(file.path)'; exec /bin/sleep 30"], shellMode: true)
        }
        check(controller.cancelAndWait(timeout: 0), "F116 cancel and wait with nothing running returns at once")
        let first = folder.appendingPathComponent("first.pid"), long = sleeper("Sleeps", first)
        try controller.persist([long])
        try choose(controller, long)
        let firstPid = try requireValue(processID(in: first), "the command started")
        let asked = Date()
        let stopped = controller.cancelAndWait(timeout: 5), took = Date().timeIntervalSince(asked)
        check(stopped && took < 2, "F116 cancel and wait stops a running command without the main run loop")
        check(isGone(firstPid), "F116 the command's process is gone when cancel and wait returns")
        spinUntil("the cancelled run to be shown") { resultText(long.name) != nil }
        check(resultText(long.name)?.contains("· cancelled") == true, "F65 the cancelled run is shown as cancelled")

        // The quit hook itself.
        let second = folder.appendingPathComponent("second.pid"), atQuit = sleeper("Running at quit", second)
        try delegate.runner.persist([atQuit])
        try choose(delegate.runner, atQuit)
        let secondPid = try requireValue(processID(in: second), "the command started under the app delegate")
        check(!isGone(secondPid), "the command is running before the quit")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        check(isGone(secondPid), "F116 a command still running when TextTank quits is stopped")
        spinUntil("the run stopped at quit to be shown") { resultText(atQuit.name) != nil }
        NSApp.windows.filter { [touch.name, pwd.name, long.name, atQuit.name].contains($0.title) }.forEach {
            $0.close()
        }
    }
    @MainActor static func lifetimeChecks(
        _ controller: RunController, _ sample: ConfiguredRun, _ button: @MainActor () -> NSButton
    ) throws {
        // F117: a shown result does not keep an editor alive. A bare editor is used because a
        // closed document's own editor is not released promptly whatever Run does.
        weak var shownEditor: TTEditor?
        autoreleasepool {
            let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            editor.text = "short lived"
            shownEditor = editor
            controller.show(
                .success(RunResult(stdout: Data("X".utf8), stderr: Data(), status: 0, reason: .finished)),
                command: sample, target: editor, revision: editor.revision, selection: false, anchor: 0, caret: 0)
            check(button().isEnabled, "a result for a live editor is offered for Apply")
        }
        check(shownEditor == nil, "F117 a shown result does not keep an editor alive")
        let orphaned = button()
        controller.apply(orphaned)
        check(!orphaned.isEnabled, "F117 Apply for a deallocated editor does nothing and disables itself")

        // F117: neither does a run in flight, whose worker block must not own the editor.
        let slow = ConfiguredRun(
            name: "Slow extension", executable: "/bin/sleep", arguments: ["0.6"], extensionMode: true)
        let previous = try Data(contentsOf: controller.storage)
        defer { try? controller.replaceLibrary(json: previous) }
        try controller.persist([slow])
        weak var runningEditor: TTEditor?
        var provided: TTEditor?
        controller.editor = { provided }
        defer { controller.editor = { nil } }
        try autoreleasepool {
            let editor = TTEditor(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            editor.text = "in flight"
            runningEditor = editor
            provided = editor
            try choose(controller, slow)
            provided = nil
        }
        check(resultText(slow.name) == nil, "the slow command is still running")
        check(runningEditor == nil, "F117 a running command does not keep an editor alive")
        spinUntil("the slow command to finish") { resultText(slow.name) != nil }
        check(!button().isEnabled, "F117 a result for an editor released during the run cannot be applied")
        NSApp.windows.filter { $0.title == slow.name }.forEach { $0.close() }
    }
}
