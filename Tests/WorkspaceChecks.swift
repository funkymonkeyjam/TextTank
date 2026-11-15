// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main struct WorkspaceChecks {
    static func main() {
        Checks.run("WorkspaceChecks") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankWorkspaceChecks-" + UUID().uuidString
            ).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            Checks.section("G360/F140 support path selection") {
                let fallback = root.appendingPathComponent("fallback", isDirectory: true)
                for value in [nil, "", "relative/folder", "/bad\0path"] as [String?] {
                    check(
                        AppStorage.resolve(override: value, fallback: fallback) == fallback,
                        "F140 empty, relative, absent or invalid overrides choose the supplied default without I/O")
                }
                check(
                    !FileManager.default.fileExists(atPath: fallback.path),
                    "F140 selecting a default path creates or reads no store")
                let before = ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]
                defer {
                    if let before {
                        setenv("TEXTTANK_SUPPORT_DIRECTORY", before, 1)
                    } else {
                        unsetenv("TEXTTANK_SUPPORT_DIRECTORY")
                    }
                }
                for name in ["first-root", "second-root"] {
                    let chosen = root.appendingPathComponent(name, isDirectory: true)
                    setenv("TEXTTANK_SUPPORT_DIRECTORY", chosen.path, 1)
                    check(
                        AppStorage.url(.commands) == chosen.appendingPathComponent("RunCommands.json"),
                        "G360 a new path lookup follows the current absolute override")
                    check(
                        !AppStorage.permitsLegacyDefaults,
                        "G360 an isolated root cannot implicitly read shared defaults")
                    check(
                        !FileManager.default.fileExists(atPath: chosen.path),
                        "G360 uncreated absolute roots are accepted without creating them")
                }
            }
            Checks.section("F149 exact private mode under a restrictive process umask") {
                let owned = root.appendingPathComponent("restrictive-mode")
                try PrivateFileStore.prepareDirectory(owned)
                let file = owned.appendingPathComponent("private.json"), bytes = Data("keep private and readable".utf8)
                do {
                    // This is the isolated check executable's process, never its parent shell.
                    let previous = umask(0o777)
                    defer { umask(previous) }
                    try PrivateFileStore.write(bytes, to: file, maximumBytes: 100)
                }
                check(
                    (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?
                        .intValue == 0o600, "F149 restrictive umask cannot produce an unreadable 0000 committed store")
                check(
                    (try? PrivateFileStore.read(file, maximumBytes: 100)) == bytes,
                    "F149 a private write still reads back under the caller's restrictive umask")
            }
            Checks.section("F149 shared private byte I/O") {
                let owned = root.appendingPathComponent("private-store")
                try PrivateFileStore.prepareDirectory(owned)
                rejects(
                    "F206 a failed open retains errno even when directory cleanup changes it",
                    where: { $0.posixCode == .ENOENT }
                ) {
                    _ = try PrivateFileStore.openRegularFile(
                        owned.appendingPathComponent("missing"), maximumBytes: 100,
                        closeDirectory: { descriptor in
                            let result = close(descriptor)
                            errno = EIO
                            return result
                        })
                }
                let file = owned.appendingPathComponent("value.json")
                let before = Data("old exact bytes".utf8), after = Data("new exact bytes".utf8)
                try PrivateFileStore.write(before, to: file, maximumBytes: 100)
                rejects("F149 a failed fsync prevents atomic replacement", where: { $0.posixCode == .EIO }) {
                    try PrivateFileStore.write(
                        after, to: file, maximumBytes: 100,
                        synchronize: { _ in
                            errno = EIO
                            return -1
                        })
                }
                check(try Data(contentsOf: file) == before, "F149 failed sync preserves the prior bytes")
                for phase in ["permissions", "close"] {
                    rejects(
                        "F206 failed private-file \(phase) prevents commit and retains operation/path/errno",
                        where: {
                            guard let failure = $0 as? FileOperationFailure else { return false }
                            return failure.errorNumber == EIO && failure.path == file.path
                                && failure.operation.contains(phase == "permissions" ? "permissions" : "close")
                        }
                    ) {
                        if phase == "permissions" {
                            try PrivateFileStore.write(
                                after, to: file, maximumBytes: 100,
                                setMode: { _, _ in
                                    errno = EIO
                                    return -1
                                })
                        } else {
                            try PrivateFileStore.write(
                                after, to: file, maximumBytes: 100,
                                closeFile: { descriptor in
                                    _ = close(descriptor)
                                    errno = EIO
                                    return -1
                                })
                        }
                    }
                    check(
                        try Data(contentsOf: file) == before,
                        "F149 failed private-file \(phase) preserves original bytes")
                }
                check(
                    try FileManager.default.contentsOfDirectory(atPath: owned.path) == ["value.json"],
                    "F149 failed sync cleans its own temporary file")
                try PrivateFileStore.write(after, to: file, maximumBytes: 100)
                check(
                    try PrivateFileStore.read(file, maximumBytes: 100) == after,
                    "F149 shared I/O roundtrips exact bytes")
                check(
                    (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?
                        .intValue == 0o600, "F149 shared writes retain private 0600 mode")
                check(
                    (try FileManager.default.attributesOfItem(atPath: owned.path)[.posixPermissions] as? NSNumber)?
                        .intValue == 0o700, "F149 shared app directories retain private 0700 mode")
                let alias = root.appendingPathComponent("chosen-parent")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: owned)
                let selected = alias.appendingPathComponent("value.json")
                check(
                    try PrivateFileStore.read(selected, maximumBytes: 100, parent: .selectedInput) == after,
                    "F149 a chosen regular import still accepts a symlinked parent")
                rejects("F149 an app-owned store refuses a symlinked immediate parent") {
                    _ = try PrivateFileStore.read(selected, maximumBytes: 100)
                }
                rejects("F149 shared reads enforce their caller's byte bound") {
                    _ = try PrivateFileStore.read(file, maximumBytes: 1)
                }
                rejects("F149 shared writes enforce the same caller's byte bound") {
                    try PrivateFileStore.write(after, to: file, maximumBytes: 1)
                }
                let moving = root.appendingPathComponent("moving-store"),
                    moved = root.appendingPathComponent("moved-store")
                try PrivateFileStore.prepareDirectory(moving)
                let movingFile = moving.appendingPathComponent("value.json")
                try PrivateFileStore.write(before, to: movingFile, maximumBytes: 100)
                rejects("F149 a replaced containing directory cannot commit through a stale descriptor") {
                    try PrivateFileStore.write(
                        after, to: movingFile, maximumBytes: 100,
                        beforeCommit: {
                            try FileManager.default.moveItem(at: moving, to: moved)
                            try FileManager.default.createDirectory(at: moving, withIntermediateDirectories: true)
                        })
                }
                check(
                    try Data(contentsOf: moved.appendingPathComponent("value.json")) == before
                        && !FileManager.default.fileExists(atPath: movingFile.path),
                    "F149 folder replacement preserves the prior file and writes nothing into the new folder")
                let retained = try requireValue(
                    try PrivateFileStore.write(after, to: file, maximumBytes: 100, retainingDescriptor: true),
                    "fixture: a journal retains its newly committed descriptor")
                defer { close(retained) }
                var byte: UInt8 = 0x5A
                check(
                    pwrite(retained, &byte, 1, 0) == 1 && fsync(retained) == 0,
                    "F149 a retained journal descriptor supports its in-place synchronized outcomes")
                check(
                    try Data(contentsOf: file).first == byte,
                    "F149 retained-descriptor outcomes belong to the committed file")
            }
            let unsafeLocation: (Error) -> Bool = {
                if case WorkspaceError.unsafeLocation = $0 { return true }
                return false
            }
            let tooLarge: (Error) -> Bool = {
                if case WorkspaceError.fileTooLarge = $0 { return true }
                return false
            }
            func posix(_ code: POSIXErrorCode) -> (Error) -> Bool { { ($0 as? POSIXError)?.code == code } }
            let original = root.appendingPathComponent("file with 'quotes' and $().txt")
            let disk = Data([0xEF, 0xBB, 0xBF]) + Data("disk content\r\n".utf8)
            try disk.write(to: original)
            let text = "\u{FEFF}½ café 🦋\0\r\n2 eggs\nlast\r"
            let id = UUID()
            let document = SessionDocument(
                id: id, originalURL: original, text: text, format: FileFormat(encoding: .windows1252, bom: false),
                isDirty: true, selection: SessionSelection(anchorByte: text.utf8.count, caretByte: 0),
                bookmarks: [0, 2], language: "cpp", originalSHA256: WorkspaceStore.fingerprint(disk))
            var session = WorkspaceSession(
                id: UUID(), name: "My $(not executable) session", documents: [document], activeDocumentID: id)
            let destination = root.appendingPathComponent("session.texttank-session")
            try WorkspaceStore.save(session, to: destination)
            check(
                try WorkspaceStore.load(from: destination) == session,
                "session roundtrips Unicode/NUL/FEFF, unsaved legacy-unrepresentable text, format, URL, reversed selection and bookmarks"
            )
            check(try Data(contentsOf: original) == disk, "saving snapshot never modifies original document")
            check(
                try (FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?
                    .intValue == 0o600, "session content file is private0600")
            check(session.inspectReferencedFiles().first?.status == .unchanged, "original fingerprint matches")
            let stableID = session.id
            session.name = "Renamed session"
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
            try WorkspaceStore.save(session, to: destination)
            check(try WorkspaceStore.load(from: destination).id == stableID, "rename preserves session identity")
            check(
                try (FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?
                    .intValue == 0o600, "atomic replacement keeps new private metadata")
            try Data("external changed bytes".utf8).write(to: original)
            check(
                session.inspectReferencedFiles().first?.status == .changed,
                "outside changes explicitly classified, retained snapshot remains")
            try FileManager.default.removeItem(at: original)
            check(
                session.inspectReferencedFiles().first?.status == .missing,
                "missing original explicitly classified without losing snapshot")
            check(
                try WorkspaceStore.load(from: destination).documents[0].text == text,
                "missing original does not prevent loading retained edits")
            var noHash = session
            noHash.documents[0].originalSHA256 = nil
            try disk.write(to: original)
            check(
                noHash.inspectReferencedFiles()[0].status == .unverified, "absent fingerprint is not falsely unchanged")
            var untitled = session
            untitled.documents[0].originalURL = nil
            untitled.documents[0].originalSHA256 = nil
            check(untitled.inspectReferencedFiles()[0].status == .untitled, "untitled document remains typed snapshot")
            let encoded = try session.encoded()
            let json = String(data: encoded, encoding: .utf8)!
            rejects("unknown schema", message: "Unsupported session schema version") {
                _ = try WorkspaceSession.decode(
                    Data(json.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8))
            }
            rejects("corrupt JSON", message: "not valid TextTank session data") {
                _ = try WorkspaceSession.decode(Data("{bad".utf8))
            }
            var bad = session
            bad.documents.append(document)
            rejects("duplicate document IDs") { try bad.validate() }
            bad = session
            bad.activeDocumentID = UUID()
            rejects("unknown active document") { try bad.validate() }
            bad = session
            bad.documents[0].selection.caretByte = -1
            rejects("negative position") { try bad.validate() }
            bad = session
            bad.documents[0].selection.caretByte = text.utf8.count + 1
            rejects("position beyond buffer") { try bad.validate() }
            bad = session
            bad.documents[0].selection.caretByte = 1
            rejects("position splits FEFF UTF8 sequence") { try bad.validate() }
            bad = session
            bad.documents[0].bookmarks = [100]
            rejects("bookmark out of line range") { try bad.validate() }
            bad = session
            bad.documents[0].bookmarks = [0, 0]
            rejects("duplicate bookmark") { try bad.validate() }
            bad = session
            bad.documents[0].format.bom = true
            rejects("legacy BOM invalid") { try bad.validate() }
            bad = session
            bad.documents[0].originalURL = URL(string: "https://example.com/file")!
            rejects("remote executable URL rejected", where: unsafeLocation) { try bad.validate() }
            bad = session
            bad.documents[0].originalSHA256 = "bad"
            rejects("bad hash rejected") { try bad.validate() }
            let fifo = root.appendingPathComponent("fifo")
            try require(mkfifo(fifo.path, mode_t(0o600)) == 0, "fixture: FIFO created")
            let fifoStart = ProcessInfo.processInfo.systemUptime
            rejects("FIFO load rejects without blocking", where: unsafeLocation) {
                _ = try WorkspaceStore.load(from: fifo)
            }
            var fifoReference = session
            fifoReference.documents[0].originalURL = fifo
            check(
                {
                    if case .unreadable = fifoReference.inspectReferencedFiles()[0].status { return true }
                    return false
                }(), "FIFO reference must be unreadable")
            check(
                ProcessInfo.processInfo.systemUptime - fifoStart < 10,
                "FIFO inspection returns well inside the hang guard")
            let before = try Data(contentsOf: destination)
            rejects("invalid snapshot cannot replace good session", message: "Invalid original-file fingerprint") {
                try WorkspaceStore.save(bad, to: destination)
            }
            check(try Data(contentsOf: destination) == before, "validation failure preserves previous session bytes")
            let link = root.appendingPathComponent("linked-session")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            rejects("loading session symlink", where: posix(.ELOOP)) { _ = try WorkspaceStore.load(from: link) }
            rejects("saving session symlink", where: unsafeLocation) { try WorkspaceStore.save(session, to: link) }
            check(try Data(contentsOf: destination) == before, "symlink destination not overwritten")
            let dangling = root.appendingPathComponent("dangling")
            try FileManager.default.createSymbolicLink(
                at: dangling, withDestinationURL: root.appendingPathComponent("absent"))
            rejects("dangling symlink rejected", where: unsafeLocation) {
                try WorkspaceStore.save(session, to: dangling)
            }
            let linkedDirectory = root.appendingPathComponent("linked-directory")
            try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: root)
            rejects("symlink storage directory rejected", where: posix(.ENOTDIR)) {
                try WorkspaceStore.save(session, to: linkedDirectory.appendingPathComponent("new-session"))
            }
            let referenceLink = root.appendingPathComponent("reference-link")
            try FileManager.default.createSymbolicLink(at: referenceLink, withDestinationURL: original)
            var linkedReference = session
            linkedReference.documents[0].originalURL = referenceLink
            check(
                {
                    if case .unreadable = linkedReference.inspectReferencedFiles()[0].status { return true }
                    return false
                }(), "reference symlink must be explicit unreadable")
            rejects("directory is not session file", where: unsafeLocation) { _ = try WorkspaceStore.load(from: root) }
            rejects("read resource limit enforced", where: tooLarge) {
                _ = try WorkspaceStore.readRegularFile(destination, maximumBytes: 2)
            }
            // F138: the streamed fingerprint is the fingerprint of the bytes, through the same open.
            for count in [0, 100, 64 * 1024, 128 * 1024, 200_000] {
                let sized = root.appendingPathComponent("sized-\(count)")
                try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ count) }).write(to: sized)
                check(
                    try WorkspaceStore.fingerprint(ofRegularFileAt: sized)
                        == WorkspaceStore.fingerprint(WorkspaceStore.readRegularFile(sized)),
                    "streamed fingerprint of \(count) bytes equals the fingerprint of the bytes read")
            }
            do {
                _ = try WorkspaceStore.readRegularFile(destination, maximumBytes: 2)
                check(false, "F94 an oversized file is rejected")
            } catch {
                check(
                    error.localizedDescription.contains("2 bytes")
                        && error.localizedDescription.contains(destination.lastPathComponent),
                    "F94 a bounded read names the actual file and its actual byte limit")
            }
            rejects("streamed fingerprint enforces the read limit", where: tooLarge) {
                _ = try WorkspaceStore.fingerprint(ofRegularFileAt: destination, maximumBytes: 2)
            }
            rejects("streamed fingerprint refuses a FIFO", where: unsafeLocation) {
                _ = try WorkspaceStore.fingerprint(ofRegularFileAt: fifo)
            }
            rejects("streamed fingerprint refuses a symbolic link", where: posix(.ELOOP)) {
                _ = try WorkspaceStore.fingerprint(ofRegularFileAt: referenceLink)
            }
            rejects("streamed fingerprint reports a missing file", where: posix(.ENOENT)) {
                _ = try WorkspaceStore.fingerprint(ofRegularFileAt: root.appendingPathComponent("absent"))
            }
            let oversized = root.appendingPathComponent("oversized")
            try Data().write(to: oversized)
            try require(
                truncate(oversized.path, off_t(WorkspaceStore.maximumSessionBytes) + 1) == 0,
                "fixture: sparse file one byte over the inspection limit")
            var oversizedReference = session
            oversizedReference.documents[0].originalURL = oversized
            check(
                oversizedReference.inspectReferencedFiles()[0].status
                    == .unreadable(
                        WorkspaceError.fileTooLarge(limit: WorkspaceStore.maximumSessionBytes, url: oversized)
                            .localizedDescription),
                "an original over the limit is reported as too large without being read")
            try FileManager.default.removeItem(at: oversized)
            var cancelledReference = session
            cancelledReference.documents[0].originalURL = original
            check(
                cancelledReference.inspectReferencedFiles()[0].status == .unchanged
                    && cancelledReference.inspectReferencedFiles(isCancelled: { true })[0].status
                        == .unreadable("the check was cancelled"),
                "a cancelled check reports the original as not inspected, never as unchanged")
            rejects("a cancelled streamed fingerprint throws", where: { $0 is CancellationError }) {
                _ = try WorkspaceStore.fingerprint(ofRegularFileAt: original, isCancelled: { true })
            }
            // The prompt is built from the session alone, so a FIFO or absent original is never opened.
            var promptSession = session
            promptSession.documents[0].originalURL = fifo
            let unread = promptSession.restorePrompt()
            check(
                unread.message == "Restore 1 Documents from Renamed session?" && unread.detail.hasSuffix("\n\nfifo")
                    && unread.detail.contains("have not been read") && !unread.detail.contains("cannot be inspected"),
                "the first restore prompt names the documents and claims nothing about the originals")
            let inspected = promptSession.restorePrompt(inspections: promptSession.inspectReferencedFiles())
            check(
                inspected.message == unread.message
                    && inspected.detail
                        == "Snapshots open as new unsaved documents. Existing tabs and original files are kept.\n\n"
                        + "fifo: Original file cannot be inspected: "
                        + WorkspaceError.unsafeLocation.localizedDescription,
                "the checked restore prompt has one status line per document, worded as before")
            // F86/F227: metadata stands in for the digest only when it is settled and unchanged.
            let watched = root.appendingPathComponent("watched.txt")
            try Data("first".utf8).write(to: watched)
            let later = WorkspaceStore.currentSecond() + 60
            let fresh = try WorkspaceStore.sample(ofRegularFileAt: watched)
            let settled = try WorkspaceStore.sample(ofRegularFileAt: watched, now: later)
            check(
                fresh.digest == WorkspaceStore.fingerprint(Data("first".utf8)) && fresh.signature == nil,
                "a file written this second has no signature to rely on")
            check(
                try settled.digest == fresh.digest && settled.signature != nil
                    && settled.signature == WorkspaceStore.signature(ofRegularFileAt: watched),
                "a settled sample's signature is what a metadata-only look reports")
            check(
                try WorkspaceStore.readRegularFileSample(watched, now: later).sample == settled
                    && WorkspaceStore.readRegularFileSample(watched).sample.signature == nil,
                "reading the bytes gives the same sample as hashing the file")
            var statBefore = stat()
            try require(stat(watched.path, &statBefore) == 0, "fixture: stat the watched file")
            let times = [statBefore.st_atimespec, statBefore.st_mtimespec]
            let rewriter = try FileHandle(forWritingTo: watched)
            try rewriter.write(contentsOf: Data("FIRST".utf8))
            try rewriter.close()
            try require(
                utimensat(AT_FDCWD, watched.path, times, 0) == 0, "fixture: put the modification time back")
            var statAfter = stat()
            try require(stat(watched.path, &statAfter) == 0, "fixture: stat the rewritten file")
            fixtureCheck(
                statAfter.st_size == statBefore.st_size && statAfter.st_ino == statBefore.st_ino
                    && statAfter.st_mtimespec.tv_sec == statBefore.st_mtimespec.tv_sec
                    && statAfter.st_mtimespec.tv_nsec == statBefore.st_mtimespec.tv_nsec,
                "the rewrite kept size, inode and the exact modification time")
            check(
                try WorkspaceStore.signature(ofRegularFileAt: watched) != settled.signature,
                "a same-size rewrite with its modification time put back still changes the signature")
            try Data("first".utf8).write(to: watched, options: .atomic)
            check(
                try WorkspaceStore.signature(ofRegularFileAt: watched) != settled.signature
                    && WorkspaceStore.sample(ofRegularFileAt: watched, now: later).digest == settled.digest,
                "an atomic replacement with the same bytes changes the signature, not the digest")
            rejects("metadata-only look refuses a symbolic link", where: posix(.ELOOP)) {
                _ = try WorkspaceStore.signature(ofRegularFileAt: referenceLink)
            }
            rejects("metadata-only look refuses a FIFO", where: unsafeLocation) {
                _ = try WorkspaceStore.signature(ofRegularFileAt: fifo)
            }
            let badParent = root.appendingPathComponent("not-directory")
            try Data("keep".utf8).write(to: badParent)
            rejects("partial-write path failure") {
                try WorkspaceStore.save(session, to: badParent.appendingPathComponent("session"))
            }
            check(try Data(contentsOf: badParent) == Data("keep".utf8), "failed storage leaves obstruction untouched")
            check(
                try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
                    $0.hasPrefix(".texttank-session-")
                }.isEmpty, "no temporary snapshot leaks after writes")
            Checks.summary {
                "PASS WorkspaceChecks: \(Checks.count) assertions; no original document writes or executable actions"
            }
        }
    }
}
