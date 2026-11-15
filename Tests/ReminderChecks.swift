// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

@MainActor final class FakeReminderStore: ReminderStore {
    var permission: ReminderPermission = .authorized
    var permissionRequests = 0
    var lists = [
        ReminderDestination(id: "a", title: "Shopping", source: "Local", writable: true),
        ReminderDestination(id: "b", title: "Shopping", source: "Work", writable: true),
        ReminderDestination(id: "locked", title: "Archive", source: "Local", writable: false)
    ]
    var saves: [(String, String)] = []
    var failAt: [Int: Error] = [:]
    var beforeSave: ((Int) -> Void)?
    func requestAccess() async throws {
        permissionRequests += 1
        permission = .authorized
    }
    func destinations() throws -> [ReminderDestination] { lists }
    func save(title: String, destinationID: String) throws -> String {
        let index = saves.count
        beforeSave?(index)
        guard permission == .authorized else { throw ReminderConnectorError.knownFailure("revoked") }
        guard lists.contains(where: { $0.id == destinationID && $0.writable }) else {
            throw ReminderConnectorError.knownFailure("deleted")
        }
        saves.append((title, destinationID))
        if let error = failAt[index] { throw error }
        return "fake-\(saves.count)"
    }
}

@main struct ReminderChecks {
    @MainActor static func main() async {
        await Checks.run("ReminderChecks") {
            if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--crash-export" {
                let fake = FakeReminderStore()
                fake.beforeSave = { _ in kill(getpid(), SIGKILL) }
                let connector = RemindersConnector(
                    storageURL: URL(fileURLWithPath: CommandLine.arguments[2]), store: fake)
                _ = try await connector.export(
                    rows: ["crash item"], destinationID: "a", batchID: UUID(uuidString: CommandLine.arguments[3])!)
                fatalError("crash did not occur")
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankReminderChecks-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let fake = FakeReminderStore()
            let connector = RemindersConnector(storageURL: root.appendingPathComponent("journal"), store: fake)
            let unavailable: (Error) -> Bool = {
                if case ReminderConnectorError.destinationUnavailable = $0 { return true }
                return false
            }
            let permissionRequired: (Error) -> Bool = {
                if case ReminderConnectorError.permissionRequired = $0 { return true }
                return false
            }
            let invalidBatch: (Error) -> Bool = {
                if case ReminderConnectorError.invalidBatch = $0 { return true }
                return false
            }
            // Shared by the cancellation section and the later resume section.
            let cancelFake = FakeReminderStore(), cancelID = UUID()
            let cancelConnector = RemindersConnector(
                storageURL: root.appendingPathComponent("cancelled"), store: cancelFake)
            await Checks.section("permissions and idempotent export") {
                check(fake.permissionRequests == 0 && fake.saves.isEmpty, "construction has no side effects")
                let lists = try connector.destinations()
                check(
                    lists[0].title == lists[1].title && lists[0].source != lists[1].source
                        && lists[0].id != lists[1].id, "duplicate names distinguished")
                await rejects("read-only", where: unavailable) {
                    _ = try await connector.export(rows: ["a"], destinationID: "locked", batchID: UUID())
                }
                await rejects("deleted", where: unavailable) {
                    _ = try await connector.export(rows: ["a"], destinationID: "missing", batchID: UUID())
                }
                fake.permission = .denied
                await rejects("denied", where: permissionRequired) {
                    _ = try await connector.export(rows: ["a"], destinationID: "a", batchID: UUID())
                }
                check(fake.saves.isEmpty && fake.permissionRequests == 0, "denied does not auto request")
                await rejects("denied access does not repeatedly request system consent", where: permissionRequired) {
                    try await connector.requestAccess()
                }
                fake.permission = .notDetermined
                try await connector.requestAccess()
                check(fake.permissionRequests == 1, "explicit first-use request only")
                try await connector.requestAccess()
                check(fake.permissionRequests == 1, "authorized access does not request again")
                let id = UUID(), rows = ["2 eggs", "½ cup flour", "2 eggs"]
                let run = try await connector.export(rows: rows, destinationID: "b", batchID: id)
                check(
                    run.rows.map(\.title) == rows && run.rows.allSatisfy { $0.status == .confirmed },
                    "quantities duplicates exact")
                check(fake.saves.allSatisfy { $0.1 == "b" }, "identifier chooses list")
                _ = try await connector.export(rows: rows, destinationID: "b", batchID: id)
                check(fake.saves.count == 3, "double invocation no duplicates")
                let journalDirectory = root.appendingPathComponent("journal")
                let directoryMode =
                    (try FileManager.default.attributesOfItem(atPath: journalDirectory.path)[.posixPermissions]
                    as! NSNumber).intValue
                let journalMode =
                    (try FileManager.default.attributesOfItem(
                        atPath: journalDirectory.appendingPathComponent(id.uuidString + ".json").path)[
                        .posixPermissions] as! NSNumber).intValue
                check(directoryMode == 0o700 && journalMode == 0o600, "journal and directory private permissions")
                let restarted = RemindersConnector(storageURL: root.appendingPathComponent("journal"), store: fake)
                _ = try await restarted.export(rows: rows, destinationID: "b", batchID: id, retryFailed: true)
                check(fake.saves.count == 3, "restart retry skips confirmed")
                await rejects("batch mismatch", where: invalidBatch) {
                    _ = try await connector.export(rows: ["different"], destinationID: "b", batchID: id)
                }
                check(fake.saves.count == 3, "mismatch writes nothing")

            }
            await Checks.section("per-item outcomes") {
                let partialFake = FakeReminderStore()
                partialFake.failAt = [
                    1: ReminderConnectorError.knownFailure("offline before write"),
                    2: ReminderConnectorError.uncertain("outcome unknown")
                ]
                let partialDirectory = root.appendingPathComponent("partial")
                let partial = RemindersConnector(storageURL: partialDirectory, store: partialFake)
                let partialID = UUID()
                let first = try await partial.export(
                    rows: ["one", "two", "three"], destinationID: "a", batchID: partialID)
                check(first.rows.map(\.status) == [.confirmed, .failed, .uncertain], "per-item outcomes")
                _ = try await partial.export(rows: ["one", "two", "three"], destinationID: "a", batchID: partialID)
                check(partialFake.saves.count == 3, "ordinary retry skips failures and uncertainty")
                let retry = try await partial.export(
                    rows: ["one", "two", "three"], destinationID: "a", batchID: partialID, retryFailed: true)
                check(
                    partialFake.saves.count == 4 && retry.rows.map(\.status) == [.confirmed, .confirmed, .uncertain],
                    "explicit retry only known failures")
                check(try partial.storedBatches().first?.rows[2].status == .uncertain, "uncertainty durable")

            }
            await Checks.section("uncertainty barrier and journal integrity") {
                // Observe on-disk barrier from inside fake external side effect.
                let barrierFake = FakeReminderStore(), barrierID = UUID(),
                    barrierDirectory = root.appendingPathComponent("barrier")
                let barrier = RemindersConnector(storageURL: barrierDirectory, store: barrierFake)
                var barrierObserved = false
                barrierFake.beforeSave = { _ in
                    let bytes = try! Data(
                        contentsOf: barrierDirectory.appendingPathComponent(barrierID.uuidString + ".json"))
                    let batch = try! JSONDecoder().decode(ReminderBatch.self, from: bytes)
                    barrierObserved = batch.rows[0].status == .uncertain
                }
                _ = try await barrier.export(rows: ["proof"], destinationID: "a", batchID: barrierID)
                check(barrierObserved && barrierFake.saves.count == 1, "uncertainty persisted before external write")
                let badPath = barrierDirectory.appendingPathComponent(barrierID.uuidString + ".json")
                var bad = try JSONDecoder().decode(ReminderBatch.self, from: Data(contentsOf: badPath))
                bad.schemaVersion = 999
                let badBytes = try JSONEncoder().encode(bad)
                try badBytes.write(to: badPath)
                await rejects("unknown journal version", where: invalidBatch) {
                    _ = try await barrier.export(rows: ["proof"], destinationID: "a", batchID: barrierID)
                }
                check(
                    try Data(contentsOf: badPath) == badBytes && barrierFake.saves.count == 1,
                    "unknown journal untouched")
                try Data("{partial".utf8).write(to: badPath)
                await rejects("corrupt journal", where: { $0 is DecodingError }) {
                    _ = try await barrier.export(rows: ["proof"], destinationID: "a", batchID: barrierID)
                }
                check(barrierFake.saves.count == 1, "corrupt journal no resend")

            }
            await Checks.section("access revoked mid-batch") {
                let revokedFake = FakeReminderStore()
                revokedFake.beforeSave = { index in if index == 1 { revokedFake.permission = .denied } }
                let revoked = RemindersConnector(storageURL: root.appendingPathComponent("revoked"), store: revokedFake)
                let revokedRun = try await revoked.export(
                    rows: ["one", "two", "three"], destinationID: "a", batchID: UUID())
                check(revokedRun.rows.map(\.status) == [.confirmed, .failed, .failed], "access revoked mid-batch")

            }
            await Checks.section("competing connectors") {
                // Competing connectors share a lock across the async yield boundary.
                let shared = root.appendingPathComponent("concurrent"), concurrentFake = FakeReminderStore(),
                    concurrentID = UUID()
                let a = RemindersConnector(storageURL: shared, store: concurrentFake),
                    b = RemindersConnector(storageURL: shared, store: concurrentFake)
                let contents = (0..<20).map { "row \($0)" }
                let taskA = Task { @MainActor in
                    try await a.export(rows: contents, destinationID: "a", batchID: concurrentID)
                }
                let taskB = Task { @MainActor in
                    try await b.export(rows: contents, destinationID: "a", batchID: concurrentID)
                }
                let results = await [taskA.result, taskB.result]
                check(
                    results.contains {
                        if case .success = $0 { return true }
                        return false
                    }, "one concurrent invocation succeeds")
                check(concurrentFake.saves.count == 20, "concurrent invocations never duplicate")
                _ = try await b.export(rows: contents, destinationID: "a", batchID: concurrentID)
                check(concurrentFake.saves.count == 20, "retry after lock contention safe")
            }
            await Checks.section("cancellation") {
                var cancelTask: Task<ReminderBatch, Error>!
                cancelFake.beforeSave = { _ in cancelTask.cancel() }
                cancelTask = Task { @MainActor in
                    try await cancelConnector.export(
                        rows: ["first", "second", "third"], destinationID: "a", batchID: cancelID)
                }
                let cancelled = try await cancelTask.value
                check(
                    cancelFake.saves.count == 1 && cancelled.rows.map(\.status) == [.confirmed, .pending, .pending],
                    "cancellation retains unsent rows")

            }
            await Checks.section("journal failure after an external write") {
                let failDirectory = root.appendingPathComponent("failed-journal"),
                    retainedDirectory = root.appendingPathComponent("retained-journal")
                let diskFake = FakeReminderStore(), diskID = UUID()
                let diskConnector = RemindersConnector(storageURL: failDirectory, store: diskFake)
                diskFake.beforeSave = { _ in
                    try! FileManager.default.moveItem(at: failDirectory, to: retainedDirectory)
                    try! Data("blocked path".utf8).write(to: failDirectory)
                }
                await rejects("post-write journal failure") {
                    _ = try await diskConnector.export(rows: ["sent item"], destinationID: "a", batchID: diskID)
                }
                check(diskFake.saves.count == 1, "external write occurred before journal failure")
                try FileManager.default.removeItem(at: failDirectory)
                try FileManager.default.moveItem(at: retainedDirectory, to: failDirectory)
                diskFake.beforeSave = nil
                let uncertain = try await diskConnector.export(
                    rows: ["sent item"], destinationID: "a", batchID: diskID, retryFailed: true)
                check(
                    diskFake.saves.count == 1 && uncertain.rows[0].status == .uncertain,
                    "journal failure cannot silently duplicate")

            }
            await Checks.section("killed export process") {
                let crashDirectory = root.appendingPathComponent("crash"), crashID = UUID()
                let child = Process()
                child.executableURL = Checks.executable
                child.arguments = ["--crash-export", crashDirectory.path, crashID.uuidString]
                try child.run()
                child.waitUntilExit()
                check(
                    child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,
                    "export process actually killed")
                let crashFake = FakeReminderStore(),
                    crashConnector = RemindersConnector(storageURL: crashDirectory, store: crashFake)
                let crashRun = try await crashConnector.export(
                    rows: ["crash item"], destinationID: "a", batchID: crashID, retryFailed: true)
                check(
                    crashRun.rows[0].status == .uncertain && crashFake.saves.isEmpty, "crash uncertainty never replayed"
                )
            }
            await Checks.section("destination identity and resume") {
                // Destination identity survives a rename/account label change; deletion/read-only never redirect.
                let movedFake = FakeReminderStore(), movedID = UUID()
                let movedConnector = RemindersConnector(
                    storageURL: root.appendingPathComponent("moved"), store: movedFake)
                movedFake.beforeSave = { index in if index == 1 { movedFake.lists = [] } }
                let deleted = try await movedConnector.export(
                    rows: ["first", "second", "third"], destinationID: "a", batchID: movedID)
                check(
                    deleted.rows.map(\.status) == [.confirmed, .failed, .failed],
                    "deleted list mid-batch leaves exact per-row failures")
                movedFake.beforeSave = nil
                movedFake.lists = [
                    ReminderDestination(id: "a", title: "Renamed", source: "Moved account label", writable: true)
                ]
                var progress: [Int] = []
                let resumed = try await movedConnector.export(
                    rows: ["first", "second", "third"], destinationID: "a", batchID: movedID, retryFailed: true,
                    progress: { done, _ in progress.append(done) })
                check(
                    resumed.rows.allSatisfy { $0.status == .confirmed } && movedFake.saves.count == 3,
                    "same destination ID resumes after rename without duplicate confirmed item")
                check(progress.last == 3, "connector reports completion progress")
                let pendingResume = try await cancelConnector.export(
                    rows: ["first", "second", "third"], destinationID: "a", batchID: cancelID)
                check(
                    pendingResume.rows.allSatisfy { $0.status == .confirmed } && cancelFake.saves.count == 3,
                    "cancelled pending rows resume same batch without duplicating first")
            }
            await Checks.section("batch and journal validation") {
                await rejects("empty batch rejected before external writes", where: invalidBatch) {
                    _ = try await connector.export(rows: [], destinationID: "a", batchID: UUID())
                }
                await rejects("blank row rejected", where: invalidBatch) {
                    _ = try await connector.export(rows: ["  "], destinationID: "a", batchID: UUID())
                }
                let fifoDirectory = root.appendingPathComponent("fifo-journal")
                try FileManager.default.createDirectory(at: fifoDirectory, withIntermediateDirectories: true)
                let fifoID = UUID(), fifoURL = fifoDirectory.appendingPathComponent(UUID().uuidString)
                let journalFIFO = fifoDirectory.appendingPathComponent(fifoID.uuidString + ".json")
                try require(mkfifo(journalFIFO.path, 0o600) == 0, "fixture: journal FIFO created")
                let fifoConnector = RemindersConnector(storageURL: fifoDirectory, store: FakeReminderStore())
                let fifoStart = ProcessInfo.processInfo.systemUptime
                rejects("FIFO journal rejects without read hang", where: invalidBatch) {
                    _ = try fifoConnector.storedBatches()
                }
                check(
                    ProcessInfo.processInfo.systemUptime - fifoStart < 10,
                    "journal FIFO rejection returns well inside the hang guard")
                _ = fifoURL
            }
            await Checks.section("oversized batch") {
                let oversizedDirectory = root.appendingPathComponent("oversized-batch")
                let oversizedFake = FakeReminderStore(), oversizedID = UUID()
                let oversizedConnector = RemindersConnector(storageURL: oversizedDirectory, store: oversizedFake)
                let oversizedRows = Array(repeating: String(repeating: "x", count: 1048576), count: 33)
                await rejects("aggregate journal ceiling rejects before first save", where: invalidBatch) {
                    _ = try await oversizedConnector.export(
                        rows: oversizedRows, destinationID: "a", batchID: oversizedID)
                }
                check(oversizedFake.saves.isEmpty, "oversized batch makes no external writes")
                check(try oversizedConnector.storedBatches().isEmpty, "oversized batch leaves no poisoned journal")
                let afterOversize = try await oversizedConnector.export(
                    rows: ["2 eggs"], destinationID: "a", batchID: UUID())
                check(afterOversize.rows.first?.status == .confirmed, "ordinary export works after oversized rejection")
            }
            let journalFailed: (Error) -> ReminderBatch? = {
                if case ReminderConnectorError.journalFailed(let batch, _) = $0 { return batch }
                return nil
            }
            func failure(_ work: () async throws -> Void) async -> Error? {
                do {
                    try await work()
                    return nil
                } catch { return error }
            }
            func journalBytes(_ directory: URL, _ id: UUID) throws -> Data {
                try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".json"))
            }
            await Checks.section("journal failure carries the per-item results") {
                // The journal directory is swapped for a plain file, then put back.
                func scenario(_ name: String) -> (directory: URL, block: () -> Void, restore: () throws -> Void) {
                    let directory = root.appendingPathComponent(name),
                        retained = root.appendingPathComponent(name + "-retained")
                    return (
                        directory,
                        {
                            try! FileManager.default.moveItem(at: directory, to: retained)
                            try! Data("blocked path".utf8).write(to: directory)
                        },
                        {
                            try FileManager.default.removeItem(at: directory)
                            try FileManager.default.moveItem(at: retained, to: directory)
                        }
                    )
                }
                let single = scenario("carried-single"), singleFake = FakeReminderStore(), singleID = UUID()
                let singleConnector = RemindersConnector(storageURL: single.directory, store: singleFake)
                singleFake.beforeSave = { _ in single.block() }
                let singleError = await failure {
                    _ = try await singleConnector.export(rows: ["sent item"], destinationID: "a", batchID: singleID)
                }
                let singleBatch = singleError.flatMap(journalFailed)
                check(
                    singleBatch?.id == singleID && singleBatch?.rows.map(\.status) == [.confirmed]
                        && !(singleBatch?.rows[0].reminderID ?? "").isEmpty && singleFake.saves.count == 1,
                    "post-save journal failure carries the confirmed row and its reminder identifier")
                check(
                    (singleError?.localizedDescription ?? "").contains("1 of 1 items were confirmed"),
                    "journal failure has a description of its own for callers that only show the error")
                try single.restore()

                let multi = scenario("carried-multi"), multiFake = FakeReminderStore(), multiID = UUID()
                let multiConnector = RemindersConnector(storageURL: multi.directory, store: multiFake)
                multiFake.beforeSave = { index in if index == 1 { multi.block() } }
                let multiError = await failure {
                    _ = try await multiConnector.export(
                        rows: ["one", "two", "three"], destinationID: "a", batchID: multiID)
                }
                check(
                    multiError.flatMap(journalFailed)?.rows.map(\.status) == [.confirmed, .confirmed, .pending]
                        && multiFake.saves.count == 2,
                    "journal failure on the second of three rows carries confirmed, confirmed, pending")
                try multi.restore()
                multiFake.beforeSave = nil
                check(
                    try multiConnector.storedBatches().first?.rows.map(\.status) == [.confirmed, .uncertain, .pending],
                    "disk keeps the row whose outcome could not be written as uncertain")
                let multiResumed = try await multiConnector.export(
                    rows: ["one", "two", "three"], destinationID: "a", batchID: multiID)
                check(
                    multiFake.saves.count == 3 && multiFake.saves.last?.0 == "three"
                        && multiResumed.rows.map(\.status) == [.confirmed, .uncertain, .confirmed],
                    "resume after a journal failure sends only the row that was never attempted")

                let barrier = scenario("carried-barrier"), barrierFake = FakeReminderStore(), barrierID = UUID()
                let barrierConnector = RemindersConnector(storageURL: barrier.directory, store: barrierFake)
                let barrierError = await failure {
                    _ = try await barrierConnector.export(
                        rows: ["one", "two", "three"], destinationID: "a", batchID: barrierID,
                        progress: { done, _ in if done == 1 { barrier.block() } })
                }
                check(
                    barrierError.flatMap(journalFailed)?.rows.map(\.status) == [.confirmed, .pending, .pending]
                        && barrierError.flatMap(journalFailed)?.rows[1].message == nil && barrierFake.saves.count == 1,
                    "barrier write failure carries the unsent row as pending and makes no save for it")
                try barrier.restore()
                check(
                    try barrierConnector.storedBatches().first?.rows.map(\.status) == [.confirmed, .pending, .pending],
                    "disk agrees after a barrier write failure")
                _ = try await barrierConnector.export(
                    rows: ["one", "two", "three"], destinationID: "a", batchID: barrierID)
                check(barrierFake.saves.count == 3, "rows after a barrier write failure remain resumable")

                let early = scenario("carried-early"), earlyFake = FakeReminderStore()
                let earlyConnector = RemindersConnector(storageURL: early.directory, store: earlyFake)
                let earlyError = await failure {
                    _ = try await earlyConnector.export(
                        rows: ["one", "two"], destinationID: "a", batchID: UUID(),
                        progress: { done, _ in if done == 0 { early.block() } })
                }
                check(
                    earlyError != nil && earlyError.flatMap(journalFailed) == nil && earlyFake.saves.isEmpty,
                    "a journal failure before anything was sent is a plain error with no save")
                try early.restore()
            }
            await Checks.section("tolerant journal listing") {
                let directory = root.appendingPathComponent("scan"), scanFake = FakeReminderStore()
                let scanConnector = RemindersConnector(storageURL: directory, store: scanFake)
                let validID = UUID()
                _ = try await scanConnector.export(rows: ["milk", "tea"], destinationID: "a", batchID: validID)
                let partialURL = directory.appendingPathComponent(UUID().uuidString + ".json"), futureID = UUID()
                let futureURL = directory.appendingPathComponent(futureID.uuidString + ".json"),
                    notesURL = directory.appendingPathComponent("notes.json")
                try Data("{partial".utf8).write(to: partialURL)
                var future = ReminderBatch(
                    id: futureID, destinationID: "a", destinationTitle: "Shopping", destinationSource: "Local",
                    rows: [ReminderRow(id: UUID(), title: "milk")], createdAt: Date())
                future.schemaVersion = 999
                try JSONEncoder().encode(future).write(to: futureURL)
                try Data("{\"note\":\"not a journal\"}".utf8).write(to: notesURL)
                let bad = [partialURL, futureURL, notesURL]
                let before = try bad.map { try Data(contentsOf: $0) }
                let scan = try scanConnector.scanBatches()
                check(
                    scan.batches.map(\.id) == [validID] && scan.batches.first?.rows.map(\.title) == ["milk", "tea"],
                    "scan returns exactly the one readable batch")
                check(
                    scan.issues.count == 3
                        && Set(scan.issues.map(\.url.lastPathComponent)) == Set(bad.map(\.lastPathComponent))
                        && scan.issues.allSatisfy { !$0.message.isEmpty },
                    "scan reports the three unreadable files by name")
                rejects("strict listing still fails on a directory with an unreadable journal") {
                    _ = try scanConnector.storedBatches()
                }
                let savesBefore = scanFake.saves.count
                let fresh = try await scanConnector.export(
                    rows: ["bread", "jam", "salt"], destinationID: "a", batchID: UUID())
                check(
                    fresh.rows.allSatisfy { $0.status == .confirmed } && scanFake.saves.count == savesBefore + 3,
                    "a new export succeeds beside unreadable journals")
                check(try scanConnector.scanBatches().batches.count == 2, "scan lists the new batch as well")
                check(
                    try bad.map { try Data(contentsOf: $0) } == before,
                    "unreadable journals are byte-identical after scan and export")
                let fifoDirectory = root.appendingPathComponent("scan-fifo")
                try FileManager.default.createDirectory(at: fifoDirectory, withIntermediateDirectories: true)
                let fifo = fifoDirectory.appendingPathComponent(UUID().uuidString + ".json")
                try require(mkfifo(fifo.path, 0o600) == 0, "fixture: scan FIFO created")
                let fifoConnector = RemindersConnector(storageURL: fifoDirectory, store: FakeReminderStore())
                let start = ProcessInfo.processInfo.systemUptime
                let fifoScan = try fifoConnector.scanBatches()
                check(
                    fifoScan.batches.isEmpty && fifoScan.issues.map(\.url.lastPathComponent) == [fifo.lastPathComponent]
                        && ProcessInfo.processInfo.systemUptime - start < 1,
                    "a FIFO journal becomes a scan issue in under one second")
                let file = root.appendingPathComponent("scan-not-a-directory")
                try Data("file".utf8).write(to: file)
                rejects("a journal path that is not a directory still fails the scan", where: invalidBatch) {
                    _ = try RemindersConnector(storageURL: file, store: FakeReminderStore()).scanBatches()
                }
                let missing = try RemindersConnector(
                    storageURL: root.appendingPathComponent("scan-missing"), store: FakeReminderStore()
                ).scanBatches()
                check(
                    missing.batches.isEmpty && missing.issues.isEmpty
                        && !FileManager.default.fileExists(atPath: root.appendingPathComponent("scan-missing").path),
                    "scanning a missing journal directory is empty and creates nothing")
            }
            await Checks.section("clearing confirmed history") {
                let directory = root.appendingPathComponent("clear"), clearFake = FakeReminderStore()
                let clearConnector = RemindersConnector(storageURL: directory, store: clearFake)
                let confirmedID = UUID(), keptID = UUID(), uncertainID = UUID(), failedID = UUID(), pendingID = UUID()
                _ = try await clearConnector.export(rows: ["a1", "a2"], destinationID: "a", batchID: confirmedID)
                _ = try await clearConnector.export(rows: ["k1"], destinationID: "a", batchID: keptID)
                clearFake.failAt = [clearFake.saves.count + 1: ReminderConnectorError.uncertain("outcome unknown")]
                _ = try await clearConnector.export(rows: ["u1", "u2"], destinationID: "a", batchID: uncertainID)
                clearFake.failAt = [clearFake.saves.count: ReminderConnectorError.knownFailure("offline")]
                _ = try await clearConnector.export(rows: ["f1", "f2"], destinationID: "a", batchID: failedID)
                clearFake.failAt = [:]
                var pendingTask: Task<ReminderBatch, Error>!
                clearFake.beforeSave = { _ in pendingTask.cancel() }
                pendingTask = Task { @MainActor in
                    try await clearConnector.export(rows: ["p1", "p2"], destinationID: "a", batchID: pendingID)
                }
                let pendingRun = try await pendingTask.value
                try require(pendingRun.rows.map(\.status) == [.confirmed, .pending], "fixture: pending batch")
                clearFake.beforeSave = nil
                let unresolved = [uncertainID, failedID, pendingID]
                let unresolvedBytes = try unresolved.map { try journalBytes(directory, $0) }
                let all = [confirmedID, keptID] + unresolved
                let saves = clearFake.saves.count

                let lockDescriptor = open(directory.appendingPathComponent(".export.lock").path, O_RDWR)
                try require(lockDescriptor >= 0 && flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0, "fixture: lock held")
                rejects(
                    "clearing while the export lock is held is refused as busy",
                    where: {
                        if case ReminderConnectorError.busy = $0 { return true }
                        return false
                    }
                ) { _ = try clearConnector.deleteConfirmedBatches(ids: all) }
                check(try clearConnector.storedBatches().count == 5, "a refused clear deletes nothing")
                flock(lockDescriptor, LOCK_UN)
                close(lockDescriptor)

                let removed = try clearConnector.deleteConfirmedBatches(ids: [confirmedID] + unresolved)
                check(
                    removed == [confirmedID]
                        && !FileManager.default.fileExists(
                            atPath: directory.appendingPathComponent(confirmedID.uuidString + ".json").path),
                    "clearing removes the fully confirmed batch that was named")
                check(
                    try Set(clearConnector.storedBatches().map(\.id)) == Set([keptID] + unresolved),
                    "the cleared batch is no longer listed; a confirmed batch that was not named stays")
                check(
                    try unresolved.map { try journalBytes(directory, $0) } == unresolvedBytes,
                    "batches with a pending, failed or uncertain row survive the clear byte for byte")
                check(clearFake.saves.count == saves, "clearing makes no external writes")
                let resumed = try await clearConnector.export(
                    rows: ["p1", "p2"], destinationID: "a", batchID: pendingID)
                check(
                    resumed.rows.map(\.status) == [.confirmed, .confirmed] && clearFake.saves.count == saves + 1,
                    "a retained pending batch resumes under the same batch ID without duplicate saves")

                let brokenID = UUID(), brokenURL = directory.appendingPathComponent(brokenID.uuidString + ".json"),
                    notesURL = directory.appendingPathComponent("notes.json")
                try Data("{partial".utf8).write(to: brokenURL)
                try Data("[]".utf8).write(to: notesURL)
                let linkedID = UUID(), linkURL = directory.appendingPathComponent(linkedID.uuidString + ".json"),
                    target = root.appendingPathComponent("clear-link-target.json")
                try FileManager.default.copyItem(
                    at: directory.appendingPathComponent(keptID.uuidString + ".json"), to: target)
                try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: target)
                let second = try clearConnector.deleteConfirmedBatches(ids: [brokenID, linkedID, UUID(), keptID])
                check(second == [keptID], "an unreadable, linked or unknown batch is skipped; the confirmed one goes")
                check(
                    try Data(contentsOf: brokenURL) == Data("{partial".utf8)
                        && (try Data(contentsOf: notesURL)) == Data("[]".utf8)
                        && FileManager.default.fileExists(atPath: target.path)
                        && (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) != nil,
                    "an undecodable journal, a stray file and a symbolic link are left untouched by the clear")
                let none = try RemindersConnector(
                    storageURL: root.appendingPathComponent("clear-missing"), store: FakeReminderStore()
                ).deleteConfirmedBatches(ids: [UUID()])
                check(
                    none.isEmpty
                        && !FileManager.default.fileExists(atPath: root.appendingPathComponent("clear-missing").path),
                    "clearing with no journal directory removes nothing and creates nothing")
            }
            await Checks.section("journal layout") {
                let titles = [
                    "say \"hi\" \\ there", "line one\nline two\ttabbed", "½ cup – crème fraîche 🍋", "a\u{2028}b\u{0}c",
                    "</script>", String(repeating: "long ", count: 2000)
                ]
                var batch = ReminderBatch(
                    id: UUID(), destinationID: "list \"a\"", destinationTitle: "Shop\\ping",
                    destinationSource: "Lo\ncal",
                    rows: titles.map { ReminderRow(id: UUID(), title: $0) },
                    createdAt: Date(timeIntervalSinceReferenceDate: 784_000_000.123456))
                batch.rows[1].status = .confirmed
                batch.rows[1].reminderID = "id \"1\""
                batch.rows[2].status = .failed
                batch.rows[2].message = String(repeating: "m\"", count: 400)
                batch.rows[3].status = .uncertain
                batch.rows[3].message = "check\nit"
                func same(_ a: ReminderBatch, _ b: ReminderBatch) -> Bool {
                    a.schemaVersion == b.schemaVersion && a.id == b.id && a.destinationID == b.destinationID
                        && a.destinationTitle == b.destinationTitle && a.destinationSource == b.destinationSource
                        && a.createdAt == b.createdAt && a.rows.map(\.id) == b.rows.map(\.id)
                        && a.rows.map(\.title) == b.rows.map(\.title) && a.rows.map(\.status) == b.rows.map(\.status)
                        && a.rows.map(\.reminderID) == b.rows.map(\.reminderID)
                        && a.rows.map(\.message) == b.rows.map(\.message)
                }
                let layout = try ReminderJournal.layout(batch)
                check(
                    same(try JSONDecoder().decode(ReminderBatch.self, from: layout.data), batch),
                    "slotted journal decodes to the same batch as the synthesized decoder expects")
                check(
                    same(
                        try JSONDecoder().decode(
                            ReminderBatch.self, from: try ReminderJournal.layout(batch, slotWidth: 0).data), batch),
                    "unpadded journal layout decodes to the same batch")
                check(
                    same(
                        try JSONDecoder().decode(
                            ReminderBatch.self, from: try RemindersConnector.encodedJournal(batch)), batch),
                    "compact journal of earlier builds still decodes to the same batch")
                let many = ReminderBatch(
                    id: UUID(), destinationID: "a", destinationTitle: "Shopping", destinationSource: "Local",
                    rows: (0..<500).map { ReminderRow(id: UUID(), title: String(repeating: "x", count: $0 % 97 + 1)) },
                    createdAt: Date())
                let manyLayout = try ReminderJournal.layout(many)
                let block = ReminderJournal.blockSize
                let manyDecoded = try JSONDecoder().decode(ReminderBatch.self, from: manyLayout.data)
                check(
                    manyLayout.slots.count == 500
                        && manyLayout.slots.allSatisfy {
                            $0.count == ReminderJournal.slotWidth
                                && $0.lowerBound / block == ($0.upperBound - 1) / block
                        }
                        && same(manyDecoded, many),
                    "every row slot has the reserved width and lies inside one storage block")

                // Outcomes that do not fit a slot fall back to a whole-file replacement mid-export.
                let directory = root.appendingPathComponent("layout"), layoutFake = FakeReminderStore(), id = UUID()
                let longUncertain = String(repeating: "u\"\n", count: 2000),
                    longFailure = String(repeating: "f\\", count: 1500)
                layoutFake.failAt = [
                    1: ReminderConnectorError.uncertain(longUncertain),
                    2: ReminderConnectorError.knownFailure(longFailure)
                ]
                let layoutConnector = RemindersConnector(storageURL: directory, store: layoutFake)
                let run = try await layoutConnector.export(rows: titles, destinationID: "a", batchID: id)
                let stored = try requireValue(try layoutConnector.storedBatches().first, "fixture: stored layout batch")
                check(
                    run.rows.map(\.status) == [.confirmed, .uncertain, .failed, .confirmed, .confirmed, .confirmed]
                        && run.rows[1].message == longUncertain && run.rows[2].message == longFailure
                        && same(stored, run),
                    "awkward titles and oversized outcome messages are journalled exactly")
                let mode =
                    (try FileManager.default.attributesOfItem(
                        atPath: directory.appendingPathComponent(id.uuidString + ".json").path)[.posixPermissions]
                    as! NSNumber).intValue
                let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
                    $0.hasSuffix(".pending")
                }
                check(mode == 0o600 && leftovers.isEmpty, "journal stays private and leaves no temporary file")

                // A journal in the compact form earlier builds wrote resumes without resending.
                let oldDirectory = root.appendingPathComponent("layout-compact"), oldFake = FakeReminderStore()
                try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
                var old = ReminderBatch(
                    id: UUID(), destinationID: "a", destinationTitle: "Shopping", destinationSource: "Local",
                    rows: ["done", "unknown", "unsent"].map { ReminderRow(id: UUID(), title: $0) }, createdAt: Date())
                old.rows[0].status = .confirmed
                old.rows[0].reminderID = "earlier-1"
                old.rows[1].status = .uncertain
                try RemindersConnector.encodedJournal(old).write(
                    to: oldDirectory.appendingPathComponent(old.id.uuidString + ".json"))
                let oldConnector = RemindersConnector(storageURL: oldDirectory, store: oldFake)
                let oldRun = try await oldConnector.export(
                    rows: ["done", "unknown", "unsent"], destinationID: "a", batchID: old.id)
                let oldStored = try requireValue(
                    try oldConnector.storedBatches().first, "fixture: stored compact batch")
                check(
                    oldFake.saves.map(\.0) == ["unsent"]
                        && oldRun.rows.map(\.status) == [.confirmed, .uncertain, .confirmed]
                        && oldRun.rows[0].reminderID == "earlier-1" && same(oldStored, oldRun),
                    "a compact journal of an earlier build resumes: only the unsent row is sent and recorded")
            }
            await Checks.section("row cost does not grow with the batch") {
                func inode(_ url: URL) -> UInt64 {
                    var info = stat()
                    return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : 0
                }
                let directory = root.appendingPathComponent("row-cost"), costFake = FakeReminderStore(), id = UUID()
                let url = directory.appendingPathComponent(id.uuidString + ".json")
                var inodes: [UInt64] = [], sizes: [Int] = [], uncertainSeen = 0
                costFake.beforeSave = { index in
                    inodes.append(inode(url))
                    let bytes = try! Data(contentsOf: url)
                    sizes.append(bytes.count)
                    let batch = try! JSONDecoder().decode(ReminderBatch.self, from: bytes)
                    if batch.rows[index].status == .uncertain
                        && batch.rows[..<index].allSatisfy({ $0.status == .confirmed })
                        && batch.rows[(index + 1)...].allSatisfy({ $0.status == .pending })
                    {
                        uncertainSeen += 1
                    }
                }
                let rows = (0..<60).map { "row \($0)" }
                _ = try await RemindersConnector(storageURL: directory, store: costFake).export(
                    rows: rows, destinationID: "a", batchID: id)
                check(
                    uncertainSeen == 60,
                    "before every save the journal on disk shows that row uncertain, earlier rows confirmed, later pending"
                )
                check(
                    Set(inodes).count == 1 && inodes.first != 0 && Set(sizes).count == 1,
                    "rows are recorded in place: the journal file is not rewritten per row")

                // 10,000 rows, the most one export accepts. Budget scales with TEXTTANK_PERF_BUDGET_SCALE.
                let scale = max(1, Double(ProcessInfo.processInfo.environment["TEXTTANK_PERF_BUDGET_SCALE"] ?? "") ?? 1)
                let bigDirectory = root.appendingPathComponent("row-cost-10k"), bigFake = FakeReminderStore()
                let bigConnector = RemindersConnector(storageURL: bigDirectory, store: bigFake)
                let bigRows = (0..<10000).map { "item \($0) of the largest batch" }, bigID = UUID()
                let start = ProcessInfo.processInfo.systemUptime
                let big = try await bigConnector.export(rows: bigRows, destinationID: "a", batchID: bigID)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                print(String(format: "NOTE 10,000-row export took %.2f s", elapsed))
                check(
                    big.rows.count == 10000 && big.rows.allSatisfy { $0.status == .confirmed }
                        && bigFake.saves.count == 10000,
                    "10,000-row export confirms every row once")
                check(elapsed < 30 * scale, "10,000-row export finishes inside its time budget")
                let bigStored = try requireValue(try bigConnector.storedBatches().first, "fixture: stored 10k batch")
                check(
                    bigStored.rows.map(\.title) == bigRows
                        && bigStored.rows.map(\.reminderID) == big.rows.map(\.reminderID)
                        && bigStored.rows.allSatisfy { $0.status == .confirmed },
                    "10,000-row journal on disk matches the returned batch")

                // Stop Sending is another main-actor task; it must get a turn between rows.
                let stopFake = FakeReminderStore(), stopID = UUID()
                let stopConnector = RemindersConnector(
                    storageURL: root.appendingPathComponent("row-cost-stop"), store: stopFake)
                var done = 0
                let exportTask = Task { @MainActor in
                    try await stopConnector.export(
                        rows: bigRows, destinationID: "a", batchID: stopID,
                        progress: { completed, _ in done = completed })
                }
                let stopper = Task { @MainActor in
                    while done < 100 { await Task.yield() }
                    exportTask.cancel()
                    return done
                }
                let stoppedAt = await stopper.value
                let stopped = try await exportTask.value
                check(
                    stopFake.saves.count <= stoppedAt + 2
                        && stopped.rows.filter({ $0.status == .confirmed }).count == stopFake.saves.count
                        && stopped.rows.filter({ $0.status == .pending }).count == 10000 - stopFake.saves.count,
                    "a stop requested from another main-actor task takes effect within two rows of a 10,000-row export")
            }
            Checks.summary {
                "PASS ReminderChecks: \(Checks.count) assertions; injected stores only, no EventKit access"
            }
        }
    }
}
