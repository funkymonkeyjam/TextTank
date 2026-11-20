// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package struct MergeFailure: Error, Sendable {
    package let reason: ReviewRejection
    /// Zero-based captured change ordinal; nil means the entire destination is invalid.
    package let block: Int?
    package init(_ reason: ReviewRejection, block: Int? = nil) {
        self.reason = reason
        self.block = block
    }
}
package struct MergeBlockCheck: Sendable {
    package let ordinal: Int
    package let range: ReviewByteRange
    package let expected: Data
}
package struct MergePlan: Sendable {
    package let proposal: EditProposal
    package let projectedParent: Data
    package let mergedSliceLength: Int
    package let contributors: [[Int]]
    package let blocks: [MergeBlockCheck]
    package func preflight(current: Data, target: DocumentTarget) throws {
        guard target.documentID == proposal.target.documentID else { throw MergeFailure(.closed) }
        guard target.loadEpoch == proposal.target.loadEpoch else { throw MergeFailure(.reloaded) }
        guard target.revision == proposal.target.revision else { throw MergeFailure(.revisionChanged) }
        try ReviewPreflight.admit(proposal, currentByteLength: current.count)
        guard current.count == target.byteLength, current.count == proposal.target.byteLength else {
            throw MergeFailure(.bytesChanged)
        }
        var failure: MergeFailure?
        // Complete the diagnostic pass before returning its first deterministic failure.
        for block in blocks {
            let r = block.range
            let valid = r.lower >= 0 && r.upper >= r.lower && r.upper <= current.count
            if !valid {
                if failure == nil { failure = MergeFailure(.invalidRange, block: block.ordinal) }
            } else if !current.withUnsafeBytes({ raw in
                block.expected.withUnsafeBytes { raw[r.lower..<r.upper].elementsEqual($0) }
            }) {
                if failure == nil { failure = MergeFailure(.bytesChanged, block: block.ordinal) }
            }
        }
        if let failure { throw failure }
        switch ReviewPreflight.validate(proposal, current: current, target: target) {
        case .success: return
        case .failure(let reason): throw MergeFailure(reason)
        }
    }
}

