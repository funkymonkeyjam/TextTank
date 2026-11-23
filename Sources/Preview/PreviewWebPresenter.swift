// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import WebKit

/// The web view of a preview. It differs from `WKWebView` in two ways: Undo and Redo pass on
/// to the preview pane, which sends them to the document, and its context menu offers only Copy.
final class PreviewWebView: WKWebView {
    private nonisolated static let passedOn: Set<String> = ["undo:", "redo:"]
    private static let keptMenuItems: Set<String> = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierCopyLink"]

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
    private var accessibilityName = ""

    /// The most recent navigation decisions, newest last, for checks and diagnosis.
    private(set) var recentDecisions: [(url: URL?, decision: PreviewNavigationPolicy.Decision)] = []
    /// Pages loaded since the presenter was made, and loads that finished or failed.
    private(set) var loadCount = 0
    private(set) var finishedCount = 0
    /// Times the web content process ended and the page had to be rendered again.
    private(set) var contentLostCount = 0
    /// True when nothing is waiting or loading: what the web view shows is the last page given.
    var isSettled: Bool { waiting == nil && !navigating && !isReadingScroll }

    override init() {
        super.init()
        handler.onCountsChanged = { [weak self] in self?.publishSummary() }
    }

    /// Shows `page`. `documentURL` is the saved document's location, or nil for an untitled
    /// document, which may load no local file.
    func show(_ page: PreviewPage, documentURL: URL?) {
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
        // Remember where the page before this one was scrolled to. This is the application's own
        // script in its own world; it runs although page scripts are switched off.
        isReadingScroll = true
        webView.evaluateJavaScript("[window.scrollX, window.scrollY]", in: nil, in: .defaultClient) {
            [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isReadingScroll = false
                if case .success(let value) = result, let pair = value as? [Double], pair.count == 2 {
                    self.restoreScroll = CGPoint(x: pair[0], y: pair[1])
                } else {
                    self.restoreScroll = nil
                }
                if let webView = self.webView { self.startLoad(in: webView) }
            }
        }
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
        pageURL = url
        startingOwnLoad = true
        navigating = true
        loadCount += 1
        onUnavailable?(nil)
        webView.load(URLRequest(url: url))
    }

    private var report = PreviewContentReport()

    private static let linkMessageName = "textTankPreviewLink"
    /// Runs in the application's own script world, which page scripts being off does not affect.
    /// It stops an external link from navigating and reports its address instead.
    private static let linkScript = """
        (function () {
          function report(event) {
            var link = event.target && event.target.closest ? event.target.closest('a[href], area[href]') : null;
            if (!link) { return; }
            var address = String(link.href);
            if (/^(https?|mailto):/i.test(address)) {
              event.preventDefault();
              event.stopPropagation();
              window.webkit.messageHandlers.\(linkMessageName).postMessage(address);
            }
          }
          document.addEventListener('click', report, true);
          document.addEventListener('auxclick', report, true);
        })();
        """

    /// A link the person clicked. Only `http`, `https` and `mailto` addresses are opened (DS-97).
    fileprivate func openClickedLink(_ url: URL?) {
        let decision = PreviewNavigationPolicy.decide(
            url: url, pageURL: pageURL, isOwnLoad: false, isLinkActivation: true, isMainFrame: true)
        note(url, decision)
        if case .openExternally(let address) = decision { RuntimeEnvironment.current.openExternalURL(address) }
    }

    private func note(_ url: URL?, _ decision: PreviewNavigationPolicy.Decision) {
        recentDecisions = Array((recentDecisions + [(url, decision)]).suffix(64))
    }

    private func publishSummary() {
        onSummaryChanged?(
            PreviewMessages.joined([
                PreviewSummary.text(for: report, missingLocalFiles: handler.missingLocalFiles),
                PreviewMessages.refusedLocalFiles(handler.refusedLocalFiles)
            ]))
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
        let receiver = PreviewLinkReceiver()
        receiver.presenter = self
        configuration.userContentController.add(receiver, contentWorld: .defaultClient, name: Self.linkMessageName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.linkScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
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
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        handler.site = nil
        handler.onCountsChanged = nil
        pageURL = nil
        navigating = false
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let isOwnLoad = startingOwnLoad && action.navigationType == .other
        let decision = PreviewNavigationPolicy.decide(
            url: action.request.url, pageURL: pageURL, isOwnLoad: isOwnLoad,
            isLinkActivation: action.navigationType == .linkActivated,
            isMainFrame: action.targetFrame?.isMainFrame == true)
        note(action.request.url, decision)
        switch decision {
        case .allow:
            if isOwnLoad, action.request.url?.fragment == nil { startingOwnLoad = false }
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally(let url):
            // The person clicked this link; opening it is their explicit choice (DS-97).
            decisionHandler(.cancel)
            RuntimeEnvironment.current.openExternalURL(url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let point = restoreScroll {
            restoreScroll = nil
            webView.evaluateJavaScript(
                "window.scrollTo(\(point.x), \(point.y))", in: nil, in: .defaultClient, completionHandler: nil)
        }
        settleNavigation()
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
        finishedCount += 1
        publishSummary()
        // A page that arrived while this one was loading is shown next.
        if waiting != nil { loadWaitingPage() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        contentLostCount += 1
        navigating = false
        pageURL = nil
        onContentLost?()
    }
}
