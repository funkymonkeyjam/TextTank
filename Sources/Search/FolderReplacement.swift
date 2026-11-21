// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import NativeSearch

package struct FolderReplacementOutcome: Sendable {
    package init(url: URL, status: Status, message: String, backup: URL?, recoveryReport: URL? = nil) {
        self.url = url
        self.status = status
        self.message = message
        self.backup = backup
        self.recoveryReport = recoveryReport
    }

    package enum Status: String, Sendable {
        case replaced, unchanged, conflict, skipped, failed, cancelled, timedOut, stopped
        package var displayName: String {
            switch self {
            case .replaced: return Strings.text("replacement.replaced", "Replaced")
            case .unchanged: return Strings.text("replacement.unchanged", "Unchanged")
            case .conflict: return Strings.text("replacement.conflict", "Changed since search")
            case .skipped: return Strings.text("replacement.skipped", "Skipped")
            case .failed: return Strings.text("replacement.failed", "Failed")
            case .timedOut: return "Search timed out"
            case .stopped: return "Stopped early"
            case .cancelled: return Strings.text("replacement.cancelled", "Cancelled")
            }
        }
    }
    package let url: URL, status: Status, message: String, backup: URL?
    package var recoveryReport: URL?
}
/// Explicit disk replacement of a completed folder-search snapshot. Each file has
/// its own byte-exact recovery copy. This is NOT an atomic multi-file transaction.
/// Descriptor traversal rejects symlink parents/leaves. Compare just before rename
/// detects ordinary external changes; noncooperating writers can still race the
/// final stat/rename interval. Open documents are excluded by the UI.
package enum FolderReplacement {
    private enum Failure: LocalizedError {
        case unsafe, changed, inputTooLarge, resultTooLarge, cancelled
        var errorDescription: String? {
            switch self {
            case .unsafe: return "Not a writable single-link regular file inside the chosen directory."
            case .changed: return "File changed since search; search again before replacing."
            case .inputTooLarge:
                return
                    "The source exceeds the \(SizePolicy.describe(SizePolicy.standard.folderInput)) replacement input limit. Choose a smaller file."
            case .resultTooLarge:
                return
                    "The encoded result exceeds the \(SizePolicy.describe(SizePolicy.standard.folderReplacementOutput)) replacement output limit. Shorten the replacement or target fewer matches."
            case .cancelled: return "Cancelled before committing this file."
            }
        }
    }
    package struct OperationBudget: Sendable {
        private let deadline: TimeInterval
        private let clock: @Sendable () -> TimeInterval
        private let perFile: TimeInterval
        private var consecutiveTimeouts = 0
        private var exhausted = false

        package init(
            seconds: TimeInterval = 30, perFile: TimeInterval = SearchCore.defaultTimeLimit,
            clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.clock = clock
            deadline = clock() + seconds
            self.perFile = perFile
        }

        fileprivate func remaining(_ cancellation: FolderSearchCancellation) throws -> TimeInterval {
            if cancellation.isCancelled || Task.isCancelled { throw Failure.cancelled }
            if consecutiveTimeouts >= 3 { throw Limit.repeatedTimeout }
            let seconds = deadline - clock()
            guard !exhausted, seconds > 0 else { throw Limit.elapsed }
            return seconds
        }

        fileprivate mutating func search(_ text: String, options: SearchOptions, cancellation: FolderSearchCancellation)
            throws -> SearchReport
        {
            let available = try remaining(cancellation)
            do {
                let matches = try SearchCore.search(
                    text, options: options, cancellation: cancellation.engineToken,
                    limit: 100_000, timeLimit: min(perFile, available))
                consecutiveTimeouts = 0
                return matches
            } catch {
                _ = try remaining(cancellation)
                guard TTSearchEngine.timedOut(error as NSError) else {
                    consecutiveTimeouts = 0
                    throw error
                }
                if available <= perFile {
                    exhausted = true
                    throw Limit.elapsed
                }
                consecutiveTimeouts += 1
                throw consecutiveTimeouts >= 3 ? Limit.repeatedTimeout : Limit.fileTimeout
            }
        }
    }

    private enum Limit: LocalizedError {
        case elapsed, repeatedTimeout, fileTimeout, comparisonTime, patchOutput(Int), comparison(ReviewBudgetReason)
        var errorDescription: String? {
            switch self {
            case .elapsed:
                return "The folder operation reached its time limit. Select fewer files or simplify the search."
            case .repeatedTimeout:
                return "Three consecutive file searches timed out. Simplify the pattern before trying again."
            case .fileTimeout: return "This file search timed out. Simplify the pattern or choose a smaller file."
            case .comparisonTime: return "Comparing this file exceeded the preview time limit. Select a smaller change."
            case .patchOutput(let limit):
                return
                    "The patch exceeds the \(SizePolicy.describe(limit)) output limit. Preview fewer files or smaller changes."
            case .comparison(let reason):
                return "The comparison reached its \(reason.rawValue) limit. Preview a smaller file or change."
            }
        }
    }
    private struct Projection {
        let original: Data, encoded: Data, oldText: String, newText: String, format: FileFormat, count: Int
    }
    private struct SelectedFile {
        let parent: Int32, source: Int32, info: stat, parts: [String]
        init(root: Int32, prefix: String, url: URL, privateRoot: String) throws {
            guard let parts = FolderSearch.relativeComponents(of: url.path, under: prefix),
                !FolderSearch.isRecoveryArtifact(parts[parts.count - 1]),
                !FolderReplacementBatch.contains(url.path, in: privateRoot)
            else { throw Failure.unsafe }
            let parent = try openParent(root: root, parts: parts)
            let source = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            var info = stat()
            guard source >= 0, fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                info.st_nlink == 1, info.st_mode & 0o222 != 0, info.st_uid == getuid()
            else {
                close(parent)
                if source >= 0 { close(source) }
                throw Failure.unsafe
            }
            self.parts = parts
            self.parent = parent
            self.source = source
            self.info = info
        }
        func closeDescriptors() {
            close(source)
            close(parent)
        }
        func project(
            url: URL, expected: String, options: SearchOptions, cancellation: FolderSearchCancellation,
            budget: inout OperationBudget
        ) throws
            -> Projection
        {
            guard info.st_size >= 0, info.st_size <= SizePolicy.standard.folderInput else {
                throw Failure.inputTooLarge
            }
            let original = try read(
                source, size: Int(info.st_size), cancellation: cancellation, path: url.path, budget: budget)
            guard sha(original) == expected else { throw Failure.changed }
            let decoded = try FileCodec.decode(original)
            let found = try budget.search(decoded.text, options: options, cancellation: cancellation)
            _ = try budget.remaining(cancellation)
            guard !found.truncated else {
                throw FolderSearchError.invalidRequest("Replacement result limit reached; file not changed.")
            }
            let output: String
            do {
                output = try SearchCore.replacing(
                    decoded.text, with: found.hits, cancellation: cancellation.engineToken)
            } catch {
                if cancellation.isCancelled { throw Failure.cancelled }
                throw error
            }
            let encoded = try FileCodec.encode(output, format: decoded.format)
            _ = try budget.remaining(cancellation)
            guard encoded.count <= SizePolicy.standard.folderReplacementOutput else { throw Failure.resultTooLarge }
            return Projection(
                original: original, encoded: encoded, oldText: decoded.text,
                newText: output, format: decoded.format, count: found.hits.count)
        }
    }
    static package func replace(
        directory: URL, matches: [FolderSearchMatch], options: SearchOptions, excluding: Set<URL> = [],
        cancellation: FolderSearchCancellation = FolderSearchCancellation(),
        batch: FolderReplacementBatch = FolderReplacementBatch(), beforeCommit: ((URL) -> Void)? = nil
    ) throws -> [FolderReplacementOutcome] {
        var budget = OperationBudget()
        return try replace(
            directory: directory, matches: matches, options: options, excluding: excluding,
            cancellation: cancellation, batch: batch, budget: &budget, beforeCommit: beforeCommit)
    }

    /// All roots of a confirmed user operation share their timeout streak, deadline and Undo batch.
    static package func replaceSelected(
        fallbackDirectory: URL, matches: [FolderSearchMatch], options: SearchOptions, excluding: Set<URL> = [],
        cancellation: FolderSearchCancellation = .init(), budget initialBudget: OperationBudget = .init(),
        beforeCommit: ((URL) -> Void)? = nil
    ) -> [FolderReplacementOutcome] {
        let roots = Dictionary(grouping: matches, by: { $0.sourceRoot ?? fallbackDirectory })
        let batch = FolderReplacementBatch()
        var budget = initialBudget, results: [FolderReplacementOutcome] = []
        for directory in roots.keys.sorted(by: { $0.path < $1.path }) {
            let selected = roots[directory]!
            do {
                results += try replace(
                    directory: directory, matches: selected, options: options, excluding: excluding,
                    cancellation: cancellation, batch: batch, budget: &budget, beforeCommit: beforeCommit)
            } catch {
                results += Set(selected.map(\.url)).sorted(by: { $0.path < $1.path }).map {
                    problem(error, url: $0, backup: nil, report: nil)
                }
            }
        }
        return results
    }

    private static func problem(_ error: Error, url: URL, backup: URL?, report: URL?) -> FolderReplacementOutcome {
        let status: FolderReplacementOutcome.Status
        switch error {
        case Failure.cancelled, is CancellationError: status = .cancelled
        case Limit.fileTimeout: status = .timedOut
        case Limit.elapsed, Limit.repeatedTimeout: status = .stopped
        default: status = .failed
        }
        return .init(
            url: url, status: status, message: error.localizedDescription, backup: backup, recoveryReport: report)
    }

    private static func replace(
        directory: URL, matches: [FolderSearchMatch], options: SearchOptions, excluding: Set<URL>,
        cancellation: FolderSearchCancellation, batch: FolderReplacementBatch, budget: inout OperationBudget,
        beforeCommit: ((URL) -> Void)?
    ) throws -> [FolderReplacementOutcome] {
        do { _ = try budget.remaining(cancellation) } catch {
            return Set(matches.map(\.url)).sorted(by: { $0.path < $1.path }).map {
                problem(error, url: $0, backup: nil, report: nil)
            }
        }
        guard let opened = try? FolderSearch.openCanonicalDirectory(directory) else { throw Failure.unsafe }
        let root = opened.fd, rootPath = opened.path, prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        defer { close(root) }
        let privateRoot = FolderReplacementBatch.canonicalPath(of: batch.directory.deletingLastPathComponent())
        let excluded = Set(excluding.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let grouped = Dictionary(grouping: matches, by: { $0.url })
        var results: [FolderReplacementOutcome] = []
        for url in grouped.keys.sorted(by: { $0.path < $1.path }) {
            do { _ = try budget.remaining(cancellation) } catch {
                results.append(problem(error, url: url, backup: nil, report: nil))
                continue
            }
            if excluded.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) {
                results.append(
                    .init(
                        url: url, status: .skipped,
                        message: "File is open in TextTank; use All Open Documents replacement and Save.", backup: nil))
                continue
            }
            guard let fingerprints = grouped[url].map({ Set($0.compactMap(\.sourceSHA256)) }), fingerprints.count == 1,
                let expected = fingerprints.first
            else {
                results.append(
                    .init(
                        url: url, status: .conflict,
                        message: "Search snapshot has no unique source fingerprint; search again.", backup: nil))
                continue
            }
            var backup: URL?, reportURL: URL?
            do {
                let file = try SelectedFile(root: root, prefix: prefix, url: url, privateRoot: privateRoot)
                defer { file.closeDescriptors() }
                let parent = file.parent, source = file.source, initial = file.info, name = file.parts.last!
                let projection = try file.project(
                    url: url, expected: expected, options: options, cancellation: cancellation, budget: &budget)
                let original = projection.original, encoded = projection.encoded
                if encoded == original {
                    results.append(.init(url: url, status: .unchanged, message: "No byte changes.", backup: nil))
                    continue
                }
                let stage = try StagingFile(for: url, parent: parent)
                let temp = stage.file
                try write(encoded, to: temp, path: url.path)
                // Copy permissions, ownership, ACLs, extended attributes and flags
                // from the still-open source descriptor, without copying its data.
                // COPYFILE_METADATA also copies the source's timestamps. The content is new, so
                // stamp the current time: build tools, backups and other editors detect changes
                // by modification time. The creation date and all other metadata are kept.
                guard fcopyfile(source, temp, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0, futimens(temp, nil) == 0,
                    fsync(temp) == 0
                else {
                    throw FileOperationFailure(
                        errno, operation: "update file metadata or replacement beside", path: url.path)
                }
                let entry = FolderReplacementBatch.Entry(
                    id: UUID(), root: rootPath, path: url.path, originalSHA256: expected,
                    replacementSHA256: sha(encoded), originalMode: UInt16(initial.st_mode & 0o7777))
                _ = try budget.remaining(cancellation)
                backup = try batch.prepare(source: source, original: original, entry: entry)
                reportURL = batch.manifest
                var renameAttempted = false
                do {
                    beforeCommit?(url)
                    _ = try budget.remaining(cancellation)
                    try verifyCurrent(
                        parent: parent, name: name, initial: initial, bytes: original,
                        cancellation: cancellation, path: url.path, budget: budget)
                    _ = try budget.remaining(cancellation)
                    renameAttempted = true
                    guard renameat(stage.folder, StagingFile.name, parent, name) == 0 else {
                        throw FileOperationFailure(
                            errno, operation: "update file metadata or replacement beside", path: url.path)
                    }
                } catch {
                    if !renameAttempted {
                        try batch.mark(entry, .abandoned)
                        backup = nil
                        reportURL = nil
                    }
                    throw error
                }
                // Once renamed the file is changed even if directory durability fails.
                let durable = fsync(parent) == 0
                var journalConfirmed = true
                do { try batch.mark(entry, .replaced) } catch {
                    journalConfirmed = false
                }
                results.append(
                    .init(
                        url: url, status: .replaced,
                        message: "Replaced \(projection.count) match(es)."
                            + (durable && journalConfirmed
                                ? ""
                                : " Completion journal/directory synchronization failed; private recovery evidence retained."),
                        backup: backup, recoveryReport: reportURL))
            } catch let pending as FolderReplacementBatch.UnconfirmedPreparation {
                results.append(
                    .init(
                        url: url, status: .failed, message: pending.localizedDescription,
                        backup: pending.backup, recoveryReport: pending.manifest))
            } catch Failure.changed {
                results.append(
                    .init(
                        url: url, status: .conflict, message: Failure.changed.localizedDescription, backup: backup,
                        recoveryReport: reportURL))
            } catch {
                results.append(problem(error, url: url, backup: backup, report: reportURL))
            }
        }
        return results
    }
    package struct PatchPreview: Sendable {
        package let bytes: Data
        package let changedFiles: Int, skippedOpenFiles: Int, textConversions: Int
        package let roots: [URL]
        private let sourcePaths: Set<String>
        private let sourceIdentities: [FileSignature]

        fileprivate init(
            bytes: Data, changedFiles: Int, skippedOpenFiles: Int, textConversions: Int,
            roots: [URL], sourcePaths: Set<String>, sourceIdentities: [FileSignature]
        ) {
            self.bytes = bytes
            self.changedFiles = changedFiles
            self.skippedOpenFiles = skippedOpenFiles
            self.textConversions = textConversions
            self.roots = roots
            self.sourcePaths = sourcePaths
            self.sourceIdentities = sourceIdentities
        }
        package func checkDestination(_ url: URL, openFiles: [URL]) throws {
            try PrivateFileStore.validateLocalURL(url)
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            var info = stat()
            let exists = lstat(path, &info) == 0
            guard !sourcePaths.contains(path),
                !openFiles.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath().path == path }),
                !exists
                    || (info.st_nlink == 1
                        && !sourceIdentities.contains(where: {
                            $0.device == Int64(info.st_dev) && $0.inode == info.st_ino
                        }))
            else {
                throw FolderSearchError.invalidRequest("Choose a patch destination outside the matched and open files.")
            }
        }
    }

    /// Project the same completed search used by Replace, without staging source files or creating a backup batch.
    static package func preview(
        fallbackDirectory: URL, matches: [FolderSearchMatch], options: SearchOptions, excluding: Set<URL> = [],
        cancellation: FolderSearchCancellation = .init(), maximumBytes: Int = 32 * 1024 * 1024,
        budget initialBudget: OperationBudget = .init()
    ) async throws -> PatchPreview {
        let grouped = Dictionary(grouping: matches, by: { $0.sourceRoot ?? fallbackDirectory })
        let roots = grouped.keys.sorted { $0.path < $1.path }
        let excluded = Set(excluding.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        let privateRoot = FolderReplacementBatch.canonicalPath(of: AppStorage.url(.folderReplacements))
        let sourcePaths = Set(matches.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path })
        var patch = Data(), identities: [FileSignature] = []
        var changed = 0, skipped = 0, conversions = 0
        let limit = max(0, min(maximumBytes, 32 * 1024 * 1024))
        var budget = initialBudget
        for (index, directory) in roots.enumerated() {
            let opened = try FolderSearch.openCanonicalDirectory(directory)
            defer { close(opened.fd) }
            let prefix = opened.path.hasSuffix("/") ? opened.path : opened.path + "/"
            let byFile = Dictionary(grouping: grouped[directory]!, by: { $0.url })
            for url in byFile.keys.sorted(by: { $0.path < $1.path }) {
                guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
                _ = try budget.remaining(cancellation)
                if excluded.contains(url.standardizedFileURL.resolvingSymlinksInPath().path) {
                    skipped += 1
                    continue
                }
                let rows = byFile[url]!
                guard let expected = rows.first?.sourceSHA256,
                    rows.allSatisfy({ $0.sourceSHA256 == expected })
                else { throw Failure.changed }
                let file = try SelectedFile(root: opened.fd, prefix: prefix, url: url, privateRoot: privateRoot)
                defer { file.closeDescriptors() }
                let p = try file.project(
                    url: url, expected: expected, options: options, cancellation: cancellation, budget: &budget)
                identities.append(FileSignature(file.info))
                guard p.original != p.encoded else { continue }
                let utf8 = p.format.encoding == .utf8
                let a = try TextSnapshot(
                    bytes: utf8 ? p.original : Data(p.oldText.utf8), source: .file(UUID()), label: url.lastPathComponent
                )
                let b = try TextSnapshot(
                    bytes: utf8 ? p.encoded : Data(p.newText.utf8), source: .file(UUID()), label: url.lastPathComponent)
                var policy = ReviewDiffPolicy.default
                policy.seconds = min(policy.seconds, try budget.remaining(cancellation))
                let delta = await ReviewDiffEngine.compare(a, b, policy: policy)
                guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
                let parts = roots.count == 1 ? file.parts : ["folder-\(index + 1)"] + file.parts
                _ = try budget.remaining(cancellation)
                switch delta.completeness {
                case .complete: break
                case .cancelled: throw CancellationError()
                case .budgetStopped(.time): throw Limit.comparisonTime
                case .budgetStopped(let reason): throw Limit.comparison(reason)
                }
                policy.seconds = min(
                    CompareTimeAllowance.standard.patchPolicy.seconds, try budget.remaining(cancellation))
                let bytes: Data
                do {
                    bytes = try await UnifiedPatch.write(
                        original: a, modified: b, changes: delta,
                        policy: policy, relativeComponents: parts,
                        maximumPatchBytes: limit - patch.count)
                } catch let failure as MergeFailure {
                    _ = try budget.remaining(cancellation)
                    if failure.budget == .time { throw Limit.comparisonTime }
                    if failure.budget == .output { throw Limit.patchOutput(limit) }
                    throw failure
                }
                let note =
                    utf8
                    ? Data() : Data("# TextTank UTF-8 text preview of \(p.format.encoding.displayName) source\n".utf8)
                guard note.count + bytes.count <= limit - patch.count else { throw Limit.patchOutput(limit) }
                patch.append(note)
                patch.append(bytes)
                if !utf8 { conversions += 1 }
                changed += 1
            }
        }
        guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
        _ = try budget.remaining(cancellation)
        return PatchPreview(
            bytes: patch, changedFiles: changed, skippedOpenFiles: skipped, textConversions: conversions,
            roots: roots, sourcePaths: sourcePaths, sourceIdentities: identities)
    }
    package enum UndoStatus: String, Sendable {
        case restored, alreadyOriginal, skipped, changed, failed, cancelled
    }
    package struct UndoOutcome: Sendable {
        package let url: URL
        package let status: UndoStatus
        package let message: String
    }
    static package func undo(
        manifest: URL, reviewed: FolderReplacementBatch.Snapshot? = nil, excluding openFiles: Set<URL> = [],
        cancellation: FolderSearchCancellation = FolderSearchCancellation(), beforeCommit: ((URL) -> Void)? = nil
    ) throws -> [UndoOutcome] {
        let batch = try FolderReplacementBatch(reopening: manifest)
        let snapshot = try batch.snapshotForUndo(reviewed: reviewed)
        let excluded = Set(openFiles.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        return snapshot.entries.map { entry, state in
            let url = URL(fileURLWithPath: entry.path)
            if state == .restored {
                return .init(url: url, status: .alreadyOriginal, message: "Already processed by Undo.")
            }
            if cancellation.isCancelled {
                return .init(url: url, status: .cancelled, message: "Cancelled before restoring this file.")
            }
            if excluded.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) {
                return .init(url: url, status: .skipped, message: "File is open in TextTank.")
            }
            do {
                return try restore(entry: entry, batch: batch, cancellation: cancellation, beforeCommit: beforeCommit)
            } catch Failure.changed {
                return .init(
                    url: url, status: .changed,
                    message: "File changed since replacement. Kept current file and recovery copy.")
            } catch Failure.cancelled {
                return .init(url: url, status: .cancelled, message: "Cancelled before restoring this file.")
            } catch { return .init(url: url, status: .failed, message: error.localizedDescription) }
        }
    }

    private static func restore(
        entry: FolderReplacementBatch.Entry, batch: FolderReplacementBatch,
        cancellation: FolderSearchCancellation, beforeCommit: ((URL) -> Void)?
    ) throws -> UndoOutcome {
        let url = URL(fileURLWithPath: entry.path)
        let root = try FolderSearch.openCanonicalDirectory(URL(fileURLWithPath: entry.root))
        defer { close(root.fd) }
        guard root.path.utf8.elementsEqual(entry.root.utf8), entry.originalMode <= 0o7777,
            let parts = FolderSearch.relativeComponents(
                of: entry.path, under: root.path == "/" ? "/" : root.path + "/"),
            let leaf = parts.last, !FolderSearch.isRecoveryArtifact(leaf),
            !FolderReplacementBatch.contains(
                entry.path, in: FolderReplacementBatch.canonicalPath(of: AppStorage.url(.folderReplacements)))
        else { throw Failure.unsafe }
        let parent = try openParent(root: root.fd, parts: parts)
        defer { close(parent) }
        let current = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard current >= 0 else { throw FileOperationFailure(errno, operation: "open file for Undo", path: url.path) }
        defer { close(current) }
        var initial = stat()
        guard fstat(current, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG, initial.st_nlink == 1,
            initial.st_uid == getuid(), initial.st_mode & 0o222 != 0,
            initial.st_size >= 0, initial.st_size <= SizePolicy.standard.folderReplacementOutput
        else { throw Failure.unsafe }
        let currentBytes = try read(current, size: Int(initial.st_size), cancellation: cancellation, path: url.path)
        let currentDigest = sha(currentBytes)
        guard currentDigest == entry.replacementSHA256 || currentDigest == entry.originalSHA256 else {
            throw Failure.changed
        }
        if currentDigest == entry.originalSHA256 {
            // Includes a crash before forward rename, or after restoring but before the journal mark.
            try verifyCurrent(
                parent: parent, name: leaf, initial: initial, bytes: currentBytes, cancellation: cancellation,
                path: url.path)
            guard fsync(parent) == 0 else {
                throw FileOperationFailure(errno, operation: "confirm original file directory", path: url.path)
            }
            try batch.mark(entry, .restored)
            return .init(url: url, status: .alreadyOriginal, message: "File already contains its original bytes.")
        }
        let backup = batch.directory.appendingPathComponent(entry.backupName)
        let saved = try PrivateFileStore.openRegularFile(backup, maximumBytes: SizePolicy.standard.folderInput)
        defer { close(saved.descriptor) }
        guard saved.info.st_nlink == 1, saved.info.st_uid == getuid(), saved.info.st_mode & 0o077 == 0 else {
            throw Failure.unsafe
        }
        let bytes = try read(
            saved.descriptor, size: Int(saved.info.st_size), cancellation: cancellation, path: backup.path)
        guard sha(bytes) == entry.originalSHA256 else {
            throw FolderSearchError.invalidRequest(
                "Private original failed its content check. The current file was kept.")
        }
        let stage = try StagingFile(for: url, parent: parent)
        try write(bytes, to: stage.file, path: url.path)
        // Use the current file's creation date and ACL. Use only the saved original for xattrs and mode.
        guard fcopyfile(current, stage.file, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_ACL)) == 0,
            fcopyfile(saved.descriptor, stage.file, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0,
            fchmod(stage.file, mode_t(entry.originalMode)) == 0, futimens(stage.file, nil) == 0, fsync(stage.file) == 0
        else {
            throw FileOperationFailure(errno, operation: "prepare original file for Undo", path: url.path)
        }
        beforeCommit?(url)
        if cancellation.isCancelled { throw Failure.cancelled }
        try verifyCurrent(
            parent: parent, name: leaf, initial: initial, bytes: currentBytes, cancellation: cancellation,
            path: url.path)
        guard renameat(stage.folder, StagingFile.name, parent, leaf) == 0 else {
            throw FileOperationFailure(errno, operation: "restore original file", path: url.path)
        }
        let durable = fsync(parent) == 0
        do {
            // An unconfirmed rename keeps its previous recovery entry available for a safe retry.
            if durable { try batch.mark(entry, .restored) }
        } catch {
            return .init(
                url: url, status: .restored,
                message: "Original restored. The private manifest update could not be confirmed.")
        }
        return .init(
            url: url, status: .restored,
            message: durable
                ? "Original bytes, mode and extended attributes restored."
                : "Original restored. Directory synchronization could not be confirmed.")
    }
    private final class StagingFile {
        static let name = "replacement"
        let directory: URL
        let folder: Int32
        let file: Int32
        init(for url: URL, parent: Int32) throws {
            guard faccessat(parent, ".", W_OK, 0) == 0 else {
                throw FileOperationFailure(errno, operation: "create replacement in", path: url.path)
            }
            directory = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: url, create: true)
            do {
                folder = try PrivateFileStore.directoryDescriptor(for: directory.appendingPathComponent(Self.name))
            } catch {
                _ = rmdir(directory.path)
                throw error
            }
            file = openat(folder, Self.name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if file < 0 {
                let failure = FileOperationFailure(errno, operation: "create replacement for", path: url.path)
                close(folder)
                _ = rmdir(directory.path)
                throw failure
            }
        }
        deinit {
            close(file)
            _ = unlinkat(folder, Self.name, 0)
            close(folder)
            _ = rmdir(directory.path)
        }
    }
    private static func openParent(root: Int32, parts: [String]) throws -> Int32 {
        var parent = dup(root)
        guard parent >= 0 else { throw Failure.unsafe }
        for part in parts.dropLast() {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else {
                close(parent)
                throw Failure.unsafe
            }
            close(parent)
            parent = next
        }
        return parent
    }
    private static func verifyCurrent(
        parent: Int32, name: String, initial: stat, bytes: Data,
        cancellation: FolderSearchCancellation, path: String, budget: OperationBudget? = nil
    ) throws {
        let current = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard current >= 0 else { throw Failure.changed }
        defer { close(current) }
        var latest = stat()
        guard fstat(current, &latest) == 0, latest.st_mode & S_IFMT == S_IFREG,
            latest.st_ino == initial.st_ino, latest.st_dev == initial.st_dev,
            latest.st_size == initial.st_size, latest.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            latest.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec, latest.st_nlink == 1,
            latest.st_mode == initial.st_mode, latest.st_uid == initial.st_uid,
            latest.st_gid == initial.st_gid, latest.st_flags == initial.st_flags,
            latest.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
            latest.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
            try read(current, size: Int(latest.st_size), cancellation: cancellation, path: path, budget: budget)
                == bytes
        else { throw Failure.changed }
    }
    private static func sha(_ data: Data) -> String { FolderSearch.sha256Hex(data) }
    static func read(
        _ fd: Int32, size: Int, cancellation: FolderSearchCancellation, path: String, budget: OperationBudget? = nil
    ) throws
        -> Data
    {
        var output = Data(), bytes = [UInt8](repeating: 0, count: 65536)
        while output.count < size {
            _ = try budget?.remaining(cancellation)
            if cancellation.isCancelled { throw Failure.cancelled }
            let count = Darwin.read(fd, &bytes, min(bytes.count, size - output.count))
            if count < 0 && errno == EINTR { continue }
            if count < 0 { throw FileOperationFailure(errno, operation: "read", path: path) }
            guard count > 0 else { throw Failure.changed }
            output.append(contentsOf: bytes.prefix(count))
        }
        return output
    }
    static func write(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw FileOperationFailure(count < 0 ? errno : EIO, operation: "write", path: path)
                }
                offset += count
            }
        }
    }
}
