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
            // F278: applying a result is an unrecorded change; showing or refusing one is not.
            var unrecordable = 0
            controller.onUnrecordableAction = { unrecordable += 1 }
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
                stdout: Data("FIRST".utf8), stderr: Data(), status: 0, cancelled: false, truncated: false)
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
                        stdout: Data("SECOND".utf8), stderr: Data(), status: 0, cancelled: false, truncated: false)),
                command: sample, target: document.editor, revision: document.editor.revision, selection: false,
                anchor: 0, caret: 0)
            let current = button()
            controller.apply(old)
            check(document.editor.text == "original" && !old.isEnabled, "old preview cannot apply a newer result")
            check(unrecordable == 0, "showing a result and refusing a superseded one report no unrecordable action")
            controller.apply(current)
            check(document.editor.text == "SECOND", "current preview applies explicit matching result")
            check(unrecordable == 1, "applying an extension result reports one unrecordable action")
            document.editor.executeCommand("undo")
            check(document.editor.text == "original", "extension apply one Undo")
            let special = "\u{FEFF}identity\0tail"
            controller.show(
                .success(
                    RunResult(stdout: Data(special.utf8), stderr: Data(), status: 0, cancelled: false, truncated: false)
                ), command: sample, target: document.editor, revision: document.editor.revision, selection: false,
                anchor: 0, caret: 0)
            controller.apply(button())
            check(
                document.editor.text.utf8.elementsEqual(special.utf8),
                "extension output preserves leading FEFF and embedded NUL")
            controller.show(
                .success(result), command: sample, target: document.editor, revision: document.editor.revision,
                selection: false, anchor: 0, caret: 0)
            // Package 21 (F293, F294, G400): the result window is a panel that leaves the document
            // window main; Escape closes it only when no result is waiting to be applied.
            let resultPanel = try requireValue(
                NSApp.windows.last { $0.title == sample.name && $0.isVisible } as? NSPanel,
                "the Run result window is a panel")
            check(
                !resultPanel.canBecomeMain && !resultPanel.hidesOnDeactivate && !resultPanel.isFloatingPanel
                    && resultPanel.level == .normal && resultPanel.defaultButtonCell == nil,
                "the Run result panel cannot become main, does not float, stays when the application is deactivated and has no default button"
            )
            resultPanel.cancelOperation(nil)
            check(
                resultPanel.isVisible && button().isEnabled,
                "Escape does not discard a result that has not been applied")
            let cancelItem = try requireValue(
                controller.makeMenu().items.first { $0.title == "Cancel Running Command" },
                "fixture: the Cancel Running Command item")
            let configureItem = try requireValue(
                controller.makeMenu().items.first { $0.title == "Configure Command…" },
                "fixture: the Configure Command item")
            check(
                !controller.isRunning && !controller.validateMenuItem(cancelItem)
                    && controller.validateMenuItem(configureItem),
                "Cancel Running Command is disabled while nothing is running; the other Run items stay enabled")
            let stale = button()
            document.editor.text = "new edit"
            controller.apply(stale)
            check(document.editor.text == "new edit", "stale extension result preserves newer edits")
            // G338: a result captured through a split pane follows the document when the pane closes.
            let pane = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            pane.shareDocument(with: document.editor)
            controller.show(
                .success(result), command: sample, target: pane, revision: pane.revision, selection: false, anchor: 0,
                caret: 0)
            let moved = button()
            pane.retire(inFavorOf: document.editor)
            controller.apply(moved)
            check(
                document.editor.text == "FIRST" && !moved.isEnabled,
                "a whole-document result captured through a closed pane applies through the remaining view")
            document.editor.executeCommand("undo")
            _ = pane.setSelectionAnchor(0, caret: 3)
            controller.show(
                .success(result), command: sample, target: pane, revision: pane.revision, selection: true, anchor: 0,
                caret: 3)
            let withdrawn = button()
            pane.retire(inFavorOf: document.editor)
            controller.apply(withdrawn)
            check(
                document.editor.text == "new edit" && !withdrawn.isEnabled,
                "a selection result captured through a closed pane is withdrawn, never applied elsewhere")
            controller.show(
                .success(result), command: sample, target: document.editor, revision: document.editor.revision,
                selection: false, anchor: 0, caret: 0)
            let closed = button()
            document.close()
            controller.apply(closed)
            check(document.editor.text == "new edit", "detached editor cannot receive extension result")
            let spent = try requireValue(
                NSApp.windows.last { $0.title == sample.name && $0.isVisible } as? NSPanel,
                "fixture: the result panel with nothing left to apply")
            spent.cancelOperation(nil)
            check(!spent.isVisible, "Escape closes the Run result panel once nothing is waiting to be applied")
            Checks.summary { "PASS RunControllerChecks: \(Checks.count) assertions" }
        }
    }
}
