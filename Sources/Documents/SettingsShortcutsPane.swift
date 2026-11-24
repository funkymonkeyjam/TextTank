// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

/// A button that records the next key press as a shortcut. Click it, or press Return on a
/// command in the list, then press the keys. Escape keeps the current shortcut.
///
/// While it records, a local event monitor sees every key first, so Command-Q or Escape reach
/// neither the menu bar nor the window's Close button. The same presses delivered straight to
/// the control (`performKeyEquivalent`, `keyDown`) are handled the same way.
final class ShortcutRecorder: NSButton {
    var onRecord: ((MenuShortcut) -> Void)?
    var onCancel: (() -> Void)?
    /// What the button says when it is not recording: the command's shortcut, or an invitation.
    var idleTitle = "" { didSet { if !isRecording { title = idleTitle } } }
    private(set) var isRecording = false
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { isEnabled }
    func beginRecording() {
        guard isEnabled, !isRecording, let window, window.makeFirstResponder(self) else { return }
        isRecording = true
        title = "Type the Shortcut"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording, event.window === self.window else { return event }
            return self.capture(event) ? nil : event
        }
    }
    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        title = idleTitle
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    /// Takes one key press while recording. False means the press is not for the recorder.
    @discardableResult func capture(_ event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty, event.keyCode == 53 {
            endRecording()
            onCancel?()
            return true
        }
        // Tab and Shift-Tab leave the control, as they leave any other (DS-73).
        if flags.subtracting(.shift).isEmpty, event.keyCode == 48 {
            endRecording()
            onCancel?()
            return false
        }
        guard let shortcut = MenuShortcut(event) else { return true }
        endRecording()
        onRecord?(shortcut)
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isRecording, window?.firstResponder === self { return capture(event) }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !capture(event) { super.keyDown(with: event) }
    }
    override func resignFirstResponder() -> Bool {
        if isRecording {
            endRecording()
            onCancel?()
        }
        return super.resignFirstResponder()
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// The Shortcuts pane: every command of the menu bar with its key, a search field, a key
/// recorder, and the answer to a key that is already in use. No chords, no conditions.
@MainActor final class ShortcutsPane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Row {
        let id: String, title: String
        let kind: ShortcutCatalog.Entry.Kind
        let standard: MenuShortcut?
        /// The key the command has now.
        var shortcut: MenuShortcut?
        var isCustom = false
        /// Another listed command with the same key, when there is one.
        var sameKeyAs: String?
        var isAssignable: Bool {
            if case .assignable = kind { return true }
            return false
        }
        var status: String {
            var words: String
            switch kind {
            case .system: words = "System"
            case .fixed: words = "Fixed"
            case .assignable:
                if isCustom {
                    words = shortcut == nil ? "Custom: none" : "Custom"
                } else if shortcut == nil, standard != nil {
                    words = "Default, given up"
                } else {
                    words = shortcut == nil ? "None" : "Default"
                }
            }
            if let sameKeyAs { words += " · Same key as “\(sameKeyAs)”" }
            return words
        }
    }
    let view = NSStackView()
    let search = NSSearchField()
    let table = ActivatingTableView()
    let selection = NSTextField(labelWithString: "")
    let recorder = ShortcutRecorder(title: "", target: nil, action: nil)
    let useDefault = NSButton(title: "Use Default", target: nil, action: nil)
    let clear = NSButton(title: "Clear Shortcut", target: nil, action: nil)
    let resetAll = NSButton(title: "Reset All Shortcuts…", target: nil, action: nil)
    /// Results and reasons; each new one is announced (DS-72).
    let message = AnnouncingLabel(wrappingLabelWithString: "")
    /// Why the selected command's shortcut cannot be changed here. It is read with the
    /// selection, so it is not announced again each time the selection moves.
    let note = NSTextField(wrappingLabelWithString: "")
    let replace = NSButton(title: "Replace", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    /// Lists only commands whose shortcut was changed: the Settings window's Changed from default.
    var changedOnly = false { didSet { if changedOnly != oldValue { reload() } } }
    private let settings: () -> EditorSettings
    private let write: ((inout EditorSettings) throws -> Void) throws -> Void
    private let confirmResetAll: () -> Void
    private let layoutChanged: () -> Void
    private var context = ShortcutContext(reservedKeys: [])
    private var all: [Row] = []
    private(set) var rows: [Row] = []
    /// A recorded key that another command holds, waiting for Replace or Cancel.
    private var pending: (id: String, shortcut: MenuShortcut?, holders: [String])?
    /// True while the list is being read again; the selection it restores is not a new choice.
    private var reloading = false

    init(
        width: CGFloat, settings: @escaping () -> EditorSettings,
        write: @escaping ((inout EditorSettings) throws -> Void) throws -> Void,
        confirmResetAll: @escaping () -> Void, layoutChanged: @escaping () -> Void
    ) {
        self.settings = settings
        self.write = write
        self.confirmResetAll = confirmResetAll
        self.layoutChanged = layoutChanged
        super.init()
        search.placeholderString = "Search commands"
        search.identifier = .init("settings.shortcuts.search")
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.delegate = self
        ControlPresentation.label("Search commands by name, menu or shortcut", control: search)

        for (id, title, width) in [
            ("command", "Command", width - 290), ("shortcut", "Shortcut", 100), ("status", "Status", 150)
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.resizingMask = id == "command" ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.identifier = .init("settings.shortcuts.list")
        table.setAccessibilityLabel("Commands and their shortcuts")
        table.target = self
        table.doubleAction = #selector(recordSelected(_:))
        table.onActivate = { [weak self] _ in self?.recordSelected(nil) }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true

        selection.lineBreakMode = .byTruncatingMiddle
        selection.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selection.identifier = .init("settings.shortcuts.selection")
        recorder.bezelStyle = .rounded
        recorder.identifier = .init("settings.shortcuts.recorder")
        recorder.target = self
        recorder.action = #selector(recordSelected(_:))
        recorder.onRecord = { [weak self] in self?.record($0) }
        recorder.onCancel = { [weak self] in self?.say("The shortcut was not changed.") }
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        for (button, id, action, label) in [
            (
                useDefault, "settings.shortcuts.default", #selector(useDefaultShortcut(_:)),
                "Use the default shortcut for the selected command"
            ),
            (
                clear, "settings.shortcuts.clear", #selector(clearShortcut(_:)),
                "Leave the selected command without a shortcut"
            ),
            (
                resetAll, "settings.shortcuts.resetAll", #selector(resetAllShortcuts(_:)),
                "Reset all shortcuts to their defaults"
            ),
            (
                replace, "settings.shortcuts.replace", #selector(replacePending(_:)),
                "Replace: give the key to the selected command"
            ),
            (
                cancel, "settings.shortcuts.cancel", #selector(cancelPending(_:)),
                "Cancel: keep both shortcuts as they are"
            )
        ] {
            button.bezelStyle = .rounded
            button.identifier = .init(id)
            button.target = self
            button.action = action
            ControlPresentation.label(label, control: button)
        }
        // The other command loses its key, and Undo does not bring that back (DS-41).
        replace.hasDestructiveAction = true
        replace.isHidden = true
        cancel.isHidden = true
        message.preferredMaxLayoutWidth = width
        message.identifier = .init("settings.shortcuts.message")
        message.textColor = .labelColor
        message.isHidden = true
        note.preferredMaxLayoutWidth = width
        note.identifier = .init("settings.shortcuts.note")
        note.textColor = .secondaryLabelColor
        note.isHidden = true

        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .horizontal)
        let detail = NSStackView(views: [selection, space, recorder, useDefault, clear])
        detail.spacing = 8
        let answerSpace = NSView()
        answerSpace.setContentHuggingPriority(.init(1), for: .horizontal)
        let answers = NSStackView(views: [replace, cancel, answerSpace, resetAll])
        answers.spacing = 8
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        for part in [search, scroll, detail, note, message, answers] as [NSView] {
            view.addArrangedSubview(part)
            part.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        reload()
    }

    // MARK: The list

    /// Reads the menu bar and the saved shortcuts again, keeping the selected command.
    func reload() {
        let selected = selectedRow?.id
        let saved = settings()
        var listed: [Row]
        if let bar = NSApp?.mainMenu {
            let catalog = ShortcutCatalog.catalog(in: bar)
            context = catalog.context
            listed = catalog.entries.map { entry in
                var row = Row(id: entry.id, title: entry.title, kind: entry.kind, standard: entry.standard)
                if row.isAssignable {
                    row.shortcut = saved.effectiveShortcut(for: entry.id, in: catalog.context)
                    row.isCustom = saved.hasShortcutOverride(for: entry.id)
                } else {
                    row.shortcut = MenuShortcut(entry.item)
                }
                return row
            }
        } else {
            // No menu bar yet: the editor commands version 1 knew, so the pane is never empty.
            context = ShortcutContext(reservedKeys: EditorSettings.protectedShortcuts)
            listed = context.commands.sorted { $0.value.title < $1.value.title }.map { id, command in
                var row = Row(
                    id: id, title: command.title, kind: .assignable(yields: command.yields), standard: command.standard)
                row.shortcut = saved.effectiveShortcut(for: id, in: context)
                row.isCustom = saved.hasShortcutOverride(for: id)
                return row
            }
        }
        var users: [String: [Int]] = [:]
        for (index, row) in listed.enumerated() {
            if let shortcut = row.shortcut { users[shortcut.identity, default: []].append(index) }
        }
        for indexes in users.values where indexes.count > 1 {
            for index in indexes {
                listed[index].sameKeyAs = indexes.first { $0 != index }.map { listed[$0].title }
            }
        }
        all = listed
        if let pending, !all.contains(where: { $0.id == pending.id }) { self.pending = nil }
        filter(selecting: selected)
    }
    private func filter(selecting id: String?) {
        let words = search.stringValue.split(whereSeparator: \.isWhitespace)
        rows = all.filter { row in
            guard !changedOnly || row.isCustom else { return false }
            let text = [row.title, row.shortcut?.displayText ?? "", row.shortcut?.spokenText ?? "", row.status]
                .joined(separator: "\n")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        reloading = true
        table.reloadData()
        if let id, let index = rows.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        reloading = false
        showSelection()
    }
    var selectedRow: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }
    /// Selects a command by its identifier, clearing a search that hides it. False when it is not listed.
    @discardableResult func select(_ id: String) -> Bool {
        if !rows.contains(where: { $0.id == id }) {
            search.stringValue = ""
            filter(selecting: id)
        }
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return false }
        table.selectRowIndexes([index], byExtendingSelection: false)
        table.scrollRowToVisible(index)
        showSelection()
        return true
    }
    @objc private func searchChanged(_ sender: Any?) { filter(selecting: selectedRow?.id) }
    func controlTextDidChange(_ notification: Notification) { filter(selecting: selectedRow?.id) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let value = rows[row]
        let text: String
        switch column {
        case "command": text = value.title
        case "shortcut": text = value.shortcut?.displayText ?? ""
        default: text = value.status
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = column == "command" ? .byTruncatingMiddle : .byTruncatingTail
        label.toolTip = text
        label.identifier = .init(value.id + "." + column)
        if !value.isAssignable { label.textColor = .secondaryLabelColor }
        switch column {
        case "shortcut":
            label.setAccessibilityLabel(value.shortcut?.spokenText ?? "No shortcut")
        default: label.setAccessibilityLabel(text)
        }
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        // A question or a result about one command does not carry over to another.
        if pending != nil, pending?.id != selectedRow?.id { endPending() }
        if !reloading, pending == nil { say("") }
        showSelection()
    }
    private func showSelection() {
        if let row = selectedRow {
            selection.stringValue = row.title
            selection.toolTip = row.title
            recorder.isEnabled = row.isAssignable
            recorder.idleTitle = row.shortcut?.displayText ?? (row.isAssignable ? "Record Shortcut" : "No Shortcut")
            let current = row.shortcut?.spokenText ?? "no shortcut"
            ControlPresentation.label("Record a shortcut for \(row.title), now \(current)", control: recorder)
            useDefault.isEnabled = row.isAssignable && row.isCustom
            clear.isEnabled = row.isAssignable && row.shortcut != nil
            switch row.kind {
            case .system(let reason), .fixed(let reason): show(note: reason)
            case .assignable: show(note: "")
            }
        } else {
            selection.stringValue =
                rows.isEmpty
                ? (changedOnly ? "No shortcut has been changed." : "No command matches the search.")
                : "Select a command to change its shortcut."
            selection.toolTip = nil
            recorder.isEnabled = false
            recorder.idleTitle = "Record Shortcut"
            ControlPresentation.label("Record a shortcut for the selected command", control: recorder)
            useDefault.isEnabled = false
            clear.isEnabled = false
            show(note: "")
        }
        resetAll.isEnabled = !settings().shortcuts.isEmpty
    }
    private func show(note text: String) {
        guard note.stringValue != text || note.isHidden != text.isEmpty else { return }
        note.stringValue = text
        note.isHidden = text.isEmpty
        layoutChanged()
    }
    /// Shows a result or a reason below the list and announces it, even when it repeats.
    private func say(_ text: String) {
        let changed = message.isHidden != text.isEmpty || message.stringValue != text
        message.stringValue = ""
        message.stringValue = text
        message.isHidden = text.isEmpty
        if changed { layoutChanged() }
    }

    // MARK: Recording and conflicts

    @objc private func recordSelected(_ sender: Any?) {
        guard selectedRow?.isAssignable == true else { return }
        if recorder.isRecording {
            recorder.endRecording()
            say("The shortcut was not changed.")
        } else {
            endPending()
            recorder.beginRecording()
            if recorder.isRecording, let row = selectedRow {
                say("Type the shortcut for “\(row.title)”. Press Escape to keep the current one.")
            }
        }
    }
    /// What happens to a key press the recorder took: refused with the reason, held for an
    /// answer when another command has the key, or saved.
    func record(_ shortcut: MenuShortcut) {
        guard let row = selectedRow, row.isAssignable else { return }
        endPending()
        if let refusal = ShortcutPolicy.refusal(for: shortcut) {
            say(refusal.reason)
            return
        }
        propose(shortcut, for: row)
    }
    private func propose(_ shortcut: MenuShortcut?, for row: Row) {
        let saved = settings()
        if let shortcut {
            if let owner = context.fixed[shortcut.identity] {
                say(
                    "\(shortcut.spokenText) is used by “\(owner)”, whose shortcut cannot be changed here. Choose a different shortcut."
                )
                return
            }
            let holders = saved.holders(of: shortcut, in: context, except: row.id)
            if !holders.isEmpty {
                pending = (row.id, shortcut, holders)
                replace.isHidden = false
                cancel.isHidden = false
                let names = holders.map { "“" + context.title($0) + "”" }.joined(separator: " and ")
                say(
                    "\(shortcut.spokenText) is already used by \(names). Replace gives it to “\(row.title)” and leaves \(names) without a shortcut. Cancel changes nothing."
                )
                return
            }
        }
        commit(shortcut, to: row, replacing: [])
    }
    private func commit(_ shortcut: MenuShortcut?, to row: Row, replacing: [String]) {
        let context = context
        do {
            try write { $0.assignShortcut(shortcut, to: row.id, replacing: replacing, in: context) }
            // The owner reloads the list when the settings change; the selection is kept.
            _ = select(row.id)
            if let shortcut {
                say("“\(row.title)” now uses \(shortcut.spokenText).")
            } else {
                say("“\(row.title)” now has no shortcut.")
            }
        } catch {
            say(error.localizedDescription)
        }
    }
    private func endPending() {
        guard pending != nil || !replace.isHidden else { return }
        pending = nil
        replace.isHidden = true
        cancel.isHidden = true
        layoutChanged()
    }
    @objc private func replacePending(_ sender: Any?) {
        guard let pending, let row = all.first(where: { $0.id == pending.id }) else { return }
        endPending()
        _ = select(row.id)
        commit(pending.shortcut, to: row, replacing: pending.holders)
    }
    @objc private func cancelPending(_ sender: Any?) {
        guard pending != nil else { return }
        endPending()
        say("The shortcut was not changed.")
    }
    /// Reset one: the command's default, which is itself a key another command may now hold.
    @objc private func useDefaultShortcut(_ sender: Any?) {
        guard let row = selectedRow, row.isAssignable, row.isCustom else { return }
        endPending()
        propose(row.standard, for: row)
    }
    @objc private func clearShortcut(_ sender: Any?) {
        guard let row = selectedRow, row.isAssignable, row.shortcut != nil else { return }
        endPending()
        commit(nil, to: row, replacing: [])
    }
    @objc private func resetAllShortcuts(_ sender: Any?) {
        endPending()
        confirmResetAll()
    }
    func didResetAll() { say("Every shortcut is back to its default.") }
    /// Called when the window closes: a recording must not outlive it.
    func retire() {
        recorder.endRecording()
        pending = nil
    }
}
