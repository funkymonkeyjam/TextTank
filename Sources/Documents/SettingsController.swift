import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os

extension EditorSettings {
    @MainActor var resolvedBaseFont: NSFont {
        NSFont(name: fontName ?? "Menlo", size: basePointSize)
            ?? NSFont(name: "Menlo", size: basePointSize)
            ?? NSFont.monospacedSystemFont(ofSize: basePointSize, weight: .regular)
    }
    @MainActor var unavailableFontNotice: String? {
        guard let fontName, NSFont(name: fontName, size: basePointSize) == nil else { return nil }
        return
            "“\(fontName)” is unavailable. Using \(resolvedBaseFont.displayName ?? resolvedBaseFont.fontName) until the saved font is available."
    }
}

@MainActor final class SettingsController: NSObject, NSMenuItemValidation {
    private var backing: SettingsStore
    /// The store, told which commands the menu bar has now before it checks or writes anything.
    /// Reading a value does not need that and goes to `backing`.
    fileprivate var store: SettingsStore {
        backing.shortcutContext = NSApp?.mainMenu.map { ShortcutCatalog.context(in: $0) }
        return backing
    }
    /// What saved shortcuts are checked against: the menu bar's commands, once it exists.
    var shortcutContext: ShortcutContext { ShortcutCatalog.context(in: NSApp?.mainMenu) }
    var value: EditorSettings { backing.value }
    var ignoredShortcutBindings: [ShortcutLoadIssue] { backing.ignoredShortcutBindings }
    var shortcutLoadNotice: String? { backing.shortcutLoadNotice }
    var loadState: StoreLoadState { backing.loadState }
    var loadError: Error? { backing.loadError }
    var url: URL { backing.url }
    var loadFailureMessage: String? { backing.loadFailureMessage }
    private let onApply: @MainActor (EditorSettings, EditorSettings?) -> Void
    fileprivate let onStatus: @MainActor (String) -> Void
    init(
        url: URL? = nil, onApply: @escaping @MainActor (EditorSettings, EditorSettings?) -> Void = { _, _ in },
        onStatus: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        backing = SettingsStore(
            url: url, reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu),
            context: NSApp?.mainMenu.map { ShortcutCatalog.context(in: $0) })
        self.onApply = onApply
        self.onStatus = onStatus
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuItemAdded(_:)), name: NSMenu.didAddItemNotification, object: nil)
    }
    func reconcileShortcuts(with menu: NSMenu) {
        backing.shortcutContext = ShortcutCatalog.context(in: menu)
        backing.reconcileShortcuts(reservedKeys: Self.reservedShortcuts(in: menu))
    }
    private var reapplyPending = false
    /// A menu its owner rebuilds (Run Commands) gets new items with their default keys. The
    /// saved shortcuts are put back on the next turn of the run loop, once for any number of
    /// items, and only by the application's own settings.
    @objc private func menuItemAdded(_ note: Notification) {
        guard !reapplyPending, !value.shortcuts.isEmpty, EditorServices.current?.settings === self,
            let bar = NSApp?.mainMenu, var menu = note.object as? NSMenu
        else { return }
        while let parent = menu.supermenu { menu = parent }
        guard menu === bar else { return }
        reapplyPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reapplyPending = false
            if let bar = NSApp?.mainMenu { ShortcutCatalog.apply(self.value, to: bar) }
        }
    }
    /// The key the menu bar shows for an editor command now, for a menu that repeats the
    /// command elsewhere (DS-20). Nil when the menu bar does not list the command.
    func menuShortcut(for command: EditorCommand) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        let context = shortcutContext
        guard context.commands[command.rawValue] != nil else { return nil }
        let shortcut = value.effectiveShortcut(for: command.rawValue, in: context)
        return (shortcut?.key ?? "", shortcut?.appKitModifiers ?? [.command])
    }
    @discardableResult func save(
        _ settings: EditorSettings, replacingUnreadable: Bool = false, requiringCurrent: Bool = false
    ) throws -> URL? {
        let previous = value
        let backup = try store.save(
            settings, replacingUnreadable: replacingUnreadable, requiringCurrent: requiringCurrent,
            reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
        apply(replacing: previous)
        liveForm?.valuesChanged()
        if previous.fontName != settings.fontName, let message = settings.unavailableFontNotice { onStatus(message) }
        return backup
    }
    func apply(to editor: TTEditor) {
        let font = value.resolvedBaseFont
        editor.setBaseFontName(font.fontName, size: font.pointSize)
        editor.applyDefaultZoomLevel(value.initialZoom)
        editor.configureTabWidth(value.tabWidth, useTabs: value.useTabs)
        editor.autoIndentEnabled = value.autoIndentEnabled
        editor.autoPairEnabled = value.autoPairEnabled
        editor.braceHighlightEnabled = value.braceHighlightEnabled
        editor.currentLineHighlightEnabled = value.currentLineHighlightEnabled
        editor.indentGuidesEnabled = value.indentGuidesEnabled
        editor.lineNumbersVisible = value.lineNumbersEnabled
        editor.whitespaceVisible = value.showWhitespaceEnabled
        editor.lineEndingsVisible = value.showLineEndingsEnabled
        editor.wrap = value.wrap
        // A large-file document's owner stops its change record again (EditorSettingsApplication).
        editor.changeBarsVisible = value.changeBarsEnabled
        editor.centeredColumnCharacters = value.centeredColumnEnabled ? value.centeredColumnCharacters : 0
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutoIndent(_:)) {
            item.state = value.autoIndentEnabled ? .on : .off
        } else if item.action == #selector(toggleAutoPair(_:)) {
            item.state = value.autoPairEnabled ? .on : .off
        } else if item.action == #selector(toggleBraceHighlight(_:)) {
            item.state = value.braceHighlightEnabled ? .on : .off
        } else if item.action == #selector(toggleCurrentLineHighlight(_:)) {
            item.state = value.currentLineHighlightEnabled ? .on : .off
        } else if item.action == #selector(toggleIndentGuides(_:)) {
            item.state = value.indentGuidesEnabled ? .on : .off
        } else if item.action == #selector(toggleChangeBars(_:)) {
            item.state = value.changeBarsEnabled ? .on : .off
        } else if item.action == #selector(toggleCenteredColumn(_:)) {
            item.state = value.centeredColumnEnabled ? .on : .off
        }
        return true
    }
    @objc func toggleAutoIndent(_ sender: Any?) { updateViewPreference(.autoIndent, sender: sender) }
    @objc func toggleAutoPair(_ sender: Any?) { updateViewPreference(.autoPair, sender: sender) }
    @objc func toggleBraceHighlight(_ sender: Any?) { updateViewPreference(.braceHighlight, sender: sender) }
    @objc func toggleCurrentLineHighlight(_ sender: Any?) {
        updateViewPreference(.currentLineHighlight, sender: sender)
    }
    @objc func toggleIndentGuides(_ sender: Any?) { updateViewPreference(.indentGuides, sender: sender) }
    /// View > Show > Change Bars and View > Centered Text Column (DS-D13): one stored choice each,
    /// for every editor view, shown with a checkmark (DS-22).
    @objc func toggleChangeBars(_ sender: Any?) { updateViewPreference(.changeBars, sender: sender) }
    @objc func toggleCenteredColumn(_ sender: Any?) { updateViewPreference(.centeredColumn, sender: sender) }
    /// Show Line Numbers, Show Whitespace and Show Line Endings stay catalog commands in the View
    /// menu; the active tab routes them here so that one stored choice reaches every editor view.
    func isEnabled(_ preference: EditorViewPreference) -> Bool { preference.enabled(in: value) }
    func toggle(_ preference: EditorViewPreference, sender: Any? = nil) {
        updateViewPreference(preference, sender: sender)
    }
    private func updateViewPreference(_ preference: EditorViewPreference, sender: Any?) {
        guard loadError == nil, ignoredShortcutBindings.isEmpty else {
            showSettings(sender)
            return
        }
        let previous = value
        do {
            try store.updateViewPreference(preference, reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu)) {
                !$0
            }
            apply(replacing: previous)
            liveForm?.valuesChanged()
        } catch {
            if let liveForm { liveForm.showViewPreferenceError(error) } else { TTAlert.present(error) }
        }
    }
    /// The rendered mode chosen last when the settings file could not take it (it is unreadable
    /// or needs repair). It is then remembered until TextTank quits.
    private var unsavedRenderedMode: DocumentViewMode?
    /// What Toggle Preview shows from Source: Preview or Both, whichever the person chose last.
    var toggledPreviewMode: DocumentViewMode { unsavedRenderedMode ?? value.toggledPreviewMode }
    /// Called when the person chooses Preview or Both for a tab. Writes one member of the
    /// settings file, and only when the choice differs from the one remembered.
    func noteRenderedMode(_ mode: DocumentViewMode) {
        guard mode != .source, mode != toggledPreviewMode else { return }
        let previous = value
        do {
            try store.updateLastRenderedPreviewMode(mode, reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
            unsavedRenderedMode = nil
            adoptStoreValue(replacing: previous)
        } catch {
            // Losing this convenience is not worth an alert in the middle of a view change (DS-40).
            unsavedRenderedMode = mode
        }
    }
    /// A one-member write reads the settings file again first, so the store may now hold values
    /// another writer changed. They are applied, and shown in an open Settings window, as they
    /// are after the neighbouring one-member writes.
    fileprivate func adoptStoreValue(replacing previous: EditorSettings) {
        guard value != previous else { return }
        apply(replacing: previous)
        liveForm?.valuesChanged()
    }
    /// The composition root applies this synchronous change to open documents and menus.
    func apply(replacing previous: EditorSettings? = nil) { onApply(value, previous) }
    static func reservedShortcuts(in menu: NSMenu?) -> Set<String> {
        var keys = EditorSettings.protectedShortcuts
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                let assignable = (item.representedObject as? String).map(EditorSettings.commands.contains) ?? false
                if !assignable && !(item is DefaultShortcutItem) && !item.keyEquivalent.isEmpty
                    && (modifiers == .command || modifiers == [.command, .shift])
                {
                    keys.insert(modifiers.contains(.shift) ? item.keyEquivalent.uppercased() : item.keyEquivalent)
                }
                if let child = item.submenu { walk(child) }
            }
        }
        if let menu { walk(menu) }
        return keys
    }
    private var liveForm: LiveSettingsForm?
    @objc func showSettings(_ sender: Any?) {
        if let liveForm {
            liveForm.form.window.makeKeyAndOrderFront(nil)
            return
        }
        // Reopening is the recovery path after an external change, including an unreadable file.
        let previous = value
        backing = SettingsStore(
            url: url, reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu),
            context: NSApp?.mainMenu.map { ShortcutCatalog.context(in: $0) })
        if value != previous { apply(replacing: previous) }
        let live = LiveSettingsForm(owner: self)
        liveForm = live
        live.form.onClose = { [weak self, weak live] in
            live?.releaseFontPanel()
            live?.retireShortcuts()
            self?.liveForm = nil
        }
        live.form.show()
    }
}

