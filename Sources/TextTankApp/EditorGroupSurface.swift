import AppKit
import TextTankCore

/// Native group chrome and split geometry (DS-14,41-43,70-74). No document ownership.
///
/// The surface is an ancestor of its tab strip, of the mounted tab's status row and of the
/// empty-group placeholder, so the keys those controls do not use themselves arrive here: the
/// arrow keys and Tab move between the controls of one area, Return presses the focused one and
/// Escape returns the keyboard to the text (DS-73). Nothing here changes a selection, a scroll
/// position or the active tab; only pressing a control does what that control always did.
final class EditorGroupSurface: NSView {
    let generation = UUID()
    var slot: GroupSlot
    weak var host: WorkspaceWindowController?
    let strip = DocumentTabStrip()
    let content = NSView()
    private let heading = NSButton()
    /// The single empty workspace gets a centered start area; split groups use a compact layout.
    private let placeholder = NSView()
    private let startIcon = NSImageView()
    private let startTitle = NSTextField(labelWithString: Strings.text("emptyGroup.start", "Open a document"))
    private let shortcutDisclosure = NSButton()
    private let emptyPrompt = NSTextField(
        wrappingLabelWithString: Strings.text("emptyGroup.dropPrompt", "Drop files here to open them."))
    private let emptyActions = NSStackView()
    let emptyStatus = AnnouncingLabel(labelWithString: "")
    private(set) weak var mounted: NSView?
    private weak var newButton: NSButton?
    private weak var openButton: NSButton?

    // MARK: Empty-group hint

