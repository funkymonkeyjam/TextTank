// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import TextTankCore
import EditorBridge

@MainActor final class ReviewRequest {
    let capture: ReviewDocumentCapture
    private let proposalID = UUID()
    private var token = ReviewCancellation()
    private var issued = false
    private var generation: UInt = 0
    private(set) var invalidated = false
    init(capture: ReviewDocumentCapture) { self.capture = capture }
    func cancel() {
        invalidated = true
        token.cancel()
        generation &+= 1
    }
    func compare(
        to modified: TextSnapshot, strategy: ReviewDiffStrategy = .myers,
        policy: ReviewDiffPolicy = .default, hooks: ReviewDiffHooks = .init()
    ) async -> ReviewChangeSet? {
        guard !invalidated, !issued else { return nil }
        generation &+= 1
        token.cancel()
        let currentToken = ReviewCancellation()
        token = currentToken
        let job = generation
        let result = await ReviewDiffEngine.compare(
            capture.snapshot, modified, strategy: strategy, policy: policy, token: currentToken, hooks: hooks)
        guard !invalidated, !currentToken.isCancelled, job == generation else { return nil }
        do { try capture.validateCurrent() } catch { return nil }
        return result
    }
    func issue(changes: ReviewChangeSet, modified: TextSnapshot) -> ReviewApplyHandle? {
        guard !issued, !invalidated else { return nil }
        guard
            let proposal = try? ReviewPreflight.proposal(from: changes, original: capture.snapshot, modified: modified)
        else { return nil }
        return issue(edits: proposal.edits)
    }
    /// Explicit proposal values may be malformed; only the single-use live applier can authorize mutation.
    func issue(edits: [ReviewEdit]) -> ReviewApplyHandle? {
        guard !issued, !invalidated, let target = capture.snapshot.document else { return nil }
        issued = true
        return ReviewApplyHandle(
            ticket: ReviewApplyTicket(
                request: self, id: proposalID,
                proposal: .init(target: target, snapshot: capture.snapshot.id, edits: edits)))
    }
}
enum ReviewApplyResult: Equatable, Sendable { case applied, noChange, rejected(ReviewRejection) }
@MainActor struct ReviewApplyHandle {
    fileprivate let ticket: ReviewApplyTicket
    var proposalID: UUID { ticket.id }
    var bridgeInvocations: Int { ticket.bridgeInvocations }
    func apply() -> ReviewApplyResult { ticket.apply() }
}
@MainActor fileprivate final class ReviewApplyTicket {
    let id: UUID
    private let request: ReviewRequest
    private let proposal: EditProposal
    private var consumed = false
    private(set) var bridgeInvocations = 0
    init(request: ReviewRequest, id: UUID, proposal: EditProposal) {
        self.request = request
        self.id = id
        self.proposal = proposal
    }
    func apply() -> ReviewApplyResult {
        // Terminal before validation or synchronous Scintilla onChange delivery; copies share this bit.
        guard !consumed else { return .rejected(.alreadyUsed) }
        consumed = true
        guard !request.invalidated else { return .rejected(.cancelled) }
        do {
            let (document, editor) = try request.capture.resolve()
            guard !editor.readOnly else { throw ReviewRejection.readOnly }
            guard document.loadEpoch == proposal.target.loadEpoch else { throw ReviewRejection.reloaded }
            guard editor.revision == proposal.target.revision else { throw ReviewRejection.revisionChanged }
            // Cheap count/size guards precede even the live-byte copy.
            guard proposal.edits.count <= 10_000, editor.byteLength <= 8 * 1024 * 1024 else {
                throw ReviewRejection.budgetExceeded
            }
            let target = DocumentTarget(
                documentID: document.runtimeID, revision: editor.revision,
                loadEpoch: document.loadEpoch, byteLength: editor.byteLength, selections: proposal.target.selections)
            let bytes = editor.utf8Data
            let edits = try ReviewPreflight.validate(proposal, current: bytes, target: target).get()
            if edits.isEmpty { return .noChange }
            var native: [TTTextEdit] = []
            native.reserveCapacity(edits.count)
            for edit in edits {
                guard let text = ReviewUTF8.text(edit.replacement), Data(text.utf8) == edit.replacement else {
                    throw ReviewRejection.invalidText
                }
                native.append(
                    TTTextEdit(
                        range: TTByteRange(location: edit.range.lower, length: edit.range.upper - edit.range.lower),
                        text: text))
            }
            // No await, callbacks, selection staging or focus changes between preflight and bridge.
            guard document.isOpen, document.loadEpoch == target.loadEpoch, !editor.readOnly,
                editor.revision == target.revision, editor.byteLength == bytes.count
            else { throw ReviewRejection.revisionChanged }
            bridgeInvocations += 1
            guard editor.applyEdits(native, expectedRevision: target.revision, expectedLength: bytes.count) else {
                throw ReviewRejection.revisionChanged
            }
            return .applied
        } catch let reason as ReviewRejection { return .rejected(reason) } catch { return .rejected(.invalidRange) }
    }
}
