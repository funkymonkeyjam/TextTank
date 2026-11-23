// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import WebKit

/// The compiled rule list that blocks every load a preview page could start except loads from
/// the preview scheme. It is compiled once for the application, asynchronously. A web view is
/// created only after it is ready; while it is compiling, or if it cannot be compiled, nothing
/// is loaded at all.
@MainActor final class PreviewContentRules {
    enum State {
        case idle
        case compiling
        case ready(WKContentRuleList)
        case failed
    }

    static let shared = PreviewContentRules()

    /// Block everything, then exempt the one scheme whose handler is in this process.
    static let source = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^\(PreviewScheme.name):"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """
    private static let identifier = "TextTankPreviewRules-1"

    private(set) var state = State.idle
    private var waiting: [@MainActor () -> Void] = []

    /// Calls `body` once the rules are ready or have failed; at once if that is already known.
    /// The first call starts the compilation.
    func whenSettled(_ body: @escaping @MainActor () -> Void) {
        switch state {
        case .ready, .failed:
            body()
        case .compiling:
            waiting.append(body)
        case .idle:
            waiting.append(body)
            compile()
        }
    }

    private func compile() {
        state = .compiling
        // Kept with the application's private files, so an isolated run never writes elsewhere.
        let directory = AppStorage.supportDirectory.appendingPathComponent("PreviewRules", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let store = WKContentRuleListStore(url: directory) else {
            settle(.failed)
            return
        }
        store.compileContentRuleList(forIdentifier: Self.identifier, encodedContentRuleList: Self.source) {
            [weak self] list, _ in
            MainActor.assumeIsolated {
                self?.settle(list.map(State.ready) ?? .failed)
            }
        }
    }

    private func settle(_ result: State) {
        state = result
        let callbacks = waiting
        waiting = []
        callbacks.forEach { $0() }
    }

    /// For checks: puts the rules in a known state without compiling.
    func replaceStateForChecks(_ replacement: State) { settle(replacement) }
}

/// Decides every navigation a preview web view is asked to make. A pure function, so the rule
/// can be checked without a web view.
enum PreviewNavigationPolicy {
    enum Decision: Equatable {
        case allow
        case cancel
        /// A link the person clicked that belongs in their browser or mail application.
        case openExternally(URL)
    }

    private static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// - Parameters:
    ///   - pageURL: the page this web view was last told to load, or nil when there is none.
    ///   - isOwnLoad: true only for the one navigation that the presenter itself just started.
    ///   - isLinkActivation: the person clicked a link (WebKit's `.linkActivated`).
    ///   - isMainFrame: the navigation targets the main frame; false for a subframe or a new window.
    static func decide(url: URL?, pageURL: URL?, isOwnLoad: Bool, isLinkActivation: Bool, isMainFrame: Bool)
        -> Decision
    {
        guard let url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if isLinkActivation, externalSchemes.contains(scheme) { return .openExternally(url) }
        guard isMainFrame, scheme == PreviewScheme.name, let pageURL,
            url.path(percentEncoded: true) == pageURL.path(percentEncoded: true), url.query == nil
        else { return .cancel }
        // The presenter's own load of the page, or a move to an anchor inside that page.
        if url.fragment != nil { return .allow }
        return isOwnLoad ? .allow : .cancel
    }
}

/// Serves a preview page and what it may load. Everything comes from memory or from a file that
/// `PreviewResourceResolver` approved; the URL's host is never looked at.
@MainActor final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    /// What the handler serves until the next render replaces it.
    struct Site {
        var page: PreviewPage
        var resolver: PreviewResourceResolver
    }

