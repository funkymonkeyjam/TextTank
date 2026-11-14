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
        try check(store.load(id:id) == first,"exact snapshot reload")
        // Reinstantiate to demonstrate persistence independent of live store instance.
        try check(RecoveryStore(directory:storeURL).load(id:id) == first,"restart reload")
        let second = RecoverySnapshot(id:id,text:"newer",format:FileFormat(),originalURL:original.absoluteString,revision:2)
        try store.save(second)
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
        print("PASS FileChecks: \(checks) assertions; codec and isolated recovery")
    }
}
