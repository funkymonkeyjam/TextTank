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
/// left behind ends when its call returns.
///
/// One volume that has stopped answering must not use up the threads, so they are shared out
/// by volume. A path's volume is the longest mount point its text starts with, read from the
/// system's mount table without touching the path. No volume has more than `perVolume`
/// questions out at once. A volume that left a question unanswered for `patience` seconds or
/// more when its deadline came is not asked again for `cooldown` seconds: its paths are "not known" at once. After that one question is tried; an answer in
/// time restores the volume, and silence starts the wait again. Such a volume is never given
/// one of the last `reserve` threads, and no more than `ceiling` threads exist at once, so
/// paths on volumes that answer are always asked.
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
    typealias VolumeNames = @Sendable ([URL]) -> [String]
    static let shared = FileProbePool(width: 4, ceiling: 8)
    let width: Int, ceiling: Int, perVolume: Int, reserve: Int
    let cooldown: TimeInterval, patience: TimeInterval
    private let volumeNames: VolumeNames
    private let state = NSCondition()
    private var running = 0
    private struct Volume {
        var asking = 0
        var quietUntil: TimeInterval = 0
        /// It let a deadline pass and has not answered in time since.
        var suspect = false
    }
    private var volumes: [String: Volume] = [:]
    /// Threads that are asking, or stuck asking, now.
    var busy: Int { state.withLock { running } }
    init(
        width: Int, ceiling: Int, perVolume: Int = 2, reserve: Int = 2, cooldown: TimeInterval = 30,
        patience: TimeInterval = 0.5,
        volumes: @escaping VolumeNames = FileProbePool.mountPoints
    ) {
        self.width = max(1, width)
        self.ceiling = max(1, ceiling)
        self.perVolume = max(1, perVolume)
        self.reserve = max(0, min(reserve, self.ceiling - 1))
        self.cooldown = cooldown
        self.patience = patience
        volumeNames = volumes
    }
    /// The mount point each path is under, by its text alone. The mount table is read without
    /// waiting for any file system (`MNT_NOWAIT`), and the paths themselves are not touched.
    static let mountPoints: VolumeNames = { urls in
        var mounts: [String] = []
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        if count > 0 {
            var table = Array(repeating: statfs(), count: Int(count))
            let filled = getfsstat(&table, count * Int32(MemoryLayout.stride(ofValue: table[0])), MNT_NOWAIT)
            for var entry in table.prefix(Int(max(0, filled))) {
                let name = withUnsafePointer(to: &entry.f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                mounts.append(name)
            }
        }
        mounts.sort { $0.utf8.count > $1.utf8.count }
        return urls.map { url in
            let path = url.path
            return mounts.first { $0 == "/" || path == $0 || path.hasPrefix($0 + "/") } ?? "/"
        }
    }
    private final class Batch: @unchecked Sendable {
        let urls: [URL], names: [String]
        var outcomes: [Outcome]
        var claimed: [Bool]
        var askedAt: [TimeInterval]
        var answered = 0, workers = 0, abandoned = false
        init(urls: [URL], names: [String]) {
            self.urls = urls
            self.names = names
            outcomes = Array(repeating: .unknown, count: urls.count)
            claimed = Array(repeating: false, count: urls.count)
            askedAt = Array(repeating: 0, count: urls.count)
        }
    }
    // The four helpers below are called with `state` held.

    /// Whether one more question may go to this volume now. `threadInHand` is true for a
    /// thread that has just finished a question and can ask another.
    private func mayAsk(_ name: String, now: TimeInterval, threadInHand: Bool) -> Bool {
        let volume = volumes[name] ?? Volume()
        guard volume.quietUntil <= now else { return false }
        let threads = threadInHand ? running - 1 : running
        if volume.suspect { return volume.asking < 1 && threads < ceiling - reserve }
        return volume.asking < perVolume && threads < ceiling
    }
    /// True when a path cannot be asked now for a reason that waiting will not change soon.
    private func isHeldBack(_ name: String, now: TimeInterval) -> Bool {
        guard let volume = volumes[name] else { return false }
        return volume.quietUntil > now || volume.suspect
    }
    /// The next path not yet taken that may be asked now.
    private func next(in batch: Batch, threadInHand: Bool) -> Int? {
        let now = ProcessInfo.processInfo.systemUptime
        var refused = Set<String>()
        for index in batch.urls.indices where !batch.claimed[index] && !refused.contains(batch.names[index]) {
            if mayAsk(batch.names[index], now: now, threadInHand: threadInHand) { return index }
            refused.insert(batch.names[index])
        }
        return nil
    }
    private func take(_ index: Int, in batch: Batch) {
        batch.claimed[index] = true
        batch.askedAt[index] = ProcessInfo.processInfo.systemUptime
        volumes[batch.names[index], default: Volume()].asking += 1
    }
    /// One thread: asks, records the answer if anyone still waits for it, and asks again while
    /// there is a path it may ask.
    private func work(on batch: Batch, from first: Int, probe: Probe) {
        var index = first
        while true {
            let file = probe(batch.urls[index])
            state.lock()
            let name = batch.names[index]
            volumes[name, default: Volume()].asking -= 1
            if !batch.abandoned {
                // An answer in time: the volume is answering.
                volumes[name]?.suspect = false
                batch.outcomes[index] = file.map(Outcome.found) ?? .missing
                batch.answered += 1
            }
            if !batch.abandoned, let following = next(in: batch, threadInHand: true) {
                take(following, in: batch)
                index = following
                state.broadcast()
                state.unlock()
                continue
            }
            running -= 1
            batch.workers -= 1
            state.broadcast()
            state.unlock()
            return
        }
    }
    /// One outcome a path, in order. Returns when every path has answered or cannot be asked,
    /// or at the deadline (in `ProcessInfo.systemUptime` seconds), whichever is first.
    func outcomes(for urls: [URL], until deadline: TimeInterval, probe: @escaping Probe) -> [Outcome] {
        guard !urls.isEmpty else { return [] }
        // A deadline that has already passed asks nothing, and so blames no volume.
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            return Array(repeating: .unknown, count: urls.count)
        }
        let batch = Batch(urls: urls, names: volumeNames(urls))
        let limit = Date(timeIntervalSinceNow: deadline - ProcessInfo.processInfo.systemUptime)
        state.lock()
        defer { state.unlock() }
        while true {
            while batch.workers < width, let index = next(in: batch, threadInHand: false) {
                take(index, in: batch)
                running += 1
                batch.workers += 1
                Thread.detachNewThread { [self] in work(on: batch, from: index, probe: probe) }
            }
            if batch.answered == urls.count { break }
            let now = ProcessInfo.processInfo.systemUptime
            // Nothing of this batch is out, and what is left is on volumes that are not being asked.
            let waiting = urls.indices.contains { !batch.claimed[$0] && !isHeldBack(batch.names[$0], now: now) }
            if batch.workers == 0 && !waiting { break }
            if now >= deadline || !state.wait(until: limit) { break }
        }
        batch.abandoned = true
        // A volume with a question out this long has stopped answering: leave it alone for a
        // while. One asked only a moment before the deadline says nothing about its volume.
        let now = ProcessInfo.processInfo.systemUptime
        for index in urls.indices
        where batch.claimed[index] && batch.outcomes[index] == .unknown && now - batch.askedAt[index] >= patience {
            volumes[batch.names[index], default: Volume()].suspect = true
            volumes[batch.names[index]]?.quietUntil = now + cooldown
        }
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
