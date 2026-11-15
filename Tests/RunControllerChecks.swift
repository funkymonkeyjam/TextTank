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
            controller.apply(current)
            check(document.editor.text == "SECOND", "current preview applies explicit matching result")
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
            let stale = button()
            document.editor.text = "new edit"
            // F207: a result that can no longer be applied says why instead of beeping.
            rejects("a stale extension result says the document changed", expecting: RunFailure.documentChanged) {
                try controller.applyResult(stale)
            }
            check(
                document.editor.text == "new edit" && !stale.isEnabled, "stale extension result preserves newer edits")
            try controller.applyResult(stale)
            check(document.editor.text == "new edit", "a dropped extension result cannot be applied by a second click")
            controller.show(
                .success(result), command: sample, target: document.editor, revision: document.editor.revision,
                selection: false, anchor: 0, caret: 0)
            let locked = button()
            document.editor.readOnly = true
            rejects(
                "an extension result for a read-only document says it is read-only",
                message: "This document is read-only"
            ) { try controller.applyResult(locked) }
            check(
                document.editor.text == "new edit" && !locked.isEnabled,
                "a read-only document is not changed by an extension result")
            controller.editor = { document.editor }
            rejects("an extension is not started for a read-only document", message: "This document is read-only") {
                try controller.start(sample)
            }
            document.editor.readOnly = false
            // A second command while one runs is refused with the reason, and the first still finishes.
            let slow = ConfiguredRun(name: "Slow", executable: "/bin/sleep", arguments: ["30"])
            try controller.start(slow)
            rejects("a command started while another runs says one is already running", expecting: RunFailure.busy) {
                try controller.start(slow)
            }
            controller.perform(NSSelectorFromString("cancel:"), with: nil)
            var finished = false
            spinUntil(timeout: 20, "the cancelled command to finish") {
                if !finished { finished = (try? controller.start(sample)) != nil }
                return finished
            }
            spinUntil(timeout: 20, "the extension sample to finish") {
                NSApp.windows.contains { $0.title == sample.name && $0.isVisible }
            }
            controller.show(
                .success(result), command: sample, target: document.editor, revision: document.editor.revision,
                selection: false, anchor: 0, caret: 0)
            let closed = button()
            document.close()
            rejects("an extension result for a closed document says it is closed", expecting: RunFailure.documentClosed)
            {
                try controller.applyResult(closed)
            }
            check(document.editor.text == "new edit", "detached editor cannot receive extension result")
            Checks.summary { "PASS RunControllerChecks: \(Checks.count) assertions" }
        }
    }
}