    /// A command the hint names, with the sentence for the key it has now and the sentence that
    /// names its menu when it has none. The key is read from the menu bar each time, so a
    /// shortcut assigned in Settings is the one shown (DS-20).
    private struct HintCommand {
        let action: Selector
        /// The sentence with a place for the key, and the sentence that names the menu instead.
        /// Each is a whole catalogue entry (DS-84).
        let withKey: @MainActor () -> String
        let withoutKey: @MainActor () -> String
    }
    private static let hintCommands: [HintCommand] = [
        HintCommand(
            action: EditorToolbarCommand.new.action,
            withKey: { Strings.text("emptyGroup.hint.new", "Press %@ for a new document.") },
            withoutKey: { Strings.text("emptyGroup.hint.new.menu", "Choose File > New for a new document.") }),
        HintCommand(
            action: EditorToolbarCommand.open.action,
            withKey: { Strings.text("emptyGroup.hint.open", "Press %@ to open a document.") },
            withoutKey: { Strings.text("emptyGroup.hint.open.menu", "Choose File > Open… to open a document.") }),
        HintCommand(
            action: #selector(WorkspaceBrowserController.quickOpen(_:)),
            withKey: {
                Strings.text("emptyGroup.hint.quickOpen", "Press %@ for Quick Open, to find a file by name.")
            },
            withoutKey: {
                Strings.text(
                    "emptyGroup.hint.quickOpen.menu", "Choose File > Quick Open… to find a file by name.")
            }),
        HintCommand(
            action: NSSelectorFromString("paletteAction"),
            withKey: { Strings.text("emptyGroup.hint.palette", "Press %@ for the Command Palette.") },
            withoutKey: {
                Strings.text(
                    "emptyGroup.hint.palette.menu", "Choose Help > Command Palette… to run any command.")
            })
    ]
    /// One label for each command, in secondary label style. A command the menu bar does not
    /// list has no row.
    private(set) var hintRows: [NSTextField] = []
    private let recentHeading = NSTextField(labelWithString: Strings.text("emptyGroup.recent", "Recent files"))
    /// One button for each recent file that still exists, newest first.
    private(set) var recentButtons: [NSButton] = []
    /// The files the buttons open, in the same order.
    private(set) var recentFiles: [URL] = []
    static let recentLimit = 5
    /// How many recent files are checked for existence at most; the rest are never looked at.
    static let recentCandidateLimit = 20
    /// The recently opened files, newest first: the list File > Open Recent shows. A host whose
    /// support directory is isolated has no access to the person's list and shows none, unless
    /// it supplies its own here.
    static var recentFilesProvider: @MainActor () -> [URL] = {
        AppStorage.permitsLegacyDefaults ? NSDocumentController.shared.recentDocumentURLs : []
    }
    /// Opens a recent file by the Workspace Browser's own route, the one File > Workspace >
    /// Reopen Recent File uses: an open document is shown, a file that cannot be decoded is
    /// answered with the encoding chooser, and a failure is explained (DS-20).
    static var openRecentFile: @MainActor (URL) -> Void = { url in
        guard let browser = EditorServices.current?.workspaceBrowser else {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error, (error as NSError).code != NSUserCancelledError { NSApp.presentError(error) }
            }
            return
        }
        let item = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
        item.representedObject = url
        browser.openRecent(item)
    }
    private var recentCandidates: [URL]?
    private var recentGeneration = 0
    /// When the recent list was last read. A routine refresh reads it at most every two seconds.
    private var recentReadAt = -Double.infinity
    private var keyObserver: NSObjectProtocol?
    init(slot: GroupSlot, host: WorkspaceWindowController) {
        self.slot = slot
        self.host = host
        super.init(frame: .zero)
        strip.host = host
        strip.groupSlot = slot
        heading.isBordered = false
        heading.alignment = .left
        heading.target = self
        heading.action = #selector(focusGroup(_:))
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let new = NSButton(
            title: Strings.text("emptyGroup.new", "New"), target: self, action: #selector(createGroupDocument(_:)))
        newButton = new
        let open = NSButton(
            title: Strings.text("emptyGroup.open", "Open…"), target: self, action: #selector(openGroupDocument(_:)))
        openButton = open
        new.setAccessibilityLabel(Strings.text("emptyGroup.new.label", "New document in this group"))
        open.setAccessibilityLabel(Strings.text("emptyGroup.open.label", "Open a document in this group"))
        startIcon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        startIcon.imageScaling = .scaleProportionallyUpOrDown
        startIcon.contentTintColor = .secondaryLabelColor
        startIcon.setAccessibilityElement(false)
        startTitle.font = .preferredFont(forTextStyle: .title1)
        startTitle.identifier = .init("groups.start.title")
        startTitle.alignment = .center
        emptyPrompt.identifier = .init("groups.start.drop")
        emptyPrompt.textColor = .secondaryLabelColor
        shortcutDisclosure.title = Strings.text("emptyGroup.shortcuts", "Keyboard shortcuts")
        shortcutDisclosure.isBordered = false
        shortcutDisclosure.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcutDisclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        shortcutDisclosure.alternateImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        shortcutDisclosure.setButtonType(.onOff)
        shortcutDisclosure.imagePosition = .imageLeading
        shortcutDisclosure.target = self
        shortcutDisclosure.action = #selector(toggleShortcuts(_:))
        shortcutDisclosure.identifier = .init("groups.start.shortcuts")
        shortcutDisclosure.setAccessibilityLabel(shortcutDisclosure.title)
        emptyActions.setViews([new, open], in: .leading)
        emptyActions.spacing = 8
        emptyStatus.lineBreakMode = .byWordWrapping
        emptyStatus.maximumNumberOfLines = 2
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hintRows = Self.hintCommands.map { _ in
            let row = NSTextField(labelWithString: "")
            row.font = small
            row.textColor = .secondaryLabelColor
            row.lineBreakMode = .byClipping
            return row
        }
        recentHeading.font = small
        recentHeading.textColor = .secondaryLabelColor
        ([startIcon, startTitle, emptyPrompt, emptyActions, emptyStatus, shortcutDisclosure] + hintRows + [recentHeading]).forEach { placeholder.addSubview($0) }
        [heading, strip, content].forEach { addSubview($0) }
        content.addSubview(placeholder)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    @objc private func toggleShortcuts(_ sender: NSButton) {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
    @objc private func focusGroup(_ sender: Any?) { host?.focusGroup(slot) }
    @objc private func createGroupDocument(_ sender: Any?) {
        host?.focusGroup(slot)
        EditorServices.current?.newDocument(sender)
    }
    @objc private func openGroupDocument(_ sender: Any?) {
        host?.focusGroup(slot)
        NSDocumentController.shared.openDocument(sender)
    }
    override func mouseDown(with event: NSEvent) { host?.focusGroup(slot) }

    // MARK: Keyboard areas (DS-73)

    /// The placeholder of a group with no tabs, and the control that takes the keyboard there.
    var emptyGroupArea: NSView? { placeholder.isHidden ? nil : placeholder }
    var emptyGroupFocusView: NSView? { Self.controls(in: placeholder).first ?? newButton }
    /// The mounted tab's status row. It is found by its identifier, so the row needs no hook.
    var statusRow: NSView? {
        mounted.flatMap { root in Self.descendants(of: root).first { $0.identifier?.rawValue == "status.row" } }
    }
    /// The tab titles, marks and close buttons that are showing, in reading order.
    /// The tabs scroll, so a tab can lie beyond the strip's edge; the list of open tabs, which
    /// does not scroll, comes after every tab wherever it is drawn.
    var tabControls: [NSControl] {
        let all = Self.controls(in: strip)
        func scrolls(_ control: NSControl) -> Bool { control.enclosingScrollView?.isDescendant(of: strip) == true }
        return all.filter(scrolls) + all.filter { !scrolls($0) }
    }
    var statusControls: [NSControl] { statusRow.map(Self.controls(in:)) ?? [] }
    /// The title button of `tab`, which is where the keyboard enters the strip.
    func tabTitle(_ tab: TabID?) -> NSControl? {
        let controls = tabControls
        return tab.flatMap { id in controls.first { $0.identifier?.rawValue == "tab." + id.rawValue.uuidString } }
            ?? controls.first(where: Self.isTabTitle)
    }
    private static func isTabTitle(_ control: NSControl) -> Bool {
        guard let id = control.identifier?.rawValue else { return false }
        return id.hasPrefix("tab.") && !id.hasPrefix("tab.viewMode.")
    }
    private static func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants(of:)) }
    /// The buttons and pop-ups in `view` that can take the keyboard now, top row first and from
    /// the leading edge. A hidden or disabled control is not offered.
    static func controls(in view: NSView) -> [NSControl] {
        descendants(of: view).compactMap { $0 as? NSButton }.filter {
            $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor && $0.acceptsFirstResponder
        }.sorted { a, b in
            let first = a.convert(a.bounds, to: nil), second = b.convert(b.bounds, to: nil)
            return abs(first.midY - second.midY) > 4 ? first.midY > second.midY : first.minX < second.minX
        }
    }
    private func moveKeyboard(to control: NSView) {
        guard window?.makeFirstResponder(control) == true else { return }
        // Only the tab strip scrolls, and only far enough to show the control that has the keyboard.
        control.scrollToVisible(control.bounds)
    }
    /// Escape outside the text: the keyboard returns to this group's text, or, from a group with
    /// no tabs, to the text of the active tab. False when the text already has the keyboard.
    @discardableResult func returnKeyboardToText() -> Bool {
        guard let host, let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self)
        else { return false }
        let shown = host.model.groups.sorted { $0.slot == slot && $1.slot != slot }.compactMap {
            $0.activeTab.flatMap { host.presentation(for: $0) }
        }
        // The two bars keep their own Escape: Go to Line puts the caret, selection and scroll
        // position back and closes; the find bar closes (DS-35). Each returns the keyboard itself.
        if let own = shown.first, mounted === own.presentationRoot {
            if own.goToLineBarVisible, responder.isDescendant(of: own.goToLineBar) {
                own.cancelGoToLine(nil)
                return true
            }
            if own.findBarVisible, let bar = own.findBar, responder.isDescendant(of: bar) {
                own.hideFind(nil)
                return true
            }
        }
        guard let target = shown.first?.keyboardFocusView, target.window === window,
            !responder.isDescendant(of: target)
        else { return false }
        return window.makeFirstResponder(target)
    }
    override func cancelOperation(_ sender: Any?) {
        if !returnKeyboardToText() { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }
    override func keyDown(with event: NSEvent) {
        if !handleAreaKey(event) { super.keyDown(with: event) }
    }
    /// The keys a tab title, a status item or a placeholder button passed up.
    private func handleAreaKey(_ event: NSEvent) -> Bool {
        guard let host, let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self)
        else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53, modifiers.isEmpty { return returnKeyboardToText() }
        let inStrip = responder.isDescendant(of: strip)
        let inPlaceholder = !placeholder.isHidden && responder.isDescendant(of: placeholder)
        let controls: [NSControl]
        if inStrip {
            controls = tabControls
        } else if inPlaceholder {
            controls = Self.controls(in: placeholder)
        } else if let row = statusRow, responder.isDescendant(of: row) {
            controls = statusControls
        } else {
            return false
        }
        guard let index = controls.firstIndex(where: { responder.isDescendant(of: $0) }) else { return false }
        switch event.keyCode {
        case 123, 124, 125, 126:
            // Left and Right; in the placeholder, whose buttons are stacked, Up and Down as well.
            guard modifiers.isEmpty, inPlaceholder || event.keyCode < 125 else { return false }
            let step = event.keyCode == 124 || event.keyCode == 125 ? 1 : -1
            var choices = controls, position = index
            if inStrip {
                // From tab to tab: the mark and the close button are reached with Tab.
                choices = controls.filter(Self.isTabTitle)
                guard let own = controls[...index].last(where: Self.isTabTitle),
                    let at = choices.firstIndex(where: { $0 === own })
                else { return true }
                // The list of open tabs follows the last tab and belongs to none: Left Arrow
                // from it reaches the last tab's title.
                position = controls[index] is NSPopUpButton ? at + 1 : at
            }
            if choices.indices.contains(position + step) { moveKeyboard(to: choices[position + step]) }
            return true
        case 48:
            // Tab and Shift-Tab step through every control of the area, then leave it.
            guard modifiers.isEmpty || modifiers == .shift else { return false }
            let step = modifiers.isEmpty ? 1 : -1
            if controls.indices.contains(index + step) {
                moveKeyboard(to: controls[index + step])
            } else {
                host.areaFocus.move(step)
            }
            return true
        case 49, 36, 76:
            // Space presses the control that has the keyboard: it selects a tab, closes one, runs
            // a status button's command or opens a pull-down's menu. Return presses a button too;
            // a pull-down (a status field, More, the list of open tabs) opens with Space only.
            guard modifiers.isEmpty, let button = controls[index] as? NSButton,
                event.keyCode == 49 || !(button is NSPopUpButton)
            else { return false }
            button.performClick(nil)
            return true
        default:
            return false
        }
    }
    // MARK: Empty-group hint: live keys and recent files

    /// The first item of the menu bar that sends `action` and is listed.
    private static func menuItem(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action == action, !item.isHidden { return item }
            if let found = menuItem(action, in: item.submenu) { return found }
        }
        return nil
    }
    /// Brings the command rows up to date with the keys the menu bar has now.
    func refreshHint() {
        guard mounted == nil else { return }
        var changed = false
        for (command, row) in zip(Self.hintCommands, hintRows) {
            var text = "", spoken = ""
            if let item = Self.menuItem(command.action, in: NSApp.mainMenu) {
                if let key = ControlPresentation.shortcut(of: item) {
                    let format = command.withKey()
                    text = String(format: format, key)
                    spoken = String(format: format, ControlPresentation.spokenShortcut(of: item) ?? key)
                } else {
                    text = command.withoutKey()
                    spoken = text
                }
            }
            if row.stringValue != text {
                row.stringValue = text
                changed = true
            }
            // VoiceOver reads the key in words: "Shift-Command-O", not its symbols.
            if row.accessibilityLabel() != spoken { row.setAccessibilityLabel(spoken) }
        }
        if changed { needsLayout = true }
    }
    /// Lists the recent files that still exist. The list is read on the main thread, at most every
    /// two seconds unless `force` is set (the group became empty, or the window became key);
    /// whether each file exists is asked on a utility queue, for at most `recentCandidateLimit`
    /// files, and an answer that arrives after a newer question is dropped (DS-100).
    func refreshRecentFiles(force: Bool = false) {
        guard mounted == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - recentReadAt >= 2 else { return }
        recentReadAt = now
        var seen = Set<String>()
        let candidates = Array(
            Self.recentFilesProvider().filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
                .prefix(Self.recentCandidateLimit))
        guard force || candidates != recentCandidates else { return }
        recentCandidates = candidates
        recentGeneration += 1
        let generation = recentGeneration, limit = Self.recentLimit
        guard !candidates.isEmpty else {
            showRecentFiles([])
            return
        }
        let deliver: @MainActor @Sendable ([URL]) -> Void = { [weak self] found in
            guard let self, self.recentGeneration == generation else { return }
            self.showRecentFiles(found)
        }
        DispatchQueue.global(qos: .utility).async {
            var existing: [URL] = []
            for url in candidates where existing.count < limit {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue {
                    existing.append(url)
                }
            }
            let found = existing
            DispatchQueue.main.async { deliver(found) }
        }
    }
    private func showRecentFiles(_ urls: [URL]) {
        guard urls != recentFiles || recentButtons.count != urls.count else { return }
        let hadKeyboard = recentButtons.contains { $0 === window?.firstResponder }
        recentButtons.forEach { $0.removeFromSuperview() }
        recentFiles = urls
        // Two files with the same name are told apart by their folder, as in File > Open Recent.
        let names = Dictionary(grouping: urls, by: \.lastPathComponent)
        recentButtons = urls.enumerated().map { index, url in
            let duplicate = (names[url.lastPathComponent]?.count ?? 0) > 1
            let name =
                duplicate
                ? String(
                    format: Strings.text("emptyGroup.recent.nameInFolder", "%1$@ — %2$@"), url.lastPathComponent,
                    url.deletingLastPathComponent().lastPathComponent) : url.lastPathComponent
            let button = NSButton(title: name, target: self, action: #selector(openRecent(_:)))
            button.tag = index
            button.isBordered = false
            button.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.alignment = .left
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.lineBreakMode = .byTruncatingMiddle
            button.toolTip = url.path
            button.identifier = .init("groups.recent.\(index)")
            button.setAccessibilityLabel(
                String(format: Strings.text("emptyGroup.recent.open", "Open recent file %@"), name))
            placeholder.addSubview(button)
            return button
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if hadKeyboard, let first = emptyGroupFocusView { window?.makeFirstResponder(first) }
    }
    @objc private func openRecent(_ sender: NSButton) {
        guard !CompareCommandScope.blocksWorkspace, recentFiles.indices.contains(sender.tag) else { return }
        host?.focusGroup(slot)
        Self.openRecentFile(recentFiles[sender.tag])
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        // Coming back from Settings or from another application: a key may have been reassigned
        // and a recent file may have gone.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshHint()
                self?.refreshRecentFiles(force: true)
            }
        }
        refreshHint()
        refreshRecentFiles(force: true)
    }
    func refresh() {
        strip.groupSlot = slot
        strip.refresh()
        refreshHint()
        refreshRecentFiles()
        let name = host?.groupLabel(slot) ?? "Group \(slot.rawValue)"
        let focused = host?.model.focusedGroup == slot
        heading.identifier = .init("groups.heading.\(slot.rawValue)")
        heading.title = (focused ? "▶ " : "   ") + name
        heading.setAccessibilityLabel(name + (focused ? ", focused" : ""))
        setAccessibilityLabel("Editor " + name.lowercased())
        needsLayout = true
    }
    func mount(_ root: NSView?) {
        if mounted !== root {
            mounted?.removeFromSuperview()
            mounted = root
            if let root { content.addSubview(root) }
        }
        placeholder.isHidden = root != nil
        if root == nil {
            refreshHint()
            refreshRecentFiles(force: true)
        }
        needsLayout = true
    }
    /// Shows a message in a group with no tabs, where there is no status row to show it.
    func showEmptyStatus(_ message: String) {
        emptyStatus.stringValue = message
        ControlPresentation.label(message, control: emptyStatus)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        // One group needs no heading: there is nothing to tell apart and nowhere else to focus (DS-10).
        heading.isHidden = host?.model.layout == .single
        let h = heading.isHidden ? 0 : min(20, bounds.height)
        heading.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        strip.frame = NSRect(x: 0, y: max(0, bounds.height - h - 36), width: bounds.width, height: 36)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - h - 36))
        mounted?.frame = content.bounds
        layoutPlaceholder()
    }
    /// The start area foregrounds actions and recent files; a small empty split keeps its shortcuts
    /// visible. In either layout, entries that cannot fit are hidden from drawing and focus (DS-67).
    private func layoutPlaceholder() {
        let start = host?.model.layout == .single
        let availableWidth = max(0, content.bounds.width - 24)
        let columnWidth = start ? min(370, availableWidth) : availableWidth
        placeholder.frame = NSRect(
            x: floor((content.bounds.width - columnWidth) / 2), y: 0,
            width: columnWidth, height: content.bounds.height)
        guard !placeholder.isHidden else { return }
        let width = placeholder.bounds.width, gap: CGFloat = 8, rowGap: CGFloat = 3, margin: CGFloat = 8
        let alignment: NSTextAlignment = start ? .center : .natural
        if emptyPrompt.alignment != alignment { emptyPrompt.alignment = alignment }
        let newTitle = start ? Strings.text("emptyGroup.newDocument", "New Document") : Strings.text("emptyGroup.new", "New")
        let openTitle = start ? Strings.text("emptyGroup.openFile", "Open File…") : Strings.text("emptyGroup.open", "Open…")
        if newButton?.title != newTitle { newButton?.title = newTitle }
        if openButton?.title != openTitle { openButton?.title = openTitle }
        let actionSize: NSControl.ControlSize = start ? .large : .regular
        for case let button as NSButton in emptyActions.views where button.controlSize != actionSize {
            button.controlSize = actionSize
        }
        func height(_ label: NSTextField) -> CGFloat {
            ceil(label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
        emptyStatus.isHidden = emptyStatus.stringValue.isEmpty
        startIcon.isHidden = !start
        startTitle.isHidden = !start
        var rows: [(view: NSView, height: CGFloat, gap: CGFloat)] = []
        if start {
            rows.append((startIcon, 38, 0))
            rows.append((startTitle, height(startTitle), 10))
        }
        rows.append((emptyPrompt, height(emptyPrompt), start ? 4 : 0))
        rows.append((emptyActions, ceil(emptyActions.fittingSize.height), start ? 14 : gap))
        if !emptyStatus.isHidden { rows.append((emptyStatus, height(emptyStatus), gap)) }
        var used = rows.reduce(CGFloat(0)) { $0 + $1.height + $1.gap }
        let available = placeholder.bounds.height - 2 * margin
        var full = false
        /// Adds `views` together or not at all. Once one thing does not fit, nothing after it is
        /// shown, so what is listed is always the start of the list.
        func offer(_ views: [(NSView, CGFloat)], leading: CGFloat) {
            let needed = views.enumerated().reduce(CGFloat(0)) { total, entry in
                total + entry.element.1 + (entry.offset == 0 ? leading : rowGap)
            }
            guard !full, used + needed <= available else {
                full = true
                views.forEach { $0.0.isHidden = true }
                return
            }
            for (index, entry) in views.enumerated() {
                entry.0.isHidden = false
                rows.append((entry.0, entry.1, index == 0 ? leading : rowGap))
            }
            used += needed
        }
        func offerHints() {
            var first = true
            for row in hintRows {
                let size = row.intrinsicContentSize
                guard !row.stringValue.isEmpty, ceil(size.width) <= width else {
                    row.isHidden = true
                    continue
                }
                offer([(row, ceil(size.height))], leading: first ? gap : rowGap)
                first = false
            }
        }
        shortcutDisclosure.isHidden = !start
        if !start { offerHints() }
        let headingHeight = ceil(recentHeading.intrinsicContentSize.height)
        if recentButtons.isEmpty { recentHeading.isHidden = true }
        for (index, button) in recentButtons.enumerated() {
            let entry = (button as NSView, max(20, ceil(button.intrinsicContentSize.height)))
            // The heading appears with the first file or not at all.
            offer(index == 0 ? [(recentHeading, headingHeight), entry] : [entry], leading: index == 0 ? (start ? 18 : gap) : rowGap)
        }
        if start {
            offer([(shortcutDisclosure, ceil(shortcutDisclosure.intrinsicContentSize.height))], leading: 14)
            if shortcutDisclosure.state == .on {
                offerHints()
            } else {
                hintRows.forEach { $0.isHidden = true }
            }
        }
        // Center the entire group of visible items, keeping a margin in small panes.
        let actionWidth = ceil(emptyActions.fittingSize.width)
        let recentWidth = recentButtons.reduce(actionWidth) { max($0, ceil($1.intrinsicContentSize.width)) }
        var y = placeholder.bounds.height - max(margin, (placeholder.bounds.height - used) / 2)
        for row in rows {
            y -= row.gap + row.height
            let fitting: CGFloat
            if row.view === emptyActions {
                fitting = actionWidth
            } else if row.view === shortcutDisclosure {
                fitting = ceil(shortcutDisclosure.intrinsicContentSize.width)
            } else if start && (row.view === recentHeading || recentButtons.contains(where: { $0 === row.view })) {
                fitting = recentWidth
            } else {
                fitting = width
            }
            let rowWidth = min(width, fitting)
            let x = start ? floor((width - rowWidth) / 2) : 0
            row.view.frame = NSRect(x: x, y: y, width: rowWidth, height: row.height)
        }
    }
    deinit {
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        }
    }
}

