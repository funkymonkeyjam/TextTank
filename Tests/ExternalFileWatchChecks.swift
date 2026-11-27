import AppKit
import Darwin
@testable import TextTankCore
@testable import TextTankRuntime

@MainActor enum ExternalFileWatchChecks {
    /// Count the actual descriptors pointing into the fixture, independent of the watcher's state.
    private static func descriptors(in folder: URL) -> (owned: Int, total: Int, distinct: Int) {
        let capacity = Int(proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0))
        guard capacity > 0 else { return (-1, -1, -1) }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity / stride + 32)
        let size = entries.withUnsafeMutableBytes {
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard size > 0 else { return (-1, -1, -1) }
        struct Node: Hashable {
            let device: dev_t, inode: ino_t
            init(_ value: stat) {
                device = value.st_dev
                inode = value.st_ino
            }
        }
        guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return (-1, -1, -1) }
        let ownedFiles = Set(
            children.compactMap { url -> Node? in
                var value = stat()
                return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG ? Node(value) : nil
            })
        var owned = 0
        var distinct = Set<Node>()
        for entry in entries.prefix(Int(size) / stride) {
            var value = stat()
            if fstat(entry.proc_fd, &value) == 0 && ownedFiles.contains(Node(value)) {
                owned += 1
                distinct.insert(Node(value))
            }
        }
        return (owned, Int(size) / stride, distinct.count)
    }

    static func run(in root: URL) throws {
        let folder = root.appendingPathComponent("vnode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("vnode.txt"), other = folder.appendingPathComponent("save-as.txt")
        func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url, options: .atomic) }
        try write("first", to: file)
        let initial = descriptors(in: folder)
        let doc = try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(file), from: file, display: false)
        defer { doc.close() }
        let view = try requireValue(doc.presentation, "vnode fixture presentation")
        doc.externalFile.setApplicationActive(true)
        _ = spinUntil("vnode attached") { descriptors(in: folder).owned == initial.owned + 1 }
        let id = try requireValue(view.tabID, "watch group source")
        check(view.host.setEditorLayout(.twoColumns), "watch fixture accepts split layout")
        let cloneID = try requireValue(view.host.openView(id, in: .second), "watch clone")
        let clone = try requireValue(view.host.presentation(for: cloneID), "watch clone presentation")
        check(descriptors(in: folder).owned == initial.owned + 1, "both group views share a single vnode")
        guard chmod(file.path, 0) == 0 else { throw POSIXError(.EACCES) }
        _ = spinUntil(timeout: 1, "permission event reported as unavailable") {
            clone.statusText.contains("Could not verify disk file")
                && view.statusText.contains("Could not verify disk file")
        }
        guard chmod(file.path, 0o600) == 0 else { throw POSIXError(.EACCES) }
        _ = spinUntil(timeout: 1, "restored access refreshes both group views") { doc.externalFile.notice == nil }
        view.host.closeTab(cloneID, sender: nil)
        _ = spinUntil("clone closed without retiring primary watch") { view.host.presentation(for: cloneID) == nil }
        check(
            doc.isOpen && descriptors(in: folder).owned == initial.owned + 1,
            "closing one clone leaves the document subscription alive")
        try write("replace1", to: file)
        _ = spinUntil(timeout: 1, "active replacement automatically announced") {
            view.statusText.contains("Changed on disk")
        }
        check(doc.editor.text == "first" && !doc.isDocumentEdited, "live Ask preserves original buffer")
        doc.externalFile.reload(nil)
        _ = spinUntil("accepted replacement") { doc.editor.text == "replace1" }
        for text in ["replace2", "replace3"] {
            try write(text, to: file)
            _ = spinUntil(timeout: 1, "watch rearms after atomic replacement " + text) {
                doc.externalFile.actionTitle == "Reload…"
            }
            doc.externalFile.reload(nil)
            _ = spinUntil("fresh inode offered " + text) { doc.editor.text == text }
        }
        // Undoable edits may never be discarded by continuous observation.
        _ = doc.editor.replaceSelection("retained")
        let dirty = doc.editor.text
        let moved = folder.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: file, to: moved)
        _ = spinUntil(timeout: 1, "removed pathname after rename is reported") {
            doc.externalFile.notice?.contains("missing") == true
        }
        check(
            doc.isDocumentEdited && doc.editor.text == dirty && doc.externalFile.actionTitle == nil,
            "rename away preserves unsaved text and makes no claim about destination")
        try write("reappeared", to: file)
        view.host.activate(view, focus: false)
        _ = spinUntil("tab check reattaches after absent pathname reappears") {
            doc.externalFile.actionTitle == "Reload…"
        }
        try doc.writeSafely(to: other, ofType: TextDocument.plainTextType, for: .saveAsOperation)
        doc.fileURL = other
        try write("new save-as bytes", to: other)
        _ = spinUntil(timeout: 1, "Save As observes new pathname") { doc.externalFile.notice == "Changed on disk" }
        doc.externalFile.setApplicationActive(false)
        _ = spinUntil("backgrounding closes owned vnode") { descriptors(in: folder).owned == initial.owned }
        doc.externalFile.setPolicy(.ignore)
        doc.externalFile.setApplicationActive(true)
        check(
            descriptors(in: folder).owned == initial.owned && doc.externalFile.notice == nil,
            "Ignore and background release their descriptor")
        try write("closed-event", to: other)
        doc.externalFile.setPolicy(.ask)
        doc.close()
        _ = spinUntil("closing during queued watch setup drains owned descriptors") {
            descriptors(in: folder).owned == initial.owned && doc.isClosed
        }
        // Let a canceled queued registration reach the kernel before the final census.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check(
            doc.externalFile.notice == nil && descriptors(in: folder).owned == initial.owned,
            "queued events after close cannot leak a subscription or restore a notice")
        try scale(in: root)
    }

    private static func scale(in root: URL) throws {
        let folder = root.appendingPathComponent("vnode-scale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let number = ProcessInfo.processInfo.environment["TEXTTANK_WATCH_200"] == "1" ? 200 : 8
        var docs: [TextDocument] = []
        defer { docs.forEach { $0.close() } }
        let baseline = descriptors(in: folder)
        for index in 0..<number {
            let file = folder.appendingPathComponent("source-\(index).txt")
            try Data("buffer \(index)".utf8).write(to: file)
            docs.append(
                try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(file), from: file, display: false))
            docs.last?.externalFile.setApplicationActive(false)
        }
        _ = spinUntil("initial file inspections have released their reads") {
            docs.allSatisfy { !$0.externalFile.checking } && descriptors(in: folder).owned == baseline.owned
        }
        let before = descriptors(in: folder)
        var original = rlimit()
        let reduced = ProcessInfo.processInfo.environment["TEXTTANK_WATCH_REDUCED_FDS"] == "1"
        if reduced {
            guard getrlimit(RLIMIT_NOFILE, &original) == 0 else { throw POSIXError(.EINVAL) }
            var limited = original
            limited.rlim_cur = min(original.rlim_cur, UInt64(before.total + 64))
            guard setrlimit(RLIMIT_NOFILE, &limited) == 0 else { throw POSIXError(.EPERM) }
        }
        defer { if reduced { _ = setrlimit(RLIMIT_NOFILE, &original) } }
        docs.forEach { $0.externalFile.setApplicationActive(true) }
        var armed = before
        if reduced {
            _ = spinUntil("watch admission under limited fds") { descriptors(in: folder).owned > before.owned }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        // A normal inspection and a vnode subscription can hold the same file independently.
        // Sample the settled file descriptors once and assert on that same kernel census.
        _ = spinUntil("settled native watches under the descriptor budget") {
            guard docs.allSatisfy({ !$0.externalFile.checking }) else { return false }
            armed = descriptors(in: folder)
            guard armed.distinct == armed.owned else { return false }
            return reduced
                ? armed.owned > before.owned && armed.owned < before.owned + number
                : armed.owned == before.owned + number
        }
        check(
            armed.distinct == armed.owned
                && (reduced
                    ? (armed.owned > before.owned && armed.owned < before.owned + number)
                    : armed.owned == before.owned + number),
            "available descriptor budget bounds watcher admission")
        let last = try requireValue(docs.last, "last owned document")
        let lastURL = try requireValue(last.fileURL, "last disk file")
        try Data("replacement under budget".utf8).write(to: lastURL, options: .atomic)
        last.externalFile.check(prioritized: true)
        _ = spinUntil(timeout: 1, "activation fallback for last file under descriptor budget") {
            last.externalFile.notice == "Changed on disk"
        }
        check(last.editor.text != "replacement under budget", "capacity fallback retains Ask semantics")
        docs.forEach { $0.close() }
        docs.removeAll()
        _ = spinUntil("all scale vnode cancellation handlers close their original descriptor") {
            descriptors(in: folder).owned == baseline.owned
        }
        let end = descriptors(in: folder)
        check(end.owned == baseline.owned, "all file-backed document subscriptions released on close")
        print(
            "WATCH FDS count=\(number) reduced=\(reduced) before=\(before) armed=\(armed) after=\(end) baseline=\(baseline)"
        )
    }
}
