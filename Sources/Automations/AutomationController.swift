import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin

/// Runs a block on the main thread through the main run loop in the common modes, which include
/// modal panels and event tracking. Unlike the main dispatch queue, this still delivers while a
/// main-queue block or main-actor job is itself inside a nested modal run loop.
enum MainRunLoop {
    static func perform(_ block: @escaping @MainActor @Sendable () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            precondition(Thread.isMainThread)
            MainActor.assumeIsolated { block() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

extension Notification.Name {
    static let textTankAutomationsDidChange = Notification.Name("TextTankAutomationsDidChange")
}

/// Remember how an unchecked optional was represented while a native checkbox is turned on.
/// Advanced JSON owns explicit values and can replace or remove individual workflows.
private struct AutomationCheckboxEdits {
    private var previouslyOmitted = Set<UUID>()

    mutating func value(_ enabled: Bool, replacing stored: Bool?, id: UUID) -> Bool? {
        guard enabled != (stored == true) else { return stored }
        if enabled {
            if stored == nil { previouslyOmitted.insert(id) } else { previouslyOmitted.remove(id) }
            return true
        }
        return previouslyOmitted.remove(id) == nil ? false : nil
    }

    mutating func remove(_ id: UUID) { previouslyOmitted.remove(id) }

    mutating func reconcile(_ library: AutomationLibrary, flag: KeyPath<AutomationDefinition, Bool?>) {
        previouslyOmitted.formIntersection(library.workflows.lazy.filter { $0[keyPath: flag] == true }.map(\.id))
    }
}

@MainActor final class AutomationController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    /// Independent isolated compositions must not share AppKit toolbar synchronization state.
    let toolbarFamilyIdentifier = UUID().uuidString
    private let editorProvider: () -> TTEditor?
    /// Called once each time a saved automation starts to run, before any prompt or change.
    var onInvocation: () -> Void = {}
    private let newDocument: @MainActor (String) -> Void
    private let storage: URL
    private var library = AutomationLibrary(workflows: [])
    weak var saveAllShortcutItem: NSMenuItem? { didSet { updateSaveAllShortcut() } }
    private func updateSaveAllShortcut() {
        let key = MenuShortcut.saveAll.key
        saveAllShortcutItem?.keyEquivalent = library.workflows.contains { $0.shortcut == key } ? "" : key
    }
    /// An existing library that could not be read. It is never overwritten; see `persistLibrary`.
    let loadState: StoreLoadState
    private var loadError: Error? {
        get { loadState.error }
        set { loadState.error = newValue }
    }
    /// No library existed and the first write of the presets failed. This does not block saving.
    private var installError: Error?
    private var installErrorReported = false
    private var busy = false {
        didSet {
            manager?.refresh()
            palette?.refresh()
        }
    }
    private var runControl: AutomationRunControl?
    var comparisonService: () -> CompareService? = { nil }
    /// The pasteboard used for clipboard input and output. Checks substitute a private one.
    var pasteboard: NSPasteboard?
    private var activePasteboard: NSPasteboard? { pasteboard ?? RuntimeEnvironment.current.generalPasteboard() }
    /// Internal, not private, so that a check can hold an export open without EventKit.
    var exportInProgress = false {
        didSet {
            manager?.refresh()
            palette?.refresh()
        }
    }
    /// Says why an automation command cannot start while a Reminders export is running.
    private func requireNoExport() throws {
        if exportInProgress {
            throw AutomationError.invalid(
                "A Reminders export is in progress. Try again when it has finished. Nothing was changed.")
        }
    }
    /// The same for commands that do not throw. `busy` alone stays a silent guard: it is only
    /// set while one of this controller's own dialogs is open, which is itself the visible reason,
    /// and a second dialog must never be stacked on the first.
    private func idleOrExplain() -> Bool {
        guard !busy else { return false }
        do { try requireNoExport() } catch {
            showError(error)
            return false
        }
        return true
    }
    private var exportTask: Task<Void, Never>?
    private lazy var automationMenu: NSMenu = {
        let m = NSMenu(title: "Automations")
        m.delegate = self
        return m
    }()

    init(editorProvider: @escaping () -> TTEditor?, newDocument: @escaping @MainActor (String) -> Void) {
        self.editorProvider = editorProvider
        self.newDocument = newDocument
        storage = AppStorage.url(.automations)
        loadState = StoreLoadState(url: storage, displayName: "Saved automations")
        super.init()
        var storageInfo = stat()
        if lstat(storage.path, &storageInfo) == 0 {
            do {
                library = try AutomationLibrary.decode(
                    AutomationFileInput.readData(storage, limit: AutomationLibrary.maximumBytes, parent: .strict))
            } catch { loadError = error }
        } else if errno != ENOENT {
            loadError = FileOperationFailure(errno, operation: "inspect saved automations", path: storage.path)
        } else {
            // Presets are ordinary editable definitions, installed only for a new configuration.
            // There is no library to protect here, so a failed first write does not block the
            // session: the presets stay in memory and the next save writes them.
            library = AutomationLibrary(workflows: AutomationDefinition.firstRunPresets)
            do { try persistLibrary(library) } catch { installError = error }
        }
    }
    /// The first write of the starting automations failed. Tries again; if it still fails, says so
    /// once and lets the session carry on with the automations held in memory.
    private func retryInstall() {
        guard installError != nil else { return }
        do { try persistLibrary(library) } catch {
            installError = error
            guard !installErrorReported else { return }
            installErrorReported = true
            showError(
                AutomationError.invalid(
                    "The starting automations could not be saved yet: \(error.localizedDescription)\nThey stay available until you quit, and the next change you save is written again."
                ))
        }
    }
    func menu() -> NSMenu {
        rebuild()
        return automationMenu
    }
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === automationMenu { rebuild() } else { populateInvocations(menu) } }
    /// Fresh menus all dispatch by stable ID and resolve the currently saved definition at invocation.
    func contextMenu() -> NSMenu { invocationMenu(title: "Run Automation") }
    func makeToolbarItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .init("TextTank.Automations"))
        item.label = Strings.text("toolbar.automations", "Automations")
        item.paletteLabel = item.label
        let description = Strings.text("toolbar.automations.help", "Run a saved automation or manage automations.")
        item.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: description)
        item.toolTip = description
        refreshToolbarItem(item)
        return item
    }
    func refreshToolbarItem(_ item: NSMenuToolbarItem) {
        item.menu = invocationMenu(title: "Automations", launcher: true)
    }
    private func canInvoke(_ id: UUID) -> Bool { canInvoke(id, editor: editorProvider()) }
    private func canInvoke(_ id: UUID, editor: TTEditor?) -> Bool {
        guard !busy, !exportInProgress, let workflow = library.workflows.first(where: { $0.id == id }) else {
            return false
        }
        if (workflow.input == .document || workflow.input == .selection) && editor == nil { return false }
        if (workflow.output == .editor || workflow.output == .previewChanges) && (editor == nil || editor?.readOnly == true) { return false }
        return true
    }
    /// Every menu, shortcut, toolbar and palette resolves the current saved definition by UUID.
    func runSavedAutomation(id: UUID) throws {
        guard !busy else { return }
        try requireNoExport()
        guard let workflow = library.workflows.first(where: { $0.id == id }) else {
            throw AutomationError.invalid("This automation no longer exists.")
        }
        busy = true
        defer { busy = false }
        try run(workflow, target: AutomationDocumentTarget(editorProvider()))
    }
    private func invocationMenu(title: String, launcher: Bool = false) -> NSMenu {
        let result = NSMenu(title: title)
        if launcher { result.identifier = .init("TextTank.AutomationLauncher") }
        result.delegate = self
        populateInvocations(result)
        return result
    }
    private func populateInvocations(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.identifier?.rawValue == "TextTank.AutomationLauncher" {
            menu.addItem(withTitle: "Automations", action: nil, keyEquivalent: "")
        }
        for workflow in library.workflows.sorted(by: {
            ($0.pinToToolbar == true ? 0 : 1) < ($1.pinToToolbar == true ? 0 : 1)
        }) {
            let item = NSMenuItem(
                title: (workflow.pinToToolbar == true ? "★ " : "") + workflow.name, action: #selector(runAction(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = workflow.id.uuidString
            menu.addItem(item)
        }
        let manage = NSMenuItem(title: "Manage Automations…", action: #selector(manageAction), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }
    private var palette: ChoicePanel?
    @MainActor func showPalette() {
        if let palette {
            palette.form.window.makeKeyAndOrderFront(nil)
            return
        }
        guard idleOrExplain() else { return }
        guard !library.workflows.isEmpty else {
            manage()
            return
        }
        let panel = ChoicePanel(
            title: "Run Automation", identifier: "automation.palette", action: "Run",
            filterLabel: "Filter automations by name")
        palette = panel
        panel.retainController(self)
        var watches: [NSObjectProtocol] = []
        panel.onClose = { [weak self] in
            for token in watches { NotificationCenter.default.removeObserver(token) }
            watches.removeAll()
            self?.palette = nil
        }
        for name in [Notification.Name.TTEditorStateDidChange, .TTEditorWillRetire] {
            watches.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak panel] _ in
                    precondition(Thread.isMainThread)
                    MainActor.assumeIsolated {
                        MainRunLoop.perform { [weak panel] in panel?.refresh() }
                    }
                })
        }
        panel.rows = { [weak self] in self?.library.workflows.map { .init(id: $0.id.uuidString, title: $0.name) } ?? []
        }
        panel.canChoose = { [weak self, weak panel] in
            guard let self, let text = panel?.selectedID, let id = UUID(uuidString: text) else { return false }
            return self.canInvoke(id, editor: self.editorProvider())
        }
        panel.choose = { [weak self] id in
            guard let self, !self.busy, !self.exportInProgress else { throw FormFailure.busy }
            guard let workflow = self.library.workflows.first(where: { $0.id.uuidString == id }) else {
                throw FormFailure.changed
            }
            self.busy = true
            defer { self.busy = false }
            try self.run(workflow, target: AutomationDocumentTarget(self.editorProvider()))
            return true
        }
        panel.show()
    }
    private func rebuild() {
        updateSaveAllShortcut()
        automationMenu.removeAllItems()
        let manage = NSMenuItem(title: "Manage Automations…", action: #selector(manageAction), keyEquivalent: "")
        manage.target = self
        automationMenu.addItem(manage)
        // The one entry for the palette, with its shortcut (Shift-Command-P).
        let palette = NSMenuItem(title: "Automation Palette…", action: #selector(paletteAction), keyEquivalent: "P")
        palette.target = self
        automationMenu.addItem(palette)
        let history = NSMenuItem(
            title: "Review Reminder Export History…", action: #selector(reminderHistory), keyEquivalent: "")
        history.target = self
        automationMenu.addItem(history)
        let restore = NSMenuItem(
            title: "Restore Default Automations…", action: #selector(restoreDefaultsAction), keyEquivalent: "")
        restore.target = self
        automationMenu.addItem(restore)
        if !library.workflows.isEmpty { automationMenu.addItem(.separator()) }
        for workflow in library.workflows {
            let item = NSMenuItem(
                title: workflow.name, action: #selector(runAction(_:)), keyEquivalent: workflow.shortcut ?? "")
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            item.representedObject = workflow.id.uuidString
            automationMenu.addItem(item)
        }
    }
    @MainActor @objc private func manageAction() { manage() }
    @MainActor @objc private func paletteAction() { showPalette() }
    @objc private func restoreDefaultsAction() { restoreDefaultAutomations() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(restoreDefaultsAction) { return !busy && !exportInProgress }
        if menuItem.action == #selector(runAction(_:)) {
            guard let value = menuItem.representedObject as? String, let id = UUID(uuidString: value) else {
                return false
            }
            return canInvoke(id)
        }
        return true
    }
    /// A picker with one item for every automation, in order. Items are built as menu items,
    /// because `addItem(withTitle:)` removes an earlier item with the same title and two
    /// automations may share a name. Each item carries its automation's UUID.
    private var manager: LibraryManager?
    private var advancedAction: (() -> Void)?
    @MainActor func manage() {
        if let manager {
            manager.form.window.makeKeyAndOrderFront(nil)
            return
        }
        guard idleOrExplain() else { return }
        do {
            guard try StoreRecovery.ensureWritable(loadState) else { return }
            retryInstall()
            var working = library
            let baseline = try SavedConfiguration.bytes(library)
            let panel = LibraryManager(title: "Manage Automations", identifier: "automation.manager") {
                (try? SavedConfiguration.bytes(working)) != baseline
            }
            manager = panel
            panel.retainController(self)
            panel.onClose = { [weak self] in
                self?.advancedAction = nil
                self?.manager = nil
            }
            panel.rows = { working.workflows.map { .init(id: $0.id, name: $0.name) } }
            panel.canEdit = { [weak self] in self.map { !$0.busy && !$0.exportInProgress } ?? false }
            panel.rename = { id, name in
                if let i = working.workflows.firstIndex(where: { $0.id == id }) { working.workflows[i].name = name }
            }
            let originalIDs = Set(library.workflows.map(\.id))
            var favoriteEdits = AutomationCheckboxEdits()
            var previewEdits = AutomationCheckboxEdits()
            var confirmedEmpty: Data?
            panel.save = { [weak self, weak panel] in
                guard let self, let panel, !self.busy, !self.exportInProgress else { throw FormFailure.busy }
                for definition in working.workflows {
                    do { try definition.validate() } catch {
                        panel.reveal(definition.id)
                        throw error
                    }
                }
                try working.validate()
                try self.checkShortcutCollisions(working)
                try SavedConfiguration.requireUnchanged(self.library, since: baseline)
                let empty = working.workflows.filter { !originalIDs.contains($0.id) && $0.steps.isEmpty }
                let emptyBytes = try SavedConfiguration.bytes(empty)
                if !empty.isEmpty && confirmedEmpty != emptyBytes {
                    let confirm = TTAlert()
                    confirm.messageText =
                        empty.count == 1 ? "Save an automation with no rules?" : "Save automations with no rules?"
                    confirm.informativeText =
                        "These automations will pass text through unchanged until rules are added. Saving never runs them."
                    confirm.addButton(withTitle: "Save Without Rules").identifier = NSUserInterfaceItemIdentifier(
                        "automation.settings.saveEmpty")
                    confirm.addButton(withTitle: "Cancel", role: .cancel)
                    confirm.beginSheetModal(for: panel.form.window) { response in
                        guard response == .alertFirstButtonReturn else { return }
                        confirmedEmpty = emptyBytes
                        panel.refresh()
                        panel.saveChanges()
                    }
                    return false
                }
                guard try StoreRecovery.ensureWritable(self.loadState) else { return false }
                try SavedConfiguration.requireUnchanged(self.library, since: baseline)
                let changed = try SavedConfiguration.bytes(working) != baseline
                if changed || self.installError != nil || !FileManager.default.fileExists(atPath: self.storage.path) {
                    try self.persistLibrary(working)
                }
                return true
            }
            func settings(_ initial: AutomationDefinition, creating: Bool) {
                let pendingBaseline = try? SavedConfiguration.bytes(working)
                self.editSettings(of: initial, creating: creating, parent: panel.form.window) { candidate in
                    guard let pendingBaseline else { throw FormFailure.changed }
                    try SavedConfiguration.requireUnchanged(working, since: pendingBaseline)
                    var updated = working
                    let index: Int
                    if let existing = updated.workflows.firstIndex(where: { $0.id == candidate.id }) {
                        index = existing
                        updated.workflows[index] = candidate
                    } else if creating {
                        index = updated.workflows.count
                        updated.workflows.append(candidate)
                    } else {
                        throw FormFailure.changed
                    }
                    try updated.validate()
                    try self.checkShortcutCollisions(updated)
                    updated.workflows[index].pinToToolbar = favoriteEdits.value(
                        candidate.pinToToolbar == true, replacing: initial.pinToToolbar, id: initial.id)
                    updated.workflows[index].previewBeforeApply = previewEdits.value(
                        candidate.previewBeforeApply == true, replacing: initial.previewBeforeApply, id: initial.id)
                    working = updated
                    panel.reload(select: candidate.id)
                }
            }
            panel.action("Add…", identifier: "automation.create") {
                settings(
                    AutomationDefinition(
                        id: UUID(), name: "My Automation", input: .document, steps: [], output: .editor,
                        pinToToolbar: false), creating: true)
            }
            panel.action("Edit…", identifier: "automation.edit", needsSelection: true) { [weak panel] in
                guard let id = panel?.selectedID, let definition = working.workflows.first(where: { $0.id == id })
                else { return }
                settings(definition, creating: false)
            }
            panel.action("Edit Rules…", identifier: "automation.rules", needsSelection: true) { [weak panel] in
                guard let panel, let id = panel.selectedID,
                    let definition = working.workflows.first(where: { $0.id == id })
                else { return }
                let pendingBaseline = try? SavedConfiguration.bytes(working)
                AutomationStepEditor.present(definition, savedWorkflows: working.workflows, parent: panel.form.window) {
                    revised in
                    guard let revised, panel.form.window.isVisible else { return }
                    do {
                        guard let pendingBaseline else { throw FormFailure.changed }
                        try SavedConfiguration.requireUnchanged(working, since: pendingBaseline)
                        guard let index = working.workflows.firstIndex(where: { $0.id == id }) else {
                            throw FormFailure.changed
                        }
                        working.workflows[index].steps = revised.steps
                        working.workflows[index].name = revised.name
                        panel.reload(select: id)
                    } catch { panel.form.showValidation(error) }
                }
            }
            panel.action("Duplicate", identifier: "automation.duplicate", needsSelection: true) { [weak panel] in
                guard let panel, let id = panel.selectedID, var copy = working.workflows.first(where: { $0.id == id })
                else { return }
                copy.id = UUID()
                copy.shortcut = nil
                working.workflows.append(copy)
                panel.reload(select: copy.id)
            }
            panel.action("Delete…", identifier: "automation.delete", needsSelection: true) { [weak panel] in
                panel?.confirmDelete { id in
                    working.workflows.removeAll { $0.id == id }
                    favoriteEdits.remove(id)
                    previewEdits.remove(id)
                }
            }
            let favoriteButton = panel.action(
                Strings.text("automation.favorite", "Favorite"), identifier: "automation.favorite", needsSelection: true
            ) { [weak panel] in
                guard let panel, let id = panel.selectedID, let i = working.workflows.firstIndex(where: { $0.id == id })
                else { return }
                let enabled = working.workflows[i].pinToToolbar != true
                working.workflows[i].pinToToolbar = favoriteEdits.value(
                    enabled, replacing: working.workflows[i].pinToToolbar, id: id)
                panel.reload(select: id)
            }
            favoriteButton.setButtonType(.switch)
            favoriteButton.setAccessibilityLabel("Favorite selected automation")
            favoriteButton.cell?.setAccessibilityLabel("Favorite selected automation")
            favoriteButton.setAccessibilityHelp(AutomationDefinition.favoriteHelp)
            favoriteButton.toolTip = AutomationDefinition.favoriteHelp
            panel.onSelection = { id in
                favoriteButton.state =
                    working.workflows.first(where: { $0.id == id })?.pinToToolbar == true ? .on : .off
            }
            advancedAction = { [weak self, weak panel] in
                guard let self, let panel, panel.canEdit(), panel.form.window.attachedSheet == nil else { return }
                do {
                    try JSONLibraryEditor.edit(
                        working,
                        configuration: .init(
                            title: "Advanced Automation Configuration", information: AutomationDefinition.advancedHelp,
                            accessibilityLabel: "Automation library JSON", exportName: "TextTank-Automations.json",
                            identifier: "automation.json", size: NSSize(width: 650, height: 330),
                            reference: .init(
                                text: AutomationDefinition.ruleKindReference,
                                accessibilityLabel: "Rule kinds reference", height: 96),
                            extraTitle: "Insert Example", extraIdentifier: "automation.json.example",
                            saveTitle: "Use Changes"),
                        panels: self.jsonFilePanels, parent: panel.form.window, current: { working },
                        read: { try AutomationFileInput.readData($0, limit: AutomationLibrary.maximumBytes) },
                        extraAction: { proposed in
                            var copy = proposed
                            var example = AutomationDefinition.example
                            if copy.workflows.contains(where: { $0.id == example.id }) { example.id = UUID() }
                            copy.workflows.append(example)
                            return copy
                        },
                        save: { proposed in
                            try SavedConfiguration.requireUnchanged(self.library, since: baseline)
                            try self.checkShortcutCollisions(proposed)
                            favoriteEdits.reconcile(proposed, flag: \.pinToToolbar)
                            previewEdits.reconcile(proposed, flag: \.previewBeforeApply)
                            working = proposed
                            panel.reload()
                        })
                    panel.refresh()
                } catch { panel.form.showValidation(error) }
            }
            panel.secondaryAction("Advanced JSON…", identifier: "automation.json") { [weak self] in
                self?.manageAdvanced()
            }
            panel.show()
        } catch { showError(error) }
    }
    private func editSettings(
        of initial: AutomationDefinition, creating: Bool, parent: NSWindow,
        accept: @escaping (AutomationDefinition) throws -> Void
    ) {
        let form = FormPanel(
            title: creating ? "New Automation" : "Edit Automation", identifier: "automation.settings",
            size: NSSize(width: 680, height: 510))
        form.window.contentMinSize = NSSize(width: 600, height: 440)
        form.note(
            "Use Changes returns to the manager. Choose Save in the manager to save the library. Editor changes can be undone; external outputs still require explicit invocation."
        )
        let name = NSTextField(string: initial.name)
        name.identifier = NSUserInterfaceItemIdentifier("automation.settings.name")
        let shortcut = NSTextField(string: initial.shortcut ?? "")
        shortcut.identifier = NSUserInterfaceItemIdentifier("automation.settings.shortcut")
        shortcut.placeholderString = "Lowercase letter for Command-Option; blank for none"
        let input = NSPopUpButton(), output = NSPopUpButton()
        ControlPresentation.populate(
            input,
            choices: [AutomationDefinition.Input.document, .selection, .clipboard, .file].map {
                ($0.rawValue, $0.displayName)
            }, selected: initial.input.rawValue)
        ControlPresentation.populate(
            output, choices: AutomationDefinition.Output.allCases.map { ($0.rawValue, $0.displayName) },
            selected: initial.output.rawValue)
        let preview = NSButton(checkboxWithTitle: "Preview before applying", target: nil, action: nil)
        preview.state = initial.previewBeforeApply == true ? .on : .off
        preview.setAccessibilityLabel("Preview this automation before applying")
        preview.cell?.setAccessibilityLabel("Preview this automation before applying")
        let favorite = NSButton(
            checkboxWithTitle: Strings.text("automation.favorite", "Favorite"), target: nil, action: nil)
        favorite.state = initial.pinToToolbar == true ? .on : .off
        favorite.setAccessibilityLabel("Favorite automation")
        favorite.cell?.setAccessibilityLabel("Favorite automation")
        favorite.setAccessibilityHelp(AutomationDefinition.favoriteHelp)
        favorite.toolTip = AutomationDefinition.favoriteHelp
        form.add(
            settingsView(
                rows: [("Name", name), ("Input", input), ("Output", output), ("Shortcut", shortcut)],
                options: [preview, favorite]))
        form.button("Use Changes", identifier: "automation.settings.save") {
            guard form.commitEditing() else { return }
            var field: NSView? = name
            do {
                var candidate = initial
                candidate.name = name.stringValue
                candidate.shortcut = nil
                try candidate.validate()
                field = shortcut
                candidate.shortcut =
                    shortcut.stringValue.isEmpty ? (initial.shortcut == "" ? "" : nil) : shortcut.stringValue
                if let value = ControlPresentation.selectedID(input).flatMap(AutomationDefinition.Input.init(rawValue:))
                {
                    candidate.input = value
                }
                if let value = ControlPresentation.selectedID(output).flatMap(
                    AutomationDefinition.Output.init(rawValue:))
                {
                    candidate.output = value
                }
                candidate.previewBeforeApply = preview.state == .on
                candidate.pinToToolbar = favorite.state == .on
                try candidate.validate()
                try accept(candidate)
                form.close()
            } catch { form.showValidation(error, field: error is FormFailure ? nil : field) }
        }
        form.button("Cancel", identifier: "automation.settings.cancel", cancel: true) { form.close() }
        form.window.initialFirstResponder = name
        form.show(parent: parent)
    }
    /// Adds fresh copies of the automations a new installation starts with, under new identifiers.
    /// Nothing already saved is replaced, including edited copies of the same presets.
    func restoreDefaultAutomations() {
        guard idleOrExplain() else { return }
        do { guard try StoreRecovery.ensureWritable(loadState) else { return } } catch {
            showError(error)
            return
        }
        busy = true
        defer { busy = false }
        let presets = AutomationDefinition.firstRunPresets
        let confirm = TTAlert()
        confirm.messageText = "Add the default automations?"
        confirm.informativeText =
            "This adds new copies of \(presets.map { "‘\($0.name)’" }.joined(separator: " and ")) as they ship with this version. Your saved automations are kept as they are, including any you edited or renamed."
        confirm.addButton(withTitle: "Add Defaults").identifier = NSUserInterfaceItemIdentifier(
            "automation.restore.confirm")
        confirm.addButton(withTitle: "Cancel", role: .cancel)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            var proposed = library
            proposed.workflows += presets.map { preset in
                var copy = preset
                copy.id = UUID()
                copy.shortcut = nil
                copy.destinationID = nil
                return copy
            }
            try checkShortcutCollisions(proposed)
            try persistLibrary(proposed)
        } catch { showError(error) }
    }
    private func settingsView(rows: [(String, NSView)], options: [NSView]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for (title, control) in rows {
            let label = NSTextField(labelWithString: title)
            ControlPresentation.label("Automation " + title.lowercased(), control: control, caption: label)
            label.translatesAutoresizingMaskIntoConstraints = false
            control.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            control.widthAnchor.constraint(equalToConstant: 420).isActive = true
            let row = NSStackView(views: [label, control])
            row.spacing = 10
            stack.addArrangedSubview(row)
        }
        for option in options { stack.addArrangedSubview(option) }
        stack.frame = NSRect(x: 0, y: 0, width: 550, height: CGFloat(rows.count * 34 + options.count * 28))
        return stack
    }
    var jsonFilePanels = JSONLibraryEditor.FilePanels.standard
    @MainActor func manageAdvanced() {
        if manager == nil { manage() }
        guard let manager, manager.canEdit(), manager.form.window.attachedSheet == nil else { return }
        advancedAction?()
    }
    /// Shared private persistence for edited workflows and explicitly selected destinations.
    func persistLibrary(_ proposed: AutomationLibrary) throws {
        try loadState.requireWritable() // Never overwrite an unreadable existing library.
        let assigned = Set(library.workflows.compactMap(\.shortcut))
        if proposed.workflows.contains(where: { $0.shortcut.map { !assigned.contains($0) } ?? false }) {
            try checkShortcutCollisions(proposed)
        }
        let data = try proposed.encoded()
        let directory = storage.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw AutomationError.invalid("Automation storage must be a regular directory.")
            }
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if FileManager.default.fileExists(atPath: storage.path) {
            // attributesOfItem performs a fresh lstat; URL resource values may be cached
            // across an externally replaced path and must not authorize the write.
            let attributes = try FileManager.default.attributesOfItem(atPath: storage.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw AutomationError.invalid("Automation storage must be a regular file.")
            }
        }
        try PrivateFileStore.write(
            data, to: storage, maximumBytes: AutomationLibrary.maximumBytes, temporaryPrefix: ".automations-")
        installError = nil
        library = proposed
        rebuild()
        NotificationCenter.default.post(name: .textTankAutomationsDidChange, object: self)
        palette?.refresh()
    }
    private func checkShortcutCollisions(_ proposed: AutomationLibrary) throws {
        func existing(_ menu: NSMenu) -> Set<String> {
            if menu === automationMenu { return [] }
            var keys = Set<String>()
            for item in menu.items {
                if item === saveAllShortcutItem { continue }
                if item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == [
                    .command, .option
                ] {
                    keys.insert(item.keyEquivalent)
                }
                if let submenu = item.submenu { keys.formUnion(existing(submenu)) }
            }
            return keys
        }
        let keys = NSApp.mainMenu.map(existing) ?? []
        for workflow in proposed.workflows {
            // No shortcut, however it is stored, collides with nothing.
            if let key = workflow.shortcut, !key.isEmpty, keys.contains(key) {
                throw AutomationError.invalid(
                    "Command-Option-\(key.uppercased()) is already assigned to an application command.")
            }
        }
    }
    @objc private func runAction(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String, let id = UUID(uuidString: identifier) else {
            return
        }
        do { try runSavedAutomation(id: id) } catch { showError(error) }
    }
    private func run(_ workflow: AutomationDefinition, target: AutomationDocumentTarget?) throws {
        onInvocation()
        if workflow.input == .document && target == nil {
            throw AutomationError.invalid("This automation requires an open editor document.")
        }
        if workflow.input == .selection || workflow.output == .editor || workflow.output == .previewChanges {
            guard let target else { throw AutomationError.invalid("This automation requires an open editor document.") }
            if workflow.output == .editor || workflow.output == .previewChanges { try target.requireWritable() }
            guard target.selections.count == 1 || (workflow.input == .selection && workflow.output == .editor) else {
                throw AutomationError.invalid(
                    "Multiple selections require selection input and editor output. Other outputs are not changed.")
            }
        }
        // Freeze all source bytes before parameter prompts, progress and preview.
        let selectionInputs = workflow.input == .selection ? try target?.selectionTexts() : nil
        guard
            let resolved = try workflow.resolvingParameters({ index, label, initial in
                let alert = TTAlert()
                alert.messageText = "\(workflow.name) — Step \(index + 1)"
                alert.informativeText = label
                alert.addButton(withTitle: "Continue")
                alert.addButton(withTitle: "Cancel", role: .cancel)
                let field = NSTextField(string: initial)
                field.frame = NSRect(x: 0, y: 0, width: 500, height: 28)
                alert.accessoryView = field
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                alert.window.makeFirstResponder(nil)
                return field.stringValue
            })
        else { return }
        if workflow.input == .selection, workflow.output == .editor, let target,
            let selectionInputs, selectionInputs.count > 1
        {
            var outputs: [String] = []
            for (index, text) in selectionInputs.enumerated() {
                var output = try transformWithProgress(resolved, input: text)
                if workflow.previewBeforeApply == true {
                    let alert = TTAlert()
                    alert.messageText = "\(workflow.name) — Selection \(index + 1) of \(selectionInputs.count)"
                    alert.informativeText =
                        "All selections apply together after every preview is accepted. Cancel preserves the entire editor."
                    alert.addButton(withTitle: "Accept")
                    alert.addButton(withTitle: "Cancel", role: .cancel)
                    let preview = makeTextView(height: 250)
                    preview.editor.setAccessibilityLabel("Automation output preview")
                    preview.editor.string = output
                    alert.accessoryView = preview.scroll
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    output = preview.editor.string
                }
                outputs.append(output)
            }
            try target.apply(outputs, wholeDocument: false)
            return
        }
        let input: String
        switch workflow.input {
        case .selection:
            guard let selection = selectionInputs?.first else {
                throw AutomationError.invalid("Select text before running this automation.")
            }
            input = selection
        case .document:
            guard let target else { throw AutomationError.invalid("This automation requires an open editor document.") }
            input = target.text
        case .file:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // File input explicitly accepts valid UTF-8 only; never guess or replace invalid bytes.
            input = try AutomationFileInput.read(url)
        case .clipboard:
            guard let board = activePasteboard, let value = Self.plainText(from: board) else {
                throw AutomationError.invalid("The clipboard does not contain supported text.")
            }
            input = value
        }
        var output = try transformWithProgress(resolved, input: input)
        let reviewChanges = workflow.output == .previewChanges
        if reviewChanges {
            guard let target else { throw AutomationError.invalid("Preview as Changes requires an open document.") }
            if try openChangePreview(workflow, output: output, target: target) { return }
        }
        if workflow.previewBeforeApply == true || reviewChanges {
            let alert = TTAlert()
            alert.messageText = workflow.name
            if workflow.output == .editor || reviewChanges {
                let format =
                    workflow.input == .document
                    ? Strings.text(
                        "automation.preview.document",
                        "Input: %@. Replace the entire captured document. Edit the preview; delete rows you do not want. Apply commits it. Cancel makes no changes. You can turn this preview off in Manage Automations."
                    )
                    : Strings.text(
                        "automation.preview.selection",
                        "Input: %@. Replace the captured selection. Edit the preview; delete rows you do not want. Apply commits it. Cancel makes no changes. You can turn this preview off in Manage Automations."
                    )
                alert.informativeText = String(format: format, workflow.input.displayName)
                if reviewChanges {
                    let scope = workflow.input == .document ? "the entire captured document" : "the captured selection"
                    alert.informativeText = "Preview as Changes supports up to 8 MiB per side. Edit this output before applying it to "
                        + scope + ", or cancel to keep the document unchanged."
                }
            } else {
                alert.informativeText = String(
                    format: Strings.text(
                        "automation.preview.output",
                        "Input: %@. Output: %@. Edit the preview; delete rows you do not want. Apply commits it. Cancel makes no changes. You can turn this preview off in Manage Automations."
                    ), workflow.input.displayName, workflow.output.displayName)
            }
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Cancel", role: .cancel)
            let preview = makeTextView(height: 350)
            preview.editor.setAccessibilityLabel("Automation output preview")
            preview.editor.string = output
            alert.accessoryView = preview.scroll
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            output = preview.editor.string
        }
        func revalidateSource() throws {
            guard workflow.input == .document || workflow.input == .selection else { return }
            guard let target else {
                throw AutomationError.invalid("The original source closed. The result was discarded.")
            }
            try target.validateSource(checkSelection: workflow.input == .selection)
        }
        try revalidateSource()
        switch workflow.output {
        case .previewChanges, .editor:
            guard let target else {
                throw AutomationError.invalid("The original document closed. Nothing was replaced.")
            }
            try target.apply([output], wholeDocument: workflow.input == .document)
        case .clipboard:
            guard let board = activePasteboard else {
                throw AutomationError.invalid("Clipboard access is unavailable for this isolated support directory.")
            }
            board.clearContents()
            guard board.setString(output, forType: .string) else {
                throw AutomationError.invalid("The clipboard could not be updated.")
            }
        case .newDocument: newDocument(output)
        case .reminders:
            beginReminderExport(output, workflow: workflow)
        case .file:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Automation-output.txt"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try revalidateSource()
            try Data(output.utf8).write(to: url, options: .atomic)
        }
    }
    /// Returns false when the size limit requires the ordinary editable output preview.
    private func openChangePreview(
        _ workflow: AutomationDefinition, output: String, target: AutomationDocumentTarget
    ) throws -> Bool {
        let editor = try target.resolve(checkSelection: workflow.input != .document)
        guard !editor.readOnly, target.value != nil, let service = comparisonService() else {
            throw AutomationError.invalid("The captured document is unavailable for comparison.")
        }
        let length = Int(editor.byteLength)
        let range: Range<Int>
        if workflow.input == .document {
            range = 0..<length
        } else {
            guard target.selections.count == 1, let selected = target.selections.first else {
                throw AutomationError.invalid("Choose one selection or caret for Preview as Changes.")
            }
            range = min(selected.anchorByte, selected.caretByte)..<max(selected.anchorByte, selected.caretByte)
            guard range.lowerBound >= 0, range.upperBound <= length else { throw ReviewRejection.invalidRange }
        }
        let limit = ReviewDiffPolicy.default.maximumInputBytes
        guard length <= limit, length - range.count + output.utf8.count <= limit else { return false }
        let original = try CompareDocumentInput(editor)
        var bytes = original.capture.snapshot.bytes
        bytes.replaceSubrange(range, with: output.utf8)
        let result = try TextSnapshot(bytes: bytes, source: .freeText(UUID()), label: workflow.name + " — Output",
                                      format: original.capture.snapshot.format)
        Task { [weak self] in
            do {
                _ = try await service.open(original: .document(original), modified: .automationResult(result),
                                           destination: .original)
            } catch { self?.showError(error) }
        }
        return true
    }
    private var runPanel: NSPanel?
    /// Cancel ends the modal itself. The worker is only asked to stop, because sorting, splitting
    /// and joining cannot be interrupted; it holds a copy of the text and nothing of the editor.
    @objc private func cancelTransform() {
        guard let runControl else { return }
        runControl.cancel()
        if let runPanel, NSApp.modalWindow === runPanel { NSApp.stopModal() }
    }
    /// One-shot worker result for the synchronous 0.2-second fast path. Every read/write is
    /// protected by this lock; UI/modal result ownership stays in TransformProgress.
    private final class TransformOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<String, Error>?
        func set(_ value: Result<String, Error>) {
            lock.lock()
            result = value
            lock.unlock()
        }
        func get() -> Result<String, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }
    /// Progress controls, created only when a run outlasts the short wait. Main thread only.
    /// The worker's blocks hold this box and can outlive the run, so the references are weak:
    /// the panel and its views are owned by the run and released on the main thread.
    @MainActor private final class TransformProgress {
        var result: Result<String, Error>?
        weak var panel: NSPanel?
        weak var bar: NSProgressIndicator?
        weak var status: NSTextField?
    }
    /// Every run goes to a worker with a run control, whatever the size of its input. The main
    /// thread waits briefly, so an ordinary cleanup still completes in the same event with no
    /// panel and no run-loop turn. A run that takes longer gets the modal panel and its Cancel.
    private func transformWithProgress(_ workflow: AutomationDefinition, input: String) throws -> String {
        let control = AutomationRunControl()
        runControl = control
        defer {
            runControl = nil
            runPanel = nil
        }
        let outcome = TransformOutcome(), finished = DispatchSemaphore(value: 0), ui = TransformProgress()
        // Progress and completion are delivered through the run loop, not the main queue, so they
        // arrive even when this run was itself started from a main-queue block.
        let deliverProgress: @MainActor @Sendable (Int, Int) -> Void = { completed, total in
            ui.bar?.doubleValue = Double(completed)
            ui.status?.stringValue = "Processing step \(min(completed+1,total)) of \(total)…"
        }
        let deliverResult: @MainActor @Sendable (Result<String, Error>) -> Void = { result in
            // The modal path publishes its actor-owned result before stopping the same run-loop turn.
            ui.result = result
            if let panel = ui.panel, NSApp.modalWindow === panel { NSApp.stopModal() }
        }
        control.onProgress = { completed, total in
            MainRunLoop.perform { deliverProgress(completed, total) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try workflow.transform(input, control: control) }
            // The locked handoff is only for the existing synchronous wait/setup fast path.
            outcome.set(result)
            finished.signal()
            MainRunLoop.perform { deliverResult(result) }
        }
        if finished.wait(timeout: .now() + 0.2) == .success, let result = outcome.get() { return try result.get() }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 130), styleMask: [.titled], backing: .buffered,
            defer: false)
        panel.title = workflow.name
        let status = NSTextField(labelWithString: "Processing captured text…")
        status.frame = NSRect(x: 20, y: 85, width: 380, height: 24)
        let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 60, width: 380, height: 18))
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(max(1, workflow.steps.count))
        progress.setAccessibilityLabel("Automation progress")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTransform))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 290, y: 15, width: 110, height: 30)
        cancel.identifier = NSUserInterfaceItemIdentifier("automation.transform.cancel")
        cancel.keyEquivalent = "\u{1b}"
        panel.contentView?.addSubview(status)
        panel.contentView?.addSubview(progress)
        panel.contentView?.addSubview(cancel)
        ui.panel = panel
        ui.bar = progress
        ui.status = status
        runPanel = panel
        panel.center()
        // A worker that finished during the wait or the setup has its stop block queued for the
        // modal run loop; skipping the modal when the result is already here saves a flash.
        if let result = outcome.get() {
            ui.result = result
        } else {
            NSApp.runModal(for: panel)
        }
        panel.orderOut(nil)
        // Cancel wins over a result that arrived at the same moment.
        try control.checkCancellation()
        guard let result = ui.result else {
            control.cancel()
            throw AutomationError.invalid("Automation cancelled. Nothing was changed.")
        }
        return try result.get()
    }
    private func beginReminderExport(_ text: String, workflow: AutomationDefinition) {
        let rows = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !rows.isEmpty else {
            showError(AutomationError.invalid("There are no nonblank reminder rows to send."))
            return
        }
        guard !exportInProgress else { return }
        exportInProgress = true // Acquire before scheduling, so double-clicks cannot queue two exports.
        exportTask = Task { @MainActor in
            defer {
                self.exportInProgress = false
                self.exportTask = nil
            }
            do {
                let connector = RemindersConnector(
                    storageURL: AppStorage.url(.reminders, under: self.storage.deletingLastPathComponent()))
                try await connector.requestAccess()
                let destinations = try connector.destinations()
                let writable = destinations.filter { $0.writable }
                guard !writable.isEmpty else {
                    throw AutomationError.invalid("No writable Reminders lists are available.")
                }
                let alert = TTAlert()
                alert.messageText = String(
                    format: rows.count == 1
                        ? Strings.text("reminders.send.title.one", "Send %@ Reminder Item")
                        : Strings.text("reminders.send.title.other", "Send %@ Reminder Items"),
                    Strings.number(rows.count))
                alert.informativeText =
                    "Choose the Reminders list to add these items to. Nothing is sent until you choose Send. Each item's result is recorded, and an item whose result is uncertain is never sent again automatically."
                alert.addButton(
                    withTitle: String(
                        format: rows.count == 1
                            ? Strings.text("reminders.send.one", "Send %@ Item")
                            : Strings.text("reminders.send.other", "Send %@ Items"), Strings.number(rows.count)))
                alert.addButton(withTitle: "Cancel", role: .cancel)
                let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 650, height: 28), pullsDown: false)
                choice.setAccessibilityLabel("Reminders destination list")
                // A list is named as Reminders names it. Only two lists with the same name in the same
                // account need telling apart, and then by position rather than by an identifier.
                let sameName = Dictionary(grouping: writable, by: { "\($0.title)\u{0}\($0.source)" })
                for destination in writable {
                    let twins = sameName["\(destination.title)\u{0}\(destination.source)"] ?? []
                    let ordinal =
                        twins.count > 1
                        ? " (\((twins.firstIndex { $0.id == destination.id } ?? 0) + 1) of \(twins.count) with this name)"
                        : ""
                    choice.addItem(withTitle: "\(destination.title) — \(destination.source)\(ordinal)")
                    choice.lastItem?.representedObject = destination.id
                }
                if let saved = workflow.destinationID, let index = writable.firstIndex(where: { $0.id == saved }) {
                    choice.selectItem(at: index)
                } else if workflow.destinationID != nil {
                    alert.informativeText +=
                        " The previously saved list is unavailable. Explicitly choose a new destination."
                    choice.select(nil)
                }
                alert.accessoryView = choice
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard let destinationID = choice.selectedItem?.representedObject as? String else {
                    throw AutomationError.invalid("Choose a writable list before sending.")
                }
                // Read the history first: if the journal folder itself cannot be read, nothing is saved or sent.
                let history = try connector.scanBatches()
                // Persist chosen default only after explicit Send intent. Failure prevents send.
                if let index = self.library.workflows.firstIndex(where: { $0.id == workflow.id }) {
                    var proposed = self.library
                    proposed.workflows[index].destinationID = destinationID
                    try self.persistLibrary(proposed)
                }
                switch Self.exportPrecheck(
                    rows: rows, destinationID: destinationID, batches: history.batches, issues: history.issues)
                {
                case .clear: break
                case .needsConfirmation(let issues):
                    // An unreadable record may be an earlier export of these very items, so the
                    // duplicate check cannot vouch for this send. Cancel is the default.
                    let unreadable = TTAlert()
                    unreadable.messageText = "Some export records could not be read"
                    unreadable.informativeText =
                        "A previous export of these items may be recorded in a file that cannot be read, so TextTank cannot tell whether they were already sent. Check Reminders before sending. The files are left unchanged in the ReminderExports folder:\n\n"
                        + Self.issueSummary(issues)
                    unreadable.addButton(withTitle: "Cancel", role: .cancel)
                    unreadable.addButton(withTitle: "Send Anyway")
                    guard unreadable.runModal() == .alertSecondButtonReturn else { return }
                case .match(let existing):
                    let repeated = TTAlert()
                    repeated.messageText = "These items have already been sent or attempted"
                    repeated.informativeText =
                        "An export with the same rows and destination already exists. Review its confirmed, failed and uncertain results to avoid duplicates. Send Another Copy intentionally creates another set."
                    repeated.addButton(withTitle: "Review Existing Export")
                    repeated.addButton(withTitle: "Cancel", role: .cancel)
                    repeated.addButton(withTitle: "Send Another Copy")
                    enum RepeatedChoice { case review, cancel, sendCopy }
                    guard let response = repeated.choice([RepeatedChoice.review, .cancel, .sendCopy]),
                        response != .cancel
                    else { return }
                    if response == .review {
                        self.showReminderResults(existing)
                        return
                    }
                    guard response == .sendCopy else {
                        return
                    }
                }
                let progress = self.exportProgressPanel(total: rows.count)
                defer { progress.panel.orderOut(nil) }
                let batch = try await connector.export(
                    rows: rows, destinationID: destinationID, batchID: UUID(), progress: progress.update)
                self.showReminderResults(batch, quietOnSuccess: true)
            } catch ReminderConnectorError.journalFailed(let batch, let underlying) {
                self.showReminderResults(batch, header: Self.journalFailureHeader(underlying))
            } catch { self.showError(error) }
        }
    }
    @objc private func cancelExport() { exportTask?.cancel() }
    private func exportProgressPanel(total: Int) -> (panel: NSPanel, update: (Int, Int) -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 130), styleMask: [.titled], backing: .buffered,
            defer: false)
        panel.title = "Sending to Reminders"
        let label = NSTextField(labelWithString: "Preparing \(total) items…")
        label.frame = NSRect(x: 20, y: 85, width: 400, height: 24)
        let indicator = NSProgressIndicator(frame: NSRect(x: 20, y: 60, width: 400, height: 16))
        indicator.isIndeterminate = false
        indicator.maxValue = Double(total)
        let cancel = NSButton(title: "Stop Sending", target: self, action: #selector(cancelExport))
        // The panel has only this button; Escape presses it.
        cancel.keyEquivalent = "\u{1b}"
        cancel.identifier = NSUserInterfaceItemIdentifier("automation.export.stop")
        cancel.frame = NSRect(x: 280, y: 15, width: 140, height: 30)
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(indicator)
        panel.contentView?.addSubview(cancel)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return (
            panel,
            { completed, total in
                label.stringValue = "Processed \(completed) of \(total). Sent items remain in Reminders."
                indicator.doubleValue = Double(completed)
            }
        )
    }
    nonisolated static func matchingExport(rows: [String], destinationID: String, batches: [ReminderBatch])
        -> ReminderBatch?
    {
        batches.filter { $0.destinationID == destinationID && $0.rows.map(\.title) == rows }
            .max { $0.createdAt < $1.createdAt }
    }
    /// What a new export must do about the recorded history: review a readable batch with the same
    /// rows and destination, ask before sending because part of the history is unreadable, or proceed.
    enum ReminderExportPrecheck {
        case match(ReminderBatch)
        case needsConfirmation([ReminderJournalIssue])
        case clear
    }
    nonisolated static func exportPrecheck(
        rows: [String], destinationID: String, batches: [ReminderBatch], issues: [ReminderJournalIssue]
    ) -> ReminderExportPrecheck {
        if let existing = matchingExport(rows: rows, destinationID: destinationID, batches: batches) {
            return .match(existing)
        }
        return issues.isEmpty ? .clear : .needsConfirmation(issues)
    }
    /// The batches Clear Confirmed History removes: those with nothing left to resume or reconcile.
    nonisolated static func clearableBatches(_ batches: [ReminderBatch]) -> [ReminderBatch] {
        batches.filter { !$0.rows.isEmpty && $0.rows.allSatisfy { $0.status == .confirmed } }
    }
    /// Export History rows, newest first.
    nonisolated static func historyOrder(_ batches: [ReminderBatch]) -> [ReminderBatch] {
        batches.sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }
    /// File names of unreadable journals with the reason for each, at most ten, then a count.
    nonisolated static func issueSummary(_ issues: [ReminderJournalIssue]) -> String {
        let lines = issues.prefix(10).map { "\($0.url.lastPathComponent): \($0.message)" }
        return (lines + (issues.count > 10 ? ["and \(issues.count - 10) more"] : [])).joined(separator: "\n")
    }
    nonisolated static func journalFailureHeader(_ underlying: Error) -> String {
        if underlying is PublishedFileSyncFailure {
            return
                "Sending stopped. \(underlying.localizedDescription) The list below shows the outcome held in memory. Export History may already show the updated result. Check Reminders before sending again."
        }
        return
            "The export journal could not be updated (\(underlying.localizedDescription)), so sending stopped. The list below is the outcome held in memory. Export History may show the last attempted item as uncertain, even if it was saved, and may be unavailable until the journal folder can be written again. Check Reminders before sending any of these items again."
    }
    /// Told about an export in which every item was confirmed. The app shows it in the document
    /// window's status line; it is always announced.
    var onQuietExportResult: (String) -> Void = { _ in }
    @MainActor private func showReminderResults(
        _ batch: ReminderBatch, header: String? = nil, quietOnSuccess: Bool = false
    ) {
        // Routine success is not an alert: the items are in Reminders and there is nothing to decide.
        if quietOnSuccess, header == nil, !batch.rows.isEmpty, batch.rows.allSatisfy({ $0.status == .confirmed }) {
            let count = batch.rows.count
            let message =
                "Added \(count) \(count == 1 ? "item" : "items") to “\(batch.destinationTitle)” in Reminders. Editor Undo does not remove them."
            Announce.say(message)
            onQuietExportResult(message)
            return
        }
        let alert = TTAlert()
        alert.messageText = header == nil ? "Reminder Export Results" : "Reminder Export Results (journal not updated)"
        alert.informativeText =
            (header.map { $0 + "\n\n" } ?? "")
            + "Confirmed items are not resent. Uncertain items require inspection in Reminders and are never automatically retried. Failed and unsent pending items remain available in Export History. Resume retries those items only. Editor Undo does not affect reminders."
        let text = makeTextView(height: 300)
        text.editor.isEditable = false
        text.editor.string =
            "List: \(batch.destinationTitle) — \(batch.destinationSource)\n\n"
            + batch.rows.map { row in "[\(row.status.rawValue)] \(row.title)\(row.message.map { " — " + $0 } ?? "")" }
            .joined(separator: "\n")
        alert.accessoryView = text.scroll
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }
    @objc private func reminderHistory() {
        guard idleOrExplain() else { return }
        exportInProgress = true
        exportTask = Task { @MainActor in
            defer {
                self.exportInProgress = false
                self.exportTask = nil
            }
            do {
                let connector = RemindersConnector(
                    storageURL: AppStorage.url(.reminders, under: self.storage.deletingLastPathComponent()))
                let history = try connector.scanBatches()
                let batches = Self.historyOrder(history.batches)
                guard !batches.isEmpty || !history.issues.isEmpty else {
                    throw AutomationError.invalid("There are no recorded reminder exports.")
                }
                let unreadable =
                    history.issues.isEmpty
                    ? ""
                    : "\n\nThese files in the ReminderExports folder could not be read and are left unchanged:\n"
                        + Self.issueSummary(history.issues)
                let alert = TTAlert()
                alert.messageText = "Reminder Export History"
                guard !batches.isEmpty else {
                    alert.informativeText = "No recorded export could be read." + unreadable
                    alert.addButton(withTitle: "OK")
                    _ = alert.runModal()
                    return
                }
                alert.informativeText =
                    "Choose a recorded batch to inspect its durable per-item results. Reading this history does not request system access."
                    + unreadable
                alert.addButton(withTitle: "Review")
                alert.addButton(withTitle: "Cancel", role: .cancel)
                alert.addButton(withTitle: "Request Access and Resume Unsent")
                let clearable = Self.clearableBatches(batches)
                if !clearable.isEmpty { alert.addButton(withTitle: "Clear Confirmed History…") }
                let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 650, height: 28), pullsDown: false)
                choice.setAccessibilityLabel("Recorded export")
                let stamp = DateFormatter()
                stamp.dateStyle = .medium
                stamp.timeStyle = .short
                for batch in batches {
                    choice.addItem(
                        withTitle:
                            "\(stamp.string(from: batch.createdAt)) · \(batch.destinationTitle) — \(batch.destinationSource) · \(batch.rows.count) rows · \(batch.id)"
                    )
                    choice.lastItem?.representedObject = batch.id.uuidString
                }
                alert.accessoryView = choice
                enum HistoryChoice { case review, cancel, resume, clear }
                guard
                    let response = alert.choice(
                        clearable.isEmpty
                            ? [HistoryChoice.review, .cancel, .resume]
                            : [HistoryChoice.review, .cancel, .resume, .clear]), response != .cancel
                else { return }
                if response == .clear {
                    let confirm = TTAlert()
                    confirm.messageText =
                        clearable.count == 1
                        ? "Remove 1 fully confirmed export record?"
                        : "Remove \(clearable.count) fully confirmed export records?"
                    confirm.informativeText =
                        "Only TextTank's own record of these exports is removed, which cannot be undone. Reminders already in Reminders are not changed. Sending one of these lists again will no longer warn that it was already sent. "
                        + (batches.count > clearable.count
                            ? "\(batches.count - clearable.count) exports with unsent, failed or uncertain items are kept."
                            : "No export has unsent, failed or uncertain items.")
                    confirm.addButton(withTitle: "Cancel", role: .cancel)
                    confirm.addButton(withTitle: "Remove Records").hasDestructiveAction = true
                    guard confirm.runModal() == .alertSecondButtonReturn else { return }
                    let removed = try connector.deleteConfirmedBatches(ids: clearable.map(\.id))
                    let report = TTAlert()
                    report.messageText =
                        removed.count == 1 ? "Removed 1 export record" : "Removed \(removed.count) export records"
                    report.informativeText =
                        removed.count == clearable.count
                        ? "Reminders was not changed."
                        : "Reminders was not changed. \(clearable.count - removed.count) records changed meanwhile and were kept."
                    report.addButton(withTitle: "OK")
                    _ = report.runModal()
                    return
                }
                guard response != .cancel, let id = choice.selectedItem?.representedObject as? String,
                    let batch = batches.first(where: { $0.id.uuidString == id })
                else { return }
                if response == .resume {
                    // The explicit retry choice authorizes a new access request, never a new batch ID.
                    try await connector.requestAccess()
                    let progress = self.exportProgressPanel(total: batch.rows.count)
                    defer { progress.panel.orderOut(nil) }
                    let retried = try await connector.export(
                        rows: batch.rows.map(\.title), destinationID: batch.destinationID, batchID: batch.id,
                        retryFailed: true, progress: progress.update)
                    self.showReminderResults(retried)
                } else {
                    self.showReminderResults(batch)
                }
            } catch ReminderConnectorError.journalFailed(let batch, let underlying) {
                self.showReminderResults(batch, header: Self.journalFailureHeader(underlying))
            } catch { self.showError(error) }
        }
    }
    /// Clipboard input as plain text: a plain-text flavour first, then RTF through the local Cocoa
    /// reader, then HTML through `AutomationHTMLText`. HTML is never handed to
    /// `NSAttributedString`, whose HTML importer is WebKit-backed and may load remote resources.
    static func plainText(from pasteboard: NSPasteboard) -> String? {
        if let string = pasteboard.string(forType: .string) { return string }
        if let data = pasteboard.data(forType: .rtf),
            let rich = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        {
            return rich.string
        }
        if let data = pasteboard.data(forType: .html) { return AutomationHTMLText.plainText(from: data) }
        return nil
    }
    private func makeTextView(height: CGFloat) -> (scroll: NSScrollView, editor: NSTextView) {
        JSONLibraryEditor.makeTextView(size: NSSize(width: 650, height: height))
    }
    private func showError(_ error: Error) {
        // A declined or restricted permission is an ordinary state with a way forward, not a dead end.
        if case ReminderConnectorError.permissionRequired = error {
            let alert = TTAlert()
            alert.messageText = "TextTank cannot use Reminders"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Open Privacy Settings")
            alert.addButton(withTitle: "Cancel", role: .cancel)
            if alert.runModal() == .alertFirstButtonReturn,
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
            {
                NSWorkspace.shared.open(url)
            }
            return
        }
        Announce.say(error.localizedDescription)
        TTAlert.present(error)
    }
}