final class EditorGroupContainer: NSView, NSSplitViewDelegate {
    private var root: NSView?
    private var splitMinimum: [ObjectIdentifier: CGFloat] = [:]
    private(set) var dividers: [NSSplitView] = []
    private var synchronizing = false
    private var alignColumns = false
    func configure(_ layout: LayoutKind, surfaces: [EditorGroupSurface]) {
        alignColumns = false
        surfaces.forEach { $0.removeFromSuperview() }
        root?.removeFromSuperview()
        dividers = []
        splitMinimum = [:]
        func split(_ vertical: Bool, _ children: [NSView], minimum: CGFloat) -> NSSplitView {
            let v = NSSplitView()
            v.isVertical = vertical
            v.dividerStyle = .thin
            v.delegate = self
            children.forEach { v.addArrangedSubview($0) }
            splitMinimum[ObjectIdentifier(v)] = minimum
            dividers.append(v)
            return v
        }
        switch layout {
        case .single: root = surfaces[0]
        case .twoColumns: root = split(true, surfaces, minimum: 320)
        case .twoRows: root = split(false, surfaces, minimum: 200)
        case .grid2x2:
            let top = split(true, Array(surfaces[0...1]), minimum: 320)
            let bottom = split(true, Array(surfaces[2...3]), minimum: 320)
            root = split(false, [top, bottom], minimum: 200)
        }
        if let root {
            addSubview(root)
            root.frame = bounds
            root.autoresizingMask = [.width, .height]
        }
        needsLayout = true
        // Native dividers retain their positions until configure is called for a layout change.
        layoutSubtreeIfNeeded()
        dividers.reversed().forEach {
            $0.adjustSubviews()
            $0.setPosition(($0.isVertical ? $0.bounds.width : $0.bounds.height) / 2, ofDividerAt: 0)
        }
        alignColumns = layout == .grid2x2
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard alignColumns, !synchronizing, let source = notification.object as? NSSplitView, source.isVertical,
            let other = dividers.first(where: { $0.isVertical && $0 !== source })
        else { return }
        // While the window is being resized the two rows are resized one after the other. A
        // position copied from the row already resized to the row still at its old width was
        // then scaled again, which left the columns out of line and one narrower than its
        // minimum. The rows are aligned only once both have the same width.
        guard abs(other.bounds.width - source.bounds.width) < 0.5 else { return }
        alignGridColumns(following: source)
    }
    // A split view reports a resize when it has laid its panes out, which under its own layout
    // pass can be after `resizeSubviews` returns. The rows are therefore aligned at each of the
    // three moments a frame can have changed: here, in `layout` and when a row reports.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        alignGridColumns()
    }
    override func layout() {
        super.layout()
        alignGridColumns()
    }
    /// Puts the column divider of both rows at the same place: where `leader`'s is (the row
    /// that was dragged, otherwise the first row), held so that no column is narrower than its
    /// minimum. A resize keeps the divider's share of the width; a share given up to the minimum
    /// is not taken back when the window widens, as with every other divider in the window.
    private func alignGridColumns(following leader: NSSplitView? = nil) {
        guard alignColumns, !synchronizing else { return }
        let rows = dividers.filter(\.isVertical)
        guard rows.count == 2, abs(rows[0].bounds.width - rows[1].bounds.width) < 0.5, rows[0].bounds.width > 0,
            let current = (leader ?? rows[0]).subviews.first?.frame.width
        else { return }
        let width = rows[0].bounds.width, least = splitMinimum[ObjectIdentifier(rows[0])] ?? 0
        let most = max(least, width - least - rows[0].dividerThickness)
        let position = min(most, max(least, current))
        synchronizing = true
        for row in rows where abs((row.subviews.first?.frame.width ?? 0) - position) > 0.5 {
            row.setPosition(position, ofDividerAt: 0)
        }
        synchronizing = false
    }
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat { max(proposedMinimumPosition, splitMinimum[ObjectIdentifier(splitView)] ?? 0) }
    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(
            proposedMaximumPosition,
            (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height)
                - (splitMinimum[ObjectIdentifier(splitView)] ?? 0) - splitView.dividerThickness)
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}

