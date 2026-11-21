import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum DocumentMonitorStatus: Equatable, Sendable {
    case stopped, checking, unchanged, changed, missing, unavailable(String)
    var message: String {
        switch self {
        case .stopped: return "File monitoring stopped."
        case .checking: return "Checking the monitored file…"
        case .unchanged: return "Monitored disk file is unchanged."
        case .changed: return "Monitored disk file changed. Reload is explicit; editor text is preserved."
        case .missing: return "Monitored disk file is missing. Editor text is preserved."
        case .unavailable(let reason): return "File monitoring: " + reason
        }
    }
}

/// Background bounded disk checks; all document/editor access stays on main.
/// Monitoring never edits a document. Reload is a separate explicit action.
/// Each poll looks at the file's metadata first and reads and hashes the file only when the
/// metadata differs from the last settled sample. No descriptor is held between polls.
@MainActor final class DocumentMonitor {
    nonisolated static let maximumBytes = 32 * 1024 * 1024
    /// Polls that had to read the file, and polls answered from metadata alone.
    private(set) var fileReads = 0
    private(set) var metadataOnlyPolls = 0
    /// The last settled sample and the file it was taken from.
    private var known: (url: URL, sample: FileSample)?
    private(set) weak var document: TextDocument?
    private(set) var status: DocumentMonitorStatus = .stopped
    var onStatus: ((DocumentMonitorStatus) -> Void)?
    private var timer: Timer?
    private var generation = UUID()
    private var inFlight = false
    // Browser/test owners and delivery dereferences are main-owned. Workers hold only
    // the Sendable delivery closure, never a temporarily strengthened monitor reference.
    deinit {
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated { timer?.invalidate() }
    }
    func start(_ document: TextDocument) throws {
        precondition(Thread.isMainThread)
        guard document.fileURL != nil, document.isOpen else {
            throw WorkspaceError.invalid("Monitoring requires an open, saved document.")
        }
        stop()
        self.document = document
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            precondition(Thread.isMainThread)
            MainActor.assumeIsolated { self?.poll() }
        }
        publish(.checking)
        poll()
    }
    func stop() {
        precondition(Thread.isMainThread)
        timer?.invalidate()
        timer = nil
        generation = UUID()
        inFlight = false
        document = nil
        known = nil
        publish(.stopped)
    }
    /// The callback hears each change of status once. It has its own label in the browser,
    /// so nothing depends on the same status being published again.
    private func publish(_ value: DocumentMonitorStatus) {
        guard value != status else { return }
        status = value
        onStatus?(value)
    }
    struct Inspection: Sendable {
        let status: DocumentMonitorStatus
        /// A settled sample that a later poll may reuse, or nil.
        let sample: FileSample?
        let readFile: Bool
        /// The observed byte digest and pathname identity, even when the metadata is too fresh for caching.
        var digest: String? = nil
        var identity: FileSignature? = nil
    }
    /// `known` is an earlier settled sample of the same file. While the file's metadata still
    /// equals its signature, the file holds the bytes that gave its digest and is not read.
    nonisolated static func inspect(
        _ url: URL, expected: String?, known: FileSample? = nil, now: Int64? = nil, contentLimit: Int = maximumBytes
    )
        -> Inspection
    {
        do {
            let identity = try WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max)
            if let known, known.signature == identity {
                return Inspection(
                    status: known.digest == expected ? .unchanged : .changed, sample: known, readFile: false,
                    digest: known.digest, identity: identity)
            }
            if identity.size > contentLimit {
                let message =
                    known?.signature == nil
                    ? "File exceeds the 32 MiB monitoring limit; editor text is preserved."
                    : "Disk metadata changed; the file exceeds the 32 MiB content check limit."
                return Inspection(status: .unavailable(message), sample: nil, readFile: false, identity: identity)
            }
            let sample = try WorkspaceStore.sample(ofRegularFileAt: url, maximumBytes: contentLimit, now: now)
            guard try WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: Int.max) == identity else {
                return Inspection(
                    status: .unavailable("The file changed while it was being checked."), sample: nil, readFile: true)
            }
            return Inspection(
                status: sample.digest == expected ? .unchanged : .changed,
                sample: sample.signature == nil ? nil : sample, readFile: true, digest: sample.digest,
                identity: identity)
        } catch  where error.isFileNotFound {
            return Inspection(status: .missing, sample: nil, readFile: false)
        } catch WorkspaceError.fileTooLarge {
            return Inspection(
                status: .unavailable("File exceeds the 32 MiB monitoring limit; editor text is preserved."),
                sample: nil, readFile: false)
        } catch { return Inspection(status: .unavailable(error.localizedDescription), sample: nil, readFile: false) }
    }
    func poll() {
        precondition(Thread.isMainThread)
        guard !inFlight else { return }
        guard let document else {
            if timer != nil { stop() }
            return
        }
        // The location resolved when the document's URL was set, never resolved again here:
        // a link swapped in afterwards is reported, not followed.
        guard let url = document.diskURL, document.isOpen else {
            stop()
            return
        }
        let baseline = document.originalDiskFingerprint, revision = document.editor.revision, token = generation
        let reusable = known.flatMap { $0.url == url ? $0.sample : nil }
        inFlight = true
        // Build the weak UI capture on main. The worker holds only immutable inputs and
        // this Sendable delivery, so it cannot strengthen/release a UI owner on its queue.
        let deliver: @MainActor @Sendable (Inspection) -> Void = { [weak self, weak document] result in
            guard let self, self.generation == token else { return }
            self.inFlight = false
            self.known = result.sample.map { (url, $0) }
            if result.readFile { self.fileReads += 1 } else if result.sample != nil { self.metadataOnlyPolls += 1 }
            guard let document, let current = self.document, current === document,
                current.isOpen
            else {
                self.stop()
                return
            }
            // A save, Save As, reload or edit during the disk check invalidates this
            // sample. The next tick captures the new file and baseline; nothing stale applies.
            guard current.diskURL == url, current.editor.revision == revision,
                current.originalDiskFingerprint == baseline
            else { return }
            self.publish(result.status)
        }
        DispatchQueue.global(qos: .utility).async {
            let result = Self.inspect(url, expected: baseline, known: reusable)
            DispatchQueue.main.async { deliver(result) }
        }
    }

    func reload(expectedRevision: UInt) throws {
        precondition(Thread.isMainThread)
        guard let document, document.isOpen, document.editor.revision == expectedRevision,
            !document.isDocumentEdited
        else {
            throw WorkspaceError.invalid("The monitored document changed or has unsaved edits. Its text was preserved.")
        }
        try document.reload(using: document.format.encoding, rememberEncoding: false)
        publish(.unchanged)
        poll()
    }
}
