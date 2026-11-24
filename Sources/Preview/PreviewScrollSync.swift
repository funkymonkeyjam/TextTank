// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
import TextTankCore

/// Keeps the source and the preview of one tab at the same place while the tab shows Both.
///
/// What is followed: rendered Markdown (a source line to a top-level block and back, through
/// the page's `PreviewScrollMap`), delimited text (a line to the row that starts on or before
/// it) and JSON (a line to the row of the value that starts on or before it). HTML and SVG are
/// not followed: nothing ties a place in the rendered page to a source line.
///
/// Invariants:
/// - It observes only while `isEligible` is true: the tab is on screen, shows Both and has a
///   followed kind. Otherwise it holds no observer and the page's script reports nothing.
/// - "Sync scrolling in Both" (`isOn`) is read at every scroll of an eligible tab, so the
///   setting takes effect at once with nothing to apply; while it is off a scroll costs that
///   one read.
/// - One scroll costs a binary search and one scroll of the other side. Nothing is read or
///   measured for the whole document.
/// - A scroll of the source is looked at in the next turn of the main queue, never inside the
///   editor's own callback, and any number of them before that turn count as one. The editor
///   moves its top line while it is still applying an edit made above it; only afterwards do
///   its revision and its lines agree.
/// - A scroll this object makes is never answered: each side remembers the place it was put at
///   and ignores a scroll that leaves it there. No timer is involved.
/// - The preview is scrolled only while it shows the text as it is now. Between an edit and
///   the rendering of it, the lines of the map are not the lines of the text, so a scroll of
///   the source in that time is remembered and followed once the new rendering is showing,
///   and then only if the preview is not already at the source's line. An edit therefore
///   never moves the preview by itself; a caret that an edit took elsewhere does.
/// - Nothing is animated, so Reduce Motion needs no separate case.
/// - It only scrolls. It never moves the selection or the caret, takes the keyboard, edits, or
///   touches Undo or the file.
@MainActor final class PreviewScrollSync {
    /// What the checks read. Counters only.
    struct CheckRecord: Equatable {
        /// Scrolls of the source and of the preview that were looked at while sync was on.
        var sourceTicks = 0
        var previewTicks = 0
        /// Times this object scrolled the preview and the source.
        var previewScrolls = 0
        var sourceScrolls = 0
    }
    private(set) var checkRecord = CheckRecord()

    private weak var pane: PreviewPane?
    /// The tab's source panes. The first is the one the preview scrolls; scrolling any of them
    /// scrolls the preview.
    private let editors: @MainActor () -> [TTEditor]
    private let isEligible: @MainActor () -> Bool
    private let isOn: @MainActor () -> Bool

    private struct SourceWatch {
        weak var editor: TTEditor?
        let token: any NSObjectProtocol
    }
    private var sources: [SourceWatch] = []
    private var rowWatch: (rows: Rows, token: any NSObjectProtocol)?
    private weak var followedPage: PreviewWebPresenter?
    /// The line each source pane had at its top when it was last looked at or put there.
    private var settledSourceLine: [ObjectIdentifier: Int] = [:]
    /// The row the table or tree had at its top when it was last looked at or put there.
    private var settledRow: Int?
    /// True while this object is scrolling a view, for an observer that is called at once.
    private var isScrolling = false
    /// True from a scroll of a source pane until the turn of the main queue that looks at it.
    private var sourceLookScheduled = false
    /// True when the preview shows the document's text as it is now. Set by the coordinator.
    var isPreviewCurrent: @MainActor () -> Bool = { true }
    /// The source pane that scrolled while the preview was behind the text, to be followed
    /// when the preview has caught up.
    private weak var pendingSource: TTEditor?

    /// True while it holds any observer. Read by the checks.
    var isWatching: Bool { !sources.isEmpty || rowWatch != nil || followedPage != nil }

    /// The kinds whose preview follows the source.
    static func follows(_ kind: PreviewKind?) -> Bool {
        switch kind {
        case .markdown, .delimited, .json: return true
        case .html, .svg, nil: return false
        }
    }

    init(
        pane: PreviewPane, editors: @escaping @MainActor () -> [TTEditor],
        isEligible: @escaping @MainActor () -> Bool, isOn: @escaping @MainActor () -> Bool
    ) {
        self.pane = pane
        self.editors = editors
        self.isEligible = isEligible
        self.isOn = isOn
    }

    /// Looks again at whether to follow and at what there is to follow. Called when the tab is
    /// shown or hidden or changes mode, when its document's state changes, and after content is
    /// shown. Cheap when nothing changed.
    func refresh() {
        guard let pane, isEligible() else {
            stop()
            return
        }
        watchSources()
        watchPreview(of: pane)
        // The table or tree has caught up with the text: follow what scrolled meanwhile.
        if rowWatch != nil, let editor = pendingSource, isOn(), isPreviewCurrent() {
            pendingSource = nil
            showInPreview(line: editor.firstVisibleDocumentLine, pane)
        }
    }

