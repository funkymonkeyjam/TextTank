import AppKit
import TextTankCore
import EditorBridge
import NativeSearch

/// The sole native-window owner. Its NSWindowController.document is always nil.
final class WorkspaceWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation,
    NSMenuItemValidation
{
    private static var fallback: WorkspaceWindowController?
    static var current: WorkspaceWindowController {
        if let host = EditorServices.current?.workspaceHost { return host }
        if let fallback { return fallback }
        let host = WorkspaceWindowController()
        fallback = host
        return host
    }
    private(set) var model = TabWorkspace()
    private(set) var tabSelection = TabSelectionState()
    @MainActor private final class Entry {
        weak var presentation: EditorWindowController?
        init(_ value: EditorWindowController) { presentation = value }
    }
    private var entries: [DocumentID: Entry] = [:]
    var acceptsDocumentCreation: Bool {
        if let current = EditorServices.current?.workspaceHost { return current === self }
        return Self.fallback === self
    }
    var presentations: [EditorWindowController] {
        model.groups.flatMap(\.tabs).compactMap { entries[$0.documentID]?.presentation }
    }
    var active: EditorWindowController? { model.activeTab.flatMap { entries[$0.documentID]?.presentation } }
    private var openIDs: Set<DocumentID> { Set(entries.keys) }
    let tabStrip = DocumentTabStrip()
    private let content = NSView()
    private let empty = NSStackView()
    private var mounted: NSView?
    private var observations: [NSKeyValueObservation] = []
    private var automationObserver: NSObjectProtocol?
    private var savingArrangement = false
    private var saveScheduled = false
    lazy var tabCommands = TabCommandController(host: self)
    private var removingTabs = false
    private let emptyStatus = AnnouncingLabel(labelWithString: "")
    private var returnTab: TabID?
    private var returnSelection: (TabSelectionState, TabWorkspace)?
    init() {
        let window = DocumentTabWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.animationBehavior = RuntimeEnvironment.current.windowAnimation ?? .none
        window.title = "TextTank"
        window.center()
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = NSSize(width: 800, height: 500)
        window.routeCloseButtonToQuit()
        let root = NSView()
        window.contentView = root
        tabStrip.host = self
        for view in [tabStrip, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: root.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: 36),
            content.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let label = NSTextField(labelWithString: "Open a document or create a new one.")
        let new = NSButton(title: EditorToolbarCommand.new.title, target: nil, action: EditorToolbarCommand.new.action)
        new.setAccessibilityLabel("Create a new document")
        let open = NSButton(
            title: EditorToolbarCommand.open.title, target: nil, action: EditorToolbarCommand.open.action)
        open.setAccessibilityLabel("Open a document")
        empty.orientation = .vertical
        empty.spacing = 12
        [label, new, open, emptyStatus].forEach { empty.addArrangedSubview($0) }
        empty.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        let toolbar = NSToolbar(
            identifier: EditorToolbarPreferences.identifier(for: EditorServices.current?.automations))
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = EditorToolbarPreferences.nativeAutosaveAllowed
        window.toolbar = toolbar
        restoreToolbarArrangement()
        refreshAutomationToolbar()
        observations = [
            toolbar.observe(\.displayMode) { [weak self] _, _ in MainActor.assumeIsolated { self?.scheduleSave() } },
            toolbar.observe(\.isVisible) { [weak self] _, _ in MainActor.assumeIsolated { self?.scheduleSave() } }
        ]
        automationObserver = NotificationCenter.default.addObserver(
            forName: .textTankAutomationsDidChange, object: EditorServices.current?.automations, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshAutomationToolbar() } }
        WindowFrames.track(window, as: "TextTank.Document")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    func register(_ presentation: EditorWindowController, document: TextDocument) {
        let previous = model.activeTab?.id
        entries[document.runtimeID] = Entry(presentation)
        do { _ = try model.open(document.runtimeID, openDocuments: openIDs) } catch {
            preconditionFailure("Invalid workspace registration: \(error)")
        }
        if let previous { try? model.activate(previous, openDocuments: openIDs) }
        // A visible empty host mounts its first registered tab without ordering another window.
        metadataChanged()
        if mounted == nil, window?.isVisible == true, let active { activate(active, focus: false, explicit: false) }
    }
    func activate(
        _ presentation: EditorWindowController, focus: Bool = true, explicit: Bool = true,
        preserveSelection: Bool = false
    ) {
        if explicit { tabCommands.cancelReopen() }
        guard let document = presentation.document as? TextDocument, document.isOpen,
            entries[document.runtimeID]?.presentation === presentation,
            let tab = model.groups.flatMap(\.tabs).first(where: { $0.documentID == document.runtimeID }),
            window?.attachedSheet == nil || active === presentation
        else { return }
        if explicit { endBackgroundCloseReturn() }
        let previous = active
        do { try model.activate(tab.id, openDocuments: openIDs) } catch { return }
        if explicit && !preserveSelection { tabSelection.collapse(in: model) }
        if previous !== presentation { previous?.stopStatusTimer() }
        if mounted !== presentation.presentationRoot {
            window?.makeFirstResponder(nil)
            mounted?.removeFromSuperview()
            mounted = presentation.presentationRoot
            let root = presentation.presentationRoot
            root.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(root)
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: content.topAnchor),
                root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
        }
        empty.isHidden = true
        // Explicit chain preserves NSDocument's native Save/Print validation and actions.
        window?.nextResponder = presentation
        presentation.nextResponder = NSApp
        EditorServices.current?.noteActiveController(presentation)
        metadataChanged()
        presentation.visibilityChanged()
        if presentation.isPresented { presentation.refreshStatusDetails() }
        validateToolbar()
        if focus { window?.makeFirstResponder(presentation.activeEditor) }
    }
    func show(_ presentation: EditorWindowController, sender: Any?) {
        activate(presentation)
        window?.makeKeyAndOrderFront(sender)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let window { WindowFrames.didPresent(window) }
        active?.visibilityChanged()
    }
    func unregister(_ presentation: EditorWindowController, document: TextDocument) {
        guard entries[document.runtimeID]?.presentation === presentation,
            let tab = model.groups.flatMap(\.tabs).first(where: { $0.documentID == document.runtimeID })
        else { return }
        let wasActive = active === presentation
        let before = model
        do { _ = try model.remove(tab.id, reviewed: true, openDocuments: openIDs) } catch {
            preconditionFailure("Invalid workspace removal")
        }
        entries.removeValue(forKey: document.runtimeID)
        if !removingTabs { tabSelection.reconcile(from: before, to: model) }
        if removingTabs {
            if mounted === presentation.presentationRoot {
                window?.makeFirstResponder(nil)
                mounted?.removeFromSuperview()
                mounted = nil
            }
            return
        }
        if wasActive {
            mounted?.removeFromSuperview()
            mounted = nil
            if let back = returnTab, model.groups.flatMap(\.tabs).contains(where: { $0.id == back }) {
                try? model.activate(back, openDocuments: openIDs)
            }
            if let (selection, original) = returnSelection {
                tabSelection = selection
                tabSelection.reconcile(from: original, to: model)
            } else {
                // Removal may have picked an intermediate neighbour before returnTab.
                // Collapse only after the final active identity has been restored.
                tabSelection.collapse(in: model)
            }
            endBackgroundCloseReturn()
            if let next = active {
                activate(next, explicit: false)
            } else {
                empty.isHidden = false
                window?.nextResponder = NSApp
                window?.makeFirstResponder(nil)
            }
        }
        metadataChanged()
        validateToolbar()
    }
    func closeTab(_ id: TabID, sender: Any?) { tabCommands.perform(.close, target: id, captured: true, sender: sender) }
    func performSingleTabClose(_ id: TabID, sender: Any?) {
        guard window?.attachedSheet == nil, let tab = model.groups.flatMap(\.tabs).first(where: { $0.id == id }),
            let presentation = entries[tab.documentID]?.presentation,
            let document = presentation.document as? TextDocument
        else { return }
        let back = model.activeTab?.id
        let original = (tabSelection, model)
        let wasSelected = tabSelection.selected(in: model, group: model.focusedGroup).contains(id)
        activate(presentation, explicit: false)
        returnSelection = wasSelected ? nil : original
        returnTab = back == id ? nil : back
        document.requestTabClose(sender)
    }
    func closeActive(_ sender: Any?) { if let id = model.activeTab?.id { closeTab(id, sender: sender) } }
    func endBackgroundCloseReturn() {
        returnTab = nil
        returnSelection = nil
    }
    func selectTab(_ id: TabID, gesture: TabSelectionGesture) {
        guard !tabCommands.isBusy, window?.attachedSheet == nil else { return }
        tabCommands.cancelReopen()
        var next = model
        do { try tabSelection.apply(id, gesture: gesture, workspace: &next, openDocuments: openIDs) } catch { return }
        if next.activeTab?.id != model.activeTab?.id || gesture == .plain {
            if let chosen = next.activeTab?.id, let p = presentation(for: chosen) {
                activate(p, preserveSelection: true)
            }
        } else {
            endBackgroundCloseReturn()
            metadataChanged()
        }
    }
    func restoreTabSelection(_ selection: TabSelectionState, from original: TabWorkspace) {
        tabSelection = selection
        tabSelection.reconcile(from: original, to: model)
        metadataChanged()
    }
    func presentation(for id: TabID) -> EditorWindowController? {
        guard let tab = model.groups.flatMap(\.tabs).first(where: { $0.id == id }) else { return nil }
        return entries[tab.documentID]?.presentation
    }
    func placeTab(_ id: TabID, in slot: GroupSlot, index: Int, pinned: Bool) {
        do { try model.place(id, in: slot, index: index, pinned: pinned, openDocuments: openIDs) } catch {
            showTabMessage("The tab could not be placed because the workspace changed.")
        }
        metadataChanged()
    }
    func setPinnedTabs(_ ids: Set<TabID>, target: TabID, pinned: Bool) {
        guard tabCommands.state(.pin, target: target).enabled,
            let group = model.groups.first(where: { $0.tabs.contains { $0.id == target } })
        else { return }
        do {
            let changed = try model.setPinned(ids, in: group.slot, pinned: pinned, openDocuments: openIDs)
            metadataChanged()
            tabStrip.revealOrganizationChange(target)
            if changed.count == 1, let name = (presentation(for: changed[0])?.document as? TextDocument)?.displayName {
                showTabMessage(String(format: pinned ? "%@ is pinned." : "%@ is unpinned.", name))
            } else if !changed.isEmpty {
                showTabMessage(String(format: pinned ? "Pinned %ld tabs." : "Unpinned %ld tabs.", changed.count))
            }
        } catch { showTabMessage("The tabs changed. No tabs were pinned or unpinned. Try again.") }
    }
    func moveTab(_ id: TabID, direction: Int) {
        guard model.canMoveTab(id, direction: direction),
            let group = model.groups.first(where: { $0.tabs.contains { $0.id == id } }),
            let index = group.tabs.firstIndex(where: { $0.id == id })
        else { return }
        reorderTab(id, to: index + direction)
    }
    func reorderTab(_ id: TabID, to index: Int) {
        guard tabCommands.state(.pin, target: id).enabled else { return }
        do { try model.reorderTab(id, to: index, openDocuments: openIDs) } catch {
            showTabMessage("The tabs changed. No tab was moved. Try again.")
            return
        }
        metadataChanged()
        tabStrip.revealOrganizationChange(id)
        if let group = model.groups.first(where: { $0.tabs.contains { $0.id == id } }),
            let position = group.tabs.firstIndex(where: { $0.id == id }),
            let name = (presentation(for: id)?.document as? TextDocument)?.displayName
        {
            showTabMessage(String(format: "%@, tab %ld of %ld.", name, position + 1, group.tabs.count))
        }
    }
    /// Internal validated model replacement; only Single is rendered until Stage 3.
    func replaceTabModel(_ value: TabWorkspace) throws {
        guard value.layout == .single else { throw TabModelError.invalid }
        try value.validate(openDocuments: openIDs)
        let before = model
        model = value
        tabSelection.reconcile(from: before, to: model)
        metadataChanged()
    }
    private(set) var lastTabMessage = ""
    func showTabMessage(_ message: String) {
        lastTabMessage = message
        if let active {
            active.showTransientStatus(message, seconds: 8, announce: true)
        } else {
            emptyStatus.stringValue = message
            Announce.say(message, from: window)
        }
    }
    func restoreTabFocus(_ id: TabID?, responder: NSResponder?) {
        if let id, let p = presentation(for: id) {
            activate(p, focus: false, explicit: false)
            if let responder { _ = window?.makeFirstResponder(responder) }
        }
    }
    func commitTabClose(_ plan: TabClosePlan, originalActive: TabID?, originalResponder: NSResponder?) {
        let before = model, selection = tabSelection
        tabCommands.prepareBulkHistory(before)
        removingTabs = true
        endBackgroundCloseReturn()
        active?.stopStatusTimer()
        for id in plan.tabs {
            guard let tab = model.groups.flatMap(\.tabs).first(where: { $0.id == id }), let p = presentation(for: id),
                let doc = p.document as? TextDocument
            else { continue }
            let final = model.groups.flatMap(\.tabs).filter { $0.documentID == tab.documentID }.count == 1
            if final {
                doc.close()
            } else {
                tabCommands.recordNonfinalTab(id)
                _ = try? model.remove(id, reviewed: false, openDocuments: openIDs)
            }
        }
        removingTabs = false
        tabCommands.finishBulkHistory()
        let survivors = Set(model.groups.flatMap(\.tabs).map(\.id))
        let chosen =
            originalActive.flatMap { survivors.contains($0) ? $0 : nil }
            ?? (survivors.contains(plan.target) ? plan.target : model.groups.first { $0.slot == plan.group }?.activeTab)
        if let chosen, let p = presentation(for: chosen) {
            activate(p, focus: false, explicit: false)
            if chosen == originalActive, let originalResponder {
                _ = window?.makeFirstResponder(originalResponder)
            } else {
                _ = window?.makeFirstResponder(p.activeEditor)
            }
        } else {
            mounted?.removeFromSuperview()
            mounted = nil
            empty.isHidden = false
            window?.nextResponder = NSApp
            window?.makeFirstResponder(nil)
        }
        restoreTabSelection(selection, from: before)
        validateToolbar()
    }
    func cycle(_ direction: Int) {
        guard window?.attachedSheet == nil else { return }
        var next = model
        try? next.cycle(direction, openDocuments: openIDs)
        if let tab = next.activeTab, let presentation = entries[tab.documentID]?.presentation { activate(presentation) }
    }
    func metadataChanged() {
        if let doc = active?.document as? TextDocument {
            window?.title = doc.displayName
            window?.representedURL = doc.fileURL
            window?.isDocumentEdited = doc.isDocumentEdited
        } else {
            window?.title = "TextTank"
            window?.representedURL = nil
            window?.isDocumentEdited = false
        }
        tabStrip.refresh()
    }
    func visibilityChanged() { presentations.forEach { $0.visibilityChanged() } }
    func validateToolbar() {
        for item in window?.toolbar?.items ?? [] { item.isEnabled = validateToolbarItem(item) }
        if let window { EditorToolbarAccessibility.apply(to: window) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        EditorToolbarCommand.allCases.map { NSToolbarItem.Identifier($0.rawValue) } + [
            .flexibleSpace, NSToolbarItem.Identifier("TextTank.Automations")
        ]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool
    ) -> NSToolbarItem? {
        if let command = EditorToolbarCommand(rawValue: id.rawValue) { return command.makeItem() }
        return id.rawValue == "TextTank.Automations" ? EditorServices.current?.automations?.makeToolbarItem() : nil
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.action == EditorToolbarCommand.new.action || item.action == EditorToolbarCommand.open.action {
            return true
        }
        if item.itemIdentifier.rawValue == "TextTank.Automations" { return true }
        guard let active else {
            if item.action == #selector(EditorWindowController.clone(_:)) {
                item.menuFormRepresentation?.state = .off
                if item.toolTip != EditorToolbarCommand.split.scope {
                    item.toolTip = EditorToolbarCommand.split.scope
                    item.image = NSImage(
                        systemSymbolName: EditorToolbarCommand.split.symbol, accessibilityDescription: item.toolTip)
                }
            }
            return false
        }
        if item.action == #selector(NSDocument.save(_:)), let doc = active.document as? TextDocument {
            return doc.validateMenuItem(NSMenuItem(title: item.label, action: item.action, keyEquivalent: ""))
        }
        return active.validateToolbarItem(item)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { active?.validateMenuItem(item) ?? false }
    func toolbarWillAddItem(_ notification: Notification) { scheduleSave() }
    func toolbarDidRemoveItem(_ notification: Notification) { scheduleSave() }
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.saveToolbarArrangement()
            self.validateToolbar()
        }
    }
    func saveToolbarArrangement() {
        guard !savingArrangement, let toolbar = window?.toolbar else { return }
        EditorToolbarPreferences.save(toolbar)
    }
    private func restoreToolbarArrangement() {
        guard let toolbar = window?.toolbar, let state = EditorToolbarPreferences.load() else { return }
        savingArrangement = true
        defer { savingArrangement = false }
        let allowed = Set(toolbarAllowedItemIdentifiers(toolbar))
        var seen = Set<NSToolbarItem.Identifier>()
        let ids = state.identifiers.map { NSToolbarItem.Identifier($0) }.filter {
            allowed.contains($0) && ($0 == .flexibleSpace || seen.insert($0).inserted)
        }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, id) in ids.enumerated() { toolbar.insertItem(withItemIdentifier: id, at: index) }
        toolbar.displayMode = NSToolbar.DisplayMode(rawValue: state.displayMode) ?? .iconAndLabel
        toolbar.isVisible = state.visible
    }
    func refreshAutomationToolbar() {
        guard let toolbar = window?.toolbar, let automations = EditorServices.current?.automations else { return }
        for index in toolbar.items.indices.reversed()
        where toolbar.items[index].itemIdentifier.rawValue.hasPrefix("TextTank.Automation.") {
            toolbar.removeItem(at: index)
        }
        for case let item as NSMenuToolbarItem in toolbar.items
        where item.itemIdentifier.rawValue == "TextTank.Automations" { automations.refreshToolbarItem(item) }
        saveToolbarArrangement()
        validateToolbar()
    }
    deinit {
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated {
            if let automationObserver { NotificationCenter.default.removeObserver(automationObserver) }
        }
    }
}