/// The panes of the Settings window, in toolbar order. A Mac settings window switches panes
/// from a real toolbar in the preference style (DS-11), and each pane is as tall as its content.
enum SettingsPane: String, CaseIterable {
    case editing, appearance, files, previews, shortcuts
    var title: String {
        switch self {
        case .editing: return "Editing"
        case .appearance: return "Appearance"
        case .files: return "Files"
        case .previews: return "Previews"
        case .shortcuts: return "Shortcuts"
        }
    }
    var symbol: String {
        switch self {
        case .editing: return "text.cursor"
        case .appearance: return "paintpalette"
        case .files: return "folder"
        case .previews: return "eye"
        case .shortcuts: return "keyboard"
        }
    }
    var toolbarItem: NSToolbarItem.Identifier { .init("settings.pane." + rawValue) }
}

/// One setting as the window lists it: the pane it lives in, the words that find it, whether
/// its value differs from the default, and the way back to that default.
@MainActor final class SettingRow {
    let id: String, pane: SettingsPane, label: String, keywords: [String]
    let view = NSStackView()
    fileprivate(set) var useDefault: NSButton?
    fileprivate let differs: (EditorSettings) -> Bool
    fileprivate let reset: (() throws -> Void)?
    fileprivate init(
        id: String, pane: SettingsPane, label: String, keywords: [String],
        differs: @escaping (EditorSettings) -> Bool, reset: (() throws -> Void)?
    ) {
        self.id = id
        self.pane = pane
        self.label = label
        self.keywords = keywords
        self.differs = differs
        self.reset = reset
    }
    /// Every word typed must be in the visible label, the pane's name or a synonym, in any order.
    nonisolated static func matches(_ query: String, label: String, pane: String, keywords: [String]) -> Bool {
        let text = ([label, pane] + keywords).joined(separator: "\n")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
    func matches(_ query: String) -> Bool {
        Self.matches(query, label: label, pane: pane.title, keywords: keywords)
    }
}

/// Views in the key window are offered a key equivalent before the menu bar. This one gives
/// Command-F its usual meaning inside Settings: it moves to the search field (DS-25, DS-73).
private final class SettingsKeyEquivalents: NSView {
    var find: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // A key that is being recorded as a shortcut belongs to the recorder, which refuses this one.
        guard flags == .command, event.charactersIgnoringModifiers == "f", let find,
            (window?.firstResponder as? ShortcutRecorder)?.isRecording != true
        else { return super.performKeyEquivalent(with: event) }
        find()
        return true
    }
}

