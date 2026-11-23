// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
import TextTankCore

/// Keeps one tab's preview pane in step with the unsaved text of its document.
///
/// Invariants:
/// - It works only while the tab is live: open, showing Preview or Both, and on screen. When
///   the tab is hidden or returns to Source, pending and running work is cancelled, and nothing
///   is done until the tab is live again; then one render brings a stale preview up to date.
/// - At most one render runs at a time. A newer request cancels the older one.
/// - A render reads one immutable copy of the text taken on the main actor and runs on a
///   background task. Its result is applied only if the tab is still live and the document's
///   revision, preview kind and saved location are the ones the render was started for;
///   otherwise it is dropped.
/// - When the web content process ends, the page is rendered again once. If it ends a second
///   time for the same text, the pane says so and nothing more is done until the text changes.
/// - It never saves, reloads or edits the document and never touches Undo.
@MainActor final class PreviewCoordinator {
    /// What the coordinator needs to know about its tab. All of it is read at the moment of use.
    struct Tab {
        /// The view whose document is previewed. Every view of a document shares its revision.
        var editor: @MainActor () -> TTEditor?
        /// The preview that applies now, or nil when the document has none.
        var kind: @MainActor () -> PreviewKind?
        /// True while the tab is open, shows Preview or Both, and is on screen.
        var isLive: @MainActor () -> Bool
        var documentName: @MainActor () -> String
        /// Where the document is saved, or nil for an untitled document.
        var documentURL: @MainActor () -> URL?
    }

    let pane: PreviewPane
    private let tab: Tab

    /// Makes content from a request. Replaced by checks to make a render slow or observable.
    var renderer: @Sendable (PreviewRequest) -> PreviewContent? = { PreviewRenderer.render($0) }
    /// The delay after an edit. Replaced by checks that need a known interval.
    var debounceInterval: (Int) -> TimeInterval = { PreviewRenderer.debounceInterval(byteCount: $0) }

    /// What the pane shows: the revision, kind and location of the last applied render.
    private var shown: (revision: UInt, kind: PreviewKind, documentURL: URL?)?
    private var debounce: Task<Void, Never>?
    private var render: (work: Task<PreviewContent?, Never>, delivery: Task<Void, Never>)?
    /// Raised for every request, so a result can tell whether it is still the newest.
    private var generation = 0
    /// The revision the scheduled or running render is for.
    private var requestedRevision: UInt?

    /// How many times the web content process ended while the pane showed `revision`.
    private var contentLosses: (revision: UInt, count: Int, at: TimeInterval)?
    /// After this many losses for the same text, the preview stops trying.
    static let contentLossLimit = 2
    /// Losses further apart than this many seconds are unrelated.
    static let contentLossWindow: TimeInterval = 30

    /// Renders started, and results applied to the pane, since the coordinator was made. Read
    /// only by the checks.
    private(set) var renderCount = 0
    private(set) var appliedCount = 0
    /// Seconds the main thread spent applying the last result to the pane (DS-101). Read only by
    /// the checks.
    private(set) var lastApplySeconds = 0.0
    /// True when no render is scheduled or running.
    var isIdle: Bool { debounce == nil && render == nil }
    /// True when the pane shows the document as it is now.
    var isCurrent: Bool {
        guard let shown, let editor = tab.editor(), let kind = tab.kind() else { return false }
        return shown.revision == editor.revision && shown.kind == kind && shown.documentURL == tab.documentURL()
    }

    private static var cachedStylesheet: String?
    /// The bundled stylesheet. Unbundled check processes read it from the repository instead.
    static var stylesheetURL =
        Bundle.main.url(
            forResource: PreviewStylesheet.resourceName, withExtension: PreviewStylesheet.resourceExtension)
    private static var stylesheet: String {
        if let cachedStylesheet { return cachedStylesheet }
        let text = stylesheetURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        cachedStylesheet = text
        return text
    }

    init(pane: PreviewPane, tab: Tab) {
        self.pane = pane
        self.tab = tab
        pane.onContentLost = { [weak self] in self?.contentWasLost() }
    }

