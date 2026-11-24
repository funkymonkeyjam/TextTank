import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor final class WorkspaceBrowserNode {
    let entry: WorkspaceBrowserEntry
    var children: [WorkspaceBrowserNode]?
    init(_ entry: WorkspaceBrowserEntry) { self.entry = entry }
}

/// The docked sidebar's root: a group named "Workspace Browser" (DS-70).
final class WorkspaceSidebarView: NSView {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Return opens the selected row and Escape gives the keyboard back to the text (DS-73).
/// Arrow keys and type-select are the outline view's own.
final class WorkspaceBrowserOutline: NSOutlineView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, [36, 76].contains(event.keyCode), let onReturn {
            onReturn()
        } else if plain, event.keyCode == 53, let onEscape {
            onEscape()
        } else {
            super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class WorkspaceBrowserController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSMenuItemValidation
{
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleMonitor(_:)) { item.state = monitor.document == nil ? .off : .on }
        // DS-22: the View menu item is a toggle and carries the sidebar's state.
        if item.action == #selector(show(_:)) { item.state = isShown ? .on : .off }
        return !CompareCommandScope.blocksWorkspace
    }
    let store: WorkspaceBrowserStore
    let monitor = DocumentMonitor()
    var chooseEncoding: @MainActor (URL, Error) -> FileEncoding? = EncodingChoice.present
    var currentDocument: () -> TextDocument? = { EditorServices.current?.activePresentation?.document as? TextDocument }
    /// The workspace window that docks the browser. There is no other presentation (DS-D9).
    var host: () -> WorkspaceWindowController = { WorkspaceWindowController.current }
    private var builtSidebar: WorkspaceSidebarView?
    /// The browser's one view, built the first time it is shown.
    var sidebarView: WorkspaceSidebarView {
        if let builtSidebar { return builtSidebar }
        let view = buildSidebar()
        builtSidebar = view
        return view
    }
    /// True while this browser is docked in the workspace window.
    var isShown: Bool {
        guard let builtSidebar else { return false }
        let host = host()
        return host.isSidebarShown && host.sidebarSplit.sidebar === builtSidebar
    }
    let outline = WorkspaceBrowserOutline()
    private var keyControls: [NSView] = []
    var firstKeyView: NSView { keyControls.first ?? outline }
    var lastKeyView: NSView { keyControls.last ?? outline }
    let fileChooser = WorkspaceQuickOpen()
    /// Shift-Command-O: free in the menu bar, in Scintilla's key map and in the reserved set.
    /// It is a default that gives way to a shortcut the person assigned to the same key in
    /// Settings, as Toggle Preview's does (DS-25 is not involved: no system shortcut has this key).
    static let quickOpenShortcut = MenuShortcut("O")
    @objc func quickOpen(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        fileChooser.show(
            roots: store.state.folders, documents: quickOpenDocuments(), recent: recentURLs(),
            select: { [weak self] id in
                guard let self, !CompareCommandScope.blocksWorkspace else { return false }
                return try selectOpenDocument(id)
            },
            open: { [weak self] root, file in
                guard let self, !CompareCommandScope.blocksWorkspace else { return false }
                if let root, !store.contains(root) {
                    throw WorkspaceError.invalid(
                        "This workspace folder was removed. Open Quick Open again to refresh the list.")
                }
                return try openOfferingEncoding(file) != nil
            },
            addFolder: { [weak self] in self?.addFolder(nil) })
    }
    /// The open documents Quick Open lists, one row a document, in the order they were opened.
    /// The group is named only when there is more than one to tell apart.
    func quickOpenDocuments() -> [QuickOpenList.OpenDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }.filter(\.isOpen).map { document in
            var group: String?
            if let tab = document.presentation, let id = tab.tabID, tab.host.model.groups.count > 1,
                let slot = tab.host.model.groups.first(where: { $0.tabs.contains { $0.id == id } })?.slot
            {
                group = tab.host.groupLabel(slot)
            }
            return .init(
                id: document.runtimeID.rawValue.uuidString, name: document.displayName, url: document.fileURL,
                group: group)
        }
    }
    /// Shows the tab the open document already has, in whichever group holds it. A document
    /// that closed while Quick Open was showing is reported, never reopened.
    func selectOpenDocument(_ id: String) throws -> Bool {
        guard
            let document = NSDocumentController.shared.documents.compactMap({ $0 as? TextDocument })
                .first(where: { $0.isOpen && $0.runtimeID.rawValue.uuidString == id }),
            let tab = document.presentation
        else { throw FormFailure.documentChanged }
        tab.host.show(tab, sender: nil)
        return true
    }
    private enum Mode: Int { case openDocuments, folders, recentFiles }
    private var selectedMode: Mode { Mode(rawValue: mode.indexOfSelectedItem) ?? .openDocuments }
    /// A pop-up rather than three segments: the titles do not fit a sidebar at its minimum width (DS-67).
    private let mode: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: ["Open Documents", "Folders", "Recent Files"])
        return button
    }()
    private let status = AnnouncingLabel(labelWithString: "")
    /// The monitor reports here, so it never replaces a listing, error or refresh message.
    private let monitorStatus = NSTextField(labelWithString: "")
    var statusText: String { status.stringValue }
    var monitorStatusText: String { monitorStatus.stringValue }
    private var nodes: [WorkspaceBrowserNode] = []
    /// A snapshot the outline view indexes, replaced whenever a document opens or closes
    /// while the sidebar is shown and emptied when it is hidden.
    private var documents: [TextDocument] = []
    /// Paths of expanded folders, so a refresh, which rebuilds every node to re-read the
    /// disk, can expand them again.
    private var expanded = Set<String>()
    private var reloading = false
    private var recent: [URL] = []
    private let recordsSystemRecent: Bool
    init(storeURL: URL? = nil, recordsSystemRecent: Bool = true) {
        self.recordsSystemRecent = recordsSystemRecent
        store = WorkspaceBrowserStore(url: storeURL ?? AppStorage.url(.workspace))
        super.init()
        monitor.onStatus = { [weak self] value in self?.monitorStatus.stringValue = value.message }
        // Explicit document registration/retirement is independent of the shared host window.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)), name: .textTankDocumentsDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func windowWillClose(_ notification: Notification) {
        // The window closes before its document leaves the document list.
        DispatchQueue.main.async { [weak self] in self?.reloadDocuments() }
    }
    @objc private func windowDidBecomeMain(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.reloadDocuments() }
    }
    /// Brings the Open Documents list up to date without touching the status line or the
    /// other two views.
    private func reloadDocuments() {
        guard isShown else { return }
        let current = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
        guard current.count != documents.count || !zip(current, documents).allSatisfy({ $0 === $1 }) else { return }
        let selected = selectedMode == .openDocuments ? outline.item(atRow: outline.selectedRow) as? TextDocument : nil
        documents = current
        guard selectedMode == .openDocuments else { return }
        outline.reloadData()
        if let selected, let row = documents.firstIndex(where: { $0 === selected }) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
    }
    /// Shows one of the three views: 0 Open Documents, 1 Folders, 2 Recent Files.
    func select(mode segment: Int) {
        guard (0..<mode.numberOfItems).contains(segment) else { return }
        mode.selectItem(at: segment)
        refresh(nil)
    }
    /// An error that carries its own recovery, such as the explicit UTF-16 LE open, needs
    /// AppKit's presentation: that is what calls the recovery attempter.
    private func present(_ error: Error) {
        if (error as NSError).recoveryAttempter != nil {
            NSApp.presentError(error)
        } else {
            TTAlert.present(error)
        }
    }
    /// The browser's menu commands. The menu bar places each where a person looks for it:
    /// opening files in File, the browser itself in View (DS-23).
    enum MenuCommand {
        case show, quickOpen, addFolder, monitor, reloadMonitored
    }
    func menuItem(_ command: MenuCommand) -> NSMenuItem {
        let title: String, action: Selector
        switch command {
        case .show: (title, action) = ("Workspace Browser", #selector(show(_:)))
        case .quickOpen: (title, action) = ("Quick Open…", #selector(quickOpen(_:)))
        case .addFolder: (title, action) = ("Add Folder to Workspace…", #selector(addFolder(_:)))
        case .monitor: (title, action) = ("Monitor Current File", #selector(toggleMonitor(_:)))
        case .reloadMonitored: (title, action) = ("Reload Monitored File…", #selector(reloadMonitored(_:)))
        }
        let item =
            command == .quickOpen
            ? DefaultShortcutItem(title, action: action, shortcut: Self.quickOpenShortcut)
            : NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    /// Recently opened files, listed when the submenu opens.
    func recentFilesMenuItem() -> NSMenuItem {
        let recent = NSMenuItem(title: Self.recentFilesTitle, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Recent Files")
        menu.delegate = self
        recent.submenu = menu
        return recent
    }
    static let recentFilesTitle = "Reopen Recent File"
    /// No item in this menu has a key equivalent, so a key press never needs it brought up to date.
    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool { false }
    /// This controller is the delegate of its recent-files submenus only.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in recentURLs() {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
    }
    private func recentURLs() -> [URL] {
        var seen = Set<String>()
        return (store.state.recent + NSDocumentController.shared.recentDocumentURLs).filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }.prefix(100).map { $0 }
    }
    @objc private func toggleMonitor(_ sender: NSMenuItem) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        if monitor.document != nil {
            monitor.stop()
            sender.state = .off
            return
        }
        guard let document = currentDocument() else {
            TTAlert.present(WorkspaceError.invalid("Choose a saved document window before enabling monitoring."))
            return
        }
        do {
            try monitor.start(document)
            sender.state = .on
            reveal()
        } catch { TTAlert.present(error) }
    }
    @objc private func reloadMonitored(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        guard let document = monitor.document else {
            monitorStatus.stringValue = "No document is being monitored."
            return
        }
        guard !document.isDocumentEdited else {
            TTAlert.present(
                WorkspaceError.invalid(
                    "The document has unsaved edits. Use Save As to keep them, or explicitly Revert to Saved; monitoring will not discard them."
                ))
            return
        }
        let revision = document.editor.revision
        let alert = TTAlert()
        alert.messageText = "Reload Monitored File?"
        alert.informativeText =
            "Replace the clean editor contents with the current disk bytes. This clears its Undo history."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try monitor.reload(expectedRevision: revision) } catch { TTAlert.present(error) }
    }
    /// View › Workspace Browser, a toggle (DS-22). Choosing it shows the sidebar and moves the
    /// keyboard to its list; choosing it again hides the sidebar and gives the keyboard back.
    /// The selector keeps its name so the command's identity in the menu map is unchanged.
    @objc func show(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        if isShown { host().setSidebarShown(false, browser: self) } else { reveal(focus: true) }
    }
    /// Shows the sidebar if it is hidden and brings its lists up to date. The keyboard moves
    /// to it only when the person asked for the browser itself.
    @discardableResult func reveal(focus: Bool = false) -> Bool {
        let wasShown = isShown
        guard host().setSidebarShown(true, browser: self, focus: focus) else { return false }
        if wasShown { refresh(nil) }
        if let error = store.loadError {
            status.stringValue =
                "Saved workspace unavailable. Choose Add Folder to review recovery options. "
                + error.localizedDescription
        }
        return true
    }
    func hide() { if isShown { host().setSidebarShown(false, browser: self) } }
    func sidebarDidShow() { refresh(nil) }
    /// Do not keep documents alive behind a hidden sidebar.
    func sidebarDidHide() {
        documents = []
        if selectedMode == .openDocuments { outline.reloadData() }
    }
    private func buildSidebar() -> WorkspaceSidebarView {
        let sidebar = WorkspaceSidebarView()
        sidebar.identifier = .init("workspace.sidebar")
        sidebar.setAccessibilityElement(true)
        sidebar.setAccessibilityRole(.group)
        sidebar.setAccessibilityLabel("Workspace Browser")
        let escape: () -> Void = { [weak self] in self?.host().returnKeyboardFromSidebar() }
        sidebar.onEscape = escape
        let column = NSTableColumn(identifier: .init("Name"))
        column.title = "Documents and Files"
        column.isEditable = false
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.delegate = self
        outline.dataSource = self
        outline.target = self
        outline.doubleAction = #selector(openSelected(_:))
        outline.onReturn = { [weak self] in self?.openSelected(nil) }
        outline.onEscape = escape
        outline.allowsTypeSelect = true
        outline.setAccessibilityLabel("Workspace files")
        // The window's own background: no material, no translucency (DS-11).
        outline.backgroundColor = .clear
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        mode.setAccessibilityLabel("Workspace browser view")
        mode.selectItem(at: Mode.openDocuments.rawValue)
        mode.target = self
        mode.action = #selector(refresh(_:))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        let add = NSButton(title: "Add Folder…", target: self, action: #selector(addFolder(_:)))
        let remove = NSButton(title: "Remove Folder", target: self, action: #selector(removeFolder(_:)))
        let open = NSButton(title: "Open", target: self, action: #selector(openSelected(_:)))
        refresh.setAccessibilityLabel("Refresh workspace browser")
        open.setAccessibilityLabel("Open selected workspace item")
        let opening = NSStackView(views: [open, refresh])
        opening.orientation = .horizontal
        let folders = NSStackView(views: [add, remove])
        folders.orientation = .horizontal
        status.setAccessibilityIdentifier("workspace.status")
        monitorStatus.setAccessibilityIdentifier("workspace.monitorStatus")
        for label in [status, monitorStatus] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        let stack = NSStackView(views: [mode, scroll, opening, folders, status, monitorStatus])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stack)
        // Below required, so a frame that is briefly too small while the window is arranged
        // never breaks the layout; at the sidebar's minimum width everything fits (DS-67).
        let trailing = stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8)
        trailing.priority = .init(999)
        let bottom = stack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8)
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            trailing,
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            bottom,
            mode.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            monitorStatus.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        keyControls = [mode, outline, open, refresh, add, remove]
        for (view, next) in zip(keyControls, keyControls.dropFirst()) { view.nextKeyView = next }
        return sidebar
    }
    @objc func refresh(_ sender: Any?) {
        reloading = true
        documents = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
        recent = recentURLs()
        // Fresh nodes every time: a node caches its listing, so this is what re-reads the disk.
        nodes = store.state.folders.map { WorkspaceBrowserNode(WorkspaceBrowserEntry(url: $0, directory: true)) }
        outline.reloadData()
        if selectedMode == .folders { restoreExpansion() }
        reloading = false
        status.stringValue =
            String(
                format: Strings.text("workspace.counts", "Open documents: %@. Saved folders: %@. Recent files: %@."),
                Strings.number(documents.count), Strings.number(nodes.count), Strings.number(recent.count))
    }
    /// Expands again the folders that were expanded before the nodes were rebuilt, parents
    /// before children. A folder that is gone, or sits under one that is, is forgotten.
    private func restoreExpansion() {
        var live = Set<String>()
        func visit(_ node: WorkspaceBrowserNode) {
            let path = WorkspaceBrowserState.identity(node.entry.url)
            guard node.entry.directory, expanded.contains(path) else { return }
            live.insert(path)
            outline.expandItem(node)
            children(node).forEach(visit)
        }
        nodes.forEach(visit)
        expanded = live
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !reloading, let node = notification.userInfo?["NSObject"] as? WorkspaceBrowserNode else { return }
        expanded.insert(WorkspaceBrowserState.identity(node.entry.url))
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let node = notification.userInfo?["NSObject"] as? WorkspaceBrowserNode else { return }
        expanded.remove(WorkspaceBrowserState.identity(node.entry.url))
    }
    @objc func addFolder(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        do { guard try StoreRecovery.ensureWritable(store.loadState) else { return } } catch {
            TTAlert.present(error)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try addChosenFolder(url) } catch { TTAlert.present(error) }
    }
    /// What every Add Folder route ends with, Quick Open's included: the folder is saved and
    /// the docked sidebar shows it under Folders. The keyboard stays where it was.
    func addChosenFolder(_ url: URL) throws {
        try store.addFolder(url)
        mode.selectItem(at: Mode.folders.rawValue)
        if isShown { refresh(nil) } else { reveal() }
    }
    @objc func removeFolder(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        guard selectedMode == .folders, let node = outline.item(atRow: outline.selectedRow) as? WorkspaceBrowserNode,
            store.contains(node.entry.url)
        else {
            status.stringValue = "Select a saved root folder to remove it from this workspace. Files on disk are kept."
            return
        }
        do {
            try store.removeFolder(node.entry.url)
            refresh(nil)
        } catch { TTAlert.present(error) }
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        guard let url = sender.representedObject as? URL else { return }
        do { _ = try openOfferingEncoding(url) } catch { present(error) }
    }
    @objc func openSelected(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace else { return }
        let index = outline.selectedRow
        guard index >= 0 else { return }
        if selectedMode == .openDocuments {
            guard let document = outline.item(atRow: index) as? TextDocument else { return }
            // A row for a document that has since closed is removed, not shown again.
            guard NSDocumentController.shared.documents.contains(where: { $0 === document }) else {
                reloadDocuments()
                return
            }
            document.showWindows()
            return
        }
        let url: URL
        if selectedMode == .recentFiles {
            guard index < recent.count else { return }
            url = recent[index]
        } else {
            guard let node = outline.item(atRow: index) as? WorkspaceBrowserNode else { return }
            if node.entry.directory {
                outline.expandItem(node)
                return
            }
            url = node.entry.url
        }
        do { _ = try openOfferingEncoding(url) } catch { present(error) }
    }
    /// Row activation and Reopen Recent: a file that cannot be decoded automatically is answered
    /// with the encoding chooser. Returns nil when the person cancels or the file was a session
    /// snapshot handed to its restore prompt. `open(_:)` itself never asks.
    @discardableResult func openOfferingEncoding(_ url: URL) throws -> TextDocument? {
        // A session snapshot goes to its restore prompt here too, never to an editable JSON tab.
        if url.pathExtension.lowercased() == WorkspaceStore.sessionFileExtension,
            let controller = NSDocumentController.shared as? TextDocumentController
        {
            controller.openSessionFile(url)
            return nil
        }
        do { return try open(url) } catch {
            return try EncodingChoice.retry(url, after: error, choose: chooseEncoding) { try open(url, as: $0) }
        }
    }
    /// Read once through a nonblocking regular-file descriptor, then hand the
    /// captured bytes to NSDocument. This avoids a FIFO race between preflight
    /// and a second pathname open. Existing dirty documents are never reloaded.
    @discardableResult func open(_ url: URL, as encoding: FileEncoding? = nil) throws -> TextDocument {
        if let existing = NSDocumentController.shared.document(for: url) as? TextDocument {
            existing.showWindows()
            return existing
        }
        let read = try WorkspaceStore.captureRegularFile(url)
        let document = try DocumentFactory.openCaptured(read, from: url, as: encoding)
        reloadDocuments()
        if recordsSystemRecent { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        do { try store.noteRecent(url) } catch {
            status.stringValue = "Opened file; recent history could not be saved: \(error.localizedDescription)"
        }
        return document
    }
    private func children(_ node: WorkspaceBrowserNode) -> [WorkspaceBrowserNode] {
        if let children = node.children { return children }
        do {
            let listing = try WorkspaceBrowserStore.list(node.entry.url)
            node.children = listing.entries.map(WorkspaceBrowserNode.init)
            if listing.truncated || listing.skipped > 0 {
                status.stringValue = Strings.workspaceSkipped(
                    listing.skipped, truncated: listing.truncated,
                    limit: WorkspaceBrowserStore.defaultListingLimit)
            }
        } catch {
            node.children = []
            status.stringValue = error.localizedDescription
        }
        return node.children ?? []
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if selectedMode == .openDocuments { return item == nil ? documents.count : 0 }
        if selectedMode == .recentFiles { return item == nil ? recent.count : 0 }
        guard let node = item as? WorkspaceBrowserNode else { return nodes.count }
        return node.entry.directory ? children(node).count : 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if selectedMode == .openDocuments { return documents[index] }
        if selectedMode == .recentFiles { return recent[index] as NSURL }
        return (item as? WorkspaceBrowserNode).map { children($0)[index] } ?? nodes[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? WorkspaceBrowserNode)?.entry.directory ?? false
    }
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?)
        -> Any?
    {
        if let document = item as? TextDocument {
            return (document.isDocumentEdited ? "● " : "") + document.displayName
        }
        if let node = item as? WorkspaceBrowserNode { return node.entry.url.lastPathComponent }
        return (item as? NSURL)?.lastPathComponent
    }
}
