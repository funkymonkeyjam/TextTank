@testable import TextTankCore
import Foundation
import Darwin
@main struct SearchReplacementChecks {
    static func undoCases(in root: URL) async throws {
        let dir = root.appendingPathComponent("undo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt"]
        let files = names.map { dir.appendingPathComponent($0) }
        let original = Data("one 🥑\r\n".utf8), replacement = Data("two 🥑\r\n".utf8)
        for file in files { try original.write(to: file) }
        let a = files[0], b = files[1], c = files[2], d = files[3], e = files[4], f = files[5]
        let attr = "app.texttank.undo", old = Data("original attribute".utf8), fresh = Data("different attribute".utf8)
        func install(_ bytes: Data, _ key: String, _ file: URL) throws {
            guard bytes.withUnsafeBytes({ setxattr(file.path, key, $0.baseAddress, $0.count, 0, 0) }) == 0 else {
                throw POSIXError(.EIO)
            }
        }
        try install(old, attr, a)
        chmod(a.path, 0o640)
        let report = try await FolderSearch.search(FolderSearchRequest(directory: dir, query: "one"))
        var opts = SearchOptions()
        opts.query = "one"
        opts.replacement = "two"
        func makeBatch() throws -> URL {
            let writer = FolderReplacementBatch()
            let changed = try FolderReplacement.replace(
                directory: dir, matches: report.matches, options: opts, batch: writer)
            try require(
                changed.count == files.count && changed.allSatisfy { $0.status == .replaced },
                "six files committed to the Undo fixture")
            rejects("an active batch defers Undo") { _ = try FolderReplacement.undo(manifest: writer.manifest) }
            return writer.manifest
        }
        let manifest = try makeBatch()
        check(
            try FolderReplacementBatch.latestManifest()?.standardizedFileURL == manifest.standardizedFileURL,
            "newest confirmed batch resolves from disk")
        let cancelled = FolderSearchCancellation()
        cancelled.cancel()
        let noChange = try FolderReplacement.undo(manifest: manifest, cancellation: cancelled)
        check(
            try noChange.allSatisfy { $0.status == .cancelled } && Data(contentsOf: a) == replacement,
            "cancelled Undo keeps replacements and pending entries")
        let snap = try FolderReplacementBatch.read(manifest)
        let damaged = try requireValue(
            snap.entries.first { $0.0.path.hasSuffix("/e.txt") }, "private original selected for mismatch")
        let damagedBackup = manifest.deletingLastPathComponent().appendingPathComponent(damaged.0.backupName)
        try Data("damaged private copy".utf8).write(to: damagedBackup)
        try Data("later edit".utf8).write(to: b)
        try install(fresh, attr, a)
        try install(fresh, "app.texttank.new-after-replacement", a)
        chmod(a.path, 0o600)
        try original.write(to: f)
        let rows = try FolderReplacement.undo(
            manifest: manifest, excluding: [c],
            beforeCommit: { file in
                if file.lastPathComponent == "d.txt" { try! Data("just before rename".utf8).write(to: file) }
            })
        let statuses = Dictionary(uniqueKeysWithValues: rows.map { ($0.url.lastPathComponent, $0.status) })
        check(
            statuses == [
                "a.txt": .restored, "b.txt": .changed, "c.txt": .skipped, "d.txt": .changed, "e.txt": .failed,
                "f.txt": .alreadyOriginal
            ],
            "Undo reports original, externally changed, open, concurrent, corrupt-backup and already-original files separately"
        )
        var info = stat(), recovered = [UInt8](repeating: 0, count: old.count)
        check(
            try Data(contentsOf: a) == original && stat(a.path, &info) == 0 && info.st_mode & 0o777 == 0o640
                && getxattr(a.path, attr, &recovered, recovered.count, 0, 0) == old.count && Data(recovered) == old
                && getxattr(a.path, "app.texttank.new-after-replacement", nil, 0, 0, 0) < 0 && errno == ENOATTR,
            "restored exact UTF-8, CRLF, mode and original xattr set")
        check(
            try Data(contentsOf: b) == Data("later edit".utf8) && Data(contentsOf: c) == replacement
                && Data(contentsOf: d) == Data("just before rename".utf8) && Data(contentsOf: e) == replacement,
            "all skipped, conflicted and unverified files keep their bytes")
        let after = try FolderReplacementBatch.read(manifest)
        check(
            after.entries.filter { $0.1 == .restored }.count == 2
                && after.entries.filter { $0.1 == .replaced }.count == 4,
            "partial Undo preserves remaining recovery entries")
        try original.write(to: damagedBackup)
        let retry = try FolderReplacement.undo(manifest: manifest)
        check(
            try retry.filter { $0.status == .restored }.count == 2 && Data(contentsOf: c) == original
                && Data(contentsOf: e) == original && Data(contentsOf: b) == Data("later edit".utf8),
            "retry only restores remaining files whose replacement still matches")
        let again = try FolderReplacement.undo(manifest: manifest)
        check(
            again.filter { $0.status == .alreadyOriginal }.count == 4
                && again.filter { $0.status == .changed }.count == 2,
            "repeated Undo does not revisit older batches or overwrite external edits")
    }

