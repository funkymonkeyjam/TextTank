// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import EventKit
import Darwin

struct ReminderDestination: Identifiable, Equatable {
    let id: String
    let title: String
    let source: String
    let writable: Bool
}
enum ReminderPermission { case notDetermined, denied, authorized }
enum ReminderRowStatus: String, Codable { case pending, confirmed, failed, uncertain }
struct ReminderRow: Codable, Identifiable {
    let id: UUID
    let title: String
    var status: ReminderRowStatus = .pending
    var reminderID: String?
    var message: String?
}
/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct ReminderBatch: Codable, Identifiable {
    var schemaVersion = 1
    let id: UUID
    let destinationID: String
    let destinationTitle: String
    let destinationSource: String
    var rows: [ReminderRow]
    let createdAt: Date
}
enum ReminderConnectorError: Error, LocalizedError {
    case permissionRequired, destinationUnavailable, invalidBatch, busy, knownFailure(String), uncertain(String)
    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "Reminders access is unavailable. Grant access explicitly or review system privacy settings."
        case .destinationUnavailable: return "The selected Reminders list is missing or no longer writable. No items were sent."
        case .invalidBatch: return "The export journal is invalid, unsupported, or does not match this batch. It was preserved."
        case .busy: return "An export is already running."
        case .knownFailure(let message): return message
        case .uncertain(let message): return message
        }
    }
}

/// Injectable boundary; tests never instantiate EventKit. All calls stay on the main actor.
@MainActor protocol ReminderStore {
    var permission: ReminderPermission { get }
    func requestAccess() async throws
    func destinations() throws -> [ReminderDestination]
    /// Throw knownFailure only when no write occurred. All other failures are uncertain.
    func save(title: String, destinationID: String) throws -> String
}