/// The keyboard route between the areas of the workspace window (DS-73): Window > Move Focus.
///
/// The areas, in order: the Workspace Browser when it is shown; then, for each editor group in
/// its usual order, the tab strip, the find bar when it is shown, the text (each pane of a split
/// view, then the preview in Both; the preview alone when the tab shows only it) and the status
/// row. A group with no tabs is one area, its New and Open buttons. The commands go round this
/// ring and back.
///
/// Moving the keyboard changes nothing else: no selection, no scroll position and no group's
/// active tab. The group that receives the keyboard becomes the focused group, as it does when
/// it is clicked, so commands act where the focus ring is. Each move is announced by the name of
/// the area it reached (DS-72); the standard focus ring shows it.
@MainActor final class WindowAreaFocusController: NSObject, NSMenuItemValidation {
    enum Kind: String { case sidebar, tabs, findBar, goToLine, text, preview, status, emptyGroup }
    struct Area {
        let kind: Kind
        /// The group the area belongs to; nil for the sidebar.
        let slot: GroupSlot?
        /// The keyboard is in the area while the first responder is this view or inside it.
        let container: NSView
        /// The view that takes the keyboard when the area is entered.
        let target: NSView
        let announcement: String
    }
    /// F6 and Shift-F6, with Option-Command-` and Shift-Option-Command-` for keyboards whose
    /// function keys need the Fn key. None of the four is used by a menu, by the editor's own key
    /// map or by a reserved system shortcut.
    static let nextShortcut = MenuShortcut("\u{f709}", [])
    static let previousShortcut = MenuShortcut("\u{f709}", [.shift])
    static let nextAlternate = MenuShortcut("`", [.command, .option])
    static let previousAlternate = MenuShortcut("~", [.command, .option])
    static let menuTitle = "Move Focus"
    static let nextTitle = "Move Focus to Next Area"
    static let previousTitle = "Move Focus to Previous Area"

