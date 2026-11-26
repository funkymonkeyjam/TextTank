// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import WebKit

/// The web view of a preview. It differs from `WKWebView` in two ways: Undo and Redo pass on
/// to the preview pane, which sends them to the document, and its context menu offers only Copy.
final class PreviewWebView: WKWebView {
    private nonisolated static let passedOn: Set<String> = ["undo:", "redo:"]
    private static let keptMenuItems: Set<String> = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink"]

    // WebKit owns this hit region even when it unregisters its drag types. Accept only files
    // here and own the entire incoming AppKit session. A read-only preview has no incoming
    // WebKit edits or navigation. Outbound drags of a selection still use WebKit's source API.
    private let fileDrop = WorkspaceFileDrop()

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes([.fileURL])
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        WorkspaceFileDrop.operation(sender, in: self)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) {}
    override func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {}
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        WorkspaceFileDrop.operation(sender, in: self) == .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDrop.capture(sender, in: self)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { fileDrop.finish() }
    override func draggingEnded(_ sender: NSDraggingInfo) { fileDrop.finish() }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        if let selector, Self.passedOn.contains(NSStringFromSelector(selector)) { return false }
        return super.responds(to: selector)
    }

    /// Reload, Download Linked File, Open Link in New Window and the rest would start loads the
    /// preview never makes; they are removed instead of being offered and then refused (DS-21).
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items where !Self.keptMenuItems.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        super.willOpenMenu(menu, with: event)
    }
}

/// Receives a clicked link from the application's own script in the preview page. The web
/// view's content controller keeps this object, so it refers to the presenter weakly.
private final class PreviewLinkReceiver: NSObject, WKScriptMessageHandler {
    weak var presenter: PreviewWebPresenter?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let address = message.body as? String else { return }
        presenter?.openClickedLink(URL(string: address))
    }
}

/// Receives the place a rendered Markdown page was scrolled to, from the application's own
/// script. Like the link receiver it is kept by the content controller.
private final class PreviewScrollReceiver: NSObject, WKScriptMessageHandler {
    weak var presenter: PreviewWebPresenter?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        presenter?.pageWasScrolled(message.body)
    }
}

private final class PreviewSelectionReceiver: NSObject, WKScriptMessageHandler {
    weak var presenter: PreviewWebPresenter?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        presenter?.receivedSelection(message)
    }
}

/// Shows rendered Markdown, static HTML and SVG in one web view per tab.
///
/// The web view runs no page script, keeps no website data, and can load nothing but the preview
/// scheme, which `PreviewSchemeHandler` answers. It is created on first use and only once the
/// rule list that blocks every other load is ready. Every navigation is decided by
/// `PreviewNavigationPolicy`.
///
/// A click on an `http`, `https` or `mailto` link is caught by the application's own script
/// before the web view starts a navigation, and handed to the person's browser. The web view
/// would otherwise open a connection to the link's server while it asked whether to navigate.
/// Only a pointer press and release on the link opens it. A page can take the keyboard focus for
/// a link by itself (`autofocus`), so Return on a focused link opens nothing (DS-97).
@MainActor final class PreviewWebPresenter: NSObject, WKNavigationDelegate {
    /// The view to place in the pane. It holds the web view once there is one.
    let view = NSView()
    private(set) var webView: PreviewWebView?
    let handler = PreviewSchemeHandler()

    /// A sentence to show instead of the page, or nil when the page is shown.
    var onUnavailable: ((String?) -> Void)?
    /// The counts of blocked, not-run and missing things for the page that is showing changed.
    var onSummaryChanged: ((String?) -> Void)?
    /// The web content process ended; what was showing is gone and must be rendered again.
    var onContentLost: (() -> Void)?
    /// The web view now exists and can take the keyboard.
    var onWebViewCreated: (() -> Void)?

    /// The page waiting for the rule list or for the scroll position of the page before it.
    private var waiting: (page: PreviewPage, documentURL: URL?)?
    private var isReadingScroll = false
    private var pageURL: URL?
    private var startingOwnLoad = false
    private var navigating = false
    private var restoreScroll: CGPoint?
    /// The block that was at the top of the page before this one, in that page's map, and how
    /// far through it the top was. Set only when the page was scrolled away from its start.
    private var restoreAnchor: (map: PreviewScrollMap, position: PreviewScrollMap.Position)?

