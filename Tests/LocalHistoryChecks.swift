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
            "V10 the earlier version is read-only: only the open document can be the destination, and nothing changed yet")
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
            "V10 the confirmation says what is deleted, how much, and that it cannot be undone (DS-43): \(prompt.detail)")
        check(store.usage() == before, "V10 Cancel clears nothing")
        answer = .thisFile
        delegate.clearLocalHistory(clearing)
        check(
            try store.versions(forPath: key(other)).isEmpty && store.versions(forPath: key(renamed)).count == 5,
            "V10 clearing this file's history leaves every other file's")
        answer = .everything
        delegate.clearLocalHistory(clearing)
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
        check(
            prompts.count == asked && delegate.workspaceWindow.lastTabMessage.contains("nothing to clear"),
            "V10 with nothing kept, the command says so instead of asking")
    }
}
