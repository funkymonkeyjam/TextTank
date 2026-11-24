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
        /// A few characters shown at the row's trailing edge: the key equivalent of a command,
        /// or the kind of a Quick Open entry. `accessoryLabel` is what assistive technology
        /// reads for it (DS-70); it defaults to the text itself.
        var accessory: String = ""
        var accessoryLabel: String = ""
    }
    let form: FormPanel
    let filter = NSTextField(string: "")
    let table = ActivatingTableView()
    var rows: () -> [Row] = { [] }
    var filteredRows: ((String) -> [Row])?
    /// Shown as one row that cannot be selected when the filter leaves nothing (DS-36). A panel
    /// without one shows an empty list, as before.
    var emptyMessage: String?
    /// The rows the list shows now, in order. The row that says nothing matched is not one of them.
    var displayedRows: [Row] { displayed }
    var showsEmptyMessage: Bool { displayed.isEmpty && emptyMessage != nil }
    private var announcedEmpty = false
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
    /// Brings a chooser that is already open to the front with whatever was typed selected, so
    /// that typing replaces it and Return still runs the selected row.
    func showAgain() {
        refresh()
        form.window.makeKeyAndOrderFront(nil)
        filter.selectText(nil)
    }
    func refresh() {
        let selected = displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow].id : nil
        let query = filter.stringValue
        displayed = filteredRows?(query) ?? rows().filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        table.rowHeight = displayed.contains { !$0.detail.isEmpty } ? 46 : 30
        table.reloadData()
        // Said once when the list empties, not for every further character typed (DS-36, DS-72).
        if showsEmptyMessage, !announcedEmpty, let emptyMessage, form.window.isVisible {
            Announce.say(emptyMessage, from: form.window)
        }
        announcedEmpty = showsEmptyMessage
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
    func numberOfRows(in tableView: NSTableView) -> Int { showsEmptyMessage ? 1 : displayed.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { displayed.indices.contains(row) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayed.indices.contains(row) else {
            guard row == 0, showsEmptyMessage, let emptyMessage else { return nil }
            let label = NSTextField(labelWithString: emptyMessage)
            label.identifier = NSUserInterfaceItemIdentifier((table.identifier?.rawValue ?? "choice") + ".empty")
            label.textColor = .secondaryLabelColor
            return label
        }
        let value = displayed[row]
        let label = NSTextField(labelWithString: value.title)
        label.identifier = NSUserInterfaceItemIdentifier(value.id)
        label.setAccessibilityLabel(value.title)
        label.toolTip = value.title
        label.lineBreakMode = .byTruncatingTail
        guard !value.detail.isEmpty || !value.accessory.isEmpty else { return label }
        if !value.enabled { label.textColor = .disabledControlTextColor }
        var leading: NSView = label
        if !value.detail.isEmpty {
            let detail = NSTextField(labelWithString: value.detail)
            detail.font = .preferredFont(forTextStyle: .caption1)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            let pair = NSStackView(views: [label, detail])
            pair.orientation = .vertical
            pair.alignment = .leading
            pair.spacing = 1
            pair.toolTip = value.detail
            leading = pair
        }
        guard !value.accessory.isEmpty else { return leading }
        // The name gives way before the short trailing text does (DS-67).
        let accessory = NSTextField(labelWithString: value.accessory)
        accessory.identifier = NSUserInterfaceItemIdentifier(value.id + ".accessory")
        accessory.textColor = value.enabled ? .secondaryLabelColor : .disabledControlTextColor
        accessory.alignment = .right
        accessory.setAccessibilityLabel(value.accessoryLabel.isEmpty ? value.accessory : value.accessoryLabel)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessory.setContentHuggingPriority(.required, for: .horizontal)
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [leading, accessory])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = 12
        line.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        return line
    }
}
