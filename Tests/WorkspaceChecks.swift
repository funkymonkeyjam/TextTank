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
            let unsafeLocation: (Error) -> Bool = {
                if case WorkspaceError.unsafeLocation = $0 { return true }
                return false
            }
            let tooLarge: (Error) -> Bool = {
                if case WorkspaceError.tooLarge = $0 { return true }
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
