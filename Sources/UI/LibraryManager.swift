// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Presentation only. Controllers own the typed working copy, validation and persistence.
final class LibraryManager: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct Row { let id: UUID, name: String }
    let form: FormPanel
    let table = NSTableView()
    private let actionBar = NSStackView()
    private var actionTargets: [ClosureAction] = []
    private var selectionButtons: [NSButton] = []
    private var allButtons: [NSButton] = []
    private var saveButton: NSButton!
    var rows: () -> [Row] = { [] }
    var canEdit: () -> Bool = { true }
    var rename: (UUID, String) -> Void = { _, _ in }
    var save: () throws -> Bool = { true }
    var add: () -> Void = {}
    var onClose: (() -> Void)?
    private var controllerOwner: AnyObject?
    func retainController(_ owner: AnyObject) { controllerOwner = owner }
    private var sheetObserver: NSObjectProtocol?
    var onSelection: ((UUID?) -> Void)?
    var selectedID: UUID? {
        let values = rows()
        return values.indices.contains(table.selectedRow) ? values[table.selectedRow].id : nil
    }
    init(title: String, identifier: String) {
        form = FormPanel(title: title, identifier: identifier, size: NSSize(width: 760, height: 480))
        super.init()
        form.window.contentMinSize = NSSize(width: 650, height: 360)
        form.retainPresentationOwner(self)
        form.onClose = { [weak self] in self?.retire() }
        form.note(
            "Changes are kept in this window until you choose Save. Cancel leaves the saved library unchanged. Double-click a name to rename it."
        )
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Name"
        column.width = 650
        column.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(title)
        table.identifier = NSUserInterfaceItemIdentifier(identifier + ".list")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        form.add(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        actionBar.orientation = .horizontal
        actionBar.spacing = 8
        form.add(actionBar)
        saveButton = form.button("Save", identifier: identifier + ".save") { [weak self] in
            guard let self, self.form.commitEditing() else { return }
            do {
                guard self.canEdit() else { throw FormFailure.busy }
                if try self.save() { self.form.close() } else { self.refresh() }
            } catch { self.form.showValidation(error, field: self.selectedNameField()) }
        }
        sheetObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: form.window, queue: .main
        ) { [weak self] _ in self?.refresh() }
        saveButton.keyEquivalent = "\r"
        form.button("Cancel", identifier: identifier + ".cancel", cancel: true) { [weak self] in self?.form.close() }
    }
    private func retire() {
        let callback = onClose
        onClose = nil
        for button in allButtons {
            button.target = nil
            button.action = nil
        }
        allButtons.removeAll()
        selectionButtons.removeAll()
        actionTargets.removeAll()
        save = { true }
        add = {}
        rows = { [] }
        rename = { _, _ in }
        onSelection = nil
        callback?()
        controllerOwner = nil
    }
    deinit { if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) } }
    @discardableResult func action(
        _ title: String, identifier: String, needsSelection: Bool = false, _ body: @escaping () -> Void
    ) -> NSButton {
        let target = ClosureAction { [weak self] in
            guard let self, self.canEdit(), !needsSelection || self.selectedID != nil else { return }
            guard self.form.commitEditing() else { return }
            body()
            self.refresh()
        }
        let button = NSButton(title: title, target: target, action: #selector(ClosureAction.invoke(_:)))
        button.bezelStyle = .rounded
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityLabel(Strings.formAction(title, scope: form.window.title))
        button.cell?.setAccessibilityLabel(Strings.formAction(title, scope: form.window.title))
        actionTargets.append(target)
        allButtons.append(button)
        if needsSelection { selectionButtons.append(button) }
        actionBar.addArrangedSubview(button)
        return button
    }
    @discardableResult func secondaryAction(_ title: String, identifier: String, _ action: @escaping () -> Void)
        -> NSButton
    {
        let button = form.button(title, identifier: identifier) { [weak self] in
            guard let self, self.canEdit(), self.form.window.attachedSheet == nil, self.form.commitEditing() else {
                return
            }
            action()
            self.refresh()
        }
        allButtons.append(button)
        return button
    }
    func show() {
        reload()
        form.show()
    }
    func saveChanges() { saveButton.performClick(nil) }
    func beginAdd() {
        if let sheet = form.window.attachedSheet {
            sheet.makeKeyAndOrderFront(nil)
            return
        }
        guard canEdit(), form.commitEditing() else { return }
        add()
        refresh()
    }
    func reload(select id: UUID? = nil) {
        let selected = id ?? selectedID
        table.reloadData()
        if let index = rows().firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if !rows().isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        refresh()
        onSelection?(selectedID)
    }
    func refresh() {
        let enabled = canEdit() && form.window.attachedSheet == nil
        saveButton?.isEnabled = enabled
        for button in allButtons { button.isEnabled = enabled }
        for button in selectionButtons { button.isEnabled = enabled && selectedID != nil }
    }
    func selectedNameField() -> NSView? {
        guard table.selectedRow >= 0 else { return table }
        return table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) ?? table
    }
    func reveal(_ id: UUID) {
        guard let index = rows().firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
    func confirmDelete(_ apply: @escaping (UUID) -> Void) {
        guard let id = selectedID, let row = rows().first(where: { $0.id == id }) else { return }
        let confirm = TTAlert()
        confirm.messageText = "Delete “\(row.name)” from this library?"
        confirm.informativeText =
            "The saved library changes only when you choose Save. Documents and external outputs are unchanged."
        confirm.addButton(withTitle: "Cancel", role: .cancel)
        confirm.addButton(withTitle: "Delete").hasDestructiveAction = true
        confirm.beginSheetModal(for: form.window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, self.canEdit() else { return }
            apply(id)
            self.reload()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows().count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let values = rows()
        guard values.indices.contains(row) else { return nil }
        let value = values[row]
        let field = NSTextField(string: value.name)
        field.isBezeled = false
        field.drawsBackground = false
        field.toolTip = value.name
        field.delegate = self
        field.identifier = NSUserInterfaceItemIdentifier(value.id.uuidString)
        ControlPresentation.label(Strings.formAction("Rename", scope: value.name), control: field)
        return field
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
            let text = field.identifier?.rawValue, let id = UUID(uuidString: text)
        else { return }
        rename(id, field.stringValue)
        ControlPresentation.label(Strings.formAction("Rename", scope: field.stringValue), control: field)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        refresh()
        onSelection?(selectedID)
    }
}

final class ClosureAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}
