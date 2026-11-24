import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A filtered, keyboard-operable chooser. Row identity is independent of its displayed name.
@MainActor final class ChoicePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Row {
        let id: String, title: String
        var detail: String = ""
        var enabled = true
        /// The command's key as the menu bar shows it, drawn at the trailing edge. Empty for none.
        var shortcut: String = ""
    }
    let form: FormPanel
    let filter = NSTextField(string: "")
    let table = ActivatingTableView()
    var rows: () -> [Row] = { [] }
    var filteredRows: ((String) -> [Row])?
    var onClose: (() -> Void)?
    private var controllerOwner: AnyObject?
    func retainController(_ owner: AnyObject) { controllerOwner = owner }
    private func retire() {
        let callback = onClose
        onClose = nil
        rows = { [] }
        filteredRows = nil
        choose = { _ in false }
        canChoose = { false }
        callback?()
        controllerOwner = nil
    }
    var canChoose: () -> Bool = { true }
    var choose: (String) throws -> Bool = { _ in true }
    var selectedID: String? { displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow].id : nil }
    private var displayed: [Row] = []
    private var activating = false
    private var chooseButton: NSButton!
    init(title: String, identifier: String, action: String, filterLabel: String) {
        form = FormPanel(title: title, identifier: identifier, size: NSSize(width: 620, height: 420))
        super.init()
        form.retainPresentationOwner(self)
        form.onClose = { [weak self] in self?.retire() }
        filter.placeholderString = filterLabel
        ControlPresentation.label(filterLabel, control: filter)
        filter.identifier = NSUserInterfaceItemIdentifier(identifier + ".filter")
        filter.delegate = self
        form.add(filter)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 560
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier(identifier + ".list")
        table.setAccessibilityLabel(title)
        table.target = self
        table.doubleAction = #selector(activate)
        table.onActivate = { [weak self] _ in self?.activate() }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        form.add(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        chooseButton = form.button(action, identifier: identifier + ".choose") { [weak self] in self?.activate() }
        chooseButton.keyEquivalent = "\r"
        form.button("Cancel", identifier: identifier + ".cancel", cancel: true) { [weak self] in self?.form.close() }
        form.window.initialFirstResponder = filter
    }
    func show(parent: NSWindow? = nil) {
        refresh()
        form.show(parent: parent)
    }
    func refresh() {
        let selected = displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow].id : nil
        let query = filter.stringValue
        displayed = filteredRows?(query) ?? rows().filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        table.rowHeight = displayed.contains { !$0.detail.isEmpty } ? 46 : 30
        table.reloadData()
        if let index = displayed.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !displayed.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateChoice()
    }
    private func updateChoice() {
        chooseButton?.isEnabled = canChoose() && displayed.indices.contains(table.selectedRow) && displayed[table.selectedRow].enabled
    }
    @objc private func activate() {
        guard !activating, form.acceptsActions else { return }
        activating = true
        defer { activating = false }
        guard form.commitEditing(), canChoose(), displayed.indices.contains(table.selectedRow), displayed[table.selectedRow].enabled else { return }
        do { if try choose(displayed[table.selectedRow].id) { form.close() } } catch {
            form.showValidation(error, field: filter)
        }
    }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        activate()
        return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateChoice() }
    func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayed.indices.contains(row) else { return nil }
        let value = displayed[row]
        let label = NSTextField(labelWithString: value.title)
        label.identifier = NSUserInterfaceItemIdentifier(value.id)
        label.setAccessibilityLabel(value.title)
        label.toolTip = value.title
        guard !value.detail.isEmpty else { return withShortcut(label, value) }
        if !value.enabled { label.textColor = .disabledControlTextColor }
        let detail = NSTextField(labelWithString: value.detail)
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = .secondaryLabelColor
        let pair = NSStackView(views: [label, detail])
        pair.orientation = .vertical
        pair.alignment = .leading
        pair.spacing = 1
        pair.toolTip = value.detail
        return withShortcut(pair, value)
    }
    /// Puts the row's shortcut, when it has one, at the trailing edge in the menu bar's form.
    private func withShortcut(_ view: NSView, _ value: Row) -> NSView {
        guard !value.shortcut.isEmpty else { return view }
        let key = NSTextField(labelWithString: value.shortcut)
        key.textColor = .secondaryLabelColor
        key.identifier = NSUserInterfaceItemIdentifier(value.id + ".shortcut")
        key.setContentHuggingPriority(.required, for: .horizontal)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [view, space, key])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }
}
