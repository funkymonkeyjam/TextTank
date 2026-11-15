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

/// Background bounded disk reads; all document/editor access stays on main.
/// Monitoring never edits a document. Reload is a separate explicit action.
final class DocumentMonitor {
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
        publish(.stopped)
    }
    private func publish(_ value: DocumentMonitorStatus) {
        status = value
        onStatus?(value)
    }
    static func inspect(_ url: URL, expected: String?) -> DocumentMonitorStatus {
        do {
            let data = try WorkspaceStore.readRegularFile(url, maximumBytes: 32 * 1024 * 1024)
            return WorkspaceStore.fingerprint(data) == expected ? .unchanged : .changed
        } catch let error as POSIXError where error.code == .ENOENT { return .missing } catch WorkspaceError.tooLarge {
            return .unavailable("File exceeds the 32 MiB monitoring limit; editor text is preserved.")
        } catch { return .unavailable(error.localizedDescription) }
    }
    func poll() {
        precondition(Thread.isMainThread)
        guard !inFlight else { return }
        guard let document else {
            if timer != nil { stop() }
            return
        }
        guard let url = document.fileURL, document.editor.window != nil else {
            stop()
            return
        }
        let baseline = document.originalDiskFingerprint, revision = document.editor.revision, token = generation
        inFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.inspect(url, expected: baseline)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.inFlight = false
                guard let current = self.document, current === document, current.fileURL == url,
                    current.editor.window != nil
                else {
                    self.stop()
                    return
                }
                // A save/reload/edit during the disk read invalidates this sample.
                // The next tick captures the new baseline; no stale result applies.
                guard current.editor.revision == revision, current.originalDiskFingerprint == baseline else { return }
                self.publish(result)
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