    // MARK: Following the source (rendered Markdown only)

    /// The map of the page that is showing, once it has finished loading. Nil while a page
    /// loads, and for HTML and SVG, which are not followed.
    private(set) var scrollMap: PreviewScrollMap?
    /// The map to scroll the page by: `scrollMap`, but only while the page it belongs to is the
    /// last one given. While a newer page waits or loads, the page that is showing is on its
    /// way out and is left where it is.
    var settledScrollMap: PreviewScrollMap? { isSettled ? scrollMap : nil }
    /// A person scrolled the page, which is now at this place of `scrollMap`. Never called for
    /// a scroll the application made itself, nor while the page is not being followed.
    var onScrolled: ((PreviewScrollMap.Position) -> Void)?
    /// A page finished loading. `restored` is the place of its map that was put back at the
    /// top because the same block was there in the page before it; nil for a page that starts
    /// at its top or has no map.
    var onPageLoaded: ((_ restored: PreviewScrollMap.Position?) -> Void)?
    /// True while the tab wants the page's scrolling reported (Both, with sync on).
    private var isFollowed = false
    /// Names the page and the moment reporting was switched on. A report carries it back, so one
    /// from an earlier page or an earlier switching-on is dropped. Zero is never used.
    private(set) var followGeneration = 0
    private var accessibilityName = ""

    /// What the checks read. Counters and a short list of addresses; nothing of the page.
    struct CheckRecord {
        /// The most recent navigation decisions, newest last, at most sixteen.
        var recentDecisions: [(url: URL?, decision: PreviewNavigationPolicy.Decision)] = []
        /// Pages loaded since the presenter was made, and loads that finished or failed.
        var loadCount = 0
        var finishedCount = 0
        /// Times the web content process ended.
        var contentLostCount = 0
        /// Scroll reports from the page that were accepted, and ones that were dropped because
        /// they were not three numbers naming this page and a place its map has.
        var acceptedScrollReports = 0
        var rejectedScrollReports = 0
        /// Times the application scrolled the page to a place of its map.
        var scrollCommands = 0
    }
    private(set) var checkRecord = CheckRecord()
    /// True when nothing is waiting or loading: what the web view shows is the last page given.
    var isSettled: Bool { waiting == nil && !navigating && !isReadingScroll }

    override init() {
        super.init()
        handler.onCountsChanged = { [weak self] in self?.publishSummary() }
    }

    /// Shows `page`. `documentURL` is the saved document's location, or nil for an untitled
    /// document, which may load no local file.
    func show(_ page: PreviewPage, documentURL: URL?) {
        selectionWork?.cancel()
        waiting = (page, documentURL)
        PreviewContentRules.shared.whenSettled { [weak self] in self?.loadWaitingPage() }
        if case .compiling = PreviewContentRules.shared.state { onUnavailable?(PreviewMessages.notReady) }
    }

    private func loadWaitingPage() {
        // A page that is still loading finishes first; `settleNavigation` then comes back here.
        guard waiting != nil, !isReadingScroll, !navigating else { return }
        guard case .ready(let rules) = PreviewContentRules.shared.state else {
            // Fail closed: without the rule list no page is loaded.
            waiting = nil
            onUnavailable?(PreviewMessages.unavailable)
            return
        }
        let webView = self.webView ?? makeWebView(rules: rules)
        guard pageURL != nil else {
            startLoad(in: webView)
            return
        }
        // Remember where the page before this one was scrolled to: the offset, and for rendered
        // Markdown the block at the top, which is what the next page is scrolled to so that an
        // edit above it does not move what is being read. This is the application's own script
        // in its own world; it runs although page scripts are switched off.
        isReadingScroll = true
        let mapBefore = scrollMap
        let source =
            mapBefore == nil
            ? "[window.scrollX, window.scrollY]"
            : "[window.scrollX, window.scrollY].concat((\(Self.syncObject) && \(Self.syncObject).place()) || [])"
        webView.evaluateJavaScript(source, in: nil, in: .defaultClient) {
            [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isReadingScroll = false
                self.restoreScroll = nil
                self.restoreAnchor = nil
                if case .success(let value) = result, let numbers = value as? [Double], numbers.count >= 2,
                    numbers.allSatisfy(\.isFinite)
                {
                    self.restoreScroll = CGPoint(x: numbers[0], y: numbers[1])
                    // A page still at its start stays there: text typed above the first block
                    // should come into view, not push the page down.
                    if let mapBefore, numbers.count == 4, numbers[1] > 0,
                        let position = Self.position(index: numbers[2], fraction: numbers[3], in: mapBefore)
                    {
                        self.restoreAnchor = (mapBefore, position)
                    }
                }
                if let webView = self.webView { self.startLoad(in: webView) }
            }
        }
    }

