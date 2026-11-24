@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import os

@main struct FileChecks {
    private static func pairedRecovery(in directory: URL) throws {
        let store = RecoveryStore(directory: directory), id = UUID()
        func draft(_ revision: UInt64, _ text: String) -> RecoverySnapshot {
            .init(
                id: id, text: text, format: .init(encoding: .utf16LE, bom: true),
                originalURL: "file:///never-open-this.txt", revision: revision)
        }
        let a = draft(1, "\u{feff}a\0😀\r\n"), b = draft(2, "b\u{301}\0"), c = draft(3, "latest")
        let url = store.fileURL(for: id)
        try store.save(a)
        let original = try Data(contentsOf: url)
        let object = try requireValue(
            try JSONSerialization.jsonObject(with: original) as? [String: Any], "v2 header object")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let body = try requireValue(files.first { $0.pathExtension == "utf8" }, "first raw sidecar")
        check(
            object["schemaVersion"] as? Int == 2 && object["minimumReaderVersion"] as? Int == 2 && object["text"] == nil
                && object["byteCount"] as? Int == a.text.utf8.count,
            "v2 header contains exact size and requires a v2 reader")
        check(
            try Data(contentsOf: body) == Data(a.text.utf8),
            "published payload is raw UTF-8 with BOM, NUL and CRLF intact")
        rejects("historical minimum-reader gate refuses the v2 header") {
            try PersistedFormat.check(original, context: "Recovery snapshot")
        }
        let fresh = RecoveryStore(directory: directory)
        let inventory = try fresh.scanHeaders()
        let listed = try requireValue(inventory.headers.first, "header-only inventory")
        check(fresh.snapshotReads == 0 && inventory.issues.isEmpty, "launch inventory does not materialize v2 payloads")
        check(
            try fresh.load(listed: listed) == a && fresh.snapshotReads == 1,
            "Recover materializes the exact listed revision")
        rejects("fault before header switch refuses new revision") {
            try store.save(b, beforeCommit: { throw CocoaError(.fileWriteUnknown) })
        }
        check(
            try Data(contentsOf: url) == original && fresh.load(id: id) == a,
            "failed header switch retains complete last good pair")
        rejects("fault after header switch cannot confirm new revision") {
            try store.save(
                b,
                synchronizeHeaderDirectory: { _ in
                    errno = EIO
                    return -1
                }, beforeCommit: {})
        }
        check(
            try fresh.load(id: id) == b && FileManager.default.fileExists(atPath: body.path),
            "visible published generation is complete and old body retained after directory uncertainty")
        try fresh.save(b)
        check(
            !FileManager.default.fileExists(atPath: body.path),
            "cold equal-revision confirmation retires superseded body")
        rejects("old listed generation cannot open an advanced draft", expecting: RecoveryError.staleRevision) {
            _ = try fresh.load(listed: listed)
        }
        check(fresh.discard(listed: [listed]).count == 1, "stale recovery review cannot discard a newer pair")
        let surviving = try requireValue(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "utf8" }, "new raw body")
        let goodBytes = try Data(contentsOf: surviving), goodHeader = try Data(contentsOf: url)
        try Data(repeating: 65, count: goodBytes.count).write(to: surviving)
        rejects("same-length damage is detected on Recover", expecting: RecoveryError.invalidSnapshot) {
            _ = try fresh.load(id: id)
        }
        rejects("same-length damage prevents cached overwrite", expecting: RecoveryError.invalidSnapshot) {
            try fresh.save(c)
        }
        rejects("same-length damage prevents cleanup", expecting: RecoveryError.invalidSnapshot) {
            try fresh.remove(id: id, throughRevision: 3)
        }
        try FileManager.default.removeItem(at: surviving)
        let damaged = try fresh.scanHeaders()
        check(
            try damaged.headers.isEmpty && damaged.issues.count == 1 && Data(contentsOf: url) == goodHeader,
            "missing sidecar is an issue and its header stays byte-identical")
        try goodBytes.write(to: surviving)
        try fresh.remove(id: id, throughRevision: 2)
        check(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
            "acknowledged removal cleans up header and raw payload together")
        var historical = try JSONEncoder().encode(a)
        try require(historical.first == 0x7b, "historical v1 fixture starts with an object")
        // Keep the legacy text’s leading U+FEFF and original timestamp token when adding unknown fields.
        historical.insert(contentsOf: #""generation":"legacy unknown","byteCount":["ignored"],"#.utf8, at: 1)
        try historical.write(to: url)
        let legacy = try fresh.scanHeaders()
        check(
            try legacy.headers.count == 1 && fresh.load(listed: legacy.headers[0]) == a,
            "genuine v1 payload stays readable through header review")
        try fresh.save(c)
        check(try fresh.load(id: id) == c, "advance after historical v1 publishes a complete new pair")
    }
    private static func independentRecoveryWrites(in directory: URL) throws {
        let store = RecoveryStore(directory: directory), second = RecoveryStore(directory: directory)
        let a = UUID(), b = UUID(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0), futureResult = DispatchSemaphore(value: 0),
            otherDone = DispatchSemaphore(value: 0)
        let old = RecoverySnapshot(id: a, text: "old", format: FileFormat(), originalURL: nil, revision: 1)
        let next = RecoverySnapshot(id: a, text: "new", format: FileFormat(), originalURL: nil, revision: 2)
        let neighbour = RecoverySnapshot(id: b, text: "B", format: FileFormat(), originalURL: nil, revision: 1)
        try store.save(old)
        DispatchQueue.global().async {
            do {
                try store.save(
                    next,
                    beforeCommit: {
                        entered.signal()
                        guard release.wait(timeout: .now() + 10) == .success else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    })
                firstDone.signal()
            } catch {
                Checks.fail(
                    "held snapshot could not publish: " + error.localizedDescription, file: #filePath, line: #line)
            }
        }
        guard entered.wait(timeout: .now() + 5) == .success else {
            release.signal()
            throw CocoaError(.fileWriteUnknown)
        }
        DispatchQueue.global().async {
            do {
                try second.save(old)
                Checks.fail("stale same-ID publication was accepted", file: #filePath, line: #line)
            } catch RecoveryError.staleRevision { futureResult.signal() } catch {
                Checks.fail(
                    "unexpected same-ID recovery error: " + error.localizedDescription, file: #filePath, line: #line)
            }
        }
        DispatchQueue.global().async {
            do {
                try store.save(neighbour)
                try store.remove(id: b, throughRevision: 1)
                otherDone.signal()
            } catch {
                Checks.fail(
                    "independent recovery operation failed: " + error.localizedDescription, file: #filePath, line: #line
                )
            }
        }
        let ran = otherDone.wait(timeout: .now() + 3) == .success
        let waiting = futureResult.wait(timeout: .now()) == .timedOut
        release.signal()
        check(ran && waiting, "unrelated ID publishes and removes while the same-ID writer remains serialized")
        check(
            firstDone.wait(timeout: .now() + 5) == .success && futureResult.wait(timeout: .now() + 5) == .success,
            "another store sharing the directory rejects the older revision after publication")
        check(
            try store.load(id: a).text == "new" && !FileManager.default.fileExists(atPath: store.fileURL(for: b).path),
            "concurrent recovery operations preserve both final document states")
    }
    static func main() {
        Checks.run("FileChecks") {
            if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--recovery-busy" {
                let store = RecoveryStore(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
                let id = UUID(uuidString: CommandLine.arguments[3])!
                let draft = RecoverySnapshot(
                    id: id, text: "foreign", format: FileFormat(), originalURL: nil, revision: 2)
                rejects("second process cannot edit with this recovery root", expecting: RecoveryError.inUse) {
                    try store.claimOwnership()
                }
                rejects("second process cannot scan live drafts", expecting: RecoveryError.inUse) {
                    _ = try store.scan()
                }
                rejects("second process cannot load live draft", expecting: RecoveryError.inUse) {
                    _ = try store.load(id: id)
                }
                rejects("second process cannot overwrite live draft", expecting: RecoveryError.inUse) {
                    try store.save(draft)
                }
                rejects("second process cannot remove live draft", expecting: RecoveryError.inUse) {
                    try store.remove(id: id, throughRevision: 2)
                }
                check(store.discard([draft]).count == 1, "second process reports failed discard")
                return
            }
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
            if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--writer-reentrancy" {
                try writerReentrancy(CommandLine.arguments[2])
                return
            }
            for mode in ["submit", "finish"] {
                let child = Process()
                child.executableURL = Checks.executable
                child.arguments = ["--writer-reentrancy", mode]
                try child.run()
                child.waitUntilExit()
                check(
                    child.terminationReason == .exit && child.terminationStatus == 0,
                    "F316 displaced recovery capture can reenter writer during " + mode)
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
            let other = Process()
            other.executableURL = Checks.executable
            other.arguments = ["--recovery-busy", storeURL.path, id.uuidString]
            try other.run()
            other.waitUntilExit()
            check(
                other.terminationReason == .exit && other.terminationStatus == 0,
                "concurrent process refuses recovery ownership")
            check(try store.load(id: id) == first, "concurrent refusal retains original live snapshot")
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
            Checks.section("V9 a quit confirms the published recovery copy by reading it back") {
                let id = UUID()
                let kept = RecoverySnapshot(
                    id: id, text: "kept caf\u{E9}\r\n\0😀", format: FileFormat(encoding: .utf16LE, bom: true),
                    originalURL: nil, revision: 4)
                rejects("V9 a copy that was never written is not confirmed") { try store.confirm(kept) }
                try store.save(kept)
                try store.confirm(kept)
                check(try RecoveryStore(directory: storeURL).load(id: id) == kept, "V9 the confirmed copy is the document")
                let twin = RecoverySnapshot(
                    id: id, text: "kept cafe\u{301}\r\n\0😀", format: kept.format, originalURL: nil, revision: 4)
                rejects("V9 text with other bytes is not confirmed", expecting: RecoveryError.staleRevision) {
                    try store.confirm(twin)
                }
                let later = RecoverySnapshot(
                    id: id, text: kept.text, format: kept.format, originalURL: nil, revision: 5)
                rejects("V9 a later revision than the one on disk is not confirmed", expecting: RecoveryError.staleRevision) {
                    try store.confirm(later)
                }
                let body = try FileManager.default.contentsOfDirectory(at: storeURL, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(id.uuidString + ".") && $0.pathExtension == "utf8" }
                let file = try requireValue(body, "V9 the copy's text file")
                let original = try Data(contentsOf: file)
                var damaged = original
                damaged[0] ^= 0x01
                try damaged.write(to: file)
                rejects("V9 a text file that no longer matches its recorded hash is not confirmed") {
                    try store.confirm(kept)
                }
                try original.write(to: file)
                try store.confirm(kept)
                try store.remove(id: id, throughRevision: 4)
            }
            Checks.section("V10 local history store") {
                final class Clock: @unchecked Sendable {
                    private let lock = NSLock()
                    private var value = Date(timeIntervalSince1970: 1_800_000_000)
                    var now: Date {
                        lock.lock()
                        defer { lock.unlock() }
                        return value
                    }
                    func advance(_ seconds: TimeInterval) {
                        lock.lock()
                        value += seconds
                        lock.unlock()
                    }
                }
                func mode(_ url: URL) throws -> Int {
                    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
                }
                func record(
                    _ store: LocalHistoryStore, _ path: String, _ text: String, replaced: String? = nil
                ) throws {
                    let failure = OSAllocatedUnfairLock<Error?>(initialState: nil)
                    store.record(
                        path: path, bytes: Data(text.utf8), format: FileFormat(),
                        replaced: replaced.map { Data($0.utf8) }
                    ) { result in
                        if case .failure(let error) = result { failure.withLock { $0 = error } }
                    }
                    store.waitUntilIdle()
                    if let error = failure.withLock({ $0 }) { throw error }
                }
                func texts(_ store: LocalHistoryStore, _ path: String) throws -> [String] {
                    try store.versions(forPath: path).map {
                        String(decoding: try store.data(forPath: path, version: $0.id), as: UTF8.self)
                    }
                }
                let base = root.appendingPathComponent("local-history-checks", isDirectory: true)
                let home = base.appendingPathComponent("LocalHistory", isDirectory: true)
                let clock = Clock()
                let store = LocalHistoryStore(directory: home, clock: { clock.now })
                let a = "/synthetic/project/a.txt", b = "/synthetic/project/b.txt"
                check(
                    try store.versions(forPath: a).isEmpty && store.latestDigest(forPath: a) == nil
                        && !FileManager.default.fileExists(atPath: home.path),
                    "V10 reading an empty history creates nothing")
                for text in ["one", "two", "three"] {
                    try record(store, a, text)
                    clock.advance(1)
                }
                check(try texts(store, a) == ["three", "two", "one"], "V10 three saves list three versions, newest first")
                let listed = try store.versions(forPath: a)
                check(
                    listed.allSatisfy { $0.kind == .saved && $0.format == FileFormat() } && listed.map(\.byteCount) == [5, 3, 3]
                        && listed[0].sha256 == WorkspaceStore.fingerprint(Data("three".utf8))
                        && store.latestDigest(forPath: a) == listed[0].sha256,
                    "V10 each version records its date, size, digest and encoding")
                try record(store, a, "three")
                check(try texts(store, a) == ["three", "two", "one"], "V10 identical consecutive versions are stored once")
                let folders = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
                let files = try FileManager.default.contentsOfDirectory(at: folders[0], includingPropertiesForKeys: nil)
                check(
                    try folders.count == 1 && folders[0].lastPathComponent == WorkspaceStore.fingerprint(Data(a.utf8))
                        && mode(home) == 0o700 && mode(folders[0]) == 0o700 && files.count == 4
                        && files.allSatisfy { try mode($0) == 0o600 }
                        && !FileManager.default.fileExists(atPath: "/synthetic"),
                    "V10 one private folder per file, named by its path's digest, never beside the document")
                let manifest =
                    try JSONSerialization.jsonObject(
                        with: Data(contentsOf: folders[0].appendingPathComponent("manifest.json"))) as! [String: Any]
                check(
                    manifest["version"] as? Int == 1 && manifest["path"] as? String == a
                        && (manifest["versions"] as? [[String: Any]])?.count == 3,
                    "V10 the manifest is a versioned record of the file's path and versions")
                try record(store, b, "new", replaced: "was on disk")
                check(
                    try texts(store, b) == ["new", "was on disk"]
                        && store.versions(forPath: b).map(\.kind) == [.saved, .replaced],
                    "V10 bytes a save replaced are kept before the bytes it wrote")
                clock.advance(1)
                try record(store, b, "newer", replaced: "new")
                check(
                    try texts(store, b) == ["newer", "new", "was on disk"],
                    "V10 replaced bytes that history already ends with are not kept twice")
                // Twenty a file.
                let c = "/synthetic/project/c.txt"
                for index in 0..<21 {
                    clock.advance(1)
                    try record(store, c, "version \(index)")
                }
                let twenty = try texts(store, c)
                check(
                    twenty.count == 20 && twenty.first == "version 20" && twenty.last == "version 1"
                        && !twenty.contains("version 0"),
                    "V10 the twenty-first version evicts the oldest")
                let cFolder = home.appendingPathComponent(WorkspaceStore.fingerprint(Data(c.utf8)))
                check(
                    try FileManager.default.contentsOfDirectory(atPath: cFolder.path).filter { $0.hasSuffix(".bytes") }
                        .count == 20,
                    "V10 an evicted version's bytes are deleted")
                check(
                    store.usage() == LocalHistoryUsage(files: 3, versions: 26, bytes: 11 + 19 + twenty.reduce(0) { $0 + $1.utf8.count })
                        && store.usage(forPath: a) == LocalHistoryUsage(files: 1, versions: 3, bytes: 11),
                    "V10 usage counts files, versions and bytes")
                // Thirty days.
                clock.advance(30 * 24 * 60 * 60 - 60)
                try record(store, a, "four")
                check(
                    try texts(store, a) == ["four", "three", "two", "one"] && texts(store, c).count == 20,
                    "V10 a version just inside thirty days is kept")
                clock.advance(45)
                let pruned = OSAllocatedUnfairLock<Bool>(initialState: false)
                store.prune { _ in pruned.withLock { $0 = true } }
                store.waitUntilIdle()
                check(
                    try pruned.withLock { $0 } && texts(store, a) == ["four"] && texts(store, b).isEmpty
                        && texts(store, c).count == 16 && !texts(store, c).contains("version 4")
                        && texts(store, c).last == "version 5",
                    "V10 versions older than thirty days are removed, oldest first, and an emptied file's folder with them")
                check(
                    try FileManager.default.contentsOfDirectory(atPath: home.path).count == 2,
                    "V10 a file with no version left has no folder")
                // 200 MB in all, here scaled down; and the per-version size limit.
                var limits = LocalHistoryLimits()
                check(
                    limits.versionsPerFile == 20 && limits.maximumAge == 30 * 24 * 60 * 60
                        && limits.totalBytes == 200_000_000 && limits.versionBytes == 32 * 1024 * 1024,
                    "V10 the documented limits: 20 versions, 30 days, 200 MB, 32 MiB a version")
                limits.totalBytes = 1000
                limits.versionBytes = 600
                let smallHome = base.appendingPathComponent("Small", isDirectory: true)
                let small = LocalHistoryStore(directory: smallHome, limits: limits, clock: { clock.now })
                let x = "/synthetic/x.txt", y = "/synthetic/y.txt"
                let block = { (letter: String) in String(repeating: letter, count: 400) }
                try record(small, x, block("a"))
                clock.advance(1)
                try record(small, y, block("b"))
                clock.advance(1)
                check(small.usage().bytes == 800, "V10 fixture: 800 bytes of history under a 1000 byte limit")
                try record(small, x, block("c"))
                check(
                    try texts(small, x) == [block("c")] && texts(small, y) == [block("b")] && small.usage().bytes == 800,
                    "V10 over the total limit the oldest version of any file goes first")
                try record(small, y, String(repeating: "z", count: 601))
                check(
                    try texts(small, y) == [block("b")] && small.usage().bytes == 800,
                    "V10 a save above the per-version size limit is not kept")
                // A rename takes the history along and joins one already there.
                let z = "/synthetic/z.txt"
                clock.advance(1)
                try record(small, z, "zed")
                small.relocate(from: x, to: z)
                small.waitUntilIdle()
                check(
                    try texts(small, x).isEmpty && texts(small, z) == ["zed", block("c")]
                        && !FileManager.default.fileExists(
                            atPath: smallHome.appendingPathComponent(WorkspaceStore.fingerprint(Data(x.utf8))).path),
                    "V10 relocating joins the moved history with the destination's, in date order")
                // Damage and absence are reported, never papered over.
                let zVersions = try small.versions(forPath: z)
                let zFolder = smallHome.appendingPathComponent(WorkspaceStore.fingerprint(Data(z.utf8)))
                let blob = zFolder.appendingPathComponent(zVersions[0].id.uuidString + ".bytes")
                try Data("zEd".utf8).write(to: blob)
                rejects("V10 bytes that no longer match their digest are refused", expecting: LocalHistoryError.damaged) {
                    _ = try small.data(forPath: z, version: zVersions[0].id)
                }
                rejects("V10 an unknown version is reported as missing", expecting: LocalHistoryError.missing) {
                    _ = try small.data(forPath: z, version: UUID())
                }
                try record(small, smallHome.appendingPathComponent("inside.txt").path, "never")
                check(
                    small.usage().files == 2,
                    "V10 a file inside the store gets no history of its own")
                // Clear: this file, then everything, and nothing else.
                let stranger = smallHome.appendingPathComponent("stranger.txt")
                let strangerFolder = smallHome.appendingPathComponent("not-a-digest", isDirectory: true)
                try Data("keep".utf8).write(to: stranger)
                try FileManager.default.createDirectory(at: strangerFolder, withIntermediateDirectories: false)
                check(
                    try small.clear(path: y) == LocalHistoryUsage(files: 1, versions: 1, bytes: 400)
                        && texts(small, y).isEmpty && small.versions(forPath: z).count == 2,
                    "V10 clearing one file's history leaves the others")
                check(
                    try small.clear().versions == 2 && small.usage() == LocalHistoryUsage(files: 0, versions: 0, bytes: 0)
                        && Set(FileManager.default.contentsOfDirectory(atPath: smallHome.path))
                            == ["stranger.txt", "not-a-digest"]
                        && Data(contentsOf: stranger) == Data("keep".utf8),
                    "V10 clearing everything removes the store's own folders and nothing else")
                check(try store.clear().files == 2 && store.usage().versions == 0, "V10 the first store clears too")
                // Fix round 1, finding 3: a folder without a readable manifest is not a dead end.
                func folder(_ store: LocalHistoryStore, _ path: String) -> URL {
                    store.directory.appendingPathComponent(WorkspaceStore.fingerprint(Data(path.utf8)))
                }
                /// Leaves the folder as a stop or damage would: no manifest, or an unreadable one.
                /// The bytes are dated now by this check's clock, as they would be by the real one.
                func spoil(_ store: LocalHistoryStore, _ path: String, with garbage: Data? = nil) throws {
                    let home = folder(store, path), manifest = home.appendingPathComponent("manifest.json")
                    for name in try FileManager.default.contentsOfDirectory(atPath: home.path) where name.hasSuffix(".bytes") {
                        try FileManager.default.setAttributes(
                            [.modificationDate: clock.now], ofItemAtPath: home.appendingPathComponent(name).path)
                    }
                    if let garbage { try garbage.write(to: manifest) } else { try FileManager.default.removeItem(at: manifest) }
                }
                let healHome = base.appendingPathComponent("Heal", isDirectory: true)
                let heal = LocalHistoryStore(directory: healHome, clock: { clock.now })
                let h = "/synthetic/heal.txt", g = "/synthetic/garbled.txt"
                try record(heal, h, "first bytes")
                // As after a stop between the first version's bytes and its manifest.
                try spoil(heal, h)
                check(
                    try heal.usage() == LocalHistoryUsage(files: 1, versions: 1, bytes: 11)
                        && heal.usage(forPath: h).versions == 1 && texts(heal, h) == ["first bytes"],
                    "F3 bytes without a manifest are counted, listed and readable for their file")
                clock.advance(1)
                try record(heal, h, "second bytes")
                check(
                    try texts(heal, h) == ["second bytes", "first bytes"]
                        && FileManager.default.fileExists(atPath: folder(heal, h).appendingPathComponent("manifest.json").path),
                    "F3 the next save of that file is kept and writes a manifest naming what was there")
                try record(heal, g, "before damage")
                try spoil(heal, g, with: Data("{ not a manifest".utf8))
                clock.advance(1)
                try record(heal, g, "after damage")
                check(
                    try texts(heal, g) == ["after damage", "before damage"],
                    "F3 a damaged manifest does not block new versions, and the bytes it named are kept")
                try spoil(heal, g, with: Data("{ not a manifest".utf8))
                check(
                    try heal.usage(forPath: g) == LocalHistoryUsage(files: 1, versions: 2, bytes: 25)
                        && heal.clear(path: g).versions == 2
                        && !FileManager.default.fileExists(atPath: folder(heal, g).path),
                    "F3 a damaged folder is counted and can be cleared for its file")
                // It also expires and counts toward the total, with no path to go by.
                try record(heal, g, "damaged again")
                try spoil(heal, g)
                clock.advance(31 * 24 * 60 * 60)
                heal.prune()
                heal.waitUntilIdle()
                check(
                    try heal.usage() == LocalHistoryUsage(files: 0, versions: 0, bytes: 0)
                        && FileManager.default.contentsOfDirectory(atPath: healHome.path).isEmpty,
                    "F3 bytes without a manifest expire like any version")
                // An interrupted move: the folder was renamed, its manifest still states the old path.
                let from = "/synthetic/before-move.txt", to = "/synthetic/after-move.txt"
                try record(heal, from, "moved one")
                clock.advance(1)
                try record(heal, from, "moved two")
                try FileManager.default.moveItem(at: folder(heal, from), to: folder(heal, to))
                check(
                    try texts(heal, to) == ["moved two", "moved one"] && texts(heal, from).isEmpty
                        && heal.versions(forPath: to).allSatisfy { $0.kind == .saved && $0.format == FileFormat() },
                    "F3 a move that stopped after the rename still lists every version, with its record")
                clock.advance(1)
                try record(heal, to, "moved three")
                check(
                    try texts(heal, to) == ["moved three", "moved two", "moved one"],
                    "F3 the next save after an interrupted move repairs the manifest")
                // Joining two histories links the bytes before either manifest changes.
                try record(heal, from, "late arrival")
                heal.relocate(from: from, to: to)
                heal.waitUntilIdle()
                check(
                    try texts(heal, to).first == "late arrival" && texts(heal, to).count == 4
                        && !FileManager.default.fileExists(atPath: folder(heal, from).path),
                    "F3 joining a moved history keeps every version of both and removes the old folder last")
                // Finding 4: every reply says what each file's newest version now is.
                var tight = LocalHistoryLimits()
                tight.totalBytes = 12
                let replyHome = base.appendingPathComponent("Reply", isDirectory: true)
                let replying = LocalHistoryStore(directory: replyHome, limits: tight, clock: { clock.now })
                let replies = OSAllocatedUnfairLock<[[String: String?]]>(initialState: [])
                let p1 = "/synthetic/one.txt", p2 = "/synthetic/two.txt"
                replying.record(path: p1, bytes: Data("12345678".utf8)) { result in
                    if case .success(let change) = result { replies.withLock { $0.append(change.newest) } }
                }
                replying.waitUntilIdle()
                clock.advance(1)
                replying.record(path: p2, bytes: Data("abcdefgh".utf8)) { result in
                    if case .success(let change) = result { replies.withLock { $0.append(change.newest) } }
                }
                replying.waitUntilIdle()
                let told = replies.withLock { $0 }
                check(
                    told.count == 2 && told[0] == [p1: WorkspaceStore.fingerprint(Data("12345678".utf8))]
                        && told[1] == [p2: WorkspaceStore.fingerprint(Data("abcdefgh".utf8)), p1: String?.none],
                    "F4 a record's reply names the newest version of its file and of every file it evicted from")
                // Finding 6: the asynchronous entry points answer without the caller waiting.
                let answers = OSAllocatedUnfairLock<(LocalHistoryUsage?, LocalHistoryUsage)?>(initialState: nil)
                replying.summary(forPath: p2) { own, all in answers.withLock { $0 = (own, all) } }
                let cleared = OSAllocatedUnfairLock<Int>(initialState: -1)
                replying.clear(path: nil) { result in cleared.withLock { $0 = (try? result.get().versions) ?? -2 } }
                replying.waitUntilIdle()
                check(
                    answers.withLock { $0?.0 } == LocalHistoryUsage(files: 1, versions: 1, bytes: 8)
                        && answers.withLock { $0?.1 } == LocalHistoryUsage(files: 1, versions: 1, bytes: 8)
                        && cleared.withLock { $0 } == 1 && replying.usage().versions == 0,
                    "F6 summary and clear answer through their completion")
                // Fix round 2: a manifest written by a newer TextTank is not damage. Its folder is
                // left entirely alone, whatever this build is asked to do with that file.
                let newerHome = base.appendingPathComponent("Newer", isDirectory: true)
                let newer = LocalHistoryStore(directory: newerHome, clock: { clock.now })
                let n = "/synthetic/newer.txt", m = "/synthetic/moving.txt"
                try record(newer, n, "kept by a newer build")
                let newerFolder = folder(newer, n), newerManifest = newerFolder.appendingPathComponent("manifest.json")
                let fixture = Data(
                    #"{"entries":[{"blob":"x"}],"minimumReaderVersion":2,"path":"/synthetic/newer.txt","version":2}"#.utf8)
                try fixture.write(to: newerManifest)
                let untouched = try FileManager.default.contentsOfDirectory(atPath: newerFolder.path).sorted()
                check(
                    try newer.versions(forPath: n).isEmpty && newer.latestDigest(forPath: n) == nil
                        && newer.usage() == LocalHistoryUsage(files: 0, versions: 0, bytes: 0),
                    "R2 a version-2 manifest is not read as version 1, and its folder is not counted")
                clock.advance(40 * 24 * 60 * 60)
                try record(newer, n, "a save by this build")
                try record(newer, m, "moving in")
                newer.relocate(from: m, to: n)
                newer.prune()
                newer.waitUntilIdle()
                check(
                    try newer.clear(path: n).versions == 0 && newer.clear().versions == 1,
                    "R2 clearing does not count or remove a newer build's folder")
                check(
                    try Data(contentsOf: newerManifest) == fixture
                        && FileManager.default.contentsOfDirectory(atPath: newerFolder.path).sorted() == untouched
                        && untouched.count == 2,
                    "R2 a save, a move into it, expiry and Clear leave a version-2 folder exactly as it was")
                try FileManager.default.removeItem(at: base)
            }
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
            let healthyHeader = try Data(contentsOf: path)
            let corrupt = Data("{partial write".utf8)
            try corrupt.write(to: path)
            rejects("corrupt read", expecting: RecoveryError.invalidSnapshot) { _ = try store.load(id: id) }
            rejects("corrupt snapshot cannot be overwritten", expecting: RecoveryError.invalidSnapshot) {
                try store.save(second)
            }
            check(try Data(contentsOf: path) == corrupt, "corrupt remains inspectable")
            check(try Data(contentsOf: original) == originalBytes, "original never changed")
            check(
                try store.scanHeaders().issues.contains { $0.url.pathExtension == "utf8" },
                "corrupt header reports its retained raw text for inspection")
            try healthyHeader.write(to: path)
            try store.remove(id: id, throughRevision: second.revision)
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
            let events = RecoveryEvents()
            let record: @Sendable (String) -> Void = { events.record($0) }
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
                events.read()
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
            // A failed later capture cannot displace a complete draft that is waiting for disk I/O.
            let checkedWriter = RecoveryWriter(), diskReady = DispatchSemaphore(value: 0)
            let diskRelease = DispatchSemaphore(value: 0), prepared = DispatchSemaphore(value: 0)
            let history = RecoveryEvents()
            checkedWriter.submit {
                diskReady.signal()
                _ = diskRelease.wait(timeout: .now() + 5)
            }
            check(diskReady.wait(timeout: .now() + 2) == .success, "controlled recovery disk queue is occupied")
            checkedWriter.submitPrepared(
                { { history.record("valid") } }, didPrepare: { prepared.signal() },
                completion: { _ in })
            check(prepared.wait(timeout: .now() + 2) == .success, "validation can finish while disk is blocked")
            checkedWriter.submitPrepared(
                { throw RecoveryError.invalidSnapshot }, didPrepare: { prepared.signal() },
                completion: { if $0 != nil { history.record("invalid") } })
            check(prepared.wait(timeout: .now() + 2) == .success, "invalid capture reports without admitting a write")
            DispatchQueue.global().async { diskRelease.signal() }
            rejects("invalid explicit flush reports its own error", expecting: RecoveryError.invalidSnapshot) {
                try checkedWriter.finishPrepared { throw RecoveryError.invalidSnapshot }
            }
            check(
                history.read() == ["invalid", "valid"],
                "failed flush retains and waits for the last valid pending draft")

            try pairedRecovery(in: root.appendingPathComponent("paired-drafts"))
            try independentRecoveryWrites(in: root.appendingPathComponent("parallel-drafts"))
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
            try cacheWritten.write(to: cacheFile)
            try cacheStore.remove(id: cacheID, throughRevision: 10)
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

/// Test-owned event state is shared only through this lock, including snapshot reads.
private final class RecoveryEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }
    func read() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// The pending closure is the sole owner after enqueue returns. Its destruction reenters
/// the actual linked writer; a child watchdog turns lock reentrancy into a bounded failure.
private final class WriterReentryToken: Sendable {
    let writer: RecoveryWriter
    let destroyed: DispatchSemaphore
    init(writer: RecoveryWriter, destroyed: DispatchSemaphore) {
        self.writer = writer
        self.destroyed = destroyed
    }
    deinit {
        writer.submit {}
        destroyed.signal()
    }
}
private func enqueueReentryToken(_ writer: RecoveryWriter, destroyed: DispatchSemaphore) {
    let token = WriterReentryToken(writer: writer, destroyed: destroyed)
    writer.submit { withExtendedLifetime(token) {} }
}
private func writerReentrancy(_ mode: String) throws {
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(70) }
    let writer = RecoveryWriter(), entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0), destroyed = DispatchSemaphore(value: 0)
    writer.submit {
        entered.signal()
        release.wait()
    }
    try require(entered.wait(timeout: .now() + 1) == .success, "fixture: writer operation is blocked")
    enqueueReentryToken(writer, destroyed: destroyed)
    if mode == "submit" {
        writer.submit {}
        release.signal()
        writer.finish {}
    } else if mode == "finish" {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { release.signal() }
        writer.finish {}
    } else {
        throw NSError(domain: "WriterReentryFixture", code: 64)
    }
    check(
        destroyed.wait(timeout: .now() + 1) == .success,
        "displaced closure is destroyed after unlocking during " + mode)
}
