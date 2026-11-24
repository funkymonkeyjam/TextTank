// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

/// A name-only inventory. General file decoding and reuse of an already-open document belong to the browser.
struct WorkspaceFileIndex: Sendable {
    struct File: Sendable {
        let root: URL, url: URL, relative: String
        let nameKey: String, pathKey: String
    }
    let files: [File]
    let limited: Bool
    let unreadable: Int

    static func scan(
        _ roots: [URL], limit: Int = 5_000, directoryLimit: Int = 512,
        deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 5
    ) -> Self {
        var files: [File] = []
        var pending = roots.map { (root: $0, directory: $0, relative: "") }
        var seenDirectories = Set<String>(), seenFiles = Set<String>()
        var offset = 0, unreadable = 0, limited = false
        while offset < pending.count && !Task.isCancelled {
            guard files.count < limit, offset < directoryLimit, ProcessInfo.processInfo.systemUptime < deadline else {
                limited = true
                break
            }
            let next = pending[offset]
            offset += 1
            guard seenDirectories.insert(next.directory.standardizedFileURL.absoluteString).inserted else { continue }
            do {
                let listing = try WorkspaceBrowserStore.list(next.directory)
                limited = limited || listing.truncated
                for entry in listing.entries {
                    if Task.isCancelled { break }
                    let name = entry.url.lastPathComponent
                    let path = next.relative.isEmpty ? name : next.relative + "/" + name
                    if entry.directory {
                        if pending.count < directoryLimit {
                            pending.append((next.root, entry.url, path))
                        } else {
                            limited = true
                        }
                    } else if seenFiles.insert(entry.url.standardizedFileURL.absoluteString).inserted {
                        guard files.count < limit else {
                            limited = true
                            break
                        }
                        files.append(
                            File(
                                root: next.root, url: entry.url, relative: path,
                                nameKey: key(name), pathKey: key(path)))
                    }
                }
            } catch { unreadable += 1 }
        }
        return Self(files: files, limited: limited, unreadable: unreadable)
    }

    private static func key(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    func matches(_ text: String, limit: Int = 200) -> [File] {
        let query = Self.key(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return Array(files.prefix(limit)) }
        func score(_ file: File) -> Int? {
            if file.nameKey == query { return 0 }
            if file.nameKey.hasPrefix(query) { return 1 }
            if file.nameKey.contains(query) { return 2 }
            if file.pathKey.contains(query) { return 3 }
            var index = query.startIndex
            for character in file.pathKey where character == query[index] {
                index = query.index(after: index)
                if index == query.endIndex { return 4 }
            }
            return nil
        }
        // Stable scan order within each score. Stop retaining rows beyond the visible limit per score.
        var groups = Array(repeating: [File](), count: 5)
        for file in files {
            if let value = score(file), groups[value].count < limit { groups[value].append(file) }
        }
        return Array(groups.joined().prefix(limit))
    }
}

/// What Quick Open lists: open documents first, then recent files that still exist, then the
/// files of the workspace folders. A file appears once, under the first kind that has it.
///
/// Building the list never reads a file's contents. `inspect` asks the file system whether a
/// path exists and which file it is, which can wait on a slow volume, so it is used off the
/// main thread only and stops at its deadline.
struct QuickOpenList: Sendable {
    enum Kind: Int, Sendable {
        case open, recent, workspace
        /// The small label at the end of a row.
        var label: String {
            switch self {
            case .open: return "Open"
            case .recent: return "Recent"
            case .workspace: return "Workspace"
            }
        }
        var spokenLabel: String {
            switch self {
            case .open: return "Open document"
            case .recent: return "Recent file"
            case .workspace: return "Workspace file"
            }
        }
    }
    /// An open document as the main thread saw it when Quick Open was shown.
    struct OpenDocument: Sendable {
        let id: String, name: String
        let url: URL?
        let group: String?
    }
    struct Entry: Sendable {
        let kind: Kind
        let id: String, title: String, detail: String
        let url: URL?, root: URL?
        let nameKey: String, pathKey: String
        /// Letters typed in order with gaps are looked for here: the path inside its folder for
        /// a workspace file, the name alone otherwise. A whole absolute path is long enough to
        /// match almost anything that way.
        var looseKey: String { kind == .workspace ? pathKey : nameKey }
    }
    static let recentLimit = 100
    private(set) var entries: [Entry] = []
    /// True when the deadline passed before every recent file had been looked at.
    private(set) var limited = false
    private var seen = Set<String>()

