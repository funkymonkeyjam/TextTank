@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

@MainActor enum DesignSettingsChecks {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func nativeText(_ value: Any, selector name: String, argument: String? = nil) -> String {
        guard let object = value as? NSObject else { return "" }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return "" }
        let result = argument.map { object.perform(selector, with: $0) } ?? object.perform(selector)
        return result?.takeUnretainedValue() as? String ?? ""
    }
    static func checkNativeButtons(_ window: NSWindow) {
        guard let content = window.contentView else {
            check(false, "DG fixture owns form content")
            return
        }
        let ids: Set<String> = [
            "settings.close", "settings.reset", "settings.font.choose", "settings.shortcuts.recorder",
            "settings.shortcuts.default", "settings.shortcuts.clear", "settings.shortcuts.resetAll",
            "settings.shortcuts.replace", "settings.shortcuts.cancel", "settings.reveal", "settings.clearLocalHistory",
            "automation.create",
            "automation.edit",
            "automation.rules", "automation.duplicate", "automation.delete", "automation.favorite", "automation.json"
        ]
        for button in descendants(content).compactMap({ $0 as? NSButton }).filter({
            let id = $0.identifier?.rawValue ?? ""
            return ids.contains(id) || id.hasPrefix("macro.manager.") || id.hasPrefix("run.manager.")
        }) {
            let exposed = NSAccessibility.unignoredChildrenForOnlyChild(from: button)
            let expected = button.accessibilityLabel() ?? ""
            let names = exposed.flatMap { element in
                [
                    nativeText(element, selector: "accessibilityLabel"),
                    nativeText(element, selector: "accessibilityTitle")
                ]
            }
            print("AX_FORM_ELEMENT", button.identifier!.rawValue, "expected=", expected, "actual=", names)
            check(
                !expected.isEmpty && expected != button.title && names.contains(expected),
                "DG actual unignored form action exposes its scoped name: \(button.identifier!.rawValue)")
        }
    }
    static func button(_ id: String, _ window: NSWindow) throws -> NSButton {
        let content = try requireValue(window.contentView, "DG fixture: owned content")
        return try requireValue(
            descendants(content).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id },
            "DG fixture: native button \(id)")
    }
    static func table(_ window: NSWindow) throws -> NSTableView {
        try requireValue(
            descendants(window.contentView!).compactMap { $0 as? NSTableView }.first, "DG fixture: manager table")
    }
    static func field(_ id: String, _ window: NSWindow) throws -> NSTextField {
        try requireValue(
            descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == id },
            "DG fixture: native field \(id)")
    }
    static func type(_ value: String, in window: NSWindow) {
        for character in value {
            let text = String(character)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
            window.sendEvent(event)
        }
    }
    static func choicePanelChecks() throws {
        func prepared(_ suffix: String, count: @escaping () -> Void) -> ChoicePanel {
            let panel = ChoicePanel(
                title: "Owned Choice", identifier: "fixture.choice." + suffix, action: "Choose",
                filterLabel: "Filter owned choices")
            panel.rows = { [.init(id: "first", title: "First item"), .init(id: "second", title: "Second item")] }
            panel.choose = { id in
                check(id == "second", "DG explicit chooser activation resolves the filtered stable identity")
                count()
                return true
            }
            panel.show()
            panel.filter.selectText(nil)
            type("second", in: panel.form.window)
            return panel
        }
        var invocations = 0
        let cancelled = prepared("cancel") { invocations += 1 }
        check(
            cancelled.table.numberOfRows == 1
                && (cancelled.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue
                    == "Second item",
            "DG typing in the real filter narrows the actual native rows")
        cancelled.form.window.makeFirstResponder(cancelled.table)
        check(invocations == 0, "DG typing and leaving a chooser filter never invokes its action")
        try button("fixture.choice.cancel.cancel", cancelled.form.window).performClick(nil)
        check(invocations == 0 && !cancelled.form.window.isVisible, "DG chooser Cancel never invokes an action")
        for action in ["button", "return", "table"] {
            let before = invocations
            let panel = prepared(action) { invocations += 1 }
            if action == "button" {
                try button("fixture.choice.button.choose", panel.form.window).performClick(nil)
            } else {
                if action == "table" { panel.form.window.makeFirstResponder(panel.table) }
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.form.window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                panel.form.window.sendEvent(event)
            }
            check(
                invocations == before + 1 && !panel.form.window.isVisible,
                "DG actual chooser \(action) activation invokes exactly once")
        }
    }
    static func settingsFrameChecks(root: URL) throws {
        // This suite runs in its own process. The public factory keeps the real AppKit
        // panel and controls while observing calls made during its close transaction.
        NSFontManager.setFontPanelFactory(CloseObservedFontPanel.self)
        defer { NSFontManager.setFontPanelFactory(nil) }

        let suite = "TextTankDesignSettingsFrames-" + UUID().uuidString
        let defaults = try requireValue(UserDefaults(suiteName: suite), "DG fixture: private frame defaults")
        let previous = WindowFrames.defaults
        WindowFrames.defaults = defaults
        defer {
            WindowFrames.defaults = previous
            defaults.removePersistentDomain(forName: suite)
        }
        try maintenanceSheetChecks(root: root)
        let controller = SettingsController(url: root.appendingPathComponent("design-settings-frames.json"))
        controller.showSettings(nil)
        let form = try requireValue(FormPanel.visible.last, "DG fixture: Settings frame")
        form.window.setContentSize(form.window.contentMinSize)
        form.window.contentView!.layoutSubtreeIfNeeded()
        let content = form.window.contentView!
        // Only the chosen pane is shown; a control of another pane cannot be clipped.
        let controls = descendants(content).compactMap { $0 as? NSControl }.filter {
            !$0.isHiddenOrHasHiddenAncestor
        }
        let clipped = controls.filter { control in
            let rect = control.convert(control.bounds, to: content)
            return rect.minX < -1 || rect.minY < -1 || rect.maxX > content.bounds.maxX + 1
                || rect.maxY > content.bounds.maxY + 1
        }
        print(
            "DG_MINIMUM_SETTINGS", content.bounds, "outside=",
            clipped.map { ($0.identifier?.rawValue ?? String(describing: Swift.type(of: $0)), $0.frame) })
        check(clipped.isEmpty, "DG Settings labels, fields and actions fit its minimum content size")
        _ = spinUntil("Settings minimum layout settles into its constrained window frame") {
            form.window.contentRect(forFrameRect: form.window.frame).height >= content.bounds.height - 1
        }
        let screen = try requireValue(NSScreen.screens.first, "DG fixture: native screen").visibleFrame
        form.window.setFrameOrigin(NSPoint(x: screen.minX + 25, y: screen.minY + 25))
        let saved = form.window.frame
        let close = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: form.window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13)!
        // The CLI has no key/main window. Bind the unchanged real File > Close metadata
        // to this owned window, rather than pretending to test global physical dispatch.
        let closeMenu = NSMenu()
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.target = form.window
        closeMenu.addItem(closeItem)
        check(
            closeMenu.performKeyEquivalent(with: close) && !form.window.isVisible,
            "DG Command-W closes the owned Settings window through the native Close menu action")
        if form.window.isVisible { form.close() }
        controller.showSettings(nil)
        let reopened = try requireValue(FormPanel.visible.last, "DG fixture: restored Settings frame")
        print(
            "DG_RESTORED_SETTINGS", "saved=", saved, "actual=", reopened.window.frame, "stored=",
            defaults.string(forKey: WindowFrames.defaultsKey("TextTank.Settings")) ?? "nil")
        check(
            reopened.window.frame == saved
                && defaults.string(forKey: WindowFrames.defaultsKey("TextTank.Settings")) != nil,
            "DG Settings restores its last frame from the explicitly injected private defaults")
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: reopened.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        reopened.window.sendEvent(escape)
        check(
            !reopened.window.isVisible && !FileManager.default.fileExists(atPath: controller.url.path),
            "DG Escape closes actual Settings without saving pending changes")
        if reopened.window.isVisible { reopened.close() }
        let unknown = #""opaque" : [123456789012345678901234567890123456789,{"fontSize":"leave this alone"}]"#
        let seed =
            #"{"version":1,"tabWidth":4,"wrap":false,"useTabs":true,"appearance":"system","shortcuts":{},"#
            + unknown + "}"
        try Data(seed.utf8).write(to: controller.url)
        controller.showSettings(nil)
        let live = try requireValue(FormPanel.visible.last, "fixture: live Settings")
        let size = try field("settings.font.size", live.window), font = try button("settings.font.choose", live.window)
        check(
            font.acceptsFirstResponder && font.accessibilityLabel()?.contains("Settings") == true,
            "the native editor font button exposes a scoped name and accepts keyboard focus")
        size.stringValue = "18.75"
        _ = NSApp.sendAction(size.action!, to: size.target, from: size)
        let savedBytes = try Data(contentsOf: controller.url)
        let decoded = try EditorSettings.decode(savedBytes)
        check(
            live.window.isVisible && controller.value.fontSize == 18.75 && decoded.fontSize == 18.75,
            "committing fractional size persists it without closing modeless Settings")
        check(
            savedBytes == Data((String(seed.dropLast()) + #","fontSize":18.75}"#).utf8),
            "a live size commit preserves every original byte outside the new member")
        size.stringValue = "73"
        _ = NSApp.sendAction(size.action!, to: size.target, from: size)
        let unchanged = try Data(contentsOf: controller.url)
        check(
            size.stringValue == "73" && live.window.isVisible && unchanged == savedBytes,
            "invalid font size keeps the draft and previous settings bytes")
        font.performClick(nil)
        size.stringValue = "31.75"
        _ = NSApp.sendAction(size.action!, to: size.target, from: size)
        font.performClick(nil)
        check(
            NSFontManager.shared.selectedFont?.pointSize == 31.75 && controller.value.fontSize == 31.75,
            "reopening the native Font panel retains the live field's latest fractional size")
        let panel = try requireValue(
            NSFontManager.shared.fontPanel(false) as? CloseObservedFontPanel, "native font panel")
        let beforeClose = try Data(contentsOf: controller.url)
        let fontClose = try requireValue(panel.standardWindowButton(.closeButton), "Fonts red close button")
        fontClose.performClick(nil)
        check(
            panel.closeCount == 1 && panel.closingReloads == 0 && !panel.isVisible && live.window.isVisible,
            "closing Fonts leaves Settings open and never reloads the closing family browser")
        check(try Data(contentsOf: controller.url) == beforeClose, "closing Fonts changes no preference bytes")
        font.performClick(nil)
        check(panel.isVisible, "the same shared Fonts panel can be reopened")
        live.close()
        check(!panel.isVisible, "closing Settings retires its reopened Fonts panel")
    }
    /// Chooses a pane the way a click on its toolbar item does.
    static func choosePane(_ pane: String, in window: NSWindow) throws {
        let item = try requireValue(
            window.toolbar?.items.first { $0.itemIdentifier.rawValue == "settings.pane." + pane },
            "DG fixture: Settings toolbar item \(pane)")
        _ = NSApp.sendAction(try requireValue(item.action, "DG fixture: pane action"), to: item.target, from: item)
        window.contentView?.layoutSubtreeIfNeeded()
    }
    /// The settings the window shows now, by the identifier of each one's first control.
    static func shownSettings(_ window: NSWindow) -> [String] {
        descendants(window.contentView!).compactMap { view in
            guard let id = view.identifier?.rawValue, id.hasSuffix(".row"), !view.isHiddenOrHasHiddenAncestor
            else { return nil }
            return String(id.dropLast(4))
        }
    }
    static func control<T: NSView>(_ id: String, _ window: NSWindow, as type: T.Type = T.self) throws -> T {
        try requireValue(
            descendants(window.contentView!).compactMap { $0 as? T }.first { $0.identifier?.rawValue == id },
            "DG fixture: Settings control \(id)")
    }
    static func search(_ text: String, in window: NSWindow) throws {
        let filter: NSSearchField = try control("settings.filter", window)
        filter.stringValue = text
        _ = NSApp.sendAction(try requireValue(filter.action, "DG fixture: search action"), to: filter.target, from: filter)
        window.contentView?.layoutSubtreeIfNeeded()
    }
    /// V6: panes, the search field, Changed from default, Use Default and Reveal in Finder.
    static func settingsPaneChecks(root: URL) throws {
        let url = root.appendingPathComponent("settings-panes.json")
        let controller = SettingsController(url: url)
        let existing = Set(FormPanel.visible.map(ObjectIdentifier.init))
        defer { for form in FormPanel.visible where !existing.contains(ObjectIdentifier(form)) { form.close() } }
        controller.showSettings(nil)
        let form = try requireValue(FormPanel.visible.last, "V6 fixture: Settings")
        let window = form.window
        let toolbar = try requireValue(window.toolbar, "V6 fixture: Settings toolbar")
        check(
            toolbar.items.map(\.label) == ["Editing", "Appearance", "Files", "Previews", "Shortcuts"]
                && window.toolbarStyle == .preference && toolbar.selectedItemIdentifier?.rawValue == "settings.pane.editing"
                && toolbar.items.allSatisfy { $0.image != nil },
            "V6 Settings switches five panes from a preference-style toolbar and opens on Editing")
        // Every setting of the flat window, and the stored toggles that had no control, by pane.
        let expected: [(String, [String])] = [
            ("editing", ["settings.width", "settings.tabs", "settings.autoIndent", "settings.autoPair", "settings.wrap"]),
            (
                "appearance",
                [
                    "settings.appearance", "settings.font.choose", "settings.font.size", "settings.font.zoom",
                    "settings.indentGuides", "settings.currentLineHighlight", "settings.braceHighlight",
                    "settings.lineNumbers", "settings.showWhitespace", "settings.showLineEndings",
                    "settings.changeBars", "settings.centeredColumn", "settings.centeredColumn.width"
                ]
            ),
            (
                "files",
                [
                    "settings.atLaunch", "settings.externalChanges", "settings.keepUntitledOnQuit",
                    "settings.keepLocalHistory", "settings.clearLocalHistory", "settings.reveal"
                ]
            ),
            ("previews", ["settings.preview.openIn", "settings.syncPreviewScrolling"]),
            ("shortcuts", ["settings.shortcuts"])
        ]
        var heights: [String: CGFloat] = [:]
        for (pane, settings) in expected {
            try choosePane(pane, in: window)
            let content = try requireValue(window.contentView, "V6 fixture: content")
            heights[pane] = content.bounds.height
            check(
                shownSettings(window) == settings && toolbar.selectedItemIdentifier?.rawValue == "settings.pane." + pane,
                "V6 the \(pane) pane lists exactly its settings: \(shownSettings(window))")
            check(
                abs(content.bounds.height - content.fittingSize.height) <= 1
                    && abs(content.bounds.width - 620) <= 1,
                "V6 the \(pane) pane is as tall as its content: \(content.bounds.size) fits \(content.fittingSize)")
        }
        check(
            Set(heights.values.map { Int($0) }).count >= 3,
            "V6 panes with different content have different heights: \(heights)")
        for id in [
            "settings.width", "settings.tabs", "settings.wrap", "settings.appearance", "settings.atLaunch",
            "settings.externalChanges", "settings.preview.format", "settings.preview.openIn", "settings.font.choose",
            "settings.font.size", "settings.font.zoom", "settings.reset", "settings.close"
        ] {
            let found = descendants(window.contentView!).first { $0.identifier?.rawValue == id }
            check(
                found != nil && !(found?.accessibilityLabel() ?? "").isEmpty,
                "V6 the control \(id) of the flat window is still there, with its accessibility label")
        }
        let unnamed = descendants(window.contentView!).compactMap { $0 as? NSControl }.filter {
            // A label's text is its own name; every control a person operates needs one.
            ($0.identifier?.rawValue ?? "").hasPrefix("settings.") && ($0 as? NSTextField)?.isEditable != false
                && ($0.accessibilityLabel() ?? "").isEmpty
        }
        check(unnamed.isEmpty, "V6 DS-70 every Settings control has an accessibility label: \(unnamed.map { $0.identifier!.rawValue })")

        // Short number fields with steppers, saved when stepped.
        try choosePane("editing", in: window)
        let width = try field("settings.width", window)
        let stepper: NSStepper = try control("settings.width.stepper", window)
        check(width.frame.width <= 60, "V6 a one- or two-digit number has a short field, not one \(width.frame.width) points wide")
        stepper.integerValue = 5
        _ = NSApp.sendAction(try requireValue(stepper.action, "V6 fixture: stepper action"), to: stepper.target, from: stepper)
        check(
            controller.value.tabWidth == 5 && width.stringValue == "5" && SettingsStore(url: url).value.tabWidth == 5
                && stepper.minValue == 1 && stepper.maxValue == 32,
            "V6 the tab width stepper saves at once, within 1 to 32")

        // The search field.
        try search("wrap", in: window)
        check(
            shownSettings(window) == ["settings.wrap"] && toolbar.selectedItemIdentifier == nil,
            "V6 typing “wrap” shows only the matching setting: \(shownSettings(window))")
        let content = try requireValue(window.contentView, "V6 fixture: content")
        check(
            abs(content.bounds.height - content.fittingSize.height) <= 1,
            "V6 the window is as tall as the search results")
        try search("THEME", in: window)
        check(shownSettings(window) == ["settings.appearance"], "V6 a synonym finds a setting in another pane, in any case")
        try search("startup", in: window)
        check(shownSettings(window) == ["settings.atLaunch"], "V6 “startup” finds At launch")
        try search("file ask", in: window)
        check(
            shownSettings(window) == ["settings.externalChanges"],
            "V6 every word typed must match, in the label or a synonym: \(shownSettings(window))")
        try search("indent", in: window)
        check(
            shownSettings(window) == ["settings.width", "settings.tabs", "settings.autoIndent", "settings.indentGuides"],
            "V6 one word lists matching settings across panes, in pane order: \(shownSettings(window))")
        NativeFixtureEnvironment.announcements = []
        try search("zzzz", in: window)
        let empty = try field("settings.filter.empty", window)
        check(
            shownSettings(window).isEmpty && !empty.isHidden && empty.stringValue.contains("zzzz")
                && NativeFixtureEnvironment.announcements.contains(empty.stringValue),
            "V6 DS-36 a search that finds nothing says so in words and is announced")
        try search("", in: window)
        check(
            shownSettings(window) == expected[0].1 && empty.isHidden
                && toolbar.selectedItemIdentifier?.rawValue == "settings.pane.editing",
            "V6 clearing the search returns to the pane that was chosen")
        let find = try requireValue(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f",
                isARepeat: false, keyCode: 3), "V6 fixture: Command-F")
        let filter: NSSearchField = try control("settings.filter", window)
        check(
            window.performKeyEquivalent(with: find) && window.firstResponder === filter.currentEditor(),
            "V6 DS-73 Command-F moves to the search field from the keyboard")
        window.makeFirstResponder(nil)
        try search("wrap", in: window)
        try choosePane("files", in: window)
        check(
            filter.stringValue.isEmpty && shownSettings(window) == expected[2].1,
            "V6 choosing a pane leaves the search and shows that pane")

        // Changed from default.
        let changed: NSButton = try control("settings.filter.changed", window)
        var custom = EditorSettings()
        custom.tabWidth = 9
        custom.wrap = true
        custom.appearance = "dark"
        custom.autoPair = true
        custom.currentLineHighlight = true  // stored, but the default value: not a change
        try controller.save(custom)
        changed.performClick(nil)
        check(
            shownSettings(window) == ["settings.width", "settings.autoPair", "settings.wrap", "settings.appearance"],
            "V6 Changed from default lists exactly the settings that differ: \(shownSettings(window))")
        let defaults = descendants(window.contentView!).compactMap { $0 as? NSButton }.filter {
            ($0.identifier?.rawValue ?? "").hasSuffix(".default") && !$0.isHiddenOrHasHiddenAncestor
        }
        check(
            defaults.map { $0.identifier!.rawValue } == [
                "settings.width.default", "settings.autoPair.default", "settings.wrap.default",
                "settings.appearance.default"
            ] && defaults.allSatisfy { $0.title == "Use Default" && $0.accessibilityLabel()?.hasPrefix("Use the default for ") == true },
            "V6 each changed setting has its own named way back to its default")
        let wrapDefault: NSButton = try control("settings.wrap.default", window)
        wrapDefault.performClick(nil)
        check(
            !controller.value.wrap && controller.value.tabWidth == 9 && !SettingsStore(url: url).value.wrap
                && shownSettings(window) == ["settings.width", "settings.autoPair", "settings.appearance"],
            "V6 Use Default returns one setting to its default, saves at once and leaves the others")
        try control("settings.width.default", window, as: NSButton.self).performClick(nil)
        check(
            controller.value.tabWidth == 4 && width.stringValue == "4",
            "V6 Use Default on a number field shows and saves the default")
        try control("settings.autoPair.default", window, as: NSButton.self).performClick(nil)
        try control("settings.appearance.default", window, as: NSButton.self).performClick(nil)
        var cleared = EditorSettings()
        cleared.currentLineHighlight = true
        check(
            controller.value == cleared && shownSettings(window).isEmpty && !empty.isHidden
                && empty.stringValue.contains("default"),
            "V6 with nothing changed the list is empty and says why: \(empty.stringValue)")
        try search("wrap", in: window)
        check(shownSettings(window).isEmpty, "V6 the search narrows Changed from default; it does not widen it")
        try search("", in: window)
        changed.performClick(nil)
        check(shownSettings(window) == expected[2].1, "V6 turning the filter off returns to the chosen pane")

        // The rows the other slices' stored keys got through the extension point: each is found
        // by the search, saves when clicked, and is listed by Changed from default while it differs.
        let added: [(id: String, word: String, read: (EditorSettings) -> Bool, standard: Bool)] = [
            ("settings.lineNumbers", "gutter", { $0.lineNumbersEnabled }, true),
            ("settings.showWhitespace", "whitespace", { $0.showWhitespaceEnabled }, false),
            ("settings.showLineEndings", "crlf", { $0.showLineEndingsEnabled }, false),
            ("settings.changeBars", "change bars", { $0.changeBarsEnabled }, false),
            ("settings.centeredColumn", "center text", { $0.centeredColumnEnabled }, false),
            ("settings.syncPreviewScrolling", "sync scrolling", { $0.syncsPreviewScrolling }, true),
            ("settings.keepUntitledOnQuit", "untitled quitting", { $0.keepsUntitledOnQuit }, true),
            ("settings.keepLocalHistory", "earlier versions saving", { $0.keepsLocalHistory }, true)
        ]
        for row in added {
            try search(row.word, in: window)
            check(shownSettings(window) == [row.id], "V6 “\(row.word)” finds \(row.id): \(shownSettings(window))")
            let box: NSButton = try control(row.id, window)
            check(
                (box.state == .on) == row.standard && !(box.accessibilityLabel() ?? "").isEmpty,
                "V6 \(row.id) shows its default and is labelled")
            box.performClick(nil)
            try search("", in: window)
            changed.performClick(nil)
            check(
                row.read(controller.value) != row.standard && row.read(SettingsStore(url: url).value) != row.standard
                    && shownSettings(window) == [row.id],
                "V6 \(row.id) saves when clicked and is then the one changed setting: \(shownSettings(window))")
            try control(row.id + ".default", window, as: NSButton.self).performClick(nil)
            check(
                row.read(controller.value) == row.standard && shownSettings(window).isEmpty,
                "V6 Use Default returns \(row.id) to its default")
            changed.performClick(nil)
        }
        try search("local history", in: window)
        let clearHistory: NSButton = try control("settings.clearLocalHistory", window)
        check(
            shownSettings(window) == ["settings.keepLocalHistory", "settings.clearLocalHistory"]
                && clearHistory.title == "Clear Local History…" && clearHistory.action != nil,
            "V6 Clear Local History… is a row of the Files pane, found with the setting it belongs to")
        try search("", in: window)

        // Stored view toggles: one helper lists each of them (the row extension point).
        try choosePane("editing", in: window)
        let autoIndent: NSButton = try control("settings.autoIndent", window)
        check(autoIndent.state == .on, "V6 fixture: Auto-indent starts on")
        autoIndent.performClick(nil)
        check(
            !controller.value.autoIndentEnabled && SettingsStore(url: url).value.autoIndent == false,
            "V6 a checkbox for a stored toggle saves when clicked")
        controller.toggleAutoIndent(nil)
        check(
            controller.value.autoIndentEnabled && autoIndent.state == .on,
            "V6 the checkbox follows the same setting changed from its menu command")

        // Reveal Settings File in Finder never reaches Finder from a check.
        let reveal = StoreRecovery.reveal
        defer { StoreRecovery.reveal = reveal }
        var revealed: [URL] = []
        StoreRecovery.reveal = { revealed.append($0) }
        try choosePane("files", in: window)
        let revealButton: NSButton = try control("settings.reveal", window)
        check(
            revealButton.title == "Reveal Settings File in Finder" && !(revealButton.accessibilityLabel() ?? "").isEmpty,
            "V6 the Files pane has Reveal Settings File in Finder")
        revealButton.performClick(nil)
        check(revealed == [url], "V6 it shows the settings file itself")
        form.close()
        let fresh = SettingsController(url: root.appendingPathComponent("settings-panes-absent.json"))
        fresh.showSettings(nil)
        let freshForm = try requireValue(FormPanel.visible.last, "V6 fixture: Settings before any save")
        revealed = []
        try control("settings.reveal", freshForm.window, as: NSButton.self).performClick(nil)
        check(
            revealed.map(\.path) == [root.path] && !FileManager.default.fileExists(atPath: fresh.url.path),
            "V6 before any setting is saved it shows the folder, and creates no file")
        freshForm.close()
    }
    /// Drives the Shortcuts pane through its own controls: the list, the search field and the recorder.
    @MainActor struct ShortcutPaneDriver {
        let window: NSWindow, table: NSTableView, recorder: ShortcutRecorder
        let message: NSTextField, note: NSTextField, search: NSSearchField
        init(_ window: NSWindow) throws {
            self.window = window
            table = try DesignSettingsChecks.control("settings.shortcuts.list", window)
            recorder = try DesignSettingsChecks.control("settings.shortcuts.recorder", window)
            message = try DesignSettingsChecks.field("settings.shortcuts.message", window)
            note = try DesignSettingsChecks.field("settings.shortcuts.note", window)
            search = try DesignSettingsChecks.control("settings.shortcuts.search", window)
        }
        func text(_ row: Int, _ column: Int) -> String {
            (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue ?? ""
        }
        func listed() -> [String] { (0..<table.numberOfRows).map { text($0, 0) } }
        func row(_ title: String) throws -> Int {
            try requireValue((0..<table.numberOfRows).first { text($0, 0) == title }, "V8 fixture: the command \(title)")
        }
        func select(_ title: String) throws {
            table.selectRowIndexes([try row(title)], byExtendingSelection: false)
        }
        func find(_ words: String) throws {
            search.stringValue = words
            _ = NSApp.sendAction(try requireValue(search.action, "V8 fixture: search"), to: search.target, from: search)
        }
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 0) throws -> NSEvent {
            try requireValue(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code), "V8 fixture: key press")
        }
        /// Clicks the recorder and presses a key, as a person does.
        func press(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 0) throws {
            recorder.performClick(nil)
            try require(recorder.isRecording && window.firstResponder === recorder, "V8 fixture: the recorder is recording")
            window.sendEvent(try key(characters, flags, code: code))
        }
        func button(_ id: String) throws -> NSButton { try DesignSettingsChecks.control("settings.shortcuts." + id, window) }
        /// The command of the selected row, or nil.
        var selectedTitle: String? { table.selectedRow >= 0 ? text(table.selectedRow, 0) : nil }
    }
    /// V8, in the real menu bar: the list of every command, the recorder, a key in use, a
    /// reserved key, Replace, Use Default, Reset All Shortcuts and the live menu.
    static func shortcutPaneChecks(composition: AppDelegate) throws {
        let settings = composition.settings
        let bar = try requireValue(NSApp.mainMenu, "V8 fixture: the menu bar")
        settings.showSettings(nil)
        let form = try requireValue(
            FormPanel.visible.last { $0.window.identifier?.rawValue == "TextTank.Settings" }, "V8 fixture: Settings")
        defer {
            form.close()
            // Whatever a failed check left behind, the application's menu bar gets its defaults back.
            _ = try? settings.save(EditorSettings())
        }
        let window = form.window
        try choosePane("shortcuts", in: window)
        let pane = try ShortcutPaneDriver(window)
        let table = pane.table, recorder = pane.recorder, message = pane.message, note = pane.note
        func text(_ row: Int, _ column: Int) -> String { pane.text(row, column) }
        func listed() -> [String] { pane.listed() }
        func row(_ title: String) throws -> Int { try pane.row(title) }
        func select(_ title: String) throws { try pane.select(title) }
        func find(_ words: String) throws { try pane.find(words) }
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 0) throws -> NSEvent {
            try pane.key(characters, flags, code: code)
        }
        func press(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 0) throws {
            try pane.press(characters, flags, code: code)
        }
        func button(_ id: String) throws -> NSButton { try pane.button(id) }
        func item(_ action: String) throws -> NSMenuItem {
            func search(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if !item.isHidden, item.action.map(NSStringFromSelector) == action { return item }
                    if let found = item.submenu.flatMap(search) { return found }
                }
                return nil
            }
            return try requireValue(search(bar), "V8 fixture: the menu item for \(action)")
        }
        check(
            table.accessibilityLabel() == "Commands and their shortcuts"
                && ["default", "clear", "resetAll", "replace", "cancel"].allSatisfy {
                    !((try? button($0))?.accessibilityLabel() ?? "").isEmpty
                },
            "V8 DS-70 the list and every button of the pane have accessibility labels")

        // The recorder as assistive technology finds it in the window: a button named for the
        // selected command, whose value is that command's key, following the selection.
        for (title, value) in [("File › New", "Command-N"), ("File › Save Copy…", "no shortcut")] {
            try select(title)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let purpose = "Record a shortcut for \(title), now \(value)"
            check(
                nativeTree(window).contains {
                    exposes($0, purpose: purpose, role: "AXButton")
                        && modernAttribute($0, "accessibilityValue") as? String == value
                } && recorder.accessibilityHelp() == nil,
                "V8 DS-70 the window's accessibility tree has the recorder as a button named “\(purpose)” with that value")
        }
        table.deselectAll(nil)
        // The list takes the height the window gives the pane.
        let scroll: NSScrollView = try control("settings.shortcuts.scroll", window)
        let content = try requireValue(window.contentView, "V8 fixture: content")
        content.layoutSubtreeIfNeeded()
        let listHeight = scroll.frame.height, paneHeight = content.bounds.height, recorderHeight = recorder.frame.height
        check(
            abs(listHeight - 240) <= 1 && window.contentMinSize.height == paneHeight
                && window.contentMaxSize.height >= paneHeight + 1000,
            "V8 the Shortcuts pane opens with its list at the least height and can be made taller: \(listHeight)")
        var taller = window.frame
        taller.size.height += 160
        taller.origin.y -= 160
        window.setFrame(taller, display: true)
        content.layoutSubtreeIfNeeded()
        check(
            abs(scroll.frame.height - (listHeight + 160)) <= 1 && recorder.frame.height == recorderHeight
                && abs(content.bounds.height - (paneHeight + 160)) <= 1,
            "V8 a taller window gives all of the extra height to the list: \(scroll.frame.height)")
        try find("save")
        try find("")
        content.layoutSubtreeIfNeeded()
        check(
            abs(scroll.frame.height - (listHeight + 160)) <= 1,
            "V8 the list keeps the height the person gave it while the pane is in use")
        try choosePane("editing", in: window)
        check(
            window.contentMaxSize == window.contentMinSize && content.bounds.height < paneHeight,
            "V8 another pane is exactly its content again")
        try choosePane("shortcuts", in: window)
        content.layoutSubtreeIfNeeded()
        check(abs(scroll.frame.height - listHeight) <= 1, "V8 fixture: the list is at its least height again")

        // (a) Every command, with its key and whether that is the default.
        let palette = composition.commandDiscovery.commands(in: bar)
        let titles = Set(listed())
        let missing = palette.map(\.path).filter { !titles.contains($0) }
        check(
            missing.isEmpty && titles.contains("Help › Command Palette…") && titles.count == listed().count,
            "V8 the list has every command the Command Palette has, once each (missing: \(missing.prefix(5)))")
        let save = try row("File › Save"), quit = try row("TextTank › Quit TextTank")
        check(
            try text(save, 1) == "⌘S" && text(save, 2) == "Default" && text(try row("File › Save Copy…"), 1).isEmpty
                && text(try row("File › Save Copy…"), 2) == "None"
                && text(try row("Edit › Lines › Move Line Up"), 1) == "⌃⌘↑",
            "V8 each command shows its current key and that it is the default")
        try select("TextTank › Quit TextTank")
        check(
            text(quit, 1) == "⌘Q" && text(quit, 2) == "System" && !recorder.isEnabled && !note.isHidden
                && note.stringValue.contains("quits TextTank"),
            "V8 DS-25 a system shortcut is listed, cannot be recorded over, and says why")
        // The function key's own name is pinned in SettingsShortcutValidationChecks.storedForms.
        let recordKey = MenuShortcut.recordMacro.displayText
        try select("Tools › Macros › Start Recording")
        check(
            text(try row("Tools › Macros › Start Recording"), 1) == recordKey && !recorder.isEnabled
                && note.stringValue.contains(recordKey + " starts and stops recording"),
            "V8 a macro key is shown read-only with the reason")
        let automation = try requireValue(
            listed().first { $0.hasPrefix("Tools › Automations › ") && !$0.hasSuffix("…") },
            "V8 fixture: a saved automation in the list")
        try select(automation)
        check(
            text(try row(automation), 2) == "Fixed" && !recorder.isEnabled
                && note.stringValue.contains("Tools › Automations › Manage Automations…"),
            "V8 an automation's own shortcut is shown read-only with where to change it")
        // Commands the other slices added are ordinary rows: each can be given a key.
        for (title, key, status) in [
            ("File › Quick Open…", "⇧⌘O", "Default"), ("View › Preview › Toggle Preview", "⌃⌘V", "Default"),
            ("Compare › Compare with Earlier Version…", "", "None"), ("Compare › Clear Local History…", "", "None"),
            ("View › Show › Whitespace", "", "None"), ("View › Show › Line Endings", "", "None"),
            ("View › Show › Line Numbers", "", "None")
        ] {
            try select(title)
            check(
                try text(try row(title), 1) == key && text(try row(title), 2) == status && recorder.isEnabled,
                "V8 \(title) is in the list and can be given a shortcut")
        }
        try find("copy save")
        check(
            listed() == ["File › Save Copy…"], "V8 the list is searched by the words of a command: \(listed())")
        try find("⌘S")
        check(listed().contains("File › Save") && listed().allSatisfy { !$0.isEmpty }, "V8 and by a key as it is shown")
        try find("command-control-v")
        check(listed().isEmpty, "V8 fixture: modifiers are said in the menu bar's order")
        try find("control-command-v")
        check(listed() == ["View › Preview › Toggle Preview"], "V8 and by a key in words: \(listed())")
        try find("")

        // (b) The recorder: a bare key and a reserved key are refused with the reason.
        let original = settings.value
        try select("Edit › Lines › Duplicate Line")
        check(
            try !listed().contains { $0.contains("duplicateLine") } && recorder.title == "⌘D"
                && text(try row("Edit › Lines › Duplicate Line"), 1) == "⌘D"
                && !FileManager.default.fileExists(atPath: settings.url.path),
            "G396 Settings shows readable command names and the selected current shortcut, and reading saves nothing")
        try select("File › New")
        check(
            recorder.isEnabled && recorder.title == "⌘N"
                && recorder.accessibilityLabel() == "Record a shortcut for File › New, now Command-N",
            "V8 DS-70 the recorder shows the selected command's key and names what it records")
        NativeFixtureEnvironment.announcements = []
        try press("k", [])
        check(
            settings.value == original && !recorder.isRecording && message.stringValue.contains("K would type text")
                && NativeFixtureEnvironment.announcements.contains(message.stringValue),
            "V8 a bare key that would type text is refused, in words that are announced: \(message.stringValue)")
        try press("q", .command, code: 12)
        check(
            settings.value == original && message.stringValue.contains("Command-Q quits TextTank.")
                && message.stringValue.contains("cannot be given to another command"),
            "V8 DS-25 a reserved system shortcut is refused with its reason: \(message.stringValue)")
        try press("\u{f70c}", .function, code: 101)
        check(
            settings.value == original
                && message.stringValue.contains(recordKey + " is used by “Tools › Macros › Start Recording”"),
            "V8 a key of a command that cannot change is refused, naming the command: \(message.stringValue)")
        recorder.performClick(nil)
        window.sendEvent(try key("\u{1b}", [], code: 53))
        check(
            !recorder.isRecording && settings.value == original && window.isVisible,
            "V8 Escape ends recording, changes nothing and leaves Settings open")

        // Control-Option-K for a File command, live in the menu bar.
        let new = try item("newDocument:")
        try press("k", [.control, .option], code: 40)
        check(
            try settings.value.shortcuts == ["newDocument:": "ctrl+opt+k"] && settings.value.version == 2
                && SettingsStore(url: settings.url).value.shortcuts == settings.value.shortcuts
                && text(try row("File › New"), 1) == "⌃⌥K" && text(try row("File › New"), 2) == "Custom"
                && message.stringValue == "“File › New” now uses Control-Option-K.",
            "V8 recording Control-Option-K for File › New saves it at once: \(settings.value.shortcuts) \(message.stringValue)")
        check(
            new.keyEquivalent == "k" && new.keyEquivalentModifierMask == [.control, .option],
            "V8 the menu item has the key at once")
        let documents = NSDocumentController.shared.documents.count
        check(
            bar.performKeyEquivalent(with: try key("k", [.control, .option], code: 40))
                && NSDocumentController.shared.documents.count == documents + 1,
            "V8 Control-Option-K runs File › New from the menu's key equivalent")
        check(
            !bar.performKeyEquivalent(with: try key("n", .command, code: 45))
                && NSDocumentController.shared.documents.count == documents + 1,
            "V8 and its former key no longer does")
        NSDocumentController.shared.documents.forEach { $0.close() }
        let entry = try requireValue(
            composition.commandDiscovery.commands(in: bar).first { $0.path == "File › New" },
            "V8 fixture: File › New in the Command Palette")
        check(
            entry.row.accessory == "⌃⌥K" && entry.row.accessory == MenuShortcut(new)?.displayText
                && entry.row.accessoryLabel == "Shortcut Control-Option-K"
                && palette.first { $0.path == "File › Save" }?.row.accessory == "⌘S",
            "V8 DS-20 the Command Palette shows the same key in the same form")

        // (c) A key in use names the clash and offers Replace or Cancel.
        let open = try item("openDocument:")
        try select("File › Open…")
        try press("k", [.control, .option], code: 40)
        let replace = try button("replace"), cancel = try button("cancel")
        check(
            settings.value.shortcuts == ["newDocument:": "ctrl+opt+k"] && !replace.isHidden && !cancel.isHidden
                && replace.hasDestructiveAction && replace.keyEquivalent.isEmpty
                && message.stringValue.hasPrefix("Control-Option-K is already used by “File › New”.")
                && open.keyEquivalent == "o",
            "V8 recording a key in use names the command that has it and changes nothing yet: \(message.stringValue)")
        cancel.performClick(nil)
        check(
            settings.value.shortcuts == ["newDocument:": "ctrl+opt+k"] && replace.isHidden && cancel.isHidden
                && message.stringValue == "The shortcut was not changed.",
            "V8 Cancel keeps both shortcuts as they were")
        try press("k", [.control, .option], code: 40)
        try button("replace").performClick(nil)
        check(
            try settings.value.shortcuts == ["openDocument:": "ctrl+opt+k", "newDocument:": ""] && replace.isHidden
                && open.keyEquivalent == "k" && open.keyEquivalentModifierMask == [.control, .option]
                && new.keyEquivalent.isEmpty && text(try row("File › New"), 2) == "Custom: none"
                && text(try row("File › Open…"), 1) == "⌃⌥K",
            "V8 Replace gives the key to the command and leaves the other without one: \(settings.value.shortcuts)")

        // A yielding default gives way without a question, and shows that it did.
        let toggle = try item("toggleDocumentPreview:")
        try select("Edit › Convert Case › Uppercase")
        try press("v", [.control, .command], code: 9)
        check(
            try settings.value.shortcuts["upper"] == "ctrl+cmd+v" && replace.isHidden && toggle.keyEquivalent.isEmpty
                && text(try row("View › Preview › Toggle Preview"), 1).isEmpty
                && text(try row("View › Preview › Toggle Preview"), 2) == "Default, given up",
            "V8 a yielding default gives way to the assignment and the list says so")

        // Quick Open's Shift-Command-O is a yielding default too.
        let quickOpen = try item("quickOpen:")
        try select("Edit › Convert Case › Lowercase")
        try press("O", [.command, .shift], code: 31)
        check(
            try settings.value.shortcuts["lower"] == "O" && replace.isHidden && quickOpen.keyEquivalent.isEmpty
                && text(try row("File › Quick Open…"), 2) == "Default, given up",
            "V8 Quick Open gives Shift-Command-O to an assignment without a question")
        try button("default").performClick(nil)
        check(
            settings.value.shortcuts["lower"] == nil && quickOpen.keyEquivalent == "O"
                && quickOpen.keyEquivalentModifierMask == .command,
            "V8 and has it again when the assignment goes")
        // A view toggle added by another slice takes a key and runs from it.
        try select("View › Show › Whitespace")
        try press("w", [.control, .option], code: 13)
        let whitespace = settings.value.showWhitespaceEnabled
        check(
            try settings.value.shortcuts["showWhitespace"] == "ctrl+opt+w"
                && text(try row("View › Show › Whitespace"), 1) == "⌃⌥W",
            "V8 View › Show › Whitespace takes Control-Option-W")
        try button("default").performClick(nil)
        check(settings.value.shortcuts["showWhitespace"] == nil && settings.value.showWhitespaceEnabled == whitespace,
            "V8 fixture: the toggle's shortcut is removed and its setting was not touched")

        // Changed from default narrows the list to the commands that were changed.
        let changed: NSButton = try control("settings.filter.changed", window)
        changed.performClick(nil)
        check(
            shownSettings(window) == ["settings.shortcuts"]
                && listed() == ["File › New", "File › Open…", "Edit › Convert Case › Uppercase"],
            "V8 Changed from default lists exactly the commands whose shortcut was changed: \(listed())")
        changed.performClick(nil)
        try choosePane("shortcuts", in: window)

        // (d) Reset one, then Reset all.
        try select("Edit › Lines › Delete Line")
        try press("k", .command, code: 40)
        try select("Edit › Lines › Duplicate Line")
        try press("j", .command, code: 38)
        check(
            try settings.value.shortcuts["deleteLine"] == "k" && settings.value.shortcuts["duplicateLine"] == "j"
                && settings.value.shortcuts["upper"] == "ctrl+cmd+v" && text(try row("Edit › Lines › Delete Line"), 1) == "⌘K",
            "G396 the real Settings list keeps several assignments, each saved as it is made")
        try button("default").performClick(nil)
        try select("Edit › Lines › Delete Line")
        try button("default").performClick(nil)
        check(
            try settings.value.shortcuts["deleteLine"] == nil && settings.value.shortcuts["duplicateLine"] == nil
                && text(try row("Edit › Lines › Duplicate Line"), 1) == "⌘D"
                && text(try row("Edit › Lines › Delete Line"), 1) == "⌃⇧K"
                && SettingsStore(url: settings.url).value.shortcuts == settings.value.shortcuts,
            "G396 Use Default restores each command's default without adding default or empty overrides")
        try select("Edit › Convert Case › Uppercase")
        try button("default").performClick(nil)
        check(
            try settings.value.shortcuts["upper"] == nil && toggle.keyEquivalent == "v"
                && toggle.keyEquivalentModifierMask == [.control, .command] && text(try row("View › Preview › Toggle Preview"), 2) == "Default",
            "V8 Use Default removes one assignment and the yielding default has its key again")
        try select("File › New")
        try button("default").performClick(nil)
        check(
            try settings.value.shortcuts == ["openDocument:": "ctrl+opt+k"] && new.keyEquivalent == "n"
                && new.keyEquivalentModifierMask == .command && !(try button("default")).isEnabled,
            "V8 Use Default returns a command that had no key to its default")
        try select("File › Open…")
        try button("clear").performClick(nil)
        check(
            settings.value.shortcuts == ["openDocument:": ""] && open.keyEquivalent.isEmpty,
            "V8 Clear Shortcut leaves a command without a key")
        try select("File › Save Copy…")
        try press("o", .command, code: 31)
        check(
            settings.value.shortcuts == ["openDocument:": "", "saveCopy:": "o"],
            "V8 a default that was taken away is free for another command")
        try select("File › Open…")
        try button("default").performClick(nil)
        check(
            !replace.isHidden && message.stringValue.hasPrefix("Command-O is already used by “File › Save Copy…”."),
            "V8 returning a command to a default that is now in use asks the same question: \(message.stringValue)")
        cancel.performClick(nil)
        let resetAll = try button("resetAll")
        check(resetAll.isEnabled && resetAll.title.hasSuffix("…"), "V8 Reset All Shortcuts… asks first (DS-41)")
        resetAll.performClick(nil)
        let sheet = try requireValue(window.attachedSheet, "V8 fixture: the Reset All Shortcuts sheet")
        check(NSApp.modalWindow == nil, "V8 the question blocks only Settings")
        let confirm = try requireValue(
            descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Reset Shortcuts" },
            "V8 fixture: Reset Shortcuts")
        check(confirm.hasDestructiveAction, "V8 DS-41 the deliberate button is marked destructive")
        confirm.performClick(nil)
        _ = spinUntil("V8 the Reset All Shortcuts sheet finished") { sheet.sheetParent == nil && !sheet.isVisible }
        check(
            try settings.value.shortcuts.isEmpty && settings.value.version == 1 && window.isVisible
                && open.keyEquivalent == "o" && open.keyEquivalentModifierMask == .command && new.keyEquivalent == "n"
                && String(decoding: try Data(contentsOf: settings.url), as: UTF8.self).contains("\"version\":1")
                && !resetAll.isEnabled,
            "V8 Reset All Shortcuts restores every default, in the menu bar and in a version-1 file")

        // A menu its owner rebuilds (Run Commands) gets new items; the saved shortcut returns to them.
        try select("Tools › Run Commands › Manage Commands…")
        try press("m", [.control, .option], code: 46)
        let manage = try item("manage:")
        check(
            manage.keyEquivalent == "m" && manage.keyEquivalentModifierMask == [.control, .option],
            "V8 fixture: a Run Commands item has an assigned key")
        try composition.runner.persist([.uppercaseSample])
        let rebuilt = try item("manage:")
        check(rebuilt !== manage, "V8 fixture: saving a Run command rebuilds its menu")
        _ = spinUntil("V8 the rebuilt Run Commands item has its shortcut again") {
            rebuilt.keyEquivalent == "m" && rebuilt.keyEquivalentModifierMask == [.control, .option]
        }
        try choosePane("shortcuts", in: window)
        let saved = "Tools › Run Commands › " + ConfiguredRun.uppercaseSample.menuTitle
        try select(saved)
        try press("u", [.control, .option], code: 32)
        func runItem() -> NSMenuItem? {
            func search(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.target is RunController, item.title == ConfiguredRun.uppercaseSample.menuTitle { return item }
                    if let found = item.submenu.flatMap(search) { return found }
                }
                return nil
            }
            return search(bar)
        }
        check(
            try settings.value.shortcuts.keys.contains { $0.hasPrefix("RunController.run:/") }
                && text(try row(saved), 1) == "⌃⌥U" && runItem().flatMap { MenuShortcut($0) }?.displayText == "⌃⌥U",
            "V8 a saved Run command takes a shortcut of its own, on its menu item")
        try composition.runner.persist([])
        _ = spinUntil("V8 the Run Commands menu was rebuilt without the command") { !listed().isEmpty }
        try choosePane("shortcuts", in: window)
        check(
            try settings.ignoredShortcutBindings.isEmpty && settings.value.shortcuts.count == 2
                && !listed().contains(saved) && text(try row("Tools › Run Commands › Manage Commands…"), 1) == "⌃⌥M",
            "V8 deleting that Run command leaves its shortcut dormant: nothing is reported and nothing else changes")
        try select("Tools › Run Commands › Manage Commands…")
        try press("u", [.control, .option], code: 32)
        check(
            settings.value.shortcuts.count == 1 && settings.value.shortcuts.values.first == "ctrl+opt+u",
            "V8 the dormant key is free, and taking it drops the dormant entry")
        try button("default").performClick(nil)
        check(settings.value.shortcuts.isEmpty, "V8 fixture: defaults again")

        // Two commands the menu bar itself puts on one key are both marked.
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let small = NSMenu()
        let fixture = NSMenu(title: "Fixture")
        small.addItem(title: "Fixture", action: nil).submenu = fixture
        fixture.addItem(title: "First", action: #selector(NSText.selectAll(_:)), keyEquivalent: "j", representedObject: "one")
        fixture.addItem(title: "Second", action: #selector(NSText.selectAll(_:)), keyEquivalent: "j", representedObject: "two")
        NSApp.mainMenu = small
        settings.showSettings(nil)
        try choosePane("files", in: window)
        try choosePane("shortcuts", in: window)
        check(
            try text(try row("Fixture › First"), 2) == "Default · Same key as “Fixture › Second”"
                && text(try row("Fixture › Second"), 2) == "Default · Same key as “Fixture › First”",
            "V8 commands on the same key are marked in words: \(text(try row("Fixture › First"), 2))")
    }
    /// The Files pane's Clear Local History… button sends the Compare menu's command. The
    /// confirmation is the injected one the command's own checks use, so nothing is presented.
    static func clearLocalHistoryRowChecks(root: URL, composition: AppDelegate) throws {
        let priorStore = LocalHistory.store, priorConfirm = LocalHistory.confirmClear
        defer {
            LocalHistory.store = priorStore
            LocalHistory.confirmClear = priorConfirm
        }
        let home = root.appendingPathComponent("history-row/LocalHistory", isDirectory: true)
        let store = LocalHistoryStore(directory: home)
        LocalHistory.store = store
        for text in ["first", "second", "third"] { store.record(path: "/fixture/notes.txt", bytes: Data(text.utf8)) }
        store.waitUntilIdle()
        let before = store.usage()
        try require(before.versions == 3, "V10 fixture: three earlier versions are kept")
        var prompts: [LocalHistory.ClearPrompt] = [], answer = LocalHistory.ClearChoice.cancel
        LocalHistory.confirmClear = { prompt, _, reply in
            prompts.append(prompt)
            reply(answer)
        }
        // The command asks in a sheet on the workspace window, so there must be one.
        let document = DocumentFactory.makeUntitled()
        defer { document.close() }
        composition.settings.showSettings(nil)
        let form = try requireValue(
            FormPanel.visible.last { $0.window.identifier?.rawValue == "TextTank.Settings" }, "V10 fixture: Settings")
        defer { form.close() }
        try choosePane("files", in: form.window)
        let row: NSButton = try control("settings.clearLocalHistory", form.window)
        row.performClick(nil)
        // The command counts the kept versions off the main thread before it asks.
        _ = spinUntil("V10 the Settings row's confirmation is asked") { prompts.count == 1 }
        check(
            prompts.count == 1 && prompts.first?.buttons.first?.choice == .cancel
                && prompts.first?.buttons.last?.choice == .everything
                && form.window.isVisible && form.window.attachedSheet == nil,
            "V10 the Settings row sends Clear Local History…, which asks with the command's own confirmation")
        store.waitUntilIdle()
        check(
            try store.usage() == before && store.versions(forPath: "/fixture/notes.txt").count == 3,
            "V10 Cancel from the Settings row deletes nothing")
        answer = .everything
        row.performClick(nil)
        _ = spinUntil("V10 the Settings row's confirmation is asked again") { prompts.count == 2 }
        _ = spinUntil("V10 the confirmed clear finished") { store.usage().versions == 0 }
        store.waitUntilIdle()
        check(
            prompts.count == 2 && store.usage().versions == 0,
            "V10 and the same row, confirmed, clears the history as the menu command does")
    }
    static func maintenanceSheetChecks(root: URL) throws {
        let url = root.appendingPathComponent("maintenance-settings.json")
        let controller = SettingsController(url: url)
        var initial = EditorSettings()
        initial.tabWidth = 13
        try controller.save(initial)
        let initialBytes = try Data(contentsOf: url)
        let existing = Set(FormPanel.visible.map(ObjectIdentifier.init))
        defer { for f in FormPanel.visible where !existing.contains(ObjectIdentifier(f)) { f.close() } }
        controller.showSettings(nil)
        let form = try requireValue(FormPanel.visible.last, "Settings maintenance fixture")
        let width = try field("settings.width", form.window)
        width.stringValue = "999"
        let reset = try button("settings.reset", form.window)
        func sheet(_ parent: FormPanel, action: NSButton) throws -> NSWindow {
            action.performClick(nil)
            let result = try requireValue(parent.window.attachedSheet, "owned Settings maintenance sheet")
            check(
                result.sheetParent === parent.window && NSApp.modalWindow == nil,
                "only Settings is blocked by maintenance confirmation")
            return result
        }
        func choose(_ title: String, in sheet: NSWindow) throws {
            let item = try requireValue(
                descendants(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title },
                "Settings maintenance choice")
            check(item.hasDestructiveAction == (title != "Cancel"), "Settings marks the deliberate destructive button")
            item.performClick(nil)
            _ = spinUntil("Settings maintenance sheet finished") { sheet.sheetParent == nil && !sheet.isVisible }
        }
        let first = try sheet(form, action: reset)
        reset.performClick(nil)
        check(
            form.window.sheets.count == 1 && form.window.attachedSheet === first,
            "duplicate Reset cannot enqueue another confirmation")
        try choose("Cancel", in: first)
        check(
            try Data(contentsOf: url) == initialBytes && width.stringValue == "999" && form.acceptsActions,
            "Cancel preserves exact saved settings and invalid draft")
        // Setting the user-immutable flag on this owned regular file allows reading the
        // original bytes but makes the atomic replacement fail at the actual save boundary.
        do {
            try require(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0, "owned immutable settings fixture")
            defer { _ = chflags(url.path, 0) }
            try choose("Reset Defaults", in: sheet(form, action: reset))
            check(
                try Data(contentsOf: url) == initialBytes && width.stringValue == "999" && controller.value == initial
                    && !form.validation.isHidden,
                "failed confirmed Reset retains original bytes, applied values and unfinished draft")
        }
        let stale = try sheet(form, action: reset)
        var changed = initial
        changed.tabWidth = 23
        try SettingsController(url: url).save(changed)
        let changedBytes = try Data(contentsOf: url)
        try choose("Reset Defaults", in: stale)
        check(
            try Data(contentsOf: url) == changedBytes && width.stringValue == "999" && !form.validation.isHidden,
            "stale sheet cannot overwrite a different controller's settings or discard the draft")
        form.close()
        controller.showSettings(nil)
        let reopened = try requireValue(FormPanel.visible.last, "reopened Settings maintenance fixture")
        let secondReset = try button("settings.reset", reopened.window)
        let closing = try sheet(reopened, action: secondReset)
        reopened.close()
        _ = spinUntil("parent closed Settings maintenance sheet") { !closing.isVisible }
        check(
            try Data(contentsOf: url) == changedBytes && !reopened.window.isVisible,
            "closing the parent cancels its pending destructive action")
        controller.showSettings(nil)
        let third = try requireValue(FormPanel.visible.last, "fresh Settings reset fixture")
        // Change only optional/unknown representation, then let two menu commands bring the
        // effective setting back to its original value and refresh the live store baseline.
        var normalized = controller.value
        normalized.autoIndent = true
        try controller.save(normalized)
        let staleMetadata = try sheet(third, action: button("settings.reset", third.window))
        var metadata = try requireValue(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], "owned extended settings")
        metadata["unrecognizedMetadata"] = "retained"
        try JSONSerialization.data(withJSONObject: metadata).write(to: url)
        controller.toggleAutoIndent(nil)
        controller.toggleAutoIndent(nil)
        let metadataBytes = try Data(contentsOf: url)
        try choose("Reset Defaults", in: staleMetadata)
        check(
            try Data(contentsOf: url) == metadataBytes && controller.value == normalized && !third.validation.isHidden,
            "sheet retains original disk baseline when menu round trip refreshes current store")

        try choose("Reset Defaults", in: sheet(third, action: button("settings.reset", third.window)))
        check(
            SettingsStore(url: url).value == EditorSettings() && !third.window.isVisible,
            "confirmed Reset saves defaults and refreshes Settings")
        FormPanel.visible.last?.close()
        let damaged = Data("damaged settings".utf8)
        try damaged.write(to: url)
        controller.showSettings(nil)
        let repair = try requireValue(FormPanel.visible.last, "damaged Settings fixture")
        let repairButton = try button("settings.repair", repair.window)
        let repairDraft = try field("settings.width", repair.window)
        repairDraft.stringValue = "unfinished"
        let cancelRepair = try sheet(repair, action: repairButton)
        try button("settings.reset", repair.window).performClick(nil)
        check(
            repair.window.sheets.count == 1 && repair.window.attachedSheet === cancelRepair,
            "repair cannot queue an incompatible reset")
        try choose("Cancel", in: cancelRepair)
        check(
            try Data(contentsOf: url) == damaged && repairDraft.stringValue == "unfinished",
            "cancelled Repair keeps original damaged bytes and draft")
        try choose("Back Up and Repair", in: sheet(repair, action: repairButton))
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.contains("unreadable") && (try? Data(contentsOf: $0)) == damaged
        }
        check(
            backups.count == 1 && SettingsStore(url: url).loadError == nil,
            "confirmed Repair creates exactly one intact backup and readable settings")
    }
    static func managerChecks() throws {
        let isolated = try IsolatedSupportDirectory("DesignSettingsManagers")
        defer { isolated.restore() }
        let automation = AutomationController(editorProvider: { nil }, newDocument: { _ in })
        let original = try Data(contentsOf: isolated.url.appendingPathComponent("Automations.json"))
        weak var releasedAutomation: FormPanel?
        try autoreleasepool {
            automation.manage()
            let form = try requireValue(FormPanel.visible.last, "DG fixture: automation manager")
            releasedAutomation = form
            let window = form.window
            check(NSApp.modalWindow == nil, "DG automation manager leaves the application non-modal")
            checkNativeButtons(window)
            let list = try table(window)
            let first = try requireValue(
                list.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField,
                "DG fixture: first automation name")
            let originalID = first.identifier
            let favorite = try button("automation.favorite", window)
            let oldState = favorite.state
            favorite.performClick(nil)
            check(favorite.state != oldState, "DG Favorite shows the selected automation's pending checked state")
            let exposed = NSAccessibility.unignoredChildrenForOnlyChild(from: favorite)
            let values = exposed.compactMap { element -> NSNumber? in
                guard let object = element as? NSObject else { return nil }
                let selector = NSSelectorFromString("accessibilityValue")
                return object.responds(to: selector)
                    ? object.perform(selector)?.takeUnretainedValue() as? NSNumber : nil
            }
            check(
                values.contains { $0.intValue == favorite.state.rawValue },
                "DG the real native favorite element exposes its checked value")
            let count = list.numberOfRows
            try button("automation.duplicate", window).performClick(nil)
            let copied = try requireValue(
                list.view(atColumn: 0, row: list.selectedRow, makeIfNecessary: true) as? NSTextField,
                "DG fixture: duplicate automation row")
            check(
                list.numberOfRows == count + 1 && copied.stringValue == first.stringValue
                    && copied.identifier != originalID,
                "DG duplicate automation names keep distinct real table identities")
            try button("automation.manager.cancel", window).performClick(nil)
        }
        check(
            try Data(contentsOf: isolated.url.appendingPathComponent("Automations.json")) == original,
            "DG Cancel abandons duplicate and favorite changes without a library write")
        _ = spinUntil("the automation manager releases its owned form") { releasedAutomation == nil }
        check(
            releasedAutomation == nil,
            "DG closing the manager releases action closures while its controller stays alive")
        withExtendedLifetime(automation) {}

        let macro = MacroController(editorProvider: { nil })
        let macroItem = try requireValue(
            macro.menu().items.first { $0.action == NSSelectorFromString("manage") },
            "DG fixture: saved macro manager command")
        _ = NSApp.sendAction(macroItem.action!, to: macroItem.target, from: macroItem)
        let macroForm = try requireValue(FormPanel.visible.last, "DG fixture: macro manager")
        checkNativeButtons(macroForm.window)
        try button("macro.manager.add", macroForm.window).performClick(nil)
        let newMacro = try requireValue(FormPanel.visible.last, "DG fixture: native new macro form")
        newMacro.window.makeFirstResponder(nil)
        try field("macro.new.name", newMacro.window).stringValue = "Café"
        let input = try requireValue(
            descendants(newMacro.window.contentView!).compactMap { $0 as? NSTextView }.first {
                $0.identifier?.rawValue == "macro.new.text"
            }, "DG fixture: macro inserted text")
        try button("macro.new.save", newMacro.window).performClick(nil)
        check(
            newMacro.window.isVisible && input.accessibilityHelp() != nil,
            "DG Add Macro refuses empty actions inline without discarding input")
        input.string = "kept text"
        try button("macro.new.save", newMacro.window).performClick(nil)
        let macroList = try table(macroForm.window)
        check(
            macroList.numberOfRows == 1
                && !FileManager.default.fileExists(atPath: isolated.url.appendingPathComponent("Macros.json").path),
            "DG Add Macro changes only the working copy and never executes or saves it")
        try button("macro.manager.duplicate", macroForm.window).performClick(nil)
        let renamed = try requireValue(
            macroList.view(atColumn: 0, row: macroList.selectedRow, makeIfNecessary: true) as? NSTextField,
            "DG fixture: editable duplicated macro name")
        renamed.selectText(nil)
        type("Renamed macro", in: macroForm.window)
        macroForm.window.makeFirstResponder(nil)
        try button("macro.manager.save", macroForm.window).performClick(nil)
        let storedMacro = try MacroLibrary.decode(Data(contentsOf: isolated.url.appendingPathComponent("Macros.json")))
        check(
            storedMacro.macros.map(\.name) == ["Café", "Renamed macro"] && Set(storedMacro.macros.map(\.id)).count == 2,
            "DG native macro Add, inline Rename, Duplicate and Save retain names and fresh identities")
        check(
            storedMacro.macros.allSatisfy { $0.steps == [.insertText("kept text")] },
            "DG native macro management preserves the exact supported actions")

        let run = RunController()
        var invocations = 0
        run.onUnrecordableAction = { invocations += 1 }
        let item = try requireValue(
            run.makeMenu().items.first { $0.action == NSSelectorFromString("manage:") },
            "DG fixture: Run manager command")
        _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        let runForm = try requireValue(FormPanel.visible.last, "DG fixture: Run manager")
        checkNativeButtons(runForm.window)
        try button("run.manager.add", runForm.window).performClick(nil)
        let newRun = try requireValue(FormPanel.visible.last, "DG fixture: Run command sheet")
        newRun.window.makeFirstResponder(nil)
        try field("run.command.name", newRun.window).stringValue = "Native command"
        let configure = try requireValue(
            run.makeMenu().items.first { $0.action == NSSelectorFromString("configure:") },
            "DG fixture: Configure Command route")
        _ = NSApp.sendAction(configure.action!, to: configure.target, from: configure)
        let keptRunName = try field("run.command.name", newRun.window).stringValue
        check(
            FormPanel.visible.filter { $0.window.identifier?.rawValue == "run.command" }.count == 1
                && keptRunName == "Native command",
            "DG repeated Configure preserves the existing owned Run sheet and its pending input")
        try field("run.command.arguments", newRun.window).stringValue = "[\"hello\"]"
        try button("run.command.save", newRun.window).performClick(nil)
        let runList = try table(runForm.window)
        try button("run.manager.duplicate", runForm.window).performClick(nil)
        check(
            runList.numberOfRows == 2 && invocations == 0 && !run.isRunning,
            "DG creating and duplicating Run definitions never starts a process")
        try button("run.manager.delete", runForm.window).performClick(nil)
        let confirmation = try requireValue(
            runForm.window.attachedSheet, "DG fixture: native Delete confirmation sheet")
        let destructive = try requireValue(
            descendants(confirmation.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Delete" },
            "DG fixture: Delete action")
        check(
            destructive.hasDestructiveAction && destructive.keyEquivalent != "\r",
            "DG deletion is explicitly marked and Return is never destructive")
        destructive.performClick(nil)
        _ = spinUntil("Run delete confirmation completes") { runList.numberOfRows == 1 }
        runForm.window.makeFirstResponder(nil)
        try button("run.manager.save", runForm.window).performClick(nil)
        let storedRun = try ConfiguredRun.decodeLibrary(Data(contentsOf: run.storage))
        check(
            storedRun.count == 1 && storedRun[0].name == "Native command" && storedRun[0].arguments == ["hello"]
                && invocations == 0,
            "DG native Run Add, Duplicate, Delete and Save preserve the configured arguments without execution")
    }

}

