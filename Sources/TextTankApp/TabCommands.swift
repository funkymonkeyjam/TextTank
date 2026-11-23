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
    let scope: TabTargetCapture?
    init(_ command: TabCommand, _ targetID: TabID, scope: TabTargetCapture?) {
        self.command = command
        self.targetID = targetID
        self.scope = scope
    }
}
/// One of Source, Preview and Both for the tab that was clicked, which need not be the active one.
@MainActor private final class TabViewModeInvocation: NSObject {
    let mode: DocumentViewMode
    let targetID: TabID
    init(_ mode: DocumentViewMode, _ targetID: TabID) {
        self.mode = mode
        self.targetID = targetID
    }
}
@MainActor final class TabSaveReply: NSObject {
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
    private var liveHistoryIDs: [UUID: DocumentID] = [:]
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
            guard let doc = presentation.document as? TextDocument, result[doc.runtimeID] == nil else { continue }
            let unavailable =
                doc.diskURL.map { (try? WorkspaceStore.signature(ofRegularFileAt: $0, maximumBytes: Int.max)) == nil }
                ?? false
            result[doc.runtimeID] = TabCloseFact(
                modified: modified(doc), fileBacked: doc.fileURL != nil, missing: unavailable)
        }
        return result
    }
    func capture(_ target: TabID?) -> TabTargetCapture? {
        target.flatMap { try? TabTargetCapture(target: $0, workspace: host.model, selection: host.tabSelection) }
    }
    private func members(_ target: TabID, scope: TabTargetCapture?) -> Set<TabID> {
        scope?.members(in: host.model) ?? [target]
    }
    private func closePlan(_ command: TabCommand, target: TabID, scope: TabTargetCapture?) -> TabClosePlan? {
        if command == .close, members(target, scope: scope).count > 1 {
            let chosen = members(target, scope: scope)
            return try? TabClosePlan.selected(
                host.model.groups.flatMap(\.tabs).filter { chosen.contains($0.id) }.map(\.id),
                target: target, workspace: host.model, facts: facts())
        }
        return try? TabClosePlan.make(
            command, target: target, workspace: host.model, facts: facts(),
            keeping: command == .closeOthers ? scope?.keeping(in: host.model) : nil)
    }
    func state(_ command: TabCommand, target: TabID?, scope: TabTargetCapture? = nil) -> (
        enabled: Bool, reason: String?
    ) {
        if let reason = blockedReason() { return (false, reason) }
        if let scope, scope.members(in: host.model) == nil { return (false, "This tab is no longer open.") }
        if command == .reopen {
            return history.latest == nil ? (false, "There are no closed file tabs to reopen.") : (true, nil)
        }
        guard let target, tab(target) != nil, let doc = document(target), doc.isOpen else {
            return (false, "There is no open tab to act on.")
        }
        if command == .reveal || command == .copyPath {
            return doc.fileURL == nil ? (false, "Save this document to give it a file path.") : (true, nil)
        }
        if command == .moveLeft || command == .moveRight {
            return host.model.canMoveTab(target, direction: command == .moveLeft ? -1 : 1)
                ? (true, nil) : (false, "This tab is at the edge of its pinned or ordinary region.")
        }
        if command.isBulkClose || (command == .close && members(target, scope: scope).count > 1) {
            guard let plan = closePlan(command, target: target, scope: scope),
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
    /// Why no tab command can run now, or nil: a comparison window is in front, or a tab
    /// operation or a sheet is in progress. The tab commands and a tab's Source, Preview and
    /// Both share this one test.
    private func blockedReason() -> String? {
        if CompareCommandScope.blocksWorkspace {
            return "Close or leave the comparison window before managing document tabs."
        }
        if host.isMutatingGroups || isBusy || isReopening || host.window?.attachedSheet != nil {
            return "Wait for the current tab operation to finish."
        }
        return nil
    }
    static var sections: [[TabCommand]] {
        [
            [.newToRight, .reopen], [.close, .closeOthers, .closeLeft, .closeRight, .closeGroup, .closeSaved],
            [.pin, .moveLeft, .moveRight], [.reveal, .copyPath]
        ]
    }
    func contextMenu(for target: TabID) -> NSMenu {
        let menu = NSMenu(title: "Tab"), scope = capture(target)
        for (index, section) in Self.sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for command in section {
                let item = menu.addItem(
                    title: command.title, action: #selector(invoke(_:)), target: self,
                    representedObject: TabMenuInvocation(command, target, scope: scope))
                item.identifier = NSUserInterfaceItemIdentifier("tabs.command." + command.rawValue)
                _ = validateMenuItem(item)
                item.isEnabled = stateFor(item).enabled
            }
        }
        addViewModeItems(to: menu, target: target)
        if let compare = EditorServices.current?.compare {
            compare.addTabItems(to: menu) { [weak host] in
                guard let doc = host?.presentation(for: target)?.document as? TextDocument, doc.isOpen else {
                    return nil
                }
                return doc.editor
            }
        }
        let groups = NSMenuItem(title: "Editor Groups", action: nil, keyEquivalent: "")
        groups.submenu = host.groupCommands.contextMenu(for: target)
        menu.addItem(groups)
        return menu
    }
    // MARK: Source, Preview and Both for one tab

    /// What the tab shows, or nil when its document has no preview: then the tab offers no
    /// choice at all, in its menu or on the tab (DS-21).
    func viewMode(of target: TabID) -> DocumentViewMode? {
        guard tab(target) != nil, let presentation = host.presentation(for: target), !presentation.isRetired,
            presentation.previewKind != nil
        else { return nil }
        return presentation.viewMode
    }
    /// The same conditions as the tab commands and the View menu: no comparison in front, no
    /// tab operation or sheet in progress, and a tab that is still open.
    func viewModeState(target: TabID) -> (enabled: Bool, reason: String?) {
        if let reason = blockedReason() { return (false, reason) }
        guard tab(target) != nil, let doc = document(target), doc.isOpen else {
            return (false, "This tab is no longer open.")
        }
        return viewMode(of: target) == nil ? (false, "This document has no preview.") : (true, nil)
    }
    /// Shows `mode` in the tab. The active tab behaves as it does for the View menu; any other
    /// tab changes where it is, without being selected and without taking the keyboard.
    @discardableResult func setViewMode(_ mode: DocumentViewMode, target: TabID) -> Bool {
        guard viewModeState(target: target).enabled, let presentation = host.presentation(for: target) else {
            return false
        }
        let isActive = host.active === presentation, before = presentation.viewMode
        guard presentation.chooseViewMode(mode, movingFocus: isActive) else { return false }
        // A tab that is not showing changes out of sight; say what happened (DS-72).
        if !isActive, presentation.viewMode != before {
            let name = (presentation.document as? TextDocument)?.displayName ?? "Untitled"
            Announce.say(String(format: Self.viewModeAnnouncement(mode), name), from: host.window)
        }
        return true
    }
    private static func viewModeAnnouncement(_ mode: DocumentViewMode) -> String {
        switch mode {
        case .source: return Strings.text("tabs.viewMode.nowSource", "%@ now shows Source.")
        case .preview: return Strings.text("tabs.viewMode.nowPreview", "%@ now shows Preview.")
        case .both: return Strings.text("tabs.viewMode.nowBoth", "%@ now shows Source and Preview.")
        }
    }
    /// The identifier of a mode's item in a tab's context menu.
    static func viewModeIdentifier(_ mode: DocumentViewMode) -> String { "tabs.command.viewMode." + mode.rawValue }
    /// Adds Source, Preview and Both with the View menu's titles (DS-20) and a checkmark on what
    /// the tab shows (DS-22). A tab whose document has no preview gets no section.
    private func addViewModeItems(to menu: NSMenu, target: TabID) {
        guard viewMode(of: target) != nil else { return }
        menu.addItem(.separator())
        for mode in DocumentViewMode.allCases {
            let item = menu.addItem(
                title: DocumentViewCommands.title(mode), action: #selector(invokeViewMode(_:)), target: self,
                representedObject: TabViewModeInvocation(mode, target))
            item.identifier = NSUserInterfaceItemIdentifier(Self.viewModeIdentifier(mode))
            item.isEnabled = validateMenuItem(item)
        }
    }
    @objc private func invokeViewMode(_ item: NSMenuItem) {
        guard let call = item.representedObject as? TabViewModeInvocation else { return }
        guard tab(call.targetID) != nil else {
            host.showTabMessage("This tab is no longer open. No document was changed.")
            return
        }
        let available = viewModeState(target: call.targetID)
        guard available.enabled else {
            host.showTabMessage(available.reason ?? "This tab command is unavailable.")
            return
        }
        setViewMode(call.mode, target: call.targetID)
    }
    private func stateFor(_ item: NSMenuItem) -> (enabled: Bool, reason: String?) {
        if let call = item.representedObject as? TabViewModeInvocation {
            return viewModeState(target: call.targetID)
        }
        guard let call = item.representedObject as? TabMenuInvocation else {
            return (false, "This tab command is unavailable.")
        }
        guard tab(call.targetID) != nil else { return (false, "This tab is no longer open.") }
        return state(call.command, target: call.targetID, scope: call.scope)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let s = stateFor(item)
        if let call = item.representedObject as? TabMenuInvocation {
            item.title = title(call.command, target: call.targetID, scope: call.scope)
            item.state = pinState(call.command, target: call.targetID, scope: call.scope)
        }
        if let call = item.representedObject as? TabViewModeInvocation {
            item.state = viewMode(of: call.targetID) == call.mode ? .on : .off
        }
        item.toolTip = s.reason
        return s.enabled
    }
    private func pinState(_ command: TabCommand, target: TabID?, scope: TabTargetCapture?) -> NSControl.StateValue {
        guard command == .pin, let target else { return .off }
        let tabs = members(target, scope: scope).compactMap(tab)
        let pinned = tabs.filter(\.isPinned).count
        return pinned == 0 ? .off : pinned == tabs.count ? .on : .mixed
    }
    func title(_ command: TabCommand, target: TabID?, scope: TabTargetCapture? = nil) -> String {
        guard let target else { return command.title }
        let chosen = members(target, scope: scope).compactMap(tab)
        if command == .close && chosen.count > 1 { return String(format: "Close %ld Tabs", chosen.count) }
        if command == .pin {
            let unpinned = chosen.filter { !$0.isPinned }.count
            let count = unpinned == 0 ? chosen.count : unpinned
            if count > 1 { return String(format: unpinned == 0 ? "Unpin %ld Tabs" : "Pin %ld Tabs", count) }
            return unpinned == 0 && !chosen.isEmpty ? "Unpin Tab" : "Pin Tab"
        }
        return command.title
    }
    func configure(_ item: NSMenuItem, command: TabCommand, target: TabID?) -> Bool {
        let scope = capture(target)
        let available = state(command, target: target, scope: scope)
        item.title = title(command, target: target, scope: scope)
        item.state = pinState(command, target: target, scope: scope)
        item.toolTip = available.reason
        return available.enabled
    }
    func performSelection(_ command: TabCommand, sender: Any? = nil) {
        let target = host.model.activeTab?.id
        perform(command, target: target, sender: sender, scope: capture(target))
    }
    @objc private func invoke(_ item: NSMenuItem) {
        guard let call = item.representedObject as? TabMenuInvocation else { return }
        perform(call.command, target: call.targetID, captured: true, scope: call.scope)
    }
    func perform(
        _ command: TabCommand, target: TabID?, captured: Bool = false, sender: Any? = nil,
        scope: TabTargetCapture? = nil
    ) {
        if isReopening { cancelReopen() }
        if captured && (target == nil || tab(target!) == nil) {
            host.showTabMessage("This tab is no longer open. No document was changed.")
            return
        }
        let available = state(command, target: target, scope: scope)
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
        case .close:
            if members(target, scope: scope).count > 1 {
                if let plan = closePlan(command, target: target, scope: scope) { beginBulk(plan) }
            } else {
                host.performSingleTabClose(target, sender: sender)
            }
        case .closeOthers, .closeLeft, .closeRight, .closeGroup, .closeSaved:
            if let plan = closePlan(command, target: target, scope: scope) { beginBulk(plan) }
        case .pin:
            let chosen = members(target, scope: scope)
            host.setPinnedTabs(chosen, target: target, pinned: chosen.contains { tab($0)?.isPinned == false })
        case .moveLeft: host.moveTab(target, direction: -1)
        case .moveRight: host.moveTab(target, direction: 1)
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
    private func beginBulk(_ plan: TabClosePlan) {
        let originalSelection = host.tabSelection, originalWorkspace = host.model
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
                if !committed {
                    host.restoreTabFocus(originalActive, responder: originalResponder)
                    host.restoreTabSelection(originalSelection, from: originalWorkspace)
                }
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
        let editor = host.presentation(for: tab.id)?.activeEditor ?? document.activeEditor
        let record = ClosedTabRecord(
            url: url, group: group, index: index, pinned: tab.isPinned, anchor: editor.selectionAnchor,
            caret: editor.selectionCaret, firstVisibleLine: editor.firstVisibleLine, fingerprint: nil)
        let capture = document.diskURL.flatMap { try? TabDiskCapture($0) }
        liveHistoryIDs[record.id] = document.runtimeID
        if let old = history.push(record) {
            liveHistoryIDs.removeValue(forKey: old.id)
            if let job = fingerprints.removeValue(forKey: old.id) {
                job.0.cancel()
                job.1.cancelQueued()
            }
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
        liveHistoryIDs.removeValue(forKey: id)
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
        liveHistoryIDs = [:]
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
    var hasPendingDiskRead: Bool { readTask != nil }
    private func focusExisting(_ record: ClosedTabRecord, in slot: GroupSlot, diskURL: URL) -> Bool {
        guard
            let existing = host.model.groups.first(where: { $0.slot == slot })?.tabs.first(where: {
                document($0.id)?.diskURL == diskURL
            }), let presentation = host.presentation(for: existing.id)
        else { return false }
        _ = consumeHistory(record.id)
        host.show(presentation, sender: nil)
        host.showTabMessage("The file is already open. Its existing tab was selected.")
        return true
    }
    private func reopenLive(_ record: ClosedTabRecord, in slot: GroupSlot, document doc: TextDocument) -> Bool {
        guard doc.isOpen else { return false }
        if let existing = host.model.groups.first(where: { $0.slot == slot })?.tabs.first(where: {
            $0.documentID == doc.runtimeID
        }), let p = host.presentation(for: existing.id) {
            guard consumeHistory(record.id) else { return false }
            host.show(p, sender: nil)
            host.showTabMessage(
                String(format: "Selected the existing view of %@ in %@.", doc.displayName, host.groupLabel(slot)))
            return true
        }
        guard let source = host.model.groups.flatMap(\.tabs).first(where: { $0.documentID == doc.runtimeID }),
            let id = host.openView(source.id, in: slot), let p = host.presentation(for: id)
        else { return false }
        host.placeTab(id, in: slot, index: record.index, pinned: record.pinned)
        host.show(p, sender: nil)
        p.primaryEditor.restoreClosedTabView(
            anchor: record.anchor, caret: record.caret, firstVisibleLine: record.firstVisibleLine)
        _ = consumeHistory(record.id)
        host.showTabMessage(String(format: "Reopened a view of %@ in %@.", doc.displayName, host.groupLabel(slot)))
        return true
    }
    private func reopen() {
        guard let record = history.latest else { return }
        let slot = host.model.groups.contains { $0.slot == record.group } ? record.group : host.model.focusedGroup
        // Identity lookup precedes path resolution, fingerprint waits and disk reads.
        if let runtimeID = liveHistoryIDs[record.id],
            let doc = host.presentations.compactMap({ $0.document as? TextDocument }).first(where: {
                $0.runtimeID == runtimeID && $0.isOpen
            })
        {
            _ = reopenLive(record, in: slot, document: doc)
            return
        }
        let diskURL = TextDocument.canonicalDiskURL(record.url)
        if let doc = host.presentations.compactMap({ $0.document as? TextDocument }).first(where: {
            $0.diskURL == diskURL && $0.isOpen
        }) {
            _ = reopenLive(record, in: slot, document: doc)
            return
        }
        if focusExisting(record, in: slot, diskURL: diskURL) { return }
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
                let url = diskURL
                let task = Task.detached(priority: .userInitiated) { try await TabDiskIO.shared.read(url) }
                self.readTask = task
                let read = try await task.value
                try Task.checkCancellation()
                guard self.reopenGeneration == token, self.history.latest?.id == record.id,
                    self.sameStructure(host.model, snapshot)
                else { return }
                guard TextDocument.canonicalDiskURL(record.url) == url,
                    (try? WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max)) == read.signature
                else { throw WorkspaceError.invalid("The file changed while reopening. Try again.") }
                guard host.acceptsDocumentCreation else { return }
                self.publishingReopen = true
                defer { self.publishingReopen = false }
                if self.focusExisting(record, in: slot, diskURL: url) { return }
                let document = try DocumentFactory.openCaptured(
                    CapturedFileRead(
                        data: read.data, sample: FileSample(digest: read.digest, signature: nil),
                        modificationDate: read.modificationDate), from: record.url, expectedDiskURL: url, display: false
                )
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
