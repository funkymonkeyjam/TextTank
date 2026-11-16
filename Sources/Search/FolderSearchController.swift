import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Coalesces worker progress before scheduling main-thread work.
private final class FolderProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func admit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.1 else { return false }
        last = now
        return true
    }
}

/// What the last Find-in-Folder action did, set wherever the status line is set.
enum FolderSearchOutcome: Equatable {
    case needsInput
    case searched(matches: Int, filesSearched: Int, skipped: Int, cancelled: Bool, limitReached: Bool)
    case replaced(replaced: Int, notReplaced: Int)
    case noReplacementReport
    case staleResult
    case failed(String)
}

final class FolderSearchController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Scope: Int, CaseIterable { case chosenFolder, workspaceFolders }
    private var selectedScope: Scope {
        ControlPresentation.selectedID(scope).flatMap(Int.init).flatMap(Scope.init(rawValue:)) ?? .chosenFolder
    }
    let queryField = NSTextField(), extensionField = NSTextField(), replacementField = NSTextField(),
        filterField = NSTextField()
    var workspaceRoots: () -> [URL] = { [] }
    var displayTabWidth: () -> Int = { 4 }
    let scope = NSPopUpButton()
    let hiddenButton = NSButton(checkboxWithTitle: "Include hidden files/folders", target: nil, action: nil)
    let preferenceNotice = AnnouncingLabel(labelWithString: "")
    let resetPreferencesButton = NSButton(title: "Reset Saved Settings…", target: nil, action: nil)
    private let preferences: JSONFileStore<FolderSearchSettings>
    let mode = NSPopUpButton()
    let wordButton = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    let dotButton = NSButton(checkboxWithTitle: "Dot matches newline", target: nil, action: nil)
    let caseButton = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let recursiveButton = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
    let folderLabel = NSTextField(labelWithString: "Choose a folder to search")
    let status = AnnouncingLabel(
        labelWithString: "Normal / Extended / Regular expression (Boost) · UTF-8/UTF-16 · symlinks skipped")
    let table = ActivatingTableView(), details = NSTextView()
    private var folder: URL?
    private var searchedFolder: URL?
    private var replaceButton: NSButton!
    private(set) var lastReplacementOutcomes: [FolderReplacementOutcome] = []
    private var matches: [FolderSearchMatch] = []
    private var searchedOptions = SearchOptions()
    /// True from the confirmation of Replace Matched Files until its report is shown or the
    /// window closes. A new search is refused meanwhile: starting one cancels the shared flag.
    private var replacing = false
    /// Asks before any file is changed. Replaceable so that checks need no modal alert.
    var confirmReplacement: (_ explanation: String) -> Bool = { explanation in
        let alert = TTAlert()
        alert.messageText = "Replace Matched Files?"
        alert.informativeText = explanation
        let replace = alert.addButton(withTitle: "Replace Files")
        replace.identifier = NSUserInterfaceItemIdentifier("folder.replace.confirm")
        // Files on disk change and editor Undo does not reach them, so Return is Cancel here.
        replace.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel", role: .cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Passed to FolderReplacement as `beforeCommit`; nil in the app. Runs on the worker.
    var replacementBeforeCommit: (@Sendable (URL) -> Void)?
    /// Opens a result's file as a document. Replaceable so that checks show no window.
    var openResultDocument: (URL, @escaping (NSDocument?, Error?) -> Void) -> Void = { url, completion in
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            completion(document, error)
        }
    }
    /// At most this many not-searched entries are written to the details view.
    static let maximumListedProblems = 200
    private var generation = UUID()
    private var cancellation: FolderSearchCancellation?
    private var work: Task<Void, Never>?
    private var searchButton: NSButton!, cancelButton: NSButton!
    /// True while a search or a replacement is running.
    private(set) var isSearching = false
    /// Nil while work is running and before the first action.
    private(set) var lastOutcome: FolderSearchOutcome?
    /// Called with the reason when opening a result moved the caret, which macros cannot record (F277).
    var onUnrecordableCommand: ((String) -> Void)?

    init(defaults: UserDefaults? = nil, preferencesURL: URL? = nil) {
        let legacy = defaults ?? RuntimeEnvironment.legacyDefaults
        preferences = JSONFileStore(
            url: preferencesURL ?? AppStorage.url(.folderSearch), displayName: "Find in Folder settings",
            maximumBytes: FolderSearchSettings.maximumBytes, initial: FolderSearchSettings(),
            decode: FolderSearchSettings.decode,
            encode: { try $0.encoded() },
            legacyValue: {
                guard let legacy else { return nil }
                return try FolderSearchSettings.load(legacy)
            })
        // A panel, so the document window stays main while Find in Folder is key. It stays on
        // screen when the application is deactivated: a long search keeps its results visible.
        let window = ToolPanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable])
        super.init(window: window)
        // Closing stops running work, so Escape closes this window only while it is idle.
        window.allowsEscapeToClose = { [weak self] in self?.isSearching != true }
        window.title = "Find in Folder"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 480)
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder(_:)))
        searchButton = NSButton(title: "Search", target: self, action: #selector(startSearch(_:)))
        replaceButton = NSButton(
            title: "Replace Matched Files…", target: self, action: #selector(replaceMatchedFiles(_:)))
        replaceButton.isEnabled = false
        replacementField.placeholderString = "Replacement (same mode as completed search)"
        cancelButton = NSButton(title: "Stop", target: self, action: #selector(cancelSearch(_:)))
        cancelButton.isEnabled = false
        ControlPresentation.populate(
            mode, choices: SearchOptions.Mode.allCases.map { (String($0.rawValue), $0.displayName) }, selected: "0")
        ControlPresentation.populate(
            scope, choices: [("0", "Chosen Folder"), ("1", "Workspace Folders")], selected: "0")
        scope.target = self
        scope.action = #selector(scopeChanged(_:))
        filterField.placeholderString = "Filename filters: *.swift *.txt !*Tests* !+\\build"
        filterField.toolTip =
            "Space-separated include globs; !pattern excludes files; !\\folder excludes root-child folders; !+\\folder excludes folders at every depth. Quote names with spaces."
        queryField.placeholderString = "Search expression"
        extensionField.placeholderString = "Extensions: txt, swift (blank = all)"
        queryField.target = self
        queryField.action = #selector(startSearch(_:))
        recursiveButton.state = .on
        caseButton.state = .on
        folderLabel.lineBreakMode = .byTruncatingMiddle
        let location = NSStackView(views: [scope, choose, folderLabel])
        let options = NSStackView(views: [caseButton, recursiveButton, extensionField, searchButton, cancelButton])
        options.spacing = 8
        let semantics = NSStackView(views: [mode, wordButton, dotButton, hiddenButton])
        let history = NSButton(title: "Replacement Report", target: self, action: #selector(showReplacementReport(_:)))
        let replacements = NSStackView(views: [replacementField, replaceButton, history])
        for (id, title, width) in [
            ("file", "File", 300.0), ("line", "Line:Column", 100.0), ("preview", "Preview", 500.0)
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openResult(_:))
        // Return on the selected row does what a double-click on it does.
        table.onActivate = { [weak self] row in self?.openResult(at: row) }
        table.setAccessibilityLabel("Folder search results")
        table.toolTip = "Columns use the default tab width captured when the search started."
        for (control, label) in [
            (queryField as NSView, "Find in folder"), (replacementField, "Replace matches in files with"),
            (mode, "Folder search mode"), (scope, "Folder search scope"), (extensionField, "Filename extensions"),
            (filterField, "Filename filters")
        ] { control.setAccessibilityLabel(label) }
        table.usesAlternatingRowBackgroundColors = true
        let results = NSScrollView()
        results.documentView = table
        results.hasVerticalScroller = true
        results.hasHorizontalScroller = true
        details.isEditable = false
        details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let detailScroll = NSScrollView()
        detailScroll.documentView = details
        detailScroll.hasVerticalScroller = true
        details.autoresizingMask = [.width]
        details.isVerticallyResizable = true
        resetPreferencesButton.target = self
        resetPreferencesButton.action = #selector(resetSavedPreferences(_:))
        resetPreferencesButton.setAccessibilityLabel("Reset saved Find in Folder settings")
        preferenceNotice.setAccessibilityLabel("Saved Find in Folder settings status")
        preferenceNotice.lineBreakMode = .byWordWrapping
        preferenceNotice.maximumNumberOfLines = 2
        let preferenceSpacer = NSView()
        preferenceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        resetPreferencesButton.setContentHuggingPriority(.required, for: .horizontal)
        let preferenceRow = NSStackView(views: [preferenceNotice, preferenceSpacer, resetPreferencesButton])
        preferenceRow.spacing = 8
        preferenceNotice.isHidden = preferences.state.error == nil
        let root = NSStackView(views: [
            location, queryField, replacements, filterField, semantics, options, preferenceRow, status, results,
            detailScroll
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = root
        for view in [
            location, queryField, replacements, filterField, semantics, options, preferenceRow, status, results,
            detailScroll
        ] { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true }
        detailScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        results.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        extensionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        applySavedPreferences(preferences.value)
        if let error = preferences.state.error { showPreferenceFailure(error) }
        window.initialFirstResponder = queryField
        WindowFrames.track(window, as: "TextTank.FindInFolder")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    @objc func showSearch(_ sender: Any?) {
        updateFolderLabel()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        // Also on reopening, when the window would otherwise keep whatever had focus last.
        window?.makeFirstResponder(queryField)
    }
    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        scope.selectItem(at: 0)
        updateFolderLabel()
        savePreferencesOrReport()
    }
    @objc private func scopeChanged(_ sender: Any?) {
        updateFolderLabel()
        savePreferencesOrReport()
    }
    private func updateFolderLabel() {
        folderLabel.stringValue =
            selectedScope == .workspaceFolders
            ? Strings.count(workspaceRoots().count, .folder) : folder?.path ?? "Choose a folder to search"
    }
    /// Native setting capture is inert and commits the shared field editor first.
    func saveSettings() throws {

        window?.makeFirstResponder(nil)
        var value = FolderSearchSettings()
        value.folder = folder
        value.workspaceScope = selectedScope == .workspaceFolders
        value.recursive = recursiveButton.state == .on
        value.includeHidden = hiddenButton.state == .on
        value.extensions = extensionField.stringValue
        value.filters = filterField.stringValue
        value.options.query = queryField.stringValue
        value.options.replacement = replacementField.stringValue
        value.options.mode =
            ControlPresentation.selectedID(mode).flatMap(Int.init).flatMap(SearchOptions.Mode.init(rawValue:))
            ?? .normal
        value.options.matchCase = caseButton.state == .on
        value.options.wholeWord = wordButton.state == .on
        value.options.dotMatchesNewline = dotButton.state == .on
        try preferences.save(value)
    }
    private func applySavedPreferences(_ settings: FolderSearchSettings) {
        folder = settings.folder
        scope.selectItem(at: scope.indexOfItem(withRepresentedObject: settings.workspaceScope ? "1" : "0"))
        recursiveButton.state = settings.recursive ? .on : .off
        hiddenButton.state = settings.includeHidden ? .on : .off
        extensionField.stringValue = settings.extensions
        filterField.stringValue = settings.filters
        queryField.stringValue = settings.options.query
        replacementField.stringValue = settings.options.replacement
        mode.selectItem(at: mode.indexOfItem(withRepresentedObject: String(settings.options.mode.rawValue)))
        caseButton.state = settings.options.matchCase ? .on : .off
        wordButton.state = settings.options.wholeWord ? .on : .off
        dotButton.state = settings.options.dotMatchesNewline ? .on : .off
        updateFolderLabel()
    }
    private func showPreferenceFailure(_ error: Error) {
        preferenceNotice.stringValue =
            "Saved search settings are unavailable. Searches still work; reset the settings to keep new choices."
        preferenceNotice.toolTip = error.localizedDescription
        preferenceNotice.isHidden = false
        resetPreferencesButton.isHidden = false
    }
    private func savePreferencesOrReport() {
        do {
            try saveSettings()
            preferenceNotice.isHidden = true
        } catch { showPreferenceFailure(error) }
    }
    @objc func resetSavedPreferences(_ sender: Any?) {
        guard StoreRecovery.confirmPreferenceReset(preferences.state) else { return }
        do {
            try preferences.reset()
            applySavedPreferences(preferences.value)
            preferenceNotice.isHidden = true
            status.stringValue = "Saved folder search settings were reset. Documents were not changed."
        } catch { showPreferenceFailure(error) }
    }
    @objc private func startSearch(_ sender: Any?) {
        // Before anything else, so that a refused Return has no side effect at all.
        guard !replacing else {
            status.stringValue = "Replacement in progress. Cancel it or wait for the report before searching."
            return
        }
        window?.makeFirstResponder(nil)
        let roots = selectedScope == .workspaceFolders ? workspaceRoots() : (folder.map { [$0] } ?? [])
        guard let folder = roots.first else {
            status.stringValue =
                selectedScope == .workspaceFolders
                ? "Add a folder in Workspace before searching Workspace Folders." : "Choose a folder first."
            lastOutcome = .needsInput
            return
        }
        let query = queryField.stringValue
        guard !query.isEmpty else {
            status.stringValue = "Enter a search expression."
            lastOutcome = .needsInput
            return
        }
        let extensions = Set(
            extensionField.stringValue.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
        var request = FolderSearchRequest(directory: folder, query: query)
        request.displayTabWidth = displayTabWidth()
        request.matchCase = caseButton.state == .on
        request.recursive = recursiveButton.state == .on
        request.extensions = extensions
        request.mode =
            ControlPresentation.selectedID(mode).flatMap(Int.init).flatMap(SearchOptions.Mode.init(rawValue:))
            ?? .normal
        request.wholeWord = wordButton.state == .on
        request.dotMatchesNewline = dotButton.state == .on
        request.filenameFilters = filterField.stringValue
        request.includeHidden = hiddenButton.state == .on
        do {
            _ = try FolderSearchFilters(request.filenameFilters)
        } catch {
            status.stringValue = error.localizedDescription
            lastOutcome = .failed(error.localizedDescription)
            return
        }
        savePreferencesOrReport()
        cancelSearch(nil)
        let token = UUID()
        generation = token
        searchedOptions = SearchOptions()
        searchedOptions.query = query
        searchedOptions.matchCase = request.matchCase
        searchedOptions.mode = request.mode
        searchedOptions.wholeWord = request.wholeWord
        searchedOptions.dotMatchesNewline = request.dotMatchesNewline
        let flag = FolderSearchCancellation(), gate = FolderProgressGate()
        cancellation = flag
        matches = []
        replaceButton.isEnabled = false
        searchedFolder = folder
        table.reloadData()
        details.string =
            String(
                format: Strings.text(
                    "folder.limits",
                    "Limits: %@ files; %@ entries; %@ per file; %@ total; %@ results. Symbolic links are excluded. Filename filters: %@."
                ), Strings.number(request.maximumFiles), Strings.number(request.maximumEntries),
                Strings.bytes(request.maximumFileBytes), Strings.bytes(request.maximumTotalBytes),
                Strings.number(request.maximumResults), request.filenameFilters)
        searchButton.isEnabled = false
        cancelButton.isEnabled = true
        status.stringValue = "Searching…"
        isSearching = true
        lastOutcome = nil
        work = Task { @MainActor [weak self] in
            do {
                let report = try await FolderSearch.searchAcross(
                    request, directories: roots, cancellation: flag,
                    progress: { [weak self] progress in
                        guard gate.admit() else { return }
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token, self.cancellation != nil else { return }
                            self.status.stringValue =
                                Strings.folderProgress(
                                    files: progress.filesSearched, matches: progress.matches,
                                    bytesRead: progress.bytesRead)
                        }
                    })
                guard let self, self.generation == token else { return }
                self.matches = report.matches
                self.table.reloadData()
                self.replaceButton.isEnabled =
                    !report.wasCancelled && report.reachedLimit == nil && !report.matches.isEmpty
                let problems = report.notSearched, excluded = report.excludedTotal
                let state: String
                if report.wasCancelled {
                    state = Strings.text("folder.cancelled", "Cancelled; partial results")
                } else if let limit = report.reachedLimit {
                    state = String(
                        format: Strings.text("folder.limited", "Limit reached: %@; partial results"), limit.displayName)
                } else {
                    state = Strings.text("folder.complete", "Complete")
                }
                self.status.stringValue = Strings.folderSummary(
                    matches: report.matches.count, files: report.filesSearched,
                    problems: problems.count, excluded: excluded, state: state)
                self.lastOutcome = .searched(
                    matches: report.matches.count, filesSearched: report.filesSearched,
                    skipped: problems.count + excluded, cancelled: report.wasCancelled,
                    limitReached: report.reachedLimit != nil)
                self.details.string += "\n" + Self.skipDetails(report)
                self.finish()
            } catch {
                guard let self, self.generation == token else { return }
                self.status.stringValue = error.localizedDescription
                self.lastOutcome = .failed(error.localizedDescription)
                self.finish()
            }
        }
    }
    /// What Replace Matched Files is about to do, in the person's own terms: the text, the
    /// replacement, how much changes, and what protects them.
    static func replacementExplanation(query: String, replacement: String, matches: Int, files: Int, folders: Int)
        -> String
    {
        func plural(_ count: Int, _ noun: String) -> String {
            "\(count) \(noun)\(count == 1 ? "" : noun.hasSuffix("ch") ? "es" : "s")"
        }
        func quoted(_ text: String) -> String {
            let line = text.replacingOccurrences(of: "\n", with: "⏎")
            return "“\(line.count > 80 ? String(line.prefix(80)) + "…" : line)”"
        }
        let change =
            replacement.isEmpty
            ? "Delete every match of \(quoted(query))" : "Replace \(quoted(query)) with \(quoted(replacement))"
        return
            "\(change): \(plural(matches, "match")) in \(plural(files, "file"))\(folders > 1 ? " across \(plural(folders, "folder"))" : "").\n\nThe files on disk are changed. Undo in the editor does not reverse this; each changed file gets a backup copy named .texttank-backup beside it.\n\nFiles that are open in TextTank, changed since the search, read-only or reached through a symbolic link are skipped. Files are changed one at a time, so if replacing stops part-way, the files already done stay changed. A report lists every file afterwards."
    }
    @objc private func replaceMatchedFiles(_ sender: Any?) {
        guard cancellation == nil, let fallbackDirectory = searchedFolder, !matches.isEmpty else { return }
        let grouped = Dictionary(grouping: matches, by: { $0.sourceRoot ?? fallbackDirectory })
        guard
            confirmReplacement(
                Self.replacementExplanation(
                    query: searchedOptions.query, replacement: replacementField.stringValue, matches: matches.count,
                    files: Set(matches.map(\.url)).count, folders: grouped.count))
        else { return }
        // The confirmation is modal; nothing may have started meanwhile.
        guard cancellation == nil, !matches.isEmpty else { return }
        window?.makeFirstResponder(nil)
        var capturedOptions = searchedOptions
        capturedOptions.replacement = replacementField.stringValue
        let options = capturedOptions
        let excluded = Set(NSDocumentController.shared.documents.compactMap { $0.fileURL }), snapshot = matches,
            flag = FolderSearchCancellation(), token = UUID(), beforeCommit = replacementBeforeCommit
        generation = token
        cancellation = flag
        replacing = true
        searchButton.isEnabled = false
        replaceButton.isEnabled = false
        cancelButton.isEnabled = true
        status.stringValue = "Replacing matched files…"
        isSearching = true
        lastOutcome = nil
        work = Task { @MainActor [weak self] in
            let outcomes = await Task.detached(priority: .userInitiated) {
                var outcomes: [FolderReplacementOutcome] = []
                let roots = Dictionary(grouping: snapshot, by: { $0.sourceRoot ?? fallbackDirectory })
                for directory in roots.keys.sorted(by: { $0.path < $1.path }) {
                    let selected = roots[directory]!
                    do {
                        outcomes += try FolderReplacement.replace(
                            directory: directory, matches: selected, options: options, excluding: excluded,
                            cancellation: flag, beforeCommit: beforeCommit)
                    } catch {
                        outcomes += Set(selected.map(\.url)).map {
                            FolderReplacementOutcome(
                                url: $0, status: .failed, message: error.localizedDescription, backup: nil)
                        }
                    }
                }
                return outcomes
            }.value
            guard let self else { return }
            self.retainReplacementOutcomes(outcomes)
            // The results are spent either way. A window closed meanwhile changed the generation
            // and left this replacement in charge of ending the busy state.
            self.matches = []
            self.table.reloadData()
            if self.generation == token { self.showReplacementReport(nil) }
            self.finish()
        }
    }
    func retainReplacementOutcomes(_ outcomes: [FolderReplacementOutcome]) { lastReplacementOutcomes = outcomes }
    @objc func showReplacementReport(_ sender: Any?) {
        guard !lastReplacementOutcomes.isEmpty else {
            status.stringValue = "No completed replacement report in this session."
            lastOutcome = .noReplacementReport
            return
        }
        status.stringValue =
            String(
                format: lastReplacementOutcomes.filter { $0.status == .replaced }.count == 1
                    ? Strings.text(
                        "folder.replaced.one",
                        "%@ file replaced · %@ unchanged/skipped/failed. Recovery copies retained.")
                    : Strings.text(
                        "folder.replaced.other",
                        "%@ files replaced · %@ unchanged/skipped/failed. Recovery copies retained."),
                Strings.number(lastReplacementOutcomes.filter { $0.status == .replaced }.count),
                Strings.number(lastReplacementOutcomes.filter { $0.status != .replaced }.count))
        lastOutcome = .replaced(
            replaced: lastReplacementOutcomes.filter { $0.status == .replaced }.count,
            notReplaced: lastReplacementOutcomes.filter { $0.status != .replaced }.count)
        details.string = lastReplacementOutcomes.map {
            "\($0.url.path): \($0.status.displayName) — \($0.message)"
                + ($0.backup.map { "\nRecovery copy: \($0.path)" } ?? "")
                + ($0.recoveryReport.map { "\nDurable recovery report: \($0.path)" } ?? "")
        }.joined(separator: "\n")
    }
    private func finish() {
        searchButton.isEnabled = true
        cancelButton.isEnabled = false
        work = nil
        cancellation = nil
        replacing = false
        isSearching = false
    }
    /// The text added to the details view after a search: the entries that could not be
    /// searched, capped, then one line of counts for what the filters left out on purpose.
    static func skipDetails(_ report: FolderSearchReport) -> String {
        var lines: [String] = []
        let problems = report.notSearched
        if !problems.isEmpty {
            lines.append("Not searched (\(problems.count)):")
            lines += problems.prefix(maximumListedProblems).map { "\($0.url.path): \($0.reason.explanation)" }
            if problems.count > maximumListedProblems {
                lines.append("… and \(problems.count - maximumListedProblems) more not listed.")
            }
        }
        let counts = FolderSearchSkipReason.policyExclusions.compactMap { reason in
            report.excludedCounts[reason].map { "\($0) \(reason.explanation)" }
        }
        if !counts.isEmpty {
            lines.append(
                "Excluded by filters or settings (\(report.excludedTotal)): " + counts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }
    @objc private func cancelSearch(_ sender: Any?) {
        cancellation?.cancel()
        work?.cancel()
    }
    func windowWillClose(_ notification: Notification) {
        savePreferencesOrReport()
        cancelSearch(nil)
        generation = UUID()
        // A cancelled replacement may still be committing its current file off the main thread.
        // It stays busy, refusing a search or an opened result, until that task returns.
        if !replacing { finish() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard matches.indices.contains(row) else { return nil }
        let match = matches[row]
        switch tableColumn?.identifier.rawValue {
        case "file": return match.url.path
        case "line": return "\(match.line):\(match.displayColumn)"
        default:
            return match.preview.replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: " ↵ ")
        }
    }
    /// The one validation behind opening a result: selects the match in `editor` only if the
    /// editor still holds `snapshot` at `revision`, the search of that snapshot (`hits`) still
    /// reports the match at the recorded UTF-16 range, and that range is the recorded UTF-8 range.
    /// Dirty documents are judged by their live text. False leaves the selection alone.
    @discardableResult static func selectResult(
        _ match: FolderSearchMatch, in editor: TTEditor, snapshot: String, revision: UInt, hits: [SearchHit]?
    ) -> Bool {
        let recorded = NSRange(location: match.utf16Range.location, length: match.utf16Range.length)
        guard editor.revision == revision, editor.text == snapshot,
            hits?.contains(where: { $0.range == recorded }) == true,
            let bytes = SearchCore.byteRange(recorded, in: snapshot),
            bytes == NSRange(location: match.utf8Range.location, length: match.utf8Range.length)
        else { return false }
        return editor.setSelectionAnchor(bytes.location, caret: NSMaxRange(bytes))
    }
    /// A double-click. `clickedRow` is -1 for a column header and the empty area below the
    /// rows, which therefore open nothing even while a row is selected.
    @objc func openResult(_ sender: Any?) { activateResult(row: table.clickedRow) }
    /// What a double-click or Return on a listed result does.
    func openResult(at row: Int) { activateResult(row: row) }
    /// Opens the result in `row` and selects its match. Refused while a search or a replacement
    /// is running: a file opened mid-run would be rewritten on disk underneath its new document.
    func activateResult(row: Int) {
        guard cancellation == nil else {
            status.stringValue =
                replacing
                ? "Replacement in progress; open results after it finishes."
                : "Search in progress; open results after it finishes."
            return
        }
        guard matches.indices.contains(row) else { return }
        let match = matches[row], options = searchedOptions, token = generation
        openResultDocument(match.url) { [weak self] document, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if let error {
                    self.status.stringValue = error.localizedDescription
                    self.lastOutcome = .failed(error.localizedDescription)
                    return
                }
                guard let document = document as? TextDocument else {
                    self.status.stringValue = "This result could not be opened as a text document."
                    self.lastOutcome = .failed("This result could not be opened as a text document.")
                    return
                }
                let editor = document.activeEditor
                let snapshot = editor.text, revision = editor.revision
                let report = try? await Task.detached(priority: .userInitiated) {
                    try SearchCore.search(snapshot, options: options)
                }.value
                guard self.generation == token, editor.window != nil,
                    Self.selectResult(match, in: editor, snapshot: snapshot, revision: revision, hits: report?.hits)
                else {
                    self.status.stringValue =
                        "Result is stale or could not be revalidated. Search again; selection was not changed."
                    self.lastOutcome = .staleResult
                    return
                }
                self.onUnrecordableCommand?("Opening a folder search result is not recorded in macros yet.")
                document.showWindows()
                document.windowControllers.first?.window?.makeFirstResponder(editor)
            }
        }
    }
}
