// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import TextTankCore
import EditorBridge

@MainActor final class MergeController {
    enum Outcome { case none, applied, noChange, copied, exported, cancelled, failed }
    private weak var comparison: CompareController?
    private(set) var destination: CompareSide?
    private var selectInitialChanges: Bool
    private(set) var selectedBlocks = Set<Int>()
    private var selectionStamp: UUID?
    private(set) var isBusy = false
    private(set) var isCommitting = false
    private(set) var appliedAwaitingComparison = false
    private(set) var lastOutcome = Outcome.none
    private(set) var sheet: MergeSelectionSheet?
    private var operation = UUID(), token = ReviewCancellation()
    private var task: Task<Void, Never>?
    private var savePanel: NSSavePanel?
    /// Explicit capabilities; checks inject owned boards/panels, never the owner's clipboard/files.
    var choosePatchFile: ((NSWindow) async -> URL?)?
    var makeSavePanel: () -> NSSavePanel = { NSSavePanel() }
    var publishClipboard: (String) -> Bool = { text in
        guard let board = RuntimeEnvironment.current.generalPasteboard() else { return false }
        board.clearContents()
        return board.setString(text, forType: .string)
    }
    var workHooks = ReviewDiffHooks()
    var stagePatchOutput:
        @Sendable (Data, URL, PreparedFileIdentity, ReviewCancellation) async throws -> PreparedPrivateFile = {
            bytes, url, expected, cancellation in
            try await Task.detached {
                try PrivateFileStore.prepareOutput(
                    bytes, to: url, expectedTarget: expected,
                    isCancelled: { cancellation.isCancelled })
            }.value
        }
    var rawComparison = true
    init(comparison: CompareController, destination: CompareSide? = nil) {
        self.comparison = comparison
        self.destination = destination
        selectInitialChanges = destination != nil
    }
    var interruptionDetail: String {
        appliedAwaitingComparison
            ? "Applied changes remain in the destination. Show Destination to use Undo, or refresh the comparison."
            : "No document was changed."
    }
    private func input(_ side: CompareSide) -> CompareDocumentInput? {
        guard let source = side == .original ? comparison?.original : comparison?.modified,
            case .document(let input) = source.input
        else { return nil }
        return input
    }
    func canChoose(_ side: CompareSide) -> Bool {
        guard let input = input(side), let (doc, editor) = try? input.capture.resolve(),
            !editor.readOnly, (try? input.validateMetadata()) != nil
        else { return false }
        return input.selection == nil || input.origin.map { EditorLifetime.document(for: $0) === doc } == true
    }
    private var ready: Bool { comparison?.readyForMerge == true && !isBusy && rawComparison }
    func validationReason(_ command: CompareCommand) -> String? {
        if canPerform(command) { return nil }
        if isBusy { return "Wait for the current operation or cancel it." }
        if sheet != nil && CompareCommand.patchCommands.contains(command) {
            return "Finish selecting changes before exporting."
        }
        if !rawComparison { return "A complete, unfiltered comparison is required." }
        if comparison?.outOfDate == true {
            return "The comparison is out of date. Refresh it before applying or exporting."
        }
        if comparison?.readyForMerge != true { return "Wait for a complete comparison and its presentation." }
        if command == .applySelected { return selectionSummary }
        return "Choose an open, editable destination document."
    }
    func commandHint(_ command: CompareCommand) -> String {
        if let reason = validationReason(command) { return reason }
        if command == .applySelected, let destination {
            return String(
                format: "Apply selected changes to %@. Applying does not save the document.",
                destinationTitle(destination))
        }
        if CompareCommand.patchCommands.contains(command) {
            return "Export the complete Original to Modified comparison, including all changes, as UTF-8 text."
        }
        return command.title
    }
    private var admitted: Bool {
        guard let side = destination, let parent = input(side)?.capture.snapshot,
            let p = comparison?.projection, selectionStamp == comparison?.comparisonStamp
        else { return false }
        return MergeCore.selectionFits(
            changes: p.changes, destination: side,
            parentByteLength: parent.bytes.count, selected: selectedBlocks)
    }
    func canPerform(_ command: CompareCommand) -> Bool {
        guard let comparison, !comparison.isClosed else { return false }
        if command == .showDestination {
            guard !isBusy, let side = destination, let input = input(side),
                let (doc, _) = try? input.capture.resolve()
            else { return false }
            return input.selection == nil || input.origin.map { EditorLifetime.document(for: $0) === doc } == true
        }
        guard ready else { return false }
        switch command {
        case .chooseDestination, .selectChanges: return canChoose(.original) || canChoose(.modified)
        case .selectAllChanges:
            return destination.map(canChoose) == true && comparison.projection?.changes.blocks.isEmpty == false
        case .clearChangeSelection: return !selectedBlocks.isEmpty
        case .applySelected: return destination.map(canChoose) == true && admitted
        case .exportPatch, .copyPatch: return sheet == nil
        default: return false
        }
    }
    @discardableResult func chooseDestination(_ side: CompareSide) -> Bool {
        guard ready, canChoose(side) else { return false }
        destination = side
        selectedBlocks.removeAll()
        selectionStamp = comparison?.comparisonStamp
        updateSelection()
        return true
    }
    @discardableResult func setSelection(_ values: Set<Int>) -> Bool {
        guard ready, let side = destination, canChoose(side), let p = comparison?.projection,
            values.count <= 100_000, values.allSatisfy({ p.changes.blocks.indices.contains($0) })
        else { return false }
        selectionStamp = comparison?.comparisonStamp
        selectedBlocks = values
        updateSelection()
        return true
    }
    func destinationTitle(_ side: CompareSide) -> String {
        let source = side == .original ? comparison?.original : comparison?.modified
        return String(
            format: side == .original ? "Original: %@" : "Modified: %@", source?.displayName ?? "Closed source")
    }
    var selectionSummary: String {
        guard let side = destination, let source = side == .original ? comparison?.original : comparison?.modified
        else {
            return "Choose a destination document, then select changes."
        }
        let name = (side == .original ? "Original: " : "Modified: ") + source.displayName
        if !selectedBlocks.isEmpty && !admitted {
            return String(
                format: "The selected changes exceed the application limits. Select fewer changes for %@.", name)
        }
        if selectedBlocks.count == 1 { return String(format: "1 change selected. Destination: %@.", name) }
        return String(format: "%d changes selected. Destination: %@.", selectedBlocks.count, name)
    }
    private func updateSelection() {
        sheet?.refresh()
        comparison?.window?.toolbar?.validateVisibleItems()
        comparison?.showStatus(selectionSummary)
    }
    func perform(_ command: CompareCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .chooseDestination, .selectChanges: showSelectionSheet()
        case .selectAllChanges:
            if let indices = comparison?.projection?.changes.blocks.indices { _ = setSelection(Set(indices)) }
        case .clearChangeSelection: _ = setSelection([])
        case .applySelected: applySelected()
        case .showDestination:
            guard let side = destination, let input = input(side), let (_, editor) = try? input.capture.resolve() else {
                return
            }
            EditorLifetime.activate(input.selection == nil ? editor : (input.origin ?? editor))
        case .copyPatch: copyPatch()
        case .exportPatch: exportPatch()
        default: break
        }
    }
    func represents(_ projection: CompareProjection) -> Bool {
        ready && comparison?.projection?.original.id == projection.original.id
            && comparison?.projection?.modified.id == projection.modified.id
    }
    func showSelectionSheet() {
        guard canPerform(.selectChanges), sheet == nil, let comparison, let window = comparison.window else { return }
        let value = MergeSelectionSheet(mergeOwner: self, projection: comparison.projection!)
        sheet = value
        window.beginSheet(value.window!)
    }
    func sheetDismissed(_ value: MergeSelectionSheet, cancelled: Bool) {
        guard sheet === value else { return }
        sheet = nil
        if cancelled {
            selectedBlocks.removeAll()
            updateSelection()
        }
    }
    func resultReplaced() {
        selectedBlocks.removeAll()
        selectionStamp = nil
        sheet?.dismiss(cancelled: false)
        if isBusy { cancelWork() }
    }
    func presentationCompleted() {
        if selectInitialChanges, ready, let blocks = comparison?.projection?.changes.blocks {
            selectInitialChanges = false
            if blocks.count <= 100_000 { _ = setSelection(Set(blocks.indices)) }
        }
        if comparison?.original?.isStale == false && comparison?.modified?.isStale == false {
            appliedAwaitingComparison = false
        }
    }
    func sourceInvalidated() {
        selectedBlocks.removeAll()
        selectionStamp = nil
        sheet?.dismiss(cancelled: false)
        if isBusy { cancelWork() }
    }
    func cancelWork() {
        let prior = operation
        operation = UUID()
        token.cancel()
        task?.cancel()
        savePanel?.cancel(nil)
        savePanel = nil
        comparison?.service?.cancelAuxiliary(prior)
        if isBusy && !appliedAwaitingComparison { lastOutcome = .cancelled }
        isBusy = false
        selectedBlocks.removeAll()
        selectionStamp = nil
        sheet?.dismiss(cancelled: false)
    }
    func applySelected() { begin(.applySelected) }
    func copyPatch() { begin(.copyPatch) }
    func exportPatch() { begin(.exportPatch) }

    private func validate(
        _ comparison: CompareController, _ p: CompareProjection, stamp: UUID, job: UUID,
        a: CompareSource, b: CompareSource
    ) throws {
        guard !comparison.isClosed, operation == job, !token.isCancelled, !Task.isCancelled else {
            throw MergeFailure(.cancelled)
        }
        guard rawComparison, comparison.readyForMerge, comparison.comparisonStamp == stamp,
            comparison.projection?.original.id == p.original.id, comparison.projection?.modified.id == p.modified.id
        else {
            throw MergeFailure(.incomplete)
        }
        try a.validate()
        try b.validate()
        guard !a.isStale, !b.isStale else { throw MergeFailure(.revisionChanged) }
    }
    func retryPatch(_ command: CompareCommand) {
        guard CompareCommand.patchCommands.contains(command) else { return }
        begin(command, allowance: .extended)
    }
    private func begin(_ command: CompareCommand, allowance: CompareTimeAllowance = .standard) {
        guard canPerform(command), let comparison, let service = comparison.service,
            let a = comparison.original, let b = comparison.modified, let p = comparison.projection
        else { return }
        comparison.clearRetry()
        let side = destination, chosen = side.flatMap(input), selected = selectedBlocks.sorted()
        let stamp = comparison.comparisonStamp, job = UUID()
        let hooks = workHooks, stage = stagePatchOutput
        sheet?.dismiss(cancelled: false)
        operation = job
        token = ReviewCancellation()
        let cancellation = token
        isBusy = true
        lastOutcome = .none
        selectedBlocks.removeAll()
        selectionStamp = nil
        comparison.showStatus(
            command == .applySelected ? "Preparing selected changes…" : "Preparing the complete patch…")
        comparison.window?.toolbar?.validateVisibleItems()
        service.enqueueAuxiliary(job) { [weak self, weak comparison] finished in
            guard let self, let comparison, !comparison.isClosed, self.operation == job else {
                finished()
                return
            }
            self.task = Task { [weak self, weak comparison] in
                defer { finished() }
                guard let self, let comparison else { return }
                do {
                    try self.validate(comparison, p, stamp: stamp, job: job, a: a, b: b)
                    if command == .applySelected {
                        guard let side, let chosen, self.canChoose(side) else { throw MergeFailure(.readOnly) }
                        let request = ReviewRequest(capture: chosen.capture)
                        let plan = try await MergeCore.plan(
                            original: a.snapshot, modified: b.snapshot, changes: p.changes,
                            destination: side, parent: chosen.capture.snapshot, slice: chosen.selection,
                            selected: selected, token: cancellation, hooks: hooks)
                        try self.validate(comparison, p, stamp: stamp, job: job, a: a, b: b)
                        try chosen.validateMetadata()
                        guard self.canChoose(side), let handle = request.issue(edits: plan.proposal.edits) else {
                            throw MergeFailure(.readOnly)
                        }
                        // Same actor turn: no await, prompt, selection or focus between guards and apply.
                        self.isCommitting = true
                        let result = handle.apply(preparingChange: service.prepareSelectedChange)
                        if result == .applied {
                            self.appliedAwaitingComparison = true
                            self.lastOutcome = .applied
                            comparison.markMergeOutOfDate("Changes applied. Recomputing remaining changes…")
                        }
                        self.isCommitting = false
                        switch result {
                        case .rejected(let reason): throw MergeFailure(reason)
                        case .noChange:
                            self.lastOutcome = .noChange
                            self.isBusy = false
                            comparison.showStatus("No text changes were needed.")
                            return
                        case .applied: break
                        }
                        // Fresh parent capture; keep the opposite captured value, with no external reads.
                        let fresh = try self.freshInput(chosen, plan: plan)
                        let source = try await self.sourceAfterApply(fresh)
                        guard self.operation == job, !comparison.isClosed, !cancellation.isCancelled else { return }
                        try fresh.validateMetadata()
                        let opposite = side == .original ? b : a
                        let retained: CompareSource
                        if case .savedFile(let saved) = opposite.input,
                            saved.parent.capture.snapshot.document?.documentID
                                == fresh.capture.snapshot.document?.documentID
                        {
                            retained = CompareSource(
                                snapshot: opposite.snapshot, input: .savedFile(try saved.reboundAfterKnownApply(fresh)))
                        } else {
                            try opposite.validate()
                            guard !opposite.isStale else { throw MergeFailure(.revisionChanged) }
                            retained = opposite
                        }
                        self.isBusy = false
                        comparison.recomputeAfterMerge(
                            side == .original ? source : retained, side == .original ? retained : source)
                    } else {
                        let bytes = try await UnifiedPatch.write(
                            original: a.snapshot, modified: b.snapshot,
                            changes: p.changes, policy: allowance.patchPolicy, token: cancellation, hooks: hooks,
                            raw: self.rawComparison)
                        try self.validate(comparison, p, stamp: stamp, job: job, a: a, b: b)
                        if command == .copyPatch {
                            guard let text = ReviewUTF8.text(bytes), Data(text.utf8) == bytes else {
                                throw MergeFailure(.invalidText)
                            }
                            try self.validate(comparison, p, stamp: stamp, job: job, a: a, b: b)
                            guard self.publishClipboard(text) else { throw CompareOpenFailure.clipboard }
                            self.lastOutcome = .copied
                            comparison.showStatus(
                                bytes.isEmpty
                                    ? "No differences. An empty patch was copied."
                                    : "The complete patch was copied to the clipboard.")
                        } else {
                            guard let window = comparison.window else { throw MergeFailure(.closed) }
                            guard let url = await self.chooseURL(window) else { throw MergeFailure(.cancelled) }
                            try self.validate(comparison, p, stamp: stamp, job: job, a: a, b: b)
                            try self.protectSources(url, a: a, b: b)
                            let expected = try PreparedFileIdentity.capture(url)
                            let staged = try await stage(bytes, url, expected, cancellation)
                            defer { staged.cancel() }
                            // No actor hop between final source/job checks and the short rename commit.
                            try self.validate(comparison, p, stamp: stamp, job: job, a: a, b: b)
                            try self.protectSources(url, a: a, b: b)
                            try staged.commit()
                            self.lastOutcome = .exported
                            comparison.showStatus(
                                bytes.isEmpty
                                    ? "No differences. An empty patch file was exported."
                                    : "The complete patch file was exported. Editor Undo does not remove the file.")
                        }
                        self.isBusy = false
                    }
                } catch {
                    guard self.operation == job, !comparison.isClosed else { return }
                    self.isCommitting = false
                    self.isBusy = false
                    if self.appliedAwaitingComparison {
                        comparison.markMergeOutOfDate(
                            "Changes were applied, but the comparison could not be updated. Show Destination to use Undo, or refresh."
                        )
                    } else if (error as? MergeFailure)?.reason == .cancelled || error is CancellationError {
                        self.lastOutcome = .cancelled
                        comparison.showStatus("The operation was cancelled. No document was changed.")
                    } else {
                        self.lastOutcome = .failed
                        if let failure = error as? MergeFailure, failure.budget == .time {
                            comparison.showStatus("The patch time limit was reached. No patch was published.")
                            if allowance == .standard { comparison.offerPatchRetry(command) }
                        } else {
                            comparison.showStatus(Self.message(error))
                        }
                        comparison.pollSources()
                    }
                }
                comparison.window?.toolbar?.validateVisibleItems()
            }
        }
    }
    private func freshInput(_ prior: CompareDocumentInput, plan: MergePlan) throws -> CompareDocumentInput {
        let (doc, editor) = try prior.capture.resolve()
        guard doc.loadEpoch == prior.capture.snapshot.document?.loadEpoch,
            doc.format == prior.capture.snapshot.format, editor.statusInfo.eol == prior.insertionMode,
            !editor.readOnly
        else { throw MergeFailure(.revisionChanged) }
        if prior.selection != nil {
            guard let origin = prior.origin, EditorLifetime.document(for: origin) === doc else {
                throw CompareOpenFailure.originClosed
            }
        }
        let capture = try ReviewSnapshotCapture.document(editor)
        guard capture.snapshot.bytes == plan.projectedParent else { throw MergeFailure(.bytesChanged) }
        let range = prior.selection.map { $0.lowerBound..<($0.lowerBound + plan.mergedSliceLength) }
        return try CompareDocumentInput(
            capture: capture, origin: prior.selection == nil ? editor : prior.origin, range: range)
    }
    private func sourceAfterApply(_ input: CompareDocumentInput) async throws -> CompareSource {
        let parent = input.capture.snapshot
        let snapshot: TextSnapshot
        if let range = input.selection {
            snapshot = try await Task.detached {
                try TextSnapshot(
                    bytes: parent.bytes.subdata(in: range), source: .freeText(UUID()),
                    label: parent.label + " selection", format: parent.format)
            }.value
        } else {
            snapshot = parent
        }
        return CompareSource(snapshot: snapshot, input: .document(input))
    }
    private func chooseURL(_ window: NSWindow) async -> URL? {
        if let choosePatchFile { return await choosePatchFile(window) }
        let panel = makeSavePanel()
        panel.title = "Export Unified Patch"
        panel.message =
            "Export the complete Original to Modified comparison as UTF-8 editor text. All changes and original line endings are included."
        panel.nameFieldStringValue = "comparison.patch"
        savePanel = panel
        let url: URL? = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { continuation.resume(returning: response == .OK ? panel.url : nil) }
            }
        }
        savePanel = nil
        return url
    }
    private func protectSources(_ destination: URL, a: CompareSource, b: CompareSource) throws {
        try PrivateFileStore.validateLocalURL(destination)
        let canonical = destination.standardizedFileURL.resolvingSymlinksInPath()
        var target = stat()
        let exists = Darwin.lstat(canonical.path, &target) == 0
        for source in [a, b] {
            if let captured = source.snapshot.capturedFileIdentity, exists,
                captured.device == Int64(target.st_dev), captured.inode == target.st_ino
            {
                throw ProtectedPatchSource()
            }
            var urls: [URL] = []
            switch source.input {
            case .file(let url, _): urls = [url]
            case .savedFile(let saved): urls = [saved.url]
            case .document(let input):
                let (doc, _) = try input.capture.resolve()
                urls = [doc.diskURL, doc.fileURL].compactMap { $0 }
            default: break
            }
            for url in urls {
                var info = stat()
                guard canonical != url.standardizedFileURL.resolvingSymlinksInPath(),
                    !(exists && Darwin.lstat(url.standardizedFileURL.resolvingSymlinksInPath().path, &info) == 0
                        && target.st_dev == info.st_dev
                        && target.st_ino == info.st_ino)
                else {
                    throw ProtectedPatchSource()
                }
            }
        }
    }
    private struct ProtectedPatchSource: Error {}
    private static func message(_ error: Error) -> String {
        if error is ProtectedPatchSource {
            return
                "The patch cannot replace a file being compared. Choose a different destination. No file was changed."
        }
        if let failure = error as? MergeFailure {
            if failure.reason == .budgetExceeded {
                return
                    "The operation exceeded a processing limit. No document was changed and no patch was published. Select fewer changes or use smaller sources."
            }
            if let block = failure.block, (0..<100_000).contains(block) {
                return String(
                    format:
                        "Change %d could not be applied because its text or range changed. No document was changed. Refresh the comparison.",
                    block + 1)
            }
            switch failure.reason {
            case .closed: return "The destination document closed. No document was changed. Choose its source again."
            case .readOnly:
                return
                    "The destination is read-only. No document was changed. Make it editable and refresh the comparison."
            case .revisionChanged, .reloaded, .bytesChanged:
                return "A source changed or was reloaded. No document was changed. Refresh the comparison."
            case .invalidRange, .invalidText:
                return
                    "The selected changes could not be applied safely. No document was changed. Refresh the comparison."
            case .incomplete:
                return
                    "A complete, current, unfiltered comparison is required. No document was changed and no patch was published. Refresh the comparison."
            case .cancelled: return "The operation was cancelled. No document was changed."
            case .alreadyUsed: return "This operation has already finished. Select changes again before applying."
            case .budgetExceeded:
                return
                    "The operation exceeded a processing limit. No document was changed and no patch was published. Use smaller sources."
            }

        }
        if error is PreparedOutputFailure {
            return
                "The patch destination changed or the operation was cancelled. No patch was published. Choose the destination again."
        }
        if error as? CompareOpenFailure == .clipboard {
            return "The patch could not be copied. The clipboard may have changed. No document was changed."
        }
        return (error as? LocalizedError)?.errorDescription ?? CompareService.message(error)
    }
}

