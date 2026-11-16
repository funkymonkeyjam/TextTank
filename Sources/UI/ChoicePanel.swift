import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A filtered, keyboard-operable chooser. Row identity is independent of its displayed name.
@MainActor final class ChoicePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Row { let id: String, title: String }
    let form: FormPanel
    let filter = NSTextField(string: "")
    let table = ActivatingTableView()
    var rows: () -> [Row] = { [] }
    var onClose: (() -> Void)?
    private var controllerOwner: AnyObject?
    func retainController(_ owner: AnyObject) { controllerOwner = owner }
    private func retire() {
        let callback = onClose
        onClose = nil
        rows = { [] }
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
    func show() {
        refresh()
        form.show()
    }
    func refresh() {
        let selected = displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow].id : nil
        let query = filter.stringValue
        displayed = rows().filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let index = displayed.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !displayed.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateChoice()
    }
    private func updateChoice() {
        chooseButton?.isEnabled = canChoose() && displayed.indices.contains(table.selectedRow)
    }
    @objc private func activate() {
        guard !activating, form.acceptsActions else { return }
        activating = true
        defer { activating = false }
        guard form.commitEditing(), canChoose(), displayed.indices.contains(table.selectedRow) else { return }
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
        return label
    }
}
