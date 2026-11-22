import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os

@MainActor private final class SettingsShortcutEditor: NSObject {
    var draft: SettingsShortcutDraft
    let popup = NSPopUpButton()
    let key = NSTextField(string: "")
    init(_ settings: EditorSettings) {
        draft = .init(settings)
        super.init()
        for command in EditorCommand.allCases.filter(\.isShortcutAssignable).sorted(by: { $0.title < $1.title }) {
            popup.addItem(withTitle: command.title)
            popup.lastItem?.representedObject = command.rawValue
        }
        popup.target = self
        popup.action = #selector(selectCommand(_:))
        ControlPresentation.label("Command shortcut to assign", control: popup)
        popup.identifier = NSUserInterfaceItemIdentifier("settings.shortcut.command")
        key.stringValue = settings.shortcut(for: draft.selected)
        key.placeholderString = "No custom shortcut"
        ControlPresentation.label("Shortcut key", control: key)
        key.identifier = NSUserInterfaceItemIdentifier("settings.shortcut.key")
    }
    @objc func selectCommand(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        let pending = key.currentEditor()?.string ?? key.stringValue
        sender.window?.makeFirstResponder(sender)
        if draft.selected != id {
            key.setAccessibilityHelp(nil)
            key.toolTip = nil
        }
        key.stringValue = draft.select(id, committing: pending)
    }
    @objc func clearShortcut(_ sender: Any?) {
        key.window?.makeFirstResponder(popup)
        key.stringValue = draft.clear()
    }
    func revealValidation(_ failure: ShortcutValidationFailure) -> NSView? {
        guard let item = popup.itemArray.first(where: { $0.representedObject as? String == failure.command }) else {
            return nil
        }
        popup.select(item)
        key.stringValue = draft.select(failure.command, committing: key.stringValue)
        return key
    }
    func rebase(_ value: EditorSettings) {
        let selected = draft.selected
        draft = SettingsShortcutDraft(value)
        key.stringValue = draft.select(selected, committing: value.shortcut(for: draft.selected))
    }
    func settings() -> EditorSettings {
        draft.commit(key.stringValue)
        return draft.settings
    }
}

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
    fileprivate var store: SettingsStore
    var value: EditorSettings { store.value }
    var ignoredShortcutBindings: [ShortcutLoadIssue] { store.ignoredShortcutBindings }
    var shortcutLoadNotice: String? { store.shortcutLoadNotice }
    var loadState: StoreLoadState { store.loadState }
    var loadError: Error? { store.loadError }
    var url: URL { store.url }
    var loadFailureMessage: String? { store.loadFailureMessage }
    private let onApply: @MainActor (EditorSettings, EditorSettings?) -> Void
    fileprivate let onStatus: @MainActor (String) -> Void
    init(
        url: URL? = nil, onApply: @escaping @MainActor (EditorSettings, EditorSettings?) -> Void = { _, _ in },
        onStatus: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        store = SettingsStore(url: url, reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
        self.onApply = onApply
        self.onStatus = onStatus
        super.init()
    }
    func reconcileShortcuts(with menu: NSMenu) {
        store.reconcileShortcuts(reservedKeys: Self.reservedShortcuts(in: menu))
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
        editor.braceHighlightEnabled = value.braceHighlightEnabled
        editor.currentLineHighlightEnabled = value.currentLineHighlightEnabled
        editor.indentGuidesEnabled = value.indentGuidesEnabled
        editor.wrap = value.wrap
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAutoIndent(_:)) {
            item.state = value.autoIndentEnabled ? .on : .off
        } else if item.action == #selector(toggleBraceHighlight(_:)) {
            item.state = value.braceHighlightEnabled ? .on : .off
        } else if item.action == #selector(toggleCurrentLineHighlight(_:)) {
            item.state = value.currentLineHighlightEnabled ? .on : .off
        } else if item.action == #selector(toggleIndentGuides(_:)) {
            item.state = value.indentGuidesEnabled ? .on : .off
        }
        return true
    }
    @objc func toggleAutoIndent(_ sender: Any?) { updateViewPreference(.autoIndent, sender: sender) }
    @objc func toggleBraceHighlight(_ sender: Any?) { updateViewPreference(.braceHighlight, sender: sender) }
    @objc func toggleCurrentLineHighlight(_ sender: Any?) {
        updateViewPreference(.currentLineHighlight, sender: sender)
    }
    @objc func toggleIndentGuides(_ sender: Any?) { updateViewPreference(.indentGuides, sender: sender) }
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
        store = SettingsStore(url: url, reservedKeys: Self.reservedShortcuts(in: NSApp?.mainMenu))
        if value != previous { apply(replacing: previous) }
        let live = LiveSettingsForm(owner: self)
        liveForm = live
        live.form.onClose = { [weak self, weak live] in
            live?.releaseFontPanel()
            self?.liveForm = nil
        }
        live.form.show()
    }
}