/// DS-44/62/70/73: native sheet, virtualized whole-block checkboxes, no custom drawing.
@MainActor
final class MergeSelectionSheet: NSWindowController, CompareWindowScope, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    private weak var mergeOwner: MergeController?
    private let projection: CompareProjection
    let table = NSTableView(), destination = NSPopUpButton()
    private let summary = AnnouncingLabel(wrappingLabelWithString: "")
    private let apply = NSButton(title: CompareCommand.applySelected.title, target: nil, action: nil)
    private let selectAll = NSButton(title: CompareCommand.selectAllChanges.title, target: nil, action: nil)
    private let clear = NSButton(title: CompareCommand.clearChangeSelection.title, target: nil, action: nil)
    private var dismissed = false
    private var acceptsActions: Bool {
        !dismissed && mergeOwner?.sheet === self && mergeOwner?.represents(projection) == true
    }

    init(mergeOwner: MergeController, projection: CompareProjection) {
        self.mergeOwner = mergeOwner
        self.projection = projection
        let panel = ToolPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable])
        super.init(window: panel)
        panel.title = "Select Changes and Destination"
        panel.contentMinSize = NSSize(width: 640, height: 420)
        panel.delegate = self
        panel.animationBehavior = .none
        let root = NSView()
        panel.contentView = root
        let caption = NSTextField(
            wrappingLabelWithString:
                "Selected changes are copied from the opposite side into the chosen document in one Undo step. Applying does not save the document."
        )
        destination.addItems(withTitles: ["Choose Destination", "Original document", "Modified document"])
        destination.autoenablesItems = false
        destination.target = self
        destination.action = #selector(destinationChanged(_:))
        destination.setAccessibilityLabel("Destination document and comparison side")
        table.headerView = nil
        table.rowHeight = 52
        table.usesAlternatingRowBackgroundColors = true
        table.addTableColumn(NSTableColumn(identifier: .init("Change")))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Whole comparison changes to apply")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        for (button, selector) in [
            (selectAll, #selector(all(_:))), (clear, #selector(clear(_:))), (apply, #selector(apply(_:)))
        ] {
            button.target = self
            button.action = selector
        }
        let buttons = NSStackView(views: [selectAll, clear, apply, done, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [caption, destination, summary, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [caption, destination, summary, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            destination.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for button in [selectAll, clear, apply, done, cancel] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            button.setAccessibilityLabel(button.title + " in this comparison")
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        guard let mergeOwner else { return }
        destination.item(at: 1)?.title = mergeOwner.destinationTitle(.original)
        destination.item(at: 2)?.title = mergeOwner.destinationTitle(.modified)
        destination.item(at: 1)?.isEnabled = mergeOwner.canChoose(.original)
        destination.item(at: 2)?.isEnabled = mergeOwner.canChoose(.modified)
        destination.selectItem(
            at: mergeOwner.destination == .original ? 1 : mergeOwner.destination == .modified ? 2 : 0)
        summary.stringValue = mergeOwner.selectionSummary
        summary.setAccessibilityLabel(mergeOwner.selectionSummary)
        apply.isEnabled = mergeOwner.canPerform(.applySelected)
        apply.toolTip = mergeOwner.commandHint(.applySelected)
        apply.setAccessibilityLabel(mergeOwner.commandHint(.applySelected))
        selectAll.isEnabled = mergeOwner.canPerform(.selectAllChanges)
        clear.isEnabled = mergeOwner.canPerform(.clearChangeSelection)
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { projection.changes.blocks.count }
    private func lines(_ range: ReviewByteRange, side: CompareSide) -> String {
        let values = projection.lines(side), name = side == .original ? "Original" : "Modified"
        func index(_ offset: Int) -> Int {
            var lo = 0, hi = values.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if values[mid].range.lower < offset { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        if range.lower == range.upper {
            if values.isEmpty { return name + ": no lines." }
            let at = index(range.lower)
            return at < values.count
                ? String(format: "%@: before line %d.", name, at + 1)
                : String(format: "%@: after line %d.", name, values.count)
        }
        return String(format: "%@: lines %d to %d.", name, index(range.lower) + 1, index(range.upper))
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard projection.changes.blocks.indices.contains(row), let mergeOwner else { return nil }
        let id = NSUserInterfaceItemIdentifier("MergeChange")
        let button = tableView.makeView(withIdentifier: id, owner: self) as? NSButton ?? NSButton()
        button.identifier = id
        button.setButtonType(.switch)
        button.tag = row
        let block = projection.changes.blocks[row]
        let kind: String
        switch block.kind {
        case .insert: kind = "Added in Modified"
        case .delete: kind = "Removed from Modified"
        case .modify: kind = "Changed text"
        }
        button.title = String(
            format: "Change %d: %@.\n%@ %@", row + 1, kind, lines(block.original, side: .original),
            lines(block.modified, side: .modified))
        (button.cell as? NSButtonCell)?.wraps = true
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.checkBox)
        button.setAccessibilityLabel(button.title)
        button.setAccessibilityValue(NSNumber(value: mergeOwner.selectedBlocks.contains(row)))
        button.state = mergeOwner.selectedBlocks.contains(row) ? .on : .off
        button.isEnabled = mergeOwner.destination != nil
        button.target = self
        button.action = #selector(toggled(_:))
        return button
    }
    @objc private func toggled(_ sender: NSButton) {
        guard acceptsActions, let mergeOwner, projection.changes.blocks.indices.contains(sender.tag) else { return }
        var values = mergeOwner.selectedBlocks
        if sender.state == .on { values.insert(sender.tag) } else { values.remove(sender.tag) }
        _ = mergeOwner.setSelection(values)
    }
    @objc private func destinationChanged(_ sender: NSPopUpButton) {
        guard acceptsActions else { return }
        if sender.indexOfSelectedItem > 0 {
            _ = mergeOwner?.chooseDestination(sender.indexOfSelectedItem == 1 ? .original : .modified)
        }
        refresh()
    }
    @objc private func all(_ sender: Any?) { if acceptsActions { mergeOwner?.perform(.selectAllChanges) } }
    @objc private func clear(_ sender: Any?) { if acceptsActions { mergeOwner?.perform(.clearChangeSelection) } }
    @objc private func apply(_ sender: Any?) { if acceptsActions { mergeOwner?.applySelected() } }
    @objc private func done(_ sender: Any?) { dismiss(cancelled: false) }
    @objc private func cancel(_ sender: Any?) { dismiss(cancelled: true) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss(cancelled: true)
        return false
    }
    func dismiss(cancelled: Bool) {
        guard !dismissed, let window else { return }
        dismissed = true
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        window.delegate = nil
        window.close()
        mergeOwner?.sheetDismissed(self, cancelled: cancelled)
    }
}
