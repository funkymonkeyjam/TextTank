// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import UniformTypeIdentifiers

/// Foundation confines coordinate() to one reader thread and explicitly permits cancel() from any thread.
private final class CoordinatedOpenRead: @unchecked Sendable {
    private let coordinator = NSFileCoordinator(filePresenter: nil)

    func read(_ url: URL, using access: (URL) throws -> Void) throws {
        var failure: Error?
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do { try access(coordinatedURL) } catch { failure = error }
        }
        if let error = failure ?? coordinationError { throw error }
    }

    func cancel() { coordinator.cancel() }
}

/// One displayed large open, including subsequent callers waiting on the same file.
@MainActor final class LargeFileOpening: NSObject {
    typealias Completion = (NSDocument?, Bool, Error?) -> Void
    private let url: URL
    let diskURL: URL
    private let type: String
    private let signature: FileSignature
    private let progress: Progress
    private let reader = CoordinatedOpenRead()
    private let controller: TextDocumentController
    private var completions: [Completion] = []
    private var operation: UUID?
    private var timer: Timer?
    private var panel: NSPanel?
    private var indicator: NSProgressIndicator?
    private var committed: NSDocument?
    private var alreadyOpen = false
    private var finished = false

    init(url: URL, diskURL: URL, type: String, signature: FileSignature, controller: TextDocumentController) {
        self.url = url
        self.diskURL = diskURL
        self.type = type
        self.signature = signature
        self.controller = controller
        progress = Progress(totalUnitCount: signature.size)
    }

    func join(_ completion: @escaping Completion) { completions.append(completion) }

    func start() {
        let center = StatusOperationCenter.shared
        operation = center.begin(
            Strings.text("open.large.progress", "Opening the document"),
            cancelLabel:
                Strings.text("open.large.cancel", "Cancel opening the document")
        ) { [weak self] in self?.cancel() }
        if finished {
            if let operation { center.end(operation) }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDisplay() }
        }
        updateDisplay()
        let diskURL = diskURL, type = type, signature = signature, progress = progress, reader = reader
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try reader.read(diskURL) { coordinatedURL in
                    if progress.isCancelled { throw CancellationError() }
                    let prepared = try TextDocument.prepareLargeOpen(
                        coordinatedURL, type: type,
                        signature: signature, progress: progress)
                    try DispatchQueue.main.sync { try self.publish(prepared, from: coordinatedURL) }
                }
                DispatchQueue.main.async { self.finish(error: nil) }
            } catch {
                DispatchQueue.main.async { self.finish(error: error) }
            }
        }
    }

    /// Register the document and file presenter during the coordinated read, as a stock NSDocument open does.
    private func publish(_ prepared: TextDocument.PreparedOpen, from coordinatedURL: URL) throws {
        guard !finished, !progress.isCancelled else { throw CocoaError(.userCancelled) }
        if let existing = controller.document(for: url) {
            alreadyOpen = true
            committed = existing
            return
        }
        guard try WorkspaceStore.signature(ofRegularFileAt: coordinatedURL, maximumBytes: Int.max) == signature,
            TextDocument.canonicalDiskURL(url) == diskURL,
            try WorkspaceStore.signature(ofRegularFileAt: diskURL, maximumBytes: Int.max) == signature
        else { throw CocoaError(.fileReadUnknown) }
        let doc = try TextDocument.withPreparedOpen(prepared, at: url) {
            try controller.makeDocument(withContentsOf: url, ofType: type)
        }
        committed = doc
        controller.addDocument(doc)
        NSFileCoordinator.addFilePresenter(doc)
        controller.noteNewRecentDocumentURL(url)
    }

    @objc private func cancel() {
        guard committed == nil, !finished else { return }
        progress.cancel()
        reader.cancel()
        finish(error: CocoaError(.userCancelled))
    }

    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        if let operation { StatusOperationCenter.shared.end(operation) }
        panel?.orderOut(nil)
        controller.largeOpenFinished(self)
        let document = committed
        if let document {
            document.makeWindowControllers()
            document.showWindows()
        }
        let callbacks = completions
        completions.removeAll()
        controller.finishOpen(url, display: true, document, alreadyOpen, document == nil ? error : nil) {
            opened, existing, failure in
            for (index, completion) in callbacks.enumerated() {
                completion(opened, opened != nil && (existing || index > 0), failure)
            }
        }
    }

    private func updateDisplay() {
        guard let operation, !finished else { return }
        let center = StatusOperationCenter.shared
        let bytes = progress.completedUnitCount
        let finalizing = bytes >= signature.size
        center.update(operation, done: Int(bytes), total: finalizing ? 0 : Int(signature.size))
        guard !finished, center.operation(for: [])?.id == operation else { return }
        let hasEditor = controller.documents.contains {
            ($0 as? TextDocument)?.presentation?.hostWindow?.isVisible == true
        }
        if hasEditor {
            panel?.orderOut(nil)
            return
        }
        if panel == nil { makePanel() }
        indicator?.isIndeterminate = finalizing
        if finalizing { indicator?.startAnimation(nil) } else { indicator?.doubleValue = progress.fractionCompleted }
        if panel?.isVisible == false { panel?.makeKeyAndOrderFront(nil) }
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 104),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = String(format: Strings.text("open.large.title", "Opening “%@”"), url.lastPathComponent)
        panel.isReleasedWhenClosed = false
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.setAccessibilityLabel(Strings.text("open.large.progress", "Opening the document"))
        let cancel = NSButton(title: Strings.text("common.cancel", "Cancel"), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityLabel(Strings.text("open.large.cancel", "Cancel opening the document"))
        guard let content = panel.contentView else { return }
        for control in [bar as NSView, cancel] {
            control.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(control)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            cancel.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        panel.initialFirstResponder = cancel
        panel.center()
        self.panel = panel
        indicator = bar
    }
}

extension TextDocumentController {
    func beginLargeOpen(_ url: URL, display: Bool, completion: @escaping LargeFileOpening.Completion) -> Bool {
        guard url.isFileURL else { return false }
        let key = TextDocument.canonicalDiskURL(url)
        if let active = largeOpens[key] {
            active.join(completion)
            return true
        }
        guard display, document(for: url) == nil,
            let signature = try? WorkspaceStore.signature(ofRegularFileAt: key, maximumBytes: Int(Int32.max)),
            signature.size >= SizePolicy.standard.streamedImportThreshold,
            let type = try? typeForContents(of: url), let contentType = UTType(type),
            contentType.conforms(to: .plainText) || contentType == .json || contentType == .xml
        else { return false }
        let opening = LargeFileOpening(url: url, diskURL: key, type: type, signature: signature, controller: self)
        largeOpens[key] = opening
        opening.join(completion)
        opening.start()
        return true
    }

    func largeOpenFinished(_ opening: LargeFileOpening) {
        let key = opening.diskURL
        if largeOpens[key] === opening { largeOpens.removeValue(forKey: key) }
    }
}
