// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

/// The compact find bar, driven through the tab adapter the application uses, its workspace
/// window and the shared Find state. Nothing here needs the
/// window to be key, and no panel, sheet, alert or menu is presented.
@MainActor enum FindBarNativeChecks {
    private static func open(_ name: String, _ text: String, in folder: URL) throws -> (
        TextDocument, EditorWindowController
    ) {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let document = TextDocument()
        document.fileURL = url
        document.fileType = TextDocument.plainTextType
        NSDocumentController.shared.addDocument(document)
        try document.read(from: Data(text.utf8), ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        document.showWindows()
        return (document, try requireValue(document.presentation, "fixture: tab adapter for \(name)"))
    }
    private static func keyboard(in view: NSView, of host: WorkspaceWindowController) -> Bool {
        (host.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
    }
    private static func typed(_ text: String, into field: NSTextField, of tab: EditorWindowController) {
        field.stringValue = text
        tab.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    private static func press(_ selector: Selector, in field: NSTextField, of tab: EditorWindowController) -> Bool {
        tab.control(field, textView: NSTextView(), doCommandBy: selector)
    }
    /// Everything shown is inside the bar and nothing overlaps; every control (a label is not
    /// one) is at least 20 by 20 points (DS-67, DS-74).
    private static func sound(_ bar: NSView) -> Bool {
        bar.layoutSubtreeIfNeeded()
        let shown = bar.subviews.filter { !$0.isHidden }
        let inside = shown.allSatisfy {
            let label = ($0 as? NSTextField).map { !$0.isEditable } == true
            return bar.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) && $0.frame.width >= 20
                && $0.frame.height >= (label ? 12 : 20)
        }
        let apart = shown.indices.allSatisfy { index in
            shown[(index + 1)...].allSatisfy { !$0.frame.insetBy(dx: 0.5, dy: 0.5).intersects(shown[index].frame) }
        }
        return inside && apart
    }
    /// A picture of the tab for the review record; the checks do not read it.
    private static func picture(_ tab: EditorWindowController, _ name: String) {
        let root = tab.presentationRoot
        root.layoutSubtreeIfNeeded()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return }
        // The window's own background first: the tab's root draws none.
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bitmap.size).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(
            to: TestPaths.artifacts.appendingPathComponent("find-bar-\(name).png"))
    }

    static func run(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let window = try requireValue(host.window, "fixture: workspace window")
        let originalSize = window.contentView?.bounds.size ?? NSSize(width: 1080, height: 720)
        let search = app.searchController
        let priorRemembered = EditorFindBar.rememberedShowsReplace
        defer {
            EditorFindBar.rememberedShowsReplace = priorRemembered
            _ = host.setSidebarShown(false)
            _ = host.setEditorLayout(.single)
            window.setContentSize(originalSize)
            search.mode.selectItem(at: 0)
            search.caseButton.state = .off
            search.wordButton.state = .off
            search.setSharedQuery("", from: nil)
            search.setSharedReplacement("", from: nil)
        }
        _ = host.setSidebarShown(false)
        _ = host.setEditorLayout(.single)
        window.setContentSize(NSSize(width: 1400, height: 700))
        let folder = root.appendingPathComponent("find-bar")
        let lines = (1...400).map { "line \($0) of the find bar fixture" }.joined(separator: "\n")
        let (document, tab) = try open("lines.txt", lines, in: folder)
        defer { document.close() }
        try compactFind(tab: tab, app: app, host: host, window: window)
    }

    // MARK: Compact Find