@MainActor
private final class LiveSettingsForm: NSObject, NSTextFieldDelegate, NSWindowDelegate, NSFontChanging,
    NSToolbarDelegate, NSSearchFieldDelegate
{
    /// Every pane has this content width; only the Shortcuts list can be made larger.
    static let contentWidth: CGFloat = 620
    let owner: SettingsController
    let form = FormPanel(
        title: "Settings", identifier: "TextTank.Settings", size: NSSize(width: contentWidth, height: 360))
    @MainActor private final class Section {
        let pane: SettingsPane
        let stack = NSStackView()
        let heading: NSTextField
        var rows: [SettingRow] = []
        var notes: [NSView] = []
        init(_ pane: SettingsPane) {
            self.pane = pane
            heading = NSTextField(labelWithString: pane.title)
            heading.font = .preferredFont(forTextStyle: .headline)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.addArrangedSubview(heading)
        }
    }
    private let sections: [Section] = SettingsPane.allCases.map { Section($0) }
    /// Every row in the order it was listed; a Use Default button's tag is its index here.
    private var rows: [SettingRow] = []
    private var pane = SettingsPane.editing
    private let filter = NSSearchField()
    private let changedOnly = NSButton(checkboxWithTitle: "Changed from default", target: nil, action: nil)
    private let noMatches = AnnouncingLabel(wrappingLabelWithString: "")
    private let width = NSTextField(), size = NSTextField(), zoom = NSTextField(), column = NSTextField()
    private let widthStepper = NSStepper(), sizeStepper = NSStepper(), zoomStepper = NSStepper()
    private let columnStepper = NSStepper()
    private let tabs = NSButton(checkboxWithTitle: "Indent with tabs", target: nil, action: nil)
    private let wrap = NSButton(checkboxWithTitle: "Wrap lines", target: nil, action: nil)
    /// Checkboxes made by `toggleRow`, with the stored member each one edits.
    private var memberToggles: [(button: NSButton, member: WritableKeyPath<EditorSettings, Bool?>, standard: Bool)] = []
    private var rowActions: [() -> Void] = []
    private let launchBehavior = NSPopUpButton()
    private let appearance = NSPopUpButton()
    private let diskChanges = NSPopUpButton()
    /// One pair of pop-ups for the five preview formats: the second shows the choice of the
    /// format the first one names.
    private let previewFormat = NSPopUpButton()
    private let previewOpenMode = NSPopUpButton()
    private let face = NSTextField(labelWithString: "")
    private let fontButton = NSButton(title: "Font…", target: nil, action: nil)
    private var shortcuts: ShortcutsPane!
    private var shortcutsRow: SettingRow?
    /// Whether the list was showing at the last resize, when its height was the person's choice.
    private var listWasShown = false
    private var maintenancePending = false
    private var presentingError = false
    private var displayed: EditorSettings
    private var panel: NSFontPanel?
    private weak var previousTarget: AnyObject?
    private weak var previousDelegate: (any NSWindowDelegate)?
    private var previousAction: Selector?
    private var previousFont: NSFont?
    private var fixedCollection: NSFontCollection.Name?
    private var previousCollection: String?
    private var previousAccessory: NSView?
    private nonisolated let legacyFilter = OSAllocatedUnfairLock(initialState: false)
    private let fixedPitch = NSButton(checkboxWithTitle: "Fixed-pitch fonts only", target: nil, action: nil)
    private var previousMultiple = false, panelWasVisible = false
    private var panelSelection: EditorSettings?
    private var convertingFont = false
    init(owner: SettingsController) {
        self.owner = owner
        displayed = owner.value
        super.init()
        build()
    }

    // MARK: Rows

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        // A wrapping label's height depends on its width; the panes have one width.
        label.preferredMaxLayoutWidth = Self.contentWidth - 40
        return label
    }
    private func section(_ pane: SettingsPane) -> Section { sections.first { $0.pane == pane }! }
    private func addNote(_ text: String, to pane: SettingsPane) {
        let label = note(text)
        label.textColor = .secondaryLabelColor
        let owner = section(pane)
        owner.notes.append(label)
        owner.stack.addArrangedSubview(label)
    }
    /// Lists one setting. `views` are its controls in reading order; a control keeps the
    /// identifier and accessibility label its caller gave it (DS-70). `differs` and `reset`
    /// drive the Changed from default filter and the row's Use Default button.
    @discardableResult private func addRow(
        _ id: String, _ pane: SettingsPane, _ label: String, keywords: [String], views: [NSView],
        differs: @escaping (EditorSettings) -> Bool = { _ in false }, reset: (() throws -> Void)? = nil
    ) -> SettingRow {
        let row = SettingRow(id: id, pane: pane, label: label, keywords: keywords, differs: differs, reset: reset)
        row.view.orientation = .horizontal
        row.view.alignment = .centerY
        row.view.spacing = 8
        row.view.identifier = .init(id + ".row")
        views.forEach(row.view.addArrangedSubview)
        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .horizontal)
        row.view.addArrangedSubview(space)
        if reset != nil {
            // One setting, and choosing its previous value again undoes it (DS-91), so this is
            // not a destructive action and needs no confirmation.
            let button = NSButton(title: "Use Default", target: self, action: #selector(useDefault(_:)))
            button.bezelStyle = .rounded
            button.identifier = .init(id + ".default")
            button.tag = rows.count
            ControlPresentation.label("Use the default for " + label, control: button)
            button.isHidden = true
            row.view.addArrangedSubview(button)
            row.useDefault = button
        }
        let owner = section(pane)
        rows.append(row)
        owner.rows.append(row)
        owner.stack.addArrangedSubview(row.view)
        row.view.widthAnchor.constraint(equalTo: owner.stack.widthAnchor).isActive = true
        return row
    }
    private func caption(_ label: String, for control: NSControl, identifier: String) -> NSTextField {
        let caption = NSTextField(labelWithString: label)
        ControlPresentation.label(label, control: control, caption: caption)
        caption.widthAnchor.constraint(equalToConstant: 160).isActive = true
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        return caption
    }
    /// A short number field with a stepper beside it. The stepper commits through the field's
    /// own action, so both validate and save the same way.
    private func numberViews(
        _ label: String, _ field: NSTextField, _ stepper: NSStepper, identifier: String, range: ClosedRange<Double>
    ) -> [NSView] {
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        field.alignment = .right
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(step(_:))
        stepper.identifier = .init(identifier + ".stepper")
        ControlPresentation.label(label + ", stepper", control: stepper)
        return [caption(label, for: field, identifier: identifier), field, stepper]
    }
    // SETTINGS-ROW-EXTENSION: how another slice lists a setting it stores.
    //
    // A stored `Bool?` member of `EditorSettings` whose missing value has a default becomes a
    // checkbox with one call in `build()`, in the pane it belongs to:
    //
    //     toggleRow("settings.lineNumbers", .appearance, "Show line numbers",
    //               keywords: ["gutter", "margin"], \.lineNumbers, default: true)
    //
    // The row saves when clicked, follows a change made from a menu, is found by the search
    // field, is listed by Changed from default and gets a Use Default button. A command that is
    // not a stored value (Clear History…) becomes a button with `actionRow`.
    @discardableResult private func toggleRow(
        _ id: String, _ pane: SettingsPane, _ title: String, keywords: [String],
        _ member: WritableKeyPath<EditorSettings, Bool?>, default standard: Bool
    ) -> SettingRow {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleMember(_:)))
        button.identifier = .init(id)
        button.tag = memberToggles.count
        ControlPresentation.label(title, control: button)
        memberToggles.append((button, member, standard))
        return addRow(
            id, pane, title, keywords: keywords, views: [button],
            differs: { ($0[keyPath: member] ?? standard) != standard },
            reset: { [unowned self] in try self.write { $0[keyPath: member] = nil } })
    }
    @discardableResult private func actionRow(
        _ id: String, _ pane: SettingsPane, _ label: String, button title: String, keywords: [String],
        action: @escaping () -> Void
    ) -> SettingRow {
        let button = NSButton(title: title, target: self, action: #selector(performRowAction(_:)))
        button.bezelStyle = .rounded
        button.tag = rowActions.count
        rowActions.append(action)
        return addRow(id, pane, label, keywords: keywords, views: [caption(label, for: button, identifier: id), button])
    }

    // MARK: Building

    private func build() {
        let window = form.window
        // Where the restored frame put the title bar, before the toolbar or any pane changes it.
        let anchor = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        form.validation.preferredMaxLayoutWidth = Self.contentWidth - 40
        let keys = SettingsKeyEquivalents()
        keys.find = { [weak self] in
            guard let self else { return }
            self.form.window.makeFirstResponder(self.filter)
        }
        window.contentView?.addSubview(keys)
        filter.placeholderString = "Search settings"
        filter.identifier = .init("settings.filter")
        filter.sendsSearchStringImmediately = true
        filter.target = self
        filter.action = #selector(filterChanged(_:))
        filter.delegate = self
        ControlPresentation.label("Search settings by name", control: filter)
        changedOnly.identifier = .init("settings.filter.changed")
        changedOnly.target = self
        changedOnly.action = #selector(filterChanged(_:))
        ControlPresentation.label("Show only settings changed from their defaults", control: changedOnly)
        changedOnly.setContentHuggingPriority(.required, for: .horizontal)
        let filterBar = NSStackView(views: [filter, changedOnly])
        filterBar.spacing = 12
        form.add(filterBar)
        if let notice = owner.shortcutLoadNotice { form.add(note(notice)) }
        if owner.loadError != nil {
            form.add(note("The saved settings could not be read. Repair Settings keeps a backup of the original file."))
        }
        noMatches.preferredMaxLayoutWidth = Self.contentWidth - 40
        noMatches.identifier = .init("settings.filter.empty")
        noMatches.isHidden = true
        form.add(noMatches)

        NumericInput.configure(width)
        NumericInput.configure(size, fractional: true)
        NumericInput.configure(zoom)
        NumericInput.configure(column)
        column.stringValue = String(displayed.centeredColumnCharacters)
        for field in [width, size, zoom, column] {
            field.target = self
            field.action = #selector(commitField(_:))
            field.delegate = self
        }
        width.stringValue = String(displayed.tabWidth)
        size.stringValue = NumericInput.editable(displayed.basePointSize)
        zoom.stringValue = String(displayed.initialZoom)
        let standard = EditorSettings()

        // Editing
        addRow(
            "settings.width", .editing, "Tab width",
            keywords: ["indent", "indentation", "spaces", "columns", "tab size"],
            views: numberViews("Tab width", width, widthStepper, identifier: "settings.width", range: 1...32),
            differs: { $0.tabWidth != standard.tabWidth },
            reset: { [unowned self] in
                try self.write { $0.tabWidth = standard.tabWidth }
                self.adoptField(self.width)
            })
        for (button, id) in [(tabs, "settings.tabs"), (wrap, "settings.wrap")] {
            button.identifier = .init(id)
            button.target = self
            button.action = #selector(toggle(_:))
            ControlPresentation.label(button.title, control: button)
        }
        addRow(
            "settings.tabs", .editing, "Indent with tabs", keywords: ["spaces", "indentation", "soft tabs", "tab key"],
            views: [tabs], differs: { $0.useTabs != standard.useTabs },
            reset: { [unowned self] in try self.write { $0.useTabs = standard.useTabs } })
        toggleRow(
            "settings.autoIndent", .editing, "Auto-indent on Return", keywords: ["indentation", "new line", "enter"],
            \.autoIndent, default: standard.autoIndentEnabled)
        toggleRow(
            "settings.autoPair", .editing, "Auto-pair brackets and quotes",
            keywords: ["braces", "parentheses", "closing", "match"], \.autoPair, default: standard.autoPairEnabled)
        addRow(
            "settings.wrap", .editing, "Wrap lines", keywords: ["word wrap", "soft wrap", "long lines"],
            views: [wrap], differs: { $0.wrap != standard.wrap },
            reset: { [unowned self] in try self.write { $0.wrap = standard.wrap } })

        // Appearance
        ControlPresentation.populate(
            appearance, choices: [("system", "System"), ("light", "Light"), ("dark", "Dark")],
            selected: displayed.appearance)
        appearance.target = self
        appearance.action = #selector(selectAppearance(_:))
        addRow(
            "settings.appearance", .appearance, "Appearance",
            keywords: ["theme", "dark mode", "light mode", "colour scheme", "color scheme"],
            views: [caption("Appearance", for: appearance, identifier: "settings.appearance"), appearance],
            differs: { $0.appearance != standard.appearance },
            reset: { [unowned self] in try self.write { $0.appearance = standard.appearance } })
        fontButton.target = self
        fontButton.action = #selector(openFontPanel(_:))
        fontButton.bezelStyle = .rounded
        let fontCaption = caption("Editor font", for: fontButton, identifier: "settings.font.choose")
        ControlPresentation.label("Choose editor font in Settings", control: fontButton)
        addRow(
            "settings.font.choose", .appearance, "Editor font", keywords: ["typeface", "family", "monospace", "text"],
            views: [fontCaption, fontButton, face],
            differs: { $0.resolvedBaseFont.fontName != standard.resolvedBaseFont.fontName },
            reset: { [unowned self] in try self.write { $0.fontName = nil } })
        if let notice = owner.value.unavailableFontNotice { addNote(notice, to: .appearance) }
        addRow(
            "settings.font.size", .appearance, "Font size (points)",
            keywords: ["text size", "typeface", "larger", "smaller"],
            views: numberViews(
                "Font size (points)", size, sizeStepper, identifier: "settings.font.size", range: 6...72),
            differs: { $0.basePointSize != standard.basePointSize },
            reset: { [unowned self] in
                try self.write { $0.fontSize = nil }
                self.adoptField(self.size)
            })
        addRow(
            "settings.font.zoom", .appearance, "Default zoom", keywords: ["magnification", "scale", "text size"],
            views: numberViews("Default zoom", zoom, zoomStepper, identifier: "settings.font.zoom", range: -10...60),
            differs: { $0.initialZoom != standard.initialZoom },
            reset: { [unowned self] in
                try self.write { $0.defaultZoom = nil }
                self.adoptField(self.zoom)
            })
        toggleRow(
            "settings.indentGuides", .appearance, "Show indentation guides", keywords: ["indent", "vertical lines"],
            \.indentGuides, default: standard.indentGuidesEnabled)
        toggleRow(
            "settings.currentLineHighlight", .appearance, "Highlight current line",
            keywords: ["caret", "cursor", "row"],
            \.currentLineHighlight, default: standard.currentLineHighlightEnabled)
        toggleRow(
            "settings.braceHighlight", .appearance, "Highlight matching braces",
            keywords: ["brackets", "parentheses", "pair"], \.braceHighlight, default: standard.braceHighlightEnabled)
        // SETTINGS-ROW-EXTENSION (Appearance): the three View toggles that are one stored choice
        // for every editor view.
        toggleRow(
            "settings.lineNumbers", .appearance, "Show line numbers", keywords: ["gutter", "margin"],
            \.lineNumbers, default: standard.lineNumbersEnabled)
        toggleRow(
            "settings.showWhitespace", .appearance, "Show whitespace",
            keywords: ["spaces", "invisibles", "invisible characters", "dots"], \.showWhitespace,
            default: standard.showWhitespaceEnabled)
        toggleRow(
            "settings.showLineEndings", .appearance, "Show line endings",
            keywords: ["eol", "crlf", "newline", "invisibles", "carriage return"], \.showLineEndings,
            default: standard.showLineEndingsEnabled)
        // SETTINGS-ROW-EXTENSION (Appearance): View › Show › Change Bars and View › Centered Text
        // Column, each one stored choice for every editor view (DS-D13).
        let changeBarsRow = toggleRow(
            "settings.changeBars", .appearance, "Show change bars",
            keywords: ["modified lines", "changed lines", "change history", "edited", "unsaved"],
            \.changeBars, default: standard.changeBarsEnabled)
        // What the bars mean, and why a document edited before the toggle has none yet (DS-85).
        if let box = changeBarsRow.view.arrangedSubviews.first as? NSButton {
            box.toolTip = EditorSettingsApplication.changeBarsHelp
            box.setAccessibilityHelp(EditorSettingsApplication.changeBarsHelp)
        }
        toggleRow(
            "settings.centeredColumn", .appearance, "Center the text in a column",
            keywords: ["centered text column", "centred", "margins", "focus", "reading width", "line length"],
            \.centeredColumn, default: standard.centeredColumnEnabled)
        let columns = EditorSettings.centeredColumnWidths
        addRow(
            "settings.centeredColumn.width", .appearance, "Column width (characters)",
            keywords: ["centred column", "line length", "margins"],
            views: numberViews(
                "Column width (characters)", column, columnStepper, identifier: "settings.centeredColumn.width",
                range: Double(columns.lowerBound)...Double(columns.upperBound)),
            differs: { $0.centeredColumnCharacters != standard.centeredColumnCharacters },
            reset: { [unowned self] in
                try self.write { $0.centeredColumnWidth = nil }
                self.adoptField(self.column)
            })

        // Files
        ControlPresentation.populate(
            launchBehavior, choices: [("restore", "Reopen last session"), ("new", "New document")],
            selected: displayed.reopensLastSession ? "restore" : "new")
        launchBehavior.target = self
        launchBehavior.action = #selector(selectLaunchBehavior(_:))
        addRow(
            "settings.atLaunch", .files, "At launch", keywords: ["startup", "session", "restore", "reopen", "open"],
            views: [caption("At launch", for: launchBehavior, identifier: "settings.atLaunch"), launchBehavior],
            differs: { $0.reopensLastSession != standard.reopensLastSession },
            reset: { [unowned self] in try self.write { $0.reopenLastSession = nil } })
        ControlPresentation.populate(
            diskChanges,
            choices: [
                (ExternalChangePolicy.ask.rawValue, "Ask"),
                (ExternalChangePolicy.reloadIfUnmodified.rawValue, "Reload if unmodified"),
                (ExternalChangePolicy.ignore.rawValue, "Ignore")
            ], selected: displayed.diskChangeBehavior.rawValue)
        diskChanges.target = self
        diskChanges.action = #selector(selectDiskChangePolicy(_:))
        addRow(
            "settings.externalChanges", .files, "External file changes",
            keywords: ["reload", "disk", "modified", "another application", "outside", "ask", "ignore"],
            views: [
                caption("External file changes", for: diskChanges, identifier: "settings.externalChanges"), diskChanges
            ],
            differs: { $0.diskChangeBehavior != standard.diskChangeBehavior },
            reset: { [unowned self] in try self.write { $0.externalChangePolicy = nil } })
        // SETTINGS-ROW-EXTENSION (Files): unsaved work and local history.
        toggleRow(
            "settings.keepUntitledOnQuit", .files, "Keep unsaved untitled documents when quitting",
            keywords: ["quit", "unsaved", "drafts", "scratch", "close"], \.keepUntitledOnQuit,
            default: standard.keepsUntitledOnQuit)
        toggleRow(
            "settings.keepLocalHistory", .files, "Keep earlier versions when saving",
            keywords: ["local history", "versions", "backup", "previous"], \.keepLocalHistory,
            default: standard.keepsLocalHistory)
        // The same command as Compare › Clear Local History…, with its own confirmation.
        actionRow(
            "settings.clearLocalHistory", .files, "Local history", button: "Clear Local History…",
            keywords: ["earlier versions", "delete", "remove", "erase"]
        ) { [weak self] in
            guard let self else { return }
            _ = NSApp.sendAction(
                #selector(AppDelegate.clearLocalHistory(_:)), to: NSApp.delegate,
                from: self.form.window)
        }
        actionRow(
            "settings.reveal", .files, "Settings file", button: "Reveal Settings File in Finder",
            keywords: ["json", "location", "folder", "path", "backup", "show"]
        ) { [weak self] in self?.revealSettingsFile() }

        // Previews
        ControlPresentation.populate(
            previewFormat, choices: PreviewFormat.allCases.map { ($0.rawValue, Self.title($0)) },
            selected: PreviewFormat.markdown.rawValue)
        previewFormat.target = self
        previewFormat.action = #selector(selectPreviewFormat(_:))
        ControlPresentation.populate(
            previewOpenMode, choices: DocumentViewMode.allCases.map { ($0.rawValue, DocumentViewCommands.title($0)) },
            selected: displayed.previewOpenMode(for: .markdown).rawValue)
        previewOpenMode.target = self
        previewOpenMode.action = #selector(selectPreviewOpenMode(_:))
        previewOpenMode.toolTip = Strings.text(
            "settings.preview.openIn.help",
            "What a document of this format shows when you open it. Tabs that are already open, and tabs reopened from the last session, keep what they show."
        )
        let formatTitle = Strings.text("settings.preview.format", "Preview format")
        let openTitle = Strings.text("settings.preview.openIn", "Open in")
        let openCaption = caption(openTitle, for: previewOpenMode, identifier: "settings.preview.openIn")
        openCaption.constraints.forEach { $0.isActive = false }
        addRow(
            "settings.preview.openIn", .previews, formatTitle,
            keywords: [openTitle, "markdown", "html", "csv", "tsv", "svg", "json", "render", "source", "both", "open"],
            views: [
                caption(formatTitle, for: previewFormat, identifier: "settings.preview.format"), previewFormat,
                openCaption, previewOpenMode
            ],
            differs: { settings in PreviewFormat.allCases.contains { settings.previewOpenMode(for: $0) != .source } },
            reset: { [unowned self] in try self.write { $0.previewOpenModes = nil } })
        // SETTINGS-ROW-EXTENSION (Previews)
        toggleRow(
            "settings.syncPreviewScrolling", .previews, "Sync scrolling in Both",
            keywords: ["scroll", "synchronize", "follow", "side by side"], \.syncPreviewScrolling,
            default: standard.syncsPreviewScrolling)

        // Shortcuts: one row that is the whole list. Changed from default narrows the list to
        // the commands whose shortcut was changed, and each has Use Default there.
        shortcuts = ShortcutsPane(
            width: Self.contentWidth - 40, settings: { [unowned self] in self.owner.value },
            issues: { [unowned self] in self.owner.ignoredShortcutBindings },
            write: { [unowned self] update in try self.write(update) },
            confirmResetAll: { [unowned self] in self.confirmMaintenance(.resetShortcuts) },
            layoutChanged: { [unowned self] in self.resizeToContent() })
        let list = addRow(
            "settings.shortcuts", .shortcuts, "Keyboard shortcuts",
            keywords: ["shortcut", "key", "hotkey", "key binding", "key equivalent", "command"],
            views: [shortcuts.view], differs: { !$0.shortcuts.isEmpty })
        // The list is as wide as the pane; nothing follows it in its row.
        list.view.setCustomSpacing(0, after: shortcuts.view)
        shortcutsRow = list
        // Extra height goes to the list and to nothing else.
        shortcuts.view.heightAnchor.constraint(equalTo: list.view.heightAnchor).isActive = true
        form.body.distribution = .fill
        let listSection = section(.shortcuts)
        listSection.stack.distribution = .fill
        for view in [listSection.stack, list.view, shortcuts.view] {
            view.setContentHuggingPriority(.init(1), for: .vertical)
        }

        for section in sections { form.add(section.stack) }
        form.add(note("Changes apply when you finish editing a control."))
        if owner.loadError != nil || !owner.ignoredShortcutBindings.isEmpty {
            form.button("Repair Settings…", identifier: "settings.repair") { [weak self] in
                self?.confirmMaintenance(.repair)
            }
        }
        form.button("Reset Defaults…", identifier: "settings.reset") { [weak self] in self?.confirmMaintenance(.reset) }
        form.button("Close", identifier: "settings.close", cancel: true) { [weak self] in self?.form.close() }

        let toolbar = NSToolbar(identifier: "TextTank.Settings.Panes")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        // A pane switcher is not a set of commands to rearrange (DS-30 is about the document toolbar).
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.autorecalculatesKeyViewLoop = true
        window.initialFirstResponder = width
        valuesChanged()
        resizeToContent(anchor: anchor)
    }

    // MARK: Panes and the filter

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarItem)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarItem)
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.toolbarItem)
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane.allCases.first(where: { $0.toolbarItem == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.toolTip = pane.title + " settings"
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(choosePane(_:))
        return item
    }
    /// Choosing a pane leaves the filter: the pane shows all of its own settings.
    @objc private func choosePane(_ sender: NSToolbarItem) {
        guard let chosen = SettingsPane.allCases.first(where: { $0.toolbarItem == sender.itemIdentifier }) else {
            return
        }
        show(chosen)
    }
    private func show(_ chosen: SettingsPane) {
        pane = chosen
        filter.stringValue = ""
        changedOnly.state = .off
        // Menus that list saved items may have changed since the list was last read.
        if chosen == .shortcuts { shortcuts.reload() }
        refreshRows()
    }
    @objc private func filterChanged(_ sender: Any?) { refreshRows() }
    private var isFiltering: Bool {
        changedOnly.state == .on || !filter.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// Shows the chosen pane, or, while the search field or Changed from default is in use,
    /// the matching settings of every pane under their pane's name.
    private func refreshRows() {
        let query = filter.stringValue, onlyChanged = changedOnly.state == .on, filtering = isFiltering
        let latest = owner.value
        var shown = 0
        for section in sections {
            var visible = 0
            for row in section.rows {
                let differs = row.differs(latest)
                row.useDefault?.isHidden = !differs
                let show = filtering ? row.matches(query) && (!onlyChanged || differs) : section.pane == pane
                row.view.isHidden = !show
                if show { visible += 1 }
            }
            for view in section.notes { view.isHidden = filtering || section.pane != pane }
            if section.pane == .shortcuts { shortcuts.changedOnly = onlyChanged }
            section.heading.isHidden = !filtering
            section.stack.isHidden = visible == 0
            shown += visible
        }
        let message: String
        if !filtering || shown > 0 {
            message = ""
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            message = "Every setting has its default value. Turn off Changed from default to see all settings."
        } else if onlyChanged {
            message = "No changed setting matches “\(query)”. Clear the search to see every changed setting."
        } else {
            message = "No setting matches “\(query)”. Clear the search to see every setting."
        }
        noMatches.isHidden = message.isEmpty
        if noMatches.stringValue != message { noMatches.stringValue = message }
        form.window.toolbar?.selectedItemIdentifier = filtering ? nil : pane.toolbarItem
        resizeToContent()
    }
    /// Makes the window as tall as what it shows, keeping its title bar where it is.
    private func resizeToContent(anchor: NSPoint? = nil) {
        let window = form.window
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var size = NSSize(width: Self.contentWidth, height: ceil(content.fittingSize.height))
        window.contentMinSize = size
        // The Shortcuts list grows with the window; every other pane is exactly its content.
        let grows = shortcutsRow?.view.isHiddenOrHasHiddenAncestor == false
        if grows, listWasShown { size.height = max(size.height, content.bounds.height) }
        listWasShown = grows
        window.contentMaxSize = grows ? NSSize(width: size.width, height: 10_000) : size
        let top = anchor ?? NSPoint(x: window.frame.minX, y: window.frame.maxY)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: top.x, y: top.y - frame.height)
        if frame != window.frame { window.setFrame(frame, display: window.isVisible) }
    }
    /// Brings a control into view before it is marked or focused: its pane, outside any filter.
    private func reveal(_ view: NSView) {
        guard view.isHiddenOrHasHiddenAncestor,
            let owner = sections.first(where: { view.isDescendant(of: $0.stack) })
        else { return }
        show(owner.pane)
    }
    @objc private func useDefault(_ sender: NSButton) {
        guard form.acceptsActions, rows.indices.contains(sender.tag), let reset = rows[sender.tag].reset else {
            return
        }
        do {
            try reset()
            valuesChanged()
            Announce.say("“\(rows[sender.tag].label)” uses its default.", from: form.window)
        } catch {
            valuesChanged()
            showError(error, field: sender)
        }
    }
    @objc private func performRowAction(_ sender: NSButton) {
        guard form.acceptsActions, rowActions.indices.contains(sender.tag) else { return }
        rowActions[sender.tag]()
    }
    @objc private func toggleMember(_ sender: NSButton) {
        guard memberToggles.indices.contains(sender.tag) else { return }
        let member = memberToggles[sender.tag].member
        do { try write { $0[keyPath: member] = sender.state == .on } } catch {
            valuesChanged()
            showError(error, field: sender)
        }
    }
    @objc private func step(_ sender: NSStepper) {
        guard let field = [widthStepper: width, sizeStepper: size, zoomStepper: zoom, columnStepper: column][sender]
        else { return }
        // The stepper replaces whatever was being typed; it does not commit that draft first.
        field.abortEditing()
        field.stringValue =
            field === size ? NumericInput.editable(sender.doubleValue) : String(Int(sender.doubleValue))
        commitField(field)
    }
    /// A field takes the saved value after its row's Use Default, whatever was typed in it.
    private func adoptField(_ field: NSTextField) {
        field.abortEditing()
        if field === width {
            displayed.tabWidth = owner.value.tabWidth
            width.stringValue = String(displayed.tabWidth)
        } else if field === size {
            displayed.fontSize = owner.value.fontSize
            size.stringValue = NumericInput.editable(displayed.basePointSize)
        } else if field === zoom {
            displayed.defaultZoom = owner.value.defaultZoom
            zoom.stringValue = String(displayed.initialZoom)
        } else if field === column {
            displayed.centeredColumnWidth = owner.value.centeredColumnWidth
            column.stringValue = String(displayed.centeredColumnCharacters)
        }
    }
    /// Shows the file itself, or the folder it will be written to before any setting is changed.
    private func revealSettingsFile() {
        let url = owner.url, folder = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: url.path) {
            StoreRecovery.reveal(url)
        } else if FileManager.default.fileExists(atPath: folder.path) {
            StoreRecovery.reveal(folder)
            let message = "TextTank has not saved a settings file yet. Its folder is shown in Finder."
            owner.onStatus(message)
            Announce.say(message, from: form.window)
        } else {
            showError(LiveError.noFile)
        }
    }
    func retireShortcuts() { shortcuts.retire() }
    /// Preserve partial field-editor input and compare it with its own last displayed setting.
    func valuesChanged() {
        let latest = owner.value
        if let selected = panelSelection, selected.resolvedBaseFont != latest.resolvedBaseFont {
            synchronizeFontPanel()
        }
        func sync<T: Equatable>(
            _ field: NSTextField, _ path: WritableKeyPath<EditorSettings, T>, _ string: (EditorSettings) -> String
        ) {
            guard field.currentEditor() == nil, field.stringValue == string(displayed) else { return }
            field.stringValue = string(latest)
            displayed[keyPath: path] = latest[keyPath: path]
        }
        sync(width, \.tabWidth) { String($0.tabWidth) }
        sync(size, \.fontSize) { NumericInput.editable($0.basePointSize) }
        sync(zoom, \.defaultZoom) { String($0.initialZoom) }
        sync(column, \.centeredColumnWidth) { String($0.centeredColumnCharacters) }
        columnStepper.integerValue = latest.centeredColumnCharacters
        widthStepper.integerValue = latest.tabWidth
        sizeStepper.doubleValue = latest.basePointSize
        zoomStepper.integerValue = latest.initialZoom
        tabs.state = latest.useTabs ? .on : .off
        wrap.state = latest.wrap ? .on : .off
        for toggle in memberToggles {
            toggle.button.state = (latest[keyPath: toggle.member] ?? toggle.standard) ? .on : .off
        }
        appearance.select(appearance.itemArray.first { ($0.representedObject as? String) == latest.appearance })
        diskChanges.select(
            diskChanges.itemArray.first { ($0.representedObject as? String) == latest.diskChangeBehavior.rawValue })
        launchBehavior.selectItem(at: latest.reopensLastSession ? 0 : 1)
        showPreviewOpenMode(latest)
        displayed.previewOpenModes = latest.previewOpenModes
        displayed.reopenLastSession = latest.reopenLastSession
        displayed.externalChangePolicy = latest.externalChangePolicy
        face.stringValue =
            latest.unavailableFontNotice ?? (latest.resolvedBaseFont.displayName ?? latest.resolvedBaseFont.fontName)
        displayed.shortcuts = latest.shortcuts
        shortcuts.reload()
        refreshRows()
    }
    func showViewPreferenceError(_ error: Error) { showError(error) }
    private func showError(_ error: Error, field: NSView? = nil) {
        presentingError = true
        defer { presentingError = false }
        if let field { reveal(field) }
        form.showValidation(error, field: field)
        resizeToContent()
    }
    private func clearError() {
        guard !form.validation.isHidden else { return }
        form.clearValidation()
        resizeToContent()
    }
    private func write(_ update: (inout EditorSettings) throws -> Void) throws {
        guard owner.loadError == nil && owner.ignoredShortcutBindings.isEmpty else { throw LiveError.repair }
        guard try owner.store.fileIsCurrent() else { throw LiveError.changed }
        var latest = owner.value
        try update(&latest)
        if latest != owner.value { try owner.save(latest, requiringCurrent: true) }
        clearError()
    }
    private func merge<T: Equatable>(
        _ value: T, key: WritableKeyPath<EditorSettings, T>, baseline: T,
        into latest: inout EditorSettings
    ) throws {
        guard latest[keyPath: key] == baseline || latest[keyPath: key] == value else { throw LiveError.changed }
        latest[keyPath: key] = value
    }
    @objc private func commitField(_ field: NSTextField) {
        guard form.acceptsActions else { return }
        do {
            try write { latest in
                if field === width {
                    guard let n = NumericInput.integer(width), (1...32).contains(n) else {
                        throw SettingsError.tabWidth
                    }
                    try merge(n, key: \.tabWidth, baseline: displayed.tabWidth, into: &latest)
                } else if field === size {
                    guard let n = NumericInput.number(size), n.isFinite, (6...72).contains(n) else {
                        throw SettingsError.invalidFont
                    }
                    let value = n == displayed.basePointSize ? displayed.fontSize : n
                    try merge(value, key: \.fontSize, baseline: displayed.fontSize, into: &latest)
                } else if field === zoom {
                    guard let n = NumericInput.integer(zoom, signed: true), (-10...60).contains(n) else {
                        throw SettingsError.invalidFont
                    }
                    let value = n == displayed.initialZoom ? displayed.defaultZoom : n
                    try merge(value, key: \.defaultZoom, baseline: displayed.defaultZoom, into: &latest)
                } else if field === column {
                    guard let n = NumericInput.integer(column), EditorSettings.centeredColumnWidths.contains(n) else {
                        throw SettingsError.centeredColumnWidth
                    }
                    let value = n == displayed.centeredColumnCharacters ? displayed.centeredColumnWidth : n
                    try merge(
                        value, key: \.centeredColumnWidth, baseline: displayed.centeredColumnWidth, into: &latest)
                }
            }
            if field === column {
                displayed.centeredColumnWidth = owner.value.centeredColumnWidth
                column.stringValue = String(displayed.centeredColumnCharacters)
            }
            if field === width {
                displayed.tabWidth = owner.value.tabWidth
                width.stringValue = String(displayed.tabWidth)
            }
            if field === size {
                displayed.fontSize = owner.value.fontSize
                size.stringValue = NumericInput.editable(displayed.basePointSize)
            }
            if field === zoom {
                displayed.defaultZoom = owner.value.defaultZoom
                zoom.stringValue = String(displayed.initialZoom)
            }
        } catch { showError(error, field: field) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard form.acceptsActions, !maintenancePending, !presentingError,
            let field = notification.object as? NSTextField, field !== filter,
            notification.userInfo?["NSTextMovement"] as? Int != NSTextMovement.cancel.rawValue
        else { return }
        commitField(field)
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === filter { refreshRows() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) {
            // Escape first clears a search, as it does in any search field; then it closes.
            if control === filter, !filter.stringValue.isEmpty {
                filter.stringValue = ""
                refreshRows()
            } else {
                form.close()
            }
            return true
        }
        return false
    }
    @objc private func toggle(_ sender: NSButton) {
        do {
            try write { if sender === tabs { $0.useTabs = sender.state == .on } else { $0.wrap = sender.state == .on } }
        } catch {
            valuesChanged()
            showError(error, field: sender)
        }
    }
    @objc private func selectAppearance(_ sender: NSPopUpButton) {
        do { try write { $0.appearance = ControlPresentation.selectedID(sender) ?? "system" } } catch {
            valuesChanged()
            showError(error, field: sender)
        }
    }
    @objc private func selectLaunchBehavior(_ sender: NSPopUpButton) {
        guard form.acceptsActions, let key = ControlPresentation.selectedID(sender) else { return }
        let previous = owner.value
        do {
            try owner.store.updateLaunchPreference(
                from: displayed.reopensLastSession, to: key == "restore",
                reservedKeys: SettingsController.reservedShortcuts(in: NSApp.mainMenu))
            owner.apply(replacing: previous)
            valuesChanged()
            clearError()
        } catch {
            valuesChanged()
            showError(error, field: sender)
        }
    }
    @objc private func selectDiskChangePolicy(_ sender: NSPopUpButton) {
        guard form.acceptsActions, let key = ControlPresentation.selectedID(sender),
            let policy = ExternalChangePolicy(rawValue: key)
        else { return }
        let previous = owner.value
        do {
            try owner.store.updateExternalChangePolicy(
                from: displayed.diskChangeBehavior, to: policy,
                reservedKeys: SettingsController.reservedShortcuts(in: NSApp.mainMenu))
            owner.apply(replacing: previous)
            valuesChanged()
            clearError()
        } catch {
            valuesChanged()
            showError(error, field: sender)
        }
    }
    private static func title(_ format: PreviewFormat) -> String {
        switch format {
        case .markdown: return Strings.text("settings.preview.markdown", "Markdown")
        case .html: return Strings.text("settings.preview.html", "HTML")
        case .delimited: return Strings.text("settings.preview.delimited", "CSV and TSV")
        case .svg: return Strings.text("settings.preview.svg", "SVG")
        case .json: return Strings.text("settings.preview.json", "JSON")
        }
    }
    private var selectedPreviewFormat: PreviewFormat {
        ControlPresentation.selectedID(previewFormat).flatMap(PreviewFormat.init(rawValue:)) ?? .markdown
    }
    /// Shows the selected format's choice, and names the format in the second pop-up's
    /// accessibility label, which would otherwise say only "Open in" (DS-70).
    private func showPreviewOpenMode(_ settings: EditorSettings) {
        let format = selectedPreviewFormat
        previewOpenMode.selectItem(
            at: previewOpenMode.indexOfItem(withRepresentedObject: settings.previewOpenMode(for: format).rawValue))
        let label = String(
            format: Strings.text("settings.preview.openIn.label", "Open %@ documents in"), Self.title(format))
        previewOpenMode.setAccessibilityLabel(label)
        previewOpenMode.cell?.setAccessibilityLabel(label)
    }
    @objc private func selectPreviewFormat(_ sender: NSPopUpButton) { showPreviewOpenMode(owner.value) }
    @objc private func selectPreviewOpenMode(_ sender: NSPopUpButton) {
        guard form.acceptsActions,
            let mode = ControlPresentation.selectedID(sender).flatMap(DocumentViewMode.init(rawValue:))
        else { return }
        let format = selectedPreviewFormat, previous = owner.value
        do {
            try owner.store.updatePreviewOpenMode(
                for: format, from: displayed.previewOpenMode(for: format), to: mode,
                reservedKeys: SettingsController.reservedShortcuts(in: NSApp.mainMenu))
            owner.apply(replacing: previous)
            valuesChanged()
            clearError()
        } catch {
            valuesChanged()
            showError(error, field: sender)
        }
    }
    private enum Maintenance { case repair, reset, resetShortcuts }
    private func confirmMaintenance(_ action: Maintenance) {
        guard form.acceptsActions, !maintenancePending, form.window.attachedSheet == nil else { return }
        let prior = owner.value
        // Keep the original file identity even if a View command refreshes the live store
        // while this non-modal confirmation is open.
        let confirmedFile = SettingsStore(
            url: owner.url, reservedKeys: SettingsController.reservedShortcuts(in: NSApp?.mainMenu))
        do {
            guard try owner.store.fileIsCurrent() else { throw LiveError.changed }
        } catch {
            showError(error)
            return
        }
        let alert = TTAlert()
        let title: String
        switch action {
        case .repair:
            alert.messageText = "Repair saved editor settings?"
            alert.informativeText =
                "A backup keeps the original file. The usable settings become the current saved settings."
            title = "Back Up and Repair"
        case .reset:
            alert.messageText = "Reset all editor settings to their defaults?"
            alert.informativeText =
                "This resets font, zoom, indentation, view preferences, how documents with a preview open, launch behavior, appearance and assigned shortcuts."
            title = "Reset Defaults"
        case .resetShortcuts:
            let count = prior.shortcuts.count
            alert.messageText = "Reset all shortcuts to their defaults?"
            alert.informativeText =
                count == 1
                ? "This removes the 1 shortcut you changed. Other settings stay as they are. Undo does not bring it back."
                : "This removes the \(Strings.number(count)) shortcuts you changed. Other settings stay as they are. Undo does not bring them back."
            title = "Reset Shortcuts"
        }
        alert.addButton(withTitle: "Cancel", role: .cancel)
        alert.addButton(withTitle: title).hasDestructiveAction = true
        maintenancePending = true
        alert.beginSheetModal(for: form.window) { [weak self] response in
            guard let self else { return }
            defer { self.maintenancePending = false }
            guard self.form.acceptsActions, response == .alertSecondButtonReturn else { return }
            do {
                guard self.owner.value == prior, try confirmedFile.fileIsCurrent(), try self.owner.store.fileIsCurrent()
                else { throw LiveError.changed }
                switch action {
                case .repair:
                    if let backup = try self.owner.save(prior, replacingUnreadable: true) {
                        let message = "Settings repaired. The original file is saved as “\(backup.lastPathComponent)”."
                        self.owner.onStatus(message)
                        Announce.say(message)
                    }
                case .reset:
                    try self.write { $0 = EditorSettings() }
                case .resetShortcuts:
                    try self.write {
                        $0.shortcuts = [:]
                        $0.version = $0.requiredVersion
                    }
                    self.shortcuts.didResetAll()
                    return
                }
                guard self.form.acceptsActions else { return }
                self.form.close()
                self.owner.showSettings(nil)
            } catch { self.showError(error) }
        }
    }
    @objc private func openFontPanel(_ sender: Any?) {
        let manager = NSFontManager.shared
        if let other = manager.target as? LiveSettingsForm, other !== self { other.releaseFontPanel() }
        if panel != nil && manager.target as AnyObject? !== self { releaseFontPanel() }
        guard let shared = manager.fontPanel(true) else { return }
        if panel == nil {
            previousTarget = manager.target as AnyObject?
            previousAction = manager.action
            previousDelegate = shared.delegate
            previousFont = manager.selectedFont
            previousMultiple = manager.isMultiple
            panelWasVisible = shared.isVisible
            panel = shared
            shared.delegate = self
            manager.target = self
            manager.action = #selector(changeFont(_:))
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyWindowChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
            synchronizeFontPanel()
            manager.orderFrontFontPanel(sender)
            configureFontCollection(in: shared)
        } else {
            synchronizeFontPanel()
            manager.orderFrontFontPanel(sender)
        }
    }
    /// Keep the conversion baseline and the system chooser's actual selection together.
    private func synchronizeFontPanel() {
        let manager = NSFontManager.shared
        guard panel != nil, manager.target as AnyObject? === self, !convertingFont else { return }
        panelSelection = owner.value
        manager.setSelectedFont(owner.value.resolvedBaseFont, isMultiple: false)
    }
    @objc private func keyWindowChanged(_ note: Notification) {
        guard let window = note.object as? NSWindow, window !== form.window, window !== panel else { return }
        releaseFontPanel()
    }
    /// Named collections are process-scoped. Discover the panel's native collection control
    /// from the menu items' public collection IDs, independent of localization and order.
    private func collectionControl(_ name: String, in panel: NSFontPanel) -> (NSPopUpButton, NSMenuItem)? {
        let popups = panel.toolbar?.items.compactMap { $0.view as? NSPopUpButton } ?? []
        for popup in popups {
            popup.menu?.update()
            if let item = popup.itemArray.last(where: { ($0.representedObject as? String) == name }) {
                return (popup, item)
            }
        }
        return nil
    }
    private func selectCollection(_ item: NSMenuItem, in popup: NSPopUpButton) {
        guard let menu = popup.menu else { return }
        popup.select(item)
        menu.performActionForItem(at: menu.index(of: item))
    }
    private func configureFontCollection(in panel: NSFontPanel) {
        let plainName = NSFontCollection.Name("TextTank Fixed-Pitch Fonts")
        let name =
            NSFontCollection.allFontCollectionNames.contains(plainName)
            ? NSFontCollection.Name(plainName.rawValue + " " + UUID().uuidString) : plainName
        let query = NSFontDescriptor(fontAttributes: [
            .traits: [NSFontDescriptor.TraitKey.symbolic: NSFontDescriptor.SymbolicTraits.monoSpace.rawValue]
        ])
        do {
            try NSFontCollection.show(NSFontCollection(descriptors: [query]), withName: name, visibility: .process)
            fixedCollection = name
            if let (popup, item) = collectionControl(name.rawValue, in: panel) {
                previousCollection =
                    (popup.selectedItem?.representedObject ?? popup.itemArray.first?.representedObject) as? String
                selectCollection(item, in: popup)
                return
            }
        } catch {
            // Older panel layouts also support their family-filter delegate.
        }
        previousAccessory = panel.accessoryView
        fixedPitch.state = .on
        fixedPitch.target = self
        fixedPitch.action = #selector(filterFonts(_:))
        fixedPitch.identifier = .init("settings.font.fixed")
        ControlPresentation.label("Fixed-pitch fonts only", control: fixedPitch)
        panel.accessoryView = fixedPitch
        filterFonts(nil)
    }
    @objc private func filterFonts(_ sender: Any?) {
        let enabled = fixedPitch.state == .on
        legacyFilter.withLock { $0 = enabled }
        panel?.reloadDefaultFontFamilies()
    }
    nonisolated override func fontManager(_ sender: Any, willIncludeFont name: String) -> Bool {
        !legacyFilter.withLock { $0 } || NSFont(name: name, size: 14)?.isFixedPitch == true
    }
    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask { [.face, .size] }
    func changeFont(_ sender: NSFontManager?) {
        guard let manager = sender, manager === NSFontManager.shared, manager.target as AnyObject? === self,
            panel?.isVisible == true, form.window.isVisible, let selected = panelSelection
        else { return }
        convertingFont = true
        defer { convertingFont = false }
        let font = manager.convert(selected.resolvedBaseFont)
        do {
            try write { latest in
                if font.fontName != selected.resolvedBaseFont.fontName {
                    try merge(font.fontName, key: \.fontName, baseline: selected.fontName, into: &latest)
                }
                if font.pointSize != selected.resolvedBaseFont.pointSize {
                    try merge(font.pointSize, key: \.fontSize, baseline: selected.fontSize, into: &latest)
                }
            }
            panelSelection = owner.value
        } catch {
            showError(error)
            // AppKit finishes its conversion after changeFont returns.
            Task { @MainActor [weak self] in
                guard let self, manager.target as AnyObject? === self else { return }
                self.synchronizeFontPanel()
            }
        }
    }
    func windowWillClose(_ note: Notification) {
        if note.object as? NSWindow === panel { releaseFontPanel(closing: true) }
    }
    func releaseFontPanel(closing: Bool = false) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard let shared = panel else { return }
        panel = nil
        panelSelection = nil
        let manager = NSFontManager.shared
        let owned = manager.target as AnyObject? === self
        let usedLegacyFilter = legacyFilter.withLock { enabled in
            defer { enabled = false }
            return enabled
        }
        if owned, let previousCollection, let (popup, item) = collectionControl(previousCollection, in: shared) {
            selectCollection(item, in: popup)
        }
        previousCollection = nil
        if let fixedCollection {
            try? NSFontCollection.hide(withName: fixedCollection, visibility: .process)
            self.fixedCollection = nil
        }
        if shared.accessoryView === fixedPitch { shared.accessoryView = previousAccessory }
        if shared.delegate === self {
            shared.delegate = previousDelegate
            // The shared panel tears down its family browser before windowWillClose.
            // Only a still-open panel with an active delegate filter needs rebuilding.
            if usedLegacyFilter && !closing { shared.reloadDefaultFontFamilies() }
        }
        if owned {
            if let previousFont { manager.setSelectedFont(previousFont, isMultiple: previousMultiple) }
            manager.target = previousTarget
            if let previousAction { manager.action = previousAction }
            if !panelWasVisible && !closing { shared.orderOut(nil) }
        }
        previousAccessory = nil
        previousFont = nil
    }
    private enum LiveError: LocalizedError {
        case repair, changed, noFile
        var errorDescription: String? {
            switch self {
            case .noFile:
                return
                    "TextTank has not saved a settings file yet, so there is nothing to show in Finder. The file is created when you change a setting."
            case .repair: return "Use Repair Settings to back up the original file before changing these settings."
            case .changed:
                return
                    "The saved configuration changed while this window was open. Close and reopen Settings to review the latest value."
            }
        }
    }
}
