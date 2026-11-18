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
        let window = try requireValue(controller.hostWindow, "DT fixture: document window")
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
            !toolbar.items.contains { $0.itemIdentifier.rawValue.hasPrefix("TextTank.Automation.") }
                && !controller.toolbarAllowedItemIdentifiers(toolbar).contains {
                    $0.rawValue.hasPrefix("TextTank.Automation.")
                },
            "the default toolbar and customization palette contain no individual automations")
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
        let splitOverflow = try requireValue(split.menuFormRepresentation, "DT fixture: Clone overflow")
        let singleViewHelp = split.toolTip
        let revisionBeforeClone = document.editor.revision
        check(
            split.label == "Clone" && controller.validateToolbarItem(split) && controller.validateMenuItem(splitMenu)
                && splitMenu.state == .off && splitOverflow.state == .off,
            "DS-20/22 Clone is enabled and unchecked on the toolbar, menu and overflow before splitting")
        check(
            NSApp.sendAction(split.action!, to: controller, from: split) && controller.secondary != nil,
            "DT-R1 the standard Split item executes the actual clone action")
        check(
            controller.validateToolbarItem(split) && controller.validateMenuItem(splitMenu)
                && splitMenu.state == .on && splitOverflow.state == .on
                && split.toolTip == "Return to a single view of the current document.",
            "DS-20/22 Clone stays enabled with a checkmark and closing help after splitting")
        check(
            nativeTree(window).contains {
                nativeAttribute($0, "accessibilityLabel") == split.toolTip
                    && nativeAttribute($0, "accessibilityRole") == "AXButton"
            }, "DS-70 the actual Clone toolbar button describes returning to a single view")
        let pane = try requireValue(controller.secondary, "DT fixture: Clone pane")
        _ = pane.setSelectionAnchor(pane.utf8Data.count, caret: pane.utf8Data.count)
        pane.replaceSelection(" through clone")
        let editedRevision = document.editor.revision
        check(
            NSApp.sendAction(split.action!, to: controller, from: split)
                && controller.secondary == nil && controller.split.arrangedSubviews.count == 1
                && controller.activeEditor === document.editor,
            "DS-91 clicking Clone again closes the split and returns focus to the primary editor")
        check(
            document.editor.text == "Owned save fixture through clone" && document.isDocumentEdited
                && document.editor.revision == editedRevision && editedRevision > revisionBeforeClone,
            "closing through Clone preserves shared text, revision and edited state")
        check(
            controller.validateToolbarItem(split) && controller.validateMenuItem(splitMenu)
                && splitMenu.state == .off && splitOverflow.state == .off && split.toolTip == singleViewHelp,
            "DS-22 closing clears Clone's checked state and restores its opening help")
        document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(
            document.editor.text == "Owned save fixture",
            "the shared Undo history survives closing through Clone")
        document.editor.readOnly = true
        check(
            NSApp.sendAction(splitOverflow.action!, to: controller, from: splitOverflow) && controller.secondary != nil
                && NSApp.sendAction(splitMenu.action!, to: controller, from: splitMenu) && controller.secondary == nil,
            "DS-20 the overflow and menu toggle the same split even in a read-only document")
        document.editor.readOnly = false
        controller.clone(nil)
        controller.closeSplit(nil)
        check(
            splitOverflow.state == .off && split.toolTip == singleViewHelp && split.isEnabled,
            "the separate Close Split View action also resets the Clone toolbar state")
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
        let siblingToolbar = try requireValue(siblingController.hostWindow?.toolbar, "DT fixture: sibling toolbar")
        let services = EditorServices.current
        let independentComposition = AppDelegate()
        independentComposition.installEditorServices()
        let independentDocument = DocumentFactory.makeUntitled()
        owned.append(independentDocument)
        let independentToolbar = try requireValue(
            independentDocument.presentation?.hostWindow?.toolbar,
            "DT fixture: independent composition toolbar")
        let independentItems = independentToolbar.items.map(\.itemIdentifier)
        EditorServices.current = services
        check(
            independentToolbar.identifier != toolbar.identifier,
            "DT-R4 independent isolated compositions cannot share AppKit toolbar synchronization state")
        check(
            siblingToolbar === toolbar && siblingToolbar.identifier == toolbar.identifier,
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
                bar.items.map(\.itemIdentifier) == custom,
                "marking a favorite preserves the customized toolbar without adding buttons")
        }
        check(
            toolbar.displayMode == .iconOnly && !toolbar.isVisible,
            "library updates preserve toolbar display mode and visibility")
        check(
            controller.toolbar(toolbar, itemForItemIdentifier: firstID, willBeInsertedIntoToolbar: true) == nil,
            "a saved favorite identifier cannot recreate an individual toolbar button")
        let launcher = try requireValue(
            toolbar.items.first { $0.itemIdentifier.rawValue == "TextTank.Automations" } as? NSMenuToolbarItem,
            "fixture: Automations drop-down")
        library.workflows[0].name = second.name
        try composition.automations.persistLibrary(library)
        let invocation = try requireValue(
            launcher.menu.items.first { $0.representedObject as? String == first.id.uuidString },
            "fixture: renamed favorite in the drop-down")
        check(
            invocation.title == "★ " + second.name
                && launcher.menu.items.contains {
                    $0.representedObject as? String == second.id.uuidString && $0.title == "★ " + second.name
                } == true,
            "renamed automations with identical titles retain distinct UUID-bound drop-down actions")
        composition.noteActive(controller)
        let savedFrame = window.frame, minimum = window.contentMinSize
        document.showWindows()
        toolbar.isVisible = true
        toolbar.displayMode = .iconAndLabel
        find.visibilityPriority = .low
        // Isolate the actual native toolbar's narrow overflow test from the document's
        // Find-row minimum width. Restore the same retained view tree before dispatch.
        let retainedContent = try requireValue(window.contentView, "fixture: retained workspace content")
        window.contentView = NSView()
        window.contentMinSize = NSSize(width: 180, height: minimum.height)
        window.setFrame(
            NSRect(x: savedFrame.minX, y: savedFrame.minY, width: 450, height: savedFrame.height), display: true)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        spinUntil("native toolbar overflow is laid out") {
            NativeWindowEvents.pump()
            let visible = toolbar.visibleItems ?? []
            return !visible.isEmpty && !visible.contains { $0 === find }
        }
        print(
            "T0 TOOLBAR OVERFLOW", window.frame, window.contentMinSize,
            toolbar.visibleItems?.map { $0.itemIdentifier.rawValue } ?? [])
        check(
            !(toolbar.visibleItems ?? []).contains { $0 === find },
            "a standard command is clipped into the native overflow menu")
        let overflow = try requireValue(find.menuFormRepresentation, "fixture: Find overflow action")
        window.contentView = retainedContent
        window.setFrame(savedFrame, display: true)
        document.showWindows()
        window.contentView?.layoutSubtreeIfNeeded()
        check(document.editor.window === window, "the retained native document is mounted before overflow dispatch")
        check(
            NSApp.sendAction(overflow.action!, to: controller, from: overflow) && controller.findBarVisible,
            "the native overflow retains the standard Find action")
        controller.hideFind(nil)
        document.editor.text = "- 2 eggs\n"
        document.editor.resetUndoHistory()
        check(
            NSApp.sendAction(invocation.action!, to: invocation.target, from: invocation)
                && document.editor.text == "2 eggs\n",
            "the drop-down runs the selected UUID rather than another automation with the same title")
        document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(
            document.editor.text == "- 2 eggs\n",
            "a drop-down automation remains one authoritative Undo step")
        document.editor.readOnly = true
        check(
            !composition.automations.validateMenuItem(invocation),
            "read-only text output is disabled in the Automations drop-down")
        document.editor.readOnly = false
        window.contentMinSize = minimum
        window.setFrame(savedFrame, display: true)
        toolbar.isVisible = false
        toolbar.displayMode = .iconOnly
        library.workflows[0].pinToToolbar = false
        try composition.automations.persistLibrary(library)
        check(
            launcher.menu.items.first { $0.representedObject is String }?.representedObject as? String
                == second.id.uuidString,
            "favorites still sort first in the drop-down without appearing on the toolbar")
        library.workflows.remove(at: 1)
        try composition.automations.persistLibrary(library)
        check(
            launcher.menu.items.contains { $0.representedObject as? String == second.id.uuidString } == false
                && [toolbar, siblingToolbar].allSatisfy { $0.items.map(\.itemIdentifier) == custom },
            "deleting an automation refreshes the drop-down and preserves both customized toolbars")
        library.workflows[0].pinToToolbar = true
        try composition.automations.persistLibrary(library)
        let unpinID = firstID
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
        let restoredComposition = AppDelegate()
        restoredComposition.installEditorServices()
        defer { EditorServices.current = services }
        let restored = DocumentFactory.makeUntitled()
        owned.append(restored)
        let restoredController = try requireValue(
            restored.windowControllers.first as? EditorWindowController, "DT fixture: restored controller")
        let restoredToolbar = try requireValue(restoredController.hostWindow?.toolbar, "DT fixture: restored toolbar")
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