    /// The web content process ended. Render again once; a second loss for the same text ends
    /// the attempts with a sentence, so a page that stops the process cannot do so in a loop.
    private func contentWasLost() {
        guard tab.isLive(), let editor = tab.editor(), let kind = tab.kind() else {
            shown = nil
            return
        }
        let revision = editor.revision
        // Only losses close together count: a page that stops the process does so as it loads,
        // while an unrelated loss long after a good render deserves a fresh attempt.
        let now = ProcessInfo.processInfo.systemUptime
        let repeated = contentLosses.map { $0.revision == revision && now - $0.at < Self.contentLossWindow } ?? false
        let count = (repeated ? contentLosses?.count ?? 0 : 0) + 1
        contentLosses = (revision, count, now)
        guard count >= Self.contentLossLimit else {
            shown = nil
            refresh(after: 0)
            return
        }
        cancelWork()
        // Recorded as showing this revision, so nothing renders until the text changes.
        apply(.message(PreviewMessages.stoppedRepeatedly), revision, kind, tab.documentURL())
    }

    // MARK: Triggers

    /// The document's text or state may have changed ("look again").
    func documentStateChanged() {
        guard tab.isLive(), !isCurrent, let editor = tab.editor() else { return }
        // A caret move or another notification for text that is already on its way changes nothing.
        if !isIdle, requestedRevision == editor.revision { return }
        refresh(after: debounceInterval(editor.byteLength))
    }

    /// The tab was shown or hidden, or changed between Source, Preview and Both, or its
    /// document's kind or location changed.
    func tabStateChanged() {
        guard tab.isLive() else {
            cancelWork()
            return
        }
        pane.setDocumentName(tab.documentName())
        if !isCurrent, isIdle { refresh(after: 0) }
    }

    /// Stops everything and releases the pane's presenters. The coordinator is not used again.
    func invalidate() {
        cancelWork()
        pane.tearDown()
    }

    private func cancelWork() {
        generation += 1
        debounce?.cancel()
        debounce = nil
        render?.work.cancel()
        render?.delivery.cancel()
        render = nil
    }

    // MARK: Pipeline

    private func refresh(after delay: TimeInterval) {
        cancelWork()
        requestedRevision = tab.editor()?.revision
        let requested = generation
        debounce = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled, self.generation == requested else { return }
            self.debounce = nil
            self.startRender()
        }
    }

    private func startRender() {
        guard tab.isLive(), let editor = tab.editor(), let kind = tab.kind() else { return }
        let revision = editor.revision
        let documentURL = tab.documentURL()
        let limit = PreviewLimits.standard.maxSourceBytes
        guard editor.byteLength <= limit else {
            // Too large: say so without copying or reading the text.
            apply(.message(PreviewLimit.sourceTooLarge(maxBytes: limit).message), revision, kind, documentURL)
            return
        }
        let request = PreviewRequest(
            kind: kind, source: editor.utf8Data, revision: revision, title: tab.documentName(),
            stylesheet: Self.stylesheet)
        let renderer = self.renderer
        let requested = generation
        renderCount += 1
        let work = Task.detached(priority: .userInitiated) { renderer(request) }
        let delivery = Task { [weak self] in
            let content = await work.value
            guard let self, self.generation == requested else { return }
            self.render = nil
            // Drop a result for text, a kind, a location or a tab state that is no longer the
            // current one. The location decides which local files a page may load, so a page
            // rendered before Save As must not be shown with the folder it had then.
            guard let content, self.tab.isLive(), let editor = self.tab.editor(), EditorLifetime.isOpen(editor),
                editor.revision == revision, self.tab.kind() == kind, self.tab.documentURL() == documentURL
            else {
                if self.tab.isLive(), !self.isCurrent { self.refresh(after: 0) }
                return
            }
            self.apply(content, revision, kind, documentURL)
        }
        render = (work, delivery)
    }

    private func apply(_ content: PreviewContent, _ revision: UInt, _ kind: PreviewKind, _ documentURL: URL?) {
        let started = ProcessInfo.processInfo.systemUptime
        // Recorded first: showing content can move the keyboard focus, which comes back here
        // through the tab's visibility check, and must find the preview already current.
        shown = (revision, kind, documentURL)
        pane.setDocumentName(tab.documentName())
        pane.show(content, documentURL: documentURL)
        appliedCount += 1
        lastApplySeconds = ProcessInfo.processInfo.systemUptime - started
    }
}
