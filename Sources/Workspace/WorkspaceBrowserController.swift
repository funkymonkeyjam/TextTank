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
    var chooseEncoding: (URL, Error) -> FileEncoding? = EncodingChoice.present
    var currentDocument: () -> TextDocument? = { NSApp.mainWindow?.windowController?.document as? TextDocument }
    private(set) var window: NSPanel?
    let outline = NSOutlineView()
    private let mode = NSSegmentedControl(
        labels: ["Open Documents", "Folders", "Recent Files"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = AnnouncingLabel(labelWithString: "")
    /// The monitor reports here, so it never replaces a listing, error or refresh message.
    private let monitorStatus = NSTextField(labelWithString: "")
    var statusText: String { status.stringValue }
    var monitorStatusText: String { monitorStatus.stringValue }
    private var nodes: [WorkspaceBrowserNode] = []
    /// A snapshot the outline view indexes, replaced whenever a document window opens or
    /// closes while the panel is visible and emptied when the panel closes.
    private var documents: [TextDocument] = []
    /// Paths of expanded folders, so a refresh, which rebuilds every node to re-read the
    /// disk, can expand them again.
    private var expanded = Set<String>()
    private var reloading = false
    private var recent: [URL] = []
    private var rootMenu: NSMenu?
    private let recordsSystemRecent: Bool
    init(storeURL: URL? = nil, recordsSystemRecent: Bool = true) {
        self.recordsSystemRecent = recordsSystemRecent
        store = WorkspaceBrowserStore(url: storeURL ?? AppStorage.url(.workspace))
        super.init()
        monitor.onStatus = { [weak self] value in self?.monitorStatus.stringValue = value.message }
        // AppKit has no notification for a document joining or leaving the document list.
        // Its window closing or becoming main is the signal.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            // The panel outlives its window (isReleasedWhenClosed is false); do not keep
            // documents alive behind a closed panel.
            documents = []
            if mode.selectedSegment == 0 { outline.reloadData() }
            return
        }
        // The window closes before its document leaves the document list.
        DispatchQueue.main.async { [weak self] in self?.reloadDocuments() }
    }
    @objc private func windowDidBecomeMain(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.reloadDocuments() }
    }
    /// Brings the Open Documents list up to date without touching the status line or the
    /// other two views.
    private func reloadDocuments() {
        guard window?.isVisible == true else { return }
        let current = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
        guard current.count != documents.count || !zip(current, documents).allSatisfy({ $0 === $1 }) else { return }
        let selected = mode.selectedSegment == 0 ? outline.item(atRow: outline.selectedRow) as? TextDocument : nil
        documents = current
        guard mode.selectedSegment == 0 else { return }
        outline.reloadData()
        if let selected, let row = documents.firstIndex(where: { $0 === selected }) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
    }
    /// Shows one of the three views: 0 Open Documents, 1 Folders, 2 Recent Files.
    func select(mode segment: Int) {
        guard (0..<mode.segmentCount).contains(segment) else { return }
        mode.selectedSegment = segment
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
            TTAlert.present(WorkspaceError.invalid("Choose a saved document window before enabling monitoring."))
            return
        }
        do {
            try monitor.start(document)
            sender.state = .on
            show(nil)
        } catch { TTAlert.present(error) }
    }
    @objc private func reloadMonitored(_ sender: Any?) {
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
    @objc func show(_ sender: Any?) {
        if window == nil { buildWindow() }
        refresh(nil)
        window?.makeKeyAndOrderFront(nil)
        if let error = store.loadError {
            status.stringValue =
                "Saved workspace unavailable. Choose Add Folder to review recovery options. "
                + error.localizedDescription
        }
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
        status.setAccessibilityIdentifier("workspace.status")
        monitorStatus.setAccessibilityIdentifier("workspace.monitorStatus")
        for label in [status, monitorStatus] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [controls, scroll, actions, status, monitorStatus])
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
        WindowFrames.track(panel, as: "TextTank.Workspace")
        window = panel
    }
    @objc func refresh(_ sender: Any?) {
        reloading = true
        documents = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
        recent = recentURLs()
        // Fresh nodes every time: a node caches its listing, so this is what re-reads the disk.
        nodes = store.state.folders.map { WorkspaceBrowserNode(WorkspaceBrowserEntry(url: $0, directory: true)) }
        outline.reloadData()
        if mode.selectedSegment == 1 { restoreExpansion() }
        reloading = false
        status.stringValue =
            "\(documents.count) open documents · \(nodes.count) saved folders · \(recent.count) recent files"
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
        do { guard try StoreRecovery.ensureWritable(store.loadState) else { return } } catch {
            TTAlert.present(error)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.addFolder(url)
            mode.selectedSegment = 1
            show(nil)
        } catch { TTAlert.present(error) }
    }
    @objc func removeFolder(_ sender: Any?) {
        guard mode.selectedSegment == 1, let node = outline.item(atRow: outline.selectedRow) as? WorkspaceBrowserNode,
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
        guard let url = sender.representedObject as? URL else { return }
        do { _ = try openOfferingEncoding(url) } catch { present(error) }
    }
    @objc func openSelected(_ sender: Any?) {
        let index = outline.selectedRow
        guard index >= 0 else { return }
        if mode.selectedSegment == 0 {
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
        let (data, sample) = try WorkspaceStore.readRegularFileSample(url)
        let document = TextDocument()
        document.fileURL = url
        try document.read(
            captured: data, sample: sample, from: url, ofType: TextDocument.plainTextType, as: encoding)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
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
