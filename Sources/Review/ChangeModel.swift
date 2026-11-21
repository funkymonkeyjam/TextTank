// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package enum ReviewDiffStrategy: String, CaseIterable, Sendable { case myers, anchored }
package enum ReviewDiffPhase: String, CaseIterable, Hashable, Sendable {
    case lines, trim, anchors, bisect, backtrack, output, inline, delivery
}
package enum ReviewBudgetReason: String, Error, Sendable {
    case input, lines, work, time, workspace, output, span, tokens, invalidInput, mainThread, notAttempted
}
package enum ReviewCompleteness: Equatable, Sendable { case complete, cancelled, budgetStopped(ReviewBudgetReason) }
package enum ReviewChangeKind: String, Sendable { case insert, delete, modify }
package struct ReviewInlineSpan: Equatable, Sendable {
    package let original: ReviewByteRange
    package let modified: ReviewByteRange
}
package enum ReviewInlineState: Equatable, Sendable {
    case refined([ReviewInlineSpan]), unrefined(ReviewBudgetReason)
}
package struct ReviewChangeBlock: Sendable {
    package let original: ReviewByteRange
    package let modified: ReviewByteRange
    package let kind: ReviewChangeKind
    package let inline: ReviewInlineState
}
package struct ReviewDiffMetrics: Sendable {
    package var work = 0
    package var peakWorkspaceBytes = 0
    package var inlineWork = 0
    package var peakInlineWorkspaceBytes = 0
    package var resultBytes = 0
    package var anchors = 0
    package var phases: Set<ReviewDiffPhase> = []
    package var seconds: Double = 0
}
package struct ReviewChangeSet: Sendable {
    package let original: SnapshotID
    package let modified: SnapshotID
    package let blocks: [ReviewChangeBlock]
    package let completeness: ReviewCompleteness
    package let metrics: ReviewDiffMetrics
    package var identical: Bool { completeness == .complete && blocks.isEmpty }
}
package struct ReviewInlinePolicy: Sendable {
    package var maximumWork = 250_000
    package var seconds = 0.250
    package var maximumWorkspaceBytes = 16 * 1024 * 1024
    package var maximumSpans = 32_000
    package var maximumOutputBytes = 8 * 1024 * 1024
    package var maximumSpanBytes = 64 * 1024
    package var maximumTokens = 32_000
}
package struct ReviewDiffPolicy: Sendable {
    package var maximumInputBytes = 8 * 1024 * 1024
    package var maximumLines = 250_000
    package var maximumWork = 128_000_000
    package var seconds = 2.0
    package var maximumWorkspaceBytes = 128 * 1024 * 1024
    package var maximumBlocks = 100_000
    package var maximumOutputBytes = 32 * 1024 * 1024
    package var inline = ReviewInlinePolicy()
    package init() {}
    package static let `default` = ReviewDiffPolicy()
    package static var correctness: ReviewDiffPolicy {
        var p = ReviewDiffPolicy()
        p.maximumWork = 512_000_000
        p.seconds = 30
        return p
    }
}
/// Only the boolean crosses threads; no document, editor or caller object is retained.
package final class ReviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    package init() {}
    package func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
    package var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
