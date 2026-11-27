// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

/// DS-D10: local history on save, through the document's real save path and the existing
/// comparison and merge. The confirmation is observed through its injected presenter.
@MainActor enum LocalHistoryChecks {
    private static func save(
        _ document: TextDocument, to url: URL, _ operation: NSDocument.SaveOperationType = .saveOperation
    ) async throws {
        var outcome: Result<Void, Error>?
        document.save(to: url, ofType: TextDocument.plainTextType, for: operation) { error in
            outcome = error.map { .failure($0) } ?? .success(())
        }
        _ = await waitUntil("the save to finish") { outcome != nil }
        try outcome?.get()
        LocalHistory.store.waitUntilIdle()
    }
    /// The store names a file by its resolved path, as the document does.
    private static func key(_ url: URL) -> String { TextDocument.canonicalDiskURL(url).path }
    static func run(in root: URL) async throws {
        let previous = EditorServices.current, priorMenu = NSApp.mainMenu
        let delegate = AppDelegate()
        delegate.installEditorServices()
        delegate.buildMenus()
        let service = delegate.compare
        service.showWindows = false
        let priorStore = LocalHistory.store, priorAllowance = LocalHistory.allowsIsolatedSupport
        let priorConfirm = LocalHistory.confirmClear
        defer {
            service.windows.forEach { $0.window?.close() }
            LocalHistory.store = priorStore
            LocalHistory.allowsIsolatedSupport = priorAllowance
            LocalHistory.confirmClear = priorConfirm
            LocalHistory.forgetNewest()
            EditorServices.current = previous
            NSApp.mainMenu = priorMenu
        }
        let folder = root.appendingPathComponent("local-history", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let home = folder.appendingPathComponent("store/LocalHistory", isDirectory: true)
        let store = LocalHistoryStore(directory: home)
        LocalHistory.store = store
        LocalHistory.allowsIsolatedSupport = false
        LocalHistory.forgetNewest()
        let menu = try requireValue(NSApp.mainMenu?.item(withTitle: "Compare")?.submenu, "built Compare menu")
        let command = try requireValue(
            menu.item(withTitle: "Compare with Earlier Version…"), "V10 Compare with Earlier Version command")
        let clearing = try requireValue(menu.item(withTitle: "Clear Local History…"), "V10 Clear Local History command")
        check(
            command.target == nil && clearing.target === delegate
                && menu.items.filter { !$0.isSeparatorItem }.count <= 20,
            "V10 both commands are in the Compare menu, which stays within DS-23")

        let url = folder.appendingPathComponent("notes.txt")
        let doc = DocumentFactory.makeUntitled(display: false)
        defer { doc.close() }
        let view = try requireValue(doc.presentation, "V10 document tab")
        view.host.activate(view, focus: false)
        check(
            !doc.validateUserInterfaceItem(command) && command.toolTip?.contains("turned off") == true,
            "V10 with an isolated support folder history is off, and the command says so")
        LocalHistory.allowsIsolatedSupport = true
        check(
            !doc.validateUserInterfaceItem(command) && command.toolTip?.contains("Save the document first") == true,
            "V10 an untitled document has no earlier versions, and the command says why")
        _ = doc.editor.replaceSelection("one\nshared\n")
        LocalHistory.allowsIsolatedSupport = false
        try await save(doc, to: url, .saveAsOperation)
        check(
            !FileManager.default.fileExists(atPath: home.path),
            "V10 a check's isolated support folder gets no history unless the check asks")
        LocalHistory.allowsIsolatedSupport = true
        let first = Data("one\nshared\n".utf8)
        _ = doc.editor.setSelectionAnchor(0, caret: 3)
        _ = doc.editor.replaceSelection("uno")
        try await save(doc, to: url)
        var versions = try store.versions(forPath: key(url))
        check(
            try versions.map(\.kind) == [.saved, .replaced]
                && store.data(forPath: key(url), version: versions[1].id) == first
                && store.data(forPath: key(url), version: versions[0].id) == Data("uno\nshared\n".utf8),
            "V10 the first save over content history has not seen keeps what it replaced, then what it wrote")
        try store.clear(path: key(url))
        LocalHistory.forgetNewest()

        // Three saves, three versions.
        var written = [Data]()
        for text in ["first draft\nshared\n", "second draft\nshared\nmore\n", "third draft\nshared\nmore\nend\n"] {
            _ = doc.editor.setSelectionAnchor(0, caret: doc.editor.byteLength)
            _ = doc.editor.replaceSelection(text)
            try await save(doc, to: url)
            written.append(Data(text.utf8))
        }
        versions = try store.versions(forPath: key(url))
        // The first of the three replaced "uno…", which the cleared history no longer held.
        let saved = versions.filter { $0.kind == .saved }
        check(
            try saved.count == 3 && versions.count == 4 && versions.last?.kind == .replaced
                && saved.reversed().map { try store.data(forPath: key(url), version: $0.id) } == written
                && saved.allSatisfy { $0.format == FileFormat(encoding: .utf8, bom: false) },
            "V10 three saves list three saved versions, newest first, each with the exact bytes written")
        check(
            try Data(contentsOf: url) == written[2]
                && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("LocalHistory").path)
                && FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["notes.txt", "store"],
            "V10 nothing is kept beside the document")
        let modes = try FileManager.default.subpathsOfDirectory(atPath: home.path).map { name -> Int in
            let attributes = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(name).path)
            return (attributes[.posixPermissions] as! NSNumber).intValue
        }
        check(
            try Set(modes).isSubset(of: [0o600, 0o700]) && modes.filter { $0 == 0o600 }.count == 5
                && (FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as! NSNumber)
                    .intValue == 0o700,
            "V10 the store's folders are 0700 and its files 0600")
        check(
            doc.validateUserInterfaceItem(command) && command.toolTip == nil,
            "V10 the command is available for a saved file")
        check(
            LocalHistory.title(saved[0]).hasPrefix("Saved ") && LocalHistory.title(saved[0]).contains(" · ")
                && LocalHistory.title(versions[3]).hasPrefix("On disk before the save of "),
            "V10 a row names the date and the size, and says which bytes a save replaced")