    /// A place made from two numbers a script gave, or nil unless they name a block of `map`
    /// and a fraction from 0 to 1.
    private static func position(index: Double, fraction: Double, in map: PreviewScrollMap)
        -> PreviewScrollMap.Position?
    {
        guard index.isFinite, fraction.isFinite, index >= 0, index < Double(map.count),
            index == index.rounded(), (0...1).contains(fraction)
        else { return nil }
        return PreviewScrollMap.Position(block: Int(index), fraction: fraction)
    }

    private func startLoad(in webView: PreviewWebView) {
        guard let next = waiting else { return }
        waiting = nil
        var address = URLComponents()
        address.scheme = PreviewScheme.name
        address.host = "preview"
        address.percentEncodedPath = next.page.pagePath
        guard let url = address.url else { return }
        handler.site = PreviewSchemeHandler.Site(
            page: next.page, resolver: PreviewResourceResolver(documentURL: next.documentURL))
        report = next.page.report
        // Nothing is followed while a page loads: the map belongs to a page that is leaving.
        scrollMap = nil
        followGeneration = 0
        pageURL = url
        startingOwnLoad = true
        navigating = true
        checkRecord.loadCount += 1
        onUnavailable?(nil)
        webView.load(URLRequest(url: url))
    }

    private var report = PreviewContentReport()

    private static let selectionMessageName = "textTankPreviewSelection"

    /// Receives only a small context around each boundary. The browser remembers the live DOM
    /// endpoints in the isolated world, so a reply for a superseded selection cannot be applied.
    static let selectionScript = """
        (() => {
          let serial = 0, dragging = false, last = null, queued = false;
          function endpoint(node, offset, end) {
            if (node.nodeType !== Node.TEXT_NODE) {
              node = node.childNodes[end ? offset - 1 : offset];
              if (!node) return null;
              while (node.nodeType !== Node.TEXT_NODE) {
                node = end ? node.lastChild : node.firstChild;
                if (!node) return null;
              }
              offset = end ? node.length : 0;
            }
            if (!document.body?.contains(node)) return null;
            let top = node;
            while (top.parentNode !== document.body) top = top.parentNode;
            const block = Array.prototype.indexOf.call(document.body.children, top);
            let start = Math.max(0, offset - 24), finish = Math.min(node.length, offset + 24);
            if (start > 0 && /[\\uDC00-\\uDFFF]/.test(node.data[start])) start--;
            if (finish < node.length && /[\\uDC00-\\uDFFF]/.test(node.data[finish])) finish++;
            return {node, offset, top, context: {block,
              before: node.data.slice(start, offset), after: node.data.slice(offset, finish)}};
          }
          function selection() {
            const sel = getSelection();
            if (!sel || sel.rangeCount !== 1 || sel.isCollapsed) return null;
            const r = sel.getRangeAt(0);
            const a = endpoint(r.startContainer, r.startOffset, false), b = endpoint(r.endContainer, r.endOffset, true);
            return a && b ? [a,b] : null;
          }
          const same = (a,b) => a && b && a.every((p,i) => p.node === b[i].node && p.offset === b[i].offset);
          function report() {
            queued = false;
            if (dragging) return;
            const pair = selection();
            if (same(pair,last)) return;
            last = pair; serial++;
            if (pair) window.webkit.messageHandlers.textTankPreviewSelection.postMessage(
              { ticket: serial, bounds: pair.map(p => p.context) });
          }
          const schedule = () => { if (!queued) { queued = true; setTimeout(report, 0); } };
          document.addEventListener('pointerdown', () => { dragging = true; }, true);
          document.addEventListener('pointerup', () => { dragging = false; schedule(); }, true);
          document.addEventListener('pointercancel', () => { dragging = false; }, true);
          document.addEventListener('selectionchange', schedule, true);

          // Parse in the template's inert document. Neither probe is attached to an active
          // document. Compare the DOM path and the entire text node before accepting a mark.
          globalThis.textTankVerifySelection = (ticket, marker, markdown, probes) => {
            if (dragging || ticket !== serial || !same(last,selection())) return null;
            if (probes.length !== 2) return [-1,-1];
            function verify(point, html) {
              const template = document.createElement('template');
              let liveRoot, probeRoot;
              if (markdown) {
                template.innerHTML = html;
                if (template.content.childElementCount !== 1) return -1;
                liveRoot = point.top; probeRoot = template.content.firstElementChild;
              } else {
                const root = template.content.ownerDocument.createElement('html');
                root.innerHTML = html;
                liveRoot = document.body; probeRoot = root.querySelector('body');
              }
              if (!probeRoot || probeRoot.nodeName !== liveRoot.nodeName) return -1;
              const path = [];
              for (let n = point.node; n !== liveRoot; n = n.parentNode) {
                if (!n || path.length > 512) return -1;
                path.push([Array.prototype.indexOf.call(n.parentNode.childNodes, n), n.nodeName]);
              }
              let node = probeRoot;
              for (const [i,name] of path.reverse()) {
                node = node.childNodes[i]; if (!node || node.nodeName !== name) return -1;
              }
              const pattern = new RegExp(marker + '([0-9]+)Z', 'g');
              let clean = '', from = 0, result = -1, match;
              while ((match = pattern.exec(node.data)) !== null) {
                clean += node.data.slice(from, match.index); from = pattern.lastIndex;
                if (clean.length === point.offset) {
                  if (result !== -1) return -1;
                  result = Number(match[1]);
                }
              }
              return clean + node.data.slice(from) === point.node.data ? result : -1;
            }
            return last.map((p,i) => verify(p, probes[i]));
          };
        })()
        """

