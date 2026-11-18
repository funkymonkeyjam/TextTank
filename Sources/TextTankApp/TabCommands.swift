import AppKit
import TextTankCore
import EditorBridge

@MainActor enum TabCloseDecision { case save, discard, cancel }
@MainActor struct TabClosePrompt {
    let documentID: DocumentID
    let name: String
    let tabCount: Int
}
@MainActor private final class TabMenuInvocation: NSObject {
    let command: TabCommand
    let targetID: TabID
    init(_ command: TabCommand, _ targetID: TabID) {
        self.command = command
        self.targetID = targetID
    }
}
@MainActor private final class TabSaveReply: NSObject {
    private static var pending: [UUID: TabSaveReply] = [:]
    let id = UUID()
    let completion: @MainActor (Error?) -> Void
    init(_ completion: @escaping @MainActor (Error?) -> Void) { self.completion = completion }
    static func save(_ doc: TextDocument, completion: @escaping @MainActor (Error?) -> Void) {
        let reply = TabSaveReply(completion)
        pending[reply.id] = reply
        doc.save(withDelegate: reply, didSave: #selector(finished(_:didSave:contextInfo:)), contextInfo: nil)
    }
    @objc private func finished(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Self.pending.removeValue(forKey: id)
        completion(didSave ? nil : CocoaError(.userCancelled))
    }
}
@MainActor final class TabCommandController: NSObject, NSMenuItemValidation {
    private unowned let host: WorkspaceWindowController
    private(set) var history = ClosedTabHistory()
    private(set) var isBusy = false
    private(set) var isReopening = false
    var isTerminating = false
    var decisionHandler: ((TabClosePrompt, @escaping @MainActor (TabCloseDecision) -> Void) -> Void)?
    var saveHandler: ((TextDocument, @escaping @MainActor (Error?) -> Void) -> Void)?
    var revealFiles: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    var copyPath: (String) -> Bool = { path in
        guard let board = RuntimeEnvironment.current.generalPasteboard() else { return false }
        board.clearContents()
        return board.setString(path, forType: .string)
    }
    private var fingerprints: [UUID: (Task<String?, Never>, TabDiskCapture)] = [:]
    private var reopenTask: Task<Void, Never>?
    private var readTask: Task<TabDiskRead, Error>?
    private var reopenGeneration = 0
    private var publishingReopen = false
    private var bulkPositions: [TabID: (GroupSlot, Int)] = [:]
    func prepareBulkHistory(_ model: TabWorkspace) {
        bulkPositions = Dictionary(
            uniqueKeysWithValues: model.groups.flatMap { group in
                group.tabs.enumerated().map { ($0.element.id, (group.slot, $0.offset)) }
            })
    }
    func finishBulkHistory() { bulkPositions = [:] }

