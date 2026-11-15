// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
@main struct WorkspaceBrowserChecks {
    static func main() {
        Checks.run("WorkspaceBrowserChecks") {
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
                fallback.languageIdentifier == "null" && fallback.editor.text == sessionText,
                "unknown session language safely falls back to plain text")
            controller.window?.close()
            Checks.summary { "WorkspaceBrowserChecks: \(Checks.count) assertions passed" }
        }
    }
}
