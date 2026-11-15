// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class WorkspaceBrowserNode {
    let entry: WorkspaceBrowserEntry
    var children: [WorkspaceBrowserNode]?
    init(_ entry: WorkspaceBrowserEntry) { self.entry = entry }
}

final class WorkspaceBrowserController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let store: WorkspaceBrowserStore
    let monitor = DocumentMonitor()
    var currentDocument: () -> TextDocument? = { NSApp.mainWindow?.windowController?.document as? TextDocument }
    private(set) var window: NSPanel?
    private let outline = NSOutlineView()
    private let mode = NSSegmentedControl(
        labels: ["Open Documents", "Folders", "Recent Files"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var nodes: [WorkspaceBrowserNode] = []
    private var documents: [TextDocument] = []
    private var recent: [URL] = []
    private var rootMenu: NSMenu?
    private let recordsSystemRecent: Bool
    init(storeURL: URL? = nil, recordsSystemRecent: Bool = true) {
        self.recordsSystemRecent = recordsSystemRecent
        let support =
            ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextTank")
        store = WorkspaceBrowserStore(url: storeURL ?? support.appendingPathComponent("WorkspaceBrowser.json"))
        super.init()
        monitor.onStatus = { [weak self] value in self?.status.stringValue = value.message }
    }
    func menu() -> NSMenu {
        let menu = NSMenu(title: "Workspace")
        menu.delegate = self
        rootMenu = menu
        let show = NSMenuItem(title: "Show Workspace Browser", action: #selector(show(_:)), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let add = NSMenuItem(title: "Add Folder to Workspace…", action: #selector(addFolder(_:)), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let monitor = NSMenuItem(title: "Monitor Current File", action: #selector(toggleMonitor(_:)), keyEquivalent: "")
        monitor.target = self
        menu.addItem(monitor)
        let reload = NSMenuItem(
            title: "Reload Monitored File…", action: #selector(reloadMonitored(_:)), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        menu.addItem(.separator())
        let recent = NSMenuItem(title: "Reopen Recent File", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Recent Files")
        menu.addItem(recent)
        return menu
    }
    /// No item in this menu has a key equivalent, so a key press never needs it brought up to date.
    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool { false }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === rootMenu, let submenu = menu.items.last?.submenu else { return }
        menu.items.first { $0.action == #selector(toggleMonitor(_:)) }?.state = monitor.document == nil ? .off : .on
        submenu.removeAllItems()
        for url in recentURLs() {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            submenu.addItem(item)
        }
    }
    private func recentURLs() -> [URL] {
        var seen = Set<String>()
        return (store.state.recent + NSDocumentController.shared.recentDocumentURLs).filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }.prefix(100).map { $0 }
    }
    @objc private func toggleMonitor(_ sender: NSMenuItem) {
        if monitor.document != nil {
            monitor.stop()
            sender.state = .off
            return
        }
        guard let document = currentDocument() else {
            NSAlert(error: WorkspaceError.invalid("Choose a saved document window before enabling monitoring."))
                .runModal()
            return
        }
        do {
            try monitor.start(document)
            sender.state = .on
            show(nil)
        } catch { NSAlert(error: error).runModal() }
    }
    @objc private func reloadMonitored(_ sender: Any?) {
        guard let document = monitor.document else {
            status.stringValue = "No document is being monitored."
            return
        }
        guard !document.isDocumentEdited else {
            NSAlert(
                error: WorkspaceError.invalid(
                    "The document has unsaved edits. Use Save As to keep them, or explicitly Revert to Saved; monitoring will not discard them."
                )
            ).runModal()
            return
        }
        let revision = document.editor.revision
        let alert = TTAlert()
        alert.messageText = "Reload Monitored File?"
        alert.informativeText =
            "Replace the clean editor contents with the current disk bytes. This clears its Undo history."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try monitor.reload(expectedRevision: revision) } catch { NSAlert(error: error).runModal() }
    }
    @objc func show(_ sender: Any?) {
        if window == nil { buildWindow() }
        refresh(nil)
        window?.makeKeyAndOrderFront(nil)
        if let error = store.loadError { status.stringValue = error.localizedDescription }
    }
    private func buildWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Workspace"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 450, height: 300)
        let column = NSTableColumn(identifier: .init("Name"))
        column.title = "Documents and Files"
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.delegate = self
        outline.dataSource = self
        outline.target = self
        outline.doubleAction = #selector(openSelected(_:))
        outline.setAccessibilityLabel("Workspace files")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(refresh(_:))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refresh(_:)))
        let add = NSButton(title: "Add Folder…", target: self, action: #selector(addFolder(_:)))
        let remove = NSButton(title: "Remove Folder", target: self, action: #selector(removeFolder(_:)))
        let open = NSButton(title: "Open", target: self, action: #selector(openSelected(_:)))
        let controls = NSStackView(views: [mode, refresh])
        controls.orientation = .horizontal
        let actions = NSStackView(views: [add, remove, open])
        actions.orientation = .horizontal
        let stack = NSStackView(views: [controls, scroll, actions, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        panel.center()
        window = panel
    }
    @objc func refresh(_ sender: Any?) {
        documents = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
        recent = recentURLs()
        nodes = store.state.folders.map { WorkspaceBrowserNode(WorkspaceBrowserEntry(url: $0, directory: true)) }
        outline.reloadData()
        status.stringValue =
            "\(documents.count) open documents · \(nodes.count) saved folders · \(recent.count) recent files"
    }
    @objc func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.addFolder(url)
            mode.selectedSegment = 1
            show(nil)
        } catch { NSAlert(error: error).runModal() }
    }
    @objc func removeFolder(_ sender: Any?) {
        guard mode.selectedSegment == 1, let node = outline.item(atRow: outline.selectedRow) as? WorkspaceBrowserNode,
            store.state.folders.contains(node.entry.url)
        else {
            status.stringValue = "Select a saved root folder to remove it from this workspace. Files on disk are kept."
            return
        }
        do {
            try store.removeFolder(node.entry.url)
            refresh(nil)
        } catch { NSAlert(error: error).runModal() }
    }
    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do { _ = try open(url) } catch { NSAlert(error: error).runModal() }
    }
    @objc func openSelected(_ sender: Any?) {
        let index = outline.selectedRow
        guard index >= 0 else { return }
        if mode.selectedSegment == 0 {
            guard index < documents.count else { return }
            documents[index].showWindows()
            return
        }
        let url: URL
        if mode.selectedSegment == 2 {
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
        do { _ = try open(url) } catch { NSAlert(error: error).runModal() }
    }
    /// Read once through a nonblocking regular-file descriptor, then hand the
    /// captured bytes to NSDocument. This avoids a FIFO race between preflight
    /// and a second pathname open. Existing dirty documents are never reloaded.
    @discardableResult func open(_ url: URL) throws -> TextDocument {
        if let existing = NSDocumentController.shared.document(for: url) as? TextDocument {
            existing.showWindows()
            return existing
        }
        let data = try WorkspaceStore.readRegularFile(url)
        let document = TextDocument()
        document.fileURL = url
        try document.read(from: data, ofType: "public.plain-text")
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
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
                status.stringValue =
                    "\(listing.skipped) hidden, symbolic-link or special entries skipped"
                    + (listing.truncated ? " · 2,000-entry listing limit reached" : "")
            }
        } catch {
            node.children = []
            status.stringValue = error.localizedDescription
        }
        return node.children ?? []
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if mode.selectedSegment == 0 { return item == nil ? documents.count : 0 }
        if mode.selectedSegment == 2 { return item == nil ? recent.count : 0 }
        guard let node = item as? WorkspaceBrowserNode else { return nodes.count }
        return node.entry.directory ? children(node).count : 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if mode.selectedSegment == 0 { return documents[index] }
        if mode.selectedSegment == 2 { return recent[index] as NSURL }
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