    private struct SelectionRequest: Decodable, Sendable {
        var ticket: Int
        var bounds: [PreviewSelectionProbe.Endpoint]
    }
    private var selectionWork: Task<Void, Never>?
    var onSelection: (([Range<Int>]) -> Void)?
    var onUnmappedSelection: (() -> Void)?

    fileprivate func receivedSelection(_ message: WKScriptMessage) {
        selectionWork?.cancel()
        guard message.frameInfo.isMainFrame, !view.isHidden, isSettled,
            let page = handler.site?.page, page.selectionSource != nil,
            let address = pageURL, message.frameInfo.request.url == address,
            JSONSerialization.isValidJSONObject(message.body),
            let data = try? JSONSerialization.data(withJSONObject: message.body), data.count <= 4096,
            let request = try? JSONDecoder().decode(SelectionRequest.self, from: data),
            request.bounds.count == 2, request.ticket > 0
        else { return }
        let marker = "TTSEL" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "Q"
        let work = Task.detached(priority: .userInitiated) {
            request.bounds.compactMap { PreviewSelectionProbe.make($0, page: page, marker: marker) }
        }
        selectionWork = Task { [weak self] in
            let probes = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self, !self.view.isHidden,
                self.pageURL == address, self.isSettled, let webView = self.webView
            else { return }
            do {
                let reply = try await webView.callAsyncJavaScript(
                    "return globalThis.textTankVerifySelection(ticket, marker, markdown, probes)",
                    arguments: [
                        "ticket": request.ticket, "marker": marker, "markdown": page.scrollMap != nil,
                        "probes": probes.map(\.html)
                    ], in: nil, contentWorld: .defaultClient)
                guard !Task.isCancelled, !self.view.isHidden, self.isSettled, self.pageURL == address,
                    let indexes = reply as? [Int], indexes.count == 2
                else { return }
                guard probes.count == 2, probes[0].positions.indices.contains(indexes[0]),
                    probes[1].positions.indices.contains(indexes[1])
                else { self.onUnmappedSelection?(); return }
                let start = probes[0].positions[indexes[0]], end = probes[1].positions[indexes[1]]
                if start < end { self.onSelection?([start..<end]) } else { self.onUnmappedSelection?() }
            } catch { /* The page or the selection went away. */  }
        }
    }