@MainActor private final class LiveSettingsForm: NSObject, NSTextFieldDelegate, NSWindowDelegate, NSFontChanging {
    let owner: SettingsController
    let form = FormPanel(title: "Settings", identifier: "TextTank.Settings", size: NSSize(width: 600, height: 550))
    private let width = NSTextField(), size = NSTextField(), zoom = NSTextField()
    private let tabs = NSButton(checkboxWithTitle: "Indent with tabs", target: nil, action: nil)
    private let wrap = NSButton(checkboxWithTitle: "Wrap lines", target: nil, action: nil)
    private let appearance = NSPopUpButton()
    private let face = NSTextField(labelWithString: "")
    private let fontButton = NSButton(title: "Font…", target: nil, action: nil)
    private let shortcuts: SettingsShortcutEditor
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
        shortcuts = SettingsShortcutEditor(owner.value)
        super.init()
        build()
    }
    private func build() {
        form.note(
            "Changes apply when you finish editing a control. Shortcut keys use Command. An uppercase shortcut adds Shift."
        )
        if let notice = owner.value.unavailableFontNotice { form.note(notice) }
        if let notice = owner.shortcutLoadNotice { form.note(notice) }
        if owner.loadError != nil {
            form.note("The saved settings could not be read. Repair Settings keeps a backup of the original file.")
        }
        func row(_ label: String, _ control: NSControl, _ identifier: String) -> NSStackView {
            let caption = NSTextField(labelWithString: label)
            ControlPresentation.label(label, control: control, caption: caption)
            caption.widthAnchor.constraint(equalToConstant: 160).isActive = true
            control.identifier = NSUserInterfaceItemIdentifier(identifier)
            let group = NSStackView(views: [caption, control])
            group.alignment = .firstBaseline
            return group
        }
        NumericInput.configure(width)
        NumericInput.configure(size, fractional: true)
        NumericInput.configure(zoom)
        for field in [width, size, zoom, shortcuts.key] {
            field.target = self
            field.action = #selector(commitField(_:))
            field.delegate = self
        }
        width.stringValue = String(displayed.tabWidth)
        size.stringValue = NumericInput.editable(displayed.basePointSize)
        zoom.stringValue = String(displayed.initialZoom)
        form.add(row("Tab width", width, "settings.width"))
        tabs.identifier = .init("settings.tabs")
        wrap.identifier = .init("settings.wrap")
        tabs.target = self
        tabs.action = #selector(toggle(_:))
        wrap.target = self
        wrap.action = #selector(toggle(_:))
        ControlPresentation.label("Indent with tabs", control: tabs)
        ControlPresentation.label("Wrap lines", control: wrap)
        form.add(NSStackView(views: [tabs, wrap]))
        ControlPresentation.populate(
            appearance, choices: [("system", "System"), ("light", "Light"), ("dark", "Dark")],
            selected: displayed.appearance)
        appearance.target = self
        appearance.action = #selector(selectAppearance(_:))
        form.add(row("Appearance", appearance, "settings.appearance"))
        fontButton.target = self
        fontButton.action = #selector(openFontPanel(_:))
        fontButton.identifier = .init("settings.font.choose")
        ControlPresentation.label("Choose editor font in Settings", control: fontButton)
        form.add(NSStackView(views: [fontButton, face]))
        form.add(row("Font size (points)", size, "settings.font.size"))
        form.add(row("Default zoom", zoom, "settings.font.zoom"))
        form.add(row("Command shortcut to assign", shortcuts.popup, "settings.shortcut.command"))
        form.add(row("Shortcut key", shortcuts.key, "settings.shortcut.key"))
        let clear = NSButton(title: "Clear Custom Shortcut", target: self, action: #selector(clearShortcut(_:)))
        clear.identifier = .init("settings.shortcut.clear")
        ControlPresentation.label("Clear the selected command's custom shortcut", control: clear)
        form.add(clear)
        if owner.loadError != nil || !owner.ignoredShortcutBindings.isEmpty {
            form.button("Repair Settings…", identifier: "settings.repair") { [weak self] in
                self?.confirmMaintenance(.repair)
            }
        }
        form.button("Apply Shortcuts", identifier: "settings.shortcuts.apply") { [weak self] in self?.commitShortcuts()
        }
        form.button("Reset Defaults…", identifier: "settings.reset") { [weak self] in self?.confirmMaintenance(.reset) }
        form.button("Close", identifier: "settings.close", cancel: true) { [weak self] in self?.form.close() }
        form.window.initialFirstResponder = width
        form.window.contentMinSize = NSSize(width: 560, height: max(490, form.body.fittingSize.height + 140))
        valuesChanged()
    }
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
        tabs.state = latest.useTabs ? .on : .off
        wrap.state = latest.wrap ? .on : .off
        appearance.select(appearance.itemArray.first { ($0.representedObject as? String) == latest.appearance })
        face.stringValue =
            latest.unavailableFontNotice ?? (latest.resolvedBaseFont.displayName ?? latest.resolvedBaseFont.fontName)
        if shortcuts.key.currentEditor() == nil,
            shortcuts.key.stringValue == shortcuts.draft.settings.shortcut(for: shortcuts.draft.selected),
            shortcuts.draft.settings.shortcuts == displayed.shortcuts
        {
            shortcuts.rebase(latest)
            displayed.shortcuts = latest.shortcuts
        }
    }
    func showViewPreferenceError(_ error: Error) { showError(error) }
    private func showError(_ error: Error, field: NSView? = nil) {
        presentingError = true
        defer { presentingError = false }
        form.showValidation(error, field: field)
    }
    private func write(_ update: (inout EditorSettings) throws -> Void) throws {
        guard owner.loadError == nil && owner.ignoredShortcutBindings.isEmpty else { throw LiveError.repair }
        guard try owner.store.fileIsCurrent() else { throw LiveError.changed }
        var latest = owner.value
        try update(&latest)
        if latest != owner.value { try owner.save(latest, requiringCurrent: true) }
        form.clearValidation()
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
        if field === shortcuts.key {
            commitShortcuts()
            return
        }
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
                }
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
            let field = notification.object as? NSTextField,
            notification.userInfo?["NSTextMovement"] as? Int != NSTextMovement.cancel.rawValue
        else { return }
        if field === shortcuts.key { commitShortcuts(reveal: false) } else { commitField(field) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) {
            form.close()
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
    @objc private func clearShortcut(_ sender: Any?) {
        shortcuts.clearShortcut(sender)
        commitShortcuts(reveal: false)
    }
    private func commitShortcuts(reveal: Bool = true) {
        let candidate = shortcuts.settings(), initial = displayed.shortcuts
        do {
            try write { latest in
                for command in Set(candidate.shortcuts.keys).union(initial.keys)
                where candidate.shortcuts[command] != initial[command] {
                    guard
                        latest.shortcuts[command] == initial[command]
                            || latest.shortcuts[command] == candidate.shortcuts[command]
                    else { throw LiveError.changed }
                    latest.shortcuts[command] = candidate.shortcuts[command]
                }
                if let failure = latest.shortcutValidationFailure(
                    reservedKeys: SettingsController.reservedShortcuts(in: NSApp.mainMenu))
                {
                    throw failure
                }
            }
            displayed.shortcuts = owner.value.shortcuts
            shortcuts.rebase(owner.value)
        } catch let failure as ShortcutValidationFailure {
            showError(failure, field: reveal ? shortcuts.revealValidation(failure) : nil)
        } catch { showError(error, field: shortcuts.key) }
    }
    private enum Maintenance { case repair, reset }
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
                "This resets font, zoom, indentation, view preferences, appearance and assigned shortcuts."
            title = "Reset Defaults"
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
        case repair, changed
        var errorDescription: String? {
            switch self {
            case .repair: return "Use Repair Settings to back up the original file before changing these settings."
            case .changed:
                return
                    "The saved configuration changed while this window was open. Close and reopen Settings to review the latest value."
            }
        }
    }
}
