// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package struct ReviewEdit: Equatable, Sendable {
    package let range: ReviewByteRange
    package let expected: Data
    package let replacement: Data
    package init(range: ReviewByteRange, expected: Data, replacement: Data) {
        self.range = range
        self.expected = expected
        self.replacement = replacement
    }
}
package struct EditProposal: Sendable {
    package let target: DocumentTarget
    package let snapshot: SnapshotID
    package let edits: [ReviewEdit]
    package init(target: DocumentTarget, snapshot: SnapshotID, edits: [ReviewEdit]) {
        self.target = target
        self.snapshot = snapshot
        self.edits = edits
    }
}
package struct ReviewApplyPolicy: Sendable {
    package var maximumEdits = 10_000
    package let maximumExpectedBytes: Int
    package let maximumReplacementBytes: Int
    package let maximumResultBytes: Int
    package var maximumWork = 64_000_000

    package init() {
        maximumExpectedBytes = SizePolicy.standard.reviewText
        maximumReplacementBytes = SizePolicy.standard.reviewText
        maximumResultBytes = SizePolicy.standard.reviewText
    }
    package init(
        maximumExpectedBytes: Int = SizePolicy.standard.reviewText,
        maximumReplacementBytes: Int = SizePolicy.standard.reviewText,
        maximumResultBytes: Int = SizePolicy.standard.reviewText
    ) throws {
        let allowed = 0...SizePolicy.standard.reviewText
        guard allowed.contains(maximumExpectedBytes), allowed.contains(maximumReplacementBytes),
            allowed.contains(maximumResultBytes)
        else { throw ReviewPolicyError.invalidByteLimit }
        self.maximumExpectedBytes = maximumExpectedBytes
        self.maximumReplacementBytes = maximumReplacementBytes
        self.maximumResultBytes = maximumResultBytes
    }
    package static let `default` = ReviewApplyPolicy()
}
package enum ReviewPolicyError: LocalizedError {
    case invalidByteLimit
    package var errorDescription: String? {
        "Choose an expected, replacement and result byte limit between zero and \(SizePolicy.describe(SizePolicy.standard.reviewText))."
    }
}
package enum ReviewPreflight {
    package static func validate(
        _ proposal: EditProposal, current: Data, target: DocumentTarget,
        policy: ReviewApplyPolicy = .default
    ) -> Result<[ReviewEdit], ReviewRejection> {
        do { return .success(try validated(proposal, current: current, target: target, policy: policy)) } catch let
            error as ReviewRejection
        { return .failure(error) } catch { return .failure(.invalidRange) }
    }
    /// Metadata-only admission, safe before taking even the bounded live-byte copy.
    package static func admit(_ proposal: EditProposal, currentByteLength: Int, policy: ReviewApplyPolicy = .default)
        throws
    {
        guard currentByteLength >= 0 else { throw ReviewRejection.invalidRange }
        guard policy.maximumEdits >= 0, proposal.edits.count <= min(10_000, policy.maximumEdits),
            currentByteLength <= SizePolicy.standard.reviewText, policy.maximumWork >= 0
        else { throw ReviewRejection.budgetExceeded }
        var expected = 0, replacements = 0, removed = 0, work = 0
        func add(_ value: Int, to total: inout Int, limit: Int) throws {
            let sum = total.addingReportingOverflow(value)
            guard value >= 0, !sum.overflow, sum.partialValue <= limit else { throw ReviewRejection.budgetExceeded }
            total = sum.partialValue
        }
        // Admission before payload inspection, copies, String conversion or no-op filtering.
        for edit in proposal.edits {
            try add(1, to: &work, limit: policy.maximumWork)
            try add(edit.expected.count, to: &expected, limit: policy.maximumExpectedBytes)
            try add(
                edit.replacement.count, to: &replacements, limit: policy.maximumReplacementBytes)
            guard edit.range.lower >= 0, edit.range.upper >= edit.range.lower,
                edit.range.upper <= currentByteLength
            else { throw ReviewRejection.invalidRange }
            try add(edit.range.upper - edit.range.lower, to: &removed, limit: currentByteLength)
        }
        let projected = (currentByteLength - removed).addingReportingOverflow(replacements)
        guard !projected.overflow, projected.partialValue <= policy.maximumResultBytes else {
            throw ReviewRejection.budgetExceeded
        }
        try add(currentByteLength, to: &work, limit: policy.maximumWork)
        // Two replacement passes: strict validation and the later exact conversion/round-trip.
        try add(replacements, to: &work, limit: policy.maximumWork)
        try add(replacements, to: &work, limit: policy.maximumWork)
        try add(expected, to: &work, limit: policy.maximumWork)
    }
    private static func validated(
        _ proposal: EditProposal, current: Data, target: DocumentTarget,
        policy: ReviewApplyPolicy
    ) throws -> [ReviewEdit] {
        guard proposal.target.documentID == target.documentID else { throw ReviewRejection.closed }
        guard proposal.target.loadEpoch == target.loadEpoch else { throw ReviewRejection.reloaded }
        guard proposal.target.revision == target.revision else { throw ReviewRejection.revisionChanged }
        try admit(proposal, currentByteLength: current.count, policy: policy)
        guard ReviewUTF8.valid(current) else { throw ReviewRejection.invalidText }
        guard current.count == proposal.target.byteLength && current.count == target.byteLength else {
            throw ReviewRejection.bytesChanged
        }
        var previous: ReviewByteRange?, effective: [ReviewEdit] = []
        for edit in proposal.edits {
            let range = edit.range
            guard range.snapshot == proposal.snapshot, ReviewUTF8.boundary(current, range.lower),
                ReviewUTF8.boundary(current, range.upper), edit.expected.count == range.upper - range.lower
            else {
                throw ReviewRejection.invalidRange
            }
            if let p = previous {
                guard range.lower > p.lower, range.lower >= p.upper,
                    !(range.lower == p.upper && range.lower == range.upper)
                else { throw ReviewRejection.invalidRange }
            }
            guard
                current.withUnsafeBytes({ raw in
                    edit.expected.withUnsafeBytes { expected in
                        raw[range.lower..<range.upper].elementsEqual(expected)
                    }
                })
            else { throw ReviewRejection.bytesChanged }
            guard ReviewUTF8.valid(edit.replacement) else { throw ReviewRejection.invalidText }
            if edit.expected != edit.replacement { effective.append(edit) }
            previous = range
        }
        return effective
    }
    package static func proposal(
        from changes: ReviewChangeSet, original: TextSnapshot,
        modified: TextSnapshot
    ) throws -> EditProposal {
        guard changes.completeness == .complete, changes.original == original.id,
            changes.modified == modified.id, let target = original.document
        else { throw ReviewRejection.incomplete }
        guard changes.blocks.count <= ReviewApplyPolicy.default.maximumEdits else {
            throw ReviewRejection.budgetExceeded
        }
        // Admit all coordinates and totals before any expected/replacement Data copy.
        var expectedBytes = 0, replacementBytes = 0, previousOriginal = -1, previousEnd = 0, previousModifiedEnd = 0
        for block in changes.blocks {
            let ar = block.original, br = block.modified
            guard ar.snapshot == original.id, br.snapshot == modified.id, ar.lower >= 0, ar.upper >= ar.lower,
                ar.upper <= original.bytes.count, br.lower >= previousModifiedEnd, br.upper >= br.lower,
                br.upper <= modified.bytes.count, ar.lower > previousOriginal, ar.lower >= previousEnd,
                !(previousOriginal >= 0 && ar.lower == previousEnd && ar.lower == ar.upper)
            else { throw ReviewRejection.invalidRange }
            let expected = expectedBytes.addingReportingOverflow(ar.upper - ar.lower)
            let replacement = replacementBytes.addingReportingOverflow(br.upper - br.lower)
            guard !expected.overflow, !replacement.overflow, expected.partialValue <= SizePolicy.standard.reviewText,
                replacement.partialValue <= SizePolicy.standard.reviewText
            else { throw ReviewRejection.budgetExceeded }
            expectedBytes = expected.partialValue
            replacementBytes = replacement.partialValue
            previousOriginal = ar.lower
            previousEnd = ar.upper
            previousModifiedEnd = br.upper
        }
        let resultLength = (original.bytes.count - expectedBytes).addingReportingOverflow(replacementBytes)
        guard !resultLength.overflow, resultLength.partialValue <= SizePolicy.standard.reviewText else {
            throw ReviewRejection.budgetExceeded
        }
        var edits: [ReviewEdit] = []
        for block in changes.blocks {
            guard block.original.snapshot == original.id, block.modified.snapshot == modified.id,
                block.original.lower >= 0, block.original.upper >= block.original.lower,
                block.original.upper <= original.bytes.count, block.modified.lower >= 0,
                block.modified.upper >= block.modified.lower, block.modified.upper <= modified.bytes.count
            else {
                throw ReviewRejection.invalidRange
            }
            edits.append(
                .init(
                    range: block.original,
                    expected: ReviewUTF8.slice(original.bytes, block.original.lower, block.original.upper),
                    replacement: ReviewUTF8.slice(modified.bytes, block.modified.lower, block.modified.upper)))
        }
        let proposal = EditProposal(target: target, snapshot: original.id, edits: edits)
        _ = try validate(proposal, current: original.bytes, target: target).get()
        return proposal
    }
}
