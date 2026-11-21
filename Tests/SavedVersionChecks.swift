import AppKit
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
        let menu = try requireValue(NSApp.mainMenu?.item(withTitle: "File")?.submenu, "built File menu")
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
    }
}