@MainActor final class EventKitReminderStore: ReminderStore {
    private let store = EKEventStore()
    var permission: ReminderPermission {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    func requestAccess() async throws {
        // This is the only permission-requesting entry point; construction and import never request.
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw ReminderConnectorError.permissionRequired }
    }
    func destinations() throws -> [ReminderDestination] {
        guard permission == .authorized else { throw ReminderConnectorError.permissionRequired }
        return store.calendars(for: .reminder).map {
            ReminderDestination(id: $0.calendarIdentifier, title: $0.title,
                                source: $0.source.title, writable: $0.allowsContentModifications)
        }
    }
    func save(title: String, destinationID: String) throws -> String {
        guard permission == .authorized else {
            throw ReminderConnectorError.knownFailure("Reminders access was revoked before this item was sent.")
        }
        guard let calendar = store.calendar(withIdentifier: destinationID), calendar.allowedEntityTypes.contains(.reminder), calendar.allowsContentModifications else {
            throw ReminderConnectorError.knownFailure("The selected list was deleted or became read-only before this item was sent.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title; reminder.calendar = calendar
        do { try store.save(reminder, commit: true) }
        catch { throw ReminderConnectorError.uncertain("EventKit did not confirm whether this item was saved: \(error.localizedDescription)") }
        return reminder.calendarItemIdentifier
    }
}

/// One durable batch identity spans invocation/retry/restart. Names and titles are data.
/// A journal row becomes uncertain before touching EventKit. Only confirmed writes become
/// confirmed; uncertain rows require manual reconciliation and are never automatically resent.
@MainActor final class RemindersConnector {
    private let store: ReminderStore
    private let storageURL: URL
    private var busy = false
    init(storageURL: URL) { self.storageURL = storageURL; self.store = EventKitReminderStore() }
    init(storageURL: URL, store: ReminderStore) { self.storageURL = storageURL; self.store = store }
    func requestAccess() async throws {
        switch store.permission {
        case .authorized: return
        case .notDetermined: try await store.requestAccess()
        case .denied: throw ReminderConnectorError.permissionRequired
        }
    }
    func destinations() throws -> [ReminderDestination] {
        guard store.permission == .authorized else { throw ReminderConnectorError.permissionRequired }
        return try store.destinations()
    }
    func storedBatches() throws -> [ReminderBatch] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        try checkDirectory()
        return try FileManager.default.contentsOfDirectory(at: storageURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw ReminderConnectorError.invalidBatch }
                return try load(id)
            }
    }
    func export(rows: [String], destinationID: String, batchID: UUID, retryFailed: Bool = false, progress: ((Int,Int)->Void)? = nil) async throws -> ReminderBatch {
        guard !busy else { throw ReminderConnectorError.busy }
        guard !rows.isEmpty, rows.count <= 10000, rows.allSatisfy({ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1048576 }) else { throw ReminderConnectorError.invalidBatch }
        busy = true; defer { busy = false }
        // A process lock covers retries across connector instances and app processes.
        // Never wait for it on the UI actor; a competing request is reported as busy.
        try checkDirectory()
        try preparePrivateDirectory()
        let lockPath = storageURL.appendingPathComponent(".export.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard descriptor >= 0 else { throw ReminderConnectorError.invalidBatch }
        var lockInfo = stat()
        guard fstat(descriptor,&lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG else { close(descriptor); throw ReminderConnectorError.invalidBatch }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw ReminderConnectorError.busy }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        let selected = try destinations().first { $0.id == destinationID && $0.writable }
        guard let selected else { throw ReminderConnectorError.destinationUnavailable }
        var batch: ReminderBatch
        if FileManager.default.fileExists(atPath: path(batchID).path) {
            batch = try load(batchID)
            guard batch.destinationID == destinationID, batch.rows.map(\.title) == rows else { throw ReminderConnectorError.invalidBatch }
        } else {
            batch = ReminderBatch(id: batchID, destinationID: destinationID, destinationTitle: selected.title,
                                  destinationSource: selected.source, rows: rows.map { ReminderRow(id: UUID(), title: $0) }, createdAt: Date())
            try persist(batch)
        }
        progress?(batch.rows.filter { $0.status != .pending }.count,batch.rows.count)
        for index in batch.rows.indices {
            if Task.isCancelled { break } // Unsent pending rows remain resumable under this batch ID.
            guard batch.rows[index].status == .pending || (retryFailed && batch.rows[index].status == .failed) else { continue }
            // A durable uncertainty barrier precedes each nontransactional external write.
            batch.rows[index].status = .uncertain
            batch.rows[index].message = "Export started but confirmation may be missing. Check the destination before sending another copy."
            try persist(batch)
            do {
                let identifier = try store.save(title: batch.rows[index].title, destinationID: destinationID)
                batch.rows[index].status = .confirmed; batch.rows[index].reminderID = identifier; batch.rows[index].message = nil
            } catch ReminderConnectorError.knownFailure(let message) {
                batch.rows[index].status = .failed; batch.rows[index].message = message
            } catch {
                batch.rows[index].status = .uncertain; batch.rows[index].message = error.localizedDescription
            }
            // If this write fails, disk retains uncertain, never a replayable pending row.
            try persist(batch)
            progress?(index + 1,batch.rows.count)
            await Task.yield() // Allow UI cancellation without releasing the batch journal lock.
        }
        return batch
    }
    private func path(_ id: UUID) -> URL { storageURL.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
    private func checkDirectory() throws {
        guard storageURL.isFileURL else { throw ReminderConnectorError.invalidBatch }
        if FileManager.default.fileExists(atPath: storageURL.path) {
            let values = try FileManager.default.attributesOfItem(atPath:storageURL.path)
            guard values[.type] as? FileAttributeType == .typeDirectory else { throw ReminderConnectorError.invalidBatch }
        }
    }
    static let maximumJournalBytes = 32 * 1024 * 1024
    private func load(_ id: UUID) throws -> ReminderBatch {
        try checkDirectory()
        let url = path(id)
        let descriptor = open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        guard descriptor >= 0 else { throw ReminderConnectorError.invalidBatch }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true); defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_size <= Self.maximumJournalBytes else { throw ReminderConnectorError.invalidBatch }
        let data = try handle.read(upToCount:Self.maximumJournalBytes + 1) ?? Data()
        guard data.count <= Self.maximumJournalBytes else { throw ReminderConnectorError.invalidBatch }
        let batch = try JSONDecoder().decode(ReminderBatch.self, from:data)
        guard batch.schemaVersion == 1, batch.id == id, Set(batch.rows.map(\.id)).count == batch.rows.count,
              batch.rows.allSatisfy({ $0.status != .confirmed || !($0.reminderID ?? "").isEmpty }) else { throw ReminderConnectorError.invalidBatch }
        return batch
    }
    private func preparePrivateDirectory() throws {
        try checkDirectory()
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkDirectory()
        // Only this dedicated journal directory is changed, never its parents.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageURL.path)
    }
    static func encodedJournal(_ batch:ReminderBatch) throws -> Data {
        // Bound aggregate row encoding before allocating a complete journal.
        let encoder=JSONEncoder();var rowBytes=0
        for row in batch.rows {
            let count=try encoder.encode(row).count
            guard count <= maximumJournalBytes-rowBytes else { throw ReminderConnectorError.invalidBatch }
            rowBytes += count
        }
        let data=try encoder.encode(batch)
        guard data.count <= maximumJournalBytes else { throw ReminderConnectorError.invalidBatch }
        return data
    }
    private func persist(_ batch: ReminderBatch) throws {
        let data = try Self.encodedJournal(batch)
        try checkDirectory()
        try preparePrivateDirectory()
        let url = path(batch.id)
        if FileManager.default.fileExists(atPath: url.path) { _ = try load(batch.id) }
        let temporary = storageURL.appendingPathComponent(UUID().uuidString + ".pending")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        // Atomic rename preserves 0600 from creation; there is no world-readable interval.
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
