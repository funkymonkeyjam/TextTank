// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum DocumentMonitorStatus: Equatable {
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
final class DocumentMonitor {
    static let maximumBytes = 32 * 1024 * 1024
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
    deinit { timer?.invalidate() }
    func start(_ document: TextDocument) throws {
        precondition(Thread.isMainThread)
        guard document.fileURL != nil, document.editor.window != nil else {
            throw WorkspaceError.invalid("Monitoring requires an open, saved document.")
        }
        stop()
        self.document = document
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
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
    struct Inspection {
        let status: DocumentMonitorStatus
        /// A settled sample that a later poll may reuse, or nil.
        let sample: FileSample?
        let readFile: Bool
    }
    /// `known` is an earlier settled sample of the same file. While the file's metadata still
    /// equals its signature, the file holds the bytes that gave its digest and is not read.
    static func inspect(_ url: URL, expected: String?, known: FileSample? = nil, now: Int64? = nil) -> Inspection {
        do {
            if let known, let signature = known.signature,
                try WorkspaceStore.signature(ofRegularFileAt: url, maximumBytes: maximumBytes) == signature
            {
                return Inspection(
                    status: known.digest == expected ? .unchanged : .changed, sample: known, readFile: false)
            }
            let sample = try WorkspaceStore.sample(ofRegularFileAt: url, maximumBytes: maximumBytes, now: now)
            return Inspection(
                status: sample.digest == expected ? .unchanged : .changed,
                sample: sample.signature == nil ? nil : sample, readFile: true)
        } catch let error as POSIXError where error.code == .ENOENT {
            return Inspection(status: .missing, sample: nil, readFile: false)
        } catch WorkspaceError.tooLarge {
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
        guard let url = document.diskURL, document.editor.window != nil else {
            stop()
            return
        }
        let baseline = document.originalDiskFingerprint, revision = document.editor.revision, token = generation
        let reusable = known.flatMap { $0.url == url ? $0.sample : nil }
        inFlight = true
        // The document is main-thread only, so the worker's block holds it weakly: its last
        // reference must never be dropped on the worker.
        DispatchQueue.global(qos: .utility).async { [weak self, weak document] in
            let result = Self.inspect(url, expected: baseline, known: reusable)
            DispatchQueue.main.async { [weak self, weak document] in
                guard let self, self.generation == token else { return }
                self.inFlight = false
                self.known = result.sample.map { (url, $0) }
                if result.readFile { self.fileReads += 1 } else if result.sample != nil { self.metadataOnlyPolls += 1 }
                guard let document, let current = self.document, current === document,
                    current.editor.window != nil
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
        }
    }
    func reload(expectedRevision: UInt) throws {
        precondition(Thread.isMainThread)
        guard let document, document.editor.window != nil, document.editor.revision == expectedRevision,
            !document.isDocumentEdited
        else {
            throw WorkspaceError.invalid("The monitored document changed or has unsaved edits. Its text was preserved.")
        }
        try document.reload(using: document.format.encoding)
        publish(.unchanged)
        poll()
    }
}