package enum MergeCore {
    package static var policy: ReviewDiffPolicy {
        var result = ReviewDiffPolicy.default
        result.maximumWork = 64_000_000
        return result
    }
    package static func plan(
        original: TextSnapshot, modified: TextSnapshot, changes: ReviewChangeSet,
        destination: CompareSide, parent: TextSnapshot, slice: Range<Int>?, selected: [Int],
        policy: ReviewDiffPolicy = MergeCore.policy, token: ReviewCancellation = ReviewCancellation(),
        hooks: ReviewDiffHooks = .init()
    ) async throws -> MergePlan {
        try await withTaskCancellationHandler {
            try await Task.detached {
                do {
                    return try build(
                        original, modified, changes, destination, parent, slice, selected,
                        meter: ReviewMeter(policy, token: token, hooks: hooks))
                } catch ReviewHalt.cancelled { throw MergeFailure(.cancelled) } catch is ReviewHalt {
                    throw MergeFailure(.budgetExceeded)
                }
            }.value
        } onCancel: {
            token.cancel()
        }
    }
    static func charge(_ count: Int, meter: ReviewMeter) throws {
        guard count >= 0 else { throw MergeFailure(.invalidRange) }
        for i in stride(from: 0, to: count, by: 1024) { try meter.spend(min(1024, count - i)) }
    }
    static func equal(_ a: Data, _ ar: Range<Int>, _ b: Data, _ br: Range<Int>, meter: ReviewMeter) throws -> Bool {
        guard ar.count == br.count else { return false }
        return try a.withUnsafeBytes { (aa: UnsafeRawBufferPointer) in
            try b.withUnsafeBytes { (bb: UnsafeRawBufferPointer) in
                for i in stride(from: 0, to: ar.count, by: 1024) {
                    let n = min(1024, ar.count - i)
                    try meter.spend(n)
                    if !aa[(ar.lowerBound + i)..<(ar.lowerBound + i + n)].elementsEqual(
                        bb[(br.lowerBound + i)..<(br.lowerBound + i + n)])
                    {
                        return false
                    }
                }
                return true
            }
        }
    }
    static func lineBoundary(_ bytes: Data, _ offset: Int) -> Bool {
        guard offset >= 0, offset <= bytes.count else { return false }
        return offset == 0 || offset == bytes.count || bytes[offset - 1] == 10
            || (bytes[offset - 1] == 13 && bytes[offset] != 10)
    }
    /// Validates the entire exact mapping, including unselected blocks and equal gaps.
    static func validatePair(_ a: TextSnapshot, _ b: TextSnapshot, _ changes: ReviewChangeSet, meter: ReviewMeter)
        throws
    {
        guard !Thread.isMainThread else { throw MergeFailure(.invalidRange) }
        try meter.enter(.lines)
        guard changes.completeness == .complete, changes.original == a.id, changes.modified == b.id else {
            throw MergeFailure(.incomplete)
        }
        guard changes.blocks.count <= min(100_000, meter.policy.maximumBlocks),
            a.bytes.count <= min(8 * 1024 * 1024, meter.policy.maximumInputBytes),
            b.bytes.count <= min(8 * 1024 * 1024, meter.policy.maximumInputBytes)
        else { throw MergeFailure(.budgetExceeded) }
        try meter.reserve(changes.blocks.count * 128)
        var x = 0, y = 0
        for (i, block) in changes.blocks.enumerated() {
            try meter.spend()
            let ar = block.original, br = block.modified
            guard ar.snapshot == a.id, br.snapshot == b.id, ar.lower >= x, br.lower >= y,
                ar.upper >= ar.lower, br.upper >= br.lower, ar.upper <= a.bytes.count, br.upper <= b.bytes.count,
                lineBoundary(a.bytes, ar.lower), lineBoundary(a.bytes, ar.upper),
                lineBoundary(b.bytes, br.lower), lineBoundary(b.bytes, br.upper),
                (block.kind == .insert && ar.lower == ar.upper && br.lower < br.upper)
                    || (block.kind == .delete && br.lower == br.upper && ar.lower < ar.upper)
                    || (block.kind == .modify && ar.lower < ar.upper && br.lower < br.upper)
            else { throw MergeFailure(.invalidRange, block: i) }
            guard try equal(a.bytes, x..<ar.lower, b.bytes, y..<br.lower, meter: meter) else {
                throw MergeFailure(.bytesChanged, block: i)
            }
            x = ar.upper
            y = br.upper
        }
        guard try equal(a.bytes, x..<a.bytes.count, b.bytes, y..<b.bytes.count, meter: meter) else {
            throw MergeFailure(.bytesChanged)
        }
    }
    private struct Group {
        var lower: Int, upper: Int
        var ordinals: [Int]
        var replacementBytes: Int
    }
    private static func build(
        _ a: TextSnapshot, _ b: TextSnapshot, _ changes: ReviewChangeSet,
        _ side: CompareSide, _ parent: TextSnapshot, _ slice: Range<Int>?, _ selected: [Int], meter: ReviewMeter
    ) throws -> MergePlan {
        try meter.poll()
        guard let target = parent.document, parent.bytes.count <= 8 * 1024 * 1024,
            selected.count <= 100_000, changes.blocks.count <= 100_000
        else { throw MergeFailure(.budgetExceeded) }
        let dest = side == .original ? a : b, source = side == .original ? b : a
        let extent = slice ?? 0..<parent.bytes.count
        guard extent.lowerBound >= 0, extent.upperBound <= parent.bytes.count,
            ReviewUTF8.boundary(parent.bytes, extent.lowerBound), ReviewUTF8.boundary(parent.bytes, extent.upperBound),
            slice != nil || dest.id == parent.id
        else { throw MergeFailure(.invalidRange) }
        guard try equal(parent.bytes, extent, dest.bytes, 0..<dest.bytes.count, meter: meter) else {
            throw MergeFailure(.bytesChanged)
        }
        try validatePair(a, b, changes, meter: meter)
        try meter.reserve(changes.blocks.count * 8 + selected.count * 64 + parent.bytes.count * 4)
        var flags = [Bool](repeating: false, count: changes.blocks.count)
        for i in selected {
            try meter.spend()
            guard flags.indices.contains(i), !flags[i] else { throw MergeFailure(.invalidRange, block: i) }
            flags[i] = true
        }
        var groups: [Group] = [], removed = 0, replacementTotal = 0
        func ranges(_ i: Int) -> (ReviewByteRange, ReviewByteRange) {
            let block = changes.blocks[i]
            return side == .original ? (block.original, block.modified) : (block.modified, block.original)
        }
        for i in flags.indices where flags[i] {
            try meter.spend()
            let (r, s) = ranges(i), lo = r.lower + extent.lowerBound, hi = r.upper + extent.lowerBound
            let n = s.upper - s.lower
            removed += hi - lo
            replacementTotal += n
            guard removed <= 8 * 1024 * 1024, replacementTotal <= 8 * 1024 * 1024 else {
                throw MergeFailure(.budgetExceeded)
            }
            if let last = groups.last, lo == last.lower || (lo == last.upper && lo == hi) {
                groups[groups.count - 1].upper = max(last.upper, hi)
                groups[groups.count - 1].ordinals.append(i)
                groups[groups.count - 1].replacementBytes += n
            } else {
                groups.append(.init(lower: lo, upper: hi, ordinals: [i], replacementBytes: n))
            }
        }
        let projectedLength = parent.bytes.count - removed + replacementTotal
        guard groups.count <= min(10_000, ReviewApplyPolicy.default.maximumEdits), projectedLength >= 0,
            projectedLength <= 8 * 1024 * 1024
        else { throw MergeFailure(.budgetExceeded) }
        try meter.enter(.output)
        var edits: [ReviewEdit] = [], checks: [MergeBlockCheck] = [], projected = Data()
        projected.reserveCapacity(projectedLength)
        func append(_ bytes: Data, _ range: Range<Int>, to data: inout Data) throws {
            try charge(range.count, meter: meter)
            bytes.withUnsafeBytes { data.append(contentsOf: $0[range]) }
        }
        var position = 0
        for group in groups {
            try meter.spend()
            var replacement = Data(), cursor = group.lower
            replacement.reserveCapacity(group.replacementBytes)
            for i in group.ordinals {
                let (r, s) = ranges(i), lo = r.lower + extent.lowerBound, hi = r.upper + extent.lowerBound
                try append(parent.bytes, cursor..<lo, to: &replacement)
                try append(source.bytes, s.lower..<s.upper, to: &replacement)
                cursor = hi
                try charge(hi - lo, meter: meter)
                checks.append(
                    .init(
                        ordinal: i, range: .init(snapshot: parent.id, lower: lo, upper: hi),
                        expected: parent.bytes.subdata(in: lo..<hi)))
            }
            try append(parent.bytes, cursor..<group.upper, to: &replacement)
            try charge(group.upper - group.lower, meter: meter)
            edits.append(
                .init(
                    range: .init(snapshot: parent.id, lower: group.lower, upper: group.upper),
                    expected: parent.bytes.subdata(in: group.lower..<group.upper), replacement: replacement))
            try append(parent.bytes, position..<group.lower, to: &projected)
            try append(replacement, 0..<replacement.count, to: &projected)
            position = group.upper
        }
        try append(parent.bytes, position..<parent.bytes.count, to: &projected)
        let proposal = EditProposal(target: target, snapshot: parent.id, edits: edits)
        try ReviewPreflight.admit(proposal, currentByteLength: parent.bytes.count)
        // Charge the bounded opaque strict encoder before invoking it; no file is written.
        try charge(projected.count * 2, meter: meter)
        guard let text = ReviewUTF8.text(projected) else { throw MergeFailure(.invalidText) }
        _ = try FileCodec.encode(text, format: parent.format ?? .init())
        try meter.poll()
        return .init(
            proposal: proposal, projectedParent: projected,
            mergedSliceLength: extent.count - removed + replacementTotal,
            contributors: groups.map(\.ordinals), blocks: checks)
    }
}
