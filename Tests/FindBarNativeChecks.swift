// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

/// The compact find bar and Go to Line as one inline field, driven through the tab adapter the
/// application uses, its workspace window and the shared Find state. Nothing here needs the
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
    /// The real paths. A key goes to the field's own editor as a key-down event, which the text
    /// system turns into typed text or a command for the field's delegate.
    private static func keyDown(_ characters: String, code: UInt16, in field: NSTextField) throws {
        let editor = try requireValue(field.currentEditor() as? NSTextView, "fixture: the field is being edited")
        let window = try requireValue(field.window, "fixture: the field is in a window")
        editor.keyDown(
            with: try requireValue(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code), "fixture: key event"))
    }
    private static let digitKeys: [Character: UInt16] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, ":": 41
    ]
    /// Replaces what the field holds by typing, one key at a time.
    private static func keys(_ text: String, into field: NSTextField) throws {
        try requireValue(field.currentEditor(), "fixture: the field is being edited").selectAll(nil)
        for character in text {
            try keyDown(String(character), code: try requireValue(digitKeys[character], "fixture: key for \(character)"), in: field)
        }
    }
    /// Presses one segment the way assistive technology does: the segment's own accessibility
    /// element performs its press, and the control sends its action.
    private static func press(segment: Int, of control: NSSegmentedControl) throws {
        // The control's accessibility children are its cell; the cell's are the segments.
        var segments: [NSObject] = [control]
        while segments.count == 1, let inner = (segments[0] as? NSAccessibilityProtocol)?.accessibilityChildren() {
            segments = inner.compactMap { $0 as? NSObject }
        }
        try require(segments.count == control.segmentCount, "fixture: one accessibility element for each segment (\(segments.count))")
        let element = try requireValue(segments[segment] as? NSAccessibilityProtocol, "fixture: segment \(segment)")
        // AppKit's segment reports false even when it has acted; the callers check the effect.
        _ = element.accessibilityPerformPress()
    }
    /// A pointer click, delivered as the window delivers one: the view under the pointer takes
    /// the keyboard if it accepts it, then receives the mouse-down and the mouse-up. `tab` is told
    /// which event is being handled, as NSApp.currentEvent would tell it in the application.
    private static func click(at point: NSPoint, in window: NSWindow, of tab: EditorWindowController) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try requireValue(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                "fixture: mouse event")
        }
        let content = try requireValue(window.contentView, "fixture: window content")
        let hit = try requireValue(
            content.hitTest(content.superview?.convert(point, from: nil) ?? point), "fixture: a view under the pointer")
        // A pane that has not been on screen yet answers with its clip view; the text view is in it.
        let view = (hit as? NSClipView)?.documentView ?? hit
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        let provider = tab.goToLineClickEvent
        tab.goToLineClickEvent = { down }
        defer { tab.goToLineClickEvent = provider }
        if view.acceptsFirstResponder { window.makeFirstResponder(view) }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }
    /// A window point over the editor's text, 40 points in from its margins, and one over its
    /// line-number margin, both on the given fraction of its height.
    private static func points(in editor: TTEditor, down fraction: CGFloat) throws -> (text: NSPoint, margin: NSPoint) {
        let frame = editor.convert(editor.bounds, to: nil)
        let y = frame.maxY - frame.height * fraction
        let edge = try requireValue(
            stride(from: frame.minX + 1, to: frame.maxX, by: 1).first {
                editor.textAreaContains(windowPoint: NSPoint(x: $0, y: y))
            }, "fixture: where the text begins")
        try require(
            edge - frame.minX >= 12 && editor.textAreaContains(windowPoint: NSPoint(x: edge + 40, y: y)),
            "fixture: the editor has a margin and drawn text beside it (\(edge - frame.minX))")
        return (NSPoint(x: edge + 40, y: y), NSPoint(x: frame.minX + 6, y: y))
    }
    private static let returnKey = #selector(NSResponder.insertNewline(_:))
    private static let escapeKey = #selector(NSResponder.cancelOperation(_:))
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
    private struct Place: Equatable {
        var anchors: [Int], carets: [Int], topLine: Int, topSubline: Int, across: Int
        /// Every range with its virtual space, which one is main, and the selection mode.
        var selections: [NSNumber]
    }
    /// The bridge's snapshot without its third entry, the keyboard column mode's "moves extend"
    /// switch: Scintilla itself turns that off whenever the text loses the keyboard, to any field.
    private static func selections(_ editor: TTEditor) -> [NSNumber] {
        var state = editor.selectionSnapshot
        state.remove(at: 2)
        return state
    }
    private static func place(_ editor: TTEditor) -> Place {
        Place(
            anchors: editor.selectionRanges.map(\.anchor), carets: editor.selectionRanges.map(\.caret),
            topLine: editor.firstVisibleDocumentLine, topSubline: editor.firstVisibleSubline,
            across: editor.horizontalScrollOffset, selections: selections(editor))
    }

    static func run(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        entryRules()
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
        try goToLine(tab: tab, document: document, app: app, host: host, window: window, folder: folder)
    }

    // MARK: What may be typed into Go to Line

    private static func entryRules() {
        typealias E = GoToLineEntry
        check(
            E.parse("12", lines: 40) == .target(line: 12, column: nil)
                && E.parse(" 12:4 ", lines: 40) == .target(line: 12, column: 4)
                && E.parse("40", lines: 40) == .target(line: 40, column: nil)
                && E.parse("1", lines: 1) == .target(line: 1, column: nil),
            "Go to Line reads a line, and a line and column, both counted from 1")
        check(
            E.parse("12:", lines: 40) == .target(line: 12, column: nil) && E.parse("", lines: 40) == .empty
                && E.parse("   ", lines: 40) == .empty,
            "a colon with no column yet is the line alone, and an empty field is not an error")
        for entry in ["0", "41", "999999999999999999999999"] {
            if case .rejected(let reason) = E.parse(entry, lines: 40) {
                check(
                    reason.hasPrefix("There is no ") && reason.hasSuffix("Lines are 1–40."),
                    "Go to Line \(entry) says in words that the line does not exist and names the range")
            } else {
                check(false, "Go to Line \(entry) is rejected")
            }
        }
        for entry in ["two", "-1", "12:x", "1.5", ":4", "12:4:1", "１２"] {
            if case .rejected(let reason) = E.parse(entry, lines: 40) {
                check(
                    reason.hasPrefix("Enter a line number, such as 12 or 12:4.") && reason.hasSuffix("Lines are 1–40."),
                    "Go to Line “\(entry)” says what to enter and names the range")
            } else {
                check(false, "Go to Line “\(entry)” is rejected")
            }
        }
        if case .rejected(let reason) = E.parse("12:0", lines: 40) {
            check(reason.hasPrefix("Columns start at 1."), "column 0 is rejected in words")
        } else {
            check(false, "column 0 is rejected")
        }
        check(
            E.hint(1_234).hasPrefix("Lines are 1–1,234.") && E.hint(1).hasPrefix("This document has 1 line."),
            "the hint names the valid range, with the number written for reading (DS-83)")
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
        // The control's own path: the first segment is pressed, and the control sends its action.
        try press(segment: 0, of: options)
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
        try press(segment: 2, of: options)
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
        // The keyboard's own path: keys typed into the Find field, then Return, then Escape.
        _ = editor.setSelectionAnchor(0, caret: 0)
        window.makeFirstResponder(tab.findField)
        try keys("390", into: tab.findField)
        spinUntil("the live count for typed keys") { tab.findCount.stringValue.contains("1") && !tab.findCount.stringValue.isEmpty }
        check(
            tab.findField.stringValue == "390" && search.sharedQuery == "390" && search.queryField.stringValue == "390",
            "keys typed into the Find field are the shared Find text")
        try keyDown("\r", code: 36, in: tab.findField)
        spinUntil("Return finds the next match") { !tab.inlineSearchPending && editor.selectedText == "390" }
        check(
            editor.selectedText == "390" && editor.statusInfo.line == 390 && tab.findBarVisible
                && tab.findField.currentEditor() != nil,
            "Return in the Find field selects the next match and the field keeps the keyboard (DS-35)")
        try keyDown("\u{1B}", code: 53, in: tab.findField)
        check(!tab.findBarVisible && keyboard(in: editor, of: host), "Escape in the Find field closes the bar")
        tab.showFind(nil)
        typed("line 39", into: tab.findField, of: tab)
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
                sound(bar) && bar.frame.height == (rows == 1 ? 50 : 72),
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
        // The smallest editor group, 320 × 200, with the bar at its tallest: three rows.
        let surface = try requireValue(host.groupSurfaces[.first], "fixture: the first group's surface")
        let surfaceFrame = surface.frame
        surface.frame = NSRect(x: surfaceFrame.minX, y: surfaceFrame.minY, width: 320, height: 200)
        tab.setReplaceRow(shown: true)
        surface.layoutSubtreeIfNeeded()
        tab.presentationRoot.layoutSubtreeIfNeeded()
        let root = tab.presentationRoot
        try require(
            root.frame.width <= 320 && root.frame.height <= 200,
            "fixture: the tab is in a 320 × 200 group (\(root.frame.size))")
        check(
            bar.frame.height == bar.intrinsicContentSize.height && bar.frame.height == 72 && sound(bar)
                && root.bounds.contains(bar.frame),
            "in a 320 × 200 group the three-row bar has its whole height: no row is cut off (bar \(bar.frame.height), root \(root.frame.size))")
        check(
            tab.viewContainer.frame.height >= 32 && tab.viewContainer.frame.maxY <= bar.frame.minY
                && root.subviews.filter { !$0.isHidden }.allSatisfy { root.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame) },
            "and the text keeps its minimum height between the bar and the status row (text \(tab.viewContainer.frame.height))")
        picture(tab, "smallest-group")
        tab.setReplaceRow(shown: false)
        surface.frame = surfaceFrame
        _ = host.setEditorLayout(.single)
        window.setContentSize(NSSize(width: 1400, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        check(options.showsWords && bar.frame.height == 24, "widening the window brings back one row and the words")
        tab.hideFind(nil)
        check(keyboard(in: editor, of: host) && !tab.findBarVisible, "Escape or Done still closes the bar and returns to the text")
    }

    // MARK: Go to Line

    private static func goToLine(
        tab: EditorWindowController, document: TextDocument, app: AppDelegate, host: WorkspaceWindowController,
        window: NSWindow, folder: URL
    ) throws {
        let search = app.searchController, editor = tab.primaryEditor
        let bar = tab.goToLineBar, field = bar.field
        window.makeFirstResponder(editor)

        // Find is open with text and a live selection; Go to Line takes its place.
        _ = editor.setSelectionAnchor(0, caret: 0)
        tab.showFind(nil)
        typed("line 39", into: tab.findField, of: tab)
        spinUntil("fixture: the live count") { !tab.findCount.stringValue.isEmpty }
        tab.hideFind(nil)
        try require(editor.setSelectionAnchor(10, caret: 25), "fixture: a selection on line 1")
        editor.scrollTo(documentLine: 50, subline: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        tab.showFind(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let before = place(editor)
        try require(before.topLine == 50 && before.anchors == [10], "fixture: line 51 at the top, a selection kept")
        NativeFixtureEnvironment.announcements = []
        tab.goToLine(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            tab.goToLineBarVisible && !tab.findBarVisible && bar.superview === tab.findBar?.superview
                && bar.frame.minX == tab.findBar?.frame.minX && bar.frame.maxY == tab.findBar?.frame.maxY,
            "Go to Line is one inline field above the text, in the find bar's place, and the find bar is closed")
        check(
            presentedFormWindow == nil && !FormPanel.visible.contains { $0.window.identifier?.rawValue == "TextTank.GoToLine" },
            "no Go to Line panel opens: there is one presentation")
        check(
            search.sharedQuery == "line 39" && tab.findField.stringValue == "line 39",
            "the shared Find text is untouched by Go to Line taking the bar's place")
        check(
            bar.frame.height == 24 && sound(bar) && field.currentEditor() != nil && field.stringValue == "1"
                && bar.label.stringValue == "Go to line:" && field.accessibilityLabel() == "Line number in Go to Line",
            "the bar is one row: a labelled field that has the keyboard and holds the caret's line")
        check(
            bar.message.stringValue == "Lines are 1–400. Add a colon for a column, such as 12:4."
                && field.placeholderString == "1–400" && !bar.entryIsMarked
                && NativeFixtureEnvironment.announcements.contains(bar.message.stringValue),
            "the hint shows the valid range, 1–400, and how to give a column")
        check(place(editor) == before, "opening Go to Line moves neither the caret, the selection nor the text")

        // Typing a line the document has shows it, and nothing is recorded as a jump.
        let revision = editor.revision
        try keys("300", into: field)
        check(field.stringValue == "300", "keys typed into the field replace the line it opened with")
        check(
            editor.statusInfo.line == 300 && tab.goToLineBarVisible && editor.revision == revision && !editor.modified
                && editor.firstVisibleDocumentLine != before.topLine,
            "typing a valid line shows that line while the field stays open, with nothing added to Undo")
        // Out of range, and not a number: words beside the field, and the text is where it was.
        NativeFixtureEnvironment.announcements = []
        typed("500", into: field, of: tab)
        check(
            bar.message.stringValue == "There is no line 500. Lines are 1–400." && bar.entryIsMarked
                && field.accessibilityHelp() == bar.message.stringValue
                && NativeFixtureEnvironment.announcements.contains(bar.message.stringValue),
            "a line past the end says so in words beside the field, marks the field and is announced")
        picture(tab, "go-to-line-rejected")
        check(place(editor) == before, "and the caret, the selection and the scroll position are back where they were")
        check(
            press(returnKey, in: field, of: tab) && tab.goToLineBarVisible && field.stringValue == "500"
                && place(editor) == before && presentedFormWindow == nil && window.attachedSheet == nil,
            "Return on an out-of-range line keeps the entry and moves nothing: no alert")
        typed("12:4", into: field, of: tab)
        check(
            editor.statusInfo.line == 12 && editor.statusInfo.column == 4 && !bar.entryIsMarked
                && bar.message.stringValue.hasPrefix("Lines are 1–400."),
            "a valid entry clears the message, and 12:4 shows line 12 column 4")
        typed("abc", into: field, of: tab)
        check(
            bar.message.stringValue == "Enter a line number, such as 12 or 12:4. Lines are 1–400." && bar.entryIsMarked
                && place(editor) == before, "text that is not a number says what to enter, and moves nothing")
        typed("", into: field, of: tab)
        check(!bar.entryIsMarked && bar.message.stringValue.hasPrefix("Lines are 1–400."), "an emptied field is not an error")
        check(
            press(returnKey, in: field, of: tab) && tab.goToLineBarVisible && bar.entryIsMarked && place(editor) == before,
            "Return on an empty field asks for a line number")

        // Escape after a preview.
        try keys("350", into: field)
        try require(editor.statusInfo.line == 350, "fixture: line 350 is shown")
        try keyDown("\u{1B}", code: 53, in: field)
        check(
            !tab.goToLineBarVisible && !tab.findBarVisible && keyboard(in: editor, of: host),
            "Escape closes Go to Line and returns the keyboard to the text")
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            place(editor) == before, "Escape after a preview restores the caret, the selection and the scroll position exactly")

        // Return goes there and closes.
        // Return with the field as it opened changes nothing: not the caret, not the selection.
        tab.goToLine(nil)
        try require(field.stringValue == "1" && place(editor) == before, "fixture: the field holds the caret's line")
        try keyDown("\r", code: 36, in: field)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            !tab.goToLineBarVisible && place(editor) == before && editor.selectedText.utf8.count == 15
                && keyboard(in: editor, of: host),
            "Return on the line the field opened with closes it and keeps the caret, the selection and the scroll position")

        // Only Return or Go makes the jump. The keyboard leaving the field any other way (Tab,
        // Move Focus to Next Area) closes it and puts everything back.
        tab.goToLine(nil)
        try keys("300", into: field)
        try require(editor.statusInfo.line == 300, "fixture: line 300 is shown")
        window.makeFirstResponder(editor)
        spinUntil("Go to Line closes when the keyboard leaves it") { !tab.goToLineBarVisible }
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            !tab.goToLineBarVisible && place(editor) == before,
            "the keyboard leaving Go to Line without Return closes it and restores the caret, selection and scroll position")
        // A click that places a caret in the text of the pane being previewed is the person's own
        // move, made where they pointed: it stands, and it is not the previewed line.
        tab.goToLine(nil)
        try keys("300", into: field)
        window.contentView?.layoutSubtreeIfNeeded()
        let spot = try points(in: editor, down: 0.5)
        try click(at: spot.text, in: window, of: tab)
        let clicked = editor.selectionCaret
        spinUntil("Go to Line closes after a click in the text") { !tab.goToLineBarVisible }
        check(
            editor.selectionCaret == clicked && editor.selectionAnchor == clicked && editor.selectionCount == 1
                && (200...400).contains(editor.statusInfo.line) && !before.carets.contains(clicked)
                && keyboard(in: editor, of: host),
            "a click in the previewed text places the caret where it pointed, and that caret stands (line \(editor.statusInfo.line))")
        try require(editor.setSelectionAnchor(10, caret: 25), "fixture: the selection again")
        editor.scrollTo(documentLine: 50, subline: 0)
        try require(place(editor) == before, "fixture: where the text was")

        // Several selections, the main one, and a rectangular selection come back exactly.
        let lineStart = { (line: Int) in (1..<line).map { "line \($0) of the find bar fixture\n".utf8.count }.reduce(0, +) }
        let threeRanges = [(lineStart(60), lineStart(60) + 4), (lineStart(62) + 4, lineStart(62)), (lineStart(64), lineStart(64) + 4)]
        try require(
            editor.setSelectionRanges(threeRanges.map { TTSelectionRange(anchor: $0.0, caret: $0.1) }),
            "fixture: three selections")
        let three = place(editor)
        tab.goToLine(nil)
        try keys("300", into: field)
        try require(editor.selectionCount == 1 && editor.statusInfo.line == 300, "fixture: line 300 is shown")
        try keyDown("\u{1B}", code: 53, in: field)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            editor.selectionCount == 3 && place(editor) == three,
            "Escape puts back every selection, with the same one as the main selection")
        // Rectangular Selection is the keyboard column mode: plain moves then grow the rectangle.
        func command(_ name: String, times: Int = 1) -> Bool {
            (0..<times).allSatisfy { _ in editor.executeCommand(TTEditorCommandIdentifier(rawValue: name)) }
        }
        try require(
            editor.setSelectionRanges([TTSelectionRange(anchor: lineStart(60) + 2, caret: lineStart(60) + 2)])
                && command("rectangularSelection") && command("lineDown", times: 3) && command("charRight", times: 4)
                && editor.selectionIsRectangular && editor.selectionCount == 4 && editor.selectedText.count >= 16,
            "fixture: a rectangular selection of four lines (\(editor.selectionIsRectangular), \(editor.selectionCount))")
        let rectangle = place(editor)
        tab.goToLine(nil)
        try keys("300", into: field)
        try require(!editor.selectionIsRectangular && editor.statusInfo.line == 300, "fixture: line 300 is shown")
        try keyDown("\u{1B}", code: 53, in: field)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            editor.selectionIsRectangular && editor.selectionCount == 4 && place(editor) == rectangle,
            "and a rectangular selection is rectangular again, corner for corner")
        _ = editor.executeCommand(TTEditorCommandIdentifier(rawValue: "streamSelection"))
        _ = editor.setSelectionRanges([TTSelectionRange(anchor: 10, caret: 25)])

        tab.goToLine(nil)
        try keys("12:4", into: field)
        try keyDown("\r", code: 36, in: field)
        check(
            !tab.goToLineBarVisible && editor.statusInfo.line == 12
                && editor.statusInfo.column == 4 && editor.selectionAnchor == editor.selectionCaret
                && keyboard(in: editor, of: host),
            "“12:4” and Return go to line 12, column 4, close the field and return to the text")
        check(editor.revision == revision && !editor.modified, "Go to Line never edits the document")
        tab.goToLine(nil)
        typed("200:999", into: field, of: tab)
        _ = press(returnKey, in: field, of: tab)
        let endOfLine200 = (1...200).map { "line \($0) of the find bar fixture\n".utf8.count }.reduce(0, +) - 1
        check(
            editor.statusInfo.line == 200 && editor.selectionCaret == endOfLine200,
            "a column past the end of the line is the end of the line")

        // The buttons, for the pointer; and the status row's entry.
        tab.runStatusCommand(.position)
        check(tab.goToLineBarVisible && field.stringValue == "200", "the status row's Go to Line… opens the same field")
        typed("7", into: field, of: tab)
        bar.goButton.performClick(nil)
        check(!tab.goToLineBarVisible && editor.statusInfo.line == 7, "Go does what Return does")
        let atSeven = place(editor)
        tab.goToLine(nil)
        typed("90", into: field, of: tab)
        bar.cancelButton.performClick(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        check(!tab.goToLineBarVisible && place(editor) == atSeven, "Cancel does what Escape does")
        tab.goToLine(nil)
        tab.goToLine(nil)
        check(tab.goToLineBarVisible && field.currentEditor() != nil, "Command-L again keeps the one field and its keyboard")
        typed("90", into: field, of: tab)
        tab.showFind(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            tab.findBarVisible && !tab.goToLineBarVisible && place(editor).anchors == atSeven.anchors
                && place(editor).carets == atSeven.carets && tab.findField.stringValue == "line 39",
            "Find takes Go to Line's place: an entry that was only typed is not a jump, and the Find text is still there")
        tab.hideFind(nil)

        // The Go to Line bar at a narrow width.
        check(host.setEditorLayout(.twoColumns), "fixture: two editor groups")
        window.setContentSize(window.contentMinSize)
        tab.goToLine(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            bar.frame.width < 520 && bar.frame.height == 50 && sound(bar) && bar.message.frame.width == bar.bounds.width,
            "in a narrow group the range has a row of its own, so it is not cut short (DS-67)")
        picture(tab, "go-to-line-narrow")
        _ = press(escapeKey, in: field, of: tab)
        _ = host.setEditorLayout(.single)
        window.setContentSize(NSSize(width: 1400, height: 700))

        // A macro recording: showing a line is not a jump; Return is, exactly as before (F277).
        let macros = app.macros
        let priorInvalidated = macros.onInvalidated
        var discarded: [String] = []
        macros.onInvalidated = { discarded.append($0) }
        defer { macros.onInvalidated = priorInvalidated }
        window.makeFirstResponder(editor)
        EditorServices.current?.noteActiveController(tab)
        _ = editor.setSelectionAnchor(0, caret: 0)
        macros.startRecording()
        try require(macros.isRecording(in: editor), "fixture: recording in this view")
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "charRight"))
        tab.goToLine(nil)
        typed("300", into: field, of: tab)
        check(
            editor.selectionCaret == 1 && discarded.isEmpty && !bar.entryIsMarked,
            "while a macro is recording, typing a line does not move the caret or touch the recording")
        _ = press(escapeKey, in: field, of: tab)
        check(
            try macros.finishRecording()?.steps.count == 1 && discarded.isEmpty,
            "a Go to Line that was cancelled leaves the recording saveable")
        window.makeFirstResponder(editor)
        macros.startRecording()
        editor.executeCommand(TTEditorCommandIdentifier(rawValue: "charRight"))
        tab.goToLine(nil)
        typed("3", into: field, of: tab)
        check(
            press(returnKey, in: field, of: tab) && editor.statusInfo.line == 3 && discarded.count == 1
                && discarded.last?.contains("Go to Line") == true,
            "Return in Go to Line during a recording moves the caret and discards the recording, with the reason")
        rejects("Go to Line cannot silently save a partial recording", message: "Go to Line") {
            _ = try macros.finishRecording()
        }
        macros.onInvalidated = priorInvalidated

        // Another tab: an entry that was only typed does not survive leaving the tab.
        _ = editor.setSelectionAnchor(10, caret: 25)
        let held = place(editor)
        tab.goToLine(nil)
        typed("380", into: field, of: tab)
        let (other, otherTab) = try open("other.txt", "one\ntwo\nthree\n", in: folder)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            host.active === otherTab && !tab.goToLineBarVisible && place(editor).anchors == held.anchors
                && place(editor).carets == held.carets,
            "switching to another tab closes Go to Line and puts the caret and selection back")

        // A one-line document, and a document with many lines.
        otherTab.primaryEditor.text = "only"
        otherTab.goToLine(nil)
        check(
            otherTab.goToLineBar.message.stringValue.hasPrefix("This document has 1 line.")
                && otherTab.goToLineBar.field.placeholderString == "1", "a one-line document says so (DS-83)")
        typed("2", into: otherTab.goToLineBar.field, of: otherTab)
        check(
            otherTab.goToLineBar.message.stringValue == "There is no line 2. This document has 1 line.",
            "and rejects line 2 in words")
        // The text changes under the open field: the range follows.
        otherTab.primaryEditor.text = (1...250_000).map { "row \($0)" }.joined(separator: "\n")
        spinUntil("the range follows the document") {
            otherTab.goToLineBar.message.stringValue.hasPrefix("Lines are 1–250,000.")
        }
        check(
            otherTab.goToLineBar.field.placeholderString == "1–250,000" && !otherTab.goToLineBar.entryIsMarked,
            "when the document changes under the open field, the range and the entry are read against the new text")
        typed("249999:5", into: otherTab.goToLineBar.field, of: otherTab)
        let started = Date()
        check(
            press(returnKey, in: otherTab.goToLineBar.field, of: otherTab) && otherTab.primaryEditor.statusInfo.line == 249_999
                && otherTab.primaryEditor.statusInfo.column == 5 && Date().timeIntervalSince(started) < 1,
            "Go to Line works in a document of 250,000 lines")
        // Closing the document with the field open.
        otherTab.goToLine(nil)
        typed("5", into: otherTab.goToLineBar.field, of: otherTab)
        other.updateChangeCount(.changeCleared)
        other.close()
        check(!otherTab.goToLineBarVisible, "closing the document closes its Go to Line")

        // Folded text: showing a line never unfolds; Return does.
        let code = "void f() {\n  if (a) {\n    b();\n    c();\n  }\n}\nint tail;\n"
        let (folding, foldTab) = try open("fold.cpp", code, in: folder)
        defer { folding.close() }
        let folded = foldTab.primaryEditor, foldField = foldTab.goToLineBar.field
        folded.setLanguage("cpp")
        try require(
            folded.goToLine(3) && folded.executeCommand(TTEditorCommandIdentifier(rawValue: "foldCurrent"))
                && !folded.lineIsVisible(3) && !folded.lineIsVisible(4) && folded.lineIsVisible(2)
                && folded.lineIsVisible(6), "fixture: lines 3 to 5 are folded under line 2")
        try require(folded.setSelectionAnchor(code.utf8.count - 4, caret: code.utf8.count - 1), "fixture: a selection on line 7")
        window.contentView?.layoutSubtreeIfNeeded()
        let foldedPlace = place(folded)
        foldTab.goToLine(nil)
        try keys("4", into: foldField)
        check(
            !folded.lineIsVisible(4) && !folded.lineIsVisible(3) && folded.statusInfo.line == 2,
            "typing a line that is inside folded text does not unfold it: the fold's own line is shown")
        check(
            foldTab.goToLineBar.message.stringValue == "Line 4 is in folded text. Press Return to unfold it and go there."
                && !foldTab.goToLineBar.entryIsMarked, "and the field says why, in words")
        try keyDown("\u{1B}", code: 53, in: foldField)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            !folded.lineIsVisible(4) && !folded.lineIsVisible(3) && place(folded) == foldedPlace,
            "Escape leaves the folding as it was, with the caret, selection and scroll position back")
        foldTab.goToLine(nil)
        try keys("4", into: foldField)
        try keyDown("\r", code: 36, in: foldField)
        check(
            !foldTab.goToLineBarVisible && folded.lineIsVisible(4) && folded.statusInfo.line == 4
                && folded.selectionAnchor == folded.selectionCaret,
            "Return unfolds the line and goes there")

        try splitAndEdits(app: app, host: host, window: window, folder: folder)

        // A Preview-alone tab shows its source first, and going back to Preview closes the field.
        let (notes, notesTab) = try open("notes.md", "# Notes\n\none\ntwo\nthree\n", in: folder)
        defer { notes.close() }
        try require(notesTab.setViewMode(.preview) && notesTab.split.isHidden, "fixture: notes.md shows Preview alone")
        notesTab.goToLine(nil)
        check(
            notesTab.viewMode == .both && !notesTab.split.isHidden && notesTab.goToLineBarVisible,
            "Go to Line in a tab that shows Preview alone shows the source beside the preview first")
        typed("4", into: notesTab.goToLineBar.field, of: notesTab)
        check(
            notesTab.setViewMode(.preview) && !notesTab.goToLineBarVisible && notesTab.primaryEditor.statusInfo.line == 1,
            "choosing Preview closes Go to Line, which acts on the hidden source, and no jump was made")
    }

    // MARK: Go to Line in a split tab, and under edits from the other pane

    private static func splitAndEdits(
        app: AppDelegate, host: WorkspaceWindowController, window: NSWindow, folder: URL
    ) throws {
        let text = (1...400).map { "row \($0) of the split fixture" }.joined(separator: "\n")
        let (document, tab) = try open("split.txt", text, in: folder)
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
        }
        let first = tab.primaryEditor, field = tab.goToLineBar.field, bar = tab.goToLineBar
        tab.clone(nil)
        let second = try requireValue(tab.secondary, "fixture: the second pane of the split")
        window.contentView?.layoutSubtreeIfNeeded()
        // The new pane sizes its text view when it first draws.
        window.displayIfNeeded()
        spinUntil("the second pane has drawn its text") {
            let frame = second.convert(second.bounds, to: nil)
            return second.textAreaContains(windowPoint: NSPoint(x: frame.maxX - 60, y: frame.midY))
        }
        func hold() throws -> Place {
            window.makeFirstResponder(first)
            try require(
                first.setSelectionRanges([TTSelectionRange(anchor: 10, caret: 25)]) && tab.activeEditor === first,
                "fixture: a selection in the first pane, which has the keyboard")
            first.scrollTo(documentLine: 50, subline: 0)
            window.contentView?.layoutSubtreeIfNeeded()
            return place(first)
        }
        func preview() throws {
            tab.goToLine(nil)
            try keys("300", into: field)
            window.contentView?.layoutSubtreeIfNeeded()
            try require(tab.goToLineBarVisible && first.statusInfo.line == 300, "fixture: line 300 is shown in the first pane")
        }

        // A click in the other pane: the previewing pane goes back exactly, and the click lands.
        var before = try hold()
        _ = second.setSelectionAnchor(0, caret: 0)
        try preview()
        let otherSpot = try points(in: second, down: 0.5)
        try click(at: otherSpot.text, in: window, of: tab)
        spinUntil("Go to Line closes after a click in the other pane") { !tab.goToLineBarVisible }
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            !tab.goToLineBarVisible && place(first) == before,
            "a click in the other pane of a split puts the previewing pane back: caret, selection and scroll position (line \(first.statusInfo.line))")
        check(
            second.selectionCaret != 0 && keyboard(in: second, of: host) && tab.activeEditor === second,
            "and the click does what it does: its caret is in the other pane, which has the keyboard ")

        // A click on the previewing pane's own margin places no caret in the text.
        before = try hold()
        try preview()
        try click(at: try points(in: first, down: 0.5).margin, in: window, of: tab)
        spinUntil("the margin click is dealt with") { !tab.goToLineBarVisible || first.statusInfo.line != 300 }
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            first.statusInfo.line != 300 && first.firstVisibleDocumentLine == before.topLine,
            "a click on the previewing pane's line-number margin does not keep the previewed line (line \(first.statusInfo.line), field open \(tab.goToLineBarVisible))")
        if tab.goToLineBarVisible { tab.cancelGoToLine(nil) }

        // The text changes underneath, from the other pane: the place to go back to moves with
        // the edit, and is never the previewed line.
        before = try hold()
        let selected = first.selectedText
        try preview()
        try require(
            second.setSelectionRanges([TTSelectionRange(anchor: 0, caret: 0)]) && second.replaceSelection("added above\n"),
            "fixture: a line added at the top from the other pane")
        spinUntil("the field follows the edit") { field.placeholderString == "1–401" }
        check(
            bar.message.stringValue.hasPrefix("Lines are 1–401.") && !bar.entryIsMarked && first.statusInfo.line == 300,
            "an edit elsewhere in the text leaves the field open, with the new range, still showing the line typed")
        try keyDown("\u{1B}", code: 53, in: field)
        window.contentView?.layoutSubtreeIfNeeded()
        check(
            first.selectionAnchor == 10 + 12 && first.selectionCaret == 25 + 12 && first.selectedText == selected
                && first.selectionCount == 1,
            "Escape after an edit from another view goes back to the selection the person had, moved with the text, not to the previewed line (line \(first.statusInfo.line))")
        check(
            first.firstVisibleDocumentLine == before.topLine + 1 && first.horizontalScrollOffset == before.across,
            "and the same line of text is at the top again")

        // The text the caret was in is deleted underneath: the nearest place left, and words.
        before = try hold()
        try preview()
        NativeFixtureEnvironment.announcements = []
        try require(
            second.setSelectionRanges([TTSelectionRange(anchor: 0, caret: 60)]) && second.replaceSelection(""),
            "fixture: the first lines, with the caret's own, deleted from the other pane")
        spinUntil("the field says the place is gone") { bar.message.stringValue.hasPrefix("The text changed.") }
        check(
            bar.message.stringValue
                == "The text changed. Escape goes back to the nearest place left to where the caret was. \(GoToLineEntry.range(first.statusInfo.lines))"
                && !bar.entryIsMarked && NativeFixtureEnvironment.announcements.contains(bar.message.stringValue),
            "when the caret's own text is deleted underneath, the field says so in words and it is announced")
        try keyDown("\u{1B}", code: 53, in: field)
        check(
            first.selectionAnchor == 0 && first.selectionCaret == 0 && first.selectionCount == 1 && first.statusInfo.line == 1,
            "and Escape goes to the nearest place left, where the deleted text began, never to the previewed line (line \(first.statusInfo.line))")
    }
}
