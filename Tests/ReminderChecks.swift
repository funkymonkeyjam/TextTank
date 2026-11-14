// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@MainActor final class FakeReminderStore: ReminderStore {
    var permission: ReminderPermission = .authorized
    var permissionRequests = 0
    var lists = [ReminderDestination(id:"a",title:"Shopping",source:"Local",writable:true),
                 ReminderDestination(id:"b",title:"Shopping",source:"Work",writable:true),
                 ReminderDestination(id:"locked",title:"Archive",source:"Local",writable:false)]
    var saves: [(String,String)] = []
    var failAt: [Int: Error] = [:]
    var beforeSave: ((Int)->Void)?
    func requestAccess() async throws { permissionRequests += 1; permission = .authorized }
    func destinations() throws -> [ReminderDestination] { lists }
    func save(title:String,destinationID:String) throws -> String {
        let index = saves.count
        beforeSave?(index)
        guard permission == .authorized else { throw ReminderConnectorError.knownFailure("revoked") }
        guard lists.contains(where: {$0.id == destinationID && $0.writable}) else { throw ReminderConnectorError.knownFailure("deleted") }
        saves.append((title,destinationID))
        if let error = failAt[index] { throw error }
        return "fake-\(saves.count)"
    }
}

@main struct ReminderChecks {
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool,_ label:String) throws {
        guard try condition() else { fatalError("FAILED: \(label)") }; assertions += 1
    }
    @MainActor static func rejects(_ label:String,_ work:() async throws -> Void) async {
        do { try await work(); fatalError("FAILED expected rejection: \(label)") } catch { assertions += 1 }
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--crash-export" {
            let fake = FakeReminderStore()
            fake.beforeSave = { _ in kill(getpid(), SIGKILL) }
            let connector = RemindersConnector(storageURL:URL(fileURLWithPath:CommandLine.arguments[2]),store:fake)
            _ = try await connector.export(rows:["crash item"],destinationID:"a",batchID:UUID(uuidString:CommandLine.arguments[3])!)
            fatalError("crash did not occur")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextTankReminderChecks-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let fake = FakeReminderStore()
        let connector = RemindersConnector(storageURL:root.appendingPathComponent("journal"),store:fake)
        try check(fake.permissionRequests == 0 && fake.saves.isEmpty,"construction has no side effects")
        let lists = try connector.destinations()
        try check(lists[0].title == lists[1].title && lists[0].source != lists[1].source && lists[0].id != lists[1].id,"duplicate names distinguished")
        await rejects("read-only") { _ = try await connector.export(rows:["a"],destinationID:"locked",batchID:UUID()) }
        await rejects("deleted") { _ = try await connector.export(rows:["a"],destinationID:"missing",batchID:UUID()) }
        fake.permission = .denied
        await rejects("denied") { _ = try await connector.export(rows:["a"],destinationID:"a",batchID:UUID()) }
        try check(fake.saves.isEmpty && fake.permissionRequests == 0,"denied does not auto request")
        try await connector.requestAccess(); try check(fake.permissionRequests == 1,"explicit request only")
        let id = UUID(), rows = ["2 eggs","½ cup flour","2 eggs"]
        let run = try await connector.export(rows:rows,destinationID:"b",batchID:id)
        try check(run.rows.map(\.title) == rows && run.rows.allSatisfy {$0.status == .confirmed},"quantities duplicates exact")
        try check(fake.saves.allSatisfy {$0.1 == "b"},"identifier chooses list")
        _ = try await connector.export(rows:rows,destinationID:"b",batchID:id)
        try check(fake.saves.count == 3,"double invocation no duplicates")
        let journalDirectory = root.appendingPathComponent("journal")
        let directoryMode = (try FileManager.default.attributesOfItem(atPath:journalDirectory.path)[.posixPermissions] as! NSNumber).intValue
        let journalMode = (try FileManager.default.attributesOfItem(atPath:journalDirectory.appendingPathComponent(id.uuidString+".json").path)[.posixPermissions] as! NSNumber).intValue
        try check(directoryMode == 0o700 && journalMode == 0o600,"journal and directory private permissions")
        let restarted = RemindersConnector(storageURL:root.appendingPathComponent("journal"),store:fake)
        _ = try await restarted.export(rows:rows,destinationID:"b",batchID:id,retryFailed:true)
        try check(fake.saves.count == 3,"restart retry skips confirmed")
        await rejects("batch mismatch") { _ = try await connector.export(rows:["different"],destinationID:"b",batchID:id) }
        try check(fake.saves.count == 3,"mismatch writes nothing")

        let partialFake = FakeReminderStore()
        partialFake.failAt = [1:ReminderConnectorError.knownFailure("offline before write"),2:ReminderConnectorError.uncertain("outcome unknown")]
        let partialDirectory = root.appendingPathComponent("partial")
        let partial = RemindersConnector(storageURL:partialDirectory,store:partialFake)
        let partialID = UUID()
        let first = try await partial.export(rows:["one","two","three"],destinationID:"a",batchID:partialID)
        try check(first.rows.map(\.status) == [.confirmed,.failed,.uncertain],"per-item outcomes")
        _ = try await partial.export(rows:["one","two","three"],destinationID:"a",batchID:partialID)
        try check(partialFake.saves.count == 3,"ordinary retry skips failures and uncertainty")
        let retry = try await partial.export(rows:["one","two","three"],destinationID:"a",batchID:partialID,retryFailed:true)
        try check(partialFake.saves.count == 4 && retry.rows.map(\.status) == [.confirmed,.confirmed,.uncertain],"explicit retry only known failures")
        try check(try partial.storedBatches().first?.rows[2].status == .uncertain,"uncertainty durable")

        // Observe on-disk barrier from inside fake external side effect.
        let barrierFake = FakeReminderStore(), barrierID = UUID(), barrierDirectory = root.appendingPathComponent("barrier")
        let barrier = RemindersConnector(storageURL:barrierDirectory,store:barrierFake)
        barrierFake.beforeSave = { _ in
            let bytes = try! Data(contentsOf:barrierDirectory.appendingPathComponent(barrierID.uuidString+".json"))
            let batch = try! JSONDecoder().decode(ReminderBatch.self,from:bytes)
            precondition(batch.rows[0].status == .uncertain)
        }
        _ = try await barrier.export(rows:["proof"],destinationID:"a",batchID:barrierID)
        try check(barrierFake.saves.count == 1,"uncertainty persisted before external write")
        let badPath = barrierDirectory.appendingPathComponent(barrierID.uuidString+".json")
        var bad = try JSONDecoder().decode(ReminderBatch.self,from:Data(contentsOf:badPath)); bad.schemaVersion = 999
        let badBytes = try JSONEncoder().encode(bad); try badBytes.write(to:badPath)
        await rejects("unknown journal version") { _ = try await barrier.export(rows:["proof"],destinationID:"a",batchID:barrierID) }
        try check(Data(contentsOf:badPath) == badBytes && barrierFake.saves.count == 1,"unknown journal untouched")
        try Data("{partial".utf8).write(to:badPath)
        await rejects("corrupt journal") { _ = try await barrier.export(rows:["proof"],destinationID:"a",batchID:barrierID) }
        try check(barrierFake.saves.count == 1,"corrupt journal no resend")

        let revokedFake = FakeReminderStore()
        revokedFake.beforeSave = { index in if index == 1 { revokedFake.permission = .denied } }
        let revoked = RemindersConnector(storageURL:root.appendingPathComponent("revoked"),store:revokedFake)
        let revokedRun = try await revoked.export(rows:["one","two","three"],destinationID:"a",batchID:UUID())
        try check(revokedRun.rows.map(\.status) == [.confirmed,.failed,.failed],"access revoked mid-batch")

        // Competing connectors share a lock across the async yield boundary.
        let shared = root.appendingPathComponent("concurrent"), concurrentFake = FakeReminderStore(), concurrentID = UUID()
        let a = RemindersConnector(storageURL:shared,store:concurrentFake), b = RemindersConnector(storageURL:shared,store:concurrentFake)
        let contents = (0..<20).map { "row \($0)" }
        let taskA = Task { @MainActor in try await a.export(rows:contents,destinationID:"a",batchID:concurrentID) }
        let taskB = Task { @MainActor in try await b.export(rows:contents,destinationID:"a",batchID:concurrentID) }
        let results = await [taskA.result,taskB.result]
        try check(results.contains { if case .success = $0 { return true }; return false },"one concurrent invocation succeeds")
        try check(concurrentFake.saves.count == 20,"concurrent invocations never duplicate")
        _ = try await b.export(rows:contents,destinationID:"a",batchID:concurrentID)
        try check(concurrentFake.saves.count == 20,"retry after lock contention safe")
        let cancelFake = FakeReminderStore(), cancelID = UUID()
        let cancelConnector = RemindersConnector(storageURL:root.appendingPathComponent("cancelled"),store:cancelFake)
        var cancelTask: Task<ReminderBatch,Error>!
        cancelFake.beforeSave = { _ in cancelTask.cancel() }
        cancelTask = Task { @MainActor in try await cancelConnector.export(rows:["first","second","third"],destinationID:"a",batchID:cancelID) }
        let cancelled = try await cancelTask.value
        try check(cancelFake.saves.count == 1 && cancelled.rows.map(\.status) == [.confirmed,.pending,.pending],"cancellation retains unsent rows")

        let failDirectory = root.appendingPathComponent("failed-journal"), retainedDirectory = root.appendingPathComponent("retained-journal")
        let diskFake = FakeReminderStore(), diskID = UUID()
        let diskConnector = RemindersConnector(storageURL:failDirectory,store:diskFake)
        diskFake.beforeSave = { _ in
            try! FileManager.default.moveItem(at:failDirectory,to:retainedDirectory)
            try! Data("blocked path".utf8).write(to:failDirectory)
        }
        await rejects("post-write journal failure") { _ = try await diskConnector.export(rows:["sent item"],destinationID:"a",batchID:diskID) }
        try check(diskFake.saves.count == 1,"external write occurred before journal failure")
        try FileManager.default.removeItem(at:failDirectory)
        try FileManager.default.moveItem(at:retainedDirectory,to:failDirectory)
        diskFake.beforeSave = nil
        let uncertain = try await diskConnector.export(rows:["sent item"],destinationID:"a",batchID:diskID,retryFailed:true)
        try check(diskFake.saves.count == 1 && uncertain.rows[0].status == .uncertain,"journal failure cannot silently duplicate")

        let crashDirectory = root.appendingPathComponent("crash"), crashID = UUID()
        let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0])
        child.arguments = ["--crash-export",crashDirectory.path,crashID.uuidString]
        try child.run(); child.waitUntilExit()
        try check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,"export process actually killed")
        let crashFake = FakeReminderStore(), crashConnector = RemindersConnector(storageURL:crashDirectory,store:crashFake)
        let crashRun = try await crashConnector.export(rows:["crash item"],destinationID:"a",batchID:crashID,retryFailed:true)
        try check(crashRun.rows[0].status == .uncertain && crashFake.saves.isEmpty,"crash uncertainty never replayed")
        print("PASS ReminderChecks: \(assertions) assertions; injected stores only, no EventKit access")
    }
}
