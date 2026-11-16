@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main struct FileChecks {
    static func main() {
        Checks.run("FileChecks") {
            if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--crash-write" {
                let directory = URL(fileURLWithPath: CommandLine.arguments[2])
                let original = URL(fileURLWithPath: CommandLine.arguments[3])
                let id = UUID(uuidString: CommandLine.arguments[4])!
                let store = RecoveryStore(directory: directory)
                try store.save(
                    RecoverySnapshot(
                        id: id, text: "named after crash\0😀", format: FileFormat(),
                        originalURL: original.absoluteString, revision: 12))
                try store.save(
                    RecoverySnapshot(
                        id: UUID(), text: "untitled after crash", format: FileFormat(), originalURL: nil, revision: 7))
                // SIGKILL bypasses defer, normal termination hooks and store deinitialization.
                kill(getpid(), SIGKILL)
                fatalError("SIGKILL unexpectedly returned")
            }
            codecAgainstReference()
            let samples = ["", "\0", "\0hello", "A\0B\r\nC\nD\rE", "½ cup — café 👩🏽‍💻 e\u{301}", "\u{FEFF}inside"]
            for encoding in [FileEncoding.utf8, .utf16LE, .utf16BE] {
                for bom in [false, true] {
                    for sample in samples {
                        let format = FileFormat(encoding: encoding, bom: bom)
                        let bytes = try FileCodec.encode(sample, format: format)
                        // Explicit selection distinguishes an intentional leading U+FEFF from a BOM.
                        // Leading U+FEFF at file start is treated as BOM by decoding contract.
                        if sample.hasPrefix("\u{FEFF}") && !bom { continue }
                        let decoded = try FileCodec.decode(bytes, encoding: encoding)
                        check(
                            decoded.text == sample && decoded.format == format,
                            "Unicode text/format roundtrip \(encoding) bom=\(bom) input=\(sample.debugDescription) output=\(decoded.text.debugDescription) format=\(decoded.format)"
                        )
                        check(
                            try FileCodec.encode(decoded.text, format: decoded.format) == bytes, "exact bytes roundtrip"
                        )
                        if bom {
                            if encoding == .utf16LE && sample.hasPrefix("\0") {
                                rejects("ambiguous UTF32/UTF16 NUL requires explicit choice") {
                                    _ = try FileCodec.decode(bytes)
                                }
                            } else {
                                check(try FileCodec.decode(bytes).text == sample, "BOM auto detection")
                            }
                        }
                    }
                }
            }
            for byte in UInt16(0)...255 {
                let data = Data([UInt8(byte)])
                let decoded = try FileCodec.decode(data, encoding: .latin1)
                check(try FileCodec.encode(decoded.text, format: decoded.format) == data, "all Latin1 bytes")
                if ![0x81, 0x8D, 0x8F, 0x90, 0x9D].contains(byte) {
                    let cp = try FileCodec.decode(data, encoding: .windows1252)
                    check(try FileCodec.encode(cp.text, format: cp.format) == data, "defined cp1252 byte")
                } else {
                    rejects("undefined cp1252") { _ = try FileCodec.decode(data, encoding: .windows1252) }
                }
            }
            for bytes: [UInt8] in [[0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0x80], [0xFF]] {
                rejects("invalid UTF8 no guessed fallback") { _ = try FileCodec.decode(Data(bytes)) }
            }
            for bytes: [UInt8] in [[0], [0, 0xD8], [0, 0xDC], [0, 0xD8, 65, 0]] {
                rejects("invalid UTF16") { _ = try FileCodec.decode(Data(bytes), encoding: .utf16LE) }
            }
            for bytes: [UInt8] in [[0xFF, 0xFE, 0, 0, 65, 0, 0, 0], [0, 0, 0xFE, 0xFF, 0, 0, 0, 65]] {
                rejects("UTF32 signature not silently misread") { _ = try FileCodec.decode(Data(bytes)) }
            }
            rejects("unrepresentable") { _ = try FileCodec.encode("€😀", format: FileFormat(encoding: .latin1)) }
            rejects("cp1252 C1 not silently mapped") {
                _ = try FileCodec.encode("\u{81}", format: FileFormat(encoding: .windows1252))
            }
            rejects("legacy BOM") { _ = try FileCodec.encode("abc", format: FileFormat(encoding: .latin1, bom: true)) }

            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankFileChecks-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = root.appendingPathComponent("original.txt")
            let originalBytes = Data("original\r\n".utf8)
            try originalBytes.write(to: original)
            let storeURL = root.appendingPathComponent("recovery")
            let store = RecoveryStore(directory: storeURL)
            let id = UUID()
            let first = RecoverySnapshot(
                id: id, text: "edited\0😀", format: FileFormat(), originalURL: original.absoluteString, revision: 1)
            try store.save(first)
            let firstPath = storeURL.appendingPathComponent(id.uuidString + ".json")
            let privateDirectoryMode =
                (try FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as! NSNumber)
                .intValue
            let privateFileMode =
                (try FileManager.default.attributesOfItem(atPath: firstPath.path)[.posixPermissions] as! NSNumber)
                .intValue
            check(
                privateDirectoryMode == 0o700 && privateFileMode == 0o600, "recovery directory and initial file private"
            )
            check(try store.load(id: id) == first, "exact snapshot reload")
            // Reinstantiate to demonstrate persistence independent of live store instance.
            check(try RecoveryStore(directory: storeURL).load(id: id) == first, "restart reload")
            let second = RecoverySnapshot(
                id: id, text: "newer", format: FileFormat(), originalURL: original.absoluteString, revision: 2)
            // Simulate old broad metadata and require replacement to restore private permissions.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeURL.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: firstPath.path)
            let parentModeBefore =
                (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as! NSNumber).intValue
            try store.save(second)
            let replacedMode =
                (try FileManager.default.attributesOfItem(atPath: firstPath.path)[.posixPermissions] as! NSNumber)
                .intValue
            let correctedDirectoryMode =
                (try FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as! NSNumber)
                .intValue
            let parentModeAfter =
                (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as! NSNumber).intValue
            check(
                replacedMode == 0o600 && correctedDirectoryMode == 0o700,
                "replacement repairs old broad recovery metadata")
            check(parentModeBefore == parentModeAfter, "recovery privacy does not chmod parent")
            check(
                RecoveryStore.maximumSnapshotBytes > 512 * 1024 * 1024,
                "F149 recovery does not inherit the smaller session byte ceiling")
            Checks.section("F149 byte-exact recovery revision identity") {
                let exactID = UUID()
                let exact = RecoverySnapshot(
                    id: exactID, text: "caf\u{E9}", format: FileFormat(), originalURL: nil, revision: 1)
                try store.save(exact)
                let saved = try Data(contentsOf: store.fileURL(for: exactID))
                let canonicalTwin = RecoverySnapshot(
                    id: exactID, text: "cafe\u{301}", format: FileFormat(), originalURL: nil, revision: 1)
                rejects(
                    "F149 equal-revision recovery text must match UTF8 bytes, not canonical String equality",
                    expecting: RecoveryError.staleRevision
                ) {
                    try store.save(canonicalTwin)
                }
                check(
                    try Data(contentsOf: store.fileURL(for: exactID)) == saved,
                    "F149 refusing byte-distinct equal-revision recovery preserves saved bytes")
                try store.remove(id: exactID, throughRevision: 1)
            }
            rejects("stale write", expecting: RecoveryError.staleRevision) { try store.save(first) }
            rejects("stale cleanup", expecting: RecoveryError.staleRevision) {
                try store.remove(id: id, throughRevision: 1)
            }
            check(try store.load(id: id) == second, "newer survives stale operations")
            let wrongEqual = RecoverySnapshot(
                id: id, text: "different", format: FileFormat(), originalURL: original.absoluteString, revision: 2)
            rejects("equal revision conflicting text", expecting: RecoveryError.staleRevision) {
                try store.save(wrongEqual)
            }
            let path = storeURL.appendingPathComponent(id.uuidString + ".json")
            let corrupt = Data("{partial write".utf8)
            try corrupt.write(to: path)
            rejects("corrupt read", expecting: RecoveryError.invalidSnapshot) { _ = try store.load(id: id) }
            rejects("corrupt snapshot cannot be overwritten", expecting: RecoveryError.invalidSnapshot) {
                try store.save(second)
            }
            check(try Data(contentsOf: path) == corrupt, "corrupt remains inspectable")
            check(try Data(contentsOf: original) == originalBytes, "original never changed")
            try FileManager.default.removeItem(at: path)
            let overflow = RecoverySnapshot(
                id: UUID(), text: "preserve", format: FileFormat(), originalURL: nil, revision: UInt64.max)
            rejects("unbounded revision rejected before restore arithmetic", expecting: RecoveryError.invalidSnapshot) {
                try store.save(overflow)
            }
            let overflowPath = storeURL.appendingPathComponent(overflow.id.uuidString + ".json")
            let overflowBytes = try JSONEncoder().encode(overflow)
            try overflowBytes.write(to: overflowPath)
            rejects("unbounded persisted revision rejected", expecting: RecoveryError.invalidSnapshot) {
                _ = try store.load(id: overflow.id)
            }
            check(try Data(contentsOf: overflowPath) == overflowBytes, "invalid revision preserved for review")
            try FileManager.default.removeItem(at: overflowPath)
            var unknown = first
            unknown.schemaVersion = 999
            rejects("unknown write version", expecting: RecoveryError.invalidSnapshot) { try store.save(unknown) }
            try JSONEncoder().encode(unknown).write(to: path)
            rejects("unknown read version", expecting: RecoveryError.invalidSnapshot) { _ = try store.load(id: id) }
            try FileManager.default.removeItem(at: path)
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: original)
            rejects("symlink write", expecting: RecoveryError.unsafeLocation) { try store.save(first) }
            check(try Data(contentsOf: original) == originalBytes, "symlink target unchanged")
            try FileManager.default.removeItem(at: path)
            let untitled = RecoverySnapshot(
                id: UUID(), text: "unsaved", format: FileFormat(encoding: .latin1), originalURL: nil, revision: 1)
            try store.save(untitled)
            check(try store.loadAll() == [untitled], "untitled snapshot")
            let unrepresentable = RecoverySnapshot(
                id: untitled.id, text: "😀", format: untitled.format, originalURL: nil, revision: 2)
            try store.save(unrepresentable)
            check(try store.load(id: untitled.id).text == "😀", "recover pending unrepresentable edits")
            let broken = storeURL.appendingPathComponent(UUID().uuidString + ".json")
            let brokenBytes = Data("{broken".utf8)
            try brokenBytes.write(to: broken)
            let scan = try store.scan()
            check(
                scan.snapshots.count == 1 && scan.snapshots[0].id == untitled.id,
                "corrupt neighbor does not block valid recovery")
            check(
                scan.issues.count == 1
                    && scan.issues[0].url.standardizedFileURL.path == broken.standardizedFileURL.path,
                "corrupt neighbor reported")
            check(try Data(contentsOf: broken) == brokenBytes, "scan preserves corrupt evidence")
            try FileManager.default.removeItem(at: broken)
            // F202: discarding a scanned list removes exactly the listed snapshots at their scanned revision.
            let discardURL = root.appendingPathComponent("discard-recovery"),
                discardStore = RecoveryStore(directory: discardURL)
            let keepID = UUID(), dropID = UUID(), advancedID = UUID()
            try discardStore.save(
                RecoverySnapshot(id: keepID, text: "unlisted", format: FileFormat(), originalURL: nil, revision: 1))
            try discardStore.save(
                RecoverySnapshot(id: dropID, text: "listed", format: FileFormat(), originalURL: nil, revision: 4))
            try discardStore.save(
                RecoverySnapshot(id: advancedID, text: "scanned", format: FileFormat(), originalURL: nil, revision: 2))
            let corruptNeighbour = discardURL.appendingPathComponent(UUID().uuidString + ".json")
            let corruptNeighbourBytes = Data("{neighbour".utf8)
            try corruptNeighbourBytes.write(to: corruptNeighbour)
            let scanned = try discardStore.scan()
            check(scanned.snapshots.count == 3 && scanned.issues.count == 1, "discard fixture scanned")
            let advanced = RecoverySnapshot(
                id: advancedID, text: "edited after the scan", format: FileFormat(), originalURL: nil, revision: 3)
            try discardStore.save(advanced)
            let listed = scanned.snapshots.filter { $0.id != keepID }
            let notDiscarded = discardStore.discard(listed)
            check(
                notDiscarded.count == 1 && notDiscarded[0].url.lastPathComponent == advancedID.uuidString + ".json",
                "discard reports only the snapshot that advanced after the scan")
            check(
                notDiscarded[0].url.standardizedFileURL.path
                    == discardStore.fileURL(for: advancedID).standardizedFileURL.path
                    && notDiscarded[0].message == RecoveryError.staleRevision.localizedDescription,
                "discard failure names the file and the reason")
            let afterDiscard = try discardStore.scan()
            check(
                Set(afterDiscard.snapshots.map(\.id)) == [keepID, advancedID],
                "discard removes exactly the listed unchanged snapshot")
            check(
                try discardStore.load(id: advancedID) == advanced && discardStore.load(id: keepID).text == "unlisted",
                "discard keeps newer and unlisted snapshots intact")
            check(
                try Data(contentsOf: corruptNeighbour) == corruptNeighbourBytes && afterDiscard.issues.count == 1,
                "discard leaves a corrupt neighbour byte-identical")
            check(
                discardStore.discard([]).isEmpty
                    && discardStore.discard(scanned.snapshots.filter { $0.id == dropID }).isEmpty,
                "discarding nothing or an already removed snapshot is not an error")
            // F202: escalation policy for repeated recovery failures.
            var tracker = RecoveryFailureTracker()
            check(
                !tracker.isFailing && !tracker.recordFailure(sessionAlreadyNotified: false) && tracker.isFailing,
                "one recovery failure does not escalate")
            check(tracker.recordFailure(sessionAlreadyNotified: false), "second consecutive recovery failure escalates")
            check(
                !tracker.recordFailure(sessionAlreadyNotified: true) && tracker.consecutiveFailures == 3,
                "escalation happens once per session")
            tracker.recordSuccess()
            check(
                !tracker.isFailing && !tracker.recordFailure(sessionAlreadyNotified: false),
                "a successful write resets the failure count")
            // F126: line-ending detection uses the first line break only.
            check(
                LineEnding.detect(in: "") == .lf && LineEnding.detect(in: "no break") == .lf,
                "text without a line break inserts LF")
            check(
                LineEnding.detect(in: "a\r\nb\n") == .crlf && LineEnding.detect(in: "a\nb\r\n") == .lf
                    && LineEnding.detect(in: "a\rb\n") == .cr, "first line break decides the insertion ending")
            check(
                LineEnding.detect(in: "a\r") == .cr && LineEnding.detect(in: "\r\n") == .crlf
                    && LineEnding.detect(in: "\r\r\n") == .cr && LineEnding.detect(in: "é\u{2028}\r\n") == .crlf,
                "trailing CR, leading CRLF and non-ASCII text detected exactly")
            // A non-directory path simulates a deterministic storage failure without root/ACL assumptions.
            let denied = RecoveryStore(directory: original)
            rejects("non-directory storage write", expecting: RecoveryError.unsafeLocation) { try denied.save(first) }
            check(try Data(contentsOf: original) == originalBytes, "failed save preserves original")
            let crashDirectory = root.appendingPathComponent("crash-recovery")
            let crashID = UUID()
            let child = Process()
            child.executableURL = Checks.executable
            child.arguments = ["--crash-write", crashDirectory.path, original.path, crashID.uuidString]
            try child.run()
            child.waitUntilExit()
            check(
                child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,
                "actual SIGKILL observed")
            let restored = try RecoveryStore(directory: crashDirectory).loadAll()
            check(restored.count == 2, "named and untitled survive killed process")
            check(
                restored.first(where: { $0.id == crashID })?.text == "named after crash\0😀",
                "named exact recovery after crash")
            check(
                restored.first(where: { $0.originalURL == nil })?.text == "untitled after crash",
                "untitled exact recovery after crash")
            check(try Data(contentsOf: original) == originalBytes, "forced crash leaves original unchanged")
            let writer = RecoveryWriter(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let eventsLock = NSLock()
            var events: [String] = []
            func record(_ event: String) {
                eventsLock.lock()
                events.append(event)
                eventsLock.unlock()
            }
            writer.submit {
                entered.signal()
                release.wait()
                record("active")
            }
            check(entered.wait(timeout: .now() + 2) == .success, "background recovery starts without blocking caller")
            writer.submit { record("superseded") }
            writer.submit { record("latest") }
            release.signal()
            // F114: finish now drops a snapshot that has not started, so wait for the coalesced
            // write before the cleanup. The order asserted is the one this check always pinned.
            func recorded() -> [String] {
                eventsLock.lock()
                defer { eventsLock.unlock() }
                return events
            }
            spinUntil("the coalesced recovery write") { recorded().count == 2 }
            writer.finish { record("cleanup") }
            check(
                recorded() == ["active", "latest", "cleanup"],
                "recovery coalesces pending work and orders cleanup after writes")
            // F114: a write that is running is still awaited; one that is only queued is superseded.
            writer.submit {
                entered.signal()
                release.wait()
                record("running")
            }
            check(entered.wait(timeout: .now() + 2) == .success, "fixture: a recovery write is in flight")
            writer.submit { record("queued") }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { release.signal() }
            writer.finish { record("finish") }
            check(
                Array(recorded().suffix(2)) == ["running", "finish"],
                "finish waits for the running recovery write before the cleanup")
            let settled = DispatchSemaphore(value: 0)
            writer.submit { settled.signal() }
            check(settled.wait(timeout: .now() + 2) == .success, "the writer accepts work after a finish")
            check(!recorded().contains("queued"), "a queued recovery snapshot is not written after finish")
            // F114/F135: this store's own previous snapshot is compared by revision from memory.
            let cacheURL = root.appendingPathComponent("revision-cache"),
                cacheStore = RecoveryStore(directory: cacheURL)
            let cacheID = UUID(), cacheFile = cacheStore.fileURL(for: cacheID)
            func cached(_ revision: UInt64, _ text: String = "cached") -> RecoverySnapshot {
                RecoverySnapshot(id: cacheID, text: text, format: FileFormat(), originalURL: nil, revision: revision)
            }
            try cacheStore.save(cached(1))
            let readsBefore = cacheStore.snapshotReads
            try cacheStore.save(cached(2, "second"))
            try cacheStore.save(cached(3, "third"))
            try cacheStore.remove(id: cacheID, throughRevision: 3)
            check(
                cacheStore.snapshotReads == readsBefore && !FileManager.default.fileExists(atPath: cacheFile.path),
                "newer saves and the cleanup do not re-read the snapshot this store wrote")
            try cacheStore.save(cached(1))
            try cacheStore.save(cached(2, "second"))
            check(try cacheStore.load(id: cacheID).text == "second", "remembered revisions write the newest text")
            rejects("remembered revision still rejects a stale write", expecting: RecoveryError.staleRevision) {
                try cacheStore.save(cached(1))
            }
            rejects("remembered revision still rejects a stale cleanup", expecting: RecoveryError.staleRevision) {
                try cacheStore.remove(id: cacheID, throughRevision: 1)
            }
            rejects(
                "equal revision with different text is still compared on disk", expecting: RecoveryError.staleRevision
            ) { try cacheStore.save(cached(2, "different")) }
            // Another writer replaces the file: the remembered revision must not be trusted.
            try RecoveryStore(directory: cacheURL).save(cached(9, "other writer"))
            rejects("a snapshot advanced by another writer is not overwritten", expecting: RecoveryError.staleRevision)
            {
                try cacheStore.save(cached(3, "third"))
            }
            rejects("a snapshot advanced by another writer is not removed", expecting: RecoveryError.staleRevision) {
                try cacheStore.remove(id: cacheID, throughRevision: 3)
            }
            check(try cacheStore.load(id: cacheID).text == "other writer", "the other writer's snapshot survives")
            try cacheStore.save(cached(10, "tenth"))
            // Same length, same modification time: only the content differs from what was written.
            let cacheWritten = try Data(contentsOf: cacheFile),
                cacheStamp =
                    try FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate] as! Date
            let cacheCorrupt = Data(repeating: 0x7B, count: cacheWritten.count)
            let tamper = try FileHandle(forWritingTo: cacheFile)
            try tamper.write(contentsOf: cacheCorrupt)
            try tamper.close()
            try FileManager.default.setAttributes([.modificationDate: cacheStamp], ofItemAtPath: cacheFile.path)
            rejects(
                "a snapshot corrupted after this store wrote it is not overwritten",
                expecting: RecoveryError.invalidSnapshot
            ) { try cacheStore.save(cached(11)) }
            rejects(
                "a snapshot corrupted after this store wrote it is not removed",
                expecting: RecoveryError.invalidSnapshot
            ) { try cacheStore.remove(id: cacheID, throughRevision: 11) }
            check(try Data(contentsOf: cacheFile) == cacheCorrupt, "the corrupted snapshot stays byte-identical")
            try FileManager.default.removeItem(at: cacheFile)
            try cacheStore.save(cached(1, "fresh"))
            try cacheStore.remove(id: cacheID, throughRevision: 1)
            check(
                !FileManager.default.fileExists(atPath: cacheFile.path),
                "cleanup from the remembered revision removes the snapshot")
            try cacheStore.save(cached(1, "after removal"))
            check(
                try cacheStore.load(id: cacheID).text == "after removal",
                "a removed snapshot's remembered revision does not block a new document revision")
            // F135: temporary files orphaned by a crash during a write are removed by the next scan.
            let orphan = cacheURL.appendingPathComponent(UUID().uuidString + ".pending"),
                inFlight = cacheURL.appendingPathComponent(UUID().uuidString + ".pending"),
                foreign = cacheURL.appendingPathComponent("notes.pending"),
                oldCorrupt = cacheURL.appendingPathComponent(UUID().uuidString + ".json")
            let longAgo = Date(timeIntervalSinceNow: -3600)
            for file in [orphan, inFlight, foreign, oldCorrupt] { try Data("partial text".utf8).write(to: file) }
            for file in [orphan, foreign, oldCorrupt] {
                try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: file.path)
            }
            check(RecoveryStore.processStart > longAgo, "fixture: the orphan is older than this process")
            let hygiene = try cacheStore.scan()
            check(
                !FileManager.default.fileExists(atPath: orphan.path),
                "scan removes a temporary file orphaned by a crash")
            check(
                FileManager.default.fileExists(atPath: inFlight.path),
                "scan keeps a temporary file written since this process started")
            check(
                try FileManager.default.fileExists(atPath: foreign.path)
                    && Data(contentsOf: oldCorrupt) == Data("partial text".utf8),
                "scan deletes nothing but orphaned UUID.pending files")
            check(
                hygiene.snapshots.map(\.id) == [cacheID]
                    && hygiene.issues.map(\.url.lastPathComponent) == [oldCorrupt.lastPathComponent],
                "scan still lists the valid snapshot and reports the corrupt entry")
            rejects("loadAll is scan with issues made fatal", expecting: RecoveryError.invalidSnapshot) {
                _ = try cacheStore.loadAll()
            }
            try FileManager.default.removeItem(at: oldCorrupt)
            check(try cacheStore.loadAll().map(\.id) == [cacheID], "loadAll returns what scan lists")
            Checks.summary { "PASS FileChecks: \(Checks.count) assertions; codec and isolated recovery" }
        }
    }
}

