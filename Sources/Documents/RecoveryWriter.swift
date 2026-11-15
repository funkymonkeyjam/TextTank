// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Serial disk writer with at most one pending snapshot. Immutable snapshots cross
/// the queue boundary; Scintilla and NSDocument are accessed only by the caller.
final class RecoveryWriter {
    private let queue=DispatchQueue(label:"TextTank.recovery",qos:.utility)
    private let lock=NSLock()
    private var pending:(() -> Void)?
    private var running=false
    func submit(_ operation:@escaping () -> Void) {
        lock.lock();pending=operation
        let start = !running;running=true;lock.unlock()
        if start {queue.async {self.drain()}}
    }
    private func drain() {
        while true {
            lock.lock()
            guard let operation=pending else {running=false;lock.unlock();return}
            pending=nil;lock.unlock();operation()
        }
    }
    /// Explicit save/discard boundaries wait for older writes before cleanup, so
    /// queued snapshots cannot resurrect a document the user discarded.
    func finish(_ operation:() throws -> Void) rethrows {try queue.sync(execute:operation)}
}
