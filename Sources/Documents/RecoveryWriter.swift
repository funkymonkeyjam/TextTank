// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Serial disk writer with at most one pending snapshot. Immutable snapshots cross
/// the queue boundary; Scintilla and NSDocument are accessed only by the caller.
/// Sendable boundary: queue/lock are immutable; pending and running are accessed only
/// under lock. Only @Sendable operations cross the queue; operations and queue.sync
/// execute after unlocking, so no client callback runs while the state lock is held.
final package class RecoveryWriter: @unchecked Sendable {
    package init() {}

    /// Validation runs independently of potentially blocked disk I/O. The owning document admits
    /// one capture at a time and resamples a deferred timer after its current capture is prepared.
    package typealias Write = @Sendable () throws -> Void
    package typealias Prepare = @Sendable () throws -> Write
    private let preparationQueue = DispatchQueue(label: "TextTank.recovery.prepare", qos: .utility)
    private let queue = DispatchQueue(label: "TextTank.recovery", qos: .utility)
    private let lock = NSLock()
    private var pending: (@Sendable () -> Void)?
    private var running = false
    package func submit(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        let displaced = pending
        pending = operation
        let start = !running
        running = true
        lock.unlock()
        // Releasing a closure can run captured deinitializers, including client reentry.
        // Keep its last reference alive until the state lock has been released.
        withExtendedLifetime(displaced) {}
        if start { queue.async { self.drain() } }
    }
    /// Only a complete, validated capture can displace the previous pending disk write.
    package func submitPrepared(
        _ prepare: @escaping Prepare, didPrepare: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        preparationQueue.async {
            defer { didPrepare() }
            do {
                let write = try prepare()
                self.submit {
                    do {
                        try write()
                        completion(nil)
                    } catch { completion(error) }
                }
            } catch { completion(error) }
        }
    }
    private func drain() {
        while true {
            lock.lock()
            guard let operation = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            operation()
        }
    }
    /// Explicit save/discard boundaries wait for a write that is already running before
    /// cleanup, so an older snapshot cannot resurrect a document the user discarded. A snapshot
    /// that is queued but not started is dropped instead: the finishing operation supersedes
    /// it, and writing it only for the cleanup to replace or delete it would be wasted work.
    /// Callers must not finish from an operation already running on this writer's queue.
    package func finish(_ operation: @Sendable () throws -> Void) rethrows {
        preparationQueue.sync {}
        try finishPending(operation)
    }
    /// The caller captures synchronously after older preparation settles. A failed capture has
    /// nothing to replace the last good write with, so let that write finish before returning.
    package func finishPrepared(_ prepare: () throws -> Write) throws {
        preparationQueue.sync {}
        let write: Write
        do { write = try prepare() } catch {
            queue.sync {}
            throw error
        }
        try finishPending(write)
    }
    private func finishPending(_ operation: @Sendable () throws -> Void) rethrows {
        dispatchPrecondition(condition: .notOnQueue(queue))
        lock.lock()
        let displaced = pending
        pending = nil
        lock.unlock()
        withExtendedLifetime(displaced) {}
        try queue.sync(execute: operation)
    }
}

/// Decides when repeated recovery-write failures deserve more than the status line.
/// One failure can be transient; from the second consecutive failure the user is told
/// once per app session, and any success starts the count again.
package struct RecoveryFailureTracker {
    package init() {}

    static package let threshold = 2
    private(set) package var consecutiveFailures = 0
    package var isFailing: Bool { consecutiveFailures > 0 }
    mutating package func recordSuccess() { consecutiveFailures = 0 }
    /// Returns true when this failure should raise the session's single notice.
    mutating package func recordFailure(sessionAlreadyNotified: Bool) -> Bool {
        consecutiveFailures += 1
        return consecutiveFailures >= Self.threshold && !sessionAlreadyNotified
    }
}
