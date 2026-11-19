// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import EditorBridge

@MainActor enum CompareCommand: String, CaseIterable {
    case previous, next, sideBySide, unified, linked, collapse, expandAll, whitespace, wrap, refresh, cancel
    var title: String {
        switch self {
        case .previous: return "Previous Change"
        case .next: return "Next Change"
        case .sideBySide: return "Side by Side"
        case .unified: return "Unified"
        case .linked: return "Linked Scrolling"
        case .collapse: return "Collapse Unchanged"
        case .expandAll: return "Expand All Unchanged Lines"
        case .whitespace: return "Show Whitespace"
        case .wrap: return "Wrap Lines"
        case .refresh: return "Refresh Comparison"
        case .cancel: return "Cancel Comparison"
        }
    }
    var symbol: String {
        switch self {
        case .previous: return "chevron.up"
        case .next: return "chevron.down"
        case .sideBySide: return "rectangle.split.2x1"
        case .unified: return "list.bullet"
        case .linked: return "link"
        case .collapse: return "arrow.up.and.down.righttriangle.up.righttriangle.down"
        case .expandAll: return "arrow.up.left.and.arrow.down.right"
        case .whitespace: return "paragraphsign"
        case .wrap: return "arrow.turn.down.left"
        case .refresh: return "arrow.clockwise"
        case .cancel: return "xmark"
        }
    }
}
@MainActor
final class CompareController: NSWindowController, CompareWindowScope, NSWindowDelegate,
    NSToolbarDelegate, NSMenuItemValidation, NSToolbarItemValidation, NSTableViewDataSource, NSTableViewDelegate
{
    static var key: CompareController? { NSApp?.keyWindow?.windowController as? CompareController }
    weak var service: CompareService?
    private(set) var original: CompareSource?
    private(set) var modified: CompareSource?
    private(set) var projection: CompareProjection?
    private(set) var isClosed = false
    private(set) var isBusy = false
    private(set) var outOfDate = false
    private(set) var statusText = ""
    let left = ComparePane(frame: .zero), right = ComparePane(frame: .zero)
    private let split = NSSplitView(), table = ActivatingTableView(), tableScroll = NSScrollView()
    private let sourceLabels = [NSTextField(wrappingLabelWithString: ""), NSTextField(wrappingLabelWithString: "")]
    private let status = AnnouncingLabel(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var navigation = CompareNavigation(count: 0)
    private var unifiedMode = false, linked = true, collapsed = false, whitespace = false, wrapped = false
    private var expanded = Set<Int>()
    private enum TableRow { case segment(Int), fold(Int) }
    private var unifiedRows: [TableRow] = []
    private var changeTops: [Int: Int] = [:], changeTableRows: [Int: Int] = [:]
    private var geometryStamp = UUID()
    private var pending: (CompareSource, CompareSource)?
    private var refreshing = false
    private var retainedFailure: String?
    private var presentationComplete = false
    private struct PreviousPresentation {
        let original: CompareSource, modified: CompareSource, projection: CompareProjection
        let navigation: CompareNavigation, font: NSFont, expanded: Set<Int>
    }
    private var rollback: PreviousPresentation?
    private var rowTops: [Int] = []
    private var rowIndices: [Int] = []
    private var token = ReviewCancellation()
    private var generation = UUID()
    private var worker: Task<Void, Never>?, geometry: Task<Void, Never>?, refreshTask: Task<Void, Never>?
    private var sourceTimer: Timer?
    private var wheelMonitor: Any?
    private var arranging = false
    private var geometryRequested = false
    private var commonFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    var unifiedTableView: NSTableView { table }
    var currentChange: Int? { navigation.current }
    var hasPendingGeometry: Bool { arranging || geometryRequested }
    init(service: CompareService, original: CompareSource, modified: CompareSource) {
        self.service = service
        self.original = original
        self.modified = modified
        let panel = ToolPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680), styleMask: [.titled, .closable, .resizable])
        super.init(window: panel)
        panel.title = "Compare Text"
        panel.listedInWindowMenu = true
        panel.contentMinSize = NSSize(width: 720, height: 420)
        panel.delegate = self
        panel.animationBehavior = .none
        let toolbar = NSToolbar(identifier: "TextTank.Compare")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        panel.toolbar = toolbar
        let root = NSView()
        panel.contentView = root
        let labels = NSStackView(views: sourceLabels)
        labels.orientation = .horizontal
        labels.distribution = .fillEqually
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        left.editor.accessibilityDocumentName = "Original comparison text"
        right.editor.accessibilityDocumentName = "Modified comparison text"
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.setAccessibilityLabel("Cancel comparison computation")
        let bottom = NSStackView(views: [status, progress, cancelButton])
        bottom.orientation = .horizontal
        for view in [labels, split, tableScroll, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            labels.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            labels.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            split.topAnchor.constraint(equalTo: labels.bottomAnchor, constant: 6),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -6),
            tableScroll.topAnchor.constraint(equalTo: split.topAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: split.trailingAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        let column = NSTableColumn(identifier: .init("comparison"))
        column.title = "Original / Modified changes"
        column.width = 2400
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.lineBreakMode = .byTruncatingTail
        table.setAccessibilityLabel("Unified comparison changes")
        table.onActivate = { [weak self] row in self?.activateUnified(row) }
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.isHidden = true
        for (side, pane) in [(CompareSide.original, left), (.modified, right)] {
            pane.onScroll = { [weak self] top in
                guard let self, !self.arranging else { return }
                if self.linked { (side == .original ? self.right : self.left).setTop(top) }
            }
            pane.onResize = { [weak self] in self?.requestGeometry() }
            pane.onFontChange = { [weak self] font in
                guard let self, self.commonFont != font else { return }
                self.commonFont = font
                self.left.editor.comparisonFont = font
                self.right.editor.comparisonFont = font
                self.requestGeometry()
            }
            pane.onExpand = { [weak self] fold in
                self?.expanded.insert(fold)
                self?.requestGeometry()
            }
        }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window, !self.unifiedMode else { return event }
            let point = self.split.convert(event.locationInWindow, from: nil)
            let pane = point.x < self.left.frame.maxX ? self.left : self.right
            if event.type == .scrollWheel, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
                pane.scrollWheel(with: event)
                return nil
            }
            if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                let responder = self.window?.firstResponder as? NSView,
                let pane = [self.left, self.right].first(where: { responder.isDescendant(of: $0.editor) })
            {
                if event.keyCode == 116 {
                    pane.scroll(by: -pane.visibleRows)
                    return nil
                }
                if event.keyCode == 121 {
                    pane.scroll(by: pane.visibleRows)
                    return nil
                }
            }
            return event
        }
        loadSources(original, modified)
        WindowFrames.track(panel, as: "TextTank.Compare")
        sourceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSources() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func loadSources(_ a: CompareSource, _ b: CompareSource) {
        original = a
        modified = b
        if case .document(let input) = a.input, let (_, view) = try? input.capture.resolve() {
            commonFont = view.comparisonFont
        } else {
            commonFont = left.editor.comparisonFont
        }
        left.editor.comparisonFont = commonFont
        right.editor.comparisonFont = commonFont
        for (source, pane) in [(a, left), (b, right)] {
            pane.editor.readOnly = false
            pane.editor.text = ReviewUTF8.text(source.snapshot.bytes) ?? ""
            pane.editor.resetUndoHistory()
            pane.editor.setSavePoint()
            pane.editor.readOnly = true
            pane.isEmpty = source.snapshot.bytes.isEmpty
        }
        updateLabels()
    }
    private func updateLabels() {
        for (i, source) in [original, modified].enumerated() {
            let value = (i == 0 ? "Original: " : "Modified: ") + (source?.label ?? "Closed")
            if sourceLabels[i].stringValue != value {
                sourceLabels[i].stringValue = value
                sourceLabels[i].setAccessibilityLabel(value)
            }
        }
    }
    private func showStatus(_ text: String) {
        statusText = text
        status.stringValue = text
        status.toolTip = text
        status.setAccessibilityLabel(text)
    }
    func showQueued() {
        isBusy = true
        showStatus("Waiting to compare…")
        progress.startAnimation(nil)
        cancelButton.isHidden = false
    }
    func run(job: UUID, engine: any ReviewDiffing, finished: @escaping @MainActor () -> Void) {
        guard !isClosed, let a = pending?.0 ?? original, let b = pending?.1 ?? modified else {
            finished()
            return
        }
        generation = job
        token = ReviewCancellation()
        let cancellation = token
        let x = a.snapshot, y = b.snapshot
        showStatus("Comparing…")
        worker = Task { [weak self] in
            let result = await engine.compare(x, y, policy: .default, token: cancellation, hooks: .init())
            do {
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CompareFailure.cancelled }
                let p: CompareProjection?
                if result.completeness == .complete {
                    p = try await CompareProjection.build(
                        original: x, modified: y, changes: result, token: cancellation)
                } else {
                    p = nil
                }
                guard let self, !self.isClosed, self.generation == job else {
                    finished()
                    return
                }
                try a.validate()
                try b.validate()
                guard !a.isStale, !b.isStale else { throw ReviewRejection.revisionChanged }
                self.isBusy = false
                self.progress.stopAnimation(nil)
                self.cancelButton.isHidden = true
                if let p {
                    if let old = self.projection, let original = self.original, let modified = self.modified,
                        self.presentationComplete
                    {
                        self.rollback = PreviousPresentation(
                            original: original, modified: modified, projection: old, navigation: self.navigation,
                            font: self.commonFont, expanded: self.expanded)
                    }
                    self.unifiedRows = []
                    self.changeTops = [:]
                    self.changeTableRows = [:]
                    self.table.reloadData()
                    self.loadSources(a, b)
                    self.projection = p
                    self.pending = nil
                    self.refreshing = false
                    self.retainedFailure = nil
                    self.expanded.removeAll()
                    self.navigation = CompareNavigation(count: p.changes.blocks.count)
                    self.outOfDate = false
                    self.requestGeometry()
                    self.showResultStatus()
                } else {
                    self.pending = nil
                    self.refreshing = false
                    let reason = "Incomplete comparison. \(Self.reason(result.completeness)) No document was changed."
                    if self.projection != nil {
                        self.outOfDate = true
                        self.retainedFailure = reason
                        self.showResultStatus()
                    } else {
                        self.showStatus(reason)
                    }
                }
            } catch {
                if let self, !self.isClosed, self.generation == job {
                    self.isBusy = false
                    self.progress.stopAnimation(nil)
                    self.cancelButton.isHidden = true
                    self.pending = nil
                    self.refreshing = false
                    if self.projection != nil {
                        self.outOfDate = true
                        self.retainedFailure = CompareService.message(error)
                        self.showResultStatus()
                    } else {
                        self.showStatus(CompareService.message(error))
                    }
                }
            }
            finished()
        }
    }
    static func reason(_ completeness: ReviewCompleteness) -> String {
        switch completeness {
        case .complete: return "Complete."
        case .cancelled: return "Computation was cancelled."
        case .budgetStopped: return "The size, time or work limit was reached."
        }
    }
    private func showResultStatus() {
        guard let p = projection else { return }
        let base =
            p.changes.identical
            ? "Byte-identical text. The decoded text matches byte for byte. File encodings or byte-order marks may differ."
            : String(format: p.changes.blocks.count == 1 ? "1 change." : "%ld changes.", p.changes.blocks.count)
        if outOfDate, let retainedFailure {
            showStatus(
                "Out of date. " + retainedFailure + " The previous captured comparison is shown. Refresh explicitly.")
            return
        }
        showStatus(
            (outOfDate ? "Out of date. Captured comparison: " : "") + base
                + (p.inlineLimited ? " Some changed spans could not be refined; line changes remain visible." : "")
                + (retainedFailure.map { " " + $0 } ?? ""))
    }
    func pollSources() {
        guard !isClosed else { return }
        updateLabels()
        if isBusy && refreshing && pending == nil { return }
        let a = pending?.0 ?? original, b = pending?.1 ?? modified
        if a?.isStale == true || b?.isStale == true {
            outOfDate = true
            if isBusy {
                cancel(nil)
                showStatus("Out of date. A source changed or closed. Refresh explicitly.")
            } else if projection != nil {
                showResultStatus()
            } else {
                showStatus("Out of date. A source changed or closed. Refresh explicitly.")
            }
        }
    }
    @objc func cancel(_ sender: Any?) {
        token.cancel()
        worker?.cancel()
        refreshTask?.cancel()
        geometry?.cancel()
        generation = UUID()
        geometryStamp = UUID()
        isBusy = false
        arranging = false
        geometryRequested = false
        pending = nil
        refreshing = false
        service?.cancelQueued(self)
        progress.stopAnimation(nil)
        cancelButton.isHidden = true
        if let previous = rollback, !isClosed {
            rollback = nil
            loadSources(previous.original, previous.modified)
            projection = previous.projection
            navigation = previous.navigation
            expanded = previous.expanded
            commonFont = previous.font
            left.editor.comparisonFont = commonFont
            right.editor.comparisonFont = commonFont
            retainedFailure = "Refresh cancelled. No document was changed."
            requestGeometry()
        }
        if projection != nil { outOfDate = true }
        showStatus("Comparison cancelled. No document was changed.")
    }
    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        cancel(nil)
        sourceTimer?.invalidate()
        sourceTimer = nil
        if let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
        rollback = nil
        original = nil
        modified = nil
        pending = nil
        projection = nil
        unifiedRows = []
        rowTops = []
        rowIndices = []
        changeTops = [:]
        changeTableRows = [:]
        left.releaseContent()
        right.releaseContent()
        service?.closed(self)
    }
    func requestGeometry() {
        guard !isClosed, projection != nil else { return }
        geometry?.cancel()
        presentationComplete = false
        geometryStamp = UUID()
        let identity = geometryStamp
        geometryRequested = true
        geometry = Task { [weak self] in
            await Task.yield()
            guard let self, !self.isClosed, self.geometryStamp == identity else { return }
            self.geometryRequested = false
            do { try await self.arrange(identity: identity) } catch is CancellationError {} catch CompareFailure
                .cancelled
            {} catch {
                guard !self.isClosed, self.geometryStamp == identity else { return }
                self.arranging = false
                self.progress.stopAnimation(nil)
                self.cancelButton.isHidden = true
                if let previous = self.rollback {
                    self.rollback = nil
                    self.loadSources(previous.original, previous.modified)
                    self.commonFont = previous.font
                    self.left.editor.comparisonFont = previous.font
                    self.right.editor.comparisonFont = previous.font
                    self.projection = previous.projection
                    self.navigation = previous.navigation
                    self.expanded = previous.expanded
                    self.outOfDate = true
                    self.retainedFailure = "The refreshed presentation exceeded its display limit."
                    self.requestGeometry()
                } else {
                    self.unifiedRows = []
                    self.table.reloadData()
                    self.split.isHidden = false
                    self.tableScroll.isHidden = true
                    self.unifiedMode = false
                    self.showStatus(
                        "Incomplete presentation. The display limit was reached. No document was changed. Try turning off Wrap Lines."
                    )
                }
            }
        }
    }
    private func arrange(identity: UUID) async throws {
        guard let p = projection, !isClosed else { return }
        arranging = true
        if rollback != nil {
            split.isHidden = true
            tableScroll.isHidden = true
        }
        progress.startAnimation(nil)
        cancelButton.isHidden = false
        defer {
            if geometryStamp == identity {
                arranging = false
                progress.stopAnimation(nil)
                cancelButton.isHidden = true
                window?.toolbar?.validateVisibleItems()
            }
        }
        let stamp = generation, oldLeft = left.top, oldRight = right.top
        func anchor(_ top: Int) -> (row: Int, subline: Int) {
            var lo = 0, hi = rowTops.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if rowTops[mid] <= top { lo = mid + 1 } else { hi = mid }
            }
            let i = max(0, lo - 1)
            return rowIndices.indices.contains(i) ? (rowIndices[i], max(0, top - rowTops[i])) : (0, 0)
        }
        let anchorA = anchor(oldLeft), anchorB = anchor(oldRight)
        let collapsing = collapsed, expansions = expanded, wrap = wrapped, spaces = whitespace
        var sliceStarted = ProcessInfo.processInfo.systemUptime
        for pane in [left, right] {
            pane.editor.clearComparisonPresentation()
            pane.editor.wrap = wrap
            pane.editor.setComparisonWhitespaceVisible(spaces)
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        var hiddenA = IndexSet(), hiddenB = IndexSet(), tokens: [(row: Int?, fold: Int?)] = []
        var i = 0, foldIndex = 0, operations = 0
        func valid() throws {
            try Task.checkCancellation()
            guard !isClosed, generation == stamp, geometryStamp == identity else { throw CompareFailure.cancelled }
        }
        while i < p.rows.count {
            if collapsing, foldIndex < p.folds.count, i == p.folds[foldIndex].rows.lowerBound,
                !expansions.contains(foldIndex)
            {
                let range = p.folds[foldIndex].rows
                for row in p.rows[range] {
                    if let a = row.original { hiddenA.insert(a) }
                    if let b = row.modified { hiddenB.insert(b) }
                    operations += 1
                    if operations % 512 == 0 || ProcessInfo.processInfo.systemUptime - sliceStarted >= 0.008 {
                        try valid()
                        await Task.yield()
                        sliceStarted = ProcessInfo.processInfo.systemUptime
                    }
                }
                tokens.append((nil, foldIndex))
                i = range.upperBound
                foldIndex += 1
            } else {
                tokens.append((i, nil))
                i += 1
                while foldIndex < p.folds.count && p.folds[foldIndex].rows.upperBound <= i { foldIndex += 1 }
            }
            operations += 1
            if operations % 512 == 0 || ProcessInfo.processInfo.systemUptime - sliceStarted >= 0.008 {
                try valid()
                await Task.yield()
                sliceStarted = ProcessInfo.processInfo.systemUptime
            }
        }
        // Scintilla's synthetic line after a final EOL contributes no source row.
        if let byte = p.original.bytes.last, (byte == 10 || byte == 13), !p.originalLines.isEmpty {
            hiddenA.insert(p.originalLines.count)
        }
        if let byte = p.modified.bytes.last, (byte == 10 || byte == 13), !p.modifiedLines.isEmpty {
            hiddenB.insert(p.modifiedLines.count)
        }
        guard left.editor.setComparisonHiddenLines(hiddenA), right.editor.setComparisonHiddenLines(hiddenB) else {
            throw CompareFailure.invalid
        }
        var gapsA: [Int: Int] = [:], gapsB: [Int: Int] = [:], lastA: Int?, lastB: Int?, leadA = 0, leadB = 0, top = 0
        var folds: [(top: Int, height: Int, count: Int, index: Int)] = [], tops: [Int] = [], indices: [Int] = [],
            changesAt: [Int: Int] = [:]
        var positions: [Int: (top: Int, height: Int)] = [:], foldPositions: [Int: Int] = [:]
        func intersecting(_ spans: [ReviewInlineSpan], line: ReviewByteRange, side: CompareSide) throws -> [TTByteRange]
        {
            func range(_ i: Int) -> ReviewByteRange { side == .original ? spans[i].original : spans[i].modified }
            var lo = 0, hi = spans.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if range(mid).upper <= line.lower { lo = mid + 1 } else { hi = mid }
            }
            var result: [TTByteRange] = [], i = lo
            while i < spans.count && range(i).lower < line.upper {
                guard result.count < 512 else { throw CompareFailure.budget(.output) }
                let r = range(i), a = max(line.lower, r.lower), b = min(line.upper, r.upper)
                if b > a { result.append(TTByteRange(location: a, length: b - a)) }
                i += 1
            }
            return result
        }
        func gap(_ line: Int?, _ count: Int, _ gaps: inout [Int: Int], _ leading: inout Int) throws {
            guard count >= 0 else { throw CompareFailure.invalid }
            if let line {
                let value = (gaps[line] ?? 0) + count
                guard value <= 32760 else { throw CompareFailure.budget(.output) }
                gaps[line] = value
            } else {
                leading += count
            }
        }
        for (n, value) in tokens.enumerated() {
            try valid()
            if let fold = value.fold {
                let height = max(1, Int(ceil(28 / Double(left.lineHeight))))
                folds.append((top, height, p.folds[fold].count, fold))
                foldPositions[fold] = top
                try gap(lastA, height, &gapsA, &leadA)
                try gap(lastB, height, &gapsB, &leadB)
                top += height
            } else if let index = value.row {
                let row = p.rows[index],
                    a = row.original.map { max(1, left.editor.comparisonWrapCount(forLine: $0)) } ?? 0
                let b = row.modified.map { max(1, right.editor.comparisonWrapCount(forLine: $0)) } ?? 0
                let height = max(1, max(a, b))
                tops.append(top)
                indices.append(index)
                positions[index] = (top, height)
                if let line = row.original {
                    lastA = line
                    try gap(line, height - a, &gapsA, &leadA)
                } else {
                    try gap(lastA, height, &gapsA, &leadA)
                }
                if let line = row.modified {
                    lastB = line
                    try gap(line, height - b, &gapsB, &leadB)
                } else {
                    try gap(lastB, height, &gapsB, &leadB)
                }
                if let change = row.change, changesAt[change] == nil { changesAt[change] = top }
                top += height
                if let change = row.change {
                    for (side, line, pane) in [
                        (CompareSide.original, row.original, left), (.modified, row.modified, right)
                    ] {
                        guard let line else { continue }
                        let r = p.lines(side)[line].range
                        let spans = try intersecting(p.inlineSpans[change], line: r, side: side)
                        guard spans.count <= 512,
                            pane.editor.addComparisonHighlights(
                                [TTByteRange(location: r.lower, length: r.upper - r.lower)], inlineRanges: spans,
                                kind: p.changes.blocks[change].kind == .modify ? 2 : side == .original ? 1 : 0)
                        else { throw CompareFailure.budget(.output) }
                    }
                }
            }
            if n % 512 == 0 || ProcessInfo.processInfo.systemUptime - sliceStarted >= 0.008 {
                await Task.yield()
                sliceStarted = ProcessInfo.processInfo.systemUptime
            }
        }
        for (pane, gaps) in [(left, gapsA), (right, gapsB)] {
            for (n, pair) in gaps.enumerated() {
                try valid()
                guard pane.editor.setComparisonGapAfterLine(pair.key, rows: pair.value) else {
                    throw CompareFailure.invalid
                }
                if n % 512 == 0 { await Task.yield() }
            }
        }
        try valid()
        rowTops = tops
        rowIndices = indices
        changeTops = changesAt
        func restored(_ anchor: (row: Int, subline: Int)) -> Int {
            if let point = positions[anchor.row] { return point.top + min(anchor.subline, max(0, point.height - 1)) }
            var lo = 0, hi = p.folds.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if p.folds[mid].rows.upperBound <= anchor.row { lo = mid + 1 } else { hi = mid }
            }
            return foldPositions[lo] ?? 0
        }
        for (pane, leading, anchor) in [(left, leadA, anchorA), (right, leadB, anchorB)] {
            pane.leadingRows = leading
            pane.totalRows = max(1, top)
            pane.foldRows = folds
            pane.setTop(restored(anchor))
        }
        // Segments are bounded off-thread by CompareProjection. Fold lookup is binary;
        // no rows*folds scan and no multi-megabyte text layout on MainActor.
        var result: [TableRow] = [], emitted = Set<Int>(), tableChanges: [Int: Int] = [:], maxBytes = 0
        for (index, segment) in p.segments.enumerated() {
            try valid()
            let row = p.unified[segment.unifiedRow]
            let sourceMap = row.side == .original ? p.originalToRow : p.modifiedToRow
            let position = sourceMap[row.line]
            var lo = 0, hi = p.folds.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if p.folds[mid].rows.upperBound <= position { lo = mid + 1 } else { hi = mid }
            }
            if collapsing, lo < p.folds.count, p.folds[lo].rows.contains(position), !expansions.contains(lo) {
                if emitted.insert(lo).inserted { result.append(.fold(lo)) }
            } else {
                if let change = row.change, tableChanges[change] == nil { tableChanges[change] = result.count }
                result.append(.segment(index))
                maxBytes = max(maxBytes, segment.range.upper - segment.range.lower)
            }
            if index % 512 == 0 || ProcessInfo.processInfo.systemUptime - sliceStarted >= 0.008 {
                await Task.yield()
                sliceStarted = ProcessInfo.processInfo.systemUptime
            }
        }
        try valid()
        unifiedRows = result
        changeTableRows = tableChanges
        let font = commonFont
        table.tableColumns.first?.width = max(
            1000, CGFloat(maxBytes + 120) * ("M" as NSString).size(withAttributes: [.font: font]).width)
        table.reloadData()
        presentationComplete = true
        rollback = nil
        split.isHidden = unifiedMode
        tableScroll.isHidden = !unifiedMode
        window?.toolbar?.validateVisibleItems()
        showResultStatus()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { unifiedRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let p = projection, unifiedRows.indices.contains(row) else { return nil }
        switch unifiedRows[row] {
        case .fold(let index):
            let button = NSButton(
                title: String(format: "Expand %ld unchanged lines", p.folds[index].count), target: self,
                action: #selector(expandTableFold(_:)))
            button.tag = index
            button.setAccessibilityLabel(button.title)
            return button
        case .segment(let index):
            let segment = p.segments[index], value = p.unified[segment.unifiedRow],
                line = p.lines(value.side)[value.line], snapshot = p.snapshot(value.side)
            let end = min(segment.range.upper, line.contentEnd)
            let bytes = snapshot.bytes.subdata(in: segment.range.lower..<max(segment.range.lower, end))
            let text = ReviewUTF8.text(bytes) ?? ""
            let cue: String
            if let change = value.change, p.changes.blocks[change].kind == .modify {
                cue = value.side == .original ? "~ Modified (-)" : "~ Modified (+)"
            } else {
                cue = value.change == nil ? "=" : value.side == .original ? "- Deleted" : "+ Inserted"
            }
            let prefix =
                "\(cue) · \(value.side == .original ? "Original" : "Modified") line \(value.line+1)\(segment.continued ? " (continued)" : "")  "
            let suffix =
                segment.last ? "  [\(line.ending.isEmpty ? "Missing final newline" : line.ending)]" : " [continued]"
            let shown =
                whitespace
                ? text.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\t", with: "→") : text
            let cell =
                (tableView.makeView(withIdentifier: .init("source-row"), owner: self) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            cell.identifier = .init("source-row")
            cell.font = commonFont
            let styled = NSMutableAttributedString(
                string: prefix + shown + suffix, attributes: [.font: commonFont, .foregroundColor: NSColor.labelColor])
            if let change = value.change {
                // A segment contains complete clusters. Byte->UTF16 conversion is bounded to
                // this at-most64KiB cell; original coordinates are never rewritten.
                for span in p.inlineSpans[change] {
                    let r = value.side == .original ? span.original : span.modified
                    let lo = max(segment.range.lower, r.lower), hi = min(end, r.upper)
                    if hi > lo {
                        let preceding = ReviewUTF8.text(snapshot.bytes.subdata(in: segment.range.lower..<lo)) ?? ""
                        let changed = ReviewUTF8.text(snapshot.bytes.subdata(in: lo..<hi)) ?? ""
                        styled.addAttribute(
                            .underlineStyle, value: NSUnderlineStyle.single.rawValue,
                            range: NSRange(
                                location: prefix.utf16.count + preceding.utf16.count, length: changed.utf16.count))
                    }
                }
            }
            let naturalWidth = styled.size().width + 24
            if let column = table.tableColumns.first, naturalWidth > column.width { column.width = naturalWidth }
            cell.attributedStringValue = styled
            cell.setAccessibilityLabel(prefix + text + suffix)
            cell.setAccessibilityHelp("Underlined spans changed within this line.")
            cell.lineBreakMode = .byClipping
            return cell
        }
    }
    @objc private func expandTableFold(_ sender: NSButton) {
        expanded.insert(sender.tag)
        requestGeometry()
    }
    private func activateUnified(_ row: Int) {
        guard unifiedRows.indices.contains(row), let p = projection else { return }
        if case .fold(let fold) = unifiedRows[row] {
            expanded.insert(fold)
            requestGeometry()
            return
        }
        guard case .segment(let index) = unifiedRows[row], let change = p.unified[p.segments[index].unifiedRow].change
        else { return }
        navigation = CompareNavigation(count: p.changes.blocks.count)
        for _ in 0...change { navigation.move(next: true) }
        announcePosition()
    }
    private func announcePosition() {
        guard let current = navigation.current else { return }
        let kind: String
        if let p = projection {
            switch p.changes.blocks[current].kind {
            case .insert: kind = "Inserted lines."
            case .delete: kind = "Deleted lines."
            case .modify: kind = "Modified lines."
            }
        } else {
            kind = ""
        }
        let position = String(format: "Change %ld of %ld. ", current + 1, navigation.count) + kind
        for pane in [left, right] {
            pane.editor.setAccessibilityHelp(
                position
                    + " Plus marks inserted lines, minus marks deleted lines, and tilde marks modified lines. Unified view labels every change."
            )
        }
        Announce.say(position)
        if let top = changeTops[current] {
            left.setTop(top)
            right.setTop(top)
        }
        if unifiedMode, let row = changeTableRows[current] {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }
    @objc func performCompareCommand(_ sender: Any?) {
        let raw =
            (sender as? NSMenuItem)?.representedObject as? String ?? (sender as? NSToolbarItem)?.itemIdentifier.rawValue
            ?? (sender as? NSButton)?.identifier?.rawValue
        guard let raw, let command = CompareCommand(rawValue: raw), enabled(command) else { return }
        perform(command)
    }
    func perform(_ command: CompareCommand) {
        guard enabled(command) else { return }
        switch command {
        case .next:
            navigation.move(next: true)
            announcePosition()
        case .previous:
            navigation.move(next: false)
            announcePosition()
        case .sideBySide, .unified:
            unifiedMode = command == .unified
            split.isHidden = unifiedMode
            tableScroll.isHidden = !unifiedMode
            if unifiedMode, let change = navigation.current, let row = changeTableRows[change] {
                table.scrollRowToVisible(row)
            }
        case .linked: linked.toggle()
        case .collapse:
            collapsed.toggle()
            requestGeometry()
        case .expandAll:
            collapsed = false
            expanded.removeAll()
            requestGeometry()
        case .whitespace:
            whitespace.toggle()
            requestGeometry()
        case .wrap:
            wrapped.toggle()
            requestGeometry()
        case .refresh: refresh()
        case .cancel: cancel(nil)
        }
        window?.toolbar?.validateVisibleItems()
    }
    private func refresh() {
        guard let a = original, let b = modified, let service else { return }
        do {
            let x = try a.refreshInput(), y = try b.refreshInput()
            let stamp = UUID()
            generation = stamp
            token.cancel()
            worker?.cancel()
            geometry?.cancel()
            outOfDate = true
            rollback = nil
            refreshing = true
            isBusy = true
            showStatus("Refreshing…")
            progress.startAnimation(nil)
            cancelButton.isHidden = false
            refreshTask = Task { [weak self, weak service] in
                do {
                    guard let service else { return }
                    let pair = try await service.capturePair(x, y, token: ReviewCancellation())
                    guard let self, !self.isClosed, self.generation == stamp else { return }
                    self.pending = pair
                    service.enqueue(self)
                } catch {
                    if let self, !self.isClosed, self.generation == stamp {
                        self.isBusy = false
                        self.refreshing = false
                        self.pending = nil
                        self.progress.stopAnimation(nil)
                        self.cancelButton.isHidden = true
                        self.retainedFailure = CompareService.message(error)
                        self.showStatus("Out of date. " + CompareService.message(error))
                    }
                }
            }
        } catch { showStatus(CompareService.message(error)) }
    }
    private func enabled(_ command: CompareCommand) -> Bool {
        guard !isClosed else { return false }
        if command == .cancel { return isBusy || arranging }
        if command == .refresh {
            return !isBusy && !hasPendingGeometry && original?.canRetainForRefresh == true
                && modified?.canRetainForRefresh == true
                && (original?.canRefresh == true || modified?.canRefresh == true)
        }
        guard projection != nil, !isBusy, !hasPendingGeometry else { return false }
        switch command {
        case .next: return presentationComplete && navigation.hasNext
        case .previous: return presentationComplete && navigation.hasPrevious
        case .sideBySide, .unified: return presentationComplete
        case .wrap: return !unifiedMode
        default: return true
        }
    }
    private func checked(_ command: CompareCommand) -> Bool {
        switch command {
        case .sideBySide: return !unifiedMode
        case .unified: return unifiedMode
        case .linked: return linked
        case .collapse: return collapsed
        case .whitespace: return whitespace
        case .wrap: return wrapped
        default: return false
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let raw = item.representedObject as? String, let command = CompareCommand(rawValue: raw) else {
            return false
        }
        item.state = checked(command) ? .on : .off
        if command == .refresh, !enabled(command) { item.toolTip = original?.refreshReason ?? modified?.refreshReason }
        return enabled(command)
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let command = CompareCommand(rawValue: item.itemIdentifier.rawValue) else { return false }
        let selected = checked(command)
        item.image = NSImage(
            systemSymbolName: selected ? "checkmark.circle" : command.symbol,
            accessibilityDescription: command.title + (selected ? ", on" : ""))
        item.toolTip = command.title + (selected ? " (on)" : "")
        if command == .refresh, !enabled(command) { item.toolTip = original?.refreshReason ?? modified?.refreshReason }
        return enabled(command)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        CompareCommand.allCases.map { .init($0.rawValue) } + [.flexibleSpace]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [CompareCommand.previous, .next, .sideBySide, .unified, .linked, .collapse, .whitespace, .wrap, .refresh].map {
            .init($0.rawValue)
        }
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let command = CompareCommand(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = command.title
        item.toolTip = command.title
        item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title)
        item.target = self
        item.action = #selector(performCompareCommand(_:))
        return item
    }
}