/// Audit package 22 (F229): the codec that validates in place must accept, reject and decode
/// exactly as the scalar-by-scalar implementation it replaced, which is kept here as the reference.
private enum ReferenceCodec {
    static let cp1252: [UInt32?] = [
        0x20AC, nil, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, nil, 0x017D, nil,
        nil, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, nil, 0x017E, 0x0178
    ]
    static func bom(_ encoding: FileEncoding) -> [UInt8] {
        switch encoding {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .utf16LE: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }
    /// nil where the reference rejects the bytes.
    static func decode(_ data: Data, encoding: FileEncoding) -> (text: String, bom: Bool)? {
        var bytes = Array(data)
        let marker = bom(encoding)
        let hasBOM = !marker.isEmpty && bytes.starts(with: marker)
        if hasBOM { bytes.removeFirst(marker.count) }
        var scalars = String.UnicodeScalarView()
        switch encoding {
        case .utf8:
            let decoded = String(decoding: bytes, as: UTF8.self)
            return decoded.utf8.elementsEqual(bytes) ? (decoded, hasBOM) : nil
        case .utf16LE, .utf16BE:
            guard bytes.count % 2 == 0 else { return nil }
            let words: [UInt16] = stride(from: 0, to: bytes.count, by: 2).map { i in
                encoding == .utf16LE
                    ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
            }
            var i = 0
            while i < words.count {
                let w = words[i]
                var scalar = UInt32(w)
                if (0xD800...0xDBFF).contains(w) {
                    guard i + 1 < words.count, (0xDC00...0xDFFF).contains(words[i + 1]) else { return nil }
                    scalar = 0x10000 + (UInt32(w - 0xD800) << 10) + UInt32(words[i + 1] - 0xDC00)
                    i += 1
                } else if (0xDC00...0xDFFF).contains(w) {
                    return nil
                }
                guard let s = UnicodeScalar(scalar) else { return nil }
                scalars.append(s)
                i += 1
            }
        case .latin1, .windows1252:
            for b in bytes {
                let value: UInt32? =
                    encoding == .windows1252 && b >= 0x80 && b <= 0x9F ? cp1252[Int(b - 0x80)] : UInt32(b)
                guard let value, let scalar = UnicodeScalar(value) else { return nil }
                scalars.append(scalar)
            }
        }
        return (String(scalars), hasBOM)
    }
    /// nil where the reference refuses to encode.
    static func encode(_ text: String, format: FileFormat) -> Data? {
        let marker = bom(format.encoding)
        if format.bom && marker.isEmpty { return nil }
        var bytes: [UInt8] = format.bom ? marker : []
        switch format.encoding {
        case .utf8: bytes.append(contentsOf: text.utf8)
        case .utf16LE, .utf16BE:
            for word in text.utf16 {
                let low = UInt8(word & 255), high = UInt8(word >> 8)
                bytes.append(contentsOf: format.encoding == .utf16LE ? [low, high] : [high, low])
            }
        case .latin1, .windows1252:
            for scalar in text.unicodeScalars {
                let value = scalar.value
                if value < 0x80 || (value >= 0xA0 && value <= 0xFF) || (format.encoding == .latin1 && value <= 0xFF) {
                    bytes.append(UInt8(value))
                } else if format.encoding == .windows1252, let index = cp1252.firstIndex(where: { $0 == value }) {
                    bytes.append(UInt8(index + 0x80))
                } else {
                    return nil
                }
            }
        }
        return Data(bytes)
    }
}

/// True when the codec and the reference agree on these bytes: both reject, or both give the
/// same scalars and BOM flag.
private func decodeAgrees(_ data: Data, _ encoding: FileEncoding) -> Bool {
    let expected = ReferenceCodec.decode(data, encoding: encoding)
    guard let actual = try? FileCodec.decode(data, encoding: encoding) else { return expected == nil }
    guard let expected else { return false }
    return actual.text.unicodeScalars.elementsEqual(expected.text.unicodeScalars) && actual.format.bom == expected.bom
        && actual.format.encoding == encoding
}
private func encodeAgrees(_ text: String, _ format: FileFormat) -> Bool {
    (try? FileCodec.encode(text, format: format)) == ReferenceCodec.encode(text, format: format)
}

private func codecAgainstReference() {
    let encodings: [FileEncoding] = [.utf8, .utf16LE, .utf16BE, .windows1252, .latin1]
    // Named edge cases first, so a failure says which rule moved.
    let named: [(String, FileEncoding, [UInt8])] = [
        ("empty file", .utf8, []), ("UTF-8 BOM only", .utf8, [0xEF, 0xBB, 0xBF]),
        ("UTF-8 BOM then content U+FEFF", .utf8, [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x61]),
        ("UTF-8 literal U+FFFD", .utf8, [0x61, 0xEF, 0xBF, 0xBD, 0x62]),
        ("UTF-8 truncated four-byte sequence", .utf8, [0xF0, 0x90, 0x80]),
        ("UTF-8 truncated four-byte sequence after text", .utf8, [0x61, 0xF0, 0x9F, 0x98]),
        ("UTF-8 truncated three-byte sequence", .utf8, [0xE2, 0x82]),
        ("UTF-8 overlong NUL", .utf8, [0xC0, 0x80]), ("UTF-8 encoded surrogate", .utf8, [0xED, 0xB0, 0x80]),
        ("UTF-8 above U+10FFFF", .utf8, [0xF4, 0x90, 0x80, 0x80]), ("UTF-8 NUL bytes", .utf8, [0, 0x61, 0]),
        ("UTF-8 highest scalar", .utf8, [0xF4, 0x8F, 0xBF, 0xBF]),
        ("UTF-16 LE odd length", .utf16LE, [0x61, 0, 0x62]), ("UTF-16 BE odd length", .utf16BE, [0, 0x61, 0]),
        ("UTF-16 LE BOM only", .utf16LE, [0xFF, 0xFE]), ("UTF-16 BE BOM only", .utf16BE, [0xFE, 0xFF]),
        ("UTF-16 LE BOM and odd length", .utf16LE, [0xFF, 0xFE, 0x61]),
        ("UTF-16 LE BOM then content U+FEFF", .utf16LE, [0xFF, 0xFE, 0xFF, 0xFE, 0x61, 0]),
        ("UTF-16 LE lone high surrogate at the end", .utf16LE, [0x61, 0, 0x3D, 0xD8]),
        ("UTF-16 LE lone high surrogate before text", .utf16LE, [0x3D, 0xD8, 0x61, 0]),
        ("UTF-16 LE lone low surrogate", .utf16LE, [0x00, 0xDE, 0x61, 0]),
        ("UTF-16 LE reversed surrogate pair", .utf16LE, [0x00, 0xDE, 0x3D, 0xD8]),
        ("UTF-16 LE two high surrogates", .utf16LE, [0x3D, 0xD8, 0x3D, 0xD8, 0x00, 0xDE]),
        ("UTF-16 LE valid surrogate pair", .utf16LE, [0x3D, 0xD8, 0x00, 0xDE]),
        ("UTF-16 BE valid surrogate pair", .utf16BE, [0xD8, 0x3D, 0xDE, 0x00]),
        ("UTF-16 BE lone low surrogate at the end", .utf16BE, [0, 0x61, 0xDC, 0x00]),
        ("UTF-16 BE bytes that are a pair only in LE order", .utf16BE, [0x3D, 0xD8, 0x00, 0xDE]),
        ("UTF-16 LE NUL and U+FFFF", .utf16LE, [0, 0, 0xFF, 0xFF]),
        ("cp1252 defined C1 bytes", .windows1252, [0x80, 0x9F, 0x8E]),
        ("cp1252 hole 0x81", .windows1252, [0x41, 0x81]), ("cp1252 hole 0x8D", .windows1252, [0x8D]),
        ("cp1252 hole 0x8F", .windows1252, [0x8F]), ("cp1252 hole 0x90", .windows1252, [0x90, 0x41]),
        ("cp1252 hole 0x9D", .windows1252, [0x9D]), ("Latin-1 C1 bytes", .latin1, [0x80, 0x81, 0x9F, 0xFF, 0]),
        ("Latin-1 bytes that look like a UTF-8 BOM", .latin1, [0xEF, 0xBB, 0xBF, 0x41])
    ]
    for (name, encoding, bytes) in named {
        check(decodeAgrees(Data(bytes), encoding), "decoding matches the reference: \(name)")
    }
    // Deterministic pseudo-random bytes, weighted towards the values the rules turn on.
    var state: UInt64 = 0x2545_F491_4F6C_DD1D
    func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    let weighted: [UInt8] = [
        0x00, 0x0A, 0x0D, 0x41, 0x7F, 0x80, 0x81, 0x8D, 0x90, 0x9D, 0x9F, 0xA0, 0xBB, 0xBF, 0xC0, 0xC2, 0xD8, 0xDB,
        0xDC,
        0xDF, 0xE0, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xFE, 0xFF, 0x3D, 0xBD
    ]
    for encoding in encodings {
        var disagreements = 0, accepted = 0, rejected = 0, encodeDisagreements = 0
        for round in 0..<4000 {
            let length = Int(next() % 24)
            var bytes: [UInt8] = []
            if round % 5 == 0 { bytes = ReferenceCodec.bom(encoding) }
            for _ in 0..<length {
                let draw = next()
                bytes.append(draw % 3 == 0 ? UInt8(truncatingIfNeeded: draw >> 8) : weighted[Int((draw >> 8) % 30)])
            }
            let data = Data(bytes)
            if !decodeAgrees(data, encoding) { disagreements += 1 }
            guard let decoded = try? FileCodec.decode(data, encoding: encoding) else {
                rejected += 1
                continue
            }
            accepted += 1
            // Exact bytes back, and the same answer as the reference for every target encoding.
            if (try? FileCodec.encode(decoded.text, format: decoded.format)) != data { encodeDisagreements += 1 }
            for target in encodings {
                for bom in [false, true] where !encodeAgrees(decoded.text, FileFormat(encoding: target, bom: bom)) {
                    encodeDisagreements += 1
                }
            }
        }
        check(
            disagreements == 0 && accepted > 100 && (rejected > 100 || encoding == .latin1),
            "4000 pseudo-random \(encoding) files decode or are rejected exactly as the reference (\(accepted) accepted, \(rejected) rejected)"
        )
        check(
            encodeDisagreements == 0,
            "every accepted \(encoding) file encodes back to its exact bytes and to every encoding as the reference")
    }
    // A Data slice does not start at index 0; the codec must not assume it does.
    let padded = Data([0x58, 0x58, 0xEF, 0xBB, 0xBF, 0xC3, 0xA9, 0x58])
    let slice = padded[2..<7]
    check(
        (try? FileCodec.decode(slice, encoding: .utf8))?.text == "\u{E9}"
            && (try? FileCodec.decode(slice))?.format == FileFormat(encoding: .utf8, bom: true),
        "a Data slice with a non-zero start index decodes by its own bytes")
    let wide = Data([0x58, 0xFF, 0xFE, 0x3D, 0xD8, 0x00, 0xDE])
    check(
        (try? FileCodec.decode(wide[1...], encoding: .utf16LE))?.text == "\u{1F600}",
        "an odd-offset UTF-16 slice decodes without an aligned load")
    // One larger document through every encoding, so the bulk paths are exercised too.
    let block = "caf\u{E9} \u{20AC}5 na\u{EF}ve\r\n\tline two\n"
    let large = String(repeating: block, count: 20_000)
    for encoding in encodings {
        for bom in [false, true] where !(bom && ReferenceCodec.bom(encoding).isEmpty) {
            let format = FileFormat(encoding: encoding, bom: bom)
            let text = encoding == .latin1 ? large.replacingOccurrences(of: "\u{20AC}", with: "E") : large
            let bytes = try? FileCodec.encode(text, format: format)
            let back = bytes.flatMap { try? FileCodec.decode($0, encoding: encoding) }
            check(
                bytes != nil && bytes == ReferenceCodec.encode(text, format: format) && back?.text == text
                    && back?.format == format,
                "a \(text.utf8.count)-byte document round-trips exactly as \(encoding) bom=\(bom)")
        }
    }
}
