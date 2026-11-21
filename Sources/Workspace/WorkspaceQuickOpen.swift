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

@MainActor final class WorkspaceQuickOpen {
    private var panel: ChoicePanel?
    func show(roots: [URL], open: @escaping (URL, URL) throws -> Bool) {
        if let panel {
            panel.form.window.makeKeyAndOrderFront(nil)
            return
        }
        let panel = ChoicePanel(
            title: "Quick Open", identifier: "workspace.quickOpen", action: "Open",
            filterLabel: "Search workspace file names or paths")
        self.panel = panel
        let status = NSTextField(
            wrappingLabelWithString: roots.isEmpty
                ? "Add a folder to the workspace to find files here." : "Reading workspace file names…")
        status.identifier = .init("workspace.quickOpen.status")
        panel.form.add(status)
        let worker = Task.detached(priority: .utility) { WorkspaceFileIndex.scan(roots) }
        panel.onClose = { [weak self] in
            worker.cancel()
            self?.panel = nil
        }
        panel.show()
        Task { @MainActor [weak self, weak panel] in
            let inventory = await worker.value
            guard let self, let panel, self.panel === panel else { return }
            let lookup = Dictionary(
                uniqueKeysWithValues: inventory.files.map { ($0.url.standardizedFileURL.absoluteString, $0) })
            panel.filteredRows = { text in
                let visible = inventory.matches(text)
                if !roots.isEmpty {
                    var message = "Showing \(visible.count) of \(inventory.files.count) indexed files."
                    if inventory.limited { message += " The workspace index reached its scan limit." }
                    if inventory.unreadable > 0 { message += " Unreadable folders: \(inventory.unreadable)." }
                    status.stringValue = message
                }
                return visible.map {
                    .init(
                        id: $0.url.standardizedFileURL.absoluteString,
                        title: $0.relative, detail: $0.root.path)
                }
            }
            panel.choose = { id in
                guard let file = lookup[id] else { return false }
                return try open(file.root, file.url)
            }
            panel.refresh()
        }
    }
}
