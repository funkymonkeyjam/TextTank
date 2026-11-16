@testable import TextTankCore
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

@MainActor enum ToolbarChecks {
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private static func nativeAttribute(_ element: Any, _ name: String) -> String {
        guard let object = element as? NSObject, object.responds(to: NSSelectorFromString(name)) else { return "" }
        return object.perform(NSSelectorFromString(name))?.takeUnretainedValue() as? String ?? ""
    }
    private static func nativeTree(_ root: Any, depth: Int = 0) -> [Any] {
        guard depth < 12, let object = root as? NSObject else { return [] }
        let selector = NSSelectorFromString("accessibilityChildren")
        let children =
            object.responds(to: selector)
            ? (object.perform(selector)?.takeUnretainedValue() as? [Any] ?? []) : []
        return [root] + children.flatMap { nativeTree($0, depth: depth + 1) }
    }
    private static func menuItem(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action == action { return item }
            if let found = menuItem(action, in: item.submenu) { return found }
        }
        return nil
    }
    static func run(composition: AppDelegate) throws {
        let suite = "TextTank.ToolbarChecks." + UUID().uuidString
        let preferences = try requireValue(UserDefaults(suiteName: suite), "DT fixture: owned preferences")
        let priorPreferences = EditorToolbarPreferences.isolatedDefaults
        let priorProvider = RuntimeEnvironment.dependencies
        let priorDelegate = NSApp.delegate
        var forbiddenDefaultsAccesses = 0
        var effects = RuntimeEnvironment.current
        effects.sharedDefaultsProvider = {
            forbiddenDefaultsAccesses += 1
            return preferences
        }
        RuntimeEnvironment.dependencies = effects
        EditorToolbarPreferences.isolatedDefaults = preferences
        NSApp.delegate = composition
        let original = try AutomationLibrary.decode(Data(contentsOf: AppStorage.url(.automations)))
        var owned: [TextDocument] = []
        defer {
            owned.forEach { $0.close() }
            try? composition.automations.persistLibrary(original)
            preferences.removePersistentDomain(forName: suite)
            EditorToolbarPreferences.isolatedDefaults = priorPreferences
            RuntimeEnvironment.dependencies = priorProvider
            NSApp.delegate = priorDelegate
        }
        var first = AutomationDefinition.example, second = AutomationDefinition.example
        first.id = UUID()
        first.name = "Toolbar First"
        first.pinToToolbar = false
        first.shortcut = nil
        second.id = UUID()
        second.name = "Toolbar Second"
        second.pinToToolbar = true
        second.shortcut = nil
        second.steps = []
        var library = AutomationLibrary(workflows: [first, second])
        try composition.automations.persistLibrary(library)
        let document = DocumentFactory.makeUntitled()
        owned.append(document)
        let controller = try requireValue(
            document.windowControllers.first as? EditorWindowController, "DT fixture: document controller")
        composition.noteActive(controller)
        let window = try requireValue(controller.window, "DT fixture: document window")
        let toolbar = try requireValue(window.toolbar, "DT fixture: native toolbar")
        let core = ["TextTank.New", "TextTank.Open", "TextTank.Save", "TextTank.Find", "TextTank.Split"]
        let native = nativeTree(window)
        for item in toolbar.items where item.itemIdentifier != .flexibleSpace {
            let exposed = native.first {
                nativeAttribute($0, "accessibilityLabel") == item.toolTip
                    && ["AXButton", "AXMenuButton"].contains(nativeAttribute($0, "accessibilityRole"))
            }
            check(exposed != nil, "DT-R5 actual native toolbar accessibility element has scoped action: \(item.label)")
        }
        let identifiers = toolbar.items.map { $0.itemIdentifier.rawValue }
        check(core.allSatisfy(identifiers.contains), "DT-R1 default toolbar contains all five standard commands")
        check(
            toolbar.allowsUserCustomization && toolbar.displayMode == .iconAndLabel,
            "DT-R4/R5 toolbar is customizable and defaults to icons with labels")
        check(
            toolbar.items.first { $0.itemIdentifier.rawValue == "TextTank.Automations" } is NSMenuToolbarItem,
            "DT-R2 Automations is a native menu toolbar item")
        check(
            composition.automations.toolbarIdentifiers().allSatisfy { id in
                toolbar.items.contains { $0.itemIdentifier == id }
            },
            "DT-R3 saved favorites appear as individual toolbar items")
        check(
            !descendants(window.contentView!).contains { $0.identifier?.rawValue == "tab.new" },
            "DT-R6 the tab strip does not repeat the toolbar New command")
        check(
            toolbar.items.filter { $0.itemIdentifier != .flexibleSpace }.allSatisfy {
                $0.image != nil && !$0.label.isEmpty && !($0.toolTip ?? "").isEmpty && $0.view == nil
            }, "DT-R1/R5 native action items have symbols, labels and tooltips without custom views")
        for command in EditorToolbarCommand.allCases {
            let item = try requireValue(
                toolbar.items.first { $0.itemIdentifier == command.identifier }, "DT fixture: core item")
            let menu = try requireValue(
                menuItem(command.action, in: NSApp.mainMenu), "DT fixture: matching menu action")
            check(
                item.action == menu.action && item.target == nil && menu.target == nil && item.label == menu.title,
                "DT-R1 standard action, title and responder target match the menu: \(command.rawValue)")
            check(
                item.menuFormRepresentation?.action == item.action && item.menuFormRepresentation?.target == nil,
                "DT-R5 core overflow uses the same responder action: \(command.rawValue)")
        }
        let save = try requireValue(
            toolbar.items.first { $0.itemIdentifier.rawValue == "TextTank.Save" }, "DT fixture: Save")
        let saveMenu = try requireValue(menuItem(save.action!, in: NSApp.mainMenu), "DT fixture: menu Save")
        document.editor.text = "Owned save fixture"
        for readOnly in [false, true] {
            document.editor.readOnly = readOnly
            check(
                document.validateUserInterfaceItem(save) == document.validateMenuItem(saveMenu),
                "DT-R1 Save uses NSDocument validation exactly as the menu (readOnly=\(readOnly))")
        }
        document.editor.readOnly = false
        let split = try requireValue(
            toolbar.items.first { $0.itemIdentifier.rawValue == "TextTank.Split" }, "DT fixture: Split")
        let splitMenu = try requireValue(menuItem(split.action!, in: NSApp.mainMenu), "DT fixture: menu Split")
        check(
            controller.validateToolbarItem(split) && controller.validateMenuItem(splitMenu),
            "DT-R1 Split enables on both surfaces")
        check(
            NSApp.sendAction(split.action!, to: controller, from: split) && controller.secondary != nil,
            "DT-R1 the standard Split item executes the actual clone action")
        check(
            !controller.validateToolbarItem(split) && !controller.validateMenuItem(splitMenu),
            "DT-R1 Split disables on both surfaces after cloning")
        controller.closeSplit(nil)
        let find = try requireValue(
            toolbar.items.first { $0.itemIdentifier.rawValue == "TextTank.Find" }, "DT fixture: Find")
        check(
            NSApp.sendAction(find.action!, to: controller, from: find) && controller.findBarVisible,
            "DT-R1 the standard Find item opens the actual document Find bar")
        controller.hideFind(nil)
        let new = try requireValue(
            toolbar.items.first { $0.itemIdentifier.rawValue == "TextTank.New" }, "DT fixture: New")
        let beforeNew = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
        check(
            NSApp.sendAction(new.action!, to: new.target, from: new),
            "DT-R1 the native New item dispatches through the responder chain")
        let created = NSDocumentController.shared.documents.filter { !beforeNew.contains(ObjectIdentifier($0)) }
        check(
            created.count == 1 && created[0].fileType == TextDocument.plainTextType,
            "DT-R1 New reaches the shared document factory exactly once")
        created.forEach { $0.close() }
        let sibling = DocumentFactory.makeUntitled()
        owned.append(sibling)
        let siblingController = try requireValue(
            sibling.windowControllers.first as? EditorWindowController, "DT fixture: sibling controller")
        let siblingToolbar = try requireValue(siblingController.window?.toolbar, "DT fixture: sibling toolbar")
        let services = EditorServices.current
        let independentComposition = AppDelegate()
        independentComposition.installEditorServices()
        let independentDocument = DocumentFactory.makeUntitled()
        owned.append(independentDocument)
        let independentToolbar = try requireValue(
            independentDocument.windowControllers.first?.window?.toolbar,
            "DT fixture: independent composition toolbar")
        let independentItems = independentToolbar.items.map(\.itemIdentifier)
        EditorServices.current = services
        check(
            independentToolbar.identifier != toolbar.identifier,
            "DT-R4 independent isolated compositions cannot share AppKit toolbar synchronization state")
        check(
            siblingToolbar.identifier == toolbar.identifier,
            "DT-R4 windows from one composition share the native toolbar family")
        let openIndex = try requireValue(
            toolbar.items.firstIndex { $0.itemIdentifier.rawValue == "TextTank.Open" }, "DT fixture: Open position")
        toolbar.removeItem(at: openIndex)
        toolbar.displayMode = .iconOnly
        toolbar.isVisible = false
        let custom = toolbar.items.map(\.itemIdentifier)
        check(
            siblingToolbar.items.map(\.itemIdentifier) == custom,
            "DT-R4 native custom arrangement synchronizes across windows")
        library.workflows[0].pinToToolbar = true
        try composition.automations.persistLibrary(library)
        check(
            independentToolbar.items.map(\.itemIdentifier) == independentItems,
            "DT-R4 updating one composition leaves an independent native toolbar family unchanged")
        let firstID = NSToolbarItem.Identifier("TextTank.Automation." + first.id.uuidString)
        for bar in [toolbar, siblingToolbar] {
            check(
                bar.items.filter { $0.itemIdentifier == firstID }.count == 1,
                "DT-R3 newly favorited automation appears once per synchronized toolbar")
            check(
                bar.items.filter { $0.itemIdentifier != firstID }.map(\.itemIdentifier) == custom,
                "DT-R3 favorite insertion preserves the customized arrangement")
        }
        check(
            toolbar.displayMode == .iconOnly && !toolbar.isVisible,
            "DT-R3 library updates preserve toolbar display mode and visibility")
        let heldFavorite = try requireValue(
            toolbar.items.first { $0.itemIdentifier == firstID }, "DT fixture: new favorite")
        library.workflows[0].name = second.name
        try composition.automations.persistLibrary(library)
        check(
            toolbar.items.first { $0.itemIdentifier == firstID } === heldFavorite && heldFavorite.label == second.name,
            "DT-R3 rename updates the existing standard item without changing its UUID binding")
        let overflow = try requireValue(heldFavorite.menuFormRepresentation, "DT fixture: favorite overflow")
        check(
            overflow.title == second.name && overflow.representedObject as? String == first.id.uuidString,
            "DT-R5 favorite overflow retains its exact UUID even when display names collide")
        composition.noteActive(controller)
        let savedFrame = window.frame, minimum = window.contentMinSize
        window.makeKeyAndOrderFront(nil)
        toolbar.isVisible = true
        toolbar.displayMode = .iconAndLabel
        heldFavorite.visibilityPriority = .low
        window.contentMinSize = NSSize(width: 180, height: minimum.height)
        window.setFrame(
            NSRect(x: savedFrame.minX, y: savedFrame.minY, width: 300, height: savedFrame.height), display: true)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        print(
            "DT_OVERFLOW", window.frame.width, window.isVisible, toolbar.items.map { $0.itemIdentifier.rawValue },
            "visible", (toolbar.visibleItems ?? []).map { $0.itemIdentifier.rawValue })
        spinUntil("DT native toolbar overflow is laid out") {
            let visible = toolbar.visibleItems ?? []
            return !visible.isEmpty && !visible.contains { $0 === heldFavorite }
        }
        check(
            !(toolbar.visibleItems ?? []).contains { $0 === heldFavorite },
            "DT-R5 the tested favorite is actually clipped into the native overflow menu")
        document.editor.text = "- 2 eggs\n"
        document.editor.resetUndoHistory()
        check(
            NSApp.sendAction(overflow.action!, to: overflow.target, from: overflow)
                && document.editor.text == "2 eggs\n",
            "DT-R5 favorite overflow executes the selected saved automation, not another identical title")
        document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(
            document.editor.text == "- 2 eggs\n",
            "DT-R5 automation invoked from overflow remains one authoritative Undo step")
        document.editor.readOnly = true
        check(
            !composition.automations.validateToolbarItem(heldFavorite)
                && !composition.automations.validateMenuItem(overflow),
            "DT-R1/R3 read-only text output is disabled consistently in toolbar and menu")
        document.editor.readOnly = false
        window.contentMinSize = minimum
        window.setFrame(savedFrame, display: true)
        toolbar.isVisible = false
        toolbar.displayMode = .iconOnly
        let secondID = NSToolbarItem.Identifier("TextTank.Automation." + second.id.uuidString)
        let removeFavoriteIndex = try requireValue(
            toolbar.items.firstIndex { $0.itemIdentifier == secondID },
            "DT fixture: customized-away favorite")
        toolbar.removeItem(at: removeFavoriteIndex)
        library.workflows[0].name = "Renamed after customization"
        try composition.automations.persistLibrary(library)
        check(
            !toolbar.items.contains { $0.itemIdentifier == secondID }
                && !siblingToolbar.items.contains { $0.itemIdentifier == secondID },
            "DT-R3 an unrelated rename does not reinsert a favorite the person customized away")
        let unpinID = firstID
        library.workflows[0].pinToToolbar = false
        try composition.automations.persistLibrary(library)
        check(
            [toolbar, siblingToolbar].allSatisfy { bar in !bar.items.contains { $0.itemIdentifier == unpinID } }
                && composition.automations.makeToolbarItem(identifier: unpinID) == nil,
            "DT-R3 unmark removes the favorite everywhere and refuses a stale saved identifier")
        let deletedID = NSToolbarItem.Identifier("TextTank.Automation." + second.id.uuidString)
        library.workflows.remove(at: 1)
        try composition.automations.persistLibrary(library)
        check(
            [toolbar, siblingToolbar].allSatisfy { bar in !bar.items.contains { $0.itemIdentifier == deletedID } },
            "DT-R3 deleting an automation removes its toolbar item without resetting core customization")
        toolbar.isVisible = true
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        check(
            document.editor.frame.width > 100 && document.editor.frame.height > 100
                && !(toolbar.visibleItems ?? []).isEmpty,
            "DT-R5 after synchronized configuration changes the real editor viewport and toolbar remain laid out")
        check(
            NSApp.sendAction(find.action!, to: controller, from: find) && controller.findBarVisible,
            "DT-R5 after synchronized configuration changes the actual Find action still dispatches")
        controller.hideFind(nil)
        let restoredIDs = ["TextTank.Find", "TextTank.Unavailable", unpinID.rawValue, "TextTank.Save", "TextTank.Find"]
        let state = EditorToolbarPreferences.Arrangement(
            identifiers: restoredIDs, displayMode: NSToolbar.DisplayMode.iconOnly.rawValue, visible: false)
        owned.forEach { $0.close() }
        owned = []
        preferences.set(try JSONEncoder().encode(state), forKey: EditorToolbarPreferences.key)
        let restored = DocumentFactory.makeUntitled()
        owned.append(restored)
        let restoredController = try requireValue(
            restored.windowControllers.first as? EditorWindowController, "DT fixture: restored controller")
        let restoredToolbar = try requireValue(restoredController.window?.toolbar, "DT fixture: restored toolbar")
        check(
            restoredToolbar.items.map { $0.itemIdentifier.rawValue } == ["TextTank.Find", "TextTank.Save"]
                && restoredToolbar.displayMode == .iconOnly && !restoredToolbar.isVisible,
            "DT-R4 owned configuration restores order, mode and visibility while ignoring stale and duplicate identifiers"
        )
        let newMenu = try requireValue(
            menuItem(#selector(AppDelegate.newDocument(_:)), in: NSApp.mainMenu), "DT fixture: menu New")
        let beforeHiddenNew = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
        check(
            newMenu.keyEquivalent == "n" && NSApp.sendAction(newMenu.action!, to: newMenu.target, from: newMenu),
            "DT-R6 File New and Command-N remain available when the toolbar is hidden and New was customized away")
        NSDocumentController.shared.documents.filter { !beforeHiddenNew.contains(ObjectIdentifier($0)) }.forEach {
            $0.close()
        }
        check(
            menuItem(#selector(NSWindow.toggleToolbarShown(_:)), in: NSApp.mainMenu) != nil
                && menuItem(#selector(NSWindow.runToolbarCustomizationPalette(_:)), in: NSApp.mainMenu) != nil,
            "DT-R4 View exposes the standard toolbar visibility and customization actions")
        check(
            !restoredToolbar.autosavesConfiguration && !EditorToolbarPreferences.nativeAutosaveAllowed
                && forbiddenDefaultsAccesses == 0,
            "DT-R4 isolation disables native autosave and never obtains the app shared-default provider")
        restoredController.saveToolbarArrangement()
        check(
            EditorToolbarPreferences.load()?.identifiers == ["TextTank.Find", "TextTank.Save"],
            "DT-R4 the shared persistence boundary writes the actual owned native configuration")
    }
}