extension DesignSettingsChecks {
    private static func modernAttribute(_ value: Any, _ name: String) -> Any? {
        guard let object = value as? NSObject, object.responds(to: NSSelectorFromString(name)) else { return nil }
        return object.perform(NSSelectorFromString(name))?.takeUnretainedValue()
    }
    /// Traverse the real window's modern accessibility children, including native cells.
    /// Host getter values and deprecated AXDescription are not the acceptance oracle.
    private static func nativeTree(_ window: NSWindow) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = [], result: [NSObject] = []
        func visit(_ value: Any) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in modernAttribute(object, "accessibilityChildren") as? [Any] ?? [] { visit(child) }
            // Some AppKit-owned table proxies expose only the AXChildren bridge.
            // Use that native edge for navigation, never legacy names/roles as the oracle.
            let childrenSelector = NSSelectorFromString("accessibilityChildren")
            let bridgeSelector = NSSelectorFromString("accessibilityAttributeValue:")
            if !object.responds(to: childrenSelector), object.responds(to: bridgeSelector),
                let children = object.perform(bridgeSelector, with: "AXChildren")?.takeUnretainedValue() as? [Any]
            {
                for child in children { visit(child) }
            }
            // AppKit's private row proxies do not implement modern children selectors.
            // Follow the table protocol's public cell edges instead of a legacy-name fallback.
            if let table = object as? NSTableView {
                for row in 0..<table.numberOfRows {
                    for column in 0..<table.numberOfColumns {
                        if let cell = table.accessibilityCell(forColumn: column, row: row) { visit(cell) }
                    }
                }
            }
        }
        visit(window)
        return result
    }
    private static func exposes(_ value: Any, purpose: String, role: String) -> Bool {
        guard modernAttribute(value, "accessibilityRole") as? String == role else { return false }
        if modernAttribute(value, "accessibilityLabel") as? String == purpose
            || modernAttribute(value, "accessibilityTitle") as? String == purpose
        {
            return true
        }
        guard let caption = modernAttribute(value, "accessibilityTitleUIElement") else { return false }
        return modernAttribute(caption, "accessibilityValue") as? String == purpose
    }
    private static func inputName(
        _ view: NSView, _ purpose: String, role: String, in form: FormPanel, focus: Bool = false
    ) {
        form.window.contentView?.layoutSubtreeIfNeeded()
        form.window.displayIfNeeded()
        let actual = NSAccessibility.unignoredChildrenForOnlyChild(from: view)
        let tree = nativeTree(form.window)
        let cellPass = actual.contains { exposes($0, purpose: purpose, role: role) }
        let treePass = tree.contains { exposes($0, purpose: purpose, role: role) }
        let expectedText =
            (view as? NSPopUpButton)?.titleOfSelectedItem ?? (view as? NSTextField)?.stringValue
            ?? (view as? NSTextView)?.string
        if let expectedText {
            check(
                actual.contains {
                    exposes($0, purpose: purpose, role: role)
                        && modernAttribute($0, "accessibilityValue") as? String == expectedText
                },
                "DG naming preserves the real native input role and displayed value: \(purpose)")
        } else if let button = view as? NSButton {
            check(
                actual.contains {
                    exposes($0, purpose: purpose, role: role)
                        && (modernAttribute($0, "accessibilityValue") as? NSNumber)?.intValue == button.state.rawValue
                },
                "DG naming preserves the real native checkbox state: \(purpose)")
        }
        print("DG_INPUT_AX", form.window.identifier!.rawValue, purpose, role, "native=", cellPass, "window=", treePass)
        if !treePass {
            for element in tree {
                print(
                    "DG_INPUT_AX_TREE", String(describing: Swift.type(of: element)),
                    modernAttribute(element, "accessibilityRole") ?? "",
                    modernAttribute(element, "accessibilityLabel") ?? "",
                    modernAttribute(element, "accessibilityTitle") ?? "",
                    modernAttribute(element, "accessibilityValue") ?? "")
            }
        }
        check(
            cellPass && treePass,
            "DG actual native input and full window tree expose purpose: \(form.window.identifier!.rawValue) / \(purpose)"
        )
        guard focus, let field = view as? NSTextField, field.isEnabled else { return }
        field.selectText(nil)
        type("8", in: form.window)
        let focusedTree = nativeTree(form.window)
        check(
            field.currentEditor() != nil && focusedTree.contains { exposes($0, purpose: purpose, role: role) },
            "DG real focused field editing retains its native input purpose: \(purpose)")
        if let editor = field.currentEditor(), focusedTree.contains(where: { $0 === editor }) {
            let editorRole = modernAttribute(editor, "accessibilityRole") as? String ?? ""
            check(
                exposes(editor, purpose: purpose, role: editorRole),
                "DG an exposed active field editor retains the input purpose: \(purpose)")
        } else {
            print("DG_FIELD_EDITOR", purpose, "represented by its named native input cell in the window tree")
        }
        form.window.makeFirstResponder(nil)
        if purpose.hasPrefix("Rename in ") {
            let renamedPurpose = "Rename in " + field.stringValue
            check(
                nativeTree(form.window).contains { exposes($0, purpose: renamedPurpose, role: role) },
                "DG the native inline Rename name follows its committed display name")
        }
    }
    static func inputAccessibilityChecks(root: URL, composition: AppDelegate) throws {
        let isolated = try IsolatedSupportDirectory("DesignSettingsInputAX")
        defer { isolated.restore() }
        let prior = Set(FormPanel.visible.map(ObjectIdentifier.init))
        defer {
            for form in FormPanel.visible.reversed() where !prior.contains(ObjectIdentifier(form)) { form.close() }
        }
        func form(_ id: String) throws -> FormPanel {
            try requireValue(
                FormPanel.visible.last { $0.window.identifier?.rawValue == id }, "DG AX fixture owns \(id)")
        }
        func labelled(_ purpose: String, in form: FormPanel) throws -> NSView {
            try requireValue(
                descendants(form.window.contentView!).first { $0.accessibilityLabel() == purpose },
                "DG AX fixture input \(purpose)")
        }
        func checkInputs(_ id: String, _ purposes: [(String, String)], focus: Bool = false) throws -> FormPanel {
            let owned = try form(id)
            for (index, pair) in purposes.enumerated() {
                inputName(try labelled(pair.0, in: owned), pair.0, role: pair.1, in: owned, focus: focus && index == 0)
            }
            return owned
        }
        func action(_ selector: String, menu: NSMenu) throws {
            let item = try requireValue(
                menu.items.first { $0.action == NSSelectorFromString(selector) }, "DG AX native menu route \(selector)")
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        // The panes and the Shortcuts pane are driven here, in this process, and not in
        // document-checks: every window shown from a check executable keeps an AppKit animation
        // worker, and that long process has few left (see docs/BUILDING.md).
        try settingsPaneChecks(root: isolated.url)
        let settings = SettingsController(url: isolated.url.appendingPathComponent("Settings.json"))
        settings.showSettings(nil)
        // Each pane is checked while it is the one shown; a hidden pane is not in the tree.
        let settingsForm = try checkInputs(
            "TextTank.Settings",
            [
                ("Tab width", "AXTextField"), ("Indent with tabs", "AXCheckBox"), ("Wrap lines", "AXCheckBox"),
                ("Auto-indent on Return", "AXCheckBox"), ("Search settings by name", "AXTextField"),
                ("Show only settings changed from their defaults", "AXCheckBox")
            ], focus: true)
        try choosePane("appearance", in: settingsForm.window)
        _ = try checkInputs(
            "TextTank.Settings",
            [("Appearance", "AXPopUpButton"), ("Font size (points)", "AXTextField"), ("Default zoom", "AXTextField")],
            focus: true)
        try choosePane("files", in: settingsForm.window)
        _ = try checkInputs(
            "TextTank.Settings", [("At launch", "AXPopUpButton"), ("External file changes", "AXPopUpButton")],
            focus: true)
        try choosePane("previews", in: settingsForm.window)
        _ = try checkInputs(
            "TextTank.Settings", [("Preview format", "AXPopUpButton"), ("Open Markdown documents in", "AXPopUpButton")],
            focus: true)
        try choosePane("shortcuts", in: settingsForm.window)
        _ = try checkInputs(
            "TextTank.Settings",
            [("Search commands by name, menu or shortcut", "AXTextField"), ("Commands and their shortcuts", "AXTable")])
        settingsForm.close()

        let document = DocumentFactory.makeUntitled()
        defer { document.close() }
        let controller = try requireValue(
            document.windowControllers.first as? EditorWindowController, "DG AX document controller")
        document.editor.text = "one\ntwo"
        document.editor.setSavePoint()
        controller.goToLine(nil)
        // The same oracle as the form fields above: the native element the field exposes (its
        // cell), and the real window's accessibility tree, each naming a text field.
        let lineField = controller.goToLineBar.field
        let lineWindow = try requireValue(lineField.window, "DG AX Go to Line is in the workspace window")
        lineWindow.contentView?.layoutSubtreeIfNeeded()
        check(
            controller.goToLineBarVisible && lineField.currentEditor() != nil
                && NSAccessibility.unignoredChildrenForOnlyChild(from: lineField).contains {
                    exposes($0, purpose: "Line number in Go to Line", role: "AXTextField")
                }
                && nativeTree(lineWindow).contains {
                    exposes($0, purpose: "Line number in Go to Line", role: "AXTextField")
                },
            "DG AX Go to Line is one named inline text field that takes the keyboard")
        controller.cancelGoToLine(nil)
        composition.showDocumentTabs(nil)
        try checkInputs(
            "TextTank.OpenDocuments", [("Filter open documents by name or path", "AXTextField")], focus: true
        ).close()
        let editor = document.editor
        let automation = AutomationController(
            editorProvider: { editor }, newDocument: { _ in check(false, "DG input checks never invoke output") })
        var workflow = AutomationDefinition.recipeFixture
        workflow.name = "AX automation"
        workflow.shortcut = nil
        try automation.persistLibrary(.init(workflows: [workflow]))
        automation.manage()
        let manager = try checkInputs("automation.manager", [("Rename in AX automation", "AXTextField")], focus: true)
        try button("automation.edit", manager.window).performClick(nil)
        try checkInputs(
            "automation.settings",
            [
                ("Automation name", "AXTextField"), ("Automation input", "AXPopUpButton"),
                ("Automation output", "AXPopUpButton"), ("Automation shortcut", "AXTextField")
            ], focus: true
        ).close()
        try button("automation.rules", manager.window).performClick(nil)
        let rules = try checkInputs(
            "TextTank.Rules", [("Automation name", "AXTextField"), ("Sample input", "AXTextArea")], focus: true)
        try button("rules.add", rules.window).performClick(nil)
        let rule = try checkInputs(
            "rule",
            [
                ("Rule", "AXPopUpButton"), ("Text to match", "AXTextField"), ("Replace with", "AXTextField"),
                ("Ask for match text when running this rule", "AXCheckBox"),
                ("Ask for replacement when running this rule", "AXCheckBox")
            ])
        let kind = try requireValue(try labelled("Rule", in: rule) as? NSPopUpButton, "DG AX actual rule kind")
        kind.selectItem(
            at: try requireValue(
                AutomationDefinition.Step.Kind.allCases.firstIndex { $0.findTitle == "Pattern" },
                "DG AX pattern rule kind"))
        _ = NSApp.sendAction(kind.action!, to: kind.target, from: kind)
        inputName(try labelled("Pattern", in: rule), "Pattern", role: "AXTextField", in: rule, focus: true)
        rule.close()
        rules.close()
        try button("automation.json", manager.window).performClick(nil)
        try checkInputs("automation.json", [("Automation library JSON", "AXTextArea")]).close()
        manager.close()
        automation.showPalette()
        try checkInputs("automation.palette", [("Filter automations by name", "AXTextField")], focus: true).close()

        let macro = MacroController(editorProvider: { editor })
        try macro.persist(.init(macros: [.init(id: UUID(), name: "AX macro", steps: [.insertText("x")])]))
        try action("manage", menu: macro.menu())
        let macroManager = try checkInputs("macro.manager", [("Rename in AX macro", "AXTextField")], focus: true)
        try button("macro.manager.add", macroManager.window).performClick(nil)
        try checkInputs(
            "macro.new", [("Name in New Macro", "AXTextField"), ("Text inserted by the new macro", "AXTextArea")],
            focus: true
        ).close()
        try button("macro.manager.advanced", macroManager.window).performClick(nil)
        try checkInputs("macro.json", [("Macro library JSON", "AXTextArea")]).close()
        macroManager.close()
        macro.startRecording()
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "newLine"))
        _ = try macro.finishRecording()
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        try action("saveLast", menu: macro.menu())
        try checkInputs("macro.save", [("Macro name in Name Recorded Macro", "AXTextField")], focus: true).close()
        let run = RunController()
        try run.persist([.uppercaseSample])
        try action("manage:", menu: run.makeMenu())
        let runManager = try checkInputs(
            "run.manager", [("Rename in " + ConfiguredRun.uppercaseSample.name, "AXTextField")], focus: true)
        try button("run.manager.add", runManager.window).performClick(nil)
        try checkInputs(
            "run.command",
            [
                ("Name in New Run Command", "AXTextField"), ("Executable in New Run Command", "AXTextField"),
                ("Arguments in New Run Command", "AXTextField"),
                ("Intentional shell mode for this Run command", "AXCheckBox"),
                ("Text extension mode for this Run command", "AXCheckBox")
            ], focus: true
        ).close()
        try button("run.manager.advanced", runManager.window).performClick(nil)
        try checkInputs("run.json", [("Saved Run commands as JSON", "AXTextArea")]).close()
        runManager.close()
        let language = LanguageController(
            editorProvider: { editor }, languageProvider: { "plain" }, setLanguage: { _ in })
        language.configure()
        try checkInputs("language.json", [("Language profiles JSON", "AXTextArea")]).close()
        // The Shortcuts pane and the Files row are driven last, after every other window of this
        // process has been checked, so they find no window of another check open.
        document.close()
        try shortcutPaneChecks(composition: composition)
        try SettingsShortcutValidationChecks.paneScenarios(root: isolated.url)
        try clearLocalHistoryRowChecks(root: isolated.url, composition: composition)
    }
}

@MainActor private final class CloseObservedFontPanel: NSFontPanel {
    private(set) var closeCount = 0, closingReloads = 0
    private var closing = false

    override func close() {
        closeCount += 1
        closing = true
        defer { closing = false }
        super.close()
    }

    override func reloadDefaultFontFamilies() {
        if closing { closingReloads += 1 }
        super.reloadDefaultFontFamilies()
    }
}
