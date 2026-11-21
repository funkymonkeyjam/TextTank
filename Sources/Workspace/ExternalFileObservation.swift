import AppKit
import TextTankCore

/// One observation is shared by every presentation of a document. Checking never writes to it.
@MainActor final class ExternalFileObservation: NSObject {
    private weak var document: TextDocument?
    private struct State: Equatable {
        let url: URL
        let baseline: String
        let revision: UInt
        let format: FileFormat
        let dirty: Bool
        let generation: UInt
    }
    private struct ContentCheck {
        let state: State
        let identity: FileSignature
    }
    private struct Candidate: Equatable {
        let state: State
        let digest: String
        let identity: FileSignature
    }
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var generation: UInt = 0
    private weak var inspectionOperation: Operation?
    private(set) var checking = false
    private var checkAgain = false
    private var frontmost = false
    private var pendingContentCheck: ContentCheck?
    private var reloading = false
    private var largeFile: ContentCheck?
    private var known: FileSample?
    private var candidate: Candidate?
    private var attemptedAutomatic: Candidate?
    private var policy: ExternalChangePolicy
    private(set) var notice: String?
    var actionTitle: String? {
        if candidate != nil { return "Reload…" }
        return largeFile != nil ? "Check Contents…" : nil
    }
    typealias Reader = @Sendable (URL, Int) throws -> CapturedFileRead
    var readCandidate: Reader = { try WorkspaceStore.captureRegularFile($0, maximumBytes: $1) }
    typealias Inspector = @Sendable (URL, String, FileSample?) -> DocumentMonitor.Inspection
    var inspect: Inspector = { DocumentMonitor.inspect($0, expected: $1, known: $2) }
    init(document: TextDocument) {
        self.document = document
        policy = EditorServices.current?.settings?.value.diskChangeBehavior ?? .ask
    }
    func setPolicy(_ next: ExternalChangePolicy) {
        guard policy != next else { return }
        policy = next
        invalidate()
        check(prioritized: document?.presentation?.isActiveTab == true)
    }

    private var state: State? {
        guard let document, document.isOpen, let url = document.diskURL, let baseline = document.originalDiskFingerprint
        else { return nil }
        return State(
            url: url, baseline: baseline, revision: document.editor.revision, format: document.format,
            dirty: document.isDocumentEdited || document.editor.modified || document.format != document.savedFormat,
            generation: generation)
    }
    func invalidate() {
        generation &+= 1
        if document?.isClosed == true {
            inspectionOperation?.cancel()
            inspectionOperation = nil
            checking = false
            checkAgain = false
        }
        known = nil
        pendingContentCheck = nil
        largeFile = nil
        candidate = nil
        attemptedAutomatic = nil
        if notice != nil {
            notice = nil
            document?.externalNoticeChanged()
        }
    }
    func check(prioritized: Bool = false) {
        guard policy != .ignore, let expected = state else { return }
        frontmost = frontmost || prioritized
        guard !checking else {
            if prioritized { inspectionOperation?.queuePriority = .veryHigh }
            checkAgain = true
            return
        }
        checking = true
        let highPriority = frontmost
        frontmost = false
        let known = known ?? document?.savedDiskSample
        let inspect = inspect
        let contentCheck = pendingContentCheck.flatMap { $0.state == expected ? $0 : nil }
        pendingContentCheck = nil
        let deliver: @MainActor @Sendable (DocumentMonitor.Inspection) -> Void = { [weak self] result in
            guard let self else { return }
            self.inspectionOperation = nil
            self.checking = false
            let repeatCheck = self.checkAgain || self.state != expected
            self.checkAgain = false
            if repeatCheck {
                if self.state == expected, self.pendingContentCheck == nil { self.pendingContentCheck = contentCheck }
                self.check()
                return
            }
            self.known = result.sample
            let message: String?
            switch result.status {
            case .unchanged, .checking, .stopped: message = nil
            case .changed: message = "Changed on disk"
            case .missing: message = "File missing on disk"
            case .unavailable(let reason): message = "Could not verify disk file: " + reason
            }
            let previousAction = self.actionTitle
            self.largeFile = result.identity.flatMap {
                result.digest == nil && $0.size > DocumentMonitor.maximumBytes
                    ? ContentCheck(state: expected, identity: $0) : nil
            }
            self.candidate = nil
            if case .changed = result.status, let digest = result.digest, let identity = result.identity {
                self.candidate = Candidate(state: expected, digest: digest, identity: identity)
            }
            if self.notice != message || self.actionTitle != previousAction {
                self.notice = message
                self.document?.externalNoticeChanged()
            }
            if self.policy == .reloadIfUnmodified, !expected.dirty, contentCheck == nil, let offered = self.candidate,
                offered.identity.size <= DocumentMonitor.maximumBytes, offered != self.attemptedAutomatic
            {
                self.attemptedAutomatic = offered
                self.read(offered)
            }
        }
        let op = BlockOperation {
            let result: DocumentMonitor.Inspection
            if let contentCheck {
                result = DocumentMonitor.inspect(
                    expected.url, expected: expected.baseline, known: known, authorized: contentCheck.identity)
            } else {
                result = inspect(expected.url, expected.baseline, known)
            }
            DispatchQueue.main.async { deliver(result) }
        }
        op.queuePriority = highPriority ? .veryHigh : .normal
        inspectionOperation = op
        Self.workers.addOperation(op)
    }

    @objc func reload(_ sender: Any?) {
        guard !CompareCommandScope.blocksWorkspace, document?.isOpen == true else { return }
        if let largeFile {
            pendingContentCheck = largeFile.state == state ? largeFile : nil
            check(prioritized: true)
            return
        }
        guard !reloading, let candidate, let document else { return }
        guard state == candidate.state else {
            check(prioritized: true)
            return
        }
        if candidate.state.dirty {
            guard let window = document.windowForSheet, window.attachedSheet == nil else { return }
            let alert = TTAlert()
            alert.messageText = "Discard edits and reload the changed file?"
            alert.informativeText = "Reload replaces the editor contents and clears this document’s Undo history."
            alert.addButton(withTitle: "Keep Editing", role: .cancel)
            alert.addButton(withTitle: "Discard and Reload").hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn else { return }
                self?.read(candidate)
            }
        } else {
            read(candidate)
        }
    }
    private func read(_ target: Candidate) {
        guard state == target.state else {
            check(prioritized: true)
            return
        }
        guard !reloading else { return }
        reloading = true
        let apply: @MainActor @Sendable (Result<CapturedFileRead, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.reloading = false
            guard self.state == target.state, let document = self.document else {
                self.check(prioritized: true)
                return
            }
            do {
                let read = try result.get()
                // The action applies only to the bytes inspected by this notice. Recheck the pinned
                // pathname after the queue hop, including atomic replacement immediately before delivery.
                guard read.sample.digest == target.digest,
                    try WorkspaceStore.signature(ofRegularFileAt: target.state.url, maximumBytes: Int.max)
                        == target.identity
                else {
                    self.check(prioritized: true)
                    return
                }
                try document.acceptExternalRead(read, from: target.state.url)
            } catch {
                document.presentation?.showTransientStatus(
                    "Reload could not be completed: " + error.localizedDescription)
                self.check(prioritized: true)
            }
        }
        let reader = readCandidate
        Self.workers.addOperation {
            let read = Result { try reader(target.state.url, Int(clamping: target.identity.size)) }
            DispatchQueue.main.async { apply(read) }
        }
    }
}