    /// Replacing the site makes every address of the previous one unknown and resets the counts.
    var site: Site? {
        didSet {
            missingLocalFiles = 0
            refusedLocalFiles = 0
            servedLocalFiles = []
        }
    }
    /// Local files the current page asked for that do not exist.
    private(set) var missingLocalFiles = 0
    /// Local files the current page asked for that the resolver refused for any other reason.
    private(set) var refusedLocalFiles = 0
    /// Local files served to the current page, as resolved file URLs.
    private(set) var servedLocalFiles: [URL] = []
    /// How many times the page and the image have been served since the handler was made.
    private(set) var pageServeCount = 0
    private(set) var imageServeCount = 0
    /// The bytes last served for the image, for checks.
    private(set) var lastServedImage: Data?
    /// The paths of the most recent requests, newest last, for checks and diagnosis.
    private(set) var recentRequestPaths: [String] = []
    var onCountsChanged: (() -> Void)?

    /// Requests whose file is being read. A request leaves when it is answered or stopped;
    /// WebKit must never be answered after it has stopped a request.
    private var reading: [Int: any WKURLSchemeTask] = [:]
    private var nextRequest = 0

    private enum FileOutcome: Sendable {
        case served(URL, Data, mimeType: String)
        case missing
        case refused
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let site, let url = task.request.url else {
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        let path = url.path(percentEncoded: true)
        recentRequestPaths = Array((recentRequestPaths + [path]).suffix(64))
        if path == site.page.pagePath {
            pageServeCount += 1
            respond(task, url: url, data: site.page.html, mimeType: "text/html; charset=utf-8")
            return
        }
        if let imagePath = site.page.imagePath, let image = site.page.image, path == imagePath {
            imageServeCount += 1
            lastServedImage = image
            respond(task, url: url, data: image, mimeType: "image/svg+xml")
            return
        }
        // Count only what the current page asked for, not a late request from the page before it.
        let fromCurrentPage = task.request.mainDocumentURL?.path(percentEncoded: true) == site.page.pagePath
        guard path.hasPrefix(site.page.pagePath) else {
            // An address above the page, such as "../file.png", is outside the document's folder.
            if fromCurrentPage { note(.refused) }
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let relativePath = String(path.dropFirst(site.page.pagePath.count))
        let resolver = site.resolver
        let request = nextRequest
        nextRequest += 1
        reading[request] = task
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Self.load(relativePath, resolver: resolver)
            await self?.finish(request, url: url, outcome: outcome, counts: fromCurrentPage)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        reading = reading.filter { $0.value !== task }
    }

    private func finish(_ request: Int, url: URL, outcome: FileOutcome, counts: Bool) {
        guard let task = reading.removeValue(forKey: request) else { return }
        switch outcome {
        case .served(let file, let data, let mimeType):
            if counts { servedLocalFiles.append(file) }
            respond(task, url: url, data: data, mimeType: mimeType)
        case .missing:
            if counts { note(.missing) }
            task.didFailWithError(URLError(.fileDoesNotExist))
        case .refused:
            if counts { note(.refused) }
            task.didFailWithError(URLError(.noPermissionsToReadFile))
        }
    }

    private func note(_ outcome: FileOutcome) {
        switch outcome {
        case .missing: missingLocalFiles += 1
        case .refused: refusedLocalFiles += 1
        case .served: return
        }
        onCountsChanged?()
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        let headers = [
            "Content-Type": mimeType, "Content-Length": String(data.count), "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// Resolves and reads one local file. Runs off the main thread. The file is opened without
    /// following a link at its final name and is measured again through the open descriptor, so a
    /// file swapped in after the resolver's answer is not served.
    private nonisolated static func load(_ relativePath: String, resolver: PreviewResourceResolver) -> FileOutcome {
        switch resolver.resolve(requestPath: relativePath) {
        case .denied(.missing): return .missing
        case .denied: return .refused
        case .allowed(let file, let mimeType):
            let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { return .missing }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return .refused }
            let limit = PreviewLimits.standard.maxResourceBytes
            guard status.st_size <= limit else { return .refused }
            do {
                // Nil means the file is empty.
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                return data.count <= limit ? .served(file, data, mimeType: mimeType) : .refused
            } catch {
                return .missing
            }
        }
    }
}
