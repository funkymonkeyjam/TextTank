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

/// Asks the file system about paths on a few threads of its own, to a deadline.
///
/// `stat` on a volume that has stopped answering does not return and cannot be interrupted. A
/// question is therefore put on a thread that may be abandoned: the caller waits for the
/// deadline at most, takes the answers that arrived and reads the rest as not known. A thread
/// left behind ends when its call returns. Threads are counted across every caller: no more
/// than `ceiling` exist at once, so paths that never answer cannot multiply them; while the
/// ceiling is reached, further questions are answered "not known" at once.
final class FileProbePool: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        /// A regular file, with the name of its volume and file number.
        case found(String)
        case missing
        /// Not answered in time.
        case unknown
        var file: String? {
            if case .found(let file) = self { return file }
            return nil
        }
    }
    typealias Probe = @Sendable (URL) -> String?
    static let shared = FileProbePool(width: 4, ceiling: 8)
    let width: Int, ceiling: Int
    private let lock = NSLock()
    private var running = 0
    /// Threads that are asking, or stuck asking, now.
    var busy: Int { lock.withLock { running } }
    init(width: Int, ceiling: Int) {
        self.width = max(1, width)
        self.ceiling = max(1, ceiling)
    }
    private final class Batch: @unchecked Sendable {
        let condition = NSCondition()
        var outcomes: [Outcome]
        var next = 0, answered = 0, abandoned = false
        init(count: Int) { outcomes = Array(repeating: .unknown, count: count) }
    }
    /// One outcome a path, in order. Returns when every path has answered or at the deadline
    /// (in `ProcessInfo.systemUptime` seconds), whichever is first.
    func outcomes(for urls: [URL], until deadline: TimeInterval, probe: @escaping Probe) -> [Outcome] {
        guard !urls.isEmpty else { return [] }
        let threads = lock.withLock { () -> Int in
            let granted = max(0, min(width, urls.count, ceiling - running))
            running += granted
            return granted
        }
        let batch = Batch(count: urls.count)
        for _ in 0..<threads {
            Thread.detachNewThread { [self] in
                while true {
                    batch.condition.lock()
                    let index = batch.next
                    let stop = batch.abandoned || index >= urls.count
                    if !stop { batch.next += 1 }
                    batch.condition.unlock()
                    if stop { break }
                    let file = probe(urls[index])
                    batch.condition.lock()
                    batch.outcomes[index] = file.map(Outcome.found) ?? .missing
                    batch.answered += 1
                    batch.condition.broadcast()
                    batch.condition.unlock()
                }
                lock.withLock { running -= 1 }
            }
        }
        batch.condition.lock()
        defer { batch.condition.unlock() }
        if threads > 0 {
            let limit = Date(timeIntervalSinceNow: deadline - ProcessInfo.processInfo.systemUptime)
            while batch.answered < urls.count, batch.condition.wait(until: limit) {}
        }
        batch.abandoned = true
        return batch.outcomes
    }
}