    private static let linkMessageName = "textTankPreviewLink"
    /// Runs in the application's own script world, which page scripts being off does not affect.
    /// It stops every activation of an external link from navigating, and reports the link's
    /// address only when a pointer was pressed and released on that same link. An activation
    /// from the keyboard (Return on a focused link) has no press before it and a click count of
    /// zero, and is not reported: a page can focus a link by itself with `autofocus`.
    static let linkScript = """
        (function () {
          var pressed = null;
          function linkOf(event) {
            return event.target && event.target.closest ? event.target.closest('a, area') : null;
          }
          document.addEventListener('mousedown', function (event) { pressed = linkOf(event); }, true);
          function activate(event) {
            var link = linkOf(event);
            var wasPressed = link !== null && link === pressed && event.detail > 0;
            pressed = null;
            if (!link) { return; }
            // An SVG link's `href` is an animated string, also when written as `xlink:href`.
            var written = link.href && typeof link.href === 'object' ? link.href.baseVal : link.getAttribute('href');
            if (written === null || written === undefined) { return; }
            var address;
            try { address = new URL(String(written), document.baseURI).href; } catch (error) { return; }
            if (/^(https?|mailto):/i.test(address)) {
              event.preventDefault();
              event.stopPropagation();
              if (wasPressed) { window.webkit.messageHandlers.\(linkMessageName).postMessage(address); }
            }
          }
          document.addEventListener('click', activate, true);
          document.addEventListener('auxclick', activate, true);
        })();
        """

    private static let syncMessageName = "textTankPreviewSync"
    private static let syncObject = "globalThis.textTankPreviewSync"
    /// Runs in the application's own script world, like the link script, and only for rendered
    /// Markdown does anything call it. It never changes the page and loads nothing.
    ///
    /// The top-level blocks are the children of `<body>`, in the order of the page's
    /// `PreviewScrollMap`. `place` finds the block at the top of the window by binary search;
    /// `show` scrolls a block to the top, at once (never animated, so Reduce Motion needs no
    /// separate case). Scrolling is reported only while `arm` has been given a number, once for
    /// each scroll event (the web view sends at most one for each frame it draws), and never
    /// for the position `show` itself just set. A report is three numbers: the number `arm` was
    /// given, a block and a fraction. No timer is used, so the last report is never late.
    static let syncScript = """
        (function () {
          var armed = 0, expected = null;
          function blocks() { return document.body ? document.body.children : []; }
          function top(list, index) { return list[index].getBoundingClientRect().top + window.scrollY; }
          function extent(list, index) {
            var start = top(list, index);
            var end = index + 1 < list.length
              ? top(list, index + 1) : list[index].getBoundingClientRect().bottom + window.scrollY;
            return [start, Math.max(start, end)];
          }
          function place() {
            var list = blocks(), low = 0, high = list.length - 1, y = window.scrollY;
            if (high < 0) { return null; }
            while (low < high) {
              var middle = (low + high + 1) >> 1;
              if (top(list, middle) <= y) { low = middle; } else { high = middle - 1; }
            }
            var range = extent(list, low), span = range[1] - range[0];
            var fraction = span > 0 ? (y - range[0]) / span : 0;
            return [low, Math.min(1, Math.max(0, fraction))];
          }
          function show(index, fraction, left) {
            var list = blocks();
            if (!(index >= 0 && index < list.length)) { return false; }
            var range = extent(list, index);
            var y = index === 0 && fraction === 0 ? 0 : range[0] + (range[1] - range[0]) * fraction;
            window.scrollTo({ left: left === undefined ? window.scrollX : left, top: y, behavior: 'instant' });
            expected = window.scrollY;
            return true;
          }
          window.addEventListener('scroll', function () {
            if (!armed) { return; }
            if (expected !== null) {
              if (Math.abs(window.scrollY - expected) < 1) { return; }
              expected = null;
            }
            var at = place();
            if (at) { window.webkit.messageHandlers.\(syncMessageName).postMessage([armed, at[0], at[1]]); }
          }, { passive: true });
          \(syncObject) = {
            place: place,
            show: show,
            arm: function (generation, count) {
              armed = generation > 0 && blocks().length === count ? generation : 0;
              return armed > 0;
            }
          };
        })();
        """

