@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch
import Darwin
@MainActor private final class SessionCancelState { var pressed = false, timedOut = false }

@main struct WorkspaceBrowserChecks {
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    /// Quick Open over open documents, recent files and workspace files.
    @MainActor static func quickOpenChecks(in root: URL) throws {
        let manager = FileManager.default
        let folder = root.appendingPathComponent("quick-open")
        let support = root.appendingPathComponent("quick-open-support")
        for directory in [folder, support] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func file(_ name: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
        let alphaURL = try file("alpha-open.txt"), betaURL = try file("beta-recent.txt")
        let goneURL = try file("gamma-gone.txt"), deltaURL = try file("delta-open.txt")
        _ = try file("epsilon-workspace.txt")
        let controller = WorkspaceBrowserController(
            storeURL: support.appendingPathComponent("WorkspaceBrowser.json"), recordsSystemRecent: false)
        let alpha = try controller.open(alphaURL)
        try controller.open(betaURL).close()
        try controller.open(goneURL).close()
        try manager.removeItem(at: goneURL)
        let untitled = DocumentFactory.makeUntitled()
        let delta = try controller.open(deltaURL)
        defer { [alpha, untitled, delta].filter(\.isOpen).forEach { $0.close() } }
        let untitledName = try requireValue(untitled.displayName, "fixture: the untitled document has a display name")
        try require(controller.store.state.folders.isEmpty, "fixture: this workspace has no folder")
        let host = try requireValue(alpha.presentation?.host, "fixture: the workspace window of the open documents")
        try require(host.active?.document === delta, "fixture: the document opened last is showing")

        controller.quickOpen(nil)
        let chooser = controller.fileChooser
        let panel = try requireValue(chooser.panel, "fixture: Quick Open is showing")
        @MainActor func rows(_ kind: String) -> [String] {
            panel.displayedRows.filter { $0.accessory == kind }.map(\.title)
        }
        check(
            rows("Open").contains("alpha-open.txt") && rows("Open").contains(untitledName)
                && rows("Recent").isEmpty && !chooser.isComplete,
            "Quick Open lists open documents at once, before any file has been looked at")
        spinUntil("Quick Open to finish checking recent files") { chooser.isComplete }
        let shown = panel.displayedRows
        let kinds = shown.map(\.accessory)
        check(
            kinds == kinds.filter { $0 == "Open" } + kinds.filter { $0 == "Recent" } && rows("Workspace").isEmpty
                && rows("Open").contains("alpha-open.txt") && rows("Open").contains("delta-open.txt")
                && rows("Recent").contains("beta-recent.txt"),
            "with no workspace folder Quick Open lists open documents, then recent files: \(shown.map(\.title))")
        check(
            shown.filter { $0.title == "alpha-open.txt" }.map(\.accessory) == ["Open"]
                && shown.filter { $0.title == "beta-recent.txt" }.map(\.accessory) == ["Recent"],
            "an open document is not listed again as the recent file it also is")
        check(
            !shown.contains { $0.title == "gamma-gone.txt" } && controller.store.state.recent.contains {
                $0.lastPathComponent == "gamma-gone.txt"
            },
            "a recent file that no longer exists is not listed")
        let untitledRow = shown.first { $0.title == untitledName }
        check(
            untitledRow?.accessory == "Open" && untitledRow?.detail == "Not saved yet"
                && untitledRow?.accessoryLabel == "Open document",
            "an untitled open document is listed by its display name")
        let add = try requireValue(
            descendants(panel.form.window.contentView!).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == WorkspaceQuickOpen.addFolderIdentifier
            }, "Quick Open's Add Folder button")
        let status = try requireValue(
            descendants(panel.form.window.contentView!).compactMap { $0 as? NSTextField }.first {
                $0.identifier?.rawValue == WorkspaceQuickOpen.statusIdentifier
            }, "Quick Open's status line")
        check(
            !add.isHidden && add.isEnabled && add.title == "Add Folder…"
                && status.stringValue.hasSuffix("Add a folder to the workspace to find its files here too."),
            "DS-85 without a workspace folder Quick Open offers Add Folder: \(status.stringValue)")
        let cell = try requireValue(
            panel.table.view(atColumn: 0, row: 0, makeIfNecessary: true), "fixture: the first Quick Open row")
        check(
            descendants(cell).compactMap { ($0 as? NSTextField)?.stringValue }.last == "Open",
            "a row carries a small label for its kind")

        // Choosing an open document shows its tab; it never opens a second copy.
        let openBefore = NSDocumentController.shared.documents.count, tabsBefore = host.presentations.count
        panel.filter.stringValue = "alpha-open"
        panel.refresh()
        let alphaRow = try requireValue(panel.displayedRows.first, "fixture: the row for alpha-open.txt")
        let choseAlpha = try panel.choose(alphaRow.id)
        check(
            alphaRow.title == "alpha-open.txt" && alphaRow.accessory == "Open" && choseAlpha,
            "the open document is found by name and can be chosen")
        check(
            host.active?.document === alpha && NSDocumentController.shared.documents.count == openBefore
                && host.presentations.count == tabsBefore,
            "choosing an open document selects its tab and opens no second copy")
        // The same when its tab is in the other group and that group is not the focused one.
        if host.setEditorLayout(.twoColumns), let alphaTab = alpha.presentation?.tabID,
            let deltaTab = delta.presentation
        {
            host.moveTabs([alphaTab], target: alphaTab, to: .second)
            host.show(deltaTab, sender: nil)
            try require(
                host.active?.document === delta && host.model.focusedGroup == .first,
                "fixture: the first group is focused and alpha-open.txt is in the second")
            panel.refresh()
            let grouped = try requireValue(panel.displayedRows.first, "fixture: the row for alpha-open.txt")
            let choseGrouped = try panel.choose(grouped.id)
            check(
                choseGrouped && host.active?.document === alpha && host.model.focusedGroup == .second
                    && NSDocumentController.shared.documents.count == openBefore
                    && host.presentations.count == tabsBefore,
                "an open document in another group is selected there, not opened again")
            check(
                controller.quickOpenDocuments().first { $0.name == "alpha-open.txt" }?.group == host.groupLabel(.second),
                "with two groups an open document's row names its group")
            _ = host.setEditorLayout(.single)
        } else {
            print("SKIP Quick Open across groups: the two-column layout does not fit this screen")
        }
        // A recent file opens as a document; a document closed meanwhile is reported, not reopened.
        panel.filter.stringValue = "beta-recent"
        panel.refresh()
        let betaRow = try requireValue(panel.displayedRows.first, "fixture: the row for beta-recent.txt")
        let choseBeta = try panel.choose(betaRow.id)
        check(
            betaRow.title == "beta-recent.txt" && betaRow.accessory == "Recent" && choseBeta
                && NSDocumentController.shared.documents.count == openBefore + 1
                && (host.active?.document as? TextDocument)?.fileURL?.lastPathComponent == "beta-recent.txt",
            "choosing a recent file opens it")
        NSDocumentController.shared.document(for: betaURL)?.close()
        panel.filter.stringValue = "delta-open"
        panel.refresh()
        let deltaRow = try requireValue(
            panel.displayedRows.first { $0.title == "delta-open.txt" }, "fixture: the row for delta-open.txt")
        let replacement = DocumentFactory.makeUntitled()
        delta.close()
        rejects("a document closed while Quick Open was showing is not reopened") { _ = try panel.choose(deltaRow.id) }
        replacement.close()
        panel.form.close()
        check(chooser.panel == nil && chooser.list.entries.isEmpty, "closing Quick Open releases its list")

        // The pure list: one row a file, whichever names reach it, and bounded checking.
        let link = root.appendingPathComponent("quick-open-link")
        try manager.createSymbolicLink(at: link, withDestinationURL: folder)
        var list = QuickOpenList()
        list.add(open: [.init(id: "one", name: "alpha-open.txt", url: alphaURL, group: nil)], inspecting: true)
        list.add(recent: [
            link.appendingPathComponent("beta-recent.txt"), link.appendingPathComponent("alpha-open.txt"), goneURL,
            betaURL, folder
        ])
        list.add(workspace: WorkspaceFileIndex.scan([folder]).files)
        check(
            list.entries.map { "\($0.kind.label) \($0.title)" } == [
                "Open alpha-open.txt", "Recent beta-recent.txt", "Workspace delta-open.txt",
                "Workspace epsilon-workspace.txt"
            ] && !list.limited,
            "one row a file by file identity, in the order open, recent, workspace: \(list.entries.map(\.title))")
        check(
            list.matches("epsilon").map(\.title) == ["epsilon-workspace.txt"]
                && list.matches("-open.").map(\.title) == ["alpha-open.txt", "delta-open.txt"]
                && list.matches("").count == 4 && list.matches("no-such-file-name").isEmpty,
            "Quick Open matches names across the three kinds, an open document first among equals")
        var late = QuickOpenList()
        late.add(recent: [betaURL], deadline: 0)
        var many = QuickOpenList()
        many.add(recent: Array(repeating: goneURL, count: QuickOpenList.recentLimit) + [betaURL])
        check(
            late.entries.isEmpty && late.limited && many.entries.isEmpty && many.limited,
            "recent files are checked up to a count and a deadline, and one not checked is left out")

        // The panel with a workspace folder, and the Add Folder button of one without.
        let direct = WorkspaceQuickOpen()
        var added = 0, opened: [(URL?, URL)] = []
        direct.show(
            roots: [folder], documents: [.init(id: "one", name: "alpha-open.txt", url: alphaURL, group: nil)],
            recent: [betaURL, alphaURL], select: { _ in true },
            open: { root, url in
                opened.append((root, url))
                return true
            }, addFolder: { added += 1 })
        let withFolder = try requireValue(direct.panel, "fixture: Quick Open with a workspace folder")
        spinUntil("Quick Open to read the workspace folder") { direct.isComplete }
        check(
            withFolder.displayedRows.map { "\($0.accessory) \($0.title)" } == [
                "Open alpha-open.txt", "Recent beta-recent.txt", "Workspace delta-open.txt",
                "Workspace epsilon-workspace.txt"
            ],
            "with a workspace folder its files follow the open documents and recent files, each file once")
        let hiddenAdd = descendants(withFolder.form.window.contentView!).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == WorkspaceQuickOpen.addFolderIdentifier
        }
        check(hiddenAdd?.isHidden == true, "Add Folder is offered only while the workspace has no folder")
        let workspaceRow = try requireValue(
            withFolder.displayedRows.first { $0.title == "epsilon-workspace.txt" }, "fixture: a workspace row")
        let choseWorkspace = try withFolder.choose(workspaceRow.id)
        check(
            choseWorkspace && opened.count == 1 && opened.first?.0 == folder
                && opened.first?.1.lastPathComponent == "epsilon-workspace.txt",
            "a workspace file is opened with the folder it was found in")
        withFolder.form.close()
        direct.show(roots: [], documents: [], recent: [], select: { _ in true }, open: { _, _ in true }) { added += 1 }
        let empty = try requireValue(direct.panel, "fixture: Quick Open with nothing to list")
        let emptyAdd = try requireValue(
            descendants(empty.form.window.contentView!).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == WorkspaceQuickOpen.addFolderIdentifier
            }, "the Add Folder button of an empty Quick Open")
        emptyAdd.performClick(nil)
        check(
            added == 1 && direct.panel == nil && !empty.form.window.isVisible,
            "Add Folder closes Quick Open and runs the workspace's Add Folder command once")

        // Shift-Command-O is a default that yields, and nothing else has the key.
        let item = controller.menuItem(.quickOpen)
        check(
            item is DefaultShortcutItem && item.keyEquivalent == "O" && item.keyEquivalentModifierMask == .command
                && ControlPresentation.shortcut(of: item) == "⇧⌘O" && item.target === controller,
            "Quick Open's shortcut is Shift-Command-O, a default that yields to one assigned in Settings")
        check(
            !EditorSettings.protectedShortcuts.contains("O") && !EditorCommand.defaultShortcuts.values.contains("O")
                && !EditorCommand.allCases.contains {
                    $0.extendedMenuShortcut.map { $0.key.lowercased() == "o" && $0.modifiers == [.command, .shift] } == true
                },
            "the key is not a protected or default editor shortcut, so saved shortcuts still load")
        var settings = EditorSettings()
        settings.setShortcut("O", for: EditorCommand.upper.rawValue)
        (item as? DefaultShortcutItem)?.applyEditorOverrides(settings)
        check(item.keyEquivalent.isEmpty, "a person's own Shift-Command-O shortcut is kept, and Quick Open gives up the key")
        (item as? DefaultShortcutItem)?.applyEditorOverrides(EditorSettings())
        check(item.keyEquivalent == "O", "fixture: the default shortcut returns")
    }
    @MainActor static func main() {
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
            NativeFixtureEnvironment.install()
            defer { NativeFixtureEnvironment.restore() }
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
            let quickRoot = root.appendingPathComponent("quick-files")
            let quickNested = quickRoot.appendingPathComponent("Sources")
            try FileManager.default.createDirectory(at: quickNested, withIntermediateDirectories: true)
            let quickFiles = ["QuickCapture.swift", "QuarterlyChart.txt", "Notes.md"]
            for name in quickFiles { try Data(name.utf8).write(to: quickNested.appendingPathComponent(name)) }
            let quick = WorkspaceFileIndex.scan([folder, quickRoot, quickNested])
            check(quick.files.count == Set(quick.files.map { $0.url.standardizedFileURL.absoluteString }).count
                && !quick.files.contains { $0.url == fifo || $0.url == symlink || $0.url.lastPathComponent.hasPrefix(".") },
                "Quick Open deduplicates overlapping workspace roots and skips hidden, linked and special entries")
            check(quick.matches("qckcp").map { $0.url.lastPathComponent } == ["QuickCapture.swift"]
                && quick.matches("QuarterlyChart.txt").first?.url.lastPathComponent == "QuarterlyChart.txt",
                "Quick Open fuzzy name matching and exact basename ranking")
            check(WorkspaceFileIndex.scan([quickRoot], limit: 1).limited
                && WorkspaceFileIndex.scan([quickRoot], directoryLimit: 1).limited
                && WorkspaceFileIndex.scan([quickRoot], deadline: 0).limited,
                "file, directory and elapsed scan limits are observable")
            check(quick.matches("NoSuchOwnedName").isEmpty && WorkspaceFileIndex.scan([]).files.isEmpty,
                "a missing match and an empty workspace do not select a file")
            // F109: the limit applies to what is shown, after sorting; skipped entries do not use it up.
            let twoShown = try WorkspaceBrowserStore.list(folder, limit: 2)
            check(
                twoShown.entries.count == 2 && twoShown.skipped == 3 && !twoShown.truncated,
                "hidden, symlink and special entries do not count toward the listing limit")
            let crowded = root.appendingPathComponent("crowded")
            try FileManager.default.createDirectory(at: crowded, withIntermediateDirectories: true)
            for index in [
                17, 3, 29, 0, 11, 24, 8, 1, 20, 5, 14, 27, 2, 9, 22, 6, 18, 4, 26, 12, 7, 21, 10, 28, 13, 16, 23, 15,
                19, 25
            ] {
                try Data().write(to: crowded.appendingPathComponent(String(format: "file%02d.txt", index)))
                try Data().write(to: crowded.appendingPathComponent(String(format: ".hidden%02d", index)))
            }
            try FileManager.default.createDirectory(
                at: crowded.appendingPathComponent("zz-last-folder"), withIntermediateDirectories: true)
            let firstFive = try WorkspaceBrowserStore.list(crowded, limit: 5)
            check(
                firstFive.entries.map(\.url.lastPathComponent)
                    == ["zz-last-folder", "file00.txt", "file01.txt", "file02.txt", "file03.txt"]
                    && firstFive.truncated && firstFive.skipped == 30,
                "a truncated listing shows the first entries in display order, not in directory order")
            let whole = try WorkspaceBrowserStore.list(crowded)
            check(
                whole.entries.count == 31 && !whole.truncated
                    && Array(whole.entries.prefix(5)) == firstFive.entries,
                "the truncated listing is a prefix of the whole listing")
            let folderLink = root.appendingPathComponent("project-link")
            try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
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
            // F93: one rule, the standardized path, for every comparison.
            try store.addFolder(URL(fileURLWithPath: folder.path, isDirectory: false))
            check(store.state.folders.count == 1, "a folder spelled without its trailing slash is the same root")
            try store.noteRecent(URL(fileURLWithPath: source.path, isDirectory: true))
            check(store.state.recent.count == 1, "a recent file spelled with a trailing slash is the same file")
            var localhost = try requireValue(
                URLComponents(url: folder, resolvingAgainstBaseURL: false), "fixture: folder URL components")
            localhost.host = "localhost"
            try store.addFolder(try requireValue(localhost.url, "fixture: localhost spelling of the folder"))
            check(store.state.folders.count == 1, "a localhost spelling of the folder is the same root")
            let respelled = WorkspaceBrowserStore(url: configuration)
            check(
                respelled.loadError == nil && respelled.state == store.state,
                "the stored workspace still loads after the respelled entries")
            rejects("a symbolic-link folder is refused with an explanation", message: "is a symbolic link") {
                try store.addFolder(folderLink)
            }
            rejects("a folder that does not exist is still refused") {
                try store.addFolder(root.appendingPathComponent("absent-folder"))
            }
            check(store.state.folders.count == 1, "a refused folder is not added")
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
            // The browser reads the bytes itself; the UTF-16 LE offer is still made for them.
            let nulFirst = folder.appendingPathComponent("nul-first-utf16.txt")
            try Data([0xFF, 0xFE, 0x00, 0x00, 0x68, 0x00, 0x69, 0x00]).write(to: nulFirst)
            var offer: ExplicitEncodingOpener?
            rejects(
                "a UTF-32-looking file opened from the browser offers the explicit UTF-16 LE open",
                where: {
                    offer = ($0 as NSError).recoveryAttempter as? ExplicitEncodingOpener
                    return offer?.url == nulFirst && offer?.encoding == .utf16LE
                        && ($0 as NSError).localizedRecoveryOptions == ["Open as UTF-16 LE", "Cancel"]
                }
            ) { _ = try controller.open(nulFirst) }
            check(NSDocumentController.shared.documents.count == documents, "the refused open creates no document")
            let explicit = try requireValue(offer, "fixture: the offer carries its opener").open(display: false)
            check(
                explicit.editor.text == "\0hi" && explicit.format == FileFormat(encoding: .utf16LE, bom: true),
                "accepting the offer opens the same bytes as UTF-16 LE")
            explicit.close()
            controller.show(nil)
            check(controller.window != nil && controller.window?.contentView != nil, "native browser built")
            // F91: the Open Documents list follows the documents without Refresh and without the status line.
            @MainActor func listed() -> Int { controller.outlineView(controller.outline, numberOfChildrenOfItem: nil) }
            func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            check(
                listed() == NSDocumentController.shared.documents.count && listed() > 0,
                "the panel lists every open document when shown")
            let statusBeforeOpen = controller.statusText
            let extra = folder.appendingPathComponent("extra.txt")
            try Data("extra".utf8).write(to: extra)
            let listedBefore = listed()
            weak var closedDocument: TextDocument?
            let drained = DispatchGroup()
            try autoreleasepool {
                let opened = try controller.open(extra)
                closedDocument = opened
                pump()
                check(
                    listed() == listedBefore + 1
                        && controller.outlineView(controller.outline, child: listedBefore, ofItem: nil) as? TextDocument
                            === opened,
                    "a newly opened document appears without Refresh")
                check(controller.statusText == statusBeforeOpen, "the quiet reload leaves the status line alone")
                let presenterQueue = opened.presentedItemOperationQueue
                opened.close()
                drained.enter()
                presenterQueue.addBarrierBlock { DispatchQueue.main.async { drained.leave() } }
            }
            // AppKit can release its last temporary owner after the presenter's barrier has run.
            // Give the run loop the existing ten-second budget to observe every close postcondition.
            let closeDeadline = Date().addingTimeInterval(10)
            while Date() < closeDeadline {
                let settled = autoreleasepool {
                    listed() == listedBefore && drained.wait(timeout: .now()) == .success && closedDocument == nil
                }
                if settled { break }
                autoreleasepool {
                    RunLoop.current.run(until: min(closeDeadline, Date().addingTimeInterval(0.01)))
                }
            }
            let rowRemoved = listed() == listedBefore, presenterDrained = drained.wait(timeout: .now()) == .success
            if let held = closedDocument {
                let managed = NSDocumentController.shared.documents.contains { $0 === held }
                let registered = NSFileCoordinator.filePresenters.contains { $0 as AnyObject === held }
                let dataSourceRow = (0..<listed()).contains {
                    controller.outlineView(controller.outline, child: $0, ofItem: nil) as? TextDocument === held
                }
                let outlineRow = (0..<controller.outline.numberOfRows).contains {
                    controller.outline.item(atRow: $0) as? TextDocument === held
                }
                print(
                    "Closed fixture retained: rowRemoved=\(rowRemoved) barrier=\(presenterDrained) "
                        + "managed=\(managed) presenter=\(registered) dataSourceRow=\(dataSourceRow) outlineRow=\(outlineRow) "
                        + "isClosed=\(held.isClosed) windowControllers=\(held.windowControllers.count) "
                        + "editorHasWindow=\(held.editor.window != nil) presenterOperations=\(held.presentedItemOperationQueue.operationCount)"
                )
            }
            if !presenterDrained { check(false, "the closed document's presenter callbacks drain") }
            check(rowRemoved, "a closed document leaves the list without Refresh")
            check(closedDocument == nil, "the list does not keep a closed document alive")
            // Refresh rebuilds the folder nodes, which is what re-reads the disk; expansion survives it.
            controller.select(mode: 1)
            @MainActor func rootNode() throws -> WorkspaceBrowserNode {
                try requireValue(
                    controller.outline.item(atRow: 0) as? WorkspaceBrowserNode, "fixture: the saved folder is listed")
            }
            @MainActor func names(_ node: WorkspaceBrowserNode) -> [String] {
                (0..<controller.outlineView(controller.outline, numberOfChildrenOfItem: node)).compactMap {
                    (controller.outlineView(controller.outline, child: $0, ofItem: node) as? WorkspaceBrowserNode)?
                        .entry.url.lastPathComponent
                }
            }
            let firstRoot = try rootNode()
            controller.outline.expandItem(firstRoot)
            let namesBefore = names(firstRoot)
            check(
                controller.outline.isItemExpanded(firstRoot) && namesBefore.contains("extra.txt")
                    && !namesBefore.contains("added-later.txt"), "fixture: the folder is expanded and listed")
            try Data("later".utf8).write(to: folder.appendingPathComponent("added-later.txt"))
            controller.refresh(nil)
            let secondRoot = try rootNode()
            check(
                secondRoot !== firstRoot && names(secondRoot).contains("added-later.txt"),
                "Refresh re-reads the folder from disk")
            check(controller.outline.isItemExpanded(secondRoot), "an expanded folder stays expanded across Refresh")
            check(
                controller.statusText.contains("Open documents:") && controller.statusText.contains("Saved folders:"),
                "Refresh still ends with the counts summary")
            controller.select(mode: 0)
            controller.select(mode: 1)
            check(
                controller.outline.isItemExpanded(try rootNode()),
                "an expanded folder stays expanded across a change of view")
            controller.outline.collapseItem(try rootNode())
            controller.refresh(nil)
            check(
                !controller.outline.isItemExpanded(try rootNode()), "a collapsed folder stays collapsed across Refresh")
            controller.select(mode: 0)
            let recentFiles = try requireValue(controller.recentFilesMenuItem().submenu, "fixture: recent files menu")
            controller.menuNeedsUpdate(recentFiles)
            check(
                recentFiles.delegate === controller && !recentFiles.items.isEmpty
                    && recentFiles.items.allSatisfy { $0.target === controller && $0.representedObject is URL },
                "recent native menu populated")
            let monitorItem = controller.menuItem(.monitor)
            check(
                controller.validateMenuItem(monitorItem) && monitorItem.state == .off
                    && monitorItem.title == "Monitor Current File",
                "DS-22 Monitor Current File validates unchecked while nothing is monitored")
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
            // F86/F227: one inspection, with the clock injected so the sample counts as settled.
            let later = WorkspaceStore.currentSecond() + 60
            let freshDigest = WorkspaceStore.fingerprint(Data("fresh".utf8))
            func openDescriptors() -> Int {
                (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
            }
            let descriptorsBefore = openDescriptors()
            let unsettled = DocumentMonitor.inspect(fresh, expected: freshDigest)
            check(
                unsettled.status == .unchanged && unsettled.readFile && unsettled.sample == nil,
                "a file written a moment ago is read and leaves nothing to reuse")
            let firstLook = DocumentMonitor.inspect(fresh, expected: freshDigest, now: later)
            check(
                firstLook.status == .unchanged && firstLook.readFile && firstLook.sample?.digest == freshDigest,
                "the first inspection reads and hashes the file")
            let secondLook = DocumentMonitor.inspect(fresh, expected: freshDigest, known: firstLook.sample)
            check(
                secondLook.status == .unchanged && !secondLook.readFile && secondLook.sample == firstLook.sample,
                "an inspection of unchanged metadata does not read the file")
            let otherBaseline = DocumentMonitor.inspect(fresh, expected: "0", known: firstLook.sample)
            check(
                otherBaseline.status == .changed && !otherBaseline.readFile,
                "a new baseline is compared with the known digest without reading the file")
            var freshStat = stat()
            try require(stat(fresh.path, &freshStat) == 0, "fixture: stat the monitored file")
            let inPlace = try FileHandle(forWritingTo: fresh)
            try inPlace.write(contentsOf: Data("FRESH".utf8))
            try inPlace.close()
            try require(
                utimensat(AT_FDCWD, fresh.path, [freshStat.st_atimespec, freshStat.st_mtimespec], 0) == 0,
                "fixture: put the modification time back")
            let sameSize = DocumentMonitor.inspect(fresh, expected: freshDigest, known: firstLook.sample, now: later)
            check(
                sameSize.status == .changed && sameSize.readFile,
                "a same-size rewrite with its modification time put back is read and reported as changed")
            try Data("fresh".utf8).write(to: fresh, options: .atomic)
            let replaced = DocumentMonitor.inspect(fresh, expected: freshDigest, known: firstLook.sample, now: later)
            check(
                replaced.status == .unchanged && replaced.readFile && replaced.sample != firstLook.sample,
                "an atomic replacement is read again even when its bytes are the same")
            try Data("other".utf8).write(to: fresh, options: .atomic)
            check(
                DocumentMonitor.inspect(fresh, expected: freshDigest, known: replaced.sample, now: later).status
                    == .changed, "an atomic replacement with other bytes is reported as changed")
            let big = folder.appendingPathComponent("big.log")
            try Data().write(to: big)
            try require(truncate(big.path, off_t(DocumentMonitor.maximumBytes) + 1) == 0, "fixture: sparse large file")
            let tooBig = DocumentMonitor.inspect(big, expected: freshDigest)
            check(
                tooBig.status == .unavailable("The file is larger than 32 MiB, so its contents are not checked automatically.")
                    && !tooBig.readFile, "a file over the monitoring limit is reported without being read")
            try FileManager.default.removeItem(at: big)
            check(
                DocumentMonitor.inspect(big, expected: freshDigest, known: firstLook.sample).status == .missing,
                "a deleted file is reported missing")
            check(openDescriptors() == descriptorsBefore, "an inspection leaves no descriptor open")
            try Data("fresh".utf8).write(to: fresh)
            let monitor = DocumentMonitor()
            var published: [DocumentMonitorStatus] = []
            monitor.onStatus = { published.append($0) }
            try monitor.start(watched)
            @MainActor func waitFor(_ wanted: DocumentMonitorStatus, line: UInt = #line) {
                spinUntil("the document monitor to report \(wanted)", line: line) { monitor.status == wanted }
                check(monitor.status == wanted, "background monitor result", line: line)
            }
            waitFor(.unchanged)
            check(
                monitor.fileReads >= 1 && monitor.metadataOnlyPolls == 0,
                "the first polls of a just-written file read it")
            // The timestamps settle about three seconds after the write; from then on a poll is one fstat.
            spinUntil(timeout: 30, "a poll to be answered from metadata alone") {
                monitor.poll()
                return monitor.metadataOnlyPolls > 0
            }
            let readsOnceSettled = monitor.fileReads, quietPolls = monitor.metadataOnlyPolls
            spinUntil("three more polls") {
                monitor.poll()
                return monitor.metadataOnlyPolls >= quietPolls + 3
            }
            check(
                monitor.fileReads == readsOnceSettled && monitor.status == .unchanged,
                "an unchanged file is not read again by later polls")
            check(published == [.checking, .unchanged], "each status is published once, however many polls repeat it")
            // F87: a Save As that lands while a check is in flight is followed, not treated as a stop.
            let movedCopy = folder.appendingPathComponent("fresh-moved.txt")
            try Data("fresh".utf8).write(to: movedCopy)
            let completedBeforeMove = monitor.fileReads + monitor.metadataOnlyPolls
            monitor.poll()
            watched.fileURL = movedCopy
            spinUntil("the in-flight check and one more to complete") {
                monitor.poll()
                return monitor.fileReads + monitor.metadataOnlyPolls >= completedBeforeMove + 2
            }
            check(
                monitor.document === watched && monitor.status == .unchanged,
                "monitoring follows the document to its new file")
            watched.fileURL = fresh
            try Data("changed on disk".utf8).write(to: fresh)
            monitor.poll()
            waitFor(.changed)
            check(published == [.checking, .unchanged, .changed], "the change is published once")
            check(watched.editor.text == "fresh", "monitor never automatically reloads")
            watched.editor.replaceSelection("local edit")
            rejects("monitor cannot reload dirty document") {
                try monitor.reload(expectedRevision: watched.editor.revision)
            }
            check(watched.editor.text.contains("local edit"), "dirty monitor preserves edits")
            let staleRevision = watched.editor.revision
            watched.editor.replaceSelection("newer")
            rejects("monitor rejects stale explicit reload") { try monitor.reload(expectedRevision: staleRevision) }
            watched.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            watched.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            try monitor.reload(expectedRevision: watched.editor.revision)
            check(watched.editor.text == "changed on disk", "explicit clean monitor reload")
            try FileManager.default.removeItem(at: fresh)
            monitor.poll()
            waitFor(.missing)
            check(watched.editor.text == "changed on disk", "missing monitored file preserves text")
            monitor.stop()
            check(monitor.status == .stopped && monitor.document == nil, "monitor stops explicitly")
            // F117: a poll in flight must not own the document, or its last reference could be
            // dropped on the worker thread. AppKit lets go of a closed document only after a turn
            // of the main run loop, so the file is large: the read is then still going on, and
            // the poll's completion still to come, when the document is looked for. A poll that
            // owned its document could never be seen in that state; one that does not might, under
            // load, finish first, so a few attempts are allowed.
            let polled = folder.appendingPathComponent("polled.bin")
            try Data(repeating: 0x61, count: 30 * 1024 * 1024).write(to: polled)
            var releasedDuringPoll = false, stoppedAfterRelease = true
            for _ in 0..<5 where !releasedDuringPoll {
                weak var polledDocument: TextDocument?
                let dropped = DocumentMonitor()
                try autoreleasepool {
                    let document = TextDocument()
                    document.fileURL = polled
                    document.makeWindowControllers()
                    polledDocument = document
                    try dropped.start(document)
                    try require(dropped.status == .checking && dropped.document === document, "the monitor is polling")
                    // Setting fileURL registers the document as a file presenter; close() ends that.
                    document.close()
                }
                let turns = Date().addingTimeInterval(10)
                while polledDocument != nil && dropped.status == .checking && Date() < turns {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                }
                releasedDuringPoll = polledDocument == nil && dropped.status == .checking
                spinUntil("the monitor of a released document to stop") { dropped.status == .stopped }
                stoppedAfterRelease = stoppedAfterRelease && dropped.status == .stopped && dropped.document == nil
            }
            check(releasedDuringPoll, "F117 a poll in flight does not keep its document alive")
            check(stoppedAfterRelease, "F117 a monitor whose document was released stops at the next result")
            // The worker also must not own the monitor itself. Its only strong owner is
            // main-owned; deinit invalidates the timer synchronously on this same thread.
            let disposableDocument = TextDocument()
            disposableDocument.fileURL = polled
            disposableDocument.makeWindowControllers()
            weak var releasedMonitor: DocumentMonitor?
            try autoreleasepool {
                let disposableMonitor = DocumentMonitor()
                releasedMonitor = disposableMonitor
                try disposableMonitor.start(disposableDocument)
                try require(disposableMonitor.status == .checking, "fixture: disposable monitor started a poll")
            }
            check(releasedMonitor == nil, "F316 an in-flight inspection does not retain its main-owned monitor")
            disposableDocument.close()
            let app = AppDelegate()
            let previousServices = EditorServices.current
            app.installEditorServices()
            defer { EditorServices.current = previousServices }
            let python = folder.appendingPathComponent("extension-only.py")
            try Data("value = 1".utf8).write(to: python)
            let detected = try controller.open(python)
            check(
                detected.languageIdentifier == "python",
                "workspace filename assigned before extension language detection")
            // G373: a language chosen by hand survives Reload and Revert; only the first load detects.
            // Every run's colour, font and traits. Two languages can share one keyword colour, so the
            // first colour alone does not tell them apart.
            @MainActor func styling(_ editor: TTEditor) -> NSAttributedString {
                editor.attributedText(forSelection: false)
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
            manual.noteAppliedLanguage("javascript")
            check(
                styling(manualReference).length == 10 && styling(manualReference) != styling(pythonReference),
                "fixture: the two languages colour the sample differently")
            try manual.reload(using: .utf8)
            check(
                manual.languageIdentifier == "javascript" && manual.editor.text == "return 42;"
                    && styling(manual.editor) == styling(manualReference),
                "Reload with an encoding keeps the manually chosen language and its styling")
            try manual.revert(toContentsOf: scriptURL, ofType: "Plain Text")
            check(
                manual.languageIdentifier == "javascript" && styling(manual.editor) == styling(manualReference),
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
            // F22: the comparison above is not trivially equal; the keyword is not plain text.
            let plain = TTEditor(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            plain.text = sessionText
            check(
                app.languages.apply(identifier: LanguageProfile.plainTextID, to: plain) && actualColor != nil
                    && actualColor
                        != plain.attributedText(forSelection: false).attribute(
                            .foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                    && restored.editor.attributedText(forSelection: false)
                        == expected.attributedText(forSelection: false),
                "the restored JavaScript keyword is styled apart from plain text")
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
            // F87: the monitor has its own label; neither message replaces the other.
            let labelled = folder.appendingPathComponent("labelled.txt")
            try Data("labelled".utf8).write(to: labelled)
            let labelledDocument = try controller.open(labelled)
            try controller.monitor.start(labelledDocument)
            spinUntil("the browser's monitor to report unchanged") { controller.monitor.status == .unchanged }
            check(
                controller.monitorStatusText == DocumentMonitorStatus.unchanged.message,
                "the monitor reports on its own label")
            try Data("labelled, changed".utf8).write(to: labelled)
            spinUntil("the browser's monitor to report changed") {
                controller.monitor.poll()
                return controller.monitor.status == .changed
            }
            controller.refresh(nil)
            let summary = controller.statusText
            check(
                controller.monitorStatusText == DocumentMonitorStatus.changed.message
                    && summary.contains("Open documents:"), "Refresh does not erase the monitor's changed notice")
            let completedPolls = controller.monitor.fileReads + controller.monitor.metadataOnlyPolls
            spinUntil("one more monitor poll to complete") {
                controller.monitor.poll()
                return controller.monitor.fileReads + controller.monitor.metadataOnlyPolls > completedPolls
            }
            check(
                controller.statusText == summary
                    && controller.monitorStatusText == DocumentMonitorStatus.changed.message,
                "a monitor poll does not replace the status line")
            controller.monitor.stop()
            check(
                controller.monitorStatusText == DocumentMonitorStatus.stopped.message
                    && controller.statusText == summary,
                "stopping the monitor is reported on its own label")
            // F138: the originals are inspected off the main thread behind a modal that ends itself.
            let checkedSnapshot = SessionDocument(
                id: UUID(), originalURL: labelled, text: "labelled", format: FileFormat(), isDirty: false,
                selection: SessionSelection(anchorByte: 0, caretByte: 0), bookmarks: [], language: nil,
                originalSHA256: WorkspaceStore.fingerprint(Data("labelled, changed".utf8)))
            var absent = checkedSnapshot
            absent.id = UUID()
            absent.originalURL = folder.appendingPathComponent("never-existed.txt")
            let checkedSession = WorkspaceSession(
                id: UUID(), name: "Checked", documents: [checkedSnapshot, absent], activeDocumentID: nil)
            check(
                WorkspaceController.checkOriginals(of: checkedSession)?.map(\.status) == [.unchanged, .missing],
                "Check Originals returns each original's status from the background inspection")
            // Hold enough bounded inspection work for the real Cancel action to interrupt it.
            // Repeated references are inert session data, all pointing at our owned fixture.
            let cancellableSession = WorkspaceSession(
                id: UUID(), name: "Cancelled native inspection",
                documents: (0..<1000).map { _ in
                    SessionDocument(
                        id: UUID(), originalURL: polled, text: "", format: FileFormat(), isDirty: false,
                        selection: SessionSelection(anchorByte: 0, caretByte: 0),
                        originalSHA256: String(repeating: "0", count: 64))
                })
            let cancelState = SessionCancelState(), cancelDeadline = Date().addingTimeInterval(3)
            let cancelTimer = Timer(timeInterval: 0.001, repeats: true) { _ in
                precondition(Thread.isMainThread)
                MainActor.assumeIsolated {
                    if Date() > cancelDeadline {
                        cancelState.timedOut = true
                        NSApp.abortModal()
                        return
                    }
                    guard !cancelState.pressed else { return }
                    guard let content = NSApp.modalWindow?.contentView,
                        let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: {
                            $0.title == "Cancel"
                        })
                    else { return }
                    cancelState.pressed = true
                    button.performClick(nil)
                }
            }
            RunLoop.main.add(cancelTimer, forMode: .modalPanel)
            let cancelledInspection = WorkspaceController.checkOriginals(of: cancellableSession)
            cancelTimer.invalidate()
            check(
                cancelState.pressed && !cancelState.timedOut && cancelledInspection == nil && NSApp.modalWindow == nil,
                "F316 actual Check Originals Cancel returns no partial result and closes its modal")
            check(listed() > 0, "fixture: the panel lists documents before it closes")
            controller.window?.close()
            check(listed() == 0, "a closed panel holds no documents")
            try quickOpenChecks(in: root)
            try ExternalFileObservationChecks.run(in: root)
            try ExternalFilePolicyChecks.run(in: root)
            try ExternalFileWatchChecks.run(in: root)
            Checks.summary { "WorkspaceBrowserChecks: \(Checks.count) assertions passed" }
        }
    }
}
