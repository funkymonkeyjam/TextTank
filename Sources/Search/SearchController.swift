// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// What the last Find-window action did, set wherever the status line is set. Checks and
/// callers read this instead of parsing the status wording.
enum SearchOutcome: Equatable {
    case needsInput
    case found(matches: Int, documents: Int, truncated: Bool)
    case noFurtherMatches
    case staleResult
    case limitReached
    case replaced(changed: Int, stale: Int)
    case marked(matches: Int, stale: Int, zeroWidth: Int)
    case bookmarked(stale: Int)
    case clearedHighlights(documents: Int)
    case cancelled
    case failed(String)
}

/// Native snapshot search. Workers never access TTEditor; results are revision checked.
final class SearchController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var currentEditor: () -> TTEditor? = { nil }
    var openEditors: () -> [TTEditor] = { [] }
    var onCommand: ((SearchOptions, String, TTEditor) -> Void)?
    var onUnrecordableCommand: ((String) -> Void)?
    let queryField = NSTextField(), replacementField = NSTextField()
    let mode = NSPopUpButton(), scope = NSPopUpButton()
    let caseButton = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let wordButton = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    let dotButton = NSButton(checkboxWithTitle: "Dot matches newline", target: nil, action: nil)
    let wrapButton = NSButton(checkboxWithTitle: "Wrap", target: nil, action: nil)
    let status = NSTextField(labelWithString: "Search current document, selection or open documents")
    let table = ActivatingTableView()
    private var options = SearchOptions(), generation = UUID(), cancellation: TTSearchCancellation?
    private var task: Task<Void, Never>?
    private struct Buffer { var editor: TTEditor, text: String, revision: UInt, offset: Int, anchor: Int, caret: Int }
    private struct Row { var buffer: Buffer, hit: SearchHit }
    private var retirementObserver: NSObjectProtocol?
    private var rows: [Row] = []
    private var searchButtons: [NSButton] = []
    private var lastNavigation: (TTEditor, UInt, NSRange)?
    private let defaults: UserDefaults
    /// True from the moment a search is started until its result, failure or cancellation is shown.
    private(set) var isSearching = false
    /// Nil while a search is running and before the first action.
    private(set) var lastOutcome: SearchOutcome?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A panel, so the document window stays main and its menu commands keep working while
        // Find and Replace is key. Escape closes it, which cancels a running search as closing does.
        let window = ToolPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 470), styleMask: [.titled, .closable, .resizable])
        super.init(window: window)
        window.title = "Find and Replace"
        // Listed results are positions in a document, checked against its text and revision.
        // When the split pane they were found through closes, they stay usable through the
        // remaining view of that document instead of going stale with the detached view.
        retirementObserver = NotificationCenter.default.addObserver(
            forName: .TTEditorWillRetire, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let retiring = note.object as? TTEditor,
                let successor = note.userInfo?[TTEditorSuccessorKey] as? TTEditor
            else { return }
            for index in self.rows.indices where self.rows[index].buffer.editor === retiring {
                self.rows[index].buffer.editor = successor
            }
            if self.lastNavigation?.0 === retiring { self.lastNavigation = nil }
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        queryField.placeholderString = "Find"
        // Return in the query field is Find Next. Only Return sends it, never leaving the field.
        queryField.target = self
        queryField.action = #selector(findNextFromQuery(_:))
        queryField.cell?.sendsActionOnEndEditing = false
        replacementField.placeholderString = "Replace with"
        mode.addItems(withTitles: ["Normal", "Extended (\\n, \\t, \\xNN)", "Regular expression (Boost)"])
        scope.addItems(withTitles: ["Current document", "Selection", "All open documents"])
        if let data = defaults.data(forKey: "TextTank.Search.v1"),
            let saved = try? JSONDecoder().decode(SearchOptions.self, from: data)
        {
            options = saved
        }
        queryField.stringValue = options.query
        replacementField.stringValue = options.replacement
        mode.selectItem(at: options.mode.rawValue)
        caseButton.state = options.matchCase ? .on : .off
        wordButton.state = options.wholeWord ? .on : .off
        dotButton.state = options.dotMatchesNewline ? .on : .off
        wrapButton.state = options.wrap ? .on : .off
        let actions: [(String, Selector)] = [
            ("Previous", #selector(previous(_:))), ("Next", #selector(next(_:))),
            ("Find All / Count", #selector(findAll(_:))), ("Replace", #selector(replaceOne(_:))),
            ("Replace All", #selector(replaceAll(_:))), ("Bookmark Matches", #selector(bookmark(_:))),
            ("Mark Matches", #selector(mark(_:))), ("Clear Marks", #selector(clearMarks(_:)))
        ]
        searchButtons = actions.map { NSButton(title: $0.0, target: self, action: $0.1) }
        let cancel = NSButton(title: "Cancel Search", target: self, action: #selector(cancel(_:)))
        let opts = NSStackView(views: [mode, scope]),
            flags = NSStackView(views: [caseButton, wordButton, dotButton, wrapButton]),
            buttons = NSStackView(views: Array(searchButtons.prefix(5)) + [cancel])
        buttons.distribution = .fillProportionally
        let marks = NSStackView(views: Array(searchButtons.suffix(3)))
        marks.spacing = 8
        let col = NSTableColumn(identifier: .init("result"))
        col.title = "Document · UTF-16 offset · Match"
        col.width = 730
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openResult(_:))
        // Return on the selected row does what a double-click on it does.
        table.onActivate = { [weak self] row in self?.activateResult(at: row) }
        table.setAccessibilityLabel("Search results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        table.usesAlternatingRowBackgroundColors = true
        let root = NSStackView(views: [queryField, replacementField, opts, flags, buttons, marks, status, scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = root
        for v in [queryField, replacementField, opts, flags, buttons, marks, status, scroll] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        window.minSize = NSSize(width: 780, height: 390)
        window.initialFirstResponder = queryField
        WindowFrames.track(window, as: "TextTank.FindAndReplace")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    deinit { if let retirementObserver { NotificationCenter.default.removeObserver(retirementObserver) } }
    @objc func showSearch(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(queryField)
    }
    private func readOptions() -> SearchOptions {
        // NSTextFields share the window field editor. Commit it before reading
        // distinct controls, otherwise the focused replacement can become query.
        window?.makeFirstResponder(nil)
        var o = SearchOptions()
        o.query = queryField.stringValue
        o.replacement = replacementField.stringValue
        o.mode = SearchOptions.Mode(rawValue: mode.indexOfSelectedItem) ?? .normal
        o.matchCase = caseButton.state == .on
        o.wholeWord = wordButton.state == .on
        o.dotMatchesNewline = dotButton.state == .on
        o.wrap = wrapButton.state == .on
        if let data = try? JSONEncoder().encode(o) { defaults.set(data, forKey: "TextTank.Search.v1") }
        options = o
        return o
    }
    @objc func next(_ sender: Any?) { run(.next) }
    /// Return in the query field. Ignored while a search is running: the buttons are disabled
    /// then, and starting Find Next would cancel a Replace All that has not been applied yet.
    @objc func findNextFromQuery(_ sender: Any?) {
        guard !isSearching else { return }
        run(.next)
    }
    @objc func previous(_ sender: Any?) { run(.previous) }
    @objc func findAll(_ sender: Any?) { run(.all) }
    @objc func replaceAll(_ sender: Any?) { run(.replaceAll) }
    @objc func replaceOne(_ sender: Any?) { run(.replaceOne) }
    @objc func bookmark(_ sender: Any?) { run(.bookmark) }
    @objc func mark(_ sender: Any?) {
        onUnrecordableCommand?("Search highlighting is not recorded in macros yet.")
        run(.mark)
    }
    @objc func clearMarks(_ sender: Any?) {
        onUnrecordableCommand?("Clearing search highlights is not recorded in macros yet.")
        cancellation?.cancel()
        task?.cancel()
        generation = UUID()
        finish()
        let editors = scope.indexOfSelectedItem == 2 ? openEditors() : currentEditor().map { [$0] } ?? []
        var cleared = Set<ObjectIdentifier>()
        for editor in editors where editor.window != nil {
            if cleared.insert(ObjectIdentifier(editor)).inserted { editor.clearSearchHighlights() }
        }
        status.stringValue = "Cleared search highlights from \(cleared.count) document(s)."
        lastOutcome = .clearedHighlights(documents: cleared.count)
    }
    @objc func cancel(_ sender: Any?) {
        cancellation?.cancel()
        task?.cancel()
        generation = UUID()
        finish()
        status.stringValue = "Cancelled; no pending replacements applied."
        lastOutcome = .cancelled
    }
    func windowWillClose(_ notification: Notification) { cancel(nil) }
    private func finish() {
        searchButtons.forEach { $0.isEnabled = true }
        cancellation = nil
        task = nil
        isSearching = false
    }
    private enum Action { case next, previous, all, replaceAll, replaceOne, bookmark, mark }
    private func run(_ action: Action) {
        let opts = readOptions()
        guard !opts.query.isEmpty else {
            status.stringValue = "Enter a search expression."
            lastOutcome = .needsInput
            return
        }
        var editors = scope.indexOfSelectedItem == 2 ? openEditors() : currentEditor().map { [$0] } ?? []
        var identities = Set<ObjectIdentifier>()
        editors = editors.filter { identities.insert(ObjectIdentifier($0)).inserted }
        guard !editors.isEmpty else {
            status.stringValue = "Open a document first."
            lastOutcome = .needsInput
            return
        }
        if scope.indexOfSelectedItem != 0 {
            onUnrecordableCommand?("Selection and all-open search operations are not recorded in macros.")
        }
        let currentDocumentScope = scope.indexOfSelectedItem == 0, selectionScope = scope.indexOfSelectedItem == 1
        var buffers: [Buffer] = []
        for e in editors {
            let text = e.text
            if scope.indexOfSelectedItem == 1 {
                guard e.selectionCount == 1,
                    let r = SearchCore.utf16Range(
                        NSRange(location: e.selectionStart, length: e.selectionEnd - e.selectionStart), in: text),
                    r.length > 0
                else {
                    status.stringValue = "Select one nonempty range first."
                    lastOutcome = .needsInput
                    return
                }
                buffers.append(
                    Buffer(
                        editor: e, text: text, revision: e.revision, offset: r.location, anchor: e.selectionAnchor,
                        caret: e.selectionCaret))
            } else {
                buffers.append(
                    Buffer(
                        editor: e, text: text, revision: e.revision, offset: 0, anchor: e.selectionAnchor,
                        caret: e.selectionCaret))
            }
        }
        let selectionRanges = buffers.map { b -> NSRange in
            if scope.indexOfSelectedItem == 1 {
                return SearchCore.utf16Range(
                    NSRange(location: b.editor.selectionStart, length: b.editor.selectionEnd - b.editor.selectionStart),
                    in: b.text)!
            }
            return NSRange(location: 0, length: (b.text as NSString).length)
        }
        cancellation?.cancel()
        task?.cancel()
        let token = UUID()
        generation = token
        let flag = TTSearchCancellation()
        cancellation = flag
        searchButtons.forEach { $0.isEnabled = false }
        status.stringValue = "Searching snapshots…"
        isSearching = true
        lastOutcome = nil
        rows = []
        table.reloadData()
        let bookmarkSnapshots = buffers.map { ($0.text, $0.offset) }
        let needsBookmarks = action == .bookmark
        let snapshots = zip(buffers, selectionRanges).map { ($0.0.text as NSString).substring(with: $0.1) }
        task = Task { @MainActor [weak self] in
            do {
                let computed = try await Task.detached(priority: .userInitiated) {
                    let reports = try snapshots.map { try SearchCore.search($0, options: opts, cancellation: flag) }
                    let lines =
                        needsBookmarks
                        ? try zip(bookmarkSnapshots, reports).map { snapshot, report in
                            try SearchCore.bookmarkLines(
                                in: snapshot.0, locations: report.hits.map { $0.range.location + snapshot.1 },
                                cancellation: flag)
                        } : []
                    return (reports, lines)
                }.value
                let reports = computed.0
                guard let self, self.generation == token, !flag.cancelled else { return }
                defer { self.finish() }
                self.rows = zip(buffers, reports).flatMap { b, r in
                    r.hits.map {
                        Row(
                            buffer: b,
                            hit: SearchHit(
                                range: NSRange(location: $0.range.location + b.offset, length: $0.range.length),
                                replacement: $0.replacement))
                    }
                }
                self.table.reloadData()
                let truncated = reports.contains { $0.truncated }
                self.status.stringValue =
                    "\(self.rows.count) matches in \(buffers.count) document(s)"
                    + (truncated ? " · result limit reached" : "")
                self.lastOutcome = .found(matches: self.rows.count, documents: buffers.count, truncated: truncated)
                switch action {
                case .all: break
                case .next, .previous:
                    // G372: the editor stayed editable while the search ran. A result for text that
                    // has since changed, or for an editor that is no longer current, moves nothing and
                    // a recording that already holds the later edits is discarded.
                    if currentDocumentScope, let b = buffers.first,
                        !(b.editor.window != nil && b.editor.revision == b.revision
                            && self.currentEditor() === b.editor)
                    {
                        self.status.stringValue = "Result is stale; search again. Selection unchanged."
                        self.lastOutcome = .staleResult
                        self.onUnrecordableCommand?(
                            "The document changed while the search was running; the search step was not recorded.")
                        return
                    }
                    // A miss is not recorded: playback stops on a recorded search that finds nothing.
                    let moved = self.navigate(backwards: action == .previous, wrap: opts.wrap)
                    if moved, currentDocumentScope, let editor = buffers.first?.editor {
                        self.onCommand?(opts, action == .previous ? "previous" : "next", editor)
                    }
                case .replaceAll, .replaceOne:
                    guard !truncated else {
                        self.status.stringValue =
                            "Result limit reached; replacements were not applied. Narrow the scope."
                        self.lastOutcome = .limitReached
                        return
                    }
                    var changed = 0, stale = 0
                    for buffer in buffers {
                        let hits = self.rows.filter { $0.buffer.editor === buffer.editor }.map { $0.hit }
                        let chosen =
                            action == .replaceOne
                            ? SearchCore.hits(
                                hits,
                                selectedBy: NSRange(
                                    location: min(buffer.anchor, buffer.caret),
                                    length: abs(buffer.anchor - buffer.caret)), in: buffer.text) : hits
                        if chosen.isEmpty { continue }
                        if (selectionScope || action == .replaceOne)
                            && (buffer.editor.selectionAnchor != buffer.anchor
                                || buffer.editor.selectionCaret != buffer.caret)
                        {
                            stale += 1
                            continue
                        }
                        if Self.apply(chosen, text: buffer.text, revision: buffer.revision, to: buffer.editor) {
                            changed += chosen.count
                        } else {
                            stale += 1
                        }
                    }
                    self.status.stringValue =
                        "Replaced \(changed) matches; \(stale) changed documents skipped. Undo is per document."
                    self.lastOutcome = .replaced(changed: changed, stale: stale)
                    if changed > 0, stale == 0, currentDocumentScope, let editor = buffers.first?.editor {
                        self.onCommand?(opts, action == .replaceOne ? "replaceOne" : "replaceAll", editor)
                    }
                case .mark:
                    guard !truncated else {
                        self.status.stringValue =
                            "Result limit reached; previous highlights were preserved. Narrow the scope."
                        self.lastOutcome = .limitReached
                        return
                    }
                    var marked = 0, stale = 0, zeroWidth = 0
                    for b in buffers {
                        let hits = self.rows.filter { $0.buffer.editor === b.editor }.map { $0.hit }
                        if selectionScope
                            && (b.editor.selectionAnchor != b.anchor || b.editor.selectionCaret != b.caret)
                        {
                            stale += 1
                            continue
                        }
                        if Self.highlight(hits, text: b.text, revision: b.revision, in: b.editor) {
                            marked += hits.filter { $0.range.length > 0 }.count
                            zeroWidth += hits.filter { $0.range.length == 0 }.count
                        } else {
                            stale += 1
                        }
                    }
                    self.status.stringValue =
                        "Marked \(marked) matches; \(stale) changed/closed documents skipped."
                        + (zeroWidth > 0 ? " \(zeroWidth) zero-width matches have no visible span." : "")
                    self.lastOutcome = .marked(matches: marked, stale: stale, zeroWidth: zeroWidth)
                case .bookmark:
                    var stale = 0
                    guard !truncated else {
                        self.status.stringValue = "Result limit reached; bookmarks were preserved. Narrow the scope."
                        self.lastOutcome = .limitReached
                        return
                    }
                    for (index, b) in buffers.enumerated() {
                        guard b.editor.window != nil, b.editor.revision == b.revision, b.editor.text == b.text,
                            !selectionScope
                                || (b.editor.selectionAnchor == b.anchor && b.editor.selectionCaret == b.caret)
                        else {
                            stale += 1
                            continue
                        }
                        var lines = Set(b.editor.bookmarkLines.map { $0.intValue })
                        lines.formUnion(computed.1[index])
                        _ = b.editor.setBookmarks(lines.sorted().map { NSNumber(value: $0) })
                    }
                    self.status.stringValue = "Bookmarked matching lines; \(stale) changed documents skipped."
                    self.lastOutcome = .bookmarked(stale: stale)
                }
            } catch {
                guard let self, self.generation == token else { return }
                self.status.stringValue = error.localizedDescription
                self.lastOutcome = .failed(error.localizedDescription)
                self.finish()
            }
        }
    }
    /// The budget of one recorded search step: the interactive budget, from the one constant.
    static let recordedStepTimeLimit = SearchCore.defaultTimeLimit
    /// Macro playback is bounded and has no disk or connector side effects: each step may search
    /// for at most `timeLimit` seconds, synchronously, and a step that runs out of time throws
    /// before any edit. Next and Previous throw when they do not land on a match, so the steps
    /// after them never run at a stale caret; Replace All with no match is a deliberate no-op.
    func playRecorded(
        options: SearchOptions, action: String, on editor: TTEditor,
        timeLimit: TimeInterval = SearchController.recordedStepTimeLimit
    ) throws {
        let text = editor.text, revision = editor.revision
        let report = try SearchCore.search(text, options: options, timeLimit: timeLimit)
        guard !report.truncated else {
            throw NSError(
                domain: "TextTank.Search", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Macro search reached the result limit; no edits were applied."])
        }
        guard
            let selection = SearchCore.utf16Range(
                NSRange(location: editor.selectionStart, length: editor.selectionEnd - editor.selectionStart), in: text)
        else { throw Self.recordedSearchStopped("the selection is not on a character boundary") }
        if action == "replaceAll" || action == "replaceOne" {
            let hits = action == "replaceAll" ? report.hits : report.hits.filter { $0.range == selection }
            if !hits.isEmpty && !Self.apply(hits, text: text, revision: revision, to: editor) {
                throw NSError(
                    domain: "TextTank.Search", code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Macro replacement encountered a stale buffer or unsupported multiple selection."
                    ])
            }
        } else if action == "next" || action == "previous" {
            let backwards = action == "previous"
            let continuing = lastNavigation.map { $0.0 === editor && $0.1 == revision && $0.2 == selection } ?? false
            let candidates = report.hits.filter { h in
                backwards
                    ? NSMaxRange(h.range) <= selection.location && !(continuing && h.range == selection)
                    : h.range.location >= NSMaxRange(selection) && !(continuing && h.range == selection)
            }
            let hit =
                (backwards ? candidates.last : candidates.first)
                ?? (options.wrap ? (backwards ? report.hits.last : report.hits.first) : nil)
            guard let hit else { throw Self.recordedSearchStopped("recorded search did not match") }
            guard let bytes = SearchCore.byteRange(hit.range, in: text),
                editor.setSelectionAnchor(bytes.location, caret: NSMaxRange(bytes))
            else { throw Self.recordedSearchStopped("the match could not be selected") }
            lastNavigation = (editor, revision, hit.range)
        } else {
            throw NSError(
                domain: "TextTank.Search", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Unrecognized recorded search action."])
        }
    }
    private static func recordedSearchStopped(_ reason: String) -> NSError {
        NSError(
            domain: "TextTank.Search", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "Macro stopped: \(reason). Prior edits remain undoable."])
    }
    @discardableResult static func highlight(_ hits: [SearchHit], text: String, revision: UInt, in editor: TTEditor)
        -> Bool
    {
        guard editor.window != nil, editor.revision == revision, editor.text == text,
            let ranges = SearchCore.byteRanges(hits.map(\.range), in: text)
        else { return false }
        return editor.setSearchHighlights(ranges.filter { $0.length > 0 }.map { NSValue(range: $0) })
    }
    @discardableResult static func apply(_ hits: [SearchHit], text: String, revision: UInt, to editor: TTEditor) -> Bool
    {
        guard editor.window != nil, !editor.readOnly, editor.revision == revision, editor.text == text,
            editor.selectionCount == 1, !hits.isEmpty
        else { return false }
        guard let ranges = SearchCore.byteRanges(hits.map(\.range), in: text) else { return false }
        // The matches are replaced as byte ranges, validated together and applied as one undo step.
        // The selection is not the edit cursor, so Undo returns to the selection the command began with.
        let anchor = editor.selectionAnchor, caret = editor.selectionCaret
        let edits = zip(hits, ranges).map { hit, range in
            [
                "start": NSNumber(value: range.location), "end": NSNumber(value: NSMaxRange(range)),
                "text": hit.replacement
            ] as [String: Any]
        }
        guard editor.applyEdits(edits, expectedRevision: revision, expectedLength: text.utf8.count) else {
            return false
        }
        // Carry the selection through the replacements: its start stays before a replacement that
        // begins at or covers it, its end stays after one that ends at or covers it.
        func carried(_ position: Int, upper: Bool) -> Int {
            var delta = 0
            for (hit, range) in zip(hits, ranges) {
                let start = range.location, end = NSMaxRange(range), length = hit.replacement.utf8.count
                if position < start || (position == start && (!upper || end > start)) { break }
                if position < end { return start + delta + (upper ? length : 0) }
                delta += length - range.length
            }
            return position + delta
        }
        let low = carried(min(anchor, caret), upper: false)
        let high = anchor == caret ? low : carried(max(anchor, caret), upper: true)
        _ = editor.setSelectionAnchor(anchor <= caret ? low : high, caret: anchor <= caret ? high : low)
        return true
    }
    /// True only when the selection moved to a match.
    private func navigate(backwards: Bool, wrap: Bool) -> Bool {
        guard let e = currentEditor(),
            let selection = SearchCore.utf16Range(
                NSRange(location: e.selectionStart, length: e.selectionEnd - e.selectionStart), in: e.text)
        else { return false }
        let available = rows.filter { $0.buffer.editor === e }
        let continuing = lastNavigation.map { $0.0 === e && $0.1 == e.revision && $0.2 == selection } ?? false
        let candidates = available.filter { r in
            backwards
                ? NSMaxRange(r.hit.range) <= selection.location && !(continuing && r.hit.range == selection)
                : r.hit.range.location >= NSMaxRange(selection) && !(continuing && r.hit.range == selection)
        }
        // Find Next stays in the Find window: these rows belong to the current editor, whose
        // window is already showing, so the document window is not made key over this one.
        if let row = backwards ? candidates.last : candidates.first {
            return select(row, focusEditor: false)
        } else if wrap, let row = backwards ? available.last : available.first {
            return select(row, focusEditor: false)
        }
        status.stringValue = "No further matches."
        lastOutcome = .noFurtherMatches
        return false
    }
    /// `focusEditor` brings the result's document window forward and puts the keyboard in its
    /// editor: opening a listed result does that, and it is what switches the document tab for a
    /// result in another document. Without it only the selection moves, unless the document is
    /// not showing at all.
    @discardableResult private func select(_ row: Row, focusEditor: Bool) -> Bool {
        let b = row.buffer
        guard b.editor.window != nil, b.editor.revision == b.revision, b.editor.text == b.text,
            let range = SearchCore.byteRange(row.hit.range, in: b.text),
            b.editor.setSelectionAnchor(range.location, caret: NSMaxRange(range))
        else {
            status.stringValue = "Result is stale; search again. Selection unchanged."
            lastOutcome = .staleResult
            return false
        }
        lastNavigation = (b.editor, b.revision, row.hit.range)
        if focusEditor || b.editor.window?.isVisible == false {
            b.editor.window?.makeKeyAndOrderFront(nil)
            b.editor.window?.makeFirstResponder(b.editor)
        }
        return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard rows.indices.contains(row) else { return nil }
        let r = rows[row]
        let match = (r.buffer.text as NSString).substring(with: r.hit.range)
        return
            "\(r.buffer.editor.window?.title ?? "Document") · \(r.hit.range.location) · \(String(match.prefix(160)).replacingOccurrences(of:"\n",with:" ↵ "))"
    }
    /// A double-click. `clickedRow` is -1 for the header and the empty area below the rows,
    /// which therefore do nothing even while a row is selected.
    @objc func openResult(_ sender: Any?) { activateResult(at: table.clickedRow) }
    /// What a double-click or Return on a listed result does: selects that match if the result
    /// is still current, and brings its document forward. The jump moves the caret with no
    /// recordable step (F277), so a jump that happened is reported to the macro recording.
    @discardableResult func activateResult(at row: Int) -> Bool {
        guard rows.indices.contains(row), select(rows[row], focusEditor: true) else { return false }
        onUnrecordableCommand?("Opening a search result is not recorded in macros yet.")
        return true
    }
    func open(row: Int) {
        activateResult(at: row)
    }
}