    /// Starts or stops reporting how the page is scrolled. It takes effect for the page that is
    /// showing and for every page loaded after it.
    func setFollowed(_ followed: Bool) {
        guard followed != isFollowed else { return }
        isFollowed = followed
        armIfFollowed()
    }

    /// Tells the script whether to report, and with which number. The script checks that the
    /// page has as many blocks as the map; if not, it stays silent and nothing is followed.
    private func armIfFollowed() {
        guard let webView, pageURL != nil else { return }
        if isFollowed, let scrollMap {
            Self.generationCounter += 1
            followGeneration = Self.generationCounter
            webView.evaluateJavaScript(
                "\(Self.syncObject).arm(\(followGeneration), \(scrollMap.count))", in: nil, in: .defaultClient,
                completionHandler: nil)
        } else if followGeneration != 0 {
            followGeneration = 0
            webView.evaluateJavaScript(
                "\(Self.syncObject).arm(0, 0)", in: nil, in: .defaultClient, completionHandler: nil)
        }
    }
    private static var generationCounter = 0

    /// Scrolls the page so that `position` of its map is at the top. The scroll is not animated
    /// and is not reported back. Does nothing while no mapped page is showing.
    func scroll(to position: PreviewScrollMap.Position) {
        guard let webView, let scrollMap = settledScrollMap, scrollMap.blocks.indices.contains(position.block),
            position.fraction.isFinite
        else { return }
        checkRecord.scrollCommands += 1
        let fraction = min(1, max(0, position.fraction))
        webView.evaluateJavaScript(
            "\(Self.syncObject).show(\(position.block), \(fraction))", in: nil, in: .defaultClient,
            completionHandler: nil)
    }

    /// A message from the sync script. Everything about it is checked: it must be exactly three
    /// finite numbers, the first the number this page was armed with, the others a block the
    /// map has and a fraction from 0 to 1. Anything else is dropped.
    fileprivate func pageWasScrolled(_ body: Any) {
        guard isFollowed, followGeneration != 0, let scrollMap, let numbers = body as? [NSNumber],
            numbers.count == 3, !numbers.contains(where: { CFGetTypeID($0) == CFBooleanGetTypeID() }),
            numbers[0].doubleValue == Double(followGeneration),
            let position = Self.position(
                index: numbers[1].doubleValue, fraction: numbers[2].doubleValue, in: scrollMap)
        else {
            checkRecord.rejectedScrollReports += 1
            return
        }
        checkRecord.acceptedScrollReports += 1
        onScrolled?(position)
    }

    /// A link the person pressed and released the pointer on. Only `http`, `https` and `mailto`
    /// addresses are opened (DS-97).
    fileprivate func openClickedLink(_ url: URL?) {
        let decision = PreviewNavigationPolicy.decide(
            url: url, pageURL: pageURL, isOwnLoad: false, isLinkActivation: true, isMainFrame: true)
        note(url, decision)
        if case .openExternally(let address) = decision { RuntimeEnvironment.current.openExternalURL(address) }
    }

    private func note(_ url: URL?, _ decision: PreviewNavigationPolicy.Decision) {
        checkRecord.recentDecisions = Array((checkRecord.recentDecisions + [(url, decision)]).suffix(16))
    }

    private func publishSummary() {
        onSummaryChanged?(
            PreviewMessages.joined([
                PreviewSummary.text(for: report, missingLocalFiles: handler.missingLocalFiles),
                PreviewMessages.refusedLocalFiles(handler.refusedLocalFiles),
                PreviewMessages.broadFolderLocalFiles(handler.broadFolderLocalFiles)
            ]))
    }

    /// The one script world the application's scripts and their message handlers live in. It is
    /// never the page's own world.
    static let scriptWorld = WKContentWorld.defaultClient

