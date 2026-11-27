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
    /// Next or Previous selected a match in a document too large to count as part of the move.
    case movedToMatch
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

/// The newest progress step of a search, written on the search's thread and read on the main one.
private final class LatestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (done: Int, total: Int)?
    func set(_ done: Int, _ total: Int) {
        lock.lock()
        latest = (done, total)
        lock.unlock()
    }
    var value: (done: Int, total: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

/// Native snapshot search. Workers never access TTEditor; results are revision checked.
final class SearchController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
    NSComboBoxDelegate
{
    var currentEditor: () -> TTEditor? = { nil }
    var openEditors: () -> [TTEditor] = { [] }
    var onCommand: ((SearchOptions, String, TTEditor) -> Void)?
    var readFindText: () -> String? = { nil }
    var sharedFlagsChanged: (() -> Void)?
    var writeFindText: (String) -> Void = { _ in }
    var onUnrecordableCommand: ((String) -> Void)?
    /// DS-35, one Find: the text to find and the text to replace it with are one pair of values,
    /// shown live by this window and by every find bar. A surface reports what is typed in it
    /// (`setSharedQuery`, `setSharedReplacement`) and is told what was typed elsewhere through
    /// `sharedTextChanged`, which never calls back into the surface that made the change, so the
    /// field being typed in keeps its caret and selection. Sharing text runs no search.
    private(set) var sharedQuery = "", sharedReplacement = ""
    /// Called with the surface that made the change (nil for a change made by a command).
    var sharedTextChanged: ((AnyObject?) -> Void)?
    /// The last ten distinct searches and replacements, kept in the private settings file and
    /// offered by both surfaces. Nothing in it is applied until the person chooses an entry.
    private(set) var findHistory = FindHistory()
    var historyChanged: (() -> Void)?
    /// The find pasteboard text this application last wrote or took in. Another application's
    /// search is imported when the pasteboard no longer holds this.
    private var findPasteboardSeen: String?
    /// A document longer than this many UTF-16 units is searched as bytes, in windows of
    /// `largeChunkBytes`. Checks lower both to exercise that path on small fixtures.
    var largeDocumentUnits = SearchCore.maximumTextUnits
    var largeChunkBytes = SearchCore.largeChunkBytes
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
    /// Combo boxes: the arrow button and the Down Arrow key both open the history (DS-73).
    let queryField = NSComboBox(), replacementField = NSComboBox()
    /// Visible captions; a placeholder disappears as soon as something is typed.
    let queryCaption = NSTextField(labelWithString: "Find"),
        replacementCaption = NSTextField(labelWithString: "Replace with")
    /// DS-45: an expression that does not compile is marked here, under the field, in full.
    let patternNotice = NSTextField(wrappingLabelWithString: "")
    private let patternIcon = NSImageView()
    private var fieldGrid: NSGridView?
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
    /// DS-21: what the last search that found nothing was a search for. Replace All stays
    /// disabled while the fields, options, scope and documents are still exactly that.
    private struct EmptySearch: Equatable {
        struct Document: Equatable { let editor: ObjectIdentifier, revision: UInt, selection: NSRange? }
        let query: [UInt8], mode: SearchOptions.Mode, matchCase: Bool, wholeWord: Bool, dotMatchesNewline: Bool
        let scope: Scope, documents: [Document]
    }
    private var emptySearch: EmptySearch?
    /// What the search now running is a search of, captured when it was asked for.
    private var searchIdentity: EmptySearch?
    /// Progress steps shown for large-document searches so far; for checks.
    private(set) var progressReports = 0
    /// The status-row operation of the large-document search now running: the same progress
    /// and the same Cancel as this window's, where the document is.
    private var statusOperation: UUID?
    var replaceAllButton: NSButton { searchButtons[4] }
    private var largeNavigation: Navigation?, largeScope: Navigation?
    /// Whether an editor at a revision is above `largeDocumentUnits`, so that the next press does
    /// not count the document again.
    private struct LargeDecision {
        weak var editor: TTEditor?
        let revision: UInt, limit: Int, large: Bool
    }
    private var largeDecisions: [ObjectIdentifier: LargeDecision] = [:]
    /// How often a document's bytes were copied only to decide whether it is large; for checks.
    private(set) var largeDecisionCopies = 0
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
        for field in [queryField, replacementField] {
            field.delegate = self
            field.usesDataSource = false
            field.completes = false
            field.numberOfVisibleItems = FindHistory.capacity
            field.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        patternNotice.isSelectable = true
        patternNotice.setAccessibilityLabel("Problem with the search expression")
        // The mark is a symbol and words, never colour alone (DS-62).
        patternIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Expression not valid")
        patternIcon.contentTintColor = .systemRed
        patternIcon.setContentHuggingPriority(.required, for: .horizontal)
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
        // A new launch is in Normal mode with both fields empty. What was searched for before is
        // in the history, offered by the fields and never put back by itself.
        applyStartingPreferences()
        for control in [mode as NSControl, caseButton, wordButton, dotButton, wrapButton] {
            control.target = self
            control.action = #selector(advancedFlagsChanged(_:))
        }
        scope.target = self
        scope.action = #selector(scopeChanged(_:))
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
        let spacer = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [queryCaption, queryField], [spacer, NSStackView(views: [patternIcon, patternNotice])],
            [replacementCaption, replacementField]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        grid.row(at: 1).isHidden = true
        fieldGrid = grid
        // The whole message is shown: an error that is cut off cannot be acted on (DS-81).
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        status.cell?.wraps = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let root = NSStackView(views: [grid, opts, flags, buttons, marks, preferenceRow, status, scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = root
        for v in [grid, opts, flags, buttons, marks, preferenceRow, status, scroll] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        }
        // The results give way first when a three-line message and the expression notice both show.
        let resultsHeight = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        resultsHeight.priority = .defaultHigh
        resultsHeight.isActive = true
        window.minSize = NSSize(width: 780, height: 500)
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
        // Find and Replace acts on the source; a tab showing only its preview shows both first.
        EditorServices.current?.activePresentation?.revealSource()
        importFindPasteboard()
        showPanel(sender)
    }
    func showFromInline(query: String, replacement: String, sender: Any?) {
        window?.makeFirstResponder(nil)
        setSharedQuery(query, from: nil)
        setSharedReplacement(replacement, from: nil)
        showPanel(sender)
    }
    /// Takes in what another application searched for. The pasteboard is read when a Find surface
    /// opens; text this application put there, or already took, is not taken again, so opening
    /// the window never replaces what was typed in the find bar a moment ago.
    @discardableResult func importFindPasteboard(onlyIfEmpty: Bool = false) -> Bool {
        guard let board = readFindText(), !board.isEmpty else { return false }
        let fresh = findPasteboardSeen.map { !$0.utf8.elementsEqual(board.utf8) } ?? true
        findPasteboardSeen = board
        guard fresh, !onlyIfEmpty || sharedQuery.isEmpty else { return false }
        setSharedQuery(board, from: nil)
        return true
    }
    /// At launch: what is on the find pasteboard now was put there before this launch, possibly
    /// by an earlier launch of this application. It is not taken in, so a new launch starts with
    /// an empty Find field; a search made in another application from now on still is.
    func adoptFindPasteboard() { findPasteboardSeen = readFindText() ?? "" }
    /// What this application searched for becomes the find pasteboard text (DS-35).
    func shareFindPasteboard(_ text: String) {
        findPasteboardSeen = text
        writeFindText(text)
    }
    func setSharedQuery(_ text: String, from source: AnyObject?) {
        let changed = !sharedQuery.utf8.elementsEqual(text.utf8)
        sharedQuery = text
        // The window's own field is set only when someone else changed the text: setting the
        // field that is being typed in would move its caret.
        if source !== self, !queryField.stringValue.utf8.elementsEqual(text.utf8) { queryField.stringValue = text }
        guard changed else { return }
        clearPatternMark()
        updateReplaceAllAvailability()
        sharedTextChanged?(source)
    }
    func setSharedReplacement(_ text: String, from source: AnyObject?) {
        let changed = !sharedReplacement.utf8.elementsEqual(text.utf8)
        sharedReplacement = text
        if source !== self, !replacementField.stringValue.utf8.elementsEqual(text.utf8) {
            replacementField.stringValue = text
        }
        if changed { sharedTextChanged?(source) }
    }
    /// A search that was asked for (not text that was merely typed) enters the history, and the
    /// history is saved with the option flags. A replacement is remembered when one was used.
    func remember(query: String, replacement: String?) {
        var changed = !query.isEmpty && findHistory.remember(query: query)
        if let replacement, !replacement.isEmpty, findHistory.remember(replacement: replacement) { changed = true }
        guard changed else { return }
        publishHistory()
        savePreferences(sharedOptions(query: "", replacement: ""))
    }
    /// Forgets the remembered searches or the remembered replacements, here and in the file.
    func clearHistory(replacements: Bool) {
        if replacements { findHistory.clearReplacements() } else { findHistory.clearQueries() }
        publishHistory()
        savePreferences(sharedOptions(query: "", replacement: ""))
    }
    private func publishHistory() {
        queryField.removeAllItems()
        queryField.addItems(withObjectValues: findHistory.queries)
        replacementField.removeAllItems()
        replacementField.addItems(withObjectValues: findHistory.replacements)
        historyChanged?()
    }
    private func applyStartingPreferences() {
        options = preferences.value.startingOptions
        findHistory = preferences.value.history
        setSharedQuery("", from: nil)
        setSharedReplacement("", from: nil)
        mode.selectItem(at: mode.indexOfItem(withRepresentedObject: String(options.mode.rawValue)))
        caseButton.state = options.matchCase ? .on : .off
        wordButton.state = options.wholeWord ? .on : .off
        dotButton.state = options.dotMatchesNewline ? .on : .off
        wrapButton.state = options.wrap ? .on : .off
        publishHistory()
    }
    private func savePreferences(_ options: SearchOptions) {
        do {
            try preferences.save(FindPreferences(saving: options, history: findHistory))
            preferenceNotice.isHidden = true
        } catch { showPreferenceFailure(error) }
    }
    // Typing in either field is shared as it happens. No search runs.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSComboBox else { return }
        if field === queryField { setSharedQuery(field.stringValue, from: self) }
        if field === replacementField { setSharedReplacement(field.stringValue, from: self) }
    }
    /// An entry chosen from a field's history becomes the shared text. Choosing with the arrow
    /// keys reports each entry passed; the field shows the entry, as a combo box does.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSComboBox, field.indexOfSelectedItem >= 0,
            let chosen = field.objectValueOfSelectedItem as? String
        else { return }
        if field === queryField { setSharedQuery(chosen, from: nil) }
        if field === replacementField { setSharedReplacement(chosen, from: nil) }
    }
    private func markPattern(_ message: String) {
        patternNotice.stringValue = message
        fieldGrid?.row(at: 1).isHidden = false
        queryField.toolTip = message
        queryField.setAccessibilityHelp(message)
    }
    private func clearPatternMark() {
        guard fieldGrid?.row(at: 1).isHidden == false else { return }
        patternNotice.stringValue = ""
        fieldGrid?.row(at: 1).isHidden = true
        queryField.toolTip = nil
        queryField.setAccessibilityHelp(nil)
    }
    var patternIsMarked: Bool { fieldGrid?.row(at: 1).isHidden == false }
    @objc private func scopeChanged(_ sender: Any?) { updateReplaceAllAvailability() }
    func windowDidUpdate(_ notification: Notification) { updateReplaceAllAvailability() }
    /// What a search for the current fields, options, scope and documents would be a search of.
    /// Reads no document text.
    private func currentSearchIdentity() -> EmptySearch {
        let scopeIndex = selectedScope
        let editors = scopeIndex == .allOpenDocuments ? openEditors() : currentEditor().map { [$0] } ?? []
        let flags = sharedOptions(query: "", replacement: "")
        return EmptySearch(
            query: Array(queryField.stringValue.utf8), mode: flags.mode, matchCase: flags.matchCase,
            wholeWord: flags.wholeWord, dotMatchesNewline: flags.dotMatchesNewline, scope: scopeIndex,
            documents: editors.map {
                EmptySearch.Document(
                    editor: ObjectIdentifier($0), revision: $0.revision,
                    selection: scopeIndex == .selection
                        ? NSRange(location: $0.selectionStart, length: $0.selectionEnd - $0.selectionStart) : nil)
            })
    }
    /// DS-21: Replace All is not offered for a search already known to find nothing. Editing the
    /// Find text, an option, the scope or a document offers it again.
    func updateReplaceAllAvailability() {
        guard !searchButtons.isEmpty else { return }
        if let known = emptySearch, known != currentSearchIdentity() { emptySearch = nil }
        let offered = emptySearch == nil
        replaceAllButton.toolTip =
            offered ? nil : "The last search found no matches. Change the Find text, an option or the document."
        if !isSearching, replaceAllButton.isEnabled != offered { replaceAllButton.isEnabled = offered }
    }
    private func noteCount(_ matches: Int, truncated: Bool) {
        emptySearch = matches == 0 && !truncated ? searchIdentity : nil
    }
    private func showPanel(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(queryField)
    }
    @objc private func advancedFlagsChanged(_ sender: NSControl) {
        clearPatternMark()
        updateReplaceAllAvailability()
        sharedFlagsChanged?()
    }
    enum InlineFlag { case matchCase, wholeWord, regex }
    func setInlineFlag(_ flag: InlineFlag, enabled: Bool) {
        switch flag {
        case .matchCase: caseButton.state = enabled ? .on : .off
        case .wholeWord: wordButton.state = enabled ? .on : .off
        case .regex:
            let desired: SearchOptions.Mode = enabled ? .regularExpression : .normal
            mode.selectItem(at: mode.indexOfItem(withRepresentedObject: String(desired.rawValue)))
        }
        clearPatternMark()
        updateReplaceAllAvailability()
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
    /// A search enters the history once it has run: its text, and its replacement when the
    /// action replaces. A search refused before it started, or one whose expression did not
    /// compile, is not remembered.
    private func rememberRan(_ o: SearchOptions, _ action: Action) {
        remember(
            query: o.query, replacement: action == .replaceOne || action == .replaceAll ? o.replacement : nil)
    }
    private func readOptions() -> SearchOptions {
        // Commit the shared field editor before reading distinct window fields.
        window?.makeFirstResponder(nil)
        let o = sharedOptions(query: queryField.stringValue, replacement: replacementField.stringValue)
        setSharedQuery(o.query, from: self)
        setSharedReplacement(o.replacement, from: self)
        savePreferences(o)
        options = o
        shareFindPasteboard(o.query)
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
            applyStartingPreferences()
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
    /// The outcome is announced by this window's status label; the row only loses its indicator.
    /// Also called when a new search replaces one that is still running.
    private func endStatusOperation() {
        guard let id = statusOperation else { return }
        statusOperation = nil
        StatusOperationCenter.shared.end(id)
    }
    private func finish() {
        endStatusOperation()
        searchButtons.forEach { $0.isEnabled = true }
        cancellation = nil
        task = nil
        isSearching = false
        appliedReplace = nil
        updateReplaceAllAvailability()
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
        searchIdentity = currentSearchIdentity()
        // A document above the engine's limit is searched as bytes, on its own.
        if scopeIndex == .allOpenDocuments {
            if let large = editors.first(where: { isLargeDocument($0) }) {
                report(SearchFailure.largeDocumentAllOpen(EditorLifetime.title(large)), audible: navigating)
                return
            }
        } else if let editor = editors.first, let data = largeSnapshot(of: editor) {
            runLarge(action, options: opts, editor: editor, data: data, selectionScope: selectionScope)
            return
        }
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
            rememberRan(opts, action)
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
        endStatusOperation()
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
                self.rememberRan(opts, action)
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
                self.report(error, audible: navigating)
                self.finish()
            }
        }
    }
    /// A search that could not run or finish. An expression that does not compile also marks the
    /// Find field, in full, until the expression or the mode changes (DS-45).
    private func report(_ error: Error, audible: Bool) {
        if TTSearchEngine.invalidPattern(error as NSError) { markPattern(error.localizedDescription) }
        if let failure = error as? SearchFailure, failure == .macroResultLimit {
            fail(
                "Result limit reached; replacements were not applied. Narrow the scope.", .limitReached, audible: false)
            return
        }
        fail(error.localizedDescription, .failed(error.localizedDescription), audible: audible)
    }
    /// Why a search step in a large document is left out of a macro recording: it could not be
    /// replayed, because playback is synchronous and a large search must not hold the window.
    static let largeUnrecordable = "Searches in a document this large are not recorded in macros."
    /// Whether the document is longer than `largeDocumentUnits` UTF-16 units. Its byte length
    /// settles most cases with no copy: at or under the limit in bytes it cannot be, and above
    /// three times the limit it must be. Between the two the bytes are copied once and counted
    /// without decoding, and the answer is kept for that revision of that document, so asking
    /// again (every press, every open document) copies nothing.
    func isLargeDocument(_ editor: TTEditor) -> Bool {
        let limit = largeDocumentUnits, bytes = editor.byteLength
        if bytes <= limit { return false }
        if bytes / 3 > limit { return true }
        let id = ObjectIdentifier(editor), revision = editor.revision
        if let known = largeDecisions[id], known.editor === editor, known.revision == revision, known.limit == limit {
            return known.large
        }
        largeDecisionCopies += 1
        let large = autoreleasepool { SearchCore.isLarge(editor.utf8Data, limit: limit) }
        largeDecisions = largeDecisions.filter { $0.value.editor != nil }
        largeDecisions[id] = LargeDecision(editor: editor, revision: revision, limit: limit, large: large)
        return large
    }
    /// The document's bytes when it is large, else nil. The copy lives exactly as long as the
    /// search that holds it, whatever autorelease pool the caller has.
    func largeSnapshot(of editor: TTEditor) -> Data? {
        isLargeDocument(editor) ? autoreleasepool { editor.utf8Data } : nil
    }
    static func isLargeDocument(_ editor: TTEditor, limit: Int = SearchCore.maximumTextUnits) -> Bool {
        let bytes = editor.byteLength
        if bytes <= limit { return false }
        if bytes / 3 > limit { return true }
        return autoreleasepool { SearchCore.isLarge(editor.utf8Data, limit: limit) }
    }
    private enum LargeResult: Sendable {
        case count(Int, truncated: Bool)
        case effect(SearchSession.ByteEffect)
        /// Replace found that the selection is not a match and looked for the next match instead.
        case nextInstead(SearchSession.ByteEffect)
    }
    private nonisolated static func name(of action: Action) -> String {
        switch action {
        case .previous: return "previous"
        case .replaceOne: return "replaceOne"
        case .replaceAll: return "replaceAll"
        default: return "next"
        }
    }
    /// Off the main thread, over the immutable bytes. Normal and Extended text is searched in
    /// windows. A regular expression is searched only in a selection that fits the snapshot
    /// engine: the selected bytes are decoded on their own, so the expression sees the selection
    /// as the whole text, and its matches are moved back to their byte positions in the document.
    private nonisolated static func computeLarge(
        _ action: Action, data: Data, options: SearchOptions, selection: NSRange, scope: NSRange?, freshScope: Bool,
        continuing: Bool, chunkBytes: Int, cancellation: TTSearchCancellation,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) throws -> LargeResult {
        let search = SearchSession.ByteSearch(chunkBytes: chunkBytes, cancellation: cancellation, progress: progress)
        if options.mode == .regularExpression {
            guard let scope else { throw SearchFailure.largeDocumentRegex }
            guard let text = String(data: data.subdata(in: scope.location..<NSMaxRange(scope)), encoding: .utf8) else {
                throw SearchFailure.positionMapping
            }
            let report = try SearchCore.search(
                text, options: options, cancellation: cancellation,
                purpose: action == .all || action == .replaceAll ? .allMatches : .navigation)
            guard let ranges = SearchCore.byteRanges(report.hits.map(\.range), in: text) else {
                throw SearchFailure.positionMapping
            }
            let hits = zip(ranges, report.hits).map {
                ByteSearchHit(
                    range: NSRange(location: $0.0.location + scope.location, length: $0.0.length),
                    replacement: $0.1.replacement)
            }
            if action == .all { return .count(hits.count, truncated: report.truncated) }
            guard !report.truncated else { throw SearchFailure.macroResultLimit }
            return .effect(
                try SearchSession.plan(
                    byteHits: hits, options: options, action: name(of: action), selection: selection,
                    freshScope: freshScope, continuing: continuing))
        }
        if action == .all {
            let total = scope?.length ?? data.count
            let report = try SearchCore.searchBytes(
                data, options: options, range: scope, chunkBytes: chunkBytes, cancellation: cancellation,
                progress: { progress($0, total) })
            return .count(report.hits.count, truncated: report.truncated)
        }
        let effect = try SearchSession.planBytes(
            data, options: options, action: name(of: action), selection: selection, scope: scope,
            freshScope: freshScope, search: search)
        if action == .replaceOne, effect == .noMatch, scope == nil {
            return .nextInstead(
                try SearchSession.planBytes(
                    data, options: options, action: "next", selection: selection, search: search))
        }
        return .effect(effect)
    }
    /// Progress of a large-document search. It ends with an ellipsis, so the status label shows
    /// it without announcing every step (DS-51, DS-72).
    private func showProgress(_ done: Int, of total: Int, token: UUID) {
        guard generation == token, isSearching, appliedReplace == nil, total > 0 else { return }
        progressReports += 1
        status.stringValue = "Searching, \(Strings.number(min(100, done * 100 / total)))%…"
        if let statusOperation { StatusOperationCenter.shared.update(statusOperation, done: done, total: total) }
    }
    /// Current document and Selection scope in a document above the engine's limit. Next and
    /// Previous go to the nearest match without listing the rest; Find All / Count counts without
    /// listing; Replace and Replace All are each one Undo step. Marks and bookmarks are refused.
    private func runLarge(
        _ action: Action, options opts: SearchOptions, editor: TTEditor, data: Data, selectionScope: Bool
    ) {
        let navigating = action == .next || action == .previous
        guard action != .mark, action != .bookmark else {
            report(SearchFailure.largeDocumentAction, audible: false)
            return
        }
        let revision = editor.revision, anchor = editor.selectionAnchor, caret = editor.selectionCaret
        let selection = NSRange(location: editor.selectionStart, length: editor.selectionEnd - editor.selectionStart)
        var chosenScope: NSRange?, firstPress = false
        if selectionScope {
            guard editor.selectionCount == 1 else {
                fail("Select one nonempty range first.", .needsInput, audible: navigating)
                return
            }
            // F35, in bytes: after Next or Previous has moved the selection onto a match, the
            // scope is the range remembered from the first press.
            if navigating, let last = largeNavigation, last.editor === editor, last.revision == revision,
                last.range == selection, let kept = largeScope, kept.editor === editor, kept.revision == revision
            {
                chosenScope = kept.range
            } else {
                guard selection.length > 0 else {
                    fail("Select one nonempty range first.", .needsInput, audible: navigating)
                    return
                }
                chosenScope = selection
                if navigating {
                    largeScope = Navigation(editor: editor, revision: revision, range: selection, from: nil)
                    firstPress = true
                }
            }
        } else {
            largeScope = nil
        }
        let scope = chosenScope, freshScope = firstPress
        if opts.mode == .regularExpression {
            guard let scope else {
                report(SearchFailure.largeDocumentRegex, audible: navigating)
                return
            }
            guard scope.length <= largeDocumentUnits else {
                report(SearchFailure.largeSelectionRegex, audible: navigating)
                return
            }
        }
        let continuing =
            largeNavigation.map { $0.editor === editor && $0.revision == revision && $0.range == selection } ?? false
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
        let chunk = largeChunkBytes
        let replacing = action == .replaceAll || action == .replaceOne
        endStatusOperation()
        statusOperation = StatusOperationCenter.shared.begin(
            replacing ? "Replacing in the document" : "Searching the document", in: editor,
            cancelLabel: replacing ? "Cancel replacing" : "Cancel search"
        ) { [weak self] in self?.cancel(nil) }
        // Each step hops to the main actor on its own, and nothing orders those hops before the
        // result's. The newest step is therefore also kept here and shown when the result arrives,
        // so a finished search has always shown the progress it made.
        let newest = LatestProgress()
        let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            newest.set(done, total)
            Task { @MainActor in self?.showProgress(done, of: total, token: token) }
        }
        task = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.computeLarge(
                        action, data: data, options: opts, selection: selection, scope: scope, freshScope: freshScope,
                        continuing: continuing, chunkBytes: chunk, cancellation: flag, progress: progress)
                }.value
                guard let self, self.generation == token, !flag.cancelled else { return }
                if let last = newest.value { self.showProgress(last.done, of: last.total, token: token) }
                self.rememberRan(opts, action)
                // G372: the editor stayed editable while the search ran. A result for text or a
                // selection that has since changed, or for an editor that is no longer current,
                // selects and replaces nothing.
                guard EditorLifetime.isOpen(editor), editor.revision == revision, self.currentEditor() === editor,
                    editor.selectionAnchor == anchor, editor.selectionCaret == caret
                else {
                    self.fail("Result is stale; search again. Selection unchanged.", .staleResult, audible: navigating)
                    self.onUnrecordableCommand?(
                        "The document changed while the search was running; the search step was not recorded.")
                    self.finish()
                    return
                }
                let replaced = self.completeLarge(
                    result, action: action, options: opts, editor: editor, revision: revision,
                    recorded: !selectionScope)
                if replaced {
                    // F45: a single Replace then moves to the next match, in the text as it is now.
                    let after = autoreleasepool { editor.utf8Data }, afterRevision = editor.revision
                    let from = NSRange(
                        location: editor.selectionStart, length: editor.selectionEnd - editor.selectionStart)
                    let done = self.status.stringValue, outcome = self.lastOutcome
                    self.appliedReplace = (done, outcome)
                    let next = try? await Task.detached(priority: .userInitiated) {
                        try SearchSession.planBytes(
                            after, options: opts, action: "next", selection: from,
                            search: SearchSession.ByteSearch(chunkBytes: chunk, cancellation: flag))
                    }.value
                    guard self.generation == token, !flag.cancelled else { return }
                    if editor.revision != afterRevision || !EditorLifetime.isOpen(editor) {
                        self.status.stringValue = done + " The document changed before the next match was selected."
                    } else if case .select(let bytes)? = next, Self.selectResult(bytes, in: editor) {
                        self.largeNavigation = Navigation(
                            editor: editor, revision: afterRevision, range: bytes, from: self.currentEditor())
                        self.status.stringValue = done + " Selected the next match."
                    } else if next == .noMatch {
                        self.status.stringValue = done + " No further matches."
                    }
                    self.lastOutcome = outcome
                }
                self.finish()
            } catch {
                guard let self, self.generation == token else { return }
                self.report(error, audible: navigating)
                self.finish()
            }
        }
    }
    /// Applies a finished large-document search. True when a single Replace was applied and the
    /// next match should now be selected.
    private func completeLarge(
        _ result: LargeResult, action: Action, options opts: SearchOptions, editor: TTEditor, revision: UInt,
        recorded: Bool
    ) -> Bool {
        let effect: SearchSession.ByteEffect
        var insteadOfReplace = false
        switch result {
        case .count(let count, let truncated):
            status.stringValue =
                Self.foundStatus(count, 1, truncated)
                + " Matches in a document this large are not listed. Use Next and Previous to go to them."
            lastOutcome = .found(matches: count, documents: 1, truncated: truncated)
            noteCount(count, truncated: truncated)
            return false
        case .effect(let planned): effect = planned
        case .nextInstead(let planned):
            effect = planned
            insteadOfReplace = true
        }
        switch effect {
        case .noMatch:
            switch action {
            case .replaceAll:
                lastReplaceSkips = ReplaceSkips()
                status.stringValue = Self.replacedStatus(changed: 0, skips: ReplaceSkips())
                lastOutcome = .replaced(changed: 0, stale: 0)
                noteCount(0, truncated: false)
            case .replaceOne where !insteadOfReplace:
                fail("No match is selected; use Next first.", .noMatchSelected, audible: false)
            default:
                fail("No further matches.", .noFurtherMatches, audible: action != .replaceOne)
            }
        case .select(let bytes):
            guard Self.selectResult(bytes, in: editor) else {
                fail("Result is stale; search again. Selection unchanged.", .staleResult, audible: true)
                return false
            }
            largeNavigation = Navigation(editor: editor, revision: revision, range: bytes, from: currentEditor())
            if !EditorLifetime.isVisible(editor) { EditorLifetime.activate(editor) }
            status.stringValue =
                insteadOfReplace ? "Selected the next match; press Replace again to replace it." : "Selected a match."
            lastOutcome = insteadOfReplace ? .selectedNextMatch : .movedToMatch
            if recorded { onUnrecordableCommand?(Self.largeUnrecordable) }
        case .replace(let hits):
            let all = action == .replaceAll
            let capture = all ? BulkChangeCapture(editor, name: "Replace All") : nil
            let priorName = editor.exchangeNextUndoName(all ? "Replace All" : "Replace")
            defer { _ = editor.exchangeNextUndoName(priorName) }
            var changed = 0, skips = ReplaceSkips()
            switch Self.replace(bytes: hits, revision: revision, in: editor) {
            case .applied(let count):
                changed = count
                capture?.finish()
            case .readOnly: skips.readOnly = 1
            case .multipleSelections: skips.multipleSelections = 1
            case .closed: skips.closed = 1
            case .stale: skips.stale = 1
            }
            lastReplaceSkips = skips
            status.stringValue = Self.replacedStatus(changed: changed, skips: skips)
            lastOutcome = .replaced(changed: changed, stale: skips.total)
            if changed > 0, skips.total == 0 {
                if recorded { onUnrecordableCommand?(Self.largeUnrecordable) }
                return !all && recorded
            }
        }
        return false
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
        noteCount(rows.count, truncated: truncated)
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
                let capture =
                    action == .replaceAll && !chosen.isEmpty ? BulkChangeCapture(editor, name: "Replace All") : nil
                let priorName = editor.exchangeNextUndoName(action == .replaceAll ? "Replace All" : "Replace")
                defer { _ = editor.exchangeNextUndoName(priorName) }
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
        let revision = editor.revision
        let matched: Bool
        do {
            // Playback is synchronous. A search of a document above the engine's limit takes
            // seconds and must not hold the window, so the step is refused in words before the
            // document is read; such searches are not recorded either.
            if isLargeDocument(editor) {
                throw SearchFailure.largeDocumentMacro
            } else {
                let text = editor.text
                let report = try SearchCore.search(
                    text, options: options, timeLimit: timeLimit,
                    purpose: action == "replaceAll" ? .allMatches : .navigation)
                matched = try applySingleReport(
                    report, text: text, revision: revision, options: options, action: action, in: editor)
            }
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
        if isLargeDocument(editor) { throw SearchFailure.largeDocumentMacro }
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
        isCurrent: @escaping () -> Bool, progress: (@Sendable (Int, Int) -> Void)? = nil,
        completion: @escaping (InlineSearchOutcome) -> Void
    ) {
        // Above the engine's limit the document is searched as bytes; nothing is decoded whole.
        let large = largeSnapshot(of: editor), chunk = largeChunkBytes
        let selection = NSRange(location: editor.selectionStart, length: editor.selectionEnd - editor.selectionStart)
        let text = large == nil ? editor.text : "", revision = editor.revision, selections = editor.selectionRanges
        let anchor = editor.selectionAnchor, caret = editor.selectionCaret
        let targetDocumentID = EditorLifetime.document(for: editor)?.runtimeID
        let window = editor.window
        Task { @MainActor [weak self, weak editor, weak window] in
            do {
                let found = try await Task.detached(priority: .userInitiated) { () throws -> InlineFound in
                    if let large {
                        return .bytes(
                            try SearchSession.planBytes(
                                large, options: options, action: action, selection: selection,
                                search: SearchSession.ByteSearch(
                                    chunkBytes: chunk, cancellation: cancellation, progress: progress)))
                    }
                    return .report(
                        try SearchCore.search(
                            text, options: options, cancellation: cancellation,
                            purpose: action == "replaceAll" ? .allMatches : .navigation))
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
                let matched: Bool, replaced: Int
                switch found {
                case .report(let report):
                    matched = try self.applySingleReport(
                        report, text: text, revision: revision, options: options, action: action, in: editor)
                    replaced = report.hits.count
                case .bytes(let effect):
                    matched = try Self.apply(effect, revision: revision, in: editor)
                    if case .replace(let hits) = effect { replaced = hits.count } else { replaced = 0 }
                }
                if matched && action == "replaceAll" {
                    completion(.replacedAll(replaced))
                } else {
                    completion(matched ? .applied : .noMatch)
                }
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
    private enum InlineFound: Sendable {
        case report(SearchReport)
        case bytes(SearchSession.ByteEffect)
    }
    /// Applies what was planned for a document searched as bytes, by the rules applySingleReport
    /// uses: a closed or changed document selects and replaces nothing.
    private static func apply(_ effect: SearchSession.ByteEffect, revision: UInt, in editor: TTEditor) throws -> Bool {
        guard EditorLifetime.isOpen(editor), editor.revision == revision else {
            throw Self.recordedSearchStopped("the document changed or selection is not on a character boundary")
        }
        switch effect {
        case .noMatch: return false
        case .select(let bytes):
            guard Self.selectResult(bytes, in: editor) else {
                throw Self.recordedSearchStopped("the match could not be selected")
            }
            return true
        case .replace(let hits):
            let condition: SearchFailure.ReplacementCondition
            switch Self.replace(bytes: hits, revision: revision, in: editor) {
            case .applied: return true
            case .readOnly: condition = .readOnly
            case .multipleSelections: condition = .multipleSelections
            case .closed: condition = .closed
            case .stale: condition = .stale
            }
            throw condition
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
            guard Self.selectResult(bytes, in: editor) else {
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
        /// The whole document was searched and holds no match (DS-21: Replace All is then disabled).
        var foundNothing: Bool { highlights.isEmpty && countText == "No matches" }
    }
    /// The live count in a document above the engine's limit: the same 256-match paint set and
    /// count wording, found by the windowed byte search. Nothing is decoded whole.
    private nonisolated static func previewBytes(
        _ snapshot: Data, options: SearchOptions, openingCaret: Int, chunkBytes: Int,
        cancellation: TTSearchCancellation
    ) throws -> InlinePreview {
        let limit = 256
        let report = try SearchCore.searchBytes(
            snapshot, options: options, limit: limit, chunkBytes: chunkBytes, cancellation: cancellation)
        let ranges = report.hits.map(\.range)
        var selected = ranges.first { $0.location >= openingCaret }
        if report.truncated && selected == nil {
            let tail = NSRange(location: openingCaret, length: snapshot.count - openingCaret)
            selected = try SearchCore.searchBytes(
                snapshot, options: options, range: tail, limit: 1, stopAtLimit: true, chunkBytes: chunkBytes,
                cancellation: cancellation
            ).hits.first?.range
        }
        guard !cancellation.cancelled else { throw CancellationError() }
        if selected == nil && options.wrap { selected = ranges.first }
        var visible = ranges
        if let selected, !visible.contains(selected) {
            visible.removeLast()
            visible.append(selected)
        }
        let count: String
        if report.truncated {
            count = "\(limit)+ matches"
        } else if let selected, let i = ranges.firstIndex(of: selected) {
            count = "\(i + 1) of \(ranges.count)"
        } else {
            count = ranges.isEmpty ? "No matches" : "\(ranges.count) matches"
        }
        return InlinePreview(highlights: visible, selected: selected, countText: count)
    }
    /// Read-only. Range conversion and searching operate only on the immutable editor snapshot.
    nonisolated static func preview(
        _ snapshot: Data, options: SearchOptions, openingCaret: Int,
        cancellation: TTSearchCancellation,
        unitLimit: Int = SearchCore.maximumTextUnits,
        chunkBytes: Int = SearchCore.largeChunkBytes
    ) throws -> InlinePreview {
        guard !cancellation.cancelled else { throw CancellationError() }
        guard (0...snapshot.count).contains(openingCaret),
            openingCaret == snapshot.count || snapshot[snapshot.startIndex + openingCaret] & 0xc0 != 0x80
        else { throw SearchFailure.positionMapping }
        if SearchCore.isLarge(snapshot, limit: unitLimit) {
            return try previewBytes(
                snapshot, options: options, openingCaret: openingCaret, chunkBytes: chunkBytes,
                cancellation: cancellation)
        }
        guard let text = String(data: snapshot, encoding: .utf8) else { throw SearchFailure.positionMapping }
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
            let tail = NSRange(
                location: utf16.distance(from: utf16.startIndex, to: start),
                length: utf16.distance(from: start, to: utf16.endIndex))
            let remaining = try SearchCore.search(
                text, options: options, range: tail, cancellation: cancellation, limit: 1)
            if let hit = remaining.hits.first { selected = try bytes(hit.range) }
        }
        guard !cancellation.cancelled else { throw CancellationError() }
        if selected == nil && options.wrap { selected = ranges.first }
        var visible = ranges
        if let selected, !visible.contains(selected) {
            visible.removeLast()
            visible.append(selected)
        }
        let count: String
        if report.truncated {
            count = "\(limit)+ matches"
        } else if let selected, let i = ranges.firstIndex(of: selected) {
            count = "\(i + 1) of \(ranges.count)"
        } else {
            count = ranges.isEmpty ? "No matches" : "\(ranges.count) matches"
        }
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
    /// The one place a search selects a match. A tab that shows Preview alone shows its source
    /// first, without the keyboard moving, so the selection is never made out of sight.
    private static func selectResult(_ bytes: NSRange, in editor: TTEditor) -> Bool {
        guard editor.setSelectionAnchor(bytes.location, caret: NSMaxRange(bytes)) else { return false }
        EditorLifetime.revealSource(of: editor)
        return true
    }
    static func replace(_ hits: [SearchHit], text: String, revision: UInt, in editor: TTEditor) -> ReplaceOutcome {
        guard EditorLifetime.isOpen(editor) else { return .closed }
        guard !editor.readOnly else { return .readOnly }
        guard editor.revision == revision else { return .stale }
        guard editor.selectionCount == 1 else { return .multipleSelections }
        guard !hits.isEmpty else { return .applied(0) }
        // The selection is not the edit cursor (G374): it is carried through the replacements, and
        // Undo returns to the selection the command began with.
        guard let ranges = SearchCore.byteRanges(hits.map(\.range), in: text) else { return .stale }
        return replace(
            bytes: zip(ranges, hits).map { ByteSearchHit(range: $0.0, replacement: $0.1.replacement) },
            revision: revision, in: editor)
    }
    /// The same replacement for matches already held as byte ranges (ascending, not overlapping).
    static func replace(bytes hits: [ByteSearchHit], revision: UInt, in editor: TTEditor) -> ReplaceOutcome {
        guard EditorLifetime.isOpen(editor) else { return .closed }
        guard !editor.readOnly else { return .readOnly }
        guard editor.revision == revision else { return .stale }
        guard editor.selectionCount == 1 else { return .multipleSelections }
        guard !hits.isEmpty else { return .applied(0) }
        let anchor = editor.selectionAnchor, caret = editor.selectionCaret
        guard
            editor.replaceSearchRanges(
                hits.map { TTByteRange(location: $0.range.location, length: $0.range.length) },
                withTexts: hits.map(\.replacement), expectedRevision: revision)
        else { return .stale }
        let edits = hits.map { SearchSession.Edit(range: $0.range, replacementBytes: $0.replacement.utf8.count) }
        let carried = SearchSession.carriedSelection(anchor: anchor, caret: caret, edits: edits)
        _ = editor.setSelectionAnchor(carried.anchor, caret: carried.caret)
        // The text changed: show where, as for a selected match.
        EditorLifetime.revealSource(of: editor)
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
            Self.selectResult(range, in: editor)
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
