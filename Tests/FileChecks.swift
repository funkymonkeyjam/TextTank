// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@main struct FileChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { fatalError("FAILED: \(label)") }; checks += 1
    }
    static func rejects(_ label: String, _ work: () throws -> Void) {
        do { try work(); fatalError("FAILED expected rejection: \(label)") } catch { checks += 1 }
    }
    static func main() throws {
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--crash-write" {
            let directory = URL(fileURLWithPath:CommandLine.arguments[2])
            let original = URL(fileURLWithPath:CommandLine.arguments[3])
            let id = UUID(uuidString:CommandLine.arguments[4])!
            let store = RecoveryStore(directory:directory)
            try store.save(RecoverySnapshot(id:id,text:"named after crash\0😀",format:FileFormat(),originalURL:original.absoluteString,revision:12))
            try store.save(RecoverySnapshot(id:UUID(),text:"untitled after crash",format:FileFormat(),originalURL:nil,revision:7))
            // SIGKILL bypasses defer, normal termination hooks and store deinitialization.
            kill(getpid(), SIGKILL)
            fatalError("SIGKILL unexpectedly returned")
        }
        let samples = ["", "\0", "\0hello", "A\0B\r\nC\nD\rE", "½ cup — café 👩🏽‍💻 e\u{301}", "\u{FEFF}inside"]
        for encoding in [FileEncoding.utf8,.utf16LE,.utf16BE] {
            for bom in [false,true] {
                for sample in samples {
                    let format = FileFormat(encoding: encoding,bom: bom)
                    let bytes = try FileCodec.encode(sample,format: format)
                    // Explicit selection distinguishes an intentional leading U+FEFF from a BOM.
                    // Leading U+FEFF at file start is treated as BOM by decoding contract.
                    if sample.hasPrefix("\u{FEFF}") && !bom { continue }
                    let decoded = try FileCodec.decode(bytes, encoding: encoding)
                    try check(decoded.text == sample && decoded.format == format, "Unicode text/format roundtrip \(encoding) bom=\(bom) input=\(sample.debugDescription) output=\(decoded.text.debugDescription) format=\(decoded.format)")
                    try check(FileCodec.encode(decoded.text, format: decoded.format) == bytes, "exact bytes roundtrip")
                    if bom {
                        if encoding == .utf16LE && sample.hasPrefix("\0") {
                            rejects("ambiguous UTF32/UTF16 NUL requires explicit choice") { _ = try FileCodec.decode(bytes) }
                        } else { try check(FileCodec.decode(bytes).text == sample, "BOM auto detection") }
                    }
                }
            }
        }
        for byte in UInt16(0)...255 {
            let data = Data([UInt8(byte)])
            let decoded = try FileCodec.decode(data, encoding: .latin1)
            try check(FileCodec.encode(decoded.text, format: decoded.format) == data, "all Latin1 bytes")
            if ![0x81,0x8D,0x8F,0x90,0x9D].contains(byte) {
                let cp = try FileCodec.decode(data, encoding: .windows1252)
                try check(FileCodec.encode(cp.text, format: cp.format) == data, "defined cp1252 byte")
            } else { rejects("undefined cp1252") { _ = try FileCodec.decode(data, encoding: .windows1252) } }
        }
        for bytes: [UInt8] in [[0xC0,0xAF],[0xED,0xA0,0x80],[0xF4,0x90,0x80,0x80],[0x80],[0xFF]] {
            rejects("invalid UTF8 no guessed fallback") { _ = try FileCodec.decode(Data(bytes)) }
        }
        for bytes: [UInt8] in [[0],[0,0xD8],[0,0xDC],[0,0xD8,65,0]] {
            rejects("invalid UTF16") { _ = try FileCodec.decode(Data(bytes), encoding: .utf16LE) }
        }
        for bytes: [UInt8] in [[0xFF,0xFE,0,0,65,0,0,0],[0,0,0xFE,0xFF,0,0,0,65]] {
            rejects("UTF32 signature not silently misread") { _ = try FileCodec.decode(Data(bytes)) }
        }
        rejects("unrepresentable") { _ = try FileCodec.encode("€😀", format: FileFormat(encoding: .latin1)) }
        rejects("cp1252 C1 not silently mapped") { _ = try FileCodec.encode("\u{81}", format: FileFormat(encoding: .windows1252)) }
        rejects("legacy BOM") { _ = try FileCodec.encode("abc", format: FileFormat(encoding: .latin1,bom: true)) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextTankFileChecks-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        let originalBytes = Data("original\r\n".utf8); try originalBytes.write(to: original)
        let storeURL = root.appendingPathComponent("recovery")
        let store = RecoveryStore(directory: storeURL)
        let id = UUID()
        let first = RecoverySnapshot(id:id,text:"edited\0😀",format:FileFormat(),originalURL:original.absoluteString,revision:1)
        try store.save(first)
        let firstPath = storeURL.appendingPathComponent(id.uuidString+".json")
        let privateDirectoryMode = (try FileManager.default.attributesOfItem(atPath:storeURL.path)[.posixPermissions] as! NSNumber).intValue
        let privateFileMode = (try FileManager.default.attributesOfItem(atPath:firstPath.path)[.posixPermissions] as! NSNumber).intValue
        try check(privateDirectoryMode == 0o700 && privateFileMode == 0o600,"recovery directory and initial file private")
        try check(store.load(id:id) == first,"exact snapshot reload")
        // Reinstantiate to demonstrate persistence independent of live store instance.
        try check(RecoveryStore(directory:storeURL).load(id:id) == first,"restart reload")
        let second = RecoverySnapshot(id:id,text:"newer",format:FileFormat(),originalURL:original.absoluteString,revision:2)
        // Simulate old broad metadata and require replacement to restore private permissions.
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:storeURL.path)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:firstPath.path)
        let parentModeBefore = (try FileManager.default.attributesOfItem(atPath:root.path)[.posixPermissions] as! NSNumber).intValue
        try store.save(second)
        let replacedMode = (try FileManager.default.attributesOfItem(atPath:firstPath.path)[.posixPermissions] as! NSNumber).intValue
        let correctedDirectoryMode = (try FileManager.default.attributesOfItem(atPath:storeURL.path)[.posixPermissions] as! NSNumber).intValue
        let parentModeAfter = (try FileManager.default.attributesOfItem(atPath:root.path)[.posixPermissions] as! NSNumber).intValue
        try check(replacedMode == 0o600 && correctedDirectoryMode == 0o700,"replacement repairs old broad recovery metadata")
        try check(parentModeBefore == parentModeAfter,"recovery privacy does not chmod parent")
        rejects("stale write") { try store.save(first) }
        rejects("stale cleanup") { try store.remove(id:id,throughRevision:1) }
        try check(store.load(id:id) == second,"newer survives stale operations")
        let wrongEqual = RecoverySnapshot(id:id,text:"different",format:FileFormat(),originalURL:original.absoluteString,revision:2)
        rejects("equal revision conflicting text") { try store.save(wrongEqual) }
        let path = storeURL.appendingPathComponent(id.uuidString+".json")
        let corrupt = Data("{partial write".utf8); try corrupt.write(to:path)
        rejects("corrupt read") { _ = try store.load(id:id) }
        rejects("corrupt snapshot cannot be overwritten") { try store.save(second) }
        try check(Data(contentsOf:path) == corrupt,"corrupt remains inspectable")
        try check(Data(contentsOf:original) == originalBytes,"original never changed")
        try FileManager.default.removeItem(at:path)
        let overflow = RecoverySnapshot(id:UUID(),text:"preserve",format:FileFormat(),originalURL:nil,revision:UInt64.max)
        rejects("unbounded revision rejected before restore arithmetic") { try store.save(overflow) }
        let overflowPath = storeURL.appendingPathComponent(overflow.id.uuidString+".json")
        let overflowBytes = try JSONEncoder().encode(overflow); try overflowBytes.write(to:overflowPath)
        rejects("unbounded persisted revision rejected") { _ = try store.load(id:overflow.id) }
        try check(Data(contentsOf:overflowPath) == overflowBytes,"invalid revision preserved for review")
        try FileManager.default.removeItem(at:overflowPath)
        var unknown = first; unknown.schemaVersion = 999
        rejects("unknown write version") { try store.save(unknown) }
        try JSONEncoder().encode(unknown).write(to:path)
        rejects("unknown read version") { _ = try store.load(id:id) }
        try FileManager.default.removeItem(at:path)
        try FileManager.default.createSymbolicLink(at:path,withDestinationURL:original)
        rejects("symlink write") { try store.save(first) }
        try check(Data(contentsOf:original) == originalBytes,"symlink target unchanged")
        try FileManager.default.removeItem(at:path)
        let untitled = RecoverySnapshot(id:UUID(),text:"unsaved",format:FileFormat(encoding:.latin1),originalURL:nil,revision:1)
        try store.save(untitled)
        try check(store.loadAll() == [untitled],"untitled snapshot")
        let unrepresentable = RecoverySnapshot(id:untitled.id,text:"😀",format:untitled.format,originalURL:nil,revision:2)
        try store.save(unrepresentable)
        try check(store.load(id:untitled.id).text == "😀","recover pending unrepresentable edits")
        let broken = storeURL.appendingPathComponent(UUID().uuidString+".json")
        let brokenBytes = Data("{broken".utf8); try brokenBytes.write(to:broken)
        let scan = try store.scan()
        try check(scan.snapshots.count == 1 && scan.snapshots[0].id == untitled.id,"corrupt neighbor does not block valid recovery")
        try check(scan.issues.count == 1 && scan.issues[0].url.standardizedFileURL.path == broken.standardizedFileURL.path,"corrupt neighbor reported")
        try check(Data(contentsOf:broken) == brokenBytes,"scan preserves corrupt evidence")
        try FileManager.default.removeItem(at:broken)
        // F202: discarding a scanned list removes exactly the listed snapshots at their scanned revision.
        let discardURL = root.appendingPathComponent("discard-recovery"), discardStore = RecoveryStore(directory:discardURL)
        let keepID = UUID(), dropID = UUID(), advancedID = UUID()
        try discardStore.save(RecoverySnapshot(id:keepID,text:"unlisted",format:FileFormat(),originalURL:nil,revision:1))
        try discardStore.save(RecoverySnapshot(id:dropID,text:"listed",format:FileFormat(),originalURL:nil,revision:4))
        try discardStore.save(RecoverySnapshot(id:advancedID,text:"scanned",format:FileFormat(),originalURL:nil,revision:2))
        let corruptNeighbour = discardURL.appendingPathComponent(UUID().uuidString+".json")
        let corruptNeighbourBytes = Data("{neighbour".utf8); try corruptNeighbourBytes.write(to:corruptNeighbour)
        let scanned = try discardStore.scan()
        try check(scanned.snapshots.count == 3 && scanned.issues.count == 1,"discard fixture scanned")
        let advanced = RecoverySnapshot(id:advancedID,text:"edited after the scan",format:FileFormat(),originalURL:nil,revision:3)
        try discardStore.save(advanced)
        let listed = scanned.snapshots.filter { $0.id != keepID }
        let notDiscarded = discardStore.discard(listed)
        try check(notDiscarded.count == 1 && notDiscarded[0].url.lastPathComponent == advancedID.uuidString+".json","discard reports only the snapshot that advanced after the scan")
        try check(notDiscarded[0].url.standardizedFileURL.path == discardStore.fileURL(for:advancedID).standardizedFileURL.path && notDiscarded[0].message == RecoveryError.staleRevision.localizedDescription,"discard failure names the file and the reason")
        let afterDiscard = try discardStore.scan()
        try check(Set(afterDiscard.snapshots.map(\.id)) == [keepID,advancedID],"discard removes exactly the listed unchanged snapshot")
        try check(discardStore.load(id:advancedID) == advanced && discardStore.load(id:keepID).text == "unlisted","discard keeps newer and unlisted snapshots intact")
        try check(Data(contentsOf:corruptNeighbour) == corruptNeighbourBytes && afterDiscard.issues.count == 1,"discard leaves a corrupt neighbour byte-identical")
        try check(discardStore.discard([]).isEmpty && discardStore.discard(scanned.snapshots.filter { $0.id == dropID }).isEmpty,"discarding nothing or an already removed snapshot is not an error")
        // F202: escalation policy for repeated recovery failures.
        var tracker = RecoveryFailureTracker()
        try check(!tracker.isFailing && !tracker.recordFailure(sessionAlreadyNotified:false) && tracker.isFailing,"one recovery failure does not escalate")
        try check(tracker.recordFailure(sessionAlreadyNotified:false),"second consecutive recovery failure escalates")
        try check(!tracker.recordFailure(sessionAlreadyNotified:true) && tracker.consecutiveFailures == 3,"escalation happens once per session")
        tracker.recordSuccess()
        try check(!tracker.isFailing && !tracker.recordFailure(sessionAlreadyNotified:false),"a successful write resets the failure count")
        // F126: line-ending detection uses the first line break only.
        try check(LineEnding.detect(in:"") == .lf && LineEnding.detect(in:"no break") == .lf,"text without a line break inserts LF")
        try check(LineEnding.detect(in:"a\r\nb\n") == .crlf && LineEnding.detect(in:"a\nb\r\n") == .lf && LineEnding.detect(in:"a\rb\n") == .cr,"first line break decides the insertion ending")
        try check(LineEnding.detect(in:"a\r") == .cr && LineEnding.detect(in:"\r\n") == .crlf && LineEnding.detect(in:"\r\r\n") == .cr && LineEnding.detect(in:"é\u{2028}\r\n") == .crlf,"trailing CR, leading CRLF and non-ASCII text detected exactly")
        // A non-directory path simulates a deterministic storage failure without root/ACL assumptions.
        let denied = RecoveryStore(directory:original)
        rejects("non-directory storage write") { try denied.save(first) }
        try check(Data(contentsOf:original) == originalBytes,"failed save preserves original")
        let crashDirectory = root.appendingPathComponent("crash-recovery")
        let crashID = UUID()
        let child = Process()
        child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments = ["--crash-write",crashDirectory.path,original.path,crashID.uuidString]
        try child.run(); child.waitUntilExit()
        try check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,"actual SIGKILL observed")
        let restored = try RecoveryStore(directory:crashDirectory).loadAll()
        try check(restored.count == 2,"named and untitled survive killed process")
        try check(restored.first(where: { $0.id == crashID })?.text == "named after crash\0😀","named exact recovery after crash")
        try check(restored.first(where: { $0.originalURL == nil })?.text == "untitled after crash","untitled exact recovery after crash")
        try check(Data(contentsOf:original) == originalBytes,"forced crash leaves original unchanged")
        let writer=RecoveryWriter(),entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        let eventsLock=NSLock();var events:[String]=[]
        func record(_ event:String) {eventsLock.lock();events.append(event);eventsLock.unlock()}
        writer.submit {entered.signal();release.wait();record("active")}
        try check(entered.wait(timeout:.now()+2) == .success,"background recovery starts without blocking caller")
        writer.submit {record("superseded")};writer.submit {record("latest")}
        release.signal();writer.finish {record("cleanup")}
        try check(events == ["active","latest","cleanup"],"recovery coalesces pending work and orders cleanup after writes")
        print("PASS FileChecks: \(checks) assertions; codec and isolated recovery")
    }
}