    /// Registers the link catcher and the scroll reporter with their message handlers. This is
    /// the only place either is registered. `world` is always `scriptWorld` in the application;
    /// the checks pass the page's world to a throwaway web view to show that their probe would
    /// see a registration there.
    static func installScripts(
        on controller: WKUserContentController, linkReceiver: any WKScriptMessageHandler,
        scrollReceiver: any WKScriptMessageHandler, selectionReceiver: any WKScriptMessageHandler,
        world: WKContentWorld = scriptWorld
    ) {
        controller.add(selectionReceiver, contentWorld: world, name: selectionMessageName)
        controller.addUserScript(
            WKUserScript(source: selectionScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.add(linkReceiver, contentWorld: world, name: linkMessageName)
        controller.addUserScript(
            WKUserScript(source: linkScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.add(scrollReceiver, contentWorld: world, name: syncMessageName)
        controller.addUserScript(
            WKUserScript(source: syncScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    }

    private func makeWebView(rules: WKContentRuleList) -> PreviewWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.userContentController.add(rules)
        let selectionReceiver = PreviewSelectionReceiver()
        selectionReceiver.presenter = self
        let receiver = PreviewLinkReceiver()
        receiver.presenter = self
        let scrollReceiver = PreviewScrollReceiver()
        scrollReceiver.presenter = self
        Self.installScripts(
            on: configuration.userContentController, linkReceiver: receiver, scrollReceiver: scrollReceiver,
            selectionReceiver: selectionReceiver)
        configuration.setURLSchemeHandler(handler, forURLScheme: PreviewScheme.name)
        let created = PreviewWebView(frame: view.bounds, configuration: configuration)
        created.navigationDelegate = self
        created.isInspectable = false
        created.allowsBackForwardNavigationGestures = false
        created.allowsLinkPreview = false
        created.autoresizingMask = [.width, .height]
        created.setAccessibilityLabel(accessibilityName)
        view.addSubview(created)
        webView = created
        onWebViewCreated?()
        return created
    }

    func setAccessibilityName(_ name: String) {
        accessibilityName = name
        webView?.setAccessibilityLabel(name)
    }

    /// The view that takes keyboard focus, when there is one.
    var focusView: NSView? { webView }

    /// Stops loading and lets go of the web view and everything it was serving.
    func tearDown() {
        waiting = nil
        selectionWork?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        handler.site = nil
        handler.onCountsChanged = nil
        pageURL = nil
        navigating = false
        scrollMap = nil
        followGeneration = 0
        isFollowed = false
        onScrolled = nil
        onPageLoaded = nil
        restoreAnchor = nil
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let isOwnLoad = startingOwnLoad && action.navigationType == .other
        // Nothing is opened from here. An external link is opened only by `openClickedLink`,
        // after the link script saw a pointer press on it; a link activation that reaches the
        // web view any other way, such as Return on a link the page focused itself, is cancelled.
        let decision = PreviewNavigationPolicy.decide(
            url: action.request.url, pageURL: pageURL, isOwnLoad: isOwnLoad, isLinkActivation: false,
            isMainFrame: action.targetFrame?.isMainFrame == true)
        note(action.request.url, decision)
        switch decision {
        case .allow:
            if isOwnLoad, action.request.url?.fragment == nil { startingOwnLoad = false }
            decisionHandler(.allow)
        case .cancel, .openExternally:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigating else { return }
        scrollMap = handler.site?.page.scrollMap
        let point = restoreScroll
        let anchor = restoreAnchor
        restoreScroll = nil
        restoreAnchor = nil
        var restored: PreviewScrollMap.Position?
        if let anchor, let point, let scrollMap,
            let block = anchor.map.counterpart(of: anchor.position.block, in: scrollMap)
        {
            // The same block as before goes back to the top, wherever the edit moved it.
            restored = PreviewScrollMap.Position(block: block, fraction: anchor.position.fraction)
            webView.evaluateJavaScript(
                "\(Self.syncObject).show(\(block), \(anchor.position.fraction), \(point.x))", in: nil,
                in: .defaultClient, completionHandler: nil)
        } else if let point {
            webView.evaluateJavaScript(
                "window.scrollTo(\(point.x), \(point.y))", in: nil, in: .defaultClient, completionHandler: nil)
        }
        armIfFollowed()
        settleNavigation()
        onPageLoaded?(restored)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        settleNavigation()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
    ) {
        settleNavigation()
    }

    private func settleNavigation() {
        guard navigating else { return }
        navigating = false
        startingOwnLoad = false
        checkRecord.finishedCount += 1
        publishSummary()
        // A page that arrived while this one was loading is shown next.
        if waiting != nil { loadWaitingPage() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        checkRecord.contentLostCount += 1
        navigating = false
        pageURL = nil
        scrollMap = nil
        followGeneration = 0
        onContentLost?()
    }
}