    func count(_ kind: Kind) -> Int { entries.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) } }

    private static func key(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
    private static func folder(_ url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
    /// The file a path names: its volume and file number. Nil if it is missing or not a regular file.
    private static func inspect(_ url: URL) -> String? {
        var info = stat()
        guard url.isFileURL, stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return "file:\(info.st_dev):\(info.st_ino)"
    }
    /// Records the names of a file and says whether none of them was listed before.
    private mutating func claim(_ url: URL, file: String?) -> Bool {
        let names = ["path:" + WorkspaceBrowserState.identity(url)] + (file.map { [$0] } ?? [])
        guard names.allSatisfy({ !seen.contains($0) }) else { return false }
        seen.formUnion(names)
        return true
    }
    /// Open documents, in the order given. An untitled document is listed by its display name.
    /// Two documents never share a file, but a document's file is remembered so that the same
    /// file is not listed again as a recent or workspace file.
    mutating func add(open documents: [OpenDocument], inspecting: Bool) {
        for document in documents {
            var place = "Not saved yet"
            if let url = document.url {
                _ = claim(url, file: inspecting ? Self.inspect(url) : nil)
                place = Self.folder(url)
            }
            let detail = document.group.map { place + " — " + $0 } ?? place
            entries.append(
                Entry(
                    kind: .open, id: "open:" + document.id, title: document.name, detail: detail, url: document.url,
                    root: nil, nameKey: Self.key(document.name),
                    pathKey: Self.key(document.url?.path ?? document.name)))
        }
    }
    /// Recent files that are still there, newest first. At most `recentLimit` are looked at, and
    /// none after the deadline; one that was not looked at is left out, never listed unchecked.
    mutating func add(recent urls: [URL], deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 2) {
        for (index, url) in urls.enumerated() {
            guard index < Self.recentLimit, ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else {
                limited = true
                break
            }
            guard let file = Self.inspect(url), claim(url, file: file) else { continue }
            let name = url.lastPathComponent
            entries.append(
                Entry(
                    kind: .recent, id: "file:" + url.standardizedFileURL.absoluteString, title: name,
                    detail: Self.folder(url), url: url, root: nil, nameKey: Self.key(name),
                    pathKey: Self.key(url.path)))
        }
    }
    /// Workspace files in scan order. The index already holds regular files only; each is asked
    /// for its identity until the deadline, and by path alone after it.
    mutating func add(
        workspace files: [WorkspaceFileIndex.File], deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 2
    ) {
        for file in files {
            if Task.isCancelled { break }
            let known = ProcessInfo.processInfo.systemUptime < deadline ? Self.inspect(file.url) : nil
            guard claim(file.url, file: known) else { continue }
            entries.append(
                Entry(
                    kind: .workspace, id: "file:" + file.url.standardizedFileURL.absoluteString,
                    title: file.url.lastPathComponent, detail: Self.folder(file.url), url: file.url, root: file.root,
                    nameKey: file.nameKey, pathKey: file.pathKey))
        }
    }

    /// Best name match first; among equal matches, open documents, then recent files, then
    /// workspace files, each in the order it was added. With nothing typed, that order alone.
    func matches(_ text: String, limit: Int = 200) -> [Entry] {
        let query = Self.key(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return Array(entries.prefix(limit)) }
        func score(_ entry: Entry) -> Int? {
            if entry.nameKey == query { return 0 }
            if entry.nameKey.hasPrefix(query) { return 1 }
            if entry.nameKey.contains(query) { return 2 }
            if entry.pathKey.contains(query) { return 3 }
            var index = query.startIndex
            for character in entry.looseKey where character == query[index] {
                index = query.index(after: index)
                if index == query.endIndex { return 4 }
            }
            return nil
        }
        var groups = Array(repeating: [Entry](), count: 5)
        for entry in entries {
            if let value = score(entry), groups[value].count < limit { groups[value].append(entry) }
        }
        return Array(groups.joined().prefix(limit))
    }
    static func row(_ entry: Entry) -> ChoicePanel.Row {
        .init(
            id: entry.id, title: entry.title, detail: entry.detail, accessory: entry.kind.label,
            accessoryLabel: entry.kind.spokenLabel)
    }
}

@MainActor final class WorkspaceQuickOpen {
    private(set) var panel: ChoicePanel?
    /// The list the panel shows now. It starts with the open documents alone and is replaced
    /// when the recent files have been checked and again when the workspace has been read.
    private(set) var list = QuickOpenList()
    /// False while recent files or workspace folders are still being read.
    private(set) var isComplete = false
    static let addFolderIdentifier = "workspace.quickOpen.addFolder"
    static let statusIdentifier = "workspace.quickOpen.status"

    /// - Parameters:
    ///   - select: shows the tab of the open document with this identity; it never opens a copy.
    ///   - open: opens a file. The folder is given for a workspace file and nil for a recent one.
    ///   - addFolder: the workspace's own Add Folder command, offered while it has no folder.
    func show(
        roots: [URL], documents: [QuickOpenList.OpenDocument], recent: [URL],
        select: @escaping (String) throws -> Bool, open: @escaping (URL?, URL) throws -> Bool,
        addFolder: @escaping () -> Void
    ) {
        if let panel {
            panel.showAgain()
            return
        }
        let panel = ChoicePanel(
            title: "Quick Open", identifier: "workspace.quickOpen", action: "Open",
            filterLabel: "Search open documents, recent files and workspace files")
        self.panel = panel
        let status = NSTextField(wrappingLabelWithString: "")
        status.identifier = .init(Self.statusIdentifier)
        panel.form.add(status)
        // DS-85: the empty state says what a workspace folder is for and offers the next step.
        let add = panel.form.button("Add Folder…", identifier: Self.addFolderIdentifier) { [weak panel] in
            panel?.form.close()
            addFolder()
        }
        add.isHidden = !roots.isEmpty
        var first = QuickOpenList()
        first.add(open: documents, inspecting: false)
        list = first
        isComplete = false
        let checked = Task.detached(priority: .userInitiated) { () -> QuickOpenList in
            var list = QuickOpenList()
            list.add(open: documents, inspecting: true)
            list.add(recent: recent)
            return list
        }
        let scanned = Task.detached(priority: .utility) { () -> (QuickOpenList, WorkspaceFileIndex) in
            var list = await checked.value
            let inventory = WorkspaceFileIndex.scan(roots)
            list.add(workspace: inventory.files)
            return (list, inventory)
        }
        panel.onClose = { [weak self] in
            checked.cancel()
            scanned.cancel()
            self?.panel = nil
            self?.list = QuickOpenList()
        }
        var inventory: WorkspaceFileIndex?
        panel.filteredRows = { [weak self] text in
            guard let self else { return [] }
            let visible = list.matches(text)
            var message = String(
                format: "Open documents: %@. Recent files: %@. Workspace files: %@. Showing %@.",
                Strings.number(list.count(.open)), Strings.number(list.count(.recent)),
                Strings.number(list.count(.workspace)), Strings.number(visible.count))
            if !isComplete {
                message += roots.isEmpty ? " Checking recent files…" : " Reading recent and workspace file names…"
            }
            if list.limited { message += " Some recent files were not checked in time." }
            if inventory?.limited == true { message += " The workspace index reached its scan limit." }
            if let unreadable = inventory?.unreadable, unreadable > 0 {
                message += " Unreadable folders: \(Strings.number(unreadable))."
            }
            if roots.isEmpty { message += " Add a folder to the workspace to find its files here too." }
            status.stringValue = message
            return visible.map(QuickOpenList.row)
        }
        panel.choose = { [weak self] id in
            guard let self, let entry = list.entries.first(where: { $0.id == id }) else { return false }
            if entry.kind == .open { return try select(String(id.dropFirst("open:".count))) }
            guard let url = entry.url else { return false }
            return try open(entry.root, url)
        }
        panel.show()
        Task { @MainActor [weak self, weak panel] in
            let recent = await checked.value
            guard let self, let panel, self.panel === panel else { return }
            list = recent
            if roots.isEmpty { isComplete = true }
            panel.refresh()
            guard !roots.isEmpty else { return }
            let all = await scanned.value
            guard self.panel === panel else { return }
            (list, inventory) = all
            isComplete = true
            panel.refresh()
        }
    }
}
