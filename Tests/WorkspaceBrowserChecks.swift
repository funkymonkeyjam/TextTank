// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
@main struct WorkspaceBrowserChecks {
    static func main() {
        Checks.run("WorkspaceBrowserChecks") {
            // F148: there is no bundle here, so the suite names the bundled language catalog itself.
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankBrowser-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            setenv("TEXTTANK_SUPPORT_DIRECTORY", root.appendingPathComponent("support").path, 1)
            defer {
                NSDocumentController.shared.documents.forEach { $0.close() }
                try? FileManager.default.removeItem(at: root)
            }
            _ = NSApplication.shared
            let folder = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("café.txt")
            try Data("café 👩🏽‍💻\n".utf8).write(to: source)
            let nested = folder.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden"))
            let symlink = folder.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
            let fifo = folder.appendingPathComponent("pipe")
            check(mkfifo(fifo.path, 0o600) == 0, "create FIFO")
            let listing = try WorkspaceBrowserStore.list(folder)
            check(listing.entries.count == 2 && listing.skipped == 3, "listing skips hidden symlink FIFO")
            check(listing.entries.first?.directory == true, "directories before files")
            check(
                try WorkspaceBrowserStore.list(folder, showHidden: true).entries.count == 3, "explicit hidden listing")
            check(try WorkspaceBrowserStore.list(folder, limit: 1).truncated, "listing cap visible")
            rejects("FIFO cannot be listed") { _ = try WorkspaceBrowserStore.list(fifo) }
            rejects("symlink cannot be listed") { _ = try WorkspaceBrowserStore.list(symlink) }
            let configuration = root.appendingPathComponent("state/browser.json")
            let store = WorkspaceBrowserStore(url: configuration)
            try store.addFolder(folder)
            try store.addFolder(folder)
            check(store.state.folders.count == 1, "duplicate root no-op")
            let reloaded = WorkspaceBrowserStore(url: configuration)
            check(reloaded.state.folders.map(\.path) == [folder.standardizedFileURL.path], "folder survives restart")
            try store.noteRecent(source)
            try store.noteRecent(source)
            check(store.state.recent.map(\.path) == [source.standardizedFileURL.path], "recent dedup")
            var invalid = store.state
            invalid.version = 2
            let before = try Data(contentsOf: configuration)
            rejects("future version rejected") { try store.save(invalid) }
            check(try Data(contentsOf: configuration) == before, "invalid save leaves prior bytes")
            let controller = WorkspaceBrowserController(storeURL: configuration, recordsSystemRecent: false)
            let document = try controller.open(source)
            check(document.editor.text == "café 👩🏽‍💻\n" && !document.isDocumentEdited, "browser opens exact clean Unicode")
            document.editor.replaceSelection("dirty ")
            let text = document.editor.text, revision = document.editor.revision
            try Data("externally changed".utf8).write(to: source)
            let again = try controller.open(source)
            check(
                again === document && document.editor.text == text && document.editor.revision == revision,
                "existing dirty document preserved")
            rejects("FIFO open rejects without blocking") { _ = try controller.open(fifo) }
            rejects("symlink open rejects") { _ = try controller.open(symlink) }
            let bad = folder.appendingPathComponent("bad.txt")
            try Data([0xFF]).write(to: bad)
            let documents = NSDocumentController.shared.documents.count
            rejects("bad UTF8 open rejects") { _ = try controller.open(bad) }
            check(NSDocumentController.shared.documents.count == documents, "failed decode creates no document")
            controller.show(nil)
            check(controller.window != nil && controller.window?.contentView != nil, "native browser built")
            let menu = controller.menu()
            controller.menuNeedsUpdate(menu)
            check((menu.items.last?.submenu?.items.count ?? 0) > 0, "recent native menu populated")
            try store.removeFolder(folder)
            check(
                store.state.folders.isEmpty && FileManager.default.fileExists(atPath: source.path),
                "remove folder preserves files")
            let corruptURL = root.appendingPathComponent("corrupt-state.json")
            let corruptBytes = Data("{invalid JSON, retain me".utf8)
            try corruptBytes.write(to: corruptURL)
            let corruptStore = WorkspaceBrowserStore(url: corruptURL)
            check(corruptStore.loadError != nil, "corrupt state reports load error")
            rejects("corrupt state cannot be silently replaced") { try corruptStore.noteRecent(source) }
            check(try Data(contentsOf: corruptURL) == corruptBytes, "corrupt state preserved after persistence attempt")
            let fresh = folder.appendingPathComponent("fresh.txt")
            try Data("fresh".utf8).write(to: fresh)
            let corruptController = WorkspaceBrowserController(storeURL: corruptURL, recordsSystemRecent: false)
            _ = try corruptController.open(fresh)
            check(
                try Data(contentsOf: corruptURL) == corruptBytes,
                "opening document preserves corrupt workspace evidence")
            let watched = try corruptController.open(fresh)
            let monitor = DocumentMonitor()
            try monitor.start(watched)
            func waitFor(_ wanted: DocumentMonitorStatus, line: UInt = #line) {
                spinUntil("the document monitor to report \(wanted)", line: line) { monitor.status == wanted }
                check(monitor.status == wanted, "background monitor result", line: line)
            }
            waitFor(.unchanged)
            try Data("changed on disk".utf8).write(to: fresh)
            monitor.poll()
            waitFor(.changed)
            check(watched.editor.text == "fresh", "monitor never automatically reloads")
            watched.editor.replaceSelection("local edit")
            rejects("monitor cannot reload dirty document") {
                try monitor.reload(expectedRevision: watched.editor.revision)
            }
            check(watched.editor.text.contains("local edit"), "dirty monitor preserves edits")
            let staleRevision = watched.editor.revision
            watched.editor.replaceSelection("newer")
            rejects("monitor rejects stale explicit reload") { try monitor.reload(expectedRevision: staleRevision) }
            watched.editor.executeCommand("undo")
            watched.editor.executeCommand("undo")
            try monitor.reload(expectedRevision: watched.editor.revision)
            check(watched.editor.text == "changed on disk", "explicit clean monitor reload")
            try FileManager.default.removeItem(at: fresh)
            monitor.poll()
            waitFor(.missing)
            check(watched.editor.text == "changed on disk", "missing monitored file preserves text")
            monitor.stop()
            check(monitor.status == .stopped && monitor.document == nil, "monitor stops explicitly")
            let app = AppDelegate()
            let previousDelegate = NSApp.delegate
            NSApp.delegate = app
            defer { NSApp.delegate = previousDelegate }
            let python = folder.appendingPathComponent("extension-only.py")
            try Data("value = 1".utf8).write(to: python)
            let detected = try controller.open(python)
            check(
                detected.languageIdentifier == "python",
                "workspace filename assigned before extension language detection")
            // G373: a language chosen by hand survives Reload and Revert; only the first load detects.
            func firstColor(_ editor: TTEditor) -> NSColor? {
                editor.attributedText(forSelection: false).attribute(.foregroundColor, at: 0, effectiveRange: nil)
                    as? NSColor
            }
            let scriptURL = folder.appendingPathComponent("manual-choice.py")
            try Data("return 42;".utf8).write(to: scriptURL)
            let manual = try controller.open(scriptURL)
            let manualReference = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 200)),
                pythonReference = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            manualReference.text = "return 42;"
            pythonReference.text = "return 42;"
            check(
                manual.languageIdentifier == "python"
                    && app.languages.apply(identifier: "javascript", to: manual.editor)
                    && app.languages.apply(identifier: "javascript", to: manualReference)
                    && app.languages.apply(identifier: "python", to: pythonReference),
                "fixture: a Python file is switched to JavaScript by hand")
            manual.languageIdentifier = "javascript"
            check(
                firstColor(manualReference) != nil && firstColor(manualReference) != firstColor(pythonReference),
                "fixture: the two languages colour the sample differently")
            try manual.reload(using: .utf8)
            check(
                manual.languageIdentifier == "javascript" && manual.editor.text == "return 42;"
                    && firstColor(manual.editor) == firstColor(manualReference),
                "Reload with an encoding keeps the manually chosen language and its styling")
            try manual.revert(toContentsOf: scriptURL, ofType: "Plain Text")
            check(
                manual.languageIdentifier == "javascript" && firstColor(manual.editor) == firstColor(manualReference),
                "Revert keeps the manually chosen language and its styling")
            let untouched = try controller.open(python)
            try untouched.reload(using: .utf8)
            check(untouched.languageIdentifier == "python", "a detected language is kept across Reload as well")
            manual.close()
            let sessionText = "return 42;"
            let snapshot = SessionDocument(
                id: UUID(), originalURL: nil, text: sessionText, format: FileFormat(), isDirty: true,
                selection: SessionSelection(anchorByte: 0, caretByte: 0), bookmarks: [], language: "javascript",
                originalSHA256: nil)
            let restored = try WorkspaceController().restore(
                WorkspaceSession(
                    id: UUID(), name: "Language restoration", documents: [snapshot], activeDocumentID: snapshot.id))[0]
            let expected = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            expected.text = sessionText
            check(
                app.languages.apply(identifier: "javascript", to: expected),
                "expected mapped JavaScript profile applies")
            let actualColor =
                restored.editor.attributedText(forSelection: false).attribute(
                    .foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            let expectedColor =
                expected.attributedText(forSelection: false).attribute(.foregroundColor, at: 0, effectiveRange: nil)
                as? NSColor
            check(
                restored.languageIdentifier == "javascript" && actualColor == expectedColor,
                "session uses mapped lexer and configured keyword styling")
            check(
                restored.editor.text == sessionText && restored.isDocumentEdited,
                "session language restore preserves unsaved text")
            var missing = snapshot
            missing.language = "missing-profile"
            let fallback = try WorkspaceController().restore(
                WorkspaceSession(id: UUID(), name: "Unavailable language", documents: [missing], activeDocumentID: nil))[
                    0]
            check(
                fallback.languageIdentifier == LanguageProfile.plainTextID && fallback.editor.text == sessionText,
                "unknown session language safely falls back to plain text")
            // F96: one plain-text identifier. Sessions written before it existed say "null" or nothing.
            var legacy = snapshot
            for stored in ["null", nil] as [String?] {
                legacy.language = stored
                let plain = try WorkspaceController().restore(
                    WorkspaceSession(id: UUID(), name: "Legacy plain", documents: [legacy], activeDocumentID: nil))[0]
                check(
                    plain.languageIdentifier == LanguageProfile.plainTextID
                        && app.languages.profile(identifier: plain.languageIdentifier)?.lexer == "null"
                        && (plain.windowControllers.first as? EditorWindowController)?.status.stringValue.contains(
                            "unavailable") == false
                        && plain.editor.text == sessionText,
                    "a session that stored \(stored ?? "no language") restores as the Plain Text profile")
            }
            check(
                TextDocument().languageIdentifier == LanguageProfile.plainTextID
                    && app.languages.profile(identifier: TextDocument().languageIdentifier)?.title != nil,
                "a new document's language is a real profile, so style and function commands accept it")
            controller.window?.close()
            Checks.summary { "WorkspaceBrowserChecks: \(Checks.count) assertions passed" }
        }
    }
}
