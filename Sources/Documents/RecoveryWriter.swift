// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Serial disk writer with at most one pending snapshot. Immutable snapshots cross
/// the queue boundary; Scintilla and NSDocument are accessed only by the caller.
/// Sendable boundary: queue/lock are immutable; pending and running are accessed only
/// under lock. Only @Sendable operations cross the queue; operations and queue.sync
/// execute after unlocking, so no client callback runs while the state lock is held.
final package class RecoveryWriter: @unchecked Sendable {
    package init() {}

    private let queue = DispatchQueue(label: "TextTank.recovery", qos: .utility)
    private let lock = NSLock()
    private var pending: (@Sendable () -> Void)?
    private var running = false
    package func submit(_ operation: @escaping @Sendable () -> Void) {
        lock.lock()
        pending = operation
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.drain() } }
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
    package func finish(_ operation: @Sendable () throws -> Void) rethrows {
        lock.lock()
        pending = nil
        lock.unlock()
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