    /// Lets go of every observer and tells the page to report nothing.
    func stop() {
        guard isWatching else { return }
        sources.forEach { NotificationCenter.default.removeObserver($0.token) }
        sources = []
        settledSourceLine = [:]
        pendingSource = nil
        unwatchRows()
        unfollowPage()
    }

    // MARK: The source

    private func watchSources() {
        let current = editors()
        guard current.count != sources.count || !zip(current, sources).allSatisfy({ $0 === $1.editor }) else {
            return
        }
        sources.forEach { NotificationCenter.default.removeObserver($0.token) }
        settledSourceLine = [:]
        sources = current.compactMap { editor in
            // Scintilla scrolls a real clip view and already asks it to post this notification.
            guard let clip = Self.clipView(in: editor) else { return nil }
            settledSourceLine[ObjectIdentifier(editor)] = editor.firstVisibleDocumentLine
            let token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
            ) { [weak self] _ in
                precondition(Thread.isMainThread)
                MainActor.assumeIsolated { self?.scheduleSourceLook() }
            }
            return SourceWatch(editor: editor, token: token)
        }
    }

    /// The clip view of the editor's own scroll view: the first scroll view inside it.
    private static func clipView(in editor: TTEditor) -> NSClipView? {
        var level: [NSView] = [editor]
        while !level.isEmpty {
            if let scrollView = level.lazy.compactMap({ $0 as? NSScrollView }).first { return scrollView.contentView }
            level = level.flatMap(\.subviews)
        }
        return nil
    }

    private func scheduleSourceLook() {
        guard !isScrolling, !sourceLookScheduled else { return }
        sourceLookScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.lookAtSources() }
        }
    }

    private func lookAtSources() {
        sourceLookScheduled = false
        guard let pane, !sources.isEmpty else { return }
        guard isEligible() else {
            stop()
            return
        }
        guard isOn() else { return }
        checkRecord.sourceTicks += 1
        for editor in sources.compactMap(\.editor) {
            // While a pane is being resized its lines wrap again; that is not a person scrolling.
            guard !editor.inLiveResize else { continue }
            let line = editor.firstVisibleDocumentLine
            guard settledSourceLine[ObjectIdentifier(editor)] != line else { continue }
            settledSourceLine[ObjectIdentifier(editor)] = line
            guard isPreviewCurrent(), showInPreview(line: line, pane) else {
                pendingSource = editor
                continue
            }
            pendingSource = nil
        }
    }

    /// Puts zero-based `line` at the top of `editor`, without animation, and remembers where
    /// that left it so the scroll is not answered.
    private func scrollSource(_ editor: TTEditor, toLine line: Int) {
        let target = min(max(0, line), max(0, editor.lineCount - 1))
        guard editor.firstVisibleDocumentLine != target else { return }
        isScrolling = true
        editor.scrollTo(documentLine: target, subline: 0)
        isScrolling = false
        settledSourceLine[ObjectIdentifier(editor)] = editor.firstVisibleDocumentLine
        checkRecord.sourceScrolls += 1
    }

    // MARK: The preview

    /// The table or the tree, which are both rows over source lines.
    @MainActor private enum Rows {
        case table(PreviewTablePresenter)
        case tree(PreviewOutlinePresenter)

        var view: NSTableView {
            switch self {
            case .table(let presenter): return presenter.tableView
            case .tree(let presenter): return presenter.outlineView
            }
        }
        var scrollView: NSScrollView {
            switch self {
            case .table(let presenter): return presenter.scrollView
            case .tree(let presenter): return presenter.scrollView
            }
        }
        func sourceLine(ofRow row: Int) -> Int? {
            switch self {
            case .table(let presenter): return presenter.sourceLine(ofRow: row)
            case .tree(let presenter): return presenter.sourceLine(ofRow: row)
            }
        }
        func row(forSourceLine line: Int) -> Int? {
            switch self {
            case .table(let presenter): return presenter.row(forSourceLine: line)
            case .tree(let presenter): return presenter.row(forSourceLine: line)
            }
        }
        /// The first row that is not under the column headers, or nil when there are no rows.
        var topRow: Int? {
            let clip = scrollView.contentView
            let y = max(0, clip.bounds.minY + clip.contentInsets.top)
            let row = view.row(at: NSPoint(x: view.bounds.minX + 1, y: y + 1))
            return row >= 0 ? row : nil
        }
        /// True when nothing has been scrolled away above the first row.
        var isAtTop: Bool {
            let clip = scrollView.contentView
            return clip.bounds.minY + clip.contentInsets.top < 1
        }
    }

    private func watchPreview(of pane: PreviewPane) {
        if let page = pane.webPresenter, !page.view.isHidden {
            unwatchRows()
            if followedPage !== page {
                unfollowPage()
                followedPage = page
                page.onScrolled = { [weak self] position in self?.pageScrolled(to: position) }
                page.onPageLoaded = { [weak self] restored in self?.pageLoaded(restored: restored) }
            }
            page.setFollowed(true)
            return
        }
        unfollowPage()
        let rows: Rows?
        if let table = pane.tablePresenter, !table.scrollView.isHidden {
            rows = .table(table)
        } else if let tree = pane.outlinePresenter, !tree.scrollView.isHidden {
            rows = .tree(tree)
        } else {
            rows = nil
        }
        guard let rows else {
            unwatchRows()
            return
        }
        guard rowWatch?.rows.view !== rows.view else { return }
        unwatchRows()
        let clip = rows.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
        ) { [weak self] _ in
            precondition(Thread.isMainThread)
            MainActor.assumeIsolated { self?.rowsScrolled() }
        }
        rowWatch = (rows, token)
        settledRow = rows.topRow
        // A table or tree that has not been scrolled yet starts where the source is.
        if isOn(), rows.isAtTop, let editor = editors().first {
            showInPreview(line: editor.firstVisibleDocumentLine, pane)
        }
    }

    private func unwatchRows() {
        guard let rowWatch else { return }
        NotificationCenter.default.removeObserver(rowWatch.token)
        self.rowWatch = nil
        settledRow = nil
    }

    private func unfollowPage() {
        guard let page = followedPage else { return }
        followedPage = nil
        page.setFollowed(false)
        page.onScrolled = nil
        page.onPageLoaded = nil
    }

    /// Scrolls whichever presenter is showing so that the block or row of `line` is at its top.
    /// False when there is nothing to scroll yet: a page that is still loading.
    @discardableResult private func showInPreview(line: Int, _ pane: PreviewPane) -> Bool {
        if let page = followedPage {
            guard let position = page.settledScrollMap?.position(forLine: line) else { return false }
            page.scroll(to: position)
            checkRecord.previewScrolls += 1
        } else if let rows = rowWatch?.rows, let row = rows.row(forSourceLine: line) {
            let clip = rows.scrollView.contentView
            var wanted = clip.bounds
            wanted.origin.y = rows.view.rect(ofRow: row).minY - clip.contentInsets.top
            let target = clip.constrainBoundsRect(wanted).origin
            if abs(target.y - clip.bounds.minY) >= 0.5 {
                isScrolling = true
                clip.scroll(to: target)
                rows.scrollView.reflectScrolledClipView(clip)
                isScrolling = false
                checkRecord.previewScrolls += 1
            }
            settledRow = rows.topRow
        }
        return true
    }

    /// A page that starts at its top (the first one, or one loaded again after its content was
    /// lost) is put where the source is. A page that kept the reader's place is left alone,
    /// unless the source scrolled while the page was behind the text and the place that was
    /// kept is not the source's line.
    private func pageLoaded(restored: PreviewScrollMap.Position?) {
        // A page that is already being replaced is left alone; the one after it comes here too.
        guard let pane, isEligible(), isOn(), isPreviewCurrent(), let map = followedPage?.settledScrollMap else {
            return
        }
        guard restored == nil || pendingSource != nil, let editor = pendingSource ?? editors().first else { return }
        pendingSource = nil
        let line = editor.firstVisibleDocumentLine
        if let restored {
            if map.line(for: restored) == line { return }
        } else if line == 0 {
            return
        }
        showInPreview(line: line, pane)
    }

    private func pageScrolled(to position: PreviewScrollMap.Position) {
        guard isEligible() else {
            stop()
            return
        }
        guard isOn() else { return }
        checkRecord.previewTicks += 1
        guard let pane, !pane.inLiveResize, let line = followedPage?.scrollMap?.line(for: position),
            let editor = editors().first
        else { return }
        scrollSource(editor, toLine: line)
    }

    private func rowsScrolled() {
        guard !isScrolling, let rows = rowWatch?.rows else { return }
        guard isEligible() else {
            stop()
            return
        }
        guard isOn() else { return }
        checkRecord.previewTicks += 1
        guard !rows.view.inLiveResize, let top = rows.topRow, top != settledRow else { return }
        settledRow = top
        guard let line = rows.sourceLine(ofRow: top), let editor = editors().first else { return }
        scrollSource(editor, toLine: line)
    }
}