        // Compare with the first of the three, then restore it through the existing apply path.
        _ = doc.editor.setSelectionAnchor(0, caret: 0)
        _ = doc.editor.replaceSelection("unsaved line\n")
        let current = try requireValue(doc.editor.checkedUTF8Data, "V10 current text")
        let revision = doc.editor.revision
        try service.compareEarlier(doc, version: saved[2])
        _ = await waitUntil("V10 the comparison to open") { service.windows.count == 1 }
        let comparison = try requireValue(service.windows.first, "V10 comparison with the earlier version")
        _ = await waitUntil("V10 the comparison to be ready") { comparison.readyForMerge }
        check(
            comparison.original?.snapshot.bytes == written[0] && comparison.modified?.snapshot.bytes == current
                && comparison.original?.canRefresh == false,
            "V10 the comparison shows the chosen version against the current text, the earlier side fixed")
        check(
            try comparison.merge.destination == .modified && !comparison.merge.canChoose(.original)
                && doc.editor.revision == revision && Data(contentsOf: url) == written[2],
            "V10 the earlier version is read-only: only the open document can be the destination, and nothing changed yet"
        )
        comparison.merge.perform(.selectAllChanges)
        try require(comparison.merge.canPerform(.applySelected), "V10 every change can be applied to the document")
        comparison.merge.applySelected()
        _ = await waitUntil("V10 the restore to be applied") {
            !comparison.merge.isBusy && comparison.merge.lastOutcome == .applied
        }
        check(
            doc.editor.checkedUTF8Data == written[0] && doc.isDocumentEdited,
            "V10 applying every change makes the document the earlier version, still unsaved")
        check(
            try Data(contentsOf: url) == written[2] && store.versions(forPath: key(url)).count == 4,
            "V10 restoring never writes the file or the history by itself")
        _ = doc.editor.executeCommand(.init(rawValue: "undo"))
        check(doc.editor.checkedUTF8Data == current, "V10 the restore is one Undo step")
        _ = doc.editor.executeCommand(.init(rawValue: "redo"))
        check(doc.editor.checkedUTF8Data == written[0], "V10 and one Redo step")
        comparison.window?.close()
        try await save(doc, to: url)
        versions = try store.versions(forPath: key(url))
        check(
            versions.count == 5 && versions[0].kind == .saved && versions[0].sha256 == saved[2].sha256,
            "V10 saving the restored text is kept as a new version like any other save")

