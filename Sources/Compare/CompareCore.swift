// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package enum CompareSide: Sendable { case original, modified }
package enum CompareFailure: Error, Equatable, Sendable {
    case invalid, incomplete, cancelled, budget(ReviewBudgetReason)
}
/// Diff and row projection previously allowed two seconds each. A single operation now
/// shares that total, including all validation and serialization for a unified patch.
package enum CompareTimeAllowance: Sendable {
    case standard, extended
    package var seconds: Double { self == .standard ? 4 : 16 }
    package var patchPolicy: ReviewDiffPolicy {
        var policy = MergeCore.policy
        policy.seconds = seconds
        return policy
    }
}
package struct ComparePolicy: Sendable {
    package var maximumWork = 32_000_000
    package var seconds = 2.0
    package var maximumWorkspaceBytes = SizePolicy.standard.reviewWorkspace
    package var maximumOutputBytes = SizePolicy.standard.displayOutput
    package var maximumRows = 500_000
    package init() {}
    package static let `default` = ComparePolicy()
}
package struct CompareLine: Sendable {
    package let range: ReviewByteRange
    package let contentEnd: Int
    package let ending: String
}
package struct CompareRow: Sendable {
    package let original: Int?
    package let modified: Int?
    package let change: Int?
}
package struct CompareUnifiedRow: Sendable {
    package let side: CompareSide
    package let line: Int
    /// Equal rows render once but retain the other source coordinate for reconstruction.
    package let counterpart: Int?
    package let change: Int?
}
/// Bounded native table cell content. Large source lines continue in additional rows;
/// each segment retains exact source bytes and complete grapheme boundaries.
package struct CompareUnifiedSegment: Sendable {
    package let unifiedRow: Int
    package let range: ReviewByteRange
    package let counterpart: ReviewByteRange?
    package let continued: Bool
    package let last: Bool
}
package struct CompareFold: Equatable, Sendable {
    package let rows: Range<Int>
    package var count: Int { rows.count }
}
package struct CompareProjection: Sendable {
    package let original: TextSnapshot
    package let modified: TextSnapshot
    package let changes: ReviewChangeSet
    package let originalLines: [CompareLine]
    package let modifiedLines: [CompareLine]
    package let rows: [CompareRow]
    package let unified: [CompareUnifiedRow]
    package let segments: [CompareUnifiedSegment]
    package let originalToRow: [Int]
    package let modifiedToRow: [Int]
    package let changeRows: [Int]
    package let folds: [CompareFold]
    /// Only independently checked grapheme-safe spans are admitted for decoration.
    package let inlineSpans: [[ReviewInlineSpan]]
    package let inlineLimited: Bool
    package let work: Int
    package let workspaceEstimate: Int

    package static func build(
        original: TextSnapshot, modified: TextSnapshot, changes: ReviewChangeSet,
        policy: ComparePolicy = .default, token: ReviewCancellation = ReviewCancellation(),
        hooks: ReviewDiffHooks = .init()
    ) async throws -> CompareProjection {
        try await withTaskCancellationHandler {
            try await Task.detached {
                try buildWorker(
                    original: original, modified: modified, changes: changes,
                    policy: policy, token: token, hooks: hooks)
            }.value
        } onCancel: {
            token.cancel()
        }
    }
    private static func buildWorker(
        original a: TextSnapshot, modified b: TextSnapshot, changes: ReviewChangeSet,
        policy: ComparePolicy, token: ReviewCancellation, hooks: ReviewDiffHooks
    ) throws -> CompareProjection {
        guard !Thread.isMainThread else { throw CompareFailure.budget(.mainThread) }
        guard changes.original == a.id, changes.modified == b.id else { throw CompareFailure.invalid }
        guard changes.completeness == .complete else { throw CompareFailure.incomplete }
        guard changes.blocks.count <= 100_000, policy.maximumRows >= 0, policy.maximumOutputBytes >= 0,
            policy.maximumWorkspaceBytes >= 0
        else { throw CompareFailure.budget(.output) }
        var limits = ReviewDiffPolicy.default
        limits.maximumWork = policy.maximumWork
        limits.seconds = policy.seconds
        limits.maximumWorkspaceBytes = policy.maximumWorkspaceBytes
        let meter = ReviewMeter(limits, token: token, hooks: hooks)
        do {
            // Reuse the actual F0 scanner with the caller's shared meter/token, not the
            // historical ReviewLineTable convenience initializer's correctness profile.
            let al = try ReviewLines(a, meter: meter), bl = try ReviewLines(b, meter: meter)
            let total = al.ranges.count + bl.ranges.count
            let rowCap = min(500_000, policy.maximumRows)
            guard total <= rowCap else { throw CompareFailure.budget(.output) }
            let estimate = total * 320 + changes.blocks.count * 80 + ((a.bytes.count + b.bytes.count) / 4096 + 2) * 128
            guard estimate <= min(SizePolicy.standard.displayOutput, policy.maximumOutputBytes) else {
                throw CompareFailure.budget(.output)
            }
            try meter.reserve(estimate)
            var retainedSpanBytes = 0
            try meter.enter(.output)
            func lines(_ table: ReviewLines) throws -> [CompareLine] {
                var result: [CompareLine] = []
                result.reserveCapacity(table.ranges.count)
                for r in table.ranges {
                    try meter.spend()
                    var end = r.upper, ending = ""
                    if end > r.lower && table.snapshot.bytes[end - 1] == 10 {
                        end -= 1
                        ending = "LF"
                        if end > r.lower && table.snapshot.bytes[end - 1] == 13 {
                            end -= 1
                            ending = "CRLF"
                        }
                    } else if end > r.lower && table.snapshot.bytes[end - 1] == 13 {
                        end -= 1
                        ending = "CR"
                    }
                    result.append(
                        .init(
                            range: .init(snapshot: table.snapshot.id, lower: r.lower, upper: r.upper),
                            contentEnd: end, ending: ending))
                }
                return result
            }
            let left = try lines(al), right = try lines(bl)
            var rows: [CompareRow] = [], unified: [CompareUnifiedRow] = [], changeRows: [Int] = []
            var leftMap = [Int](repeating: 0, count: left.count), rightMap = [Int](repeating: 0, count: right.count)
            rows.reserveCapacity(total)
            unified.reserveCapacity(total)
            var ai = 0, bi = 0, spans: [[ReviewInlineSpan]] = [], limited = false, admittedSpans = 0
            func offset(_ index: Int, _ lines: [CompareLine], _ s: TextSnapshot) -> Int {
                index == lines.count ? s.bytes.count : lines[index].range.lower
            }
            func equal(_ x: CompareLine, _ y: CompareLine) throws -> Bool {
                let count = x.range.upper - x.range.lower
                guard count == y.range.upper - y.range.lower else { return false }
                return try a.bytes.withUnsafeBytes { (ab: UnsafeRawBufferPointer) in
                    try b.bytes.withUnsafeBytes { (bb: UnsafeRawBufferPointer) in
                        for i in 0..<count {
                            try meter.spend()
                            if ab[x.range.lower + i] != bb[y.range.lower + i] { return false }
                        }
                        return true
                    }
                }
            }
            func appendEqual(until lowerA: Int, _ lowerB: Int) throws {
                while offset(ai, left, a) < lowerA && offset(bi, right, b) < lowerB {
                    try meter.spend()
                    guard ai < left.count, bi < right.count, try equal(left[ai], right[bi]) else {
                        throw CompareFailure.invalid
                    }
                    leftMap[ai] = rows.count
                    rightMap[bi] = rows.count
                    rows.append(.init(original: ai, modified: bi, change: nil))
                    unified.append(.init(side: .original, line: ai, counterpart: bi, change: nil))
                    ai += 1
                    bi += 1
                }
                guard offset(ai, left, a) == lowerA, offset(bi, right, b) == lowerB else {
                    throw CompareFailure.invalid
                }
            }
            for (index, block) in changes.blocks.enumerated() {
                try meter.spend()
                let x = block.original, y = block.modified
                guard x.snapshot == a.id, y.snapshot == b.id, x.lower >= 0, y.lower >= 0,
                    x.lower <= x.upper, y.lower <= y.upper, x.upper <= a.bytes.count, y.upper <= b.bytes.count,
                    x.lower < x.upper || y.lower < y.upper
                else { throw CompareFailure.invalid }
                guard
                    (block.kind == .insert && x.lower == x.upper && y.lower < y.upper)
                        || (block.kind == .delete && y.lower == y.upper && x.lower < x.upper)
                        || (block.kind == .modify && x.lower < x.upper && y.lower < y.upper)
                else { throw CompareFailure.invalid }
                try appendEqual(until: x.lower, y.lower)
                let aStart = ai, bStart = bi
                while ai < left.count && left[ai].range.lower < x.upper {
                    try meter.spend()
                    ai += 1
                }
                while bi < right.count && right[bi].range.lower < y.upper {
                    try meter.spend()
                    bi += 1
                }
                guard offset(ai, left, a) == x.upper, offset(bi, right, b) == y.upper else {
                    throw CompareFailure.invalid
                }
                changeRows.append(rows.count)
                for n in 0..<max(ai - aStart, bi - bStart) {
                    try meter.spend()
                    let l: Int? = n < ai - aStart ? aStart + n : nil, r: Int? = n < bi - bStart ? bStart + n : nil
                    if let l { leftMap[l] = rows.count }
                    if let r { rightMap[r] = rows.count }
                    rows.append(.init(original: l, modified: r, change: index))
                }
                for i in aStart..<ai {
                    try meter.spend()
                    unified.append(.init(side: .original, line: i, counterpart: nil, change: index))
                }
                for i in bStart..<bi {
                    try meter.spend()
                    unified.append(.init(side: .modified, line: i, counterpart: nil, change: index))
                }
                switch block.inline {
                case .unrefined:
                    spans.append([])
                    limited = true
                case .refined(let refinements):
                    // F0 admits at most64KiB per block for refinement. Refuse foreign large
                    // metadata before making strings/cluster maps; line changes remain usable.
                    let size = x.upper - x.lower + y.upper - y.lower
                    if size > 65_536 || refinements.count > 32_000 - admittedSpans {
                        spans.append([])
                        limited = true
                        continue
                    }
                    let retained = refinements.count * MemoryLayout<ReviewInlineSpan>.stride
                    guard retained <= min(SizePolicy.standard.displayOutput, policy.maximumOutputBytes) - estimate - retainedSpanBytes
                    else {
                        spans.append([])
                        limited = true
                        continue
                    }
                    retainedSpanBytes += retained
                    try meter.reserve(retained)
                    let temporary = size * 64 + refinements.count * 128
                    try meter.reserve(temporary)
                    func boundaries(_ s: TextSnapshot, _ r: ReviewByteRange) throws -> Set<Int> {
                        let bytes = s.bytes.subdata(in: r.lower..<r.upper)
                        for start in stride(from: 0, to: bytes.count, by: 1024) {
                            try meter.spend(min(1024, bytes.count - start))
                        }
                        guard let text = ReviewUTF8.text(bytes) else { throw CompareFailure.invalid }
                        var set: Set<Int> = [r.lower], p = r.lower
                        for character in text {
                            let n = character.utf8.count
                            try meter.spend(n)
                            p += n
                            set.insert(p)
                        }
                        return set
                    }
                    let ax = try boundaries(a, x), by = try boundaries(b, y)
                    var checked: [ReviewInlineSpan] = [], previousA = x.lower, previousB = y.lower
                    for span in refinements {
                        try meter.spend()
                        let p = span.original, q = span.modified
                        guard p.snapshot == a.id, q.snapshot == b.id,
                            p.lower >= previousA, q.lower >= previousB, p.upper >= p.lower, q.upper >= q.lower,
                            p.upper <= x.upper, q.upper <= y.upper,
                            ax.contains(p.lower), ax.contains(p.upper), by.contains(q.lower), by.contains(q.upper)
                        else { throw CompareFailure.invalid }
                        checked.append(span)
                        previousA = p.upper
                        previousB = q.upper
                    }
                    spans.append(checked)
                    admittedSpans += checked.count
                    meter.release(temporary)
                }
            }
            try appendEqual(until: a.bytes.count, b.bytes.count)
            guard rows.count <= rowCap, unified.count <= rowCap else { throw CompareFailure.budget(.output) }
            // Three-line context union. An isolated small unchanged run remains visible.
            var folds: [CompareFold] = [], start = 0
            while start < rows.count {
                try meter.spend()
                if rows[start].change != nil {
                    start += 1
                    continue
                }
                var end = start
                while end < rows.count && rows[end].change == nil {
                    try meter.spend()
                    end += 1
                }
                let lo = start == 0 ? min(end, 1) : min(end, start + 3)
                let hi = end == rows.count ? end : max(lo, end - 3)
                if hi > lo { folds.append(.init(rows: lo..<hi)) }
                start = end
            }
            var segments: [CompareUnifiedSegment] = []
            segments.reserveCapacity(unified.count)
            for (rowIndex, row) in unified.enumerated() {
                try meter.spend()
                let snapshot = row.side == .original ? a : b
                let sourceLine = (row.side == .original ? left : right)[row.line]
                let range = sourceLine.range
                let other = row.counterpart.map { right[$0].range }
                func appendSegment(_ lower: Int, _ upper: Int) throws {
                    try meter.spend()
                    guard segments.count < rowCap else { throw CompareFailure.budget(.output) }
                    segments.append(
                        .init(
                            unifiedRow: rowIndex,
                            range: .init(snapshot: snapshot.id, lower: lower, upper: upper),
                            counterpart: other.map {
                                .init(
                                    snapshot: $0.snapshot, lower: $0.lower + lower - range.lower,
                                    upper: $0.lower + upper - range.lower)
                            },
                            continued: lower > range.lower, last: upper == range.upper))
                }
                if range.upper - range.lower <= 4096 {
                    try appendSegment(range.lower, range.upper)
                    continue
                }
                for offset in stride(from: range.lower, to: range.upper, by: 1024) {
                    try meter.spend(min(1024, range.upper - offset))
                }
                guard let text = ReviewUTF8.text(snapshot.bytes.subdata(in: range.lower..<range.upper)) else {
                    throw CompareFailure.invalid
                }
                var start = range.lower, offset = range.lower
                for character in text {
                    let count = character.utf8.count
                    guard count <= 65_536 else { throw CompareFailure.budget(.span) }
                    for i in stride(from: 0, to: count, by: 1024) { try meter.spend(min(1024, count - i)) }
                    if offset > start && count > 4096 - (offset - start) {
                        try appendSegment(start, offset)
                        start = offset
                    }
                    offset += count
                }
                if offset > start { try appendSegment(start, offset) }
            }
            try meter.enter(.delivery)
            return .init(
                original: a, modified: b, changes: changes, originalLines: left, modifiedLines: right,
                rows: rows, unified: unified, segments: segments, originalToRow: leftMap, modifiedToRow: rightMap,
                changeRows: changeRows,
                folds: folds, inlineSpans: spans, inlineLimited: limited, work: meter.metrics.work,
                workspaceEstimate: meter.metrics.peakWorkspaceBytes)
        } catch ReviewHalt.cancelled { throw CompareFailure.cancelled } catch ReviewHalt.budget(let reason) {
            throw CompareFailure.budget(reason)
        }
    }
    package func lines(_ side: CompareSide) -> [CompareLine] { side == .original ? originalLines : modifiedLines }
    package func snapshot(_ side: CompareSide) -> TextSnapshot { side == .original ? original : modified }
    package func row(forLine line: Int, side: CompareSide) -> Int? {
        let map = side == .original ? originalToRow : modifiedToRow
        return map.indices.contains(line) ? map[line] : nil
    }
}
package struct CompareNavigation: Sendable {
    package private(set) var current: Int?
    package let count: Int
    package init(count: Int) {
        self.count = max(0, count)
        current = nil
    }
    package mutating func select(_ index: Int) {
        guard index >= 0, index < count else { return }
        current = index
    }
    package var hasNext: Bool { count > 0 && (current == nil || current! < count - 1) }
    package var hasPrevious: Bool { count > 0 && (current == nil || current! > 0) }
    @discardableResult package mutating func move(next: Bool) -> Int? {
        guard next ? hasNext : hasPrevious else { return current }
        current = current.map { $0 + (next ? 1 : -1) } ?? (next ? 0 : count - 1)
        return current
    }
}

