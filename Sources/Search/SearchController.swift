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
    /// Replace found no selected match and selected the next one instead (current document).
    case selectedNextMatch
    /// Replace found no selected match in Selection or All open documents scope.
    case noMatchSelected
}
/// What a replacement did to one document; nothing is changed unless it is `applied`.
enum ReplaceOutcome: Equatable { case applied(Int), readOnly, multipleSelections, closed, stale }
/// Documents the last Replace or Replace All left untouched, by reason.
struct ReplaceSkips: Equatable {
    var readOnly = 0, multipleSelections = 0, closed = 0, stale = 0
    var total: Int { readOnly + multipleSelections + closed + stale }
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
    let table = NSTableView()
    private var options = SearchOptions(), generation = UUID(), cancellation: TTSearchCancellation?
    private var task: Task<Void, Never>?
    /// One searched document: the editor is held weakly, so results never keep a closed document
    /// alive, and `text` is the one snapshot shared by all of its rows (F122). `range` is the
    /// UTF-16 scope in Selection scope and nil for the whole text.
    private struct Buffer {
        weak var editor: TTEditor?
        let text: String, revision: UInt, anchor: Int, caret: Int, range: NSRange?
    }
    private struct Row { let buffer: Int, hit: SearchHit }
    private struct Navigation {
        weak var editor: TTEditor?
        let revision: UInt, range: NSRange
        /// The application's current editor when the match was selected.
        weak var from: TTEditor?
    }
    /// What the held rows are the result of. Revisions make it the staleness authority.
    private struct ResultKey: Equatable {
        struct Document: Equatable {
            let editor: ObjectIdentifier?, revision: UInt, range: NSRange?
        }
        let options: SearchOptions, scope: Int, documents: [Document]
    }
    private var resultBuffers: [Buffer] = [], rows: [Row] = []
    private var resultKey: ResultKey?, resultTruncated = false
    private var searchButtons: [NSButton] = []
    private var lastNavigation: Navigation?, navigationScope: Navigation?
    /// Set while the match after a single Replace is being looked for: what that Replace reported.
    private var appliedReplace: (status: String, outcome: SearchOutcome?)?
    /// Called when Find Next or Find Previous selects nothing; the default is the system alert sound.
    var onFailureSignal: () -> Void = { NSSound.beep() }
    /// How many Next and Previous presses walked the held results without searching again.
    private(set) var reusedResults = 0
    /// Why the last Replace or Replace All skipped documents; `lastOutcome` carries their total.
    private(set) var lastReplaceSkips = ReplaceSkips()
    private let defaults: UserDefaults
    /// True from the moment a search is started until its result, failure or cancellation is shown.
    private(set) var isSearching = false
    /// Nil while a search is running and before the first action.
    private(set) var lastOutcome: SearchOutcome?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 470), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Find and Replace"
        window.isReleasedWhenClosed = false
        window.delegate = self
        queryField.placeholderString = "Find"
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
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
        let applied = appliedReplace
        finish()
        if let applied {
            // The replacement was made before the cancel; only the move to the next match was not.
            status.stringValue = applied.status + " Cancelled before the next match was selected."
            lastOutcome = applied.outcome
            return
        }
        status.stringValue = "Cancelled; no pending replacements applied."
        lastOutcome = .cancelled
    }
    func windowWillClose(_ notification: Notification) {
        cancel(nil)
        // F122: a closed Find window keeps no text snapshot of any document.
        rows = []
        resultBuffers = []
        resultKey = nil
        table.reloadData()
    }
    private func finish() {
        searchButtons.forEach { $0.isEnabled = true }
        cancellation = nil
        task = nil
        isSearching = false
        appliedReplace = nil
    }
    /// Every exit that selects and changes nothing reports here. Find Next and Find Previous also
    /// work from the menu while this window is closed, so their failures are audible too (F308).
    private func fail(_ message: String, _ outcome: SearchOutcome, audible: Bool) {
        status.stringValue = message
        lastOutcome = outcome
        if audible { onFailureSignal() }
    }
    private enum Action { case next, previous, all, replaceAll, replaceOne, bookmark, mark }
    private func run(_ action: Action) {
        let opts = readOptions(), navigating = action == .next || action == .previous
        guard !opts.query.isEmpty else {
            fail("Enter a search expression.", .needsInput, audible: navigating)
            return
        }
        let scopeIndex = scope.indexOfSelectedItem
        // Captured before the search: focus may have moved by the time the results arrive (F36).
        let current = currentEditor()
        var editors = scopeIndex == 2 ? openEditors() : current.map { [$0] } ?? []
        var identities = Set<ObjectIdentifier>()
        editors = editors.filter { identities.insert(ObjectIdentifier($0)).inserted }
        guard !editors.isEmpty else {
            fail("Open a document first.", .needsInput, audible: navigating)
            return
        }
        if scopeIndex != 0 {
            onUnrecordableCommand?("Selection and all-open search operations are not recorded in macros.")
        }
        let currentDocumentScope = scopeIndex == 0, selectionScope = scopeIndex == 1
        // A scope kept for Selection scope ends with any action in another scope: navigation there
        // would otherwise leave a selection that reads as a continuation inside the old scope.
        if !selectionScope { navigationScope = nil }
        var buffers: [Buffer] = [], freshScope = false
        for e in editors {
            let revision = e.revision
            // A snapshot already held for this revision is this text; do not copy the document again (F223).
            let text = resultBuffers.first { $0.editor === e && $0.revision == revision }?.text ?? e.text
            var range: NSRange?
            if selectionScope {
                guard e.selectionCount == 1,
                    let live = SearchCore.utf16Range(
                        NSRange(location: e.selectionStart, length: e.selectionEnd - e.selectionStart), in: text)
                else {
                    fail("Select one nonempty range first.", .needsInput, audible: navigating)
                    return
                }
                // F35: once Next or Previous has moved the selection onto a hit, the scope is the
                // range remembered from the first press, until an edit or a manual selection change.
                if navigating, let last = lastNavigation, last.editor === e, last.revision == revision,
                    last.range == live, let kept = navigationScope, kept.editor === e, kept.revision == revision
                {
                    range = kept.range
                } else {
                    guard live.length > 0 else {
                        fail("Select one nonempty range first.", .needsInput, audible: navigating)
                        return
                    }
                    range = live
                    if navigating {
                        navigationScope = Navigation(editor: e, revision: revision, range: live, from: nil)
                        freshScope = true
                    }
                }
            }
            buffers.append(
                Buffer(
                    editor: e, text: text, revision: revision, anchor: e.selectionAnchor, caret: e.selectionCaret,
                    range: range))
        }
        // F36: the document a single Replace may edit. In All open documents scope that is the
        // document Next last moved to while its match is still selected, by the same rule as
        // navigation, because the application's current editor can lag behind that move.
        let active =
            scopeIndex == 2 ? allOpenOrigin(in: buffers, current: current).flatMap { buffers[$0].editor } : current
        var keyOptions = opts
        keyOptions.wrap = false
        let key = ResultKey(
            options: keyOptions, scope: scopeIndex,
            documents: buffers.map { b in
                ResultKey.Document(editor: b.editor.map { ObjectIdentifier($0) }, revision: b.revision, range: b.range)
            })
        // F223: the same editors at the same revisions with the same options have the same hits,
        // so Next and Previous walk the rows already held instead of searching again.
        if navigating, key == resultKey, resultBuffers.allSatisfy({ $0.editor != nil }) {
            status.stringValue = Self.foundStatus(rows.count, resultBuffers.count, resultTruncated)
            lastOutcome = .found(matches: rows.count, documents: resultBuffers.count, truncated: resultTruncated)
            reusedResults += 1
            let moved = navigate(
                backwards: action == .previous, wrap: opts.wrap, freshScope: freshScope, allOpen: scopeIndex == 2,
                audible: true)
            if moved, currentDocumentScope, let editor = resultBuffers.first?.editor {
                onCommand?(opts, action == .previous ? "previous" : "next", editor)
            }
            return
        }
        cancellation?.cancel()
        task?.cancel()
        let token = UUID()
        generation = token
        let flag = TTSearchCancellation()
        cancellation = flag
        searchButtons.forEach { $0.isEnabled = false }
        appliedReplace = nil
        status.stringValue = "Searching snapshots…"
        isSearching = true
        lastOutcome = nil
        rows = []
        resultBuffers = []
        resultKey = nil
        table.reloadData()
        let needsBookmarks = action == .bookmark
        // Selection scope searches a range of the whole text, not an extracted substring, so word
        // boundaries, anchors and lookbehind see the document around the selection (F37). Hits are
        // already at document offsets.
        let snapshots = buffers.map {
            ($0.text, $0.range ?? NSRange(location: 0, length: ($0.text as NSString).length))
        }
        task = Task { @MainActor [weak self] in
            do {
                let computed = try await Task.detached(priority: .userInitiated) {
                    let reports = try snapshots.map {
                        try SearchCore.search($0.0, options: opts, range: $0.1, cancellation: flag)
                    }
                    let lines =
                        needsBookmarks
                        ? try zip(snapshots, reports).map { snapshot, report in
                            try SearchCore.bookmarkLines(
                                in: snapshot.0, locations: report.hits.map { $0.range.location }, cancellation: flag)
                        } : []
                    return (reports, lines)
                }.value
                guard let self, self.generation == token, !flag.cancelled else { return }
                let replaced = self.complete(
                    action, options: opts, key: key, buffers: buffers, reports: computed.0, bookmarkLines: computed.1,
                    scopeIndex: scopeIndex, active: active, freshScope: freshScope)
                if let editor = replaced {
                    // F45: a single Replace then moves to the next match. The text has changed, so
                    // that needs a search of the new text; it is recorded as an ordinary Next.
                    let text = editor.text, revision = editor.revision
                    self.appliedReplace = (self.status.stringValue, self.lastOutcome)
                    let report = try? await Task.detached(priority: .userInitiated) {
                        try SearchCore.search(text, options: opts, cancellation: flag)
                    }.value
                    guard self.generation == token, !flag.cancelled else { return }
                    if let report {
                        self.advance(
                            in: editor, text: text, revision: revision, report: report, options: opts, key: key)
                    }
                }
                self.finish()
            } catch {
                guard let self, self.generation == token else { return }
                self.fail(error.localizedDescription, .failed(error.localizedDescription), audible: navigating)
                self.finish()
            }
        }
    }
    private static func foundStatus(_ matches: Int, _ documents: Int, _ truncated: Bool) -> String {
        "\(matches) matches in \(documents) document(s)" + (truncated ? " · result limit reached" : "")
    }
    private static func replacedStatus(changed: Int, skips: ReplaceSkips) -> String {
        var kinds: [String] = []
        if skips.readOnly > 0 { kinds.append("\(skips.readOnly) read-only") }
        if skips.multipleSelections > 0 { kinds.append("\(skips.multipleSelections) with multiple selections") }
        if skips.closed > 0 { kinds.append("\(skips.closed) closed") }
        guard !kinds.isEmpty else {
            return "Replaced \(changed) matches; \(skips.stale) changed documents skipped. Undo is per document."
        }
        if skips.stale > 0 { kinds.append("\(skips.stale) changed") }
        return "Replaced \(changed) matches; documents skipped: \(kinds.joined(separator: ", ")). Undo is per document."
    }
    /// Shows the results of a finished search and performs `action` on them. Returns the editor
    /// in which a single Replace was applied when the next match should then be selected.
    private func complete(
        _ action: Action, options opts: SearchOptions, key: ResultKey, buffers: [Buffer], reports: [SearchReport],
        bookmarkLines: [[Int]], scopeIndex: Int, active: TTEditor?, freshScope: Bool
    ) -> TTEditor? {
        let currentDocumentScope = scopeIndex == 0, selectionScope = scopeIndex == 1
        resultBuffers = buffers
        rows = reports.enumerated().flatMap { index, report in report.hits.map { Row(buffer: index, hit: $0) } }
        let truncated = reports.contains { $0.truncated }
        resultKey = key
        resultTruncated = truncated
        table.reloadData()
        status.stringValue = Self.foundStatus(rows.count, buffers.count, truncated)
        lastOutcome = .found(matches: rows.count, documents: buffers.count, truncated: truncated)
        switch action {
        case .all: break
        case .next, .previous:
            // A miss is not recorded: playback stops on a recorded search that finds nothing.
            let moved = navigate(
                backwards: action == .previous, wrap: opts.wrap, freshScope: freshScope, allOpen: scopeIndex == 2,
                audible: true)
            if moved, currentDocumentScope, let editor = buffers.first?.editor {
                onCommand?(opts, action == .previous ? "previous" : "next", editor)
            }
        case .replaceAll, .replaceOne:
            guard !truncated else {
                fail(
                    "Result limit reached; replacements were not applied. Narrow the scope.", .limitReached,
                    audible: false)
                return nil
            }
            var changed = 0, skips = ReplaceSkips()
            for (index, buffer) in buffers.enumerated() {
                // F36: a single Replace edits the document it was pressed in, never a background one.
                if action == .replaceOne && (active == nil || buffer.editor !== active) { continue }
                let hits = reports[index].hits
                let chosen =
                    action == .replaceOne
                    ? SearchCore.hits(
                        hits,
                        selectedBy: NSRange(
                            location: min(buffer.anchor, buffer.caret),
                            length: abs(buffer.anchor - buffer.caret)), in: buffer.text) : hits
                if chosen.isEmpty { continue }
                guard let editor = buffer.editor else {
                    skips.closed += 1
                    continue
                }
                if (selectionScope || action == .replaceOne)
                    && (editor.selectionAnchor != buffer.anchor || editor.selectionCaret != buffer.caret)
                {
                    skips.stale += 1
                    continue
                }
                switch Self.replace(chosen, text: buffer.text, revision: buffer.revision, in: editor) {
                case .applied(let count): changed += count
                case .readOnly: skips.readOnly += 1
                case .multipleSelections: skips.multipleSelections += 1
                case .closed: skips.closed += 1
                case .stale: skips.stale += 1
                }
            }
            lastReplaceSkips = skips
            if action == .replaceOne, changed == 0, skips.total == 0 {
                // F45: nothing is selected that is a match. In the current document Replace finds
                // the next one, exactly as Next does; the edit itself still needs a selected match.
                guard currentDocumentScope else {
                    fail("No match is selected; use Next first.", .noMatchSelected, audible: false)
                    return nil
                }
                if navigate(backwards: false, wrap: opts.wrap, freshScope: false, allOpen: false, audible: false),
                    let editor = buffers.first?.editor
                {
                    status.stringValue = "Selected the next match; press Replace again to replace it."
                    lastOutcome = .selectedNextMatch
                    onCommand?(opts, "next", editor)
                }
                return nil
            }
            status.stringValue = Self.replacedStatus(changed: changed, skips: skips)
            lastOutcome = .replaced(changed: changed, stale: skips.total)
            if changed > 0, skips.total == 0, currentDocumentScope, let editor = buffers.first?.editor {
                onCommand?(opts, action == .replaceOne ? "replaceOne" : "replaceAll", editor)
                if action == .replaceOne { return editor }
            }
        case .mark:
            guard !truncated else {
                fail(
                    "Result limit reached; previous highlights were preserved. Narrow the scope.", .limitReached,
                    audible: false)
                return nil
            }
            var marked = 0, stale = 0, zeroWidth = 0
            for (index, b) in buffers.enumerated() {
                let hits = reports[index].hits
                guard let editor = b.editor,
                    !selectionScope || (editor.selectionAnchor == b.anchor && editor.selectionCaret == b.caret),
                    Self.highlight(hits, text: b.text, revision: b.revision, in: editor)
                else {
                    stale += 1
                    continue
                }
                marked += hits.filter { $0.range.length > 0 }.count
                zeroWidth += hits.filter { $0.range.length == 0 }.count
            }
            status.stringValue =
                "Marked \(marked) matches; \(stale) changed/closed documents skipped."
                + (zeroWidth > 0 ? " \(zeroWidth) zero-width matches have no visible span." : "")
            lastOutcome = .marked(matches: marked, stale: stale, zeroWidth: zeroWidth)
        case .bookmark:
            var stale = 0
            guard !truncated else {
                fail("Result limit reached; bookmarks were preserved. Narrow the scope.", .limitReached, audible: false)
                return nil
            }
            for (index, b) in buffers.enumerated() {
                guard let editor = b.editor, editor.window != nil, editor.revision == b.revision,
                    !selectionScope || (editor.selectionAnchor == b.anchor && editor.selectionCaret == b.caret)
                else {
                    stale += 1
                    continue
                }
                var lines = Set(editor.bookmarkLines.map { $0.intValue })
                lines.formUnion(bookmarkLines[index])
                _ = editor.setBookmarks(lines.sorted().map { NSNumber(value: $0) })
            }
            status.stringValue = "Bookmarked matching lines; \(stale) changed documents skipped."
            lastOutcome = .bookmarked(stale: stale)
        }
        return nil
    }
    /// After a single Replace: the hits of the new text become the results, and the next one is
    /// selected. The status keeps the replacement count and says where the selection went.
    private func advance(
        in editor: TTEditor, text: String, revision: UInt, report: SearchReport, options opts: SearchOptions,
        key: ResultKey
    ) {
        let replaced = status.stringValue, outcome = lastOutcome
        resultBuffers = [
            Buffer(
                editor: editor, text: text, revision: revision, anchor: editor.selectionAnchor,
                caret: editor.selectionCaret, range: nil)
        ]
        rows = report.hits.map { Row(buffer: 0, hit: $0) }
        resultKey = ResultKey(
            options: key.options, scope: key.scope,
            documents: [ResultKey.Document(editor: ObjectIdentifier(editor), revision: revision, range: nil)])
        resultTruncated = report.truncated
        table.reloadData()
        let moved = navigate(backwards: false, wrap: opts.wrap, freshScope: false, allOpen: false, audible: false)
        let changedMeanwhile = lastOutcome == .staleResult
        status.stringValue =
            replaced
            + (moved
                ? " Selected the next match."
                : changedMeanwhile
                    ? " The document changed before the next match was selected." : " No further matches.")
        lastOutcome = outcome
        if moved { onCommand?(opts, "next", editor) }
    }
    /// Macro playback is bounded and has no disk or connector side effects. Next and Previous throw
    /// when they do not land on a match, so the steps after them never run at a stale caret;
    /// Replace All with no match is a deliberate no-op. Replace stays strict here: it replaces only
    /// a selected match and never moves on, because saved macros carry their own Next steps.
    func playRecorded(options: SearchOptions, action: String, on editor: TTEditor) throws {
        let text = editor.text, revision = editor.revision
        let report = try SearchCore.search(text, options: options, timeLimit: 0.1)
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
            if !hits.isEmpty {
                let reason: String
                switch Self.replace(hits, text: text, revision: revision, in: editor) {
                case .applied: return
                case .readOnly: reason = "the document is read-only"
                case .multipleSelections: reason = "multiple selections are not supported"
                case .closed: reason = "the document is not in a window"
                case .stale: reason = "the document changed during the step"
                }
                throw NSError(
                    domain: "TextTank.Search", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Macro replacement was not applied: \(reason)."])
            }
        } else if action == "next" || action == "previous" {
            let backwards = action == "previous"
            let continuing =
                lastNavigation.map { $0.editor === editor && $0.revision == revision && $0.range == selection } ?? false
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
            lastNavigation = Navigation(editor: editor, revision: revision, range: hit.range, from: nil)
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
    /// `revision` is the staleness authority: every insert and delete moves it, in every view of a
    /// shared document, so an equal revision means `text` is still the editor's text (F223).
    @discardableResult static func highlight(_ hits: [SearchHit], text: String, revision: UInt, in editor: TTEditor)
        -> Bool
    {
        guard editor.window != nil, editor.revision == revision,
            let ranges = SearchCore.byteRanges(hits.map(\.range), in: text)
        else { return false }
        return editor.setSearchHighlights(ranges.filter { $0.length > 0 }.map { NSValue(range: $0) })
    }
    @discardableResult static func apply(_ hits: [SearchHit], text: String, revision: UInt, to editor: TTEditor) -> Bool
    {
        if case .applied(let count) = replace(hits, text: text, revision: revision, in: editor) { return count > 0 }
        return false
    }
    /// Replaces `hits` (ascending, found in `text` at `revision`) in one bridge call under one undo
    /// action, or changes nothing and says why. The caret ends just after the first replacement.
    static func replace(_ hits: [SearchHit], text: String, revision: UInt, in editor: TTEditor) -> ReplaceOutcome {
        guard editor.window != nil else { return .closed }
        guard !editor.readOnly else { return .readOnly }
        guard editor.revision == revision else { return .stale }
        guard editor.selectionCount == 1 else { return .multipleSelections }
        guard !hits.isEmpty else { return .applied(0) }
        guard let ranges = SearchCore.byteRanges(hits.map(\.range), in: text),
            editor.replaceRanges(
                ranges.map { NSValue(range: $0) }, withTexts: hits.map(\.replacement), expectedRevision: revision)
        else { return .stale }
        return .applied(hits.count)
    }
    /// All open documents: the buffer of the document the person is in, for Next, Previous and
    /// single Replace alike. After a move into another document the application's idea of the
    /// current editor can lag (F48), so the document last navigated to stays the answer while its
    /// selection is still that match and the person has not moved elsewhere. Moving elsewhere
    /// shows as a different listed current editor, or, since only the selected tab's window is
    /// visible, as the editor navigated from being on screen while the one navigated to is not.
    private func allOpenOrigin(in buffers: [Buffer], current: TTEditor?) -> Int? {
        if let last = lastNavigation, let editor = last.editor, editor.revision == last.revision,
            current == nil || current === editor || !buffers.contains(where: { $0.editor === current })
                || (current === last.from
                    && !(current?.window?.isVisible == true && editor.window?.isVisible != true)),
            let index = buffers.firstIndex(where: { $0.editor === editor && $0.revision == last.revision }),
            SearchCore.utf16Range(
                NSRange(location: editor.selectionStart, length: editor.selectionEnd - editor.selectionStart),
                in: buffers[index].text) == last.range
        {
            return index
        }
        guard let current else { return nil }
        return buffers.firstIndex { $0.editor === current }
    }
    /// True only when the selection moved to a match. `freshScope` is the first press in Selection
    /// scope: the selection is then the scope itself, not a place to continue from.
    private func navigate(backwards: Bool, wrap: Bool, freshScope: Bool, allOpen: Bool, audible: Bool) -> Bool {
        let buffers = resultBuffers
        var origin: Int?
        if allOpen {
            origin = allOpenOrigin(in: buffers, current: currentEditor())
        } else if !buffers.isEmpty {
            origin = 0
        }
        var available: [Row] = [], row: Row?
        if let origin {
            let b = buffers[origin]
            guard let e = b.editor, e.revision == b.revision,
                let selection = SearchCore.utf16Range(
                    NSRange(location: e.selectionStart, length: e.selectionEnd - e.selectionStart), in: b.text)
            else {
                fail("Result is stale; search again. Selection unchanged.", .staleResult, audible: audible)
                return false
            }
            available = rows.filter { $0.buffer == origin }
            if freshScope {
                row = backwards ? available.last : available.first
            } else {
                let continuing =
                    lastNavigation.map { $0.editor === e && $0.revision == e.revision && $0.range == selection }
                    ?? false
                let candidates = available.filter { r in
                    backwards
                        ? NSMaxRange(r.hit.range) <= selection.location && !(continuing && r.hit.range == selection)
                        : r.hit.range.location >= NSMaxRange(selection) && !(continuing && r.hit.range == selection)
                }
                row = backwards ? candidates.last : candidates.first
            }
        }
        if row == nil, buffers.count > 1 {
            // The other documents in open order; an editor outside the list counts as before the
            // first document going forwards and after the last going backwards.
            let count = buffers.count
            var order: [Int] = []
            if backwards {
                let start = origin ?? count
                order = Array((0..<start).reversed())
                if wrap, start < count { order += Array(((start + 1)..<count).reversed()) }
            } else {
                let start = origin ?? -1
                order = Array((start + 1)..<count)
                if wrap, start > 0 { order += Array(0..<start) }
            }
            for index in order {
                if let found = backwards
                    ? rows.last(where: { $0.buffer == index }) : rows.first(where: { $0.buffer == index })
                {
                    row = found
                    break
                }
            }
        }
        if row == nil, wrap { row = backwards ? available.last : available.first }
        guard let row else {
            fail("No further matches.", .noFurtherMatches, audible: audible)
            return false
        }
        return select(row, audible: audible)
    }
    @discardableResult private func select(_ row: Row, audible: Bool) -> Bool {
        guard resultBuffers.indices.contains(row.buffer), let editor = resultBuffers[row.buffer].editor,
            editor.window != nil, editor.revision == resultBuffers[row.buffer].revision,
            let range = SearchCore.byteRange(row.hit.range, in: resultBuffers[row.buffer].text),
            editor.setSelectionAnchor(range.location, caret: NSMaxRange(range))
        else {
            fail("Result is stale; search again. Selection unchanged.", .staleResult, audible: audible)
            return false
        }
        lastNavigation = Navigation(
            editor: editor, revision: editor.revision, range: row.hit.range, from: currentEditor())
        editor.window?.makeKeyAndOrderFront(nil)
        editor.window?.makeFirstResponder(editor)
        return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard rows.indices.contains(row), resultBuffers.indices.contains(rows[row].buffer) else { return nil }
        let r = rows[row], buffer = resultBuffers[r.buffer]
        let match = (buffer.text as NSString).substring(with: r.hit.range)
        return
            "\(buffer.editor?.window?.title ?? "Document") · \(r.hit.range.location) · \(String(match.prefix(160)).replacingOccurrences(of:"\n",with:" ↵ "))"
    }
    @objc private func openResult(_ sender: Any?) {
        guard rows.indices.contains(table.clickedRow) else { return }
        select(rows[table.clickedRow], audible: false)
    }
}