/// Ordinary scheduling/clock/hash dependencies, also useful for deterministic owned checks.
package struct ReviewDiffHooks: Sendable {
    package let checkpoint: (@Sendable (ReviewDiffPhase, Int) -> Void)?
    package let clock: @Sendable () -> Double
    package let hashByte: @Sendable (UInt64, UInt8) -> UInt64
    package init(
        checkpoint: (@Sendable (ReviewDiffPhase, Int) -> Void)? = nil,
        clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        hashByte: @escaping @Sendable (UInt64, UInt8) -> UInt64 = { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    ) {
        self.checkpoint = checkpoint
        self.clock = clock
        self.hashByte = hashByte
    }
}
enum ReviewHalt: Error { case cancelled, budget(ReviewBudgetReason) }
final class ReviewMeter {
    let policy: ReviewDiffPolicy, token: ReviewCancellation, hooks: ReviewDiffHooks
    let started: Double
    var metrics = ReviewDiffMetrics()
    private var workspace = 0, sincePoll = 0
    private var phase: ReviewDiffPhase = .lines
    init(_ policy: ReviewDiffPolicy, token: ReviewCancellation, hooks: ReviewDiffHooks) {
        self.policy = policy
        self.token = token
        self.hooks = hooks
        started = hooks.clock()
    }
    func enter(_ phase: ReviewDiffPhase) throws {
        self.phase = phase
        metrics.phases.insert(phase)
        try poll()
    }
    func poll() throws {
        hooks.checkpoint?(phase, metrics.work)
        if token.isCancelled { throw ReviewHalt.cancelled }
        guard policy.seconds.isFinite, policy.seconds > 0, hooks.clock() - started < policy.seconds else {
            throw ReviewHalt.budget(.time)
        }
        sincePoll = 0
    }
    func spend(_ amount: Int = 1) throws {
        guard amount >= 0, metrics.work <= policy.maximumWork,
            amount <= policy.maximumWork - metrics.work
        else { throw ReviewHalt.budget(.work) }
        if sincePoll > 0 && amount > 1024 - sincePoll { try poll() }
        metrics.work += amount
        // Callers split opaque byte scans into at most1024-byte chunks.
        sincePoll += amount
        if sincePoll >= 1024 { try poll() }
    }
    func reserve(_ bytes: Int) throws {
        try poll()
        let limit = min(128 * 1024 * 1024, policy.maximumWorkspaceBytes)
        guard bytes >= 0, workspace <= limit,
            bytes <= limit - workspace
        else { throw ReviewHalt.budget(.workspace) }
        workspace += bytes
        metrics.peakWorkspaceBytes = max(metrics.peakWorkspaceBytes, workspace)
    }
    func release(_ bytes: Int) { workspace -= bytes }
    func result(_ count: Int) throws {
        let bytes = count.multipliedReportingOverflow(by: 256)
        guard count <= min(100_000, policy.maximumBlocks), !bytes.overflow,
            bytes.partialValue <= min(32 * 1024 * 1024, policy.maximumOutputBytes)
        else { throw ReviewHalt.budget(.output) }
        metrics.resultBytes = bytes.partialValue
    }
}
struct ReviewLine {
    let lower: Int, upper: Int, hash: UInt64
}
struct ReviewLines {
    let snapshot: TextSnapshot
    let ranges: [ReviewLine]
    init(_ snapshot: TextSnapshot, meter: ReviewMeter, lfOnly: Bool = false) throws {
        self.snapshot = snapshot
        try meter.enter(.lines)
        guard snapshot.bytes.count <= min(8 * 1024 * 1024, meter.policy.maximumInputBytes),
            meter.policy.maximumLines >= 0
        else {
            throw ReviewHalt.budget(.input)
        }
        // Pre-admit capacity including conservative Array capacity overhead, before allocation.
        let capacity = min(snapshot.bytes.count, min(250_000, meter.policy.maximumLines))
        try meter.reserve(capacity * 64)
        var lines: [ReviewLine] = []
        lines.reserveCapacity(capacity)
        try snapshot.bytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0, i = 0, hash: UInt64 = 14_695_981_039_346_656_037
            while i < bytes.count {
                try meter.spend()
                let c = bytes[i]
                hash = meter.hooks.hashByte(hash, c)
                i += 1
                if !lfOnly, c == 13, i < bytes.count, bytes[i] == 10 {
                    try meter.spend()
                    hash = meter.hooks.hashByte(hash, bytes[i])
                    i += 1
                }
                if c == 10 || (!lfOnly && c == 13) {
                    guard lines.count < capacity else { throw ReviewHalt.budget(.lines) }
                    lines.append(.init(lower: start, upper: i, hash: hash))
                    start = i
                    hash = 14_695_981_039_346_656_037
                }
            }
            if start < bytes.count {
                guard lines.count < capacity else { throw ReviewHalt.budget(.lines) }
                lines.append(.init(lower: start, upper: bytes.count, hash: hash))
            }
        }
        ranges = lines
    }
    func offset(_ index: Int) -> Int { index == ranges.count ? snapshot.bytes.count : ranges[index].lower }
}