/// What Quick Open lists: open documents first, then recent files that still exist, then the
/// files of the workspace folders. A file appears once, under the first kind that has it.
///
/// Building the list never reads a file's contents. `inspect` asks the file system whether a
/// path exists and which file it is. That can wait for ever on a volume that has stopped
/// answering, so it is asked through a `FileProbePool`, off the main thread: a path that has
/// not answered by the deadline is read as not known and its thread is left behind.
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
    static let inspect: FileProbePool.Probe = { url in
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
    /// The files of the open documents that have one, asked to a deadline. Nil where the
    /// document is untitled or its file did not answer.
    static func files(
        of documents: [OpenDocument], deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 1,
        pool: FileProbePool = .shared, probe: @escaping FileProbePool.Probe = inspect
    ) -> [String?] {
        let saved = documents.compactMap(\.url)
        var answers = pool.outcomes(for: saved, until: deadline, probe: probe).map(\.file).makeIterator()
        return documents.map { $0.url == nil ? nil : (answers.next() ?? nil) }
    }
    /// Whether each recent file is still there. At most `recentLimit` are asked; one beyond
    /// that, or one that has not answered by the deadline, is not known.
    static func outcomes(
        recent urls: [URL], deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 2,
        pool: FileProbePool = .shared, probe: @escaping FileProbePool.Probe = inspect
    ) -> [FileProbePool.Outcome] {
        let asked = Array(urls.prefix(recentLimit))
        return pool.outcomes(for: asked, until: deadline, probe: probe)
            + Array(repeating: .unknown, count: urls.count - asked.count)
    }
    /// The file each workspace file is, asked to a deadline; nil where it did not answer.
    static func files(
        of workspace: [WorkspaceFileIndex.File], deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 2,
        pool: FileProbePool = .shared, probe: @escaping FileProbePool.Probe = inspect
    ) -> [String?] {
        pool.outcomes(for: workspace.map(\.url), until: deadline, probe: probe).map(\.file)
    }
    /// Open documents, in the order given. An untitled document is listed by its display name.
    /// Two documents never share a file, but a document's file is remembered so that the same
    /// file is not listed again as a recent or workspace file. `files` is what `files(of:)`
    /// answered, or nil before it has.
    mutating func add(open documents: [OpenDocument], files: [String?]? = nil) {
        for (index, document) in documents.enumerated() {
            var place = "Not saved yet"
            if let url = document.url {
                _ = claim(url, file: files.flatMap { $0.indices.contains(index) ? $0[index] : nil })
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
    mutating func add(open documents: [OpenDocument], inspecting: Bool) {
        add(open: documents, files: inspecting ? Self.files(of: documents) : nil)
    }
    /// Recent files that are still there, newest first. One whose existence is not known is
    /// left out, never listed unchecked, and `limited` then says so.
    mutating func add(recent urls: [URL], outcomes: [FileProbePool.Outcome]) {
        for (index, url) in urls.enumerated() {
            guard outcomes.indices.contains(index), outcomes[index] != .unknown else {
                limited = true
                continue
            }
            guard let file = outcomes[index].file, claim(url, file: file) else { continue }
            let name = url.lastPathComponent
            entries.append(
                Entry(
                    kind: .recent, id: "file:" + url.standardizedFileURL.absoluteString, title: name,
                    detail: Self.folder(url), url: url, root: nil, nameKey: Self.key(name),
                    pathKey: Self.key(url.path)))
        }
    }
    mutating func add(
        recent urls: [URL], deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 2,
        pool: FileProbePool = .shared, probe: @escaping FileProbePool.Probe = inspect
    ) {
        add(recent: urls, outcomes: Self.outcomes(recent: urls, deadline: deadline, pool: pool, probe: probe))
    }
    /// Workspace files in scan order. The index already holds regular files only; one whose
    /// identity is not known is told apart by its path alone.
    mutating func add(workspace files: [WorkspaceFileIndex.File], identities: [String?]) {
        for (index, file) in files.enumerated() {
            guard claim(file.url, file: identities.indices.contains(index) ? identities[index] : nil) else { continue }
            entries.append(
                Entry(
                    kind: .workspace, id: "file:" + file.url.standardizedFileURL.absoluteString,
                    title: file.url.lastPathComponent, detail: Self.folder(file.url), url: file.url, root: file.root,
                    nameKey: file.nameKey, pathKey: file.pathKey))
        }
    }
    mutating func add(
        workspace files: [WorkspaceFileIndex.File], deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 2
    ) {
        add(workspace: files, identities: Self.files(of: files, deadline: deadline))
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
    /// How the file system is asked, and for how long about recent files. Checks replace them.
    var probe: FileProbePool.Probe = QuickOpenList.inspect
    var pool = FileProbePool.shared
    var recentBound: TimeInterval = 2
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
        // Three questions, none waiting for another: which files the open documents are, which
        // recent files are still there, and what the workspace folders hold. The list is put
        // together again from whatever has answered, always in the order open, recent, workspace.
        let probe = probe, pool = pool, recentBound = recentBound
        var openFiles: [String?]?
        var recentOutcomes: [FileProbePool.Outcome]?
        var workspace: (index: WorkspaceFileIndex, files: [String?])?
        let rebuild = { [weak self] in
            var next = QuickOpenList()
            next.add(open: documents, files: openFiles)
            if let recentOutcomes { next.add(recent: recent, outcomes: recentOutcomes) }
            if let workspace { next.add(workspace: workspace.index.files, identities: workspace.files) }
            self?.list = next
            self?.isComplete = recentOutcomes != nil && (roots.isEmpty || workspace != nil)
        }
        rebuild()
        let identified = Task.detached(priority: .userInitiated) {
            QuickOpenList.files(of: documents, pool: pool, probe: probe)
        }
        let checked = Task.detached(priority: .userInitiated) {
            QuickOpenList.outcomes(
                recent: recent, deadline: ProcessInfo.processInfo.systemUptime + recentBound, pool: pool, probe: probe)
        }
        let scanned = Task.detached(priority: .utility) { () -> (WorkspaceFileIndex, [String?]) in
            let inventory = WorkspaceFileIndex.scan(roots)
            return (inventory, QuickOpenList.files(of: inventory.files, pool: pool, probe: probe))
        }
        panel.onClose = { [weak self] in
            identified.cancel()
            checked.cancel()
            scanned.cancel()
            self?.panel = nil
            self?.list = QuickOpenList()
        }
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
            if workspace?.index.limited == true { message += " The workspace index reached its scan limit." }
            if let unreadable = workspace?.index.unreadable, unreadable > 0 {
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
        let current = { [weak self, weak panel] () -> ChoicePanel? in
            guard let self, let panel, self.panel === panel else { return nil }
            return panel
        }
        Task { @MainActor in
            let files = await identified.value
            guard let panel = current() else { return }
            openFiles = files
            rebuild()
            panel.refresh()
        }
        Task { @MainActor in
            let outcomes = await checked.value
            guard let panel = current() else { return }
            recentOutcomes = outcomes
            rebuild()
            panel.refresh()
        }
        guard !roots.isEmpty else { return }
        Task { @MainActor in
            let found = await scanned.value
            guard let panel = current() else { return }
            workspace = found
            rebuild()
            panel.refresh()
        }
    }
}