    private static func compactFind(
        tab: EditorWindowController, app: AppDelegate, host: WorkspaceWindowController, window: NSWindow
    ) throws {
        let search = app.searchController, editor = tab.primaryEditor
        let bar = try requireValue(tab.findBar, "fixture: find bar")
        let options = tab.findOptions, disclosure = tab.replaceDisclosure
        let replaceControls: [NSView] = [tab.replaceField, tab.replaceMatchButton, tab.replaceAllButton]
        EditorFindBar.rememberedShowsReplace = nil
        // No Find text yet: a live match would scroll to itself while the layout is measured.
        search.setSharedQuery("", from: nil)
        search.setSharedReplacement("", from: nil)
        window.makeFirstResponder(editor)

        // One row, with Replace behind the disclosure control.
        tab.showFind(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            tab.findBarVisible && !tab.replaceRowShown && replaceControls.allSatisfy(\.isHidden)
                && disclosure.state == .off && bar.frame.height == 24,
            "Find opens as one row: the Replace field and its buttons are not shown")
        check(
            disclosure.superview === bar && disclosure.frame.minX == 0 && disclosure.frame.maxX <= tab.findField.frame.minX
                && disclosure.bezelStyle == .disclosure && disclosure.frame.width >= 20 && disclosure.frame.height >= 20,
            "a standard disclosure control sits at the leading edge of the bar, before the Find field")
        check(
            disclosure.accessibilityLabel() == "Replace in document" && disclosure.toolTip?.hasPrefix("Show the Replace field") == true
                && disclosure.accessibilityHelp() == disclosure.toolTip,
            "the disclosure control says what it shows, to the pointer and to assistive technology")
        check(sound(bar) && options.showsWords, "at a wide window everything is on the one row, with the options in words")
        picture(tab, "one-row")

        // Disclosing Replace: the bar grows, the editor gives up exactly that height, the text stays.
        editor.scrollTo(documentLine: 150, subline: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        let top = editor.firstVisibleDocumentLine, editorHeight = editor.frame.height
        try require(top == 150, "fixture: line 151 is at the top of the editor")
        disclosure.performClick(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            tab.replaceRowShown && replaceControls.allSatisfy { !$0.isHidden } && bar.frame.height == 50
                && disclosure.state == .on && disclosure.toolTip?.hasPrefix("Hide the Replace field") == true,
            "the disclosure control shows the Replace row and the bar is two rows tall")
        check(
            editor.frame.height == editorHeight - 26 && editor.firstVisibleDocumentLine == top && sound(bar),
            "the editor gives the row its height and the same line is still at the top of the text")
        check(
            tab.replaceField.frame.minX == tab.findField.frame.minX && tab.replaceField.frame.maxY < tab.findField.frame.minY,
            "the Replace field is under the Find field")
        check(EditorFindBar.rememberedShowsReplace == true, "the choice is remembered")
        picture(tab, "replace-row")
        tab.hideFind(nil)
        tab.showFind(nil)
        check(tab.replaceRowShown, "Find opens with the Replace row again after it was left open")
        disclosure.performClick(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            !tab.replaceRowShown && bar.frame.height == 24 && editor.frame.height == editorHeight
                && editor.firstVisibleDocumentLine == top && EditorFindBar.rememberedShowsReplace == false,
            "hiding the row gives the height back, again without scrolling the text")
        tab.hideFind(nil)
        search.setSharedReplacement("replacement in use", from: nil)
        tab.showFind(nil)
        check(
            !tab.replaceRowShown && tab.replaceField.stringValue == "replacement in use",
            "a row the person hid stays hidden for the session, and the shared replacement is still in its field")
        tab.hideFind(nil)
        EditorFindBar.rememberedShowsReplace = nil
        tab.showFind(nil)
        check(tab.replaceRowShown, "with no choice made yet, Find opens with the Replace row when a replacement is in use")
        tab.hideFind(nil)
        search.setSharedReplacement("", from: nil)
        tab.showFind(nil)
        check(!tab.replaceRowShown, "and with one row when there is none")
        tab.hideFind(nil)
        tab.showFindWithReplace(nil)
        check(
            tab.findBarVisible && tab.replaceRowShown && EditorFindBar.rememberedShowsReplace == nil,
            "opened for replacing, the bar shows the Replace row without that becoming the remembered choice")
        tab.hideFind(nil)
        tab.showFind(nil)

        // One select-any control for the options, sharing the Find window's options.
        check(
            options.superview === bar && options.trackingMode == .selectAny && options.segmentCount == 3
                && (0..<3).map { options.label(forSegment: $0) } == ["Match case", "Whole word", "Regex"],
            "the options are one standard select-any segmented control, labelled in words")
        check(
            options.accessibilityLabel() == "Search options for Find in document"
                && options.accessibilityValue() as? String == "Match case off, Whole word off, Regular expression off",
            "the control has an accessibility label and a value that names each option's state")
        check(
            (0..<3).allSatisfy { index in
                let name = FindOptionsControl.Option(rawValue: index)?.name ?? "?"
                return options.toolTip(forSegment: index)?.hasPrefix("\(name) is off") == true
            }, "each segment's tooltip names its option and says what it does")
        options.toggle(.matchCase)
        check(
            options.isOn(.matchCase) && search.caseButton.state == .on
                && search.sharedOptions(query: "", replacement: "").matchCase
                && options.toolTip(forSegment: 0)?.hasPrefix("Match case is on") == true
                && (options.accessibilityValue() as? String)?.hasPrefix("Match case on") == true,
            "Match case in the bar is Match case in the Find and Replace window")
        search.wordButton.state = .on
        _ = NSApp.sendAction(try requireValue(search.wordButton.action, "fixture"), to: search, from: search.wordButton)
        check(options.isOn(.wholeWord) && options.isOn(.matchCase), "Whole word set in the window is lit in the bar")
        options.toggle(.matchCase)
        options.toggle(.wholeWord)
        check(
            !options.isOn(.matchCase) && !options.isOn(.wholeWord) && search.caseButton.state == .off
                && search.wordButton.state == .off, "and both turn off from the bar")
        options.toggle(.regex)
        check(
            options.isOn(.regex) && search.sharedOptions(query: "", replacement: "").mode == .regularExpression
                && search.mode.indexOfSelectedItem == 2, "Regex in the bar is Regex mode in the window")
        options.toggle(.regex)
        check(
            !options.isOn(.regex) && search.sharedOptions(query: "", replacement: "").mode == .normal,
            "turning it off is Normal mode: the modes stay exclusive")
        search.mode.selectItem(at: 1)
        _ = NSApp.sendAction(try requireValue(search.mode.action, "fixture"), to: search.mode.target, from: search.mode)
        check(
            search.sharedOptions(query: "", replacement: "").mode == .extended && !options.isOn(.regex)
                && options.toolTip(forSegment: 2)?.contains("The search mode is Extended") == true
                && (options.accessibilityValue() as? String)?.hasSuffix("Extended search mode") == true,
            "Extended mode chosen in the window is named by the bar, not hidden behind an unlit Regex")
        options.toggle(.matchCase)
        check(
            search.sharedOptions(query: "", replacement: "").mode == .extended && options.isOn(.matchCase),
            "changing another option leaves the mode alone")
        options.toggle(.matchCase)
        search.mode.selectItem(at: 0)
        _ = NSApp.sendAction(try requireValue(search.mode.action, "fixture"), to: search.mode.target, from: search.mode)

        // The shared Find state: text, live count and its announcement, the mark, the history.
        _ = editor.setSelectionAnchor(0, caret: 0)
        NativeFixtureEnvironment.announcements = []
        typed("line 39", into: tab.findField, of: tab)
        spinUntil("the live count") { !tab.findCount.stringValue.isEmpty }
        let counted = tab.findCount.stringValue
        check(
            search.sharedQuery == "line 39" && search.queryField.stringValue == "line 39" && counted.contains("11")
                && NativeFixtureEnvironment.announcements.contains(counted),
            "typing in the bar is the Find text of the window, and the live count is shown and announced (DS-36)")
        typed("no such text anywhere", into: tab.findField, of: tab)
        spinUntil("the live count finds nothing") { tab.findCount.stringValue == "No matches" }
        check(
            NativeFixtureEnvironment.announcements.contains("No matches") && tab.findCount.frame.width >= 80
                && !tab.findCount.isHidden, "a search that finds nothing says so in the bar and is announced")
        options.toggle(.regex)
        typed("(unclosed [group", into: tab.findField, of: tab)
        spinUntil("the invalid expression is marked") { tab.findFieldIsMarked }
        check(
            tab.findFieldIsMarked && tab.findCount.stringValue == "Expression not valid"
                && tab.findField.accessibilityHelp()?.isEmpty == false,
            "an expression that does not compile marks the Find field and says so beside it (DS-45)")
        options.toggle(.regex)
        typed("line 39", into: tab.findField, of: tab)
        spinUntil("the mark clears") { !tab.findFieldIsMarked && !tab.findCount.stringValue.isEmpty }
        check(!tab.findFieldIsMarked, "and the mark clears with a valid search")
        search.remember(query: "line 39", replacement: "LINE 39")
        var shownHistory: (menu: NSMenu, anchor: NSView)?
        let nativePresenter = tab.presentFindHistory
        tab.presentFindHistory = { shownHistory = ($0, $1) }
        check(
            press(#selector(NSResponder.moveDown(_:)), in: tab.findField, of: tab)
                && shownHistory?.menu.items.first?.title == "line 39" && shownHistory?.anchor === tab.findField
                && tab.findField.searchMenuTemplate?.items.first?.title == "line 39",
            "Down Arrow and the magnifying glass still open the recent searches")
        tab.presentFindHistory = nativePresenter
        let recentReplacement = try requireValue(
            tab.findHistoryMenu(replacements: true).items.first { $0.representedObject as? String == "LINE 39" },
            "fixture: a recent replacement")
        try require(!tab.replaceRowShown, "fixture: the Replace row is hidden")
        check(
            NSApp.sendAction(try requireValue(recentReplacement.action, "fixture"), to: recentReplacement.target, from: recentReplacement)
                && tab.replaceField.stringValue == "LINE 39" && search.sharedReplacement == "LINE 39" && tab.replaceRowShown
                && !tab.replaceField.isHidden,
            "a replacement chosen from the history is shown: the Replace row opens for it")
        search.setSharedReplacement("", from: nil)
        tab.setReplaceRow(shown: false)

        // Widths (DS-67, DS-74): the 800-point window, the docked sidebar, and a narrow group.
        func checkWidth(_ label: String, oneRow: Bool) {
            window.contentView?.layoutSubtreeIfNeeded()
            let rows = oneRow ? 1 : 2
            check(
                sound(bar) && bar.frame.height == CGFloat(rows * 26 - 2) && tab.findField.frame.width >= 90,
                "\(label): \(rows == 1 ? "one row" : "two rows"), every control whole and at least 20 points (bar \(Int(bar.frame.width)) wide)")
            tab.setReplaceRow(shown: true)
            window.contentView?.layoutSubtreeIfNeeded()
            check(
                sound(bar) && bar.frame.height == CGFloat((rows + 1) * 26 - 2),
                "\(label): the Replace row adds one row and nothing overlaps")
            picture(tab, "width-\(Int(bar.frame.width))")
            tab.setReplaceRow(shown: false)
        }
        window.setContentSize(NSSize(width: 800, height: 500))
        checkWidth("the 800-point window", oneRow: true)
        check(
            !options.showsWords && (0..<3).allSatisfy { index in
                options.image(forSegment: index)?.accessibilityDescription == FindOptionsControl.Option(rawValue: index)?.name
                    && options.label(forSegment: index)?.isEmpty != false && options.width(forSegment: index) >= 28
                    && options.toolTip(forSegment: index)?.isEmpty == false
            },
            "where words do not fit the options are symbols, each still named for assistive technology and by its tooltip")
        check(host.setSidebarShown(true), "fixture: the sidebar is shown")
        window.setContentSize(window.contentMinSize)
        checkWidth("the smallest window with the sidebar", oneRow: true)
        // The sidebar at its widest in an 800-point-wide window's worth of editor: about 800 less the sidebar.
        _ = host.setSidebarShown(false)
        check(host.setEditorLayout(.twoColumns), "fixture: two editor groups")
        window.setContentSize(window.contentMinSize)
        window.contentView?.layoutSubtreeIfNeeded()
        try require(bar.frame.width < 520, "fixture: the bar is in a narrow group (\(bar.frame.width))")
        checkWidth("a narrow editor group", oneRow: false)
        check(
            options.frame.minY < tab.findField.frame.minY && abs(tab.findCount.frame.midY - options.frame.midY) <= 1
                && tab.findNavigation.frame.minY == tab.findField.frame.minY,
            "in a narrow group the options and the count take the second row; Find and its navigation keep the first")
        _ = host.setEditorLayout(.single)
        window.setContentSize(NSSize(width: 1400, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        check(options.showsWords && bar.frame.height == 24, "widening the window brings back one row and the words")
        tab.hideFind(nil)
        check(keyboard(in: editor, of: host) && !tab.findBarVisible, "Escape or Done still closes the bar and returns to the text")
    }
}