    private unowned let host: WorkspaceWindowController
    /// The sentence announced for the area the keyboard last moved to.
    private(set) var lastAnnouncement = ""
    init(host: WorkspaceWindowController) { self.host = host }

    /// The two commands, each with its default key, and a hidden second key for each. The
    /// defaults give way to a shortcut the person assigns (`DefaultShortcutItem`).
    func addMenuItems(to menu: NSMenu) {
        let commands: [(String, Selector, MenuShortcut, Bool)] = [
            (Self.nextTitle, #selector(moveFocusToNextArea(_:)), Self.nextShortcut, false),
            (Self.previousTitle, #selector(moveFocusToPreviousArea(_:)), Self.previousShortcut, false),
            (Self.nextTitle, #selector(moveFocusToNextArea(_:)), Self.nextAlternate, true),
            (Self.previousTitle, #selector(moveFocusToPreviousArea(_:)), Self.previousAlternate, true)
        ]
        for (title, action, shortcut, alias) in commands {
            let item = DefaultShortcutItem(title, action: action, shortcut: shortcut)
            item.target = self
            item.isHidden = alias
            item.allowsKeyEquivalentWhenHidden = alias
            menu.addItem(item)
        }
    }
    var isAvailable: Bool {
        guard host.window != nil else { return false }
        return !host.hasAttachedSheet && !host.isMutatingGroups && !host.tabCommands.isBusy
            && !CompareCommandScope.blocksWorkspace
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { isAvailable }
    @objc func moveFocusToNextArea(_ sender: Any?) { move(1) }
    @objc func moveFocusToPreviousArea(_ sender: Any?) { move(-1) }

    /// The areas that are present now, in the order the commands visit them.
    func areas() -> [Area] {
        var result: [Area] = []
        let group = host.model.groups.count > 1
        if host.isSidebarShown, let sidebar = host.sidebarSplit.sidebar, let target = host.sidebarFocusView {
            result.append(
                Area(
                    kind: .sidebar, slot: nil, container: sidebar, target: target,
                    announcement: Self.sentence(.sidebar, group: nil, name: "")))
        }
        for entry in host.model.groups {
            guard let surface = host.groupSurfaces[entry.slot] else { continue }
            let label = group ? host.groupLabel(entry.slot) : nil
            func add(_ kind: Kind, _ container: NSView, _ target: NSView, name: String = "") {
                result.append(
                    Area(
                        kind: kind, slot: entry.slot, container: container, target: target,
                        announcement: Self.sentence(kind, group: label, name: name)))
            }
            guard let tab = entry.activeTab, let presentation = host.presentation(for: tab),
                surface.mounted === presentation.presentationRoot
            else {
                if let area = surface.emptyGroupArea, let target = surface.emptyGroupFocusView {
                    add(.emptyGroup, area, target)
                }
                continue
            }
            let name = (presentation.document as? TextDocument)?.displayName ?? "Untitled"
            if let title = surface.tabTitle(tab) { add(.tabs, surface.strip, title) }
            // The find bar and Go to Line share one slot; only one of them is shown at a time.
            if presentation.findBarVisible, let bar = presentation.findBar {
                add(.findBar, bar, presentation.findField)
            }
            if presentation.goToLineBarVisible {
                add(.goToLine, presentation.goToLineBar, presentation.goToLineBar.field)
            }
            // The hidden source of a tab that shows Preview alone is not an area: putting the
            // keyboard there would make the tab show Both.
            if presentation.viewMode != .preview {
                for editor in presentation.views {
                    add(.text, editor, editor, name: editor.accessibilityDocumentName ?? name)
                }
            }
            if presentation.viewMode != .source, let pane = presentation.previewCoordinator?.pane {
                add(.preview, pane, pane.focusView, name: name)
            }
            if let row = surface.statusRow, let first = surface.statusControls.first { add(.status, row, first) }
        }
        return result
    }
    /// One whole sentence for each area, with and without the group's name (DS-84).
    private static func sentence(_ kind: Kind, group: String?, name: String) -> String {
        switch (kind, group) {
        case (.sidebar, _): return Strings.text("areas.sidebar", "Workspace Browser.")
        case (.tabs, nil): return Strings.text("areas.tabs", "Tabs.")
        case (.tabs, let group?): return String(format: Strings.text("areas.tabs.group", "Tabs in %@."), group)
        case (.findBar, nil): return Strings.text("areas.find", "Find bar.")
        case (.findBar, let group?): return String(format: Strings.text("areas.find.group", "Find bar in %@."), group)
        case (.goToLine, nil): return Strings.text("areas.goToLine", "Go to Line.")
        case (.goToLine, let group?):
            return String(format: Strings.text("areas.goToLine.group", "Go to Line in %@."), group)
        case (.text, nil): return String(format: Strings.text("areas.text", "Text of %@."), name)
        case (.text, let group?):
            return String(format: Strings.text("areas.text.group", "Text of %1$@ in %2$@."), name, group)
        case (.preview, nil): return String(format: Strings.text("areas.preview", "Preview of %@."), name)
        case (.preview, let group?):
            return String(format: Strings.text("areas.preview.group", "Preview of %1$@ in %2$@."), name, group)
        case (.status, nil): return Strings.text("areas.status", "Document status.")
        case (.status, let group?):
            return String(format: Strings.text("areas.status.group", "Document status in %@."), group)
        case (.emptyGroup, nil): return Strings.text("areas.empty", "Empty editor group.")
        case (.emptyGroup, let group?): return String(format: Strings.text("areas.empty.group", "%@, empty."), group)
        }
    }
    /// The view that has the keyboard. A text field's typing is done by the window's field
    /// editor on the field's behalf, so the field is what is returned for it.
    private func currentResponderView(in window: NSWindow?) -> NSView? {
        guard let responder = window?.firstResponder else { return nil }
        if let editor = responder as? NSText, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return field
        }
        return responder as? NSView
    }
    /// The area that holds the keyboard, or nil when none does.
    func currentArea(in areas: [Area]) -> Int? {
        guard let view = currentResponderView(in: host.window) else { return nil }
        return areas.firstIndex { view.isDescendant(of: $0.container) }
    }
    /// Moves the keyboard `direction` areas round the ring (1 or -1), skipping an area that
    /// cannot take it now. With the keyboard in no area the first move reaches the focused
    /// group's text. Returns false, with nothing changed, when no area took the keyboard.
    @discardableResult func move(_ direction: Int) -> Bool {
        guard isAvailable, let window = host.window else { return false }
        let ring = areas()
        guard !ring.isEmpty else { return false }
        let start: Int
        if let current = currentArea(in: ring) {
            start = current
        } else {
            let home =
                ring.firstIndex {
                    $0.slot == host.model.focusedGroup && [.text, .preview, .emptyGroup].contains($0.kind)
                } ?? 0
            start = home - direction
        }
        if NSApp.isActive, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        for step in 1...ring.count {
            let index = ((start + direction * step) % ring.count + ring.count) % ring.count
            if enter(ring[index], in: window) { return true }
        }
        return false
    }
    private func enter(_ area: Area, in window: NSWindow) -> Bool {
        guard area.target.window === window, !area.target.isHiddenOrHasHiddenAncestor else { return false }
        // Leaving Go to Line by this route is not Return: the bar closes and the caret, the
        // selection and the scroll position go back to what they were before it opened.
        if let responder = currentResponderView(in: window) {
            for presentation in host.presentations
            where presentation.goToLineBarVisible && responder.isDescendant(of: presentation.goToLineBar)
                && !area.target.isDescendant(of: presentation.goToLineBar)
            {
                presentation.closeGoToLineBar(restoring: true, returningKeyboard: false)
            }
        }
        if let slot = area.slot, slot != host.model.focusedGroup { host.focusGroup(slot, focus: false) }
        if area.kind == .sidebar { host.sidebarWillTakeKeyboardByArea() }
        guard window.makeFirstResponder(area.target) else { return false }
        if area.kind == .tabs { area.target.scrollToVisible(area.target.bounds) }
        lastAnnouncement = area.announcement
        Announce.say(area.announcement, from: window)
        return true
    }
}

/// The workspace window's root split: the docked Workspace Browser, when it is shown, and the
/// editor groups (owner decision DS-D11). The editor area is always the last pane and is never
/// removed or rebuilt, so showing and hiding the sidebar leaves every editor as it was.
///
/// Widths follow `WorkspaceSidebarGeometry`: the sidebar keeps the width the person dragged it
/// to while the window is resized, gives up width before the editor groups do, and never goes
/// below its minimum, so the panes never overlap (DS-67). No material or translucency is added:
/// the sidebar draws on the window's own background (DS-11).
final class WorkspaceSidebarSplit: NSSplitView, NSSplitViewDelegate {
    let editorArea: NSView
    private(set) var sidebar: NSView?
    /// The width the person chose. It changes only when they drag the divider.
    var preferredWidth = CGFloat(WorkspaceSidebarGeometry.defaultWidth) {
        didSet { layoutPanes() }
    }
    /// The width the editor groups need for their layout.
    var editorMinimumWidth = CGFloat(TabGroupGeometry.minimumContent(.single).width) {
        didSet { layoutPanes() }
    }
    /// The person dragged the divider.
    var onUserResize: (() -> Void)?
    init(editorArea: NSView) {
        self.editorArea = editorArea
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(editorArea)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    func setSidebar(_ view: NSView?) {
        guard sidebar !== view else { return }
        sidebar?.removeFromSuperview()
        sidebar = view
        if let view { insertArrangedSubview(view, at: 0) }
        layoutPanes()
    }
    private func layoutPanes() {
        guard let sidebar else {
            editorArea.frame = bounds
            return
        }
        let width = CGFloat(
            WorkspaceSidebarGeometry.width(
                preferred: Double(preferredWidth), total: Double(bounds.width),
                editorMinimum: Double(editorMinimumWidth)))
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        editorArea.frame = NSRect(
            x: width + dividerThickness, y: 0, width: max(0, bounds.width - width - dividerThickness),
            height: bounds.height)
    }
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { layoutPanes() }
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat { max(proposedMinimumPosition, CGFloat(WorkspaceSidebarGeometry.minimumWidth)) }
    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(
            CGFloat(WorkspaceSidebarGeometry.minimumWidth),
            min(
                proposedMaximumPosition, CGFloat(WorkspaceSidebarGeometry.maximumWidth),
                bounds.width - dividerThickness - editorMinimumWidth))
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    /// Remembers the width only when the person moved the divider.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let sidebar, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        let width = sidebar.frame.width
        if abs(width - preferredWidth) > 0.5 {
            preferredWidth = width
            onUserResize?()
        }
    }
}