    static func historyCases(in root: URL) async throws {
        let privateSupport = try IsolatedSupportDirectory("TextTankReplacementPolicy")
        defer { privateSupport.restore() }
        func make(_ name: String, batch: FolderReplacementBatch = FolderReplacementBatch()) async throws -> (URL, URL) {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let file = dir.appendingPathComponent("owned.txt")
            try Data("before".utf8).write(to: file)
            let matches = try await FolderSearch.search(FolderSearchRequest(directory: dir, query: "before")).matches
            var options = SearchOptions()
            options.query = "before"
            options.replacement = "after"
            let result = try FolderReplacement.replace(directory: dir, matches: matches, options: options, batch: batch)
            try require(result.first?.status == .replaced, "owned batch for " + name)
            return (batch.manifest, file)
        }
        let future = Date().addingTimeInterval(8 * 86400)
        let (a, original) = try await make("history-selected")
        let saved = try FolderReplacementBatch.read(a)
        check(
            try FolderReplacementHistory.retention() == .keep
                && FolderReplacementHistory.prune(now: future).removed == 0,
            "default retention preserves even an old completed batch")
        _ = try FolderReplacement.undo(manifest: a)
        rejects("a stale Undo confirmation cannot restore a newly changed batch") {
            _ = try FolderReplacement.undo(manifest: a, reviewed: saved)
        }
        rejects("a stale review cannot delete a changed batch") {
            try FolderReplacementHistory.delete(a, reviewed: saved)
        }
        let current = try FolderReplacementBatch.read(a)
        let unrelated = a.deletingLastPathComponent().appendingPathComponent("unrelated-note.txt")
        try Data("retain".utf8).write(to: unrelated)
        rejects("unknown members protect a private directory from deletion") {
            try FolderReplacementHistory.delete(a, reviewed: current)
        }
        check(
            try Data(contentsOf: unrelated) == Data("retain".utf8) && Data(contentsOf: original) == Data("before".utf8),
            "unspecified private item and source file survive refusal")
        try FileManager.default.removeItem(at: unrelated)
        try FolderReplacementHistory.delete(a, reviewed: current)
        check(
            try !FileManager.default.fileExists(atPath: a.deletingLastPathComponent().path)
                && Data(contentsOf: original) == Data("before".utf8),
            "explicit deletion removes only the confirmed private batch")
        let (b, user) = try await make("history-aged")
        let (broken, untouched) = try await make("history-incomplete")
        let marker = FileHandle(forWritingAtPath: broken.path)!
        _ = try marker.seekToEnd()
        try marker.write(contentsOf: Data("{".utf8))
        try marker.close()
        var active: FolderReplacementBatch? = FolderReplacementBatch()
        let (inUse, activeFile) = try await make("history-in-use", batch: active!)
        try FolderReplacementHistory.setRetention(.week, replacing: .keep)
        check(try FolderReplacementHistory.retention() == .week, "retention choice survives a fresh disk read")
        rejects("stale retention controls keep the newer preference") {
            try FolderReplacementHistory.setRetention(.month, replacing: .keep)
        }
        check(
            try FolderReplacementHistory.prune().removed == 0 && FileManager.default.fileExists(atPath: b.path),
            "in-period originals survive scheduled cleanup")
        let report = try FolderReplacementHistory.prune(now: future)
        check(
            try report.removed == 1 && !FileManager.default.fileExists(atPath: b.path)
                && FileManager.default.fileExists(atPath: broken.path)
                && FileManager.default.fileExists(atPath: inUse.path)
                && Data(contentsOf: user) == Data("after".utf8) && Data(contentsOf: untouched) == Data("after".utf8),
            "configured age removes only the old complete batch and retains interrupted and in-use records")
        withExtendedLifetime(active) {}
        active = nil
        let repaired = try FolderReplacementHistory.prune(now: future)
        check(
            try repaired.removed == 1 && !FileManager.default.fileExists(atPath: inUse.path)
                && Data(contentsOf: activeFile) == Data("after".utf8),
            "later cleanup succeeds after the writer releases its batch")
        let (interrupted, currentFile) = try await make("history-delete-interrupted")
        let dir = interrupted.deletingLastPathComponent()
        let retired = dir.deletingLastPathComponent().appendingPathComponent(".deleting-" + dir.lastPathComponent)
        try FileManager.default.moveItem(at: dir, to: retired)
        _ = try FolderReplacementHistory.prune()
        check(
            try !FileManager.default.fileExists(atPath: retired.path)
                && Data(contentsOf: currentFile) == Data("after".utf8),
            "restart completes an interrupted private deletion without touching the user's file")
        let protected = AppStorage.url(.folderReplacements).appendingPathComponent("Retention.json")
        let futurePolicy = Data("{\"version\":9,\"days\":7}".utf8)
        try futurePolicy.write(to: protected)
        rejects("future retention schema blocks automatic pruning") {
            _ = try FolderReplacementHistory.prune(now: future)
        }
        rejects("an unsupported policy cannot be silently overwritten") {
            try FolderReplacementHistory.setRetention(.keep, replacing: .week)
        }
        check(
            try Data(contentsOf: protected) == futurePolicy && FileManager.default.fileExists(atPath: broken.path),
            "unreadable settings and remaining private backup stay intact")
        let store = AppStorage.url(.folderReplacements)
        let preserved = privateSupport.url.appendingPathComponent("owned-store-offline")
        try FileManager.default.moveItem(at: store, to: preserved)
        let elsewhere = root.appendingPathComponent("owned-unrelated-directory")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        let sentinel = elsewhere.appendingPathComponent(".deleting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: store, withDestinationURL: elsewhere)
        rejects("a linked storage root cannot be pruned") { _ = try FolderReplacementHistory.prune(now: future) }
        rejects("a linked storage root cannot supply a batch list") { _ = try FolderReplacementBatch.listing() }
        check(
            FileManager.default.fileExists(atPath: sentinel.path),
            "cleanup preserves the separate directory behind a storage alias")
    }

    static func main() async {
        if CommandLine.arguments.count == 3 {
            let argument = URL(fileURLWithPath: CommandLine.arguments[2])
            do {
                switch CommandLine.arguments[1] {
                case "--interrupt-replacement":
                    let request = FolderSearchRequest(directory: argument, query: "restart-original")
                    let matches = try await FolderSearch.search(request).matches
                    var options = SearchOptions()
                    options.query = request.query
                    options.replacement = "restart-replaced"
                    _ = try FolderReplacement.replace(
                        directory: argument, matches: matches, options: options,
                        beforeCommit: { _ in _exit(23) })
                case "--undo-already-original":
                    let rows = try FolderReplacement.undo(manifest: argument)
                    exit(rows.count == 1 && rows[0].status == .alreadyOriginal ? 0 : 2)
                case "--inspect-replacement":
                    let entries = try FolderReplacementBatch.read(argument).entries
                    guard entries.count == 1, entries[0].1 == .prepared else { exit(2) }
                    let backup = argument.deletingLastPathComponent().appendingPathComponent(entries[0].0.backupName)
                    let bytes = try Data(contentsOf: backup)
                    guard bytes == Data("restart-original".utf8),
                        entries[0].0.originalSHA256 == FolderSearch.sha256Hex(bytes)
                    else { exit(2) }
                    exit(0)
                default: break
                }
            } catch { print(error) }
            exit(1)
        }
        await Checks.run("SearchReplacementChecks") {
            let isolated = try IsolatedSupportDirectory("TextTankReplacementSupport")
            defer { isolated.restore() }
            setbuf(stdout, nil)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankReplacement-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt"),
                c = root.appendingPathComponent("c.txt")
            let original = try FileCodec.encode("🥑 key=12\r\n", format: FileFormat(encoding: .utf16LE, bom: true))
            try original.write(to: a)
            try Data("key=34".utf8).write(to: b)
            try Data("key=56".utf8).write(to: c)
            chmod(a.path, 0o640)
            let attribute = Data("metadata fixture".utf8)
            let setAttribute = attribute.withUnsafeBytes {
                setxattr(a.path, "app.texttank.test", $0.baseAddress, $0.count, 0, 0)
            }
            check(setAttribute == 0, "test metadata installed")
            // F128: back-date the file so a fresh modification time is unambiguous.
            var oldTimes = [timeval(tv_sec: 1_577_836_800, tv_usec: 0), timeval(tv_sec: 1_577_836_800, tv_usec: 0)]
            check(utimes(a.path, &oldTimes) == 0, "test file back-dated")
            var dated = stat()
            stat(a.path, &dated)
            check(dated.st_mtimespec.tv_sec == 1_577_836_800, "back-dated modification time observed")
            // F20/G343: an extended replacement that decodes to an unpaired surrogate must not reach disk.
            let lone = root.appendingPathComponent("lone.txt")
            try Data("key lone".utf8).write(to: lone)
            var loneRequest = FolderSearchRequest(directory: root, query: "lone")
            loneRequest.mode = .extended
            loneRequest.extensions = ["txt"]
            let loneReport = try await FolderSearch.search(loneRequest)
            check(loneReport.matches.count == 1, "fixture: one match for the surrogate replacement case")
            var loneOptions = SearchOptions()
            loneOptions.mode = .extended
            loneOptions.query = "lone"
            loneOptions.replacement = "\\uD83D"
            let loneResult = try FolderReplacement.replace(
                directory: root, matches: loneReport.matches, options: loneOptions)
            check(
                loneResult.count == 1 && loneResult[0].status == .failed && loneResult[0].backup == nil
                    && loneResult[0].message.contains("surrogate"),
                "unpaired-surrogate replacement fails the file with an explanation")
            check(
                try Data(contentsOf: lone) == Data("key lone".utf8),
                "unpaired-surrogate replacement leaves file bytes identical")
            check(
                try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [
                    "a.txt", "b.txt", "c.txt", "lone.txt"
                ], "unpaired-surrogate replacement leaves no backup, journal or temporary file")
            try FileManager.default.removeItem(at: lone)
            var request = FolderSearchRequest(directory: root, query: "key=(\\d+)")
            request.mode = .regularExpression
            let report = try await FolderSearch.search(request)
            var options = SearchOptions()
            options.mode = .regularExpression
            options.query = request.query
            options.replacement = "value=$1"
            let result = try FolderReplacement.replace(
                directory: root, matches: report.matches, options: options, excluding: [c])
            if result.contains(where: { $0.status == .failed }) { print(result.map { $0.message }) }
            check(
                result.filter { $0.status == .replaced }.count == 2, "two disk files replaced with individual outcomes")
            check(
                try FileCodec.decode(Data(contentsOf: a)).text == "🥑 value=12\r\n",
                "UTF16 BOM Unicode and CRLF preserved")
            let aResult = result.first { $0.url.lastPathComponent == "a.txt" }!
            check(try Data(contentsOf: aResult.backup!) == original, "byte-exact original backup retained")
            let journal = try FolderReplacementBatch.read(try requireValue(aResult.recoveryReport, "batch manifest"))
            let item = try requireValue(journal.entries.first { $0.0.path == aResult.url.path }, "record for a.txt")
            let store = AppStorage.url(.folderReplacements).resolvingSymlinksInPath().standardizedFileURL
            check(
                try journal.entries.count == 2 && item.1 == .replaced
                    && item.0.originalSHA256 == FolderSearch.sha256Hex(original)
                    && item.0.replacementSHA256 == FolderSearch.sha256Hex(Data(contentsOf: a))
                    && item.0.originalMode == 0o640 && aResult.backup!.lastPathComponent == item.0.backupName
                    && aResult.backup!.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
                        .standardizedFileURL.path == store.path
                    && Set(result.compactMap(\.recoveryReport)).count == 1,
                "one private batch records original bytes, mode and both content fingerprints for both files")
            var backupInfo = stat(), batchInfo = stat(), manifestInfo = stat()
            var privateAttribute = [UInt8](repeating: 0, count: 100)
            let attributeSize = getxattr(
                aResult.backup!.path, "app.texttank.test", &privateAttribute, privateAttribute.count, 0, 0)
            check(
                stat(aResult.backup!.path, &backupInfo) == 0 && backupInfo.st_mode & 0o777 == 0o600
                    && stat(aResult.recoveryReport!.path, &manifestInfo) == 0 && manifestInfo.st_mode & 0o777 == 0o600
                    && stat(aResult.backup!.deletingLastPathComponent().path, &batchInfo) == 0
                    && batchInfo.st_mode & 0o777 == 0o700
                    && attributeSize == attribute.count && Data(privateAttribute.prefix(attribute.count)) == attribute,
                "private original preserves file attributes with owner-only access")
            var containing = FolderSearchRequest(directory: store.deletingLastPathComponent(), query: "key")
            containing.includeHidden = true
            let containingReport = try await FolderSearch.search(containing)
            check(
                containingReport.matches.isEmpty && containingReport.excludedCounts[.recoveryArtifact] == 1,
                "a search above the private store skips its entire subtree")
            let privateSearch = try await FolderSearch.search(FolderSearchRequest(directory: store, query: "key"))
            check(
                privateSearch.matches.isEmpty && privateSearch.excludedCounts[.recoveryArtifact] == 1,
                "a directly selected private recovery store is excluded from search")
            var info = stat()
            stat(a.path, &info)
            check(info.st_mode & 0o777 == 0o640, "original permission mode retained")
            check(
                info.st_mtimespec.tv_sec > dated.st_mtimespec.tv_sec
                    && abs(Int(info.st_mtimespec.tv_sec) - Int(Date().timeIntervalSince1970)) < 120,
                "replaced file has fresh modification time")
            check(
                info.st_birthtimespec.tv_sec <= dated.st_birthtimespec.tv_sec, "replaced file keeps its creation date")
            var metadata = [UInt8](repeating: 0, count: 100)
            let size = getxattr(a.path, "app.texttank.test", &metadata, metadata.count, 0, 0)
            check(
                size == attribute.count && Data(metadata.prefix(max(0, size))) == attribute,
                "extended metadata preserved")
            check(
                try String(contentsOf: c, encoding: .utf8) == "key=56"
                    && result.first { $0.url.lastPathComponent == "c.txt" }?.status == .skipped,
                "open document excluded without disk edits")
            let again = try FolderReplacement.replace(directory: root, matches: report.matches, options: options)
            check(
                again.filter { $0.status == .conflict }.count == 2,
                "old search fingerprints reject repeat after file change")
            var fresh = FolderSearchRequest(directory: root, query: "value=(\\d+)")
            fresh.mode = .regularExpression
            fresh.extensions = ["txt"]
            let before = try await FolderSearch.search(fresh)
            options.query = fresh.query
            options.replacement = "next=$1"
            func artifacts() throws -> [String] {
                try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".texttank-") }
                    .sorted()
            }
            let artifactsBeforeConflict = try artifacts()
            let changed = try FolderReplacement.replace(
                directory: root, matches: before.matches, options: options,
                beforeCommit: { url in
                    if url.lastPathComponent == "a.txt" { try! Data("external writer".utf8).write(to: url) }
                })
            check(
                try changed.first { $0.url.lastPathComponent == "a.txt" }?.status == .conflict
                    && String(contentsOf: a, encoding: .utf8) == "external writer",
                "external writer before commit not overwritten")
            check(
                changed.first { $0.url.lastPathComponent == "b.txt" }?.status == .replaced,
                "independent file completes despite other conflict")
            // F39: a file that was not changed keeps no recovery copy and no "prepared" journal.
            let conflicted = changed.first { $0.url.lastPathComponent == "a.txt" }
            check(
                conflicted?.backup == nil && conflicted?.recoveryReport == nil,
                "a conflicting file reports no recovery copy")
            check(
                try changed.filter { $0.status == .replaced }.count == 2
                    && artifacts().isEmpty && artifactsBeforeConflict.isEmpty
                    && FolderReplacementBatch.read(changed.compactMap(\.recoveryReport)[0]).entries.count == 2,
                "only the two replaced files have private recovery entries and the working tree stays clean")
            let bBytes = try Data(contentsOf: b), cBytes = try Data(contentsOf: c),
                artifactsBeforeCancel = try artifacts()
            var later = FolderSearchRequest(directory: root, query: "next=(\\d+)")
            later.mode = .regularExpression
            later.extensions = ["txt"]
            let beforeCancel = try await FolderSearch.search(later)
            try require(
                Set(beforeCancel.matches.map { $0.url.lastPathComponent }) == ["b.txt", "c.txt"],
                "fixture: two files match before the cancelled run")
            options.query = later.query
            options.replacement = "last=$1"
            let batchesBeforeCancel = try Set(FileManager.default.contentsOfDirectory(atPath: store.path))
            let stopping = FolderSearchCancellation()
            let stopped = try FolderReplacement.replace(
                directory: root, matches: beforeCancel.matches, options: options, cancellation: stopping,
                beforeCommit: { _ in stopping.cancel() })
            check(
                stopped.count == 2
                    && stopped.allSatisfy { $0.status == .cancelled && $0.backup == nil && $0.recoveryReport == nil },
                "cancelling before the commit reports no recovery copy")
            let duringBuild = FolderSearchCancellation()
            duringBuild.cancel()
            rejects("a cancelled token stops the replacement text being built", where: { ($0 as NSError).code == 9 }) {
                _ = try SearchCore.replacing(
                    "abc", with: [SearchHit(range: NSRange(location: 0, length: 1), replacement: "X")],
                    cancellation: duringBuild.engineToken)
            }
            check(
                try artifacts() == artifactsBeforeCancel && Data(contentsOf: b) == bBytes
                    && Data(contentsOf: c) == cBytes
                    && Set(FileManager.default.contentsOfDirectory(atPath: store.path)) == batchesBeforeCancel,
                "cancelling before the commit leaves no recovery copy or journal and the files unchanged")
            // F39: recovery copies are never search results, even with hidden files included,
            // and never replacement targets.
            // Explicit fixtures from previous TextTank releases remain excluded.
            let legacyA = root.appendingPathComponent(".texttank-backup-a")
            let legacyB = root.appendingPathComponent(".texttank-backup-b")
            try original.write(to: legacyA)
            try Data("key=34".utf8).write(to: legacyB)
            let legacyFingerprint = ["originalSHA256": FolderSearch.sha256Hex(Data("key=34".utf8))]
            try JSONEncoder().encode(legacyFingerprint).write(to: legacyB.appendingPathExtension("json"))
            var hiddenToo = FolderSearchRequest(directory: root, query: "key=")
            hiddenToo.includeHidden = true
            let withHidden = try await FolderSearch.search(hiddenToo)
            let backups = try artifacts().filter { !$0.hasSuffix(".json") }
            try require(
                backups.contains { (try? Data(contentsOf: root.appendingPathComponent($0))) == original },
                "fixture: a recovery copy holding the searched text exists")
            check(
                !withHidden.matches.contains { $0.url.lastPathComponent.hasPrefix(".texttank-") },
                "recovery copies are not searched when hidden files are included")
            check(
                try withHidden.excludedCounts[.recoveryArtifact] == artifacts().count && withHidden.isComplete,
                "recovery copies and journals are counted as exclusions and leave coverage complete")
            hiddenToo.listsPolicyExclusions = true
            let listed = try await FolderSearch.search(hiddenToo)
            check(
                try Set(listed.skipped.filter { $0.reason == .recoveryArtifact }.map { $0.url.lastPathComponent })
                    == Set(artifacts()), "every recovery copy and journal appears in the opt-in exclusion list")
            // The forged match is built under the kernel's canonical root, as search results are, so
            // the artifact rule is the only thing between it and a rewrite.
            let template = beforeCancel.matches[0]
            let canonicalRoot = template.url.deletingLastPathComponent()
            let openedRoot = try FolderSearch.openCanonicalDirectory(root)
            close(openedRoot.fd)
            try require(
                canonicalRoot.path == openedRoot.path, "fixture: the forged match is inside the canonical root")
            let backupURL = canonicalRoot.appendingPathComponent(
                try requireValue(
                    backups.first { (try? Data(contentsOf: root.appendingPathComponent($0))) == Data("key=34".utf8) },
                    "fixture: the recovery copy of b.txt"))
            let backupJournal = try JSONDecoder().decode(
                [String: String].self, from: Data(contentsOf: backupURL.appendingPathExtension("json")))
            let forged = FolderSearchMatch(
                url: backupURL, line: 1, columnUTF16: 1, utf16Range: .init(location: 0, length: 6),
                utf8Range: .init(location: 0, length: 6), preview: template.preview,
                previewMatchRange: template.previewMatchRange, isMatchTruncatedInPreview: false,
                sourceSHA256: try requireValue(
                    backupJournal["originalSHA256"], "fixture: the journal records the hash of the recovery copy"))
            var forgedOptions = SearchOptions()
            forgedOptions.query = "key=34"
            forgedOptions.replacement = "overwritten"
            let forgedResult = try FolderReplacement.replace(directory: root, matches: [forged], options: forgedOptions)
            check(
                try forgedResult.first?.status == .failed && Data(contentsOf: backupURL) == Data("key=34".utf8),
                "a recovery copy is refused as a replacement target and keeps its bytes")
            check(
                try !artifacts().contains {
                    $0.hasPrefix(".texttank-replacement-") || $0.hasPrefix(".texttank-report-")
                },
                "no replacement or report temporaries remain after any run")
            // G352: files whose names start with a combining mark are inside the root.
            let markedDirectory = root.appendingPathComponent("sub").appendingPathComponent("\u{301}dir")
            try FileManager.default.createDirectory(at: markedDirectory, withIntermediateDirectories: true)
            let lead = root.appendingPathComponent("\u{301}lead.txt"),
                inner = markedDirectory.appendingPathComponent("inner.txt")
            try Data("mark here".utf8).write(to: lead)
            try Data("mark there".utf8).write(to: inner)
            let markedMatches = try await FolderSearch.search(FolderSearchRequest(directory: root, query: "mark"))
            var markedOptions = SearchOptions()
            markedOptions.query = "mark"
            markedOptions.replacement = "sign"
            let markedResult = try FolderReplacement.replace(
                directory: root, matches: markedMatches.matches, options: markedOptions)
            check(
                try markedResult.count == 2 && markedResult.allSatisfy { $0.status == .replaced }
                    && Data(contentsOf: lead) == Data("sign here".utf8)
                    && Data(contentsOf: inner) == Data("sign there".utf8),
                "files whose names start with a combining mark are replaced")
            let token = FolderSearchCancellation()
            token.cancel()
            let cancelled = try FolderReplacement.replace(
                directory: root, matches: before.matches, options: options, cancellation: token)
            check(cancelled.allSatisfy { $0.status == .cancelled }, "cancellation reports unsent files")
            let link = root.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b)
            var fake = before.matches.first { $0.url.lastPathComponent == "b.txt" }!
            fake = FolderSearchMatch(
                url: link, line: fake.line, columnUTF16: fake.columnUTF16, utf16Range: fake.utf16Range,
                utf8Range: fake.utf8Range, preview: fake.preview, previewMatchRange: fake.previewMatchRange,
                isMatchTruncatedInPreview: false, sourceSHA256: fake.sourceSHA256)
            check(
                try FolderReplacement.replace(directory: root, matches: [fake], options: options).first?.status
                    == .failed, "symlink leaf rejected")
            let unwritable = root.appendingPathComponent("unwritable-parent")
            try FileManager.default.createDirectory(at: unwritable, withIntermediateDirectories: true)
            defer { chmod(unwritable.path, 0o700) }
            let deniedFile = unwritable.appendingPathComponent("denied.txt")
            try Data("old".utf8).write(to: deniedFile)
            let deniedReport = try await FolderSearch.search(FolderSearchRequest(directory: unwritable, query: "old"))
            try require(chmod(unwritable.path, 0o500) == 0, "F206 fixture: parent directory is not writable")
            var deniedOptions = SearchOptions()
            deniedOptions.query = "old"
            deniedOptions.replacement = "new"
            let deniedResult = try FolderReplacement.replace(
                directory: unwritable, matches: deniedReport.matches, options: deniedOptions)
            check(
                deniedResult.count == 1 && deniedResult[0].status == .failed
                    && deniedResult[0].message.lowercased().contains("permission denied")
                    && deniedResult[0].message.lowercased().contains("create"),
                "F206 a real denied replacement preserves errno and names the failed operation")
            check(
                try Data(contentsOf: deniedFile) == Data("old".utf8),
                "F206 a denied replacement preserves original bytes")
            chmod(unwritable.path, 0o700)
            let shared = FolderReplacementBatch()
            var mixedOptions = SearchOptions()
            mixedOptions.query = "cross-root"
            mixedOptions.replacement = "changed"
            for leaf in ["first-root", "second-root"] {
                let directory = root.appendingPathComponent(leaf)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let file = directory.appendingPathComponent("document.txt")
                try Data("cross-root".utf8).write(to: file)
                let report = try await FolderSearch.search(
                    FolderSearchRequest(directory: directory, query: mixedOptions.query))
                let replaced = try FolderReplacement.replace(
                    directory: directory, matches: report.matches,
                    options: mixedOptions, batch: shared)
                check(
                    replaced.first?.status == .replaced && replaced.first?.recoveryReport == shared.manifest,
                    "workspace folder uses the same private batch: " + leaf)
            }
            let sharedItems = try FolderReplacementBatch.read(shared.manifest).entries
            check(
                sharedItems.count == 2 && Set(sharedItems.map { $0.0.root }).count == 2
                    && sharedItems.allSatisfy { $0.1 == .replaced },
                "one reopened workspace batch identifies both source roots")
            let interruptedRoot = root.appendingPathComponent("interrupted")
            try FileManager.default.createDirectory(at: interruptedRoot, withIntermediateDirectories: false)
            let interruptedFile = interruptedRoot.appendingPathComponent("document.txt")
            let initialBytes = Data("restart-original".utf8)
            try initialBytes.write(to: interruptedFile)
            func child(_ mode: String, _ path: URL) throws -> Int32 {
                let process = Process()
                process.executableURL = Checks.executable
                process.arguments = [mode, path.path]
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }
            let existing = Set(try FileManager.default.contentsOfDirectory(atPath: store.path))
            check(
                try child("--interrupt-replacement", interruptedRoot) == 23,
                "original batch writer terminated after persisting prepared state")
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: store.path))
            let interruptedBatch = try requireValue(after.subtracting(existing).first, "interrupted private batch")
            let interruptedManifest = store.appendingPathComponent(interruptedBatch).appendingPathComponent(
                "manifest.jsonl")
            check(
                try child("--inspect-replacement", interruptedManifest) == 0
                    && Data(contentsOf: interruptedFile) == initialBytes
                    && FileManager.default.contentsOfDirectory(atPath: interruptedRoot.path) == ["document.txt"],
                "a fresh process reads interrupted private originals and the user directory remains intact")
            check(
                try child("--undo-already-original", interruptedManifest) == 0
                    && FolderReplacementBatch.read(interruptedManifest).entries.first?.1 == .restored
                    && Data(contentsOf: interruptedFile) == initialBytes,
                "a newly launched Undo recognizes a prepared entry whose file was never changed")
            try await undoCases(in: root)
            try await historyCases(in: root)
            Checks.summary { "PASS SearchReplacementChecks: \(Checks.count) assertions" }
        }
    }
}
