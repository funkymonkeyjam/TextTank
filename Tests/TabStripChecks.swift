// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

/// What a tab draws and how it answers the mouse: the edited dot in the close button's place,
/// the symbols for an outside change and for comparison, the tooltip, the other mouse button,
/// a double-click on the empty strip, and the list of open tabs when the strip overflows. Driven
/// through the application's own workspace window and tab strip. Nothing here needs the window
/// to be key, and no menu, sheet or alert is presented.
@MainActor enum TabStripChecks {
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
    private static func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }
    private static func tabButton(_ tab: EditorWindowController, in strip: DocumentTabStrip) throws -> NSButton {
        let id = try requireValue(tab.tabID, "fixture: tab identity")
        return try requireValue(
            buttons(in: strip).first { $0.identifier?.rawValue == "tab." + id.rawValue.uuidString },
            "fixture: the tab's own button")
    }
    private static func closeButton(_ document: TextDocument, in strip: DocumentTabStrip) throws -> NSButton {
        try requireValue(
            buttons(in: strip).first { $0.accessibilityLabel() == "Close " + document.displayName },
            "fixture: the close button of \(document.displayName ?? "")")
    }
    private static func appearance(_ tab: EditorWindowController, in strip: DocumentTabStrip) throws
        -> DocumentTabStrip.TabAppearance
    {
        try requireValue(strip.tabAppearance(try requireValue(tab.tabID, "fixture: tab identity")), "fixture: tab appearance")
    }
    private static func hover(_ tab: EditorWindowController?, in strip: DocumentTabStrip) throws {
        guard let tab else {
            strip.pointerMoved(to: nil)
            return
        }
        let button = try tabButton(tab, in: strip)
        strip.pointerMoved(to: strip.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button))
    }
    private static func closeAll(_ host: WorkspaceWindowController) {
        host.tabCommands.isTerminating = true
        NSDocumentController.shared.documents.forEach { $0.close() }
        host.tabCommands.isTerminating = false
    }
    /// Lays the window out at `width` and returns the width every tab then has.
    private static func resize(_ host: WorkspaceWindowController, to width: CGFloat, strip: DocumentTabStrip) throws {
        let window = try requireValue(host.window, "workspace window")
        window.setContentSize(NSSize(width: width, height: window.contentView?.bounds.height ?? 600))
        window.contentView?.layoutSubtreeIfNeeded()
        strip.layout()
    }

    static func run(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let window = try requireValue(host.window, "workspace window")
        let size = window.contentView?.bounds.size ?? .zero
        defer {
            closeAll(host)
            window.setContentSize(size)
        }
        try stateSymbols(root: root, app: app, host: host)
        closeAll(host)
        try mouseAndToolTip(root: root, app: app, host: host)
        closeAll(host)
        try openTabList(root: root, app: app, host: host)
        closeAll(host)
    }

    // MARK: The edited dot and the state symbols

    private static func stateSymbols(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let folder = root.appendingPathComponent("tab-state")
        let (notes, notesTab) = try open("notes.md", "# Notes\n", in: folder)
        let (plain, plainTab) = try open("plain.txt", "plain\n", in: folder)
        let (other, otherTab) = try open("other.txt", "other\n", in: folder)
        let strip = try requireValue(host.tabStrips.first, "fixture: the focused group's tab strip")
        try resize(host, to: 1000, strip: strip)
        host.activate(otherTab)
        try hover(nil, in: strip)

        // Edited: a dot where the close button is, the cross under the pointer or the keyboard.
        let close = try closeButton(notes, in: strip)
        var drawn = try appearance(notesTab, in: strip)
        check(
            drawn.title == "notes.md" && !drawn.closeShowsEditedDot && drawn.outsideChange == nil && drawn.comparison == nil,
            "fixture: a saved tab shows its name, the cross and no state symbol")
        let cross = close.image
        _ = notesTab.primaryEditor.replaceSelection("edited ")
        spinUntil("the edited dot") { (try? appearance(notesTab, in: strip).closeShowsEditedDot) == true }
        drawn = try appearance(notesTab, in: strip)
        check(notes.isDocumentEdited && drawn.closeShowsEditedDot, "an edited tab shows the dot in the close button's place")
        check(
            drawn.title == "notes.md" && drawn.accessibilityLabel == "notes.md, edited",
            "the title of an edited tab is its name alone; its label says it is edited (\(drawn.title))")
        let again = try closeButton(notes, in: strip)
        check(
            again === close && close.image != nil && close.image !== cross && close.isEnabled && !close.isHidden
                && close.action != nil && close.target === strip && close.frame.width == 28 && close.frame.height == 28,
            "DS-14/74 the dot is the close button itself: the same 28 by 28 target, action and review")
        check(
            close.accessibilityLabel() == "Close notes.md" && close.toolTip == "Close notes.md",
            "DS-70 the dot still says it closes the document")
        try hover(notesTab, in: strip)
        check(try !appearance(notesTab, in: strip).closeShowsEditedDot, "the pointer over an edited tab shows the cross")
        try hover(otherTab, in: strip)
        check(try appearance(notesTab, in: strip).closeShowsEditedDot, "and the dot returns when the pointer moves to another tab")
        try hover(nil, in: strip)
        let window = try requireValue(host.window, "workspace window")
        check(window.makeFirstResponder(close), "fixture: the close button takes the keyboard")
        check(
            try !appearance(notesTab, in: strip).closeShowsEditedDot,
            "DS-73 the close button of an edited tab shows the cross while it has the keyboard")
        check(window.makeFirstResponder(otherTab.primaryEditor), "fixture: the keyboard returns to the text")
        check(try appearance(notesTab, in: strip).closeShowsEditedDot, "and the dot once the keyboard has left it")
        check(
            try !appearance(plainTab, in: strip).closeShowsEditedDot && !appearance(otherTab, in: strip).closeShowsEditedDot,
            "tabs that are not edited keep the cross")

        // A file changed outside TextTank: a symbol, not a character in the title.
        _ = plainTab.primaryEditor.replaceSelection("mine ")
        try Data("changed elsewhere\n".utf8).write(to: try requireValue(plain.fileURL, "fixture: saved file"), options: .atomic)
        plain.externalFile.check(prioritized: true)
        spinUntil("the outside change") {
            plain.externalFile.notice != nil && (try? appearance(plainTab, in: strip).outsideChange) != nil
        }
        drawn = try appearance(plainTab, in: strip)
        let notice = plain.externalFile.notice ?? ""
        let outside = try requireValue(drawn.outsideChange, "a tab whose file changed outside shows a symbol")
        check(
            drawn.title == "plain.txt" && notice == "Changed on disk",
            "and its title is the name alone (\(drawn.title); \(notice))")
        check(
            outside.toolTip == "plain.txt: Changed on disk. Select this tab to choose what to do."
                && outside.accessibilityLabel == outside.toolTip,
            "DS-62/70/85 the symbol says what happened and what to do, in its tooltip and to assistive technology")
        check(
            drawn.accessibilityLabel == "plain.txt, edited. Changed on disk.",
            "DS-84 the tab's own label says both in whole sentences (\(drawn.accessibilityLabel ?? "nil"))")
        let plainID = try requireValue(plainTab.tabID, "fixture: plain tab")
        var frames = try requireValue(strip.tabLayout(plainID), "fixture: layout")
        check(
            outside.frame.minX - frames.title.maxX == 4 && frames.close.minX - outside.frame.maxX == 4
                && frames.close.width == 28 && outside.frame.width == 16,
            "DS-14 four points separate the title, the symbol and the 28-point close target")

        // Selected for comparison.
        let compare = try requireValue(EditorServices.current?.compare, "fixture: the compare service")
        try compare.mark(otherTab.primaryEditor)
        drawn = try appearance(otherTab, in: strip)
        let compared = try requireValue(drawn.comparison, "a tab selected for comparison shows a symbol")
        check(
            drawn.title == "other.txt" && drawn.accessibilityLabel == "other.txt. Selected for comparison.",
            "its title is the name alone and its label says it is selected (\(drawn.accessibilityLabel ?? "nil"))")
        check(
            compared.toolTip
                == "other.txt is selected for comparison. Choose Compare with Selected on another tab to compare them."
                && compared.accessibilityLabel == compared.toolTip,
            "DS-70/85 the comparison symbol says what it means and what to do next")

        // Both on one tab, wide and at the minimum width.
        try compare.mark(plainTab.primaryEditor)
        drawn = try appearance(plainTab, in: strip)
        frames = try requireValue(strip.tabLayout(plainID), "fixture: layout")
        check(
            try drawn.comparison != nil && drawn.outsideChange != nil && appearance(otherTab, in: strip).comparison == nil,
            "a wide tab shows both symbols; the tab no longer selected loses its symbol")
        check(
            drawn.accessibilityLabel == "plain.txt, edited. Changed on disk. Selected for comparison.",
            "DS-84 and one whole label for the two together (\(drawn.accessibilityLabel ?? "nil"))")
        if let first = drawn.outsideChange, let second = drawn.comparison {
            check(
                first.frame.minX - frames.title.maxX == 4 && second.frame.minX - first.frame.maxX == 4
                    && frames.close.minX - second.frame.maxX == 4,
                "the two symbols sit between the title and the close button, four points apart")
        }
        var fillers: [TextDocument] = []
        for number in 1...4 { fillers.append(try open("filler\(number).txt", "filler\n", in: folder).0) }
        try resize(host, to: 800, strip: strip)
        frames = try requireValue(strip.tabLayout(plainID), "fixture: layout")
        let width = frames.close.maxX + 8 - (frames.title.minX - 8)
        check(width < 162 && width >= 130, "fixture: seven tabs in an 800-point window are near the minimum width (\(width) pt)")
        drawn = try appearance(plainTab, in: strip)
        check(
            drawn.outsideChange != nil && drawn.comparison == nil && drawn.closeShowsEditedDot
                && frames.title.width == width - 68
                && frames.title.width >= DocumentTabStrip.minimumTitleWidthBesideComparisonMark,
            "at the minimum width the outside change wins: it and the dot are drawn, the comparison symbol is not (\(frames.title.width) pt title)")
        check(
            drawn.accessibilityLabel == "plain.txt, edited. Changed on disk. Selected for comparison.",
            "and what is not drawn is still in the tab's label")
        try compare.mark(otherTab.primaryEditor)
        let otherID = try requireValue(otherTab.tabID, "fixture: other tab")
        frames = try requireValue(strip.tabLayout(otherID), "fixture: layout")
        check(
            try appearance(otherTab, in: strip).comparison != nil && frames.title.width == width - 68,
            "alone, the comparison symbol fits a tab at the minimum width")
        // With the eye of a tab in Preview, the eye and the outside change stay.
        check(notesTab.setViewMode(.preview), "fixture: the notes tab shows Preview")
        try Data("# Changed elsewhere\n".utf8).write(to: try requireValue(notes.fileURL, "fixture: saved file"), options: .atomic)
        notes.externalFile.check(prioritized: true)
        spinUntil("the second outside change") { (try? appearance(notesTab, in: strip).outsideChange) != nil }
        let notesID = try requireValue(notesTab.tabID, "fixture: notes tab")
        frames = try requireValue(strip.tabLayout(notesID), "fixture: layout")
        drawn = try appearance(notesTab, in: strip)
        if let mark = drawn.outsideChange {
            check(
                frames.markShown && drawn.closeShowsEditedDot && frames.mark.minX - mark.frame.maxX == 4
                    && mark.frame.minX - frames.title.maxX == 4 && frames.close.minX - frames.mark.maxX == 4,
                "a narrow tab in Preview keeps its eye, the outside-change symbol and the dot, four points apart")
        } else {
            check(false, "a narrow tab in Preview keeps its outside-change symbol")
        }
        check(
            drawn.accessibilityLabel == "notes.md, edited, showing Preview. Changed on disk.",
            "DS-84 the label of an edited Preview tab with an outside change (\(drawn.accessibilityLabel ?? "nil"))")

        // A press on a symbol is a press on its tab.
        let plainMark = descendantImageViews(of: strip).first {
            !$0.isHidden && $0.toolTip?.hasPrefix("plain.txt:") == true
        }
        if let mark = plainMark {
            let point = mark.convert(NSPoint(x: 8, y: 8), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try requireValue(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1), "fixture: a click")
            }
            check(host.active !== plainTab, "fixture: the plain tab is not the active one")
            mark.mouseDown(with: try event(.leftMouseDown))
            mark.mouseUp(with: try event(.leftMouseUp))
            check(host.active === plainTab, "a click on a state symbol selects its tab")
        } else {
            check(false, "fixture: the outside-change symbol of the plain tab")
        }
        _ = (other, fillers)
    }
    // MARK: Tooltip, the other mouse button and a double-click on the empty strip

    private static func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1, in window: NSWindow
    ) throws -> NSEvent {
        try requireValue(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1), "fixture: a mouse event")
    }
    /// The view a press at `point` (in the strip's coordinates) reaches, as AppKit would find it.
    private static func target(at point: NSPoint, in strip: DocumentTabStrip) throws -> NSView {
        try requireValue(
            strip.hitTest(strip.superview?.convert(point, from: strip) ?? point), "fixture: a view under the pointer")
    }
    private static func otherClick(down: NSPoint, up: NSPoint, in strip: DocumentTabStrip, window: NSWindow) throws {
        let view = try target(at: down, in: strip)
        view.otherMouseDown(with: try mouse(.otherMouseDown, at: strip.convert(down, to: nil), in: window))
        view.otherMouseUp(with: try mouse(.otherMouseUp, at: strip.convert(up, to: nil), in: window))
    }
    private static func click(_ count: Int, at point: NSPoint, in strip: DocumentTabStrip, window: NSWindow) throws {
        let view = try target(at: point, in: strip)
        view.mouseDown(with: try mouse(.leftMouseDown, at: strip.convert(point, to: nil), clicks: count, in: window))
        view.mouseUp(with: try mouse(.leftMouseUp, at: strip.convert(point, to: nil), clicks: count, in: window))
    }
    private static func middle(of tab: EditorWindowController, in strip: DocumentTabStrip) throws -> NSPoint {
        let button = try tabButton(tab, in: strip)
        return strip.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)
    }

    private static func mouseAndToolTip(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        // The rule, with a made-up home folder.
        let home = "/home/person"
        check(
            DocumentTabStrip.tabToolTip(name: "a.txt", path: "/home/person/Notes/a.txt", notice: nil, home: home)
                == "~/Notes/a.txt",
            "a saved file's tooltip is its full path with the home folder written as ~")
        check(
            DocumentTabStrip.tabToolTip(name: "a.txt", path: "/home/personal/a.txt", notice: nil, home: home)
                == "/home/personal/a.txt"
                && DocumentTabStrip.tabToolTip(name: "a.txt", path: "/srv/a.txt", notice: nil, home: home + "/")
                    == "/srv/a.txt"
                && DocumentTabStrip.tabToolTip(name: "person", path: home, notice: nil, home: home) == "~",
            "only the home folder itself is abbreviated: a folder whose name merely starts the same is not")
        check(
            DocumentTabStrip.tabToolTip(name: "Untitled", path: nil, notice: nil, home: home) == "Untitled",
            "a document with no file shows its name")
        check(
            DocumentTabStrip.tabToolTip(name: "a.txt", path: "/home/person/a.txt", notice: "Changed on disk", home: home)
                == "~/a.txt\nChanged on disk",
            "a notice follows the path on its own line")

        let folder = root.appendingPathComponent("tab-mouse")
        let (first, firstTab) = try open("first.txt", "first\n", in: folder)
        let (second, secondTab) = try open("second.txt", "second\n", in: folder)
        let (third, thirdTab) = try open("third.txt", "third\n", in: folder)
        let strip = try requireValue(host.tabStrips.first, "fixture: the focused group's tab strip")
        let window = try requireValue(host.window, "workspace window")
        try resize(host, to: 1000, strip: strip)
        try hover(nil, in: strip)
        let path = try requireValue(first.fileURL?.path, "fixture: saved path")
        let expected = DocumentTabStrip.tabToolTip(name: "first.txt", path: path, notice: nil)
        let userHome = NSHomeDirectory()
        check(
            try tabButton(firstTab, in: strip).toolTip == expected && expected.hasSuffix("/tab-mouse/first.txt")
                && (path.hasPrefix(userHome + "/") ? expected.hasPrefix("~/") : expected == path),
            "the tab of a saved file shows that path as its tooltip")
        let untitled = DocumentFactory.makeUntitled()
        let untitledTab = try requireValue(untitled.presentation, "fixture: untitled tab")
        check(
            try tabButton(untitledTab, in: strip).toolTip == untitled.displayName,
            "the tab of an untitled document shows its name as its tooltip")
        _ = thirdTab.primaryEditor.replaceSelection("mine ")
        try Data("changed elsewhere\n".utf8).write(to: try requireValue(third.fileURL, "fixture: saved file"), options: .atomic)
        third.externalFile.check(prioritized: true)
        spinUntil("the outside change") { third.externalFile.notice != nil }
        check(
            try tabButton(thirdTab, in: strip).toolTip
                == DocumentTabStrip.tabToolTip(name: "third.txt", path: third.fileURL?.path, notice: "Changed on disk")
                && tabButton(thirdTab, in: strip).toolTip?.hasSuffix("/third.txt\nChanged on disk") == true,
            "with an outside change the tooltip gives the path and then the notice")

        // The other mouse button closes the tab it is pressed and released on.
        host.activate(firstTab)
        func documents() -> Int { NSDocumentController.shared.documents.count }
        var count = documents()
        try otherClick(down: try middle(of: secondTab, in: strip), up: try middle(of: firstTab, in: strip), in: strip, window: window)
        settle()
        check(
            documents() == count && second.isOpen && first.isOpen,
            "an other-button press on one tab released on another closes nothing")
        let empty = NSPoint(x: strip.bounds.maxX - 60, y: strip.bounds.midY)
        check(
            strip.tabLayout(try requireValue(untitledTab.tabID, "fixture: untitled tab")).map { $0.close.maxX + 8 < empty.x }
                == true, "fixture: the strip has an empty part after its last tab")
        try otherClick(down: empty, up: empty, in: strip, window: window)
        settle()
        check(documents() == count, "an other-button click on the empty strip closes nothing")
        try otherClick(down: try middle(of: secondTab, in: strip), up: try middle(of: secondTab, in: strip), in: strip, window: window)
        spinUntil("the other-button close") { !second.isOpen }
        check(
            !second.isOpen && documents() == count - 1 && first.isOpen && third.isOpen && host.active === firstTab,
            "an other-button click on a tab closes that tab, and only that one, without selecting it first")
        let closeOfFirst = try closeButton(first, in: strip)
        let onClose = strip.convert(NSPoint(x: closeOfFirst.bounds.midX, y: closeOfFirst.bounds.midY), from: closeOfFirst)
        host.activate(thirdTab)
        count = documents()
        try otherClick(down: onClose, up: onClose, in: strip, window: window)
        spinUntil("the other-button close on the close button") { !first.isOpen }
        check(
            !first.isOpen && documents() == count - 1,
            "the other button closes from anywhere on the tab, its close button included")

        // A double-click on the empty strip is File > New; on a tab it is nothing new.
        count = documents()
        try click(1, at: empty, in: strip, window: window)
        check(documents() == count, "a single click on the empty strip opens nothing")
        try click(2, at: empty, in: strip, window: window)
        let created = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }.filter {
            $0 !== untitled && $0 !== third && $0.fileURL == nil
        }
        check(
            documents() == count + 1 && created.count == 1 && host.active === created.first?.presentation
                && host.model.focusedGroup == strip.groupSlot,
            "a double-click on the empty part of the strip opens one new untitled tab and shows it")
        count = documents()
        let onThird = try middle(of: thirdTab, in: strip)
        try click(1, at: onThird, in: strip, window: window)
        try click(2, at: onThird, in: strip, window: window)
        check(
            documents() == count && host.active === thirdTab && third.isOpen,
            "a double-click on a tab selects it and opens nothing")
        // A release that did not begin on the empty strip, such as the end of a reorder, opens nothing.
        let thirdID = try requireValue(thirdTab.tabID, "fixture: third tab")
        check(strip.beginReorder(thirdID), "fixture: a reorder begins")
        strip.updateReorder(at: empty)
        strip.finishReorder(at: empty)
        strip.mouseUp(with: try mouse(.leftMouseUp, at: strip.convert(empty, to: nil), clicks: 2, in: window))
        check(documents() == count && !strip.isReordering, "the end of a reorder on the empty strip opens nothing")
        // The window's frame keeps its own double-click on its inside edge.
        if let border = window.contentView?.superview {
            let claimed = stride(from: strip.bounds.maxX - 0.5, to: strip.bounds.maxX - 12, by: -0.5).map {
                NSPoint(x: $0, y: strip.bounds.midY)
            }.first { border.hitTest(border.convert(strip.convert($0, to: nil), from: nil)) === border }
            if let claimed {
                strip.mouseDown(with: try mouse(.leftMouseDown, at: strip.convert(claimed, to: nil), clicks: 2, in: window))
                strip.mouseUp(with: try mouse(.leftMouseUp, at: strip.convert(claimed, to: nil), clicks: 2, in: window))
                check(documents() == count, "a double-click where the window frame takes the pointer is left to the frame")
            } else {
                print("NOTE the window frame claims no point of the tab strip in this window; nothing to leave to it")
            }
        }
    }
    // MARK: The list of open tabs when the strip overflows

    private static func choose(_ item: NSMenuItem) -> Bool {
        guard item.isEnabled, let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
    private static func openTabList(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let folder = root.appendingPathComponent("tab-list")
        let strip = try requireValue(host.tabStrips.first, "fixture: the focused group's tab strip")
        let window = try requireValue(host.window, "workspace window")
        let clip = try requireValue(
            strip.subviews.compactMap { $0 as? NSScrollView }.first?.contentView, "fixture: the strip's scrolling area")
        var tabs: [(TextDocument, EditorWindowController)] = []
        for number in 1...6 { tabs.append(try open("list\(number).txt", "text\n", in: folder)) }
        try resize(host, to: 800, strip: strip)
        let list = strip.openTabListButton
        func children() -> [NSView] { (strip.accessibilityChildren() ?? []).compactMap { $0 as? NSView } }
        check(
            !strip.showsOpenTabList && list.isHidden && !children().contains { $0 === list }
                && clip.convert(clip.bounds, to: strip).maxX == strip.bounds.maxX,
            "six tabs fit an 800-point strip at the minimum width: no list of open tabs, and the tabs have the whole strip")
        tabs.append(try open("list7.txt", "text\n", in: folder))
        try resize(host, to: 800, strip: strip)
        check(strip.showsOpenTabList && !list.isHidden, "a seventh tab overflows the strip, and the list of open tabs appears")
        let frame = strip.openTabListFrame, scrolling = clip.convert(clip.bounds, to: strip)
        check(
            frame.width == 28 && frame.height == 28 && frame.minX - scrolling.maxX == 4 && frame.maxX <= strip.bounds.maxX
                && list.superview === strip && !list.isDescendant(of: clip),
            "DS-14/74 it is a 28 by 28 target at the trailing end, outside the scrolling area and four points from it")
        check(
            list.accessibilityLabel() == "Open tabs in this group" && list.toolTip == "Open tabs in this group"
                && children().last === list && list.menu?.items.first?.image != nil,
            "DS-70 it is labelled Open tabs in this group, and is the strip's last accessibility child")
        check(
            list.acceptsFirstResponder && window.makeFirstResponder(list) && window.firstResponder === list,
            "DS-73 it takes the keyboard like any pull-down")
        window.makeFirstResponder(tabs[0].1.primaryEditor)
        let lastID = try requireValue(tabs[6].1.tabID, "fixture: last tab")
        let layout = try requireValue(strip.tabLayout(lastID), "fixture: layout")
        check(
            layout.close.width == 28 && layout.close.minX - layout.title.maxX == 4
                && layout.close.maxX + 8 - (layout.title.minX - 8) == DocumentTabStrip.minimumTabWidth,
            "the tabs keep their 130 points and their own separated 28-point close target")

        // Every tab, in order, with the active one checked and pinned and edited said in words.
        host.activate(tabs[0].1)
        _ = tabs[2].1.primaryEditor.replaceSelection("edited ")
        spinUntil("the edited tab") { tabs[2].0.isDocumentEdited }
        host.tabCommands.perform(.pin, target: try requireValue(tabs[4].1.tabID, "fixture: fifth tab"))
        _ = tabs[4].1.primaryEditor.replaceSelection("edited ")
        spinUntil("the pinned, edited tab") { tabs[4].0.isDocumentEdited }
        host.tabCommands.perform(.pin, target: try requireValue(tabs[5].1.tabID, "fixture: sixth tab"))
        var items = strip.openTabListItems()
        let order = host.model.groups.first { $0.slot == strip.groupSlot }?.tabs.map(\.id) ?? []
        check(
            items.count == 7 && items.compactMap { $0.representedObject as? TabID } == order,
            "the list has every tab of the group, in the strip's order (\(items.map(\.title)))")
        check(
            items.map(\.title) == [
                "list5.txt, pinned, edited", "list6.txt, pinned", "list1.txt", "list2.txt", "list3.txt, edited",
                "list4.txt", "list7.txt"
            ], "DS-62 each row names its document and says in words when it is pinned or edited (\(items.map(\.title)))")
        check(
            items.filter { $0.state == .on }.map(\.title) == ["list1.txt"] && items.allSatisfy { $0.isEnabled },
            "the active tab, and only it, has the checkmark")
        check(
            (list.menu?.items.count ?? 0) == 8 && list.menu?.delegate === strip,
            "the pull-down fills itself when it opens; its first item is its own face")

        // Choosing a row selects that tab and scrolls it into view.
        clip.scroll(to: .zero)
        check(!strip.isTabHorizontallyVisible(lastID), "fixture: the last tab is scrolled out of view")
        check(choose(try requireValue(items.last, "fixture: last row")), "fixture: the last row can be chosen")
        check(
            host.active === tabs[6].1 && strip.isTabHorizontallyVisible(lastID),
            "choosing a tab from the list selects it and scrolls it into view")
        clip.scroll(to: .zero)
        items = strip.openTabListItems()
        check(
            items.filter { $0.state == .on }.map(\.title) == ["list7.txt"] && !strip.isTabHorizontallyVisible(lastID),
            "fixture: the checkmark follows the active tab, which is scrolled away again")
        check(
            choose(try requireValue(items.last, "fixture: last row")) && host.active === tabs[6].1
                && strip.isTabHorizontallyVisible(lastID),
            "choosing the tab that is already active scrolls it into view")
        let stale = try requireValue(items.first { $0.title == "list2.txt" }, "fixture: a row")
        tabs[1].0.close()
        _ = choose(stale)
        check(
            host.active === tabs[6].1 && !tabs[1].0.isOpen,
            "a row kept from a tab that has since closed selects nothing")

        // Six tabs fit again: the list goes.
        try resize(host, to: 800, strip: strip)
        check(
            !strip.showsOpenTabList && !children().contains { $0 === list }
                && clip.convert(clip.bounds, to: strip).maxX == strip.bounds.maxX,
            "when the tabs fit again the list of open tabs disappears and the tabs have the whole strip")

        // Each group has its own list, of its own tabs.
        tabs.append(try open("list8.txt", "text\n", in: folder))
        try resize(host, to: 800, strip: strip)
        check(strip.showsOpenTabList, "fixture: seven tabs overflow again")
        check(host.setEditorLayout(.twoColumns), "fixture: two editor groups")
        let moved = [tabs[6].1, tabs[7].1].compactMap(\.tabID)
        for id in moved { host.moveTabs([id], target: id, to: .second) }
        window.contentView?.layoutSubtreeIfNeeded()
        host.tabStrips.forEach { $0.layout() }
        if host.tabStrips.count == 2 {
            let left = host.tabStrips[0], right = host.tabStrips[1]
            let rightTabs = host.model.groups.first { $0.slot == right.groupSlot }?.tabs.map(\.id) ?? []
            check(
                left.showsOpenTabList && !right.showsOpenTabList && left.openTabListButton !== right.openTabListButton
                    && rightTabs.count == 2,
                "with two groups, the group whose tabs overflow shows its list and the group whose tabs fit does not")
            check(
                left.openTabListItems().compactMap { $0.representedObject as? TabID }
                    == (host.model.groups.first { $0.slot == left.groupSlot }?.tabs.map(\.id) ?? [])
                    && left.openTabListItems().count == 5 && right.openTabListItems().count == 2,
                "and each list holds its own group's tabs")
        } else {
            check(false, "fixture: two tab strips")
        }
        closeAll(host)
        check(host.setEditorLayout(.single), "fixture: back to one group")
    }
    private static func settle() {
        let end = Date().addingTimeInterval(0.2)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    private static func descendantImageViews(of view: NSView) -> [NSImageView] {
        view.subviews.flatMap { ($0 as? NSImageView).map { [$0] } ?? descendantImageViews(of: $0) }
    }
}