    init(host: WorkspaceWindowController) {
        self.host = host
        super.init()
    }
    deinit {
        for job in fingerprints.values {
            job.0.cancel()
            job.1.cancelQueued()
        }
        reopenTask?.cancel()
        readTask?.cancel()
    }
    private func tab(_ id: TabID) -> DocumentTab? { host.model.groups.flatMap(\.tabs).first { $0.id == id } }
    private func document(_ id: TabID) -> TextDocument? { host.presentation(for: id)?.document as? TextDocument }
    private func modified(_ document: TextDocument) -> Bool {
        document.isDocumentEdited || document.editor.modified || document.format != document.savedFormat
    }
    func facts() -> [DocumentID: TabCloseFact] {
        var result: [DocumentID: TabCloseFact] = [:]
        for presentation in host.presentations {
            guard let doc = presentation.document as? TextDocument else { continue }
            let unavailable =
                doc.diskURL.map { (try? WorkspaceStore.signature(ofRegularFileAt: $0, maximumBytes: Int.max)) == nil }
                ?? false
            result[doc.runtimeID] = TabCloseFact(
                modified: modified(doc), fileBacked: doc.fileURL != nil, missing: unavailable)
        }
        return result
    }
    func state(_ command: TabCommand, target: TabID?) -> (enabled: Bool, reason: String?) {
        if isBusy || isReopening || host.window?.attachedSheet != nil {
            return (false, "Wait for the current tab operation to finish.")
        }
        if command == .reopen {
            return history.latest == nil ? (false, "There are no closed file tabs to reopen.") : (true, nil)
        }
        guard let target, tab(target) != nil, let doc = document(target), doc.isOpen else {
            return (false, "There is no open tab to act on.")
        }
        if command == .reveal || command == .copyPath {
            return doc.fileURL == nil ? (false, "Save this document to give it a file path.") : (true, nil)
        }
        if command.isBulkClose {
            guard let plan = try? TabClosePlan.make(command, target: target, workspace: host.model, facts: facts()),
                !plan.tabs.isEmpty
            else {
                return (
                    false,
                    command == .closeSaved
                        ? "There are no unmodified, saved tabs with an available file to close."
                        : "There are no eligible unpinned tabs to close."
                )
            }
        }
        return (true, nil)
    }
    static var sections: [[TabCommand]] {
        [
            [.newToRight, .reopen], [.close, .closeOthers, .closeLeft, .closeRight, .closeGroup, .closeSaved],
            [.reveal, .copyPath]
        ]
    }
    func contextMenu(for target: TabID) -> NSMenu {
        let menu = NSMenu(title: "Tab")
        for (index, section) in Self.sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in section {
                let item = menu.addItem(
                    title: command.title, action: #selector(invoke(_:)), target: self,
                    representedObject: TabMenuInvocation(command, target))
                item.identifier = NSUserInterfaceItemIdentifier("tabs.command." + command.rawValue)
                _ = validateMenuItem(item)
                item.isEnabled = stateFor(item).enabled
            }
        }
        return menu
    }
    private func stateFor(_ item: NSMenuItem) -> (enabled: Bool, reason: String?) {
        guard let call = item.representedObject as? TabMenuInvocation else {
            return (false, "This tab command is unavailable.")
        }
        guard tab(call.targetID) != nil else { return (false, "This tab is no longer open.") }
        return state(call.command, target: call.targetID)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let s = stateFor(item)
        item.toolTip = s.reason
        return s.enabled
    }
    @objc private func invoke(_ item: NSMenuItem) {
        guard let call = item.representedObject as? TabMenuInvocation else { return }
        perform(call.command, target: call.targetID, captured: true)
    }
    func perform(_ command: TabCommand, target: TabID?, captured: Bool = false, sender: Any? = nil) {
        if isReopening { cancelReopen() }
        if captured && (target == nil || tab(target!) == nil) {
            host.showTabMessage("This tab is no longer open. No document was changed.")
            return
        }
        let available = state(command, target: target)
        guard available.enabled else {
            host.showTabMessage(available.reason ?? "This tab command is unavailable.")
            return
        }
        if command == .reopen {
            reopen()
            return
        }
        guard let target, let doc = document(target) else { return }
        switch command {
        case .newToRight:
            guard let group = host.model.groups.first(where: { $0.tabs.contains { $0.id == target } }),
                let index = group.tabs.firstIndex(where: { $0.id == target })
            else { return }
            let insertion = group.tabs[index].isPinned ? group.tabs.prefix { $0.isPinned }.count : index + 1
            let created = DocumentFactory.makeUntitled(display: false)
            if let id = host.model.groups.flatMap(\.tabs).first(where: { $0.documentID == created.runtimeID })?.id {
                host.placeTab(id, in: group.slot, index: insertion, pinned: false)
            }
            created.showWindows()
        case .close: host.performSingleTabClose(target, sender: sender)
        case .closeOthers, .closeLeft, .closeRight, .closeGroup, .closeSaved: beginBulk(command, target: target)
        case .reveal: if let url = doc.fileURL { revealFiles([url]) }
        case .copyPath:
            if let url = doc.fileURL {
                host.showTabMessage(
                    copyPath(url.path)
                        ? "The file path was copied." : "The file path could not be copied. No document was changed.")
            }
        case .reopen: break
        }
    }
    @MainActor private struct Stamp: Equatable {
        let revision: UInt, format: FileFormat, url: URL?, edited: Bool
        init(_ doc: TextDocument) {
            revision = doc.editor.revision
            format = doc.format
            url = doc.fileURL
            edited = doc.isDocumentEdited || doc.editor.modified
        }
    }
    private func beginBulk(_ command: TabCommand, target: TabID) {
        guard let plan = try? TabClosePlan.make(command, target: target, workspace: host.model, facts: facts()) else {
            return
        }
        let originalActive = host.model.activeTab?.id, originalResponder = host.window?.firstResponder
        var docs: [DocumentID: TextDocument] = [:]
        for id in plan.tabs { if let doc = document(id) { docs[doc.runtimeID] = doc } }
        var stamps = docs.mapValues(Stamp.init)
        isBusy = true
        host.metadataChanged()
        Task { @MainActor [weak self, host = self.host] in
            guard let self else { return }
            var committed = false
            defer {
                self.isBusy = false
                host.metadataChanged()
                if !committed { host.restoreTabFocus(originalActive, responder: originalResponder) }
            }
            @MainActor func valid() -> Bool {
                plan.isCurrent(workspace: host.model, facts: self.facts())
                    && docs.allSatisfy { id, doc in doc.isOpen && Stamp(doc) == stamps[id] }
            }
            var decisions: [DocumentID: TabCloseDecision] = [:]
            for id in plan.modifiedDocuments {
                guard valid(), let doc = docs[id] else {
                    self.changedPlan()
                    return
                }
                let prompt = TabClosePrompt(documentID: id, name: doc.displayName, tabCount: plan.tabs.count)
                let decision = await withCheckedContinuation { continuation in
                    if let handler = self.decisionHandler {
                        handler(prompt) { continuation.resume(returning: $0) }
                    } else {
                        self.review(prompt) { continuation.resume(returning: $0) }
                    }
                }
                if decision == .cancel {
                    host.showTabMessage("Closing tabs was cancelled. No tabs were saved or closed.")
                    return
                }
                decisions[id] = decision
            }
            guard valid() else {
                self.changedPlan()
                return
            }
            for id in plan.modifiedDocuments where decisions[id] == .save {
                guard valid(), let doc = docs[id] else {
                    self.changedPlan()
                    return
                }
                let before = Stamp(doc)
                let error: Error? = await withCheckedContinuation { continuation in
                    if let handler = self.saveHandler {
                        handler(doc) { continuation.resume(returning: $0) }
                    } else {
                        TabSaveReply.save(doc) { continuation.resume(returning: $0) }
                    }
                }
                guard error == nil, doc.isOpen, !self.modified(doc), doc.editor.revision == before.revision,
                    doc.format == before.format
                else {
                    host.showTabMessage(
                        String(
                            format:
                                "The document “%@” could not be saved or its save was cancelled. No tabs were closed. Earlier completed saves remain saved.",
                            doc.displayName))
                    return
                }
                stamps[id] = Stamp(doc)
            }
            guard valid() else {
                self.changedPlan()
                return
            }
            host.commitTabClose(plan, originalActive: originalActive, originalResponder: originalResponder)
            committed = true
            host.showTabMessage(
                plan.tabs.count == 1 ? "Closed 1 tab." : String(format: "Closed %ld tabs.", plan.tabs.count))
        }
    }
    private func changedPlan() {
        host.showTabMessage(
            "The tabs or documents changed while closing was being reviewed. No tabs were closed. Earlier completed saves remain saved."
        )
    }
    func makeReview(_ prompt: TabClosePrompt) -> TTAlert {
        let alert = TTAlert()
        alert.alertStyle = .warning
        let format =
            prompt.tabCount == 1
            ? "Save changes to “%@” before closing 1 tab?" : "Save changes to “%@” before closing %ld tabs?"
        alert.messageText = String(format: format, prompt.name, prompt.tabCount)
        alert.informativeText =
            "Tabs close only after every requested save succeeds. Discarded edits cannot be restored by Undo; completed saves are not rolled back."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel", role: .cancel)
        return alert
    }
    private func review(_ prompt: TabClosePrompt, completion: @escaping @MainActor (TabCloseDecision) -> Void) {
        guard let window = host.window else {
            completion(.cancel)
            return
        }
        makeReview(prompt).beginSheetModal(for: window) { result in
            switch TTAlert.Result(result) {
            case .button(0): completion(.save)
            case .button(1): completion(.discard)
            default: completion(.cancel)
            }
        }
    }
    /// Called before TextDocument marks itself closed or retires its Clone/view state.
    func willClose(_ doc: TextDocument) {
        guard !isTerminating,
            let group = host.model.groups.first(where: { $0.tabs.contains { $0.documentID == doc.runtimeID } }),
            let index = group.tabs.firstIndex(where: { $0.documentID == doc.runtimeID }), let url = doc.fileURL
        else { return }
        let position = bulkPositions[group.tabs[index].id] ?? (group.slot, index)
        record(group.tabs[index], group: position.0, index: position.1, document: doc, url: url)
    }
    private func record(_ tab: DocumentTab, group: GroupSlot, index: Int, document: TextDocument, url: URL) {
        let editor = document.activeEditor
        let record = ClosedTabRecord(
            url: url, group: group, index: index, pinned: tab.isPinned, anchor: editor.selectionAnchor,
            caret: editor.selectionCaret, firstVisibleLine: editor.firstVisibleLine, fingerprint: nil)
        let capture = document.diskURL.flatMap { try? TabDiskCapture($0) }
        if let old = history.push(record), let job = fingerprints.removeValue(forKey: old.id) {
            job.0.cancel()
            job.1.cancelQueued()
        }
        guard let capture else { return }
        let task = Task.detached(priority: .utility) { await TabDiskIO.shared.fingerprint(capture) }
        fingerprints[record.id] = (task, capture)
        Task { @MainActor [weak self] in
            let value = await task.value
            guard let self else { return }
            _ = self.history.setFingerprint(value, for: record.id)
            self.fingerprints.removeValue(forKey: record.id)
        }
    }
    func recordNonfinalTab(_ id: TabID) {
        guard let group = host.model.groups.first(where: { $0.tabs.contains { $0.id == id } }),
            let index = group.tabs.firstIndex(where: { $0.id == id }),
            let doc = document(id), let url = doc.fileURL
        else { return }
        let position = bulkPositions[group.tabs[index].id] ?? (group.slot, index)
        record(group.tabs[index], group: position.0, index: position.1, document: doc, url: url)
    }
    var pendingFingerprintCount: Int { fingerprints.count }
    /// Consumed records no longer participate in capacity eviction. Retire their
    /// descriptor/job here so repeated existing-file reopens cannot grow a queue.
    @discardableResult private func consumeHistory(_ id: UUID) -> Bool {
        guard history.consume(id) else { return false }
        if let job = fingerprints.removeValue(forKey: id) {
            job.0.cancel()
            job.1.cancelQueued()
        }
        return true
    }
    func clearHistory() {
        cancelReopen()
        for job in fingerprints.values {
            job.0.cancel()
            job.1.cancelQueued()
        }
        fingerprints.removeAll()
        history = ClosedTabHistory()
    }
    func cancelReopen() {
        guard isReopening, !publishingReopen else { return }
        reopenGeneration += 1
        reopenTask?.cancel()
        readTask?.cancel()
        reopenTask = nil
        readTask = nil
        isReopening = false
    }
    private func sameStructure(_ a: TabWorkspace, _ b: TabWorkspace) -> Bool {
        a.layout == b.layout && a.groups.count == b.groups.count
            && zip(a.groups, b.groups).allSatisfy { $0.slot == $1.slot && $0.tabs == $1.tabs }
    }
    private func reopen() {
        guard let record = history.latest else { return }
        let slot = host.model.groups.contains { $0.slot == record.group } ? record.group : host.model.focusedGroup
        if let existing = host.model.groups.first(where: { $0.slot == slot })?.tabs.first(where: {
            document($0.id)?.fileURL?.standardizedFileURL == record.url.standardizedFileURL
        }), let presentation = host.presentation(for: existing.id) {
            _ = consumeHistory(record.id)
            host.show(presentation, sender: nil)
            host.showTabMessage("The file is already open. Its existing tab was selected.")
            return
        }
        isReopening = true
        reopenGeneration += 1
        let token = reopenGeneration, snapshot = host.model
        let pending = fingerprints[record.id]?.0
        host.showTabMessage(String(format: "Reopening “%@”…", record.url.lastPathComponent))
        reopenTask = Task { @MainActor [weak self, host = self.host] in
            guard let self else { return }
            defer {
                if self.reopenGeneration == token {
                    self.isReopening = false
                    self.readTask = nil
                    self.reopenTask = nil
                }
            }
            let oldFingerprint = await pending?.value ?? record.fingerprint
            do {
                try Task.checkCancellation()
                let url = record.url.resolvingSymlinksInPath()
                let task = Task.detached(priority: .userInitiated) { try await TabDiskIO.shared.read(url) }
                self.readTask = task
                let read = try await task.value
                try Task.checkCancellation()
                guard self.reopenGeneration == token, self.history.latest?.id == record.id,
                    self.sameStructure(host.model, snapshot)
                else { return }
                guard (try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max)) == read.signature
                else { throw WorkspaceError.invalid("The file changed while reopening. Try again.") }
                guard host.acceptsDocumentCreation else { return }
                self.publishingReopen = true
                defer { self.publishingReopen = false }
                let document = try DocumentFactory.openCaptured(
                    CapturedFileRead(
                        data: read.data, sample: FileSample(digest: read.digest, signature: nil),
                        modificationDate: read.modificationDate), from: record.url, display: false)
                document.editor.readOnly = !read.writable
                guard
                    let id = host.model.groups.flatMap(\.tabs).first(where: { $0.documentID == document.runtimeID }
                    )?.id
                else {
                    document.close()
                    return
                }
                host.placeTab(id, in: slot, index: record.index, pinned: record.pinned)
                _ = self.consumeHistory(record.id)
                document.showWindows()
                document.editor.restoreClosedTabView(
                    anchor: record.anchor, caret: record.caret, firstVisibleLine: record.firstVisibleLine)
                let message: String
                if let oldFingerprint, oldFingerprint != read.digest {
                    message = String(
                        format: "Reopened “%@”. The file changed on disk since its tab was closed.",
                        record.url.lastPathComponent)
                } else if oldFingerprint == nil {
                    message = String(
                        format: "Reopened “%@”. Its earlier on-disk version could not be verified.",
                        record.url.lastPathComponent)
                } else {
                    message = String(format: "Reopened “%@”.", record.url.lastPathComponent)
                }
                host.showTabMessage(message)
            } catch {
                guard self.reopenGeneration == token, self.history.latest?.id == record.id else { return }
                if error is CancellationError { return }
                if error.isFileNotFound {
                    _ = self.consumeHistory(record.id)
                    host.showTabMessage(
                        String(
                            format: "“%@” is no longer at its file path. Nothing was opened.",
                            record.url.lastPathComponent))
                } else {
                    host.showTabMessage(
                        String(
                            format: "“%@” could not be reopened. No document was changed. %@",
                            record.url.lastPathComponent, error.localizedDescription))
                }
            }
        }
    }
}
