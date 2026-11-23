import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

actor CompareFileGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
@MainActor enum SavedVersionChecks {
    static func run(in root: URL) async throws {
        let previous = EditorServices.current, priorMenu = NSApp.mainMenu
        let delegate = AppDelegate()
        delegate.installEditorServices()
        delegate.buildMenus()
        let service = delegate.compare
        service.showWindows = false
        defer {
            service.windows.forEach { $0.window?.close() }
            EditorServices.current = previous
            NSApp.mainMenu = priorMenu
        }
        let menu = try requireValue(NSApp.mainMenu?.item(withTitle: "Compare")?.submenu, "built Compare menu")
        let action = try requireValue(
            menu.item(withTitle: "Compare with Saved Version"), "one-step saved version control")
        let blank = DocumentFactory.makeUntitled(display: false)
        defer { blank.close() }
        check(
            action.target == nil && !blank.validateUserInterfaceItem(action),
            "saved-file command is disabled on an untitled responder")
        let url = root.appendingPathComponent("compare-saved-cp1252.txt")
        try Data([0x80, 0x31]).write(to: url)
        let doc = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(url), from: url, as: .windows1252, display: false)
        defer { doc.close() }
        let view = try requireValue(doc.presentation, "saved-file tab")
        view.host.activate(view, focus: false)
        _ = doc.editor.setSelectionAnchor(4, caret: 4)
        _ = doc.editor.replaceSelection(" pending")
        _ = doc.editor.setSelectionAnchor(7, caret: 1)
        let info = (doc.editor.text, doc.editor.revision, doc.editor.selectionAnchor, doc.editor.selectionCaret)
        try Data([0x80, 0x32]).write(to: url, options: .atomic)
        check(
            doc.validateUserInterfaceItem(action) && NSApp.sendAction(action.action!, to: doc, from: action),
            "File menu dispatches through its saved document responder")
        _ = await waitUntil("one-step comparison opens without a second click") { service.windows.count == 1 }
        let comparison = try requireValue(service.windows.first, "actual saved comparison")
        check(
            comparison.original?.snapshot.bytes == Data(info.0.utf8)
                && comparison.modified?.snapshot.bytes == Data("€2".utf8),
            "comparison captures unsaved UTF-8 editor text and decodes current CP1252 disk bytes")
        let unchangedDisk = try Data(contentsOf: url)
        check(
            doc.isOpen && doc.isDocumentEdited && doc.fileURL == url && doc.editor.text == info.0
                && doc.editor.revision == info.1 && doc.editor.selectionAnchor == info.2
                && doc.editor.selectionCaret == info.3 && unchangedDisk == Data([0x80, 0x32]),
            "opening comparison preserves dirty state, document, selections and external file")
        comparison.window?.close()
        view.host.activate(view, focus: false)
        _ = await waitUntil("external change notice on edited source") { doc.externalFile.actionTitle == "Reload…" }
        func findCompareButton() -> NSButton? {
            descendants(view.presentationRoot).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "status.compareExternalFile" && !$0.isHidden
            }
        }
        let noticeButton = try requireValue(findCompareButton(), "nonmodal change notice Compare action")
        check(
            noticeButton.accessibilityLabel() == "Compare editor and changed file on disk",
            "notice Compare action has a distinct accessible name")
        noticeButton.performClick(nil)
        _ = await waitUntil("direct comparison from disk-change notice") { service.windows.count == 1 }
        let noticeComparison = try requireValue(service.windows.first, "notice-owned comparison")
        check(
            noticeComparison.original?.snapshot.bytes == Data(info.0.utf8)
                && noticeComparison.modified?.snapshot.bytes == Data("€2".utf8)
                && doc.isDocumentEdited && doc.editor.text == info.0,
            "notice Compare preserves dirty bytes and binds the observed file")
        noticeComparison.window?.close()
        try Data([0x80, 0x33]).write(to: url, options: .atomic)
        noticeButton.performClick(nil)
        _ = await waitUntil("changed inode after notice produces source error") {
            NSApp.windows.compactMap { $0.windowController as? CompareSourcePicker }
                .filter { $0.window?.isVisible == true }.flatMap { descendants($0.window!.contentView!) }
                .compactMap { $0 as? NSTextField }.contains {
                    $0.stringValue == CompareService.message(ReviewRejection.bytesChanged)
                }
        }
        check(
            service.windows.isEmpty && doc.editor.text == info.0 && doc.isDocumentEdited,
            "an unreviewed replacement cannot enter the prior notice comparison")
        NSApp.windows.compactMap { $0.windowController as? CompareSourcePicker }.forEach { $0.window?.close() }
        try Data(repeating: 65, count: ReviewDiffPolicy.default.maximumInputBytes + 1).write(to: url, options: .atomic)
        doc.externalFile.check()
        _ = await waitUntil("same change notice updates when disk exceeds comparison limit") {
            !doc.externalFile.checking && findCompareButton() == nil
        }
        check(
            doc.externalFile.actionTitle == "Reload…" && findCompareButton() == nil,
            "an oversized changed file retains Reload and hides Compare")
        try Data([0x80, 0x33]).write(to: url, options: .atomic)
        doc.externalFile.check()
        _ = await waitUntil("same change notice restores comparison after disk shrinks") {
            !doc.externalFile.checking && findCompareButton() != nil
        }
        check(findCompareButton() != nil, "Compare returns on the same notice after the file fits")
        let host = try requireValue(doc.windowForSheet, "saved document sheet parent")
        func sheetButton(_ title: String) -> NSButton? {
            host.attachedSheet?.contentView.map(descendants)?.compactMap { $0 as? NSButton }
                .first { $0.title == title }
        }
        for choice in ["Cancel", "Compare…"] {
            doc.save(nil)
            _ = await waitUntil("native Save conflict sheet") { host.attachedSheet != nil }
            print(
                "Native save conflict buttons",
                host.attachedSheet?.contentView.map(descendants)?
                    .compactMap { ($0 as? NSButton)?.title } ?? [])
            check(
                sheetButton("Save") == nil && sheetButton("Don’t Save") == nil,
                "File Save offers conflict review directly")
            _ = await waitUntil("native save conflict decision " + choice) { sheetButton(choice) != nil }
            try requireValue(sheetButton(choice), "save conflict offers " + choice).performClick(nil)
            _ = await waitUntil("save conflict sheet dismisses") { host.attachedSheet == nil }
            if choice == "Compare…" {
                _ = await waitUntil("save conflict Compare opens after cancelling save") { service.windows.count == 1 }
                let result = try requireValue(service.windows.first, "conflict-owned comparison")
                check(
                    result.original?.snapshot.bytes == Data(info.0.utf8)
                        && result.modified?.snapshot.bytes == Data("€3".utf8),
                    "save conflict compares the actual external and pending versions")
                result.window?.close()
            } else {
                check(service.windows.isEmpty, "Cancel on a save conflict leaves no comparison")
            }
            let disk = try Data(contentsOf: url)
            check(
                doc.isOpen && doc.isDocumentEdited && doc.fileURL == url && doc.editor.text == info.0
                    && doc.editor.selectionAnchor == info.2 && doc.editor.selectionCaret == info.3
                    && disk == Data([0x80, 0x33]),
                "save conflict choice preserves source, external file, dirty state and selections")
        }
        // Other native save entry points can still reach writeSafely directly.
        var failure: Error?
        do { try doc.writeSafely(to: url, ofType: TextDocument.plainTextType, for: .saveOperation) } catch {
            failure = error
        }
        let rejected = try requireValue(failure, "actual downstream safe-write refusal")
        let decorated = doc.willPresentError(rejected) as NSError
        check(
            decorated.localizedRecoveryOptions == ["Cancel", "Compare…"],
            "downstream safe write retains native Compare recovery")
        let stale = try requireValue(decorated.recoveryAttempter as? NSObject, "bound conflict recovery attempter")
        _ = doc.editor.setSelectionAnchor(doc.editor.byteLength, caret: doc.editor.byteLength)
        _ = doc.editor.replaceSelection("!")
        check(
            !stale.attemptRecovery(fromError: rejected, optionIndex: 1),
            "old save conflict never reports a recovered save")
        try await Task.sleep(nanoseconds: 40_000_000)
        check(
            service.windows.isEmpty && doc.editor.text.hasSuffix("!"), "stale save comparison preserves the newer edit")
        doc.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        _ = doc.editor.setSelectionAnchor(info.2, caret: info.3)
        let ordinary = root.appendingPathComponent("unchanged-before-save.txt")
        try Data("safe".utf8).write(to: ordinary)
        let safe = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(ordinary), from: ordinary, display: false)
        safe.editor.text = "ordinary save"
        safe.save(nil)
        _ = await waitUntil("uncontested native Save finishes") { !safe.isDocumentEdited }
        check(
            (try Data(contentsOf: ordinary)) == Data("ordinary save".utf8) && safe.windowForSheet?.attachedSheet == nil,
            "uncontested Save writes normally without a comparison")
        safe.close()
        view.host.activate(view, focus: false)
        try await closeReviews(in: root, service: service)
        view.host.activate(view, focus: false)
        let read = service.fileSnapshot
        let gate = CompareFileGate()
        service.fileSnapshot = { url, encoding in
            await gate.wait()
            return try await read(url, encoding)
        }
        doc.compareWithSavedVersion(action)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !(await gate.started) && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = await gate.started
        check(started, "second saved comparison started its bound disk capture")
        let pending = try requireValue(
            NSApp.windows.compactMap { $0.windowController as? CompareSourcePicker }.first {
                $0.window?.isVisible == true
            }, "visible source picker while capture is pending")
        check(
            pending.kind.selectedItem?.title == "Tab and Saved File",
            "pending command preselects existing Tab and Saved File source")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let cancel = try requireValue(
            descendants(pending.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Cancel" },
            "native capture cancellation")
        cancel.performClick(nil)
        await gate.release()
        _ = await waitUntil("canceling pending capture dismisses picker") { pending.window?.isVisible != true }
        try await Task.sleep(nanoseconds: 50_000_000)
        check(
            service.windows.isEmpty && doc.editor.text == info.0 && doc.isDocumentEdited,
            "Cancel opens no comparison and leaves the edited source untouched")

        let quitGate = CompareFileGate()
        service.fileSnapshot = { url, encoding in
            await quitGate.wait()
            return try await read(url, encoding)
        }
        doc.compareWithSavedVersion(action)
        let quitDeadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await quitGate.started) && ProcessInfo.processInfo.systemUptime < quitDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let quitStarted = await quitGate.started
        var reviews = 0, replies: [Bool] = []
        delegate.requestUnsavedReview = { _ in reviews += 1 }
        delegate.replyToTerminate = { replies.append($0) }
        check(
            quitStarted && delegate.applicationShouldTerminate(NSApp) == .terminateLater,
            "dirty quit starts native review")
        check(
            !doc.validateUserInterfaceItem(action) && delegate.applicationShouldTerminate(NSApp) == .terminateLater,
            "repeated quit suppresses saved comparison commands during native review")
        await quitGate.release()
        _ = await waitUntil("native review delivered once") { reviews == 1 }
        delegate.reviewed(NSDocumentController.shared, didReviewAll: false, contextInfo: nil)
        try await Task.sleep(nanoseconds: 40_000_000)
        check(
            service.windows.isEmpty && doc.isDocumentEdited && doc.isOpen && doc.validateUserInterfaceItem(action)
                && replies == [false], "cancelling quit keeps the source and suppresses the pre-quit comparison")
    }

    private static func closeReviews(in root: URL, service: CompareService) async throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for choice in ["Cancel", "Review Changes…", "Save", "Don’t Save", "stale discard", "replaced disk"] {
            let url = root.appendingPathComponent("close-" + choice + ".txt")
            try Data("initial".utf8).write(to: url)
            let doc = try DocumentFactory.openCaptured(
                WorkspaceStore.captureRegularFile(url), from: url, display: false)
            defer { doc.close() }
            let view = try requireValue(doc.presentation, "single-close presentation")
            let host = try requireValue(doc.windowForSheet, "single-close sheet parent")
            view.host.activate(view, focus: false)
            doc.editor.text = "original pending"
            _ = doc.editor.setSelectionAnchor(7, caret: 2)
            let close = try requireValue(
                descendants(view.host.tabStrip).compactMap { $0 as? NSButton }.first {
                    $0.toolTip == "Close " + url.lastPathComponent
                }, "built tab close control")
            close.performClick(nil)
            _ = await waitUntil("single close opens native choice sheet") { host.attachedSheet != nil }
            let buttons = host.attachedSheet?.contentView.map(descendants)?.compactMap { $0 as? NSButton } ?? []
            check(
                Set(buttons.map(\.title)).isSuperset(of: ["Save", "Don’t Save", "Cancel", "Review Changes…"]),
                "saved dirty close offers all four explicit choices")
            if choice == "stale discard" { doc.editor.text = "newer pending" }
            if choice == "replaced disk" { try Data("new external".utf8).write(to: url, options: .atomic) }
            let title = ["stale discard", "replaced disk"].contains(choice) ? "Don’t Save" : choice
            try requireValue(buttons.first { $0.title == title }, "single-close choice").performClick(nil)
            _ = await waitUntil("single close decision dismisses its sheet") { host.attachedSheet == nil }
            switch choice {
            case "Save", "Don’t Save":
                _ = await waitUntil("explicit save/discard closes owned tab") { doc.isClosed }
                let expected = choice == "Save" ? "original pending" : "initial"
                check(doc.isClosed && (try? Data(contentsOf: url)) == Data(expected.utf8), "explicit close " + choice)
            case "Review Changes…":
                _ = await waitUntil("cancel-close opens comparison") { service.windows.count == 1 }
                let result = try requireValue(service.windows.first, "close review comparison")
                check(
                    doc.isOpen && doc.isDocumentEdited && doc.fileURL == url && doc.editor.selectionAnchor == 7
                        && doc.editor.selectionCaret == 2
                        && result.original?.snapshot.bytes == Data("original pending".utf8)
                        && result.modified?.snapshot.bytes == Data("initial".utf8)
                        && (try? Data(contentsOf: url)) == Data("initial".utf8),
                    "Review Changes cancels close and preserves the edited selection and disk")
                result.window?.close()
            default:
                let expected = choice == "stale discard" ? "newer pending" : "original pending"
                let disk = choice == "replaced disk" ? "new external" : "initial"
                check(
                    doc.isOpen && doc.isDocumentEdited && doc.editor.text == expected && service.windows.isEmpty
                        && (try? Data(contentsOf: url)) == Data(disk.utf8), "safe single-close outcome " + choice)
            }
        }
    }
}
