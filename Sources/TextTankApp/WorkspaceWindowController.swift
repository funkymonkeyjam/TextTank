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
    private var entries: [TabID: EditorWindowController] = [:]
    private var documents: [DocumentID: WeakDocument] = [:]
    @MainActor private final class WeakDocument {
        weak var value: TextDocument?
        init(_ document: TextDocument) { value = document }
    }
    private var recent: [DocumentID: [TabID]] = [:]
    private(set) var isMutatingGroups = false
    var acceptsDocumentCreation: Bool {
        guard !isMutatingGroups else { return false }
        if let current = EditorServices.current?.workspaceHost { return current === self }
        return Self.fallback === self
    }
    var presentations: [EditorWindowController] { model.groups.flatMap(\.tabs).compactMap { presentation(for: $0.id) } }
    /// Visual order is stable when keyboard focus moves between groups.
    var visibleComparisonEditors: (TTEditor, TTEditor)? {
        guard model.groups.count == 2 else { return nil }
        let editors = model.groups.compactMap { group -> TTEditor? in
            guard let tab = group.activeTab, let view = presentation(for: tab),
                groupSurfaces[group.slot]?.mounted === view.presentationRoot else { return nil }
            return view.activeEditor
        }
        guard editors.count == 2 else { return nil }
        return (editors[0], editors[1])
    }
    var active: EditorWindowController? { model.activeTab.flatMap { presentation(for: $0.id) } }
    private var openIDs: Set<DocumentID> { Set(documents.keys) }
    private(set) var groupSurfaces: [GroupSlot: EditorGroupSurface] = [:]
    let groupContainer = EditorGroupContainer()
    var tabStrip: DocumentTabStrip { groupSurfaces[.first]!.strip }
    var tabStrips: [DocumentTabStrip] { model.groups.compactMap { groupSurfaces[$0.slot]?.strip } }
    private let content = NSView()
    private var observations: [NSKeyValueObservation] = []
    private var automationObserver: NSObjectProtocol?
    private var savingArrangement = false
    private var saveScheduled = false
    lazy var tabCommands = TabCommandController(host: self)
    lazy var groupCommands = GroupCommandController(host: self)
    let layoutPicker = NSPopUpButton(frame: .zero, pullsDown: true)
    private var removingTabs = false
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
        content.frame = root.bounds
        content.autoresizingMask = [.width, .height]
        root.addSubview(content)
        groupContainer.translatesAutoresizingMaskIntoConstraints = false
        layoutPicker.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(groupContainer)
        content.addSubview(layoutPicker)
        layoutPicker.setAccessibilityLabel("Editor group layout")
        refreshLayoutPicker()
        NSLayoutConstraint.activate([
            layoutPicker.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            layoutPicker.topAnchor.constraint(equalTo: content.topAnchor, constant: 3),
            layoutPicker.heightAnchor.constraint(equalToConstant: 30),
            layoutPicker.widthAnchor.constraint(equalToConstant: 160),
            groupContainer.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            groupContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            groupContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            groupContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let first = EditorGroupSurface(slot: .first, host: self)
        groupSurfaces[.first] = first
        groupContainer.configure(.single, surfaces: [first])
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
        documents[document.runtimeID] = WeakDocument(document)
        do {
            let id = try model.open(document.runtimeID, openDocuments: openIDs)
            entries[id] = presentation
            presentation.bindTab(id)
        } catch { preconditionFailure("Invalid workspace registration: \(error)") }
        if let previous { try? model.activate(previous, openDocuments: openIDs) }
        metadataChanged()
        if window?.isVisible == true { syncGroups() }
    }
    func presentation(for document: DocumentID) -> EditorWindowController? {
        if let active, (active.document as? TextDocument)?.runtimeID == document { return active }
        if let p = recent[document]?.compactMap({ entries[$0] }).first(where: { !$0.isRetired }) { return p }
        return presentations.first { ($0.document as? TextDocument)?.runtimeID == document }
    }
    func isPresented(_ presentation: EditorWindowController) -> Bool {
        model.groups.contains { group in group.activeTab.flatMap { entries[$0] } === presentation }
    }
    func activate(
        _ presentation: EditorWindowController, focus: Bool = true, explicit: Bool = true,
        preserveSelection: Bool = false
    ) {
        guard !isMutatingGroups, let document = presentation.document as? TextDocument, document.isOpen,
            let id = presentation.tabID, entries[id] === presentation,
            window?.attachedSheet == nil || active === presentation
        else { return }
        if explicit {
            tabCommands.cancelReopen()
            endBackgroundCloseReturn()
        }
        do { try model.activate(id, openDocuments: openIDs) } catch { return }
        if explicit && !preserveSelection { tabSelection.collapse(in: model) }
        recent[document.runtimeID] = [id] + (recent[document.runtimeID] ?? []).filter { $0 != id }
        syncGroups()
        window?.nextResponder = presentation
        presentation.nextResponder = NSApp
        EditorServices.current?.noteActiveController(presentation)
        document.externalFile.check(prioritized: true)
        metadataChanged()
        validateToolbar()
        if focus { window?.makeFirstResponder(presentation.keyboardFocusView) }
    }
    func focusGroup(_ slot: GroupSlot) {
        guard !isMutatingGroups, !tabCommands.isBusy, window?.attachedSheet == nil else { return }
        tabCommands.cancelReopen()
        endBackgroundCloseReturn()
        do { try model.focusGroup(slot, openDocuments: openIDs) } catch { return }
        if let active {
            activate(active, preserveSelection: true)
        } else {
            window?.nextResponder = NSApp
            window?.makeFirstResponder(nil)
            metadataChanged()
            validateToolbar()
        }
    }
    private func syncGroups() {
        for group in model.groups {
            groupSurfaces[group.slot]?.mount(group.activeTab.flatMap { entries[$0]?.presentationRoot })
            groupSurfaces[group.slot]?.refresh()
        }
        presentations.forEach { $0.visibilityChanged() }
        active?.resumeVisibleFindPreview()
        window?.contentView?.layoutSubtreeIfNeeded()
        for group in model.groups {
            if let id = group.activeTab { entries[id]?.applyRestoredSplitIfMounted() }
        }
    }
    private func refreshLayoutPicker() {
        let menu = groupCommands.layoutMenu(picker: true)
        layoutPicker.menu = menu
        groupCommands.menuNeedsUpdate(menu)
    }
    func groupLabel(_ slot: GroupSlot) -> String {
        let position: String
        switch model.layout {
        case .single: position = ""
        case .twoColumns: position = slot == .first ? "Left" : "Right"
        case .twoRows: position = slot == .first ? "Top" : "Bottom"
        case .grid2x2: position = ["Top Left", "Top Right", "Bottom Left", "Bottom Right"][slot.rawValue - 1]
        }
        return "Group \(slot.rawValue)" + (position.isEmpty ? "" : ", " + position)
    }
    func canFitSessionLayout(_ layout: LayoutKind, availableContent: TabGroupExtent? = nil) -> Bool {
        if let availableContent {
            return TabGroupGeometry.fits(TabGroupGeometry.minimumContent(layout), available: availableContent)
        }
        guard let window, let screen = window.screen ?? NSScreen.main else { return layout == .single }
        let available = window.contentRect(forFrameRect: screen.visibleFrame).size
        return TabGroupGeometry.fits(
            TabGroupGeometry.minimumContent(layout),
            available: TabGroupExtent(width: available.width, height: available.height))
    }
    func captureSessionLayout() -> WorkspaceLayoutState {
        WorkspaceLayoutState(
            layout: model.layout, focusedGroup: model.focusedGroup,
            groups: model.groups.map { group in
                WorkspaceLayoutState.Group(
                    slot: group.slot, activeTabIndex: group.tabs.firstIndex { $0.id == group.activeTab },
                    tabs: group.tabs.compactMap { tab in
                        guard let p = entries[tab.id], let doc = p.document as? TextDocument else { return nil }
                        return p.sessionTab(documentID: DocumentID(doc.recoveryID), pinned: tab.isPinned)
                    })
            })
    }
    @discardableResult func restoreSessionLayout(
        _ state: WorkspaceLayoutState, documents mapping: [DocumentID: TextDocument]
    ) -> Bool {
        guard Set(mapping.values.map(\.runtimeID)) == openIDs,
            let plan = try? model.planSessionLayout(
                state, documentIDs: mapping.mapValues(\.runtimeID), openDocuments: openIDs),
            applyGroupChange(plan)
        else { return false }
        let minimum = TabGroupGeometry.minimumContent(state.layout)
        window?.contentMinSize = NSSize(width: minimum.width, height: minimum.height)
        if let window {
            let size = window.contentView?.bounds.size ?? .zero
            window.setContentSize(
                NSSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height)))
        }
        for (saved, actual) in zip(state.groups, model.groups) {
            for (view, tab) in zip(saved.tabs, actual.tabs) {
                entries[tab.id]?.restoreSessionTab(view)
            }
        }
        syncGroups()
        if let active {
            activate(active, focus: false, explicit: false)
            window?.makeFirstResponder(active.restoredKeyboardFocusView)
        } else {
            window?.makeFirstResponder(nil)
        }
        return true
    }
    @discardableResult func setEditorLayout(_ layout: LayoutKind, availableContent: TabGroupExtent? = nil) -> Bool {
        guard !tabCommands.isBusy, !tabCommands.isReopening, window?.attachedSheet == nil else { return false }
        if layout == model.layout { return true }
        let minimum = TabGroupGeometry.minimumContent(layout)
        if let window, let screen = window.screen ?? NSScreen.main {
            let available = window.contentRect(forFrameRect: screen.visibleFrame).size
            guard
                TabGroupGeometry.fits(
                    minimum,
                    available: availableContent ?? TabGroupExtent(width: available.width, height: available.height))
            else {
                showTabMessage(
                    "This screen cannot fit that editor layout. The current layout is unchanged. Use a larger display.")
                return false
            }
        }
        guard let plan = try? model.planLayout(layout, openDocuments: openIDs) else { return false }
        guard applyGroupChange(plan) else { return false }
        window?.contentMinSize = NSSize(width: minimum.width, height: minimum.height)
        if let window {
            let size = window.contentView?.bounds.size ?? .zero
            window.setContentSize(
                NSSize(width: max(size.width, minimum.width), height: max(size.height, minimum.height)))
            if let screen = window.screen {
                window.setFrameOrigin(
                    NSPoint(
                        x: max(
                            screen.visibleFrame.minX,
                            min(window.frame.minX, screen.visibleFrame.maxX - window.frame.width)),
                        y: max(
                            screen.visibleFrame.minY,
                            min(window.frame.minY, screen.visibleFrame.maxY - window.frame.height))))
            }
        }
        if let name = (active?.document as? TextDocument)?.displayName {
            showTabMessage(
                String(
                    format: "%@. %@ is in %@.", GroupCommandController.title(layout), name,
                    groupLabel(model.focusedGroup)))
        } else {
            showTabMessage(
                String(
                    format: "%@. %@ is focused.", GroupCommandController.title(layout), groupLabel(model.focusedGroup)))
        }
        return true
    }
    @discardableResult func openView(_ source: TabID, in slot: GroupSlot) -> TabID? {
        guard !tabCommands.isBusy, !tabCommands.isReopening, window?.attachedSheet == nil,
            let plan = try? model.planAdditionalView(source, to: slot, openDocuments: openIDs),
            let id = plan.resolved[source], applyGroupChange(plan)
        else { return nil }
        let name = (presentation(for: id)?.document as? TextDocument)?.displayName ?? "Document"
        showTabMessage(
            plan.created.isEmpty
                ? String(format: "Selected %@ in %@.", name, groupLabel(slot))
                : String(format: "Opened another view of %@ in %@.", name, groupLabel(slot)))
        return id
    }
    func moveTabs(_ ids: [TabID], target: TabID, to slot: GroupSlot) {
        guard !tabCommands.isBusy, !tabCommands.isReopening, window?.attachedSheet == nil,
            let plan = try? model.planMove(ids, target: target, to: slot, openDocuments: openIDs),
            applyGroupChange(plan)
        else { return }
        tabSelection.set(Set(ids.compactMap { plan.resolved[$0] }), in: model, group: slot)
        metadataChanged()
        groupSurfaces[slot]?.strip.revealOrganizationChange(plan.resolved[target] ?? target)
        let name =
            (presentation(for: plan.resolved[target] ?? target)?.document as? TextDocument)?.displayName ?? "Document"
        showTabMessage(
            ids.count == 1
                ? "Moved \(name) to \(groupLabel(slot))."
                : String(format: "Moved %ld tabs, including %@, to %@.", ids.count, name, groupLabel(slot)))
    }
    func closeEditorGroup(_ slot: GroupSlot) {
        let priorActive = model.groups.first { $0.slot == slot }?.activeTab
        let name = priorActive.flatMap { presentation(for: $0)?.document as? TextDocument }?.displayName
        guard !tabCommands.isBusy, !tabCommands.isReopening, window?.attachedSheet == nil,
            let plan = try? model.planCloseGroup(slot, openDocuments: openIDs), applyGroupChange(plan)
        else { return }
        let resolved = priorActive.flatMap { plan.resolved[$0] }
        let destination = model.groups.first { $0.tabs.contains { $0.id == resolved } }?.slot ?? model.focusedGroup
        if let name {
            showTabMessage(
                String(format: "Closed Group %ld. %@ is in %@.", slot.rawValue, name, groupLabel(destination)))
        } else {
            showTabMessage(
                String(
                    format: "Closed Group %ld. All documents remain open. %@ is focused.", slot.rawValue,
                    groupLabel(model.focusedGroup)))
        }
    }
    @discardableResult func applyGroupChange(_ plan: TabGroupChange) -> Bool {
        guard !isMutatingGroups, !tabCommands.isBusy, !tabCommands.isReopening, window?.attachedSheet == nil,
            plan.isCurrent(workspace: model)
        else { return false }
        do { try plan.result.validate(openDocuments: openIDs) } catch { return false }
        let before = model, selection = tabSelection
        let originalActive = active, originalResponder = window?.firstResponder
        isMutatingGroups = true
        for tab in plan.created {
            guard let doc = documents[tab.documentID]?.value,
                let sourceID = plan.createdSources[tab.id],
                let source = entries[sourceID], !source.isRetired, source.document === doc
            else {
                isMutatingGroups = false
                return false
            }
            // The validated plan maps the chosen source TabID to this fresh view. A
            // document-MRU lookup would copy an unrelated sibling's caret/wrap/zoom.
            let seed = source.activeEditor
            let editor = TTEditor(frame: seed.frame)
            editor.shareDocument(with: seed)
            editor.adoptViewState(from: seed)
            editor.restoreClosedTabView(
                anchor: seed.selectionAnchor, caret: seed.selectionCaret, firstVisibleLine: seed.firstVisibleLine)
            let p = EditorWindowController(document: doc, editor: editor)
            doc.addWindowController(p)
            entries[tab.id] = p
            p.bindTab(tab.id)
        }
        // Stage native views before publishing identities. Retirement never closes a document.
        for id in plan.retired {
            guard let p = entries[id], let doc = p.document as? TextDocument,
                let survivor = plan.result.groups.flatMap(\.tabs).first(where: { $0.documentID == doc.runtimeID }),
                let successor = entries[survivor.id]
            else { continue }
            doc.promoteEditor(from: p, to: successor)
            p.retireTab(inFavorOf: successor.primaryEditor)
            doc.removeWindowController(p)
            entries.removeValue(forKey: id)
            recent[doc.runtimeID]?.removeAll { $0 == id }
        }
        let changedLayout = before.layout != plan.result.layout
        if changedLayout {
            let old = groupSurfaces
            groupSurfaces = [:]
            for group in plan.result.groups {
                let surface =
                    plan.groupOrigins[group.slot].flatMap { old[$0] }
                    ?? EditorGroupSurface(slot: group.slot, host: self)
                surface.slot = group.slot
                groupSurfaces[group.slot] = surface
            }
        }
        model = plan.result
        tabSelection = selection
        tabSelection.reconcile(from: before, to: model)
        if changedLayout {
            groupContainer.configure(model.layout, surfaces: model.groups.compactMap { groupSurfaces[$0.slot] })
        }
        isMutatingGroups = false
        if changedLayout { groupCommands.refreshMenu() }
        if let active {
            activate(active, focus: false, explicit: false, preserveSelection: true)
            if active === originalActive, let responder = originalResponder {
                window?.makeFirstResponder(responder)
            } else {
                window?.makeFirstResponder(active.keyboardFocusView)
            }
        } else {
            syncGroups()
            metadataChanged()
            window?.nextResponder = NSApp
            window?.makeFirstResponder(nil)
        }
        tabStrips.forEach { $0.refresh() }
        validateToolbar()
        return true
    }
    func show(_ presentation: EditorWindowController, sender: Any?) {
        activate(presentation)
        window?.makeKeyAndOrderFront(sender)
        window?.contentView?.layoutSubtreeIfNeeded()
        if let window { WindowFrames.didPresent(window) }
        active?.visibilityChanged()
    }
    func unregister(_ presentation: EditorWindowController, document: TextDocument) {
        guard let id = presentation.tabID, entries[id] === presentation else { return }
        let wasActive = model.activeTab?.id == id, before = model
        _ = try? model.remove(id, reviewed: true, openDocuments: openIDs)
        presentation.presentationRoot.removeFromSuperview()
        entries.removeValue(forKey: id)
        recent[document.runtimeID]?.removeAll { $0 == id }
        if !model.groups.flatMap(\.tabs).contains(where: { $0.documentID == document.runtimeID }) {
            documents.removeValue(forKey: document.runtimeID)
            recent.removeValue(forKey: document.runtimeID)
        }
        if !removingTabs { tabSelection.reconcile(from: before, to: model) }
        if wasActive && !removingTabs {
            if let back = returnTab { try? model.activate(back, openDocuments: openIDs) }
            if let (selection, original) = returnSelection {
                tabSelection = selection
                tabSelection.reconcile(from: original, to: model)
            } else {
                tabSelection.collapse(in: model)
            }
            endBackgroundCloseReturn()
        }
        if !removingTabs {
            if let next = active {
                activate(next, explicit: false, preserveSelection: true)
            } else {
                window?.nextResponder = NSApp
                window?.makeFirstResponder(nil)
                syncGroups()
                metadataChanged()
            }
            validateToolbar()
        }
    }
    private func removeNonfinalTab(_ id: TabID) {
        guard let p = entries[id], let doc = p.document as? TextDocument,
            let successor =
                ([active].compactMap { $0 } + (recent[doc.runtimeID] ?? []).compactMap { entries[$0] } + presentations)
                .first(where: { $0 !== p && $0.document === doc })
        else { return }
        doc.promoteEditor(from: p, to: successor)
        p.retireTab(inFavorOf: successor.primaryEditor)
        unregister(p, document: doc)
        doc.removeWindowController(p)
    }
    func closeTab(_ id: TabID, sender: Any?) { tabCommands.perform(.close, target: id, captured: true, sender: sender) }
    func performSingleTabClose(_ id: TabID, sender: Any?) {
        guard !isMutatingGroups, window?.attachedSheet == nil,
            let tab = model.groups.flatMap(\.tabs).first(where: { $0.id == id }),
            let presentation = entries[id],
            let document = presentation.document as? TextDocument
        else { return }
        if model.groups.flatMap(\.tabs).filter({ $0.documentID == tab.documentID }).count > 1 {
            tabCommands.recordNonfinalTab(id)
            removeNonfinalTab(id)
            return
        }
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
    @discardableResult func selectTab(_ id: TabID, gesture: TabSelectionGesture) -> Bool {
        guard !isMutatingGroups, !tabCommands.isBusy, window?.attachedSheet == nil else { return false }
        tabCommands.cancelReopen()
        var next = model
        if let group = model.groups.first(where: { $0.tabs.contains { $0.id == id } }) {
            try? next.focusGroup(group.slot, openDocuments: openIDs)
        }
        do { try tabSelection.apply(id, gesture: gesture, workspace: &next, openDocuments: openIDs) } catch {
            return false
        }
        if next.activeTab?.id != model.activeTab?.id || gesture == .plain {
            if let chosen = next.activeTab?.id, let p = presentation(for: chosen) {
                activate(p, preserveSelection: true)
            }
        } else {
            endBackgroundCloseReturn()
            metadataChanged()
        }
        return true
    }
    func restoreTabSelection(_ selection: TabSelectionState, from original: TabWorkspace) {
        tabSelection = selection
        tabSelection.reconcile(from: original, to: model)
        metadataChanged()
    }
    func presentation(for id: TabID) -> EditorWindowController? {
        guard let presentation = entries[id], !presentation.isRetired else { return nil }
        return presentation
    }
    func placeTab(_ id: TabID, in slot: GroupSlot, index: Int, pinned: Bool) {
        guard !isMutatingGroups else { return }
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
            groupSurfaces[group.slot]?.strip.revealOrganizationChange(target)
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
        groupSurfaces[model.groups.first(where: { $0.tabs.contains { $0.id == id } })!.slot]?.strip
            .revealOrganizationChange(id)
        if let group = model.groups.first(where: { $0.tabs.contains { $0.id == id } }),
            let position = group.tabs.firstIndex(where: { $0.id == id }),
            let name = (presentation(for: id)?.document as? TextDocument)?.displayName
        {
            showTabMessage(String(format: "%@, tab %ld of %ld.", name, position + 1, group.tabs.count))
        }
    }
    /// Single-only fixture replacement; group operations require staged runtime plans.
    func replaceTabModel(_ value: TabWorkspace) throws {
        guard !isMutatingGroups, value.layout == .single else { throw TabModelError.invalid }
        try value.validate(openDocuments: openIDs)
        let before = model
        model = value
        tabSelection.reconcile(from: before, to: model)
        metadataChanged()
    }
    private(set) var lastTabMessage = ""
    func showTabMessage(_ message: String) {
        guard !isMutatingGroups else { return }
        lastTabMessage = message
        if let active {
            active.showTransientStatus(message, seconds: 8, announce: true)
        } else {
            if let status = groupSurfaces[model.focusedGroup]?.emptyStatus {
                status.stringValue = message
                ControlPresentation.label(message, control: status)
            }
            Announce.say(message, from: window)
        }
    }
    func restoreTabFocus(_ id: TabID?, responder: NSResponder?) {
        guard !isMutatingGroups else { return }
        if let id, let p = presentation(for: id) {
            activate(p, focus: false, explicit: false)
            if let responder { _ = window?.makeFirstResponder(responder) }
        }
    }
    func commitTabClose(_ plan: TabClosePlan, originalActive: TabID?, originalResponder: NSResponder?) {
        guard !isMutatingGroups else { return }
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
                removeNonfinalTab(id)
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
                _ = window?.makeFirstResponder(p.keyboardFocusView)
            }
        } else {
            syncGroups()
            window?.nextResponder = NSApp
            window?.makeFirstResponder(nil)
        }
        restoreTabSelection(selection, from: before)
        validateToolbar()
    }
    func cycle(_ direction: Int) {
        guard !isMutatingGroups, window?.attachedSheet == nil else { return }
        var next = model
        try? next.cycle(direction, openDocuments: openIDs)
        if let tab = next.activeTab, let presentation = entries[tab.id] { activate(presentation) }
    }
    func metadataChanged() {
        guard !isMutatingGroups else { return }
        if let doc = active?.document as? TextDocument {
            window?.title = doc.displayName
            window?.representedURL = doc.fileURL
            window?.isDocumentEdited = doc.isDocumentEdited
        } else {
            window?.title = "TextTank"
            window?.representedURL = nil
            window?.isDocumentEdited = false
        }
        refreshLayoutPicker()
        groupSurfaces.values.forEach { $0.refresh() }
    }
    /// A tab changed between Source, Preview and Both, or its document gained or lost a preview.
    /// Only the strips are brought up to date; their controls are reused, so focus stays put.
    func tabViewModeChanged() {
        guard !isMutatingGroups else { return }
        // Without scrolling: the tab that was clicked must stay under the pointer.
        groupSurfaces.values.forEach { $0.strip.refresh(revealingActive: false) }
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
