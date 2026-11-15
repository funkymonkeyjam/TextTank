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
    let queryField = NSTextField(), extensionField = NSTextField(), replacementField = NSTextField(),
        filterField = NSTextField()
    var workspaceRoots: () -> [URL] = { [] }
    let scope = NSPopUpButton()
    let hiddenButton = NSButton(checkboxWithTitle: "Include hidden files/folders", target: nil, action: nil)
    private let defaults: UserDefaults
    private var settingsError: Error?
    let mode = NSPopUpButton()
    let wordButton = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    let dotButton = NSButton(checkboxWithTitle: "Dot matches newline", target: nil, action: nil)
    let caseButton = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let recursiveButton = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
    let folderLabel = NSTextField(labelWithString: "Choose a folder to search")
    let status = NSTextField(labelWithString: "Normal / Extended / Boost regex · UTF-8/UTF-16 · symlinks skipped")
    let table = NSTableView(), details = NSTextView()
    private var folder: URL?
    private var searchedFolder: URL?
    private var replaceButton: NSButton!
    private(set) var lastReplacementOutcomes: [FolderReplacementOutcome] = []
    private var matches: [FolderSearchMatch] = []
    private var searchedQuery = "", searchedCase = true
    private var searchedOptions = SearchOptions()
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
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
        cancelButton = NSButton(title: "Cancel Search", target: self, action: #selector(cancelSearch(_:)))
        cancelButton.isEnabled = false
        mode.addItems(withTitles: ["Normal", "Extended", "Boost regex"])
        scope.addItems(withTitles: ["Chosen Folder", "Workspace Folders"])
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
        let root = NSStackView(views: [
            location, queryField, replacements, filterField, semantics, options, status, results, detailScroll
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = root
        for view in [location, queryField, replacements, filterField, semantics, options, status, results, detailScroll]
        { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true }
        detailScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        results.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        extensionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        do {
            let settings = try FolderSearchSettings.load(defaults)
            folder = settings.folder
            scope.selectItem(at: settings.workspaceScope ? 1 : 0)
            recursiveButton.state = settings.recursive ? .on : .off
            hiddenButton.state = settings.includeHidden ? .on : .off
            extensionField.stringValue = settings.extensions
            filterField.stringValue = settings.filters
            queryField.stringValue = settings.options.query
            replacementField.stringValue = settings.options.replacement
            mode.selectItem(at: settings.options.mode.rawValue)
            caseButton.state = settings.options.matchCase ? .on : .off
            wordButton.state = settings.options.wholeWord ? .on : .off
            dotButton.state = settings.options.dotMatchesNewline ? .on : .off
            updateFolderLabel()
        } catch {
            settingsError = error
            filterField.stringValue = "*.*"
            status.stringValue = "Saved search settings could not be read; original settings preserved."
        }

    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    @objc func showSearch(_ sender: Any?) {
        updateFolderLabel()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
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
        try? saveSettings()
    }
    @objc private func scopeChanged(_ sender: Any?) {
        updateFolderLabel()
        try? saveSettings()
    }
    private func updateFolderLabel() {
        folderLabel.stringValue =
            scope.indexOfSelectedItem == 1
            ? "\(workspaceRoots().count) saved workspace folder(s)" : folder?.path ?? "Choose a folder to search"
    }
    /// Native setting capture is inert and commits the shared field editor first.
    func saveSettings() throws {
        guard settingsError == nil else { return } // Preserve a corrupt/future version verbatim.
        window?.makeFirstResponder(nil)
        var value = FolderSearchSettings()
        value.folder = folder
        value.workspaceScope = scope.indexOfSelectedItem == 1
        value.recursive = recursiveButton.state == .on
        value.includeHidden = hiddenButton.state == .on
        value.extensions = extensionField.stringValue
        value.filters = filterField.stringValue
        value.options.query = queryField.stringValue
        value.options.replacement = replacementField.stringValue
        value.options.mode = SearchOptions.Mode(rawValue: mode.indexOfSelectedItem) ?? .normal
        value.options.matchCase = caseButton.state == .on
        value.options.wholeWord = wordButton.state == .on
        value.options.dotMatchesNewline = dotButton.state == .on
        try value.save(defaults)
    }
    @objc private func startSearch(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        let roots = scope.indexOfSelectedItem == 1 ? workspaceRoots() : (folder.map { [$0] } ?? [])
        guard let folder = roots.first else {
            status.stringValue =
                scope.indexOfSelectedItem == 1
                ? "Add a folder in Workspace before searching Workspace Folders." : "Choose a folder first."
            lastOutcome = .needsInput
            return
        }
        let query = queryField.stringValue
        guard !query.isEmpty else {
            status.stringValue = "Enter a nonempty search expression."
            lastOutcome = .needsInput
            return
        }
        let extensions = Set(
            extensionField.stringValue.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init))
        var request = FolderSearchRequest(directory: folder, query: query)
        request.matchCase = caseButton.state == .on
        request.recursive = recursiveButton.state == .on
        request.extensions = extensions
        request.mode = SearchOptions.Mode(rawValue: mode.indexOfSelectedItem) ?? .normal
        request.wholeWord = wordButton.state == .on
        request.dotMatchesNewline = dotButton.state == .on
        request.filenameFilters = filterField.stringValue
        request.includeHidden = hiddenButton.state == .on
        do {
            _ = try FolderSearchFilters(request.filenameFilters)
            try saveSettings()
        } catch {
            status.stringValue = error.localizedDescription
            lastOutcome = .failed(error.localizedDescription)
            return
        }
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
            "Limits: 10,000 files · 100,000 entries · 32 MiB/file · 256 MiB total · 10,000 results. Symbolic links are excluded. Filename filters: \(request.filenameFilters)."
        searchedQuery = query
        searchedCase = request.matchCase
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
                                "Searching: \(progress.filesSearched) files · \(progress.matches) matches · \(progress.bytesRead) bytes"
                        }
                    })
                guard let self, self.generation == token else { return }
                self.matches = report.matches
                self.table.reloadData()
                self.replaceButton.isEnabled =
                    !report.wasCancelled && report.reachedLimit == nil && !report.matches.isEmpty
                self.status.stringValue =
                    "\(report.matches.count) matches · \(report.filesSearched) files searched · \(report.skipped.count) skipped"
                    + (report.wasCancelled ? " · Cancelled (partial results)" : "")
                    + (report.reachedLimit.map { " · Limit reached: \($0.rawValue) (partial results)" } ?? "")
                self.lastOutcome = .searched(
                    matches: report.matches.count, filesSearched: report.filesSearched, skipped: report.skipped.count,
                    cancelled: report.wasCancelled, limitReached: report.reachedLimit != nil)
                self.details.string +=
                    "\n"
                    + report.skipped.map { "\($0.url.path): \(String(describing:$0.reason))" }.joined(separator: "\n")
                self.finish()
            } catch {
                guard let self, self.generation == token else { return }
                self.status.stringValue = error.localizedDescription
                self.lastOutcome = .failed(error.localizedDescription)
                self.finish()
            }
        }
    }
    @objc private func replaceMatchedFiles(_ sender: Any?) {
        guard cancellation == nil, let fallbackDirectory = searchedFolder, !matches.isEmpty else { return }
        let grouped = Dictionary(grouping: matches, by: { $0.sourceRoot ?? fallbackDirectory })
        let alert = TTAlert()
        alert.messageText = "Replace Matched Files?"
        alert.informativeText =
            "Replace matches in \(Set(matches.map(\.url)).count) files across \(grouped.count) root(s) from the completed search. Each changed file gets a byte-exact .texttank-backup copy beside it. Files open in TextTank, changed since search, read-only, symlinked are skipped. Changes commit per file, not as one transaction."
        alert.addButton(withTitle: "Replace Files").identifier = NSUserInterfaceItemIdentifier("folder.replace.confirm")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        window?.makeFirstResponder(nil)
        var options = searchedOptions
        options.replacement = replacementField.stringValue
        let excluded = Set(NSDocumentController.shared.documents.compactMap { $0.fileURL }), snapshot = matches,
            flag = FolderSearchCancellation(), token = UUID()
        generation = token
        cancellation = flag
        searchButton.isEnabled = false
        replaceButton.isEnabled = false
        cancelButton.isEnabled = true
        status.stringValue = "Replacing snapshot-matched files…"
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
                            cancellation: flag)
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
            guard self.generation == token else { return }
            self.matches = []
            self.table.reloadData()
            self.showReplacementReport(nil)
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
            "\(lastReplacementOutcomes.filter{$0.status == .replaced}.count) files replaced · \(lastReplacementOutcomes.filter{$0.status != .replaced}.count) unchanged/skipped/failed. Recovery copies retained."
        lastOutcome = .replaced(
            replaced: lastReplacementOutcomes.filter { $0.status == .replaced }.count,
            notReplaced: lastReplacementOutcomes.filter { $0.status != .replaced }.count)
        details.string = lastReplacementOutcomes.map {
            "\($0.url.path): \($0.status.rawValue) — \($0.message)"
                + ($0.backup.map { "\nRecovery copy: \($0.path)" } ?? "")
                + ($0.recoveryReport.map { "\nDurable recovery report: \($0.path)" } ?? "")
        }.joined(separator: "\n")
    }
    private func finish() {
        searchButton.isEnabled = true
        cancelButton.isEnabled = false
        work = nil
        cancellation = nil
        isSearching = false
    }
    @objc private func cancelSearch(_ sender: Any?) {
        cancellation?.cancel()
        work?.cancel()
    }
    func windowWillClose(_ notification: Notification) {
        try? saveSettings()
        cancelSearch(nil)
        generation = UUID()
        finish()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard matches.indices.contains(row) else { return nil }
        let match = matches[row]
        switch tableColumn?.identifier.rawValue {
        case "file": return match.url.path
        case "line": return "\(match.line):\(match.columnUTF16)"
        default:
            return match.preview.replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\r", with: " ↵ ")
        }
    }
    /// Validates both recorded offsets against the live buffer, including dirty documents.
    static func validatedRange(_ match: FolderSearchMatch, text: String, query: String, matchCase: Bool) -> NSRange? {
        let bytes = Array(text.utf8), span = match.utf8Range
        guard !query.isEmpty, span.location >= 0, span.length > 0, span.location <= bytes.count,
            span.length <= bytes.count - span.location
        else { return nil }
        let selected = String(decoding: bytes[span.location..<span.location + span.length], as: UTF8.self)
        guard Array(selected.utf8) == Array(bytes[span.location..<span.location + span.length]) else { return nil }
        let prefix = String(decoding: bytes[..<span.location], as: UTF8.self)
        guard prefix.utf8.count == span.location, prefix.utf16.count == match.utf16Range.location,
            selected.utf16.count == match.utf16Range.length
        else { return nil }
        let options: NSString.CompareOptions = matchCase ? [.literal] : [.literal, .caseInsensitive]
        let found = (selected as NSString).range(of: query, options: options)
        guard found.location == 0, found.length == (selected as NSString).length else { return nil }
        return NSRange(location: span.location, length: span.length)
    }
    @discardableResult static func selectResult(
        _ match: FolderSearchMatch, in document: TextDocument, query: String, matchCase: Bool
    ) -> Bool {
        guard let range = validatedRange(match, text: document.editor.text, query: query, matchCase: matchCase) else {
            return false
        }
        let editor = (document.windowControllers.first as? EditorWindowController)?.activeEditor ?? document.editor
        return editor.setSelectionAnchor(range.location, caret: range.location + range.length)
    }
    @discardableResult static func selectResult(
        _ match: FolderSearchMatch, in document: TextDocument, options: SearchOptions
    ) -> Bool {
        let editor = (document.windowControllers.first as? EditorWindowController)?.activeEditor ?? document.editor
        let text = editor.text
        guard let report = try? SearchCore.search(text, options: options),
            report.hits.contains(where: {
                $0.range == NSRange(location: match.utf16Range.location, length: match.utf16Range.length)
            }),
            let bytes = SearchCore.byteRange(
                NSRange(location: match.utf16Range.location, length: match.utf16Range.length), in: text),
            bytes == NSRange(location: match.utf8Range.location, length: match.utf8Range.length)
        else { return false }
        return editor.setSelectionAnchor(bytes.location, caret: NSMaxRange(bytes))
    }
    @objc private func openResult(_ sender: Any?) {
        let row = table.clickedRow
        guard matches.indices.contains(row) else { return }
        let match = matches[row], options = searchedOptions, token = generation
        NSDocumentController.shared.openDocument(withContentsOf: match.url, display: true) {
            [weak self] document, _, error in
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
                let editor =
                    (document.windowControllers.first as? EditorWindowController)?.activeEditor ?? document.editor
                let snapshot = editor.text, revision = editor.revision
                let report = try? await Task.detached(priority: .userInitiated) {
                    try SearchCore.search(snapshot, options: options)
                }.value
                guard self.generation == token, editor.window != nil, editor.revision == revision,
                    editor.text == snapshot,
                    report?.hits.contains(where: {
                        $0.range == NSRange(location: match.utf16Range.location, length: match.utf16Range.length)
                    }) == true,
                    let bytes = SearchCore.byteRange(
                        NSRange(location: match.utf16Range.location, length: match.utf16Range.length), in: snapshot),
                    bytes == NSRange(location: match.utf8Range.location, length: match.utf8Range.length),
                    editor.setSelectionAnchor(bytes.location, caret: NSMaxRange(bytes))
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
