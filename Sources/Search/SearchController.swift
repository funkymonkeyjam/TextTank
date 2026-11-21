import TextTankCore
import EditorBridge
import NativeSearch
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
/// A bar request has its own cancellation token; it never replaces the Find window's held results.
enum InlineSearchOutcome { case applied, replacedAll(Int), noMatch, stale, cancelled, failed(Error) }
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
    var readFindText: () -> String? = { nil }
    var sharedFlagsChanged: (() -> Void)?
    var writeFindText: (String) -> Void = { _ in }
    var onUnrecordableCommand: ((String) -> Void)?
    private enum Scope: Int, CaseIterable {
        case currentDocument, selection, allOpenDocuments
        var title: String {
            switch self {
            case .currentDocument: return "Current document"
            case .selection: return "Selection"
            case .allOpenDocuments: return "All open documents"
            }
        }
    }
    private var selectedScope: Scope {
        ControlPresentation.selectedID(scope).flatMap(Int.init).flatMap(Scope.init(rawValue:)) ?? .currentDocument
    }
    let queryField = NSTextField(), replacementField = NSTextField()
    let mode = NSPopUpButton(), scope = NSPopUpButton()
    let caseButton = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let wordButton = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    let dotButton = NSButton(checkboxWithTitle: "Dot matches newline", target: nil, action: nil)
    let wrapButton = NSButton(checkboxWithTitle: "Wrap Around", target: nil, action: nil)
    let status = AnnouncingLabel(labelWithString: "Search current document, selection or open documents")
    let table = ActivatingTableView()
    private var options = SearchOptions(), generation = UUID(), cancellation: TTSearchCancellation?
    private(set) var task: Task<Void, Never>?
    /// The next match must be searched against the text after the replacement.
    var searchAfterReplace: @MainActor (String, SearchOptions, TTSearchCancellation, Int) async throws -> SearchReport =
        {
            text, options, cancellation, tabWidth in
            try await Task.detached(priority: .userInitiated) {
                try SearchCore.search(
                    text, options: options, cancellation: cancellation, purpose: .navigation, displayTabWidth: tabWidth)
            }.value
        }
    /// One searched document: the editor is held weakly, so results never keep a closed document
    /// alive, and `text` is the one snapshot shared by all of its rows (F122). `range` is the
    /// UTF-16 scope in Selection scope and nil for the whole text.
    private struct Buffer {
        weak var editor: TTEditor?
        let text: String, revision: UInt, anchor: Int, caret: Int, range: NSRange?
        let tabWidth: Int
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
            let tabWidth: Int
        }
        let options: SearchOptions, scope: Scope, documents: [Document]
        let purpose: SearchCore.Purpose
        // Swift String equality folds canonical equivalents, but Boost regexes and replacement
        // output distinguish their scalar sequences. Cache only identical engine input bytes.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.scope == rhs.scope && lhs.documents == rhs.documents && lhs.purpose == rhs.purpose
                && lhs.options.query.utf8.elementsEqual(rhs.options.query.utf8)
                && lhs.options.replacement.utf8.elementsEqual(rhs.options.replacement.utf8)
                && lhs.options.mode == rhs.options.mode && lhs.options.matchCase == rhs.options.matchCase
                && lhs.options.wholeWord == rhs.options.wholeWord
                && lhs.options.dotMatchesNewline == rhs.options.dotMatchesNewline
                && lhs.options.wrap == rhs.options.wrap
        }
    }
    private var retirementObserver: NSObjectProtocol?
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
    let preferenceNotice = AnnouncingLabel(labelWithString: "")
    let resetPreferencesButton = NSButton(title: "Reset Saved Settings…", target: nil, action: nil)
    private let preferences: JSONFileStore<FindPreferences>
    /// True from the moment a search is started until its result, failure or cancellation is shown.
    private(set) var isSearching = false
    /// Nil while a search is running and before the first action.
    private(set) var lastOutcome: SearchOutcome?
    init(defaults: UserDefaults? = nil, preferencesURL: URL? = nil) {
        let legacy = defaults ?? RuntimeEnvironment.legacyDefaults
        preferences = JSONFileStore(
            url: preferencesURL ?? AppStorage.url(.find), displayName: "Find and Replace settings",
            maximumBytes: FindPreferences.maximumBytes, initial: FindPreferences(), decode: FindPreferences.decode,
            encode: { try $0.encoded() },
            legacyValue: {
                guard let data = legacy?.data(forKey: "TextTank.Search.v1") else { return nil }
                guard data.count <= FindPreferences.maximumBytes else { throw SearchFailure.preferencesTooLarge }
                try PersistedFormat.check(data, context: "Find settings")
                let options = try JSONInputFailure.decode(SearchOptions.self, from: data, context: "Find settings")
                try options.validatePreferences()
                return FindPreferences(options: options)
            })
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
            precondition(Thread.isMainThread)
            let retiring = note.object as? TTEditor
            let successor = note.userInfo?[TTEditorSuccessorKey] as? TTEditor
            MainActor.assumeIsolated {
                guard let self, let retiring, let successor else { return }
                for index in self.resultBuffers.indices where self.resultBuffers[index].editor === retiring {
                    self.resultBuffers[index].editor = successor
                }
                if self.lastNavigation?.editor === retiring { self.lastNavigation = nil }

            }
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        queryField.placeholderString = "Find"
        queryField.setAccessibilityLabel("Find in document")
        replacementField.setAccessibilityLabel("Replace matches with")
        mode.setAccessibilityLabel("Search mode")
        scope.setAccessibilityLabel("Search scope")
        // Return in the query field is Find Next. Only Return sends it, never leaving the field.
        queryField.target = self
        queryField.action = #selector(findNextFromQuery(_:))
        queryField.cell?.sendsActionOnEndEditing = false
        replacementField.placeholderString = "Replace with"
        ControlPresentation.populate(
            mode, choices: SearchOptions.Mode.allCases.map { (String($0.rawValue), $0.displayName) }, selected: "0")
        ControlPresentation.populate(
            scope, choices: Scope.allCases.map { (String($0.rawValue), $0.title) }, selected: "0")
        options = preferences.value.options
        queryField.stringValue = options.query
        replacementField.stringValue = options.replacement
        mode.selectItem(at: mode.indexOfItem(withRepresentedObject: String(options.mode.rawValue)))
        caseButton.state = options.matchCase ? .on : .off
        wordButton.state = options.wholeWord ? .on : .off
        dotButton.state = options.dotMatchesNewline ? .on : .off
        wrapButton.state = options.wrap ? .on : .off
        for control in [mode as NSControl, caseButton, wordButton, dotButton, wrapButton] {
            control.target = self
            control.action = #selector(advancedFlagsChanged(_:))
        }
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
        col.title = "Document · Line:Column · Match"
        col.width = 730
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openResult(_:))
        // Return on the selected row does what a double-click on it does.
        table.onActivate = { [weak self] row in self?.activateResult(at: row) }
        table.setAccessibilityLabel("Search results")
        table.toolTip = "Columns use the tab width captured when the search started."
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        table.usesAlternatingRowBackgroundColors = true
        resetPreferencesButton.target = self
        resetPreferencesButton.action = #selector(resetSavedPreferences(_:))
        resetPreferencesButton.setAccessibilityLabel("Reset saved Find and Replace settings")
        preferenceNotice.setAccessibilityLabel("Saved Find and Replace settings status")
        let preferenceSpacer = NSView()
        preferenceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resetPreferencesButton.setContentHuggingPriority(.required, for: .horizontal)
        let preferenceRow = NSStackView(views: [preferenceNotice, preferenceSpacer, resetPreferencesButton])
        preferenceRow.spacing = 8
        preferenceNotice.lineBreakMode = .byWordWrapping
        preferenceNotice.maximumNumberOfLines = 2
        preferenceNotice.isHidden = preferences.state.error == nil
        preferenceNotice.stringValue =
            preferences.state.error == nil
            ? "" : "Saved search settings could not be read. Reset them to keep new settings."
        preferenceNotice.toolTip = preferences.state.error?.localizedDescription
        let root = NSStackView(views: [
            queryField, replacementField, opts, flags, buttons, marks, preferenceRow, status, scroll
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = root
        for v in [queryField, replacementField, opts, flags, buttons, marks, preferenceRow, status, scroll] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        window.minSize = NSSize(width: 780, height: 440)
        window.initialFirstResponder = queryField
        WindowFrames.track(window, as: "TextTank.FindAndReplace")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    deinit {
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated {
            if let retirementObserver { NotificationCenter.default.removeObserver(retirementObserver) }
        }
    }
    @objc func showSearch(_ sender: Any?) {
        if let shared = readFindText(), !shared.isEmpty { queryField.stringValue = shared }
        showPanel(sender)
    }
    func showFromInline(query: String, replacement: String, sender: Any?) {
        window?.makeFirstResponder(nil)
        queryField.stringValue = query
        replacementField.stringValue = replacement
        showPanel(sender)
    }
    private func showPanel(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(queryField)
    }
    @objc private func advancedFlagsChanged(_ sender: NSControl) { sharedFlagsChanged?() }
    enum InlineFlag { case matchCase, wholeWord, regex }
    func setInlineFlag(_ flag: InlineFlag, enabled: Bool) {
        switch flag {
        case .matchCase: caseButton.state = enabled ? .on : .off
        case .wholeWord: wordButton.state = enabled ? .on : .off
        case .regex:
            let desired: SearchOptions.Mode = enabled ? .regularExpression : .normal
            mode.selectItem(at: mode.indexOfItem(withRepresentedObject: String(desired.rawValue)))
        }
        sharedFlagsChanged?()
    }
    func sharedOptions(query: String, replacement: String) -> SearchOptions {
        var o = SearchOptions(query: query, replacement: replacement)
        o.mode =
            ControlPresentation.selectedID(mode).flatMap(Int.init).flatMap(SearchOptions.Mode.init(rawValue:))
            ?? .normal
        o.matchCase = caseButton.state == .on
        o.wholeWord = wordButton.state == .on
        o.dotMatchesNewline = dotButton.state == .on
        o.wrap = wrapButton.state == .on
        return o
    }
    private func readOptions() -> SearchOptions {
        // Commit the shared field editor before reading distinct window fields.
        window?.makeFirstResponder(nil)
        let o = sharedOptions(query: queryField.stringValue, replacement: replacementField.stringValue)
        do {
            try preferences.save(FindPreferences(options: o))
            preferenceNotice.isHidden = true
        } catch { showPreferenceFailure(error) }
        options = o
        writeFindText(o.query)
        return o
    }
    private func showPreferenceFailure(_ error: Error) {
        preferenceNotice.stringValue =
            "The search can run, but its settings were not saved. Reset saved settings or try again."
        preferenceNotice.toolTip = error.localizedDescription
        preferenceNotice.isHidden = false
        resetPreferencesButton.isHidden = false
    }
    @objc func resetSavedPreferences(_ sender: Any?) {
        guard StoreRecovery.confirmPreferenceReset(preferences.state) else { return }
        do {
            try preferences.reset()
            options = preferences.value.options
            queryField.stringValue = options.query
            replacementField.stringValue = options.replacement
            mode.selectItem(at: mode.indexOfItem(withRepresentedObject: String(options.mode.rawValue)))
            caseButton.state = options.matchCase ? .on : .off
            wordButton.state = options.wholeWord ? .on : .off
            dotButton.state = options.dotMatchesNewline ? .on : .off
            wrapButton.state = options.wrap ? .on : .off
            sharedFlagsChanged?()
            preferenceNotice.isHidden = true
            status.stringValue = "Saved search settings were reset. Documents were not changed."
        } catch { showPreferenceFailure(error) }
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
        let editors = selectedScope == .allOpenDocuments ? openEditors() : currentEditor().map { [$0] } ?? []
        var cleared = Set<ObjectIdentifier>()
        for editor in editors where EditorLifetime.isOpen(editor) {
            if cleared.insert(ObjectIdentifier(editor)).inserted { editor.clearSearchHighlights() }
        }
        status.stringValue = Strings.cleared(cleared.count)
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
        _ = readOptions()
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
        let scopeIndex = selectedScope
        // Captured before the search: focus may have moved by the time the results arrive (F36).
        let current = currentEditor()
        var editors = scopeIndex == .allOpenDocuments ? openEditors() : current.map { [$0] } ?? []
        var identities = Set<ObjectIdentifier>()
        editors = editors.filter { identities.insert(ObjectIdentifier($0)).inserted }
        guard !editors.isEmpty else {
            fail("Open a document first.", .needsInput, audible: navigating)
            return
        }
        if scopeIndex != .currentDocument {
            onUnrecordableCommand?("Selection and all-open search operations are not recorded in macros.")
        }
        let currentDocumentScope = scopeIndex == .currentDocument, selectionScope = scopeIndex == .selection
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
                    range: range, tabWidth: e.statusInfo.tabWidth))
        }
        // F36: the document a single Replace may edit. In All open documents scope that is the
        // document Next last moved to while its match is still selected, by the same rule as
        // navigation, because the application's current editor can lag behind that move.
        let active =
            scopeIndex == .allOpenDocuments
            ? allOpenOrigin(in: buffers, current: current).flatMap { buffers[$0].editor } : current
        var keyOptions = opts
        keyOptions.wrap = false
        let purpose: SearchCore.Purpose = navigating || action == .replaceOne ? .navigation : .allMatches
        let key = ResultKey(
            options: keyOptions, scope: scopeIndex,
            documents: buffers.map { b in
                ResultKey.Document(
                    editor: b.editor.map { ObjectIdentifier($0) }, revision: b.revision, range: b.range,
                    tabWidth: b.tabWidth)
            }, purpose: purpose)
        // F223: the same editors at the same revisions with the same options have the same hits,
        // so Next and Previous walk the rows already held instead of searching again.
        if navigating, key == resultKey, resultBuffers.allSatisfy({ $0.editor != nil }) {
            status.stringValue = Self.foundStatus(rows.count, resultBuffers.count, resultTruncated)
            lastOutcome = .found(matches: rows.count, documents: resultBuffers.count, truncated: resultTruncated)
            reusedResults += 1
            let moved = navigate(
                backwards: action == .previous, wrap: opts.wrap, freshScope: freshScope,
                allOpen: scopeIndex == .allOpenDocuments,
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
        status.stringValue = "Searching…"
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
            (
                text: $0.text, scope: $0.range ?? NSRange(location: 0, length: ($0.text as NSString).length),
                tabWidth: $0.tabWidth
            )
        }
        task = Task { @MainActor [weak self] in
            do {
                let computed = try await Task.detached(priority: .userInitiated) {
                    let reports = try snapshots.map {
                        try SearchCore.search(
                            $0.text, options: opts, range: $0.scope, cancellation: flag, purpose: purpose,
                            displayTabWidth: $0.tabWidth)
                    }
                    let lines =
                        needsBookmarks
                        ? try zip(snapshots, reports).map { snapshot, report in
                            try SearchCore.bookmarkLines(
                                in: snapshot.text, locations: report.hits.map { $0.range.location }, cancellation: flag)
                        } : []
                    return (reports: reports, bookmarkLines: lines)
                }.value
                guard let self, self.generation == token, !flag.cancelled else { return }
                let replaced = self.complete(
                    action, options: opts, key: key, buffers: buffers, reports: computed.reports,
                    bookmarkLines: computed.bookmarkLines,
                    scopeIndex: scopeIndex, active: active, freshScope: freshScope)
                if let editor = replaced {
                    // F45: a single Replace then moves to the next match. The text has changed, so
                    // that needs a search of the new text; it is recorded as an ordinary Next.
                    let text = editor.text, revision = editor.revision,
                        tabWidth = editor.statusInfo.tabWidth
                    self.appliedReplace = (self.status.stringValue, self.lastOutcome)
                    let report = try? await self.searchAfterReplace(text, opts, flag, tabWidth)
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
        Strings.found(matches, documents: documents, truncated: truncated)
    }
    private static func replacedStatus(changed: Int, skips: ReplaceSkips) -> String {
        var kinds: [String] = []
        if skips.readOnly > 0 { kinds.append("\(skips.readOnly) read-only") }
        if skips.multipleSelections > 0 { kinds.append("\(skips.multipleSelections) with multiple selections") }
        if skips.closed > 0 { kinds.append("\(skips.closed) closed") }
        guard !kinds.isEmpty else {
            return Strings.replaced(changed, stale: skips.stale)
        }
        if skips.stale > 0 { kinds.append("\(skips.stale) changed") }
        return String(
            format: changed == 1
                ? Strings.text(
                    "search.replaced.reasons.one", "Replaced %@ match; documents skipped: %@. Undo is per document.")
                : Strings.text(
                    "search.replaced.reasons.other", "Replaced %@ matches; documents skipped: %@. Undo is per document."
                ), Strings.number(changed), kinds.joined(separator: ", "))
    }
    /// Shows the results of a finished search and performs `action` on them. Returns the editor
    /// in which a single Replace was applied when the next match should then be selected.
    private func complete(
        _ action: Action, options opts: SearchOptions, key: ResultKey, buffers: [Buffer], reports: [SearchReport],
        bookmarkLines: [[Int]], scopeIndex: Scope, active: TTEditor?, freshScope: Bool
    ) -> TTEditor? {
        let currentDocumentScope = scopeIndex == .currentDocument, selectionScope = scopeIndex == .selection
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
            // G372: the editor stayed editable while the search ran. A result for text that has
            // since changed, or for an editor that is no longer current, moves nothing and a
            // recording that already holds the later edits is discarded.
            if currentDocumentScope, let b = buffers.first,
                !(b.editor.map { EditorLifetime.isOpen($0) } == true && b.editor?.revision == b.revision
                    && currentEditor() === b.editor)
            {
                fail("Result is stale; search again. Selection unchanged.", .staleResult, audible: true)
                onUnrecordableCommand?(
                    "The document changed while the search was running; the search step was not recorded.")
                return nil
            }
            // A miss is not recorded: playback stops on a recorded search that finds nothing.
            let moved = navigate(
                backwards: action == .previous, wrap: opts.wrap, freshScope: freshScope,
                allOpen: scopeIndex == .allOpenDocuments,
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
                let chosen: [SearchHit]
                if action == .replaceOne {
                    let selected = SearchCore.utf16Range(
                        NSRange(location: min(buffer.anchor, buffer.caret), length: abs(buffer.anchor - buffer.caret)),
                        in: buffer.text)
                    chosen = hits.filter { $0.range == selected }
                } else {
                    chosen = hits
                }
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
                let capture = action == .replaceAll && !chosen.isEmpty ? BulkChangeCapture(editor, name: "Replace All") : nil
                switch Self.replace(chosen, text: buffer.text, revision: buffer.revision, in: editor) {
                case .applied(let count):
                    changed += count
                    capture?.finish()
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
                Strings.marked(marked, stale: stale, zeroWidth: zeroWidth)
            lastOutcome = .marked(matches: marked, stale: stale, zeroWidth: zeroWidth)
        case .bookmark:
            var stale = 0
            guard !truncated else {
                fail("Result limit reached; bookmarks were preserved. Narrow the scope.", .limitReached, audible: false)
                return nil
            }
            for (index, b) in buffers.enumerated() {
                guard let editor = b.editor, EditorLifetime.isOpen(editor), editor.revision == b.revision,
                    !selectionScope || (editor.selectionAnchor == b.anchor && editor.selectionCaret == b.caret)
                else {
                    stale += 1
                    continue
                }
                var lines = Set(editor.bookmarkLines.map { $0.intValue })
                lines.formUnion(bookmarkLines[index])
                _ = editor.setBookmarks(lines.sorted().map { NSNumber(value: $0) })
            }
            status.stringValue = String(
                format: stale == 1
                    ? Strings.text("search.bookmarked.one", "Bookmarked matching lines; %@ changed document skipped.")
                    : Strings.text(
                        "search.bookmarked.other", "Bookmarked matching lines; %@ changed documents skipped."),
                Strings.number(stale))
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
                caret: editor.selectionCaret, range: nil, tabWidth: editor.statusInfo.tabWidth)
        ]
        rows = report.hits.map { Row(buffer: 0, hit: $0) }
        resultKey = ResultKey(
            options: key.options, scope: key.scope,
            documents: [
                ResultKey.Document(
                    editor: ObjectIdentifier(editor), revision: revision, range: nil,
                    tabWidth: editor.statusInfo.tabWidth)
            ],
            purpose: report.purpose)
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
    /// The budget of one recorded search step: the interactive budget, from the one constant.
    static let recordedStepTimeLimit = SearchCore.defaultTimeLimit
    /// Macro playback is bounded and has no disk or connector side effects: each step may search
    /// for at most `timeLimit` seconds, synchronously, and a step that runs out of time throws
    /// before any edit. Next and Previous throw when they do not land on a match, so the steps
    /// after them never run at a stale caret; Replace All with no match is a deliberate no-op.
    /// Replace stays strict here: it replaces only a selected match and never moves on, because
    /// saved macros carry their own Next steps.
    func playRecorded(
        options: SearchOptions, action: String, on editor: TTEditor,
        timeLimit: TimeInterval = SearchController.recordedStepTimeLimit
    ) throws {
        let text = editor.text, revision = editor.revision
        let report = try SearchCore.search(
            text, options: options, timeLimit: timeLimit,
            purpose: action == "replaceAll" ? .allMatches : .navigation)
        let matched: Bool
        do {
            matched = try applySingleReport(
                report, text: text, revision: revision, options: options, action: action, in: editor)
        } catch let condition as SearchFailure.ReplacementCondition {
            // Keep the existing recorded-macro error API and wording. Inline feedback receives
            // typed conditions directly and selects complete templates instead of these fragments.
            switch condition {
            case .readOnly: throw SearchFailure.macroReplacement("the document is read-only")
            case .multipleSelections: throw SearchFailure.macroReplacement("multiple selections are not supported")
            case .closed: throw SearchFailure.macroReplacement("the document is not in a window")
            case .stale: throw SearchFailure.macroReplacement("the document changed during the step")
            }
        }
        if !matched && (action == "next" || action == "previous") {
            throw Self.recordedSearchStopped("recorded search did not match")
        }
    }
    /// Legacy v1 findLiteral is read-only migration input. It uses the same engine and application
    /// rules as a new search step; old replaceSelection retains its captured-text caret semantics.
    static func playLegacyFind(text query: String, matchCase: Bool, backwards: Bool, in editor: TTEditor) throws -> Bool
    {
        var options = SearchOptions()
        options.query = query
        options.matchCase = matchCase
        let text = editor.text, revision = editor.revision
        let report = try SearchCore.search(text, options: options, purpose: .navigation)
        return try applySingleReport(
            report, text: text, revision: revision, options: options, action: backwards ? "previous" : "next",
            continuing: false, in: editor)
    }
    /// The bar uses immutable snapshots off-main, then validates document/window/selection and the
    /// caller's query generation before applying. A cancelled or stale request cannot select, edit or record.
    /// Macro playback deliberately retains bounded synchronous scheduling over the same engine/apply path.
    func performInline(
        options: SearchOptions, action: String, on editor: TTEditor, cancellation: TTSearchCancellation,
        isCurrent: @escaping () -> Bool, completion: @escaping (InlineSearchOutcome) -> Void
    ) {
        let text = editor.text, revision = editor.revision, selections = editor.selectionRanges
        let anchor = editor.selectionAnchor, caret = editor.selectionCaret
        let targetDocumentID = EditorLifetime.document(for: editor)?.runtimeID
        let window = editor.window
        Task { @MainActor [weak self, weak editor, weak window] in
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try SearchCore.search(
                        text, options: options, cancellation: cancellation,
                        purpose: action == "replaceAll" ? .allMatches : .navigation)
                }.value
                guard !cancellation.cancelled else {
                    completion(.cancelled)
                    return
                }
                guard let self, let editor, EditorLifetime.isOpen(editor),
                    (targetDocumentID != nil
                        ? EditorLifetime.document(for: editor)?.runtimeID == targetDocumentID
                        : editor.window === window),
                    editor.revision == revision, editor.selectionRanges == selections,
                    editor.selectionAnchor == anchor, editor.selectionCaret == caret, isCurrent()
                else {
                    completion(.stale)
                    return
                }
                let matched = try self.applySingleReport(
                    report, text: text, revision: revision, options: options, action: action, in: editor)
                if matched && action == "replaceAll" { completion(.replacedAll(report.hits.count)) }
                else { completion(matched ? .applied : .noMatch) }
            } catch {
                guard !cancellation.cancelled else {
                    completion(.cancelled)
                    return
                }
                guard self != nil, let editor, EditorLifetime.isOpen(editor),
                    (targetDocumentID != nil
                        ? EditorLifetime.document(for: editor)?.runtimeID == targetDocumentID
                        : editor.window === window),
                    editor.revision == revision, editor.selectionRanges == selections,
                    editor.selectionAnchor == anchor, editor.selectionCaret == caret, isCurrent()
                else {
                    completion(.stale)
                    return
                }
                if let failure = error as? SearchFailure, failure == .macroResultLimit {
                    completion(.failed(SearchFailure.inlineResultLimit))
                } else if let condition = error as? SearchFailure.ReplacementCondition {
                    completion(.failed(SearchFailure.inlineReplacement(condition)))
                } else {
                    completion(.failed(error))
                }
            }
        }
    }
    private func applySingleReport(
        _ report: SearchReport, text: String, revision: UInt, options: SearchOptions, action: String,
        in editor: TTEditor
    ) throws -> Bool {
        let selection = SearchCore.utf16Range(
            NSRange(location: editor.selectionStart, length: editor.selectionEnd - editor.selectionStart), in: text)
        let continuing =
            lastNavigation.map {
                $0.editor === editor && $0.revision == revision && $0.range == selection
            } ?? false
        let matched = try Self.applySingleReport(
            report, text: text, revision: revision, options: options, action: action, continuing: continuing, in: editor
        )
        if matched && (action == "next" || action == "previous"),
            let range = SearchCore.utf16Range(
                NSRange(location: editor.selectionStart, length: editor.selectionEnd - editor.selectionStart), in: text)
        {
            lastNavigation = Navigation(editor: editor, revision: revision, range: range, from: nil)
        }
        return matched
    }
    private static func applySingleReport(
        _ report: SearchReport, text: String, revision: UInt, options: SearchOptions, action: String, continuing: Bool,
        in editor: TTEditor
    ) throws -> Bool {
        // Preserve the pre-extraction cheap rejection boundary: closed/stale/truncated
        // results must not read selections or scan positions in a captured document.
        guard !report.truncated else { throw SearchFailure.macroResultLimit }
        guard EditorLifetime.isOpen(editor), editor.revision == revision else {
            throw Self.recordedSearchStopped("the document changed or selection is not on a character boundary")
        }
        let selection = SearchCore.utf16Range(
            NSRange(location: editor.selectionStart, length: editor.selectionEnd - editor.selectionStart), in: text)
        let snapshot = SearchSession.Snapshot(
            text: text, revision: revision, currentRevision: editor.revision,
            selection: selection, isOpen: EditorLifetime.isOpen(editor))
        switch try SearchSession.plan(
            report, snapshot: snapshot, options: options, action: action, continuing: continuing)
        {
        case .noMatch: return false
        case .select(let bytes):
            guard editor.setSelectionAnchor(bytes.location, caret: NSMaxRange(bytes)) else {
                throw Self.recordedSearchStopped("the match could not be selected")
            }
            return true
        case .replace(let hits):
            let condition: SearchFailure.ReplacementCondition
            switch Self.replace(hits, text: text, revision: revision, in: editor) {
            case .applied: return true
            case .readOnly: condition = .readOnly
            case .multipleSelections: condition = .multipleSelections
            case .closed: condition = .closed
            case .stale: condition = .stale
            }
            throw condition
        }
    }

    private static func recordedSearchStopped(_ reason: String) -> SearchFailure { .macroStopped(reason) }
    struct InlinePreview: Sendable {
        let highlights: [NSRange]
        let selected: NSRange?
        let countText: String
    }
    /// Read-only. Range conversion and searching operate only on the immutable editor snapshot.
    nonisolated static func preview(_ snapshot: Data, options: SearchOptions, openingCaret: Int,
                                    cancellation: TTSearchCancellation) throws -> InlinePreview {
        guard !cancellation.cancelled else { throw CancellationError() }
        guard (0...snapshot.count).contains(openingCaret),
              openingCaret == snapshot.count || snapshot[snapshot.startIndex + openingCaret] & 0xc0 != 0x80,
              let text = String(data: snapshot, encoding: .utf8) else { throw SearchFailure.positionMapping }
        let limit = 256
        let report = try SearchCore.search(text, options: options, cancellation: cancellation, limit: limit)
        let utf16 = text.utf16, utf8 = text.utf8
        let ascii = utf16.count == snapshot.count
        func bytes(_ range: NSRange) throws -> NSRange {
            guard !cancellation.cancelled else { throw CancellationError() }
            if ascii { return range }
            let start = utf16.index(utf16.startIndex, offsetBy: range.location)
            let end = utf16.index(start, offsetBy: range.length)
            guard let a = start.samePosition(in: utf8), let b = end.samePosition(in: utf8) else {
                throw SearchFailure.positionMapping
            }
            return NSRange(location: utf8.distance(from: utf8.startIndex, to: a), length: utf8.distance(from: a, to: b))
        }
        let ranges = try report.hits.map { try bytes($0.range) }
        var selected = ranges.first { $0.location >= openingCaret }
        if report.truncated && selected == nil {
            guard !cancellation.cancelled else { throw CancellationError() }
            let caret = utf8.index(utf8.startIndex, offsetBy: openingCaret)
            guard let start = caret.samePosition(in: utf16) else { throw SearchFailure.positionMapping }
            let tail = NSRange(location: utf16.distance(from: utf16.startIndex, to: start),
                               length: utf16.distance(from: start, to: utf16.endIndex))
            let remaining = try SearchCore.search(text, options: options, range: tail, cancellation: cancellation, limit: 1)
            if let hit = remaining.hits.first { selected = try bytes(hit.range) }
        }
        guard !cancellation.cancelled else { throw CancellationError() }
        if selected == nil && options.wrap { selected = ranges.first }
        var visible = ranges
        if let selected, !visible.contains(selected) { visible.removeLast(); visible.append(selected) }
        let count: String
        if report.truncated { count = "\(limit)+ matches" }
        else if let selected, let i = ranges.firstIndex(of: selected) { count = "\(i + 1) of \(ranges.count)" }
        else { count = ranges.isEmpty ? "No matches" : "\(ranges.count) matches" }
        return InlinePreview(highlights: visible, selected: selected, countText: count)
    }
    /// `revision` is the staleness authority: every insert and delete moves it, in every view of a
    /// shared document, so an equal revision means `text` is still the editor's text (F223).
    @discardableResult static func highlight(_ hits: [SearchHit], text: String, revision: UInt, in editor: TTEditor)
        -> Bool
    {
        guard EditorLifetime.isOpen(editor), editor.revision == revision,
            let ranges = SearchCore.byteRanges(hits.map(\.range), in: text)
        else { return false }
        return editor.setSearchHighlights(
            ranges.filter { $0.length > 0 }.map { TTByteRange(location: $0.location, length: $0.length) })
    }
    @discardableResult static func apply(_ hits: [SearchHit], text: String, revision: UInt, to editor: TTEditor) -> Bool
    {
        if case .applied(let count) = replace(hits, text: text, revision: revision, in: editor) { return count > 0 }
        return false
    }
    /// Replaces `hits` (ascending, found in `text` at `revision`) in one bridge call under one undo
    /// action, or changes nothing and says why. The selection the command began with is kept around
    /// the text it covered.
    static func replace(_ hits: [SearchHit], text: String, revision: UInt, in editor: TTEditor) -> ReplaceOutcome {
        guard EditorLifetime.isOpen(editor) else { return .closed }
        guard !editor.readOnly else { return .readOnly }
        guard editor.revision == revision else { return .stale }
        guard editor.selectionCount == 1 else { return .multipleSelections }
        guard !hits.isEmpty else { return .applied(0) }
        // The selection is not the edit cursor (G374): it is carried through the replacements, and
        // Undo returns to the selection the command began with.
        let anchor = editor.selectionAnchor, caret = editor.selectionCaret
        guard let ranges = SearchCore.byteRanges(hits.map(\.range), in: text),
            editor.replaceRanges(
                ranges.map { TTByteRange(location: $0.location, length: $0.length) },
                withTexts: hits.map(\.replacement), expectedRevision: revision)
        else { return .stale }
        let edits = zip(ranges, hits).map {
            SearchSession.Edit(range: $0.0, replacementBytes: $0.1.replacement.utf8.count)
        }
        let carried = SearchSession.carriedSelection(anchor: anchor, caret: caret, edits: edits)
        _ = editor.setSelectionAnchor(carried.anchor, caret: carried.caret)
        return .applied(hits.count)
    }
    /// All open documents: the buffer of the document the person is in, for Next, Previous and
    /// single Replace alike. After a move into another document the application's idea of the
    /// current editor can lag (F48), so the document last navigated to stays the answer while its
    /// selection is still that match and the person has not moved elsewhere. Moving elsewhere
    /// shows as a different listed current editor, or, since only the selected tab's window is
    /// visible, as the current editor being on screen while the one navigated to is not. That
    /// test covers the editor navigated from and a current editor outside the open list (a split
    /// view) alike, so a hidden document is never the answer once the person is back.
    private func allOpenOrigin(in buffers: [Buffer], current: TTEditor?) -> Int? {
        if let last = lastNavigation, let editor = last.editor, editor.revision == last.revision,
            current == nil || current === editor
                || ((current === last.from || !buffers.contains(where: { $0.editor === current }))
                    && !(EditorLifetime.isVisible(current) && !EditorLifetime.isVisible(editor))),
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
        var originSelection: NSRange?
        if let origin {
            let b = buffers[origin]
            guard let e = b.editor, e.revision == b.revision,
                let selection = SearchCore.utf16Range(
                    NSRange(location: e.selectionStart, length: e.selectionEnd - e.selectionStart), in: b.text)
            else {
                fail("Result is stale; search again. Selection unchanged.", .staleResult, audible: audible)
                return false
            }
            originSelection = selection
            available = rows.filter { $0.buffer == origin }
            if freshScope {
                row = backwards ? available.last : available.first
            } else {
                let continuing =
                    lastNavigation.map { $0.editor === e && $0.revision == e.revision && $0.range == selection }
                    ?? false
                let candidates = available.filter {
                    SearchCore.isNavigationCandidate(
                        $0.hit.range, from: selection, backwards: backwards, continuing: continuing)
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
        if row == nil, wrap {
            let wrapped = available.filter { row in
                guard let selection = originSelection else { return true }
                return SearchCore.isWrappedNavigationCandidate(
                    row.hit.range, from: selection, backwards: backwards,
                    mode: resultKey?.options.mode ?? .normal)
            }
            row = backwards ? wrapped.last : wrapped.first
        }
        guard let row else {
            fail("No further matches.", .noFurtherMatches, audible: audible)
            return false
        }
        // Find Next stays in the Find window: a row of a document whose window is already showing
        // only moves the selection, so the document window is not made key over this one. A row
        // in a document that is not showing brings that document forward.
        return select(row, focusEditor: false, audible: audible)
    }
    /// `focusEditor` brings the result's document window forward and puts the keyboard in its
    /// editor: opening a listed result does that, and it is what switches the document tab for a
    /// result in another document. Without it only the selection moves, unless the document is
    /// not showing at all.
    @discardableResult private func select(_ row: Row, focusEditor: Bool, audible: Bool) -> Bool {
        guard resultBuffers.indices.contains(row.buffer), let editor = resultBuffers[row.buffer].editor,
            EditorLifetime.isOpen(editor), editor.revision == resultBuffers[row.buffer].revision,
            let range = SearchCore.byteRange(row.hit.range, in: resultBuffers[row.buffer].text),
            editor.setSelectionAnchor(range.location, caret: NSMaxRange(range))
        else {
            fail("Result is stale; search again. Selection unchanged.", .staleResult, audible: audible)
            return false
        }
        lastNavigation = Navigation(
            editor: editor, revision: editor.revision, range: row.hit.range, from: currentEditor())
        if focusEditor || !EditorLifetime.isVisible(editor) { EditorLifetime.activate(editor) }
        return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard rows.indices.contains(row), resultBuffers.indices.contains(rows[row].buffer) else { return nil }
        let r = rows[row], buffer = resultBuffers[r.buffer]
        let match = (buffer.text as NSString).substring(with: r.hit.range)
        return
            "\(EditorLifetime.title(buffer.editor)) · \(r.hit.displayPosition.map { "\($0.line):\($0.column)" } ?? "—") · \(String(match.prefix(160)).replacingOccurrences(of:"\n",with:" ↵ "))"
    }
    /// A double-click. `clickedRow` is -1 for the header and the empty area below the rows,
    /// which therefore do nothing even while a row is selected.
    @objc func openResult(_ sender: Any?) { activateResult(at: table.clickedRow) }
    /// What a double-click or Return on a listed result does: selects that match if the result
    /// is still current, and brings its document forward. The jump moves the caret with no
    /// recordable step (F277), so a jump that happened is reported to the macro recording.
    @discardableResult func activateResult(at row: Int) -> Bool {
        guard rows.indices.contains(row), select(rows[row], focusEditor: true, audible: false) else { return false }
        onUnrecordableCommand?("Opening a search result is not recorded in macros yet.")
        return true
    }
    func open(row: Int) {
        activateResult(at: row)
    }
}
