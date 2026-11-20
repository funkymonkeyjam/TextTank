// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package enum UnifiedPatch {
    package static func write(
        original: TextSnapshot, modified: TextSnapshot, changes: ReviewChangeSet,
        strategy: ReviewDiffStrategy = .myers, policy: ReviewDiffPolicy = MergeCore.policy,
        token: ReviewCancellation = ReviewCancellation(), hooks: ReviewDiffHooks = .init(), raw: Bool = true
    ) async throws -> Data {
        guard raw else { throw MergeFailure(.incomplete) }
        return try await withTaskCancellationHandler {
            // One shared wall-clock/work allowance covers validation, LF diff and serialization.
            let started = hooks.clock()
            let validation = try await Task.detached { () -> ReviewDiffMetrics in
                let meter = ReviewMeter(policy, token: token, hooks: hooks)
                do { try MergeCore.validatePair(original, modified, changes, meter: meter) } catch ReviewHalt.cancelled
                { throw MergeFailure(.cancelled) } catch is ReviewHalt { throw MergeFailure(.budgetExceeded) }
                return meter.metrics
            }.value
            var remaining = policy
            remaining.maximumWork -= validation.work
            remaining.seconds -= hooks.clock() - started
            guard remaining.maximumWork >= 0, remaining.seconds > 0 else { throw MergeFailure(.budgetExceeded) }
            let lf = await ReviewDiffEngine.compareLF(
                original, modified, strategy: strategy, policy: remaining, token: token, hooks: hooks)
            guard lf.completeness == .complete else {
                throw MergeFailure(lf.completeness == .cancelled ? .cancelled : .budgetExceeded)
            }
            remaining.maximumWork -= lf.metrics.work
            remaining.seconds = policy.seconds - (hooks.clock() - started)
            guard remaining.maximumWork >= 0, remaining.seconds > 0 else { throw MergeFailure(.budgetExceeded) }
            let finalPolicy = remaining
            return try await Task.detached {
                do {
                    return try serialize(
                        original, modified, lf, meter: ReviewMeter(finalPolicy, token: token, hooks: hooks))
                } catch ReviewHalt.cancelled { throw MergeFailure(.cancelled) } catch is ReviewHalt {
                    throw MergeFailure(.budgetExceeded)
                }
            }.value
        } onCancel: {
            token.cancel()
        }
    }
    private struct Hunk { var a: Int, endA: Int, b: Int, endB: Int }
    private static func serialize(_ a: TextSnapshot, _ b: TextSnapshot, _ changes: ReviewChangeSet, meter: ReviewMeter)
        throws -> Data
    {
        try meter.poll()
        if changes.blocks.isEmpty { return Data() }
        let al = try ReviewLines(a, meter: meter, lfOnly: true), bl = try ReviewLines(b, meter: meter, lfOnly: true)
        var ar: [Int: Int] = [:], br: [Int: Int] = [:]
        try meter.reserve((al.ranges.count + bl.ranges.count + changes.blocks.count + 2) * 128)
        for i in al.ranges.indices {
            try meter.spend()
            ar[al.ranges[i].lower] = i
        }
        for i in bl.ranges.indices {
            try meter.spend()
            br[bl.ranges[i].lower] = i
        }
        ar[a.bytes.count] = al.ranges.count
        br[b.bytes.count] = bl.ranges.count
        var hunks: [Hunk] = []
        for block in changes.blocks {
            try meter.spend()
            guard let x = ar[block.original.lower], let endX = ar[block.original.upper],
                let y = br[block.modified.lower], let endY = br[block.modified.upper]
            else { throw MergeFailure(.invalidRange) }
            let before = min(3, min(x, y)), after = min(3, min(al.ranges.count - endX, bl.ranges.count - endY))
            let h = Hunk(a: x - before, endA: endX + after, b: y - before, endB: endY + after)
            if let prior = hunks.last, h.a <= prior.endA || h.b <= prior.endB {
                hunks[hunks.count - 1].endA = max(prior.endA, h.endA)
                hunks[hunks.count - 1].endB = max(prior.endB, h.endB)
            } else {
                hunks.append(h)
            }
        }
        let cap = min(32 * 1024 * 1024, meter.policy.maximumOutputBytes)
        var output = Data(), labels = 0
        func append(_ bytes: Data) throws {
            guard bytes.count <= cap - output.count else { throw MergeFailure(.budgetExceeded) }
            try MergeCore.charge(bytes.count, meter: meter)
            output.append(bytes)
        }
        func label(_ value: String) throws -> String {
            // Scan original label under the same budget before deriving/copying its basename.
            try MergeCore.charge(value.utf8.count, meter: meter)
            guard value.utf8.count <= 16_384 else { throw MergeFailure(.budgetExceeded) }
            let name = (value as NSString).lastPathComponent
            let input = name.isEmpty ? "Untitled" : name
            let dotOnly = input == "." || input == ".."
            var bytes = Data()
            for c in input.utf8 {
                try meter.spend()
                if !dotOnly
                    && ((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
                        || [UInt8(45), 46, 95].contains(c))
                {
                    labels += 1
                    guard labels <= 16_384 - 14 else { throw MergeFailure(.budgetExceeded) }
                    bytes.append(c)
                } else {
                    labels += 4
                    guard labels <= 16_384 - 14 else { throw MergeFailure(.budgetExceeded) }
                    bytes.append(contentsOf: String(format: "\\x%02X", c).utf8)
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let oldName = try label(a.label), newName = try label(b.label)
        // Pre-admit the maximum output before building it; actual count stays separately guarded.
        try meter.reserve(
            min(cap, a.bytes.count + b.bytes.count + (al.ranges.count + bl.ranges.count) * 40 + labels + 128))
        try append(Data("--- a/\(oldName)\n+++ b/\(newName)\n".utf8))
        func row(_ prefix: UInt8, _ snapshot: TextSnapshot, _ line: ReviewLine) throws {
            let n = line.upper - line.lower
            guard n + 1 <= cap - output.count else { throw MergeFailure(.budgetExceeded) }
            try MergeCore.charge(n, meter: meter)
            output.append(prefix)
            snapshot.bytes.withUnsafeBytes { output.append(contentsOf: $0[line.lower..<line.upper]) }
            if snapshot.bytes[line.upper - 1] != 10 { try append(Data("\n\\ No newline at end of file\n".utf8)) }
        }
        var nextBlock = 0
        for h in hunks {
            try meter.spend()
            let countA = h.endA - h.a, countB = h.endB - h.b
            try append(
                Data("@@ -\(countA == 0 ? h.a : h.a + 1),\(countA) +\(countB == 0 ? h.b : h.b + 1),\(countB) @@\n".utf8)
            )
            var x = h.a, y = h.b
            while nextBlock < changes.blocks.count {
                let block = changes.blocks[nextBlock]
                let bx = ar[block.original.lower]!, by = br[block.modified.lower]!
                if bx > h.endA || by > h.endB { break }
                while x < bx && y < by {
                    try row(32, a, al.ranges[x])
                    x += 1
                    y += 1
                }
                guard x == bx, y == by else { throw MergeFailure(.invalidRange) }
                let ex = ar[block.original.upper]!, ey = br[block.modified.upper]!
                while x < ex {
                    try row(45, a, al.ranges[x])
                    x += 1
                }
                while y < ey {
                    try row(43, b, bl.ranges[y])
                    y += 1
                }
                nextBlock += 1
            }
            while x < h.endA && y < h.endB {
                try row(32, a, al.ranges[x])
                x += 1
                y += 1
            }
            guard x == h.endA, y == h.endB else { throw MergeFailure(.invalidRange) }
        }
        guard nextBlock == changes.blocks.count else { throw MergeFailure(.invalidRange) }
        try meter.poll()
        return output
    }
}