package enum CompareSelection {
    /// Validate complete-string grapheme boundaries off MainActor. No selection is changed.
    package static func slice(_ snapshot: TextSnapshot, range: Range<Int>, token: ReviewCancellation) async throws
        -> TextSnapshot
    {
        try await Task.detached {
            guard range.lowerBound >= 0, range.upperBound <= snapshot.bytes.count, !range.isEmpty,
                let text = ReviewUTF8.text(snapshot.bytes)
            else { throw CompareFailure.invalid }
            var policy = ReviewDiffPolicy.default
            policy.maximumWork = 32_000_000
            let meter = ReviewMeter(policy, token: token, hooks: .init())
            var offset = 0, low = range.lowerBound == 0, high = false
            do {
                for c in text {
                    let n = c.utf8.count
                    for i in stride(from: 0, to: n, by: 1024) { try meter.spend(min(1024, n - i)) }
                    offset += n
                    if offset == range.lowerBound { low = true }
                    if offset == range.upperBound {
                        high = true
                        break
                    }
                    if offset > range.upperBound { break }
                }
                try meter.poll()
                guard low && high else { throw CompareFailure.invalid }
                return try TextSnapshot(
                    bytes: snapshot.bytes.subdata(in: range), source: .freeText(UUID()),
                    label: snapshot.label + " selection", format: snapshot.format)
            } catch ReviewHalt.cancelled { throw CompareFailure.cancelled } catch ReviewHalt.budget(let r) {
                throw CompareFailure.budget(r)
            }
        }.value
    }
}