        // Save Copy and an untitled document keep nothing.
        let copyURL = folder.appendingPathComponent("copy.txt")
        var copyError: Error?, copied = false
        doc.writeCopy(to: copyURL) {
            copyError = $0
            copied = true
        }
        _ = await waitUntil("V10 the copy to be written") { copied }
        store.waitUntilIdle()
        check(
            try copyError == nil && store.versions(forPath: key(copyURL)).isEmpty && store.usage().files == 1,
            "V10 Save Copy keeps no history for the copy")

        // A rename takes the history along; Save As leaves it with the earlier file.
        let renamed = folder.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: renamed)
        doc.fileURL = renamed
        store.waitUntilIdle()
        check(
            try store.versions(forPath: key(renamed)).map(\.id) == versions.map(\.id)
                && store.versions(forPath: key(url)).isEmpty,
            "V10 a renamed file keeps its history")
        let other = folder.appendingPathComponent("other.txt")
        _ = doc.editor.replaceSelection("for save as ")
        try await save(doc, to: other, .saveAsOperation)
        check(
            try store.versions(forPath: key(renamed)).count == 5 && store.versions(forPath: key(other)).count == 1
                && doc.fileURL == other,
            "V10 Save As starts a history for the new file and leaves the earlier file's history with it")

        // The setting off keeps nothing new.
        var options = delegate.settings.value
        check(options.keepsLocalHistory, "V10 the setting is on unless it is stored off")
        options.keepLocalHistory = false
        _ = try delegate.settings.save(options)
        _ = doc.editor.replaceSelection("while off ")
        try await save(doc, to: other)
        check(
            try store.versions(forPath: key(other)).count == 1 && !doc.validateUserInterfaceItem(command),
            "V10 with the setting stored off a save keeps no version and the command is unavailable")
        options.keepLocalHistory = nil
        _ = try delegate.settings.save(options)

        // Clear History: the confirmation, then only the copies.
        try Data("bystander".utf8).write(to: home.appendingPathComponent("not-history.txt"))
        var prompts = [LocalHistory.ClearPrompt](), answer = LocalHistory.ClearChoice.cancel
        LocalHistory.confirmClear = { prompt, _, reply in
            prompts.append(prompt)
            reply(answer)
        }
        let before = store.usage()
        check(delegate.validateMenuItem(clearing), "V10 Clear Local History is available")
        delegate.clearLocalHistory(clearing)
        _ = await waitUntil("V10 the clear confirmation to be asked") { prompts.count == 1 }
        let prompt = try requireValue(prompts.last, "V10 the clear confirmation")
        check(
            prompt.buttons.map(\.title) == ["Cancel", "Clear This File’s History", "Clear All History"]
                && prompt.buttons.map(\.choice) == [.cancel, .thisFile, .everything],
            "V10 the confirmation offers Cancel first, then this file, then everything (DS-41)")
        check(
            before == LocalHistoryUsage(files: 2, versions: 6, bytes: before.bytes)
                && prompt.detail.contains("6 earlier versions of 2 files, \(LocalHistory.size(before.bytes)) in all")
                && prompt.detail.contains("“\(doc.displayName ?? "")” accounts for 1 earlier version, ")
                && prompt.detail.contains("This cannot be undone.")
                && prompt.detail.contains("Your files and open documents are not changed."),
            "V10 the confirmation says what is deleted, how much, and that it cannot be undone (DS-43): \(prompt.detail)"
        )
        check(store.usage() == before, "V10 Cancel clears nothing")
        answer = .thisFile
        delegate.clearLocalHistory(clearing)
        _ = await waitUntil("V10 this file's history to be cleared") {
            prompts.count == 2
                && delegate.workspaceWindow.lastTabMessage.hasPrefix("Cleared 1 earlier version of this file")
        }
        check(
            try store.versions(forPath: key(other)).isEmpty && store.versions(forPath: key(renamed)).count == 5,
            "V10 clearing this file's history leaves every other file's")
        answer = .everything
        delegate.clearLocalHistory(clearing)
        _ = await waitUntil("V10 all history to be cleared") {
            prompts.count == 3
                && delegate.workspaceWindow.lastTabMessage.hasPrefix("Cleared 5 earlier versions of 1 file")
        }
        check(
            try store.usage() == LocalHistoryUsage(files: 0, versions: 0, bytes: 0)
                && FileManager.default.contentsOfDirectory(atPath: home.path) == ["not-history.txt"],
            "V10 clearing everything removes the copies and nothing else in the folder")
        check(
            try Data(contentsOf: renamed) == written[0] && FileManager.default.fileExists(atPath: other.path)
                && FileManager.default.fileExists(atPath: copyURL.path) && doc.isOpen,
            "V10 clearing changes no file and no open document")
        let asked = prompts.count
        delegate.clearLocalHistory(clearing)
        _ = await waitUntil("V10 the nothing-to-clear message") {
            delegate.workspaceWindow.lastTabMessage.contains("nothing to clear")
        }
        check(
            prompts.count == asked && delegate.workspaceWindow.lastTabMessage.contains("nothing to clear"),
            "V10 with nothing kept, the command says so instead of asking")
        try await fixRoundOne(delegate: delegate, doc: doc, folder: folder, command: command, clearing: clearing)
    }
    /// Fix round 1: a save never waits for the store, the version before the newest stays the
    /// pre-save content after an eviction, expiry runs with the switch off, and an unreadable
    /// settings file keeps nothing new and deletes nothing.
    private static func fixRoundOne(
        delegate: AppDelegate, doc: TextDocument, folder: URL, command: NSMenuItem, clearing: NSMenuItem
    ) async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Date()
            var now: Date {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            func advance(_ seconds: TimeInterval) {
                lock.lock()
                value += seconds
                lock.unlock()
            }
        }
        let clock = Clock()
        var limits = LocalHistoryLimits()
        limits.totalBytes = 100
        let home = folder.appendingPathComponent("store-two/LocalHistory", isDirectory: true)
        let store = LocalHistoryStore(directory: home, limits: limits, clock: { clock.now })
        LocalHistory.store = store
        LocalHistory.forgetNewest()
        func settle() async {
            store.waitUntilIdle()
            // The store's reply reaches the main thread on its next turns.
            for _ in 0..<5 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        func write(
            _ text: String, to document: TextDocument, _ url: URL,
            _ operation: NSDocument.SaveOperationType = .saveOperation
        )
            async throws
        {
            _ = document.editor.setSelectionAnchor(0, caret: document.editor.byteLength)
            _ = document.editor.replaceSelection(text)
            try await save(document, to: url, operation)
            await settle()
        }
        // Finding 4: the newest version of a file is evicted by another file's save.
        let small = folder.appendingPathComponent("small.txt"), large = folder.appendingPathComponent("large.txt")
        try await write("small one\n", to: doc, small, .saveAsOperation)
        let neighbour = DocumentFactory.makeUntitled(display: false)
        defer { neighbour.close() }
        clock.advance(10)
        try await write(String(repeating: "L", count: 95) + "\n", to: neighbour, large, .saveAsOperation)
        check(
            try store.versions(forPath: key(small)).isEmpty && store.versions(forPath: key(large)).count == 1,
            "history fix 4: fixture: another file's save evicted this file's only version")
        clock.advance(10)
        try FileManager.default.removeItem(at: large)
        try store.clear(path: key(large))
        try await write("small two\n", to: doc, small)
        let afterEviction = try store.versions(forPath: key(small))
        check(
            try afterEviction.map(\.kind) == [.saved, .replaced]
                && store.data(forPath: key(small), version: afterEviction[1].id) == Data("small one\n".utf8),
            "history fix 4: after its newest version was evicted, the next save again keeps what it replaced")
        clock.advance(10)
        try await write("small three\n", to: doc, small)
        check(
            try store.versions(forPath: key(small)).map(\.kind) == [.saved, .saved, .replaced],
            "history fix 4: an ordinary next save keeps only what it wrote: history already ends with what it replaced")
        // A record that fails leaves the newest version unknown, so the next save reads again.
        let manifestFolder = try requireValue(
            try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil).first,
            "history fix 4: the file's history folder")
        // The folder is moved aside and a plain file put in its place: nothing can be written there.
        let aside = home.appendingPathComponent("aside")
        try FileManager.default.moveItem(at: manifestFolder, to: aside)
        try Data().write(to: manifestFolder)
        clock.advance(10)
        try await write("small four\n", to: doc, small)
        _ = await waitUntil("history fix 4: the status line to report the version that was not kept") {
            let status = doc.presentation?.status
            return ((status?.stringValue ?? "") + (status?.toolTip ?? "")).contains(
                "An earlier version could not be kept")
        }
        try FileManager.default.removeItem(at: manifestFolder)
        try FileManager.default.moveItem(at: aside, to: manifestFolder)
        let status = doc.presentation?.status
        check(
            try store.versions(forPath: key(small)).count == 3 && Data(contentsOf: small) == Data("small four\n".utf8)
                && ((status?.stringValue ?? "") + (status?.toolTip ?? "")).contains(
                    "An earlier version could not be kept"),
            "history fix 4: fixture: a version that cannot be written does not fail the save, and the status line says so"
        )
        clock.advance(10)
        try await write("small five\n", to: doc, small)
        let afterFailure = try store.versions(forPath: key(small))
        check(
            try afterFailure.prefix(2).map(\.kind) == [.saved, .replaced]
                && store.data(forPath: key(small), version: afterFailure[1].id) == Data("small four\n".utf8),
            "history fix 4: after a failed record, the next save keeps the content that record missed")

        // Finding 6: a save, and the Clear command, never wait for the store's queue.
        let gate = DispatchSemaphore(value: 0)
        store.prune { _ in gate.wait() }
        _ = doc.editor.setSelectionAnchor(0, caret: 0)
        _ = doc.editor.replaceSelection("while the store is busy ")
        // Nothing remembered: before the fix this save asked the store, and waited for it.
        LocalHistory.forgetNewest()
        var finished = false
        doc.save(to: small, ofType: TextDocument.plainTextType, for: .saveOperation) { _ in finished = true }
        let saved = await waitUntil(timeout: 5, "history fix 6: the save to finish while the store's queue is blocked")
        { finished }
        var busyPrompts = 0
        let priorConfirm = LocalHistory.confirmClear
        LocalHistory.confirmClear = { _, _, reply in
            busyPrompts += 1
            reply(.cancel)
        }
        delegate.clearLocalHistory(clearing)
        check(
            try saved && !doc.isDocumentEdited && Data(contentsOf: small).starts(with: Data("while the store".utf8))
                && busyPrompts == 0,
            "history fix 6: a save completes, and Clear returns, while the history queue is blocked")
        gate.signal()
        await settle()
        _ = await waitUntil("history fix 6: the clear confirmation once the store answers") { busyPrompts == 1 }
        LocalHistory.confirmClear = priorConfirm
        check(
            try store.versions(forPath: key(small)).first?.kind == .saved,
            "history fix 6: the version handed over during the wait is kept once the queue is free")

        // A rename that only changes case keeps the history, whatever the volume does with case.
        let cased = folder.appendingPathComponent("SMALL.txt")
        let kept = try store.versions(forPath: key(small)).map(\.id)
        try require(rename(small.path, cased.path) == 0, "history fix 7: fixture: the file is renamed by case alone")
        doc.fileURL = cased
        await settle()
        check(
            try store.versions(forPath: key(cased)).map(\.id) == kept,
            "history fix 7: a rename that changes only the case of the name keeps the history")
        // Bytes another program wrote are not labelled with the document's own format.
        clock.advance(10)
        try Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]).write(to: cased, options: .atomic)
        _ = doc.editor.setSelectionAnchor(0, caret: doc.editor.byteLength)
        _ = doc.editor.replaceSelection("after an outside rewrite\n")
        // Save As over the document's own file is the one save allowed over an outside change.
        try doc.writeSafely(to: cased, ofType: TextDocument.plainTextType, for: .saveAsOperation)
        await settle()
        let outside = try store.versions(forPath: key(cased))
        check(
            outside.prefix(2).map(\.kind) == [.saved, .replaced] && outside[1].format == nil
                && outside[0].format == FileFormat(encoding: .utf8, bom: false),
            "history fix 7: bytes that another program wrote are kept without the document's format, to be detected on reading"
        )
        check(
            try LocalHistory.snapshot(
                store.data(forPath: key(cased), version: outside[1].id), of: outside[1], name: "x"
            ).bytes == Data("hi".utf8),
            "history fix 7: and they are decoded by detection when compared")

        // Finding 2: versions expire while the switch is off.
        var options = delegate.settings.value
        options.keepLocalHistory = false
        _ = try delegate.settings.save(options)
        clock.advance(31 * 24 * 60 * 60)
        check(
            try store.versions(forPath: key(cased)).count >= 2,
            "history fix 2: fixture: versions older than thirty days are still there")
        LocalHistory.pruneAtLaunch()
        await settle()
        check(
            store.usage() == LocalHistoryUsage(files: 0, versions: 0, bytes: 0),
            "history fix 2: with the switch off the launch prune still expires old versions")
        options.keepLocalHistory = nil
        _ = try delegate.settings.save(options)

        // An unreadable settings file: keep nothing new, delete nothing.
        clock.advance(10)
        try await write("kept before settings broke\n", to: doc, cased)
        let settingsURL = delegate.settings.url, good = try Data(contentsOf: settingsURL)
        try Data("{ not settings".utf8).write(to: settingsURL)
        let unreadable = AppDelegate()
        unreadable.installEditorServices()
        defer {
            try? good.write(to: settingsURL)
            delegate.installEditorServices()
        }
        try require(
            unreadable.settings.loadFailureMessage != nil, "history fix 7: fixture: the settings file cannot be read")
        let before = try store.versions(forPath: key(cased)).map(\.id)
        check(
            !LocalHistory.isEnabled && !doc.validateUserInterfaceItem(command),
            "history fix 7: with unreadable settings local history is off, not silently on")
        clock.advance(10)
        try await write("saved while settings are unreadable\n", to: doc, cased)
        clock.advance(31 * 24 * 60 * 60)
        LocalHistory.pruneAtLaunch()
        await settle()
        check(
            try store.versions(forPath: key(cased)).map(\.id) == before && !before.isEmpty,
            "history fix 7: with unreadable settings a save keeps no version and nothing kept is expired or deleted")
    }
}
