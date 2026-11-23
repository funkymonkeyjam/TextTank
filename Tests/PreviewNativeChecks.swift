// SPDX-License-Identifier: GPL-3.0-or-later
// Source, Preview and Both: the per-tab preview driven through the real tab adapter, coordinator,
// presenters and web view, against the signed frameworks.
//
// These checks do not depend on the window being key or on an unlocked screen. They drive
// `EditorWindowController` and the preview types directly, wait on explicit completion signals
// (coordinator idle and current, navigation settled) with bounded waits, and read the web
// view through the application's own script world.
import AppKit
import Darwin
import EditorBridge
import NativeSearch
@testable import TextTankCore
@testable import TextTankRuntime
import WebKit

/// A mutable value shared with a completion handler or a background task.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// A TCP listener on 127.0.0.1 with a port chosen by the system. It counts every connection it
/// accepts and answers none, so "the preview made no network request" is an observation.
private final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let accepted: Box<Int>

    init() throws {
        let listening = socket(AF_INET, SOCK_STREAM, 0)
        guard listening >= 0 else { throw CheckStop(description: "listener socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listening, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(listening, 64) == 0 else { throw CheckStop(description: "listener bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listening, $0, &length) }
        }
        guard named == 0 else { throw CheckStop(description: "listener port") }
        _ = fcntl(listening, F_SETFL, O_NONBLOCK)
        let counter = Box(0)
        let reader = DispatchSource.makeReadSource(
            fileDescriptor: listening, queue: DispatchQueue(label: "preview-checks.listener"))
        reader.setEventHandler {
            while true {
                let client = accept(listening, nil, nil)
                guard client >= 0 else { break }
                counter.value += 1
                close(client)
            }
        }
        port = UInt16(bigEndian: address.sin_port)
        descriptor = listening
        source = reader
        accepted = counter
        reader.resume()
    }

    var connections: Int { accepted.value }
    var base: String { "http://127.0.0.1:\(port)" }

    /// Connects once from this process, to prove that a connection is counted.
    func connectOnce() -> Bool {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { return false }
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    func stop() {
        source.cancel()
        close(descriptor)
    }
}

/// Holds a render until the check lets it go, and records what the render saw.
private final class RenderGate: @unchecked Sendable {
    let started = Box(0)
    let open = Box(false)
    let sawCancellation = Box(false)
    let ranOnMainThread = Box(false)
    let seconds = Box(0.0)

    func renderer(holding: Bool) -> @Sendable (PreviewRequest) -> PreviewContent? {
        { [self] request in
            started.value += 1
            if Thread.isMainThread { ranOnMainThread.value = true }
            while holding, !open.value, !Task.isCancelled { usleep(2_000) }
            if Task.isCancelled {
                sawCancellation.value = true
                return nil
            }
            let begin = ProcessInfo.processInfo.systemUptime
            let content = PreviewRenderer.render(request)
            seconds.value = ProcessInfo.processInfo.systemUptime - begin
            return content
        }
    }
}

/// A scheme task that records what the handler answers, so a response can be read without a
/// web view in between. Used on the main thread only.
private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: HTTPURLResponse?
    private(set) var body = Data()
    private(set) var failure: (any Error)?
    private(set) var isDone = false

    init(_ address: String, page: String) {
        var request = URLRequest(url: URL(string: address)!)
        request.mainDocumentURL = URL(string: page)
        self.request = request
    }

    func didReceive(_ response: URLResponse) { self.response = response as? HTTPURLResponse }
    func didReceive(_ data: Data) { body.append(data) }
    func didFinish() { isDone = true }
    func didFailWithError(_ error: any Error) {
        failure = error
        isDone = true
    }
}

@MainActor private final class PreviewCheckContext {
    let isolated: IsolatedSupportDirectory
    init() throws { isolated = try IsolatedSupportDirectory("PreviewNativeProcess") }
}
@MainActor private final class PreviewCheckDelegate: NSObject, NSApplicationDelegate {
    var launched: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ note: Notification) { launched?() }
}

@main @MainActor enum PreviewNativeChecks {
    static func main() {
        do {
            let context = try PreviewCheckContext()
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            PreviewCoordinator.stylesheetURL = TestPaths.resources.appendingPathComponent("Preview/preview.css")
            NativeFixtureEnvironment.install()
            let documents = TextDocumentController(), app = NSApplication.shared, delegate = PreviewCheckDelegate()
            // An accessory application takes neither the Dock nor the keyboard from the person.
            app.setActivationPolicy(.accessory)
            app.delegate = delegate
            delegate.launched = {
                let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
                    MainActor.assumeIsolated { () -> Void in
                        Checks.run("PreviewNativeChecks") {
                            defer {
                                context.isolated.restore()
                                NativeFixtureEnvironment.restore()
                            }
                            check(NSDocumentController.shared === documents, "owned document controller")
                            try run(root: context.isolated.url)
                            Checks.summary { "PASS PreviewNativeChecks: \(Checks.count) native assertions" }
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .default)
            }
            withExtendedLifetime(delegate) { app.run() }
        } catch { Checks.fail("preview native setup: \(error)", file: #filePath, line: #line) }
        Checks.finish("PreviewNativeChecks")
    }

    // MARK: Support

    private static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    @discardableResult
    private static func wait(
        _ label: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        spinUntil(timeout: timeout, label, file: file, line: line) {
            for _ in 0..<32 {
                guard let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) else {
                    break
                }
                NSApp.sendEvent(event)
            }
            return condition()
        }
    }

    /// Lets the run loop turn for a fixed time, for "nothing more happens" observations.
    private static func settle(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private static func write(_ text: String, _ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Opens a saved document in a new tab of the workspace window.
    private static func open(_ url: URL) throws -> (TextDocument, EditorWindowController) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let document = TextDocument()
        document.fileURL = url
        document.fileType = TextDocument.plainTextType
        NSDocumentController.shared.addDocument(document)
        try document.read(from: Data(text.utf8), ofType: TextDocument.plainTextType)
        document.makeWindowControllers()
        document.showWindows()
        let controller = try requireValue(document.presentation, "fixture: tab adapter for \(url.lastPathComponent)")
        return (document, controller)
    }

    private static func open(_ name: String, _ text: String, in folder: URL) throws -> (
        TextDocument, EditorWindowController
    ) {
        try open(write(text, name, in: folder))
    }

    /// Waits until the tab's preview shows the document as it is now and nothing is in flight.
    @discardableResult
    private static func waitCurrent(
        _ controller: EditorWindowController, _ label: String, timeout: TimeInterval = 30,
        file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        wait("preview current: \(label)", timeout: timeout, file: file, line: line) {
            guard let coordinator = controller.previewCoordinator else { return false }
            return coordinator.isIdle && coordinator.isCurrent && (coordinator.pane.webPresenter?.isSettled ?? true)
        }
    }

    /// Runs the application's own script in the web view and returns its value.
    private static func script(_ web: WKWebView?, _ source: String) -> Any? {
        guard let web else { return nil }
        let done = Box(false), value = Box<Any?>(nil)
        web.evaluateJavaScript(source, in: nil, in: .defaultClient) { result in
            if case .success(let got) = result { value.value = got }
            done.value = true
        }
        wait("script result") { done.value }
        return value.value
    }

    private static func pageText(_ controller: EditorWindowController) -> String {
        script(controller.previewCoordinator?.pane.webPresenter?.webView, "document.body.innerText") as? String ?? ""
    }

    private static func replace(_ old: String, with new: String, in editor: TTEditor) throws {
        let text = editor.text
        let range = try requireValue(text.range(of: old), "fixture: text to replace '\(old)'")
        let start = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
        let end = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
        _ = editor.setSelectionAnchor(start, caret: end)
        _ = editor.replaceSelection(new)
    }

    /// With TEXTTANK_PREVIEW_SNAPSHOTS=1, writes pictures of a tab for a person to look at. They
    /// are not compared with anything.
    private static func picture(_ tab: EditorWindowController, _ name: String) {
        guard ProcessInfo.processInfo.environment["TEXTTANK_PREVIEW_SNAPSHOTS"] == "1" else { return }
        func save(_ image: NSBitmapImageRep?, _ suffix: String) {
            guard let data = image?.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: TestPaths.artifacts.appendingPathComponent("preview-\(name)-\(suffix).png"))
        }
        let root = tab.presentationRoot
        root.layoutSubtreeIfNeeded()
        if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: bitmap)
            save(bitmap, "tab")
        }
        if let web = tab.previewCoordinator?.pane.webPresenter?.webView {
            let done = Box(false)
            web.takeSnapshot(with: nil) { image, _ in
                if let tiff = image?.tiffRepresentation { save(NSBitmapImageRep(data: tiff), "page") }
                done.value = true
            }
            wait("snapshot \(name)") { done.value }
        }
    }

    private static let undo = TTEditorCommandIdentifier(rawValue: "undo")
    private static let redo = TTEditorCommandIdentifier(rawValue: "redo")

    // MARK: Run

    static func run(root: URL) throws {
        let priorDelegate = NSApp.delegate, priorServices = EditorServices.current
        let app = AppDelegate()
        NSApp.delegate = app
        app.installEditorServices()
        app.buildMenus()
        let host = app.workspaceWindow
        let window = try requireValue(host.window, "owned workspace window")
        let commands = host.tabCommands
        defer {
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            commands.clearHistory()
            window.orderOut(nil)
            EditorServices.current = priorServices
            NSApp.delegate = priorDelegate
        }
        print("NOTE screen locked: \(screenLocked); these checks do not depend on the window being key")
        let opened = Box<[URL]>([])
        RuntimeEnvironment.dependencies?.openExternalURL = { opened.value.append($0) }
        let listener = try LoopbackListener()
        defer { listener.stop() }

        Checks.section("session record") { try sessionRecord() }
        Checks.section("layout and navigation rules") { layoutAndNavigationRules() }
        Checks.section("listener control") {
            check(listener.connectOnce(), "control: a connection to the listener can be made")
            wait("control connection counted") { listener.connections == 1 }
            check(listener.connections == 1, "control: the listener counts a connection, so zero means none was made")
        }
        // The control connection is the only one any check may cause.
        let allowedConnections = 1

        Checks.section("eligibility and commands") { try eligibility(root: root, app: app, host: host) }
        Checks.section("mode round trip") { try modeRoundTrip(root: root, app: app) }
        Checks.section("unsaved Markdown") { try unsavedMarkdown(root: root, listener: listener) }
        Checks.section("static HTML") { try staticHTML(root: root, listener: listener, opened: opened) }
        Checks.section("scheme handler responses") { try schemeHandlerResponses(root: root) }
        Checks.section("policy header") { try policyHeader(root: root, listener: listener) }
        Checks.section("SVG") { try svg(root: root, listener: listener) }
        Checks.section("delimited text") { try delimited(root: root) }
        Checks.section("JSON") { try json(root: root) }
        Checks.section("staleness and lifetime") { try stalenessAndLifetime(root: root, host: host) }
        Checks.section("close during a render") { try closeMidRender(root: root) }
        Checks.section("delivery guard") { try deliveryGuard(root: root) }
        Checks.section("content process loss") { try contentProcessLoss(root: root) }
        Checks.section("status row of a Preview tab") { try statusRowKeepsPreview(root: root, host: host) }
        Checks.section("narrow pane") { try narrowPane() }
        Checks.section("limits and timing") { try limitsAndTiming(root: root) }
        Checks.section("session capture and restore") { try sessionRestore(root: root, host: host) }
        Checks.section("tab context menu") { try tabContextMenu(root: root, host: host) }
        Checks.section("mark on the tab") { try tabMark(root: root, app: app, host: host) }
        Checks.section("Toggle Preview") { try togglePreview(root: root, app: app, host: host) }
        Checks.section("Open in, per format") { try openInPerFormat(root: root, app: app, host: host) }
        Checks.section("fail closed") { try failClosed(root: root) }
        settle(0.5)
        check(
            listener.connections == allowedConnections,
            "no preview made any network connection in the whole run (listener saw \(listener.connections - allowedConnections))"
        )
        // Last, because it makes connections on purpose: the same listener does see a web view
        // that has no rule list, so the zero above is an observation and not a blind spot.
        Checks.section("listener sees an unprotected web view") {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let unprotected = WKWebView(frame: NSRect(x: 0, y: 0, width: 50, height: 50), configuration: configuration)
            unprotected.loadHTMLString("<img src=\"\(listener.base)/control.png\">", baseURL: nil)
            wait("unprotected web view reaches the listener", timeout: 20) {
                listener.connections > allowedConnections
            }
            check(
                listener.connections > allowedConnections,
                "control: a web view without the rule list does connect to the listener for the same kind of image (\(listener.connections - allowedConnections) connections)"
            )
            unprotected.stopLoading()
        }
    }

    // MARK: Session record (Core)

    private static func sessionRecord() throws {
        func state(_ change: (inout WorkspaceLayoutState.Tab) -> Void) -> WorkspaceLayoutState {
            var tab = WorkspaceLayoutState.Tab(
                documentID: DocumentID(UUID()), isPinned: false, anchorByte: 3, caretByte: 9, firstVisibleLine: 2)
            change(&tab)
            return WorkspaceLayoutState(
                layout: .single, focusedGroup: .first,
                groups: [.init(slot: .first, activeTabIndex: 0, tabs: [tab])])
        }
        for mode in [DocumentViewMode.preview, .both] {
            let original = state {
                $0.viewMode = mode
                $0.previewSourceFraction = 0.37
            }
            let decoded = try WorkspaceLayoutState.decoded(original.encoded())
            check(decoded == original, "session round trip keeps view mode \(mode.rawValue) and its fraction")
        }
        let source = state { _ in }
        let sourceJSON = String(decoding: try source.encoded(), as: UTF8.self)
        check(
            !sourceJSON.contains("viewMode") && !sourceJSON.contains("previewSourceFraction"),
            "a Source tab is written without the new fields, as before")
        check(
            try WorkspaceLayoutState.decoded(source.encoded()).groups[0].tabs[0].viewMode == nil,
            "a record without the field reads as Source")
        rejects("a fraction outside 0...1 is refused") {
            _ = try state { $0.previewSourceFraction = 1.5 }.encoded()
        }
        rejects("an unknown view mode is refused") {
            var object = try JSONSerialization.jsonObject(with: source.encoded()) as! [String: Any]
            var groups = object["groups"] as! [[String: Any]]
            var tabs = groups[0]["tabs"] as! [[String: Any]]
            tabs[0]["viewMode"] = "sideways"
            groups[0]["tabs"] = tabs
            object["groups"] = groups
            _ = try WorkspaceLayoutState.decoded(JSONSerialization.data(withJSONObject: object))
        }
        // The golden session files were written before the field existed.
        for name in ["Session.texttanksession", "SessionLayout.texttanksession"] {
            let bytes = try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/" + name))
            let text = String(decoding: bytes, as: UTF8.self)
            check(!text.contains("viewMode"), "golden \(name) has no view mode field")
        }
        let golden = try JSONSerialization.jsonObject(
            with: Data(
                contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/SessionLayout.texttanksession")))
        if let layout = Self.find("layoutState", in: golden) ?? Self.find("layout", in: golden),
            JSONSerialization.isValidJSONObject(layout),
            let decoded = try? WorkspaceLayoutState.decoded(JSONSerialization.data(withJSONObject: layout))
        {
            check(
                decoded.groups.flatMap(\.tabs).allSatisfy { $0.viewMode == nil && $0.previewSourceFraction == nil },
                "the golden session layout decodes unchanged, every tab in Source")
        } else {
            Checks.fail("the golden session layout could not be located and decoded", file: #filePath, line: #line)
        }
        check(
            abs(PreviewRenderer.debounceInterval(byteCount: 0) - 0.2) < 0.001
                && abs(PreviewRenderer.debounceInterval(byteCount: 4 * 1024 * 1024) - 0.6) < 0.001
                && abs(PreviewRenderer.debounceInterval(byteCount: 64 * 1024 * 1024) - 1.0) < 0.001,
            "the debounce is 0.2 s for a small document and grows to 1 s at the source limit")
    }

    /// The first dictionary value stored under `key` anywhere in a JSON object that itself has a
    /// "groups" member.
    private static func find(_ key: String, in object: Any) -> Any? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] as? [String: Any], value["groups"] != nil { return value }
            for value in dictionary.values { if let found = find(key, in: value) { return found } }
        } else if let array = object as? [Any] {
            for value in array { if let found = find(key, in: value) { return found } }
        }
        return nil
    }

    // MARK: Pure rules

    private static func layoutAndNavigationRules() {
        let minimum = DocumentViewContainer.minimumPaneWidth
        for available in stride(from: CGFloat(0), through: 1200, by: 37) {
            for fraction in [0.0, 0.1, 0.5, 0.9, 1.0] {
                let source = DocumentViewContainer.sourceWidth(available: available, fraction: fraction)
                let preview = available - source
                let roomy = available >= 2 * minimum
                guard source >= 0, preview >= 0, !roomy || (source >= minimum && preview >= minimum) else {
                    Checks.fail(
                        "pane widths at \(available) pt, fraction \(fraction): \(source) + \(preview)",
                        file: #filePath, line: #line)
                    return
                }
            }
        }
        check(true, "DS-67 in Both the two panes never overlap and keep their minimum width when there is room")

        let page = URL(string: "texttank-preview://preview/abc/")!
        func decide(_ address: String, own: Bool = false, click: Bool = false, main: Bool = true)
            -> PreviewNavigationPolicy.Decision
        {
            PreviewNavigationPolicy.decide(
                url: URL(string: address), pageURL: page, isOwnLoad: own, isLinkActivation: click, isMainFrame: main)
        }
        check(
            decide("texttank-preview://preview/abc/", own: true) == .allow,
            "navigation: the presenter's own load is allowed")
        check(
            decide("texttank-preview://preview/abc/") == .cancel,
            "navigation: a reload or meta refresh of the page is cancelled")
        check(
            decide("texttank-preview://preview/abc/#part", click: true) == .allow,
            "navigation: an anchor in the page is allowed")
        check(
            decide("texttank-preview://preview/abc/other.html", click: true) == .cancel,
            "navigation: a relative page link is cancelled")
        check(
            decide("texttank-preview://preview/abc/?q=1") == .cancel,
            "navigation: a form submission to the page is cancelled")
        check(
            decide("file:///etc/passwd") == .cancel && decide("file:///etc/passwd", click: true) == .cancel,
            "navigation: file: is cancelled")
        check(decide("http://example.com/") == .cancel, "navigation: http: that the person did not click is cancelled")
        check(decide("javascript:alert(1)", click: true) == .cancel, "navigation: javascript: is cancelled")
        check(decide("data:text/html,hi", click: true) == .cancel, "navigation: data: is cancelled")
        check(
            decide("texttank-preview://preview/abc/", own: true, main: false) == .cancel,
            "navigation: a frame or new window is cancelled")
        check(
            decide("texttank-preview://another-host/abc/") == .cancel
                && decide("texttank-preview://another-host/abc/", own: true) == .allow
                && decide("texttank-preview://another-host/abc/other.html", click: true) == .cancel,
            "navigation: the host of a preview address is never looked at; only its path decides")
        check(
            decide("https://example.com/a", click: true) == .openExternally(URL(string: "https://example.com/a")!)
                && decide("mailto:a@example.com", click: true, main: false)
                    == .openExternally(URL(string: "mailto:a@example.com")!),
            "navigation: a clicked http, https or mailto link goes to the person's browser or mail application")
    }

    // MARK: Eligibility and commands

    private static func viewModeItems() throws -> [NSMenuItem] {
        let view = try requireValue(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu, "View menu")
        return view.items.filter { $0.action == #selector(EditorWindowController.setDocumentViewMode(_:)) }
    }

    private static func eligibility(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let items = try viewModeItems()
        check(
            items.map(\.title) == ["Source", "Preview", "Both"]
                && items.map { $0.representedObject as? String } == ["source", "preview", "both"]
                && items.allSatisfy { $0.target == nil && $0.keyEquivalent.isEmpty },
            "View has Source, Preview and Both as first-responder commands with no shortcut")
        let view = try requireValue(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu, "View menu")
        check(
            Array(view.items.prefix(4)).map(\.title) == ["Source", "Preview", "Both", "Toggle Preview"]
                && view.items[4].isSeparatorItem,
            "the three commands, Toggle Preview and a separator open the View menu")

        let document = DocumentFactory.makeUntitled()
        document.editor.text = "# Title\n\nplain so far\n"
        let tab = try requireValue(document.presentation, "untitled tab")
        func states() -> [(Bool, NSControl.StateValue)] { items.map { (host.validateMenuItem($0), $0.state) } }
        var seen = states()
        check(
            seen.map(\.0) == [false, false, false] && seen.map(\.1) == [.on, .off, .off],
            "DS-21 a plain-text document has all three commands disabled, with Source checked")
        check(!tab.setViewMode(.both) && tab.viewMode == .source, "a document with no preview cannot leave Source")

        check(document.applyLanguage("markdown", using: app.languages), "fixture: Markdown language applied")
        seen = states()
        check(
            seen.map(\.0) == [true, true, true] && seen.map(\.1) == [.on, .off, .off],
            "choosing the Markdown language enables the three commands")
        tab.setDocumentViewMode(items[2])
        seen = states()
        check(
            tab.viewMode == .both && seen.map(\.1) == [.off, .off, .on],
            "DS-22 View > Both shows both panes and moves the checkmark")
        check(
            tab.viewContainer.preview === tab.previewCoordinator?.pane && !tab.split.isHidden
                && tab.previewCoordinator?.pane.isHidden == false,
            "Both shows the source and the preview side by side")
        let frames = (tab.split.frame, try requireValue(tab.previewCoordinator?.pane.frame, "pane frame"))
        check(
            !frames.0.intersects(frames.1) && frames.0.width >= DocumentViewContainer.minimumPaneWidth
                && frames.1.width >= DocumentViewContainer.minimumPaneWidth,
            "DS-67 the two panes do not overlap: \(frames.0.width) and \(frames.1.width) pt")
        waitCurrent(tab, "untitled Markdown")
        check(pageText(tab).contains("Title"), "an untitled Markdown document is previewed from its language alone")
        check(
            tab.previewCoordinator?.pane.accessibilityLabel() == "Preview of \(document.displayName ?? "")"
                && tab.previewCoordinator?.pane.webPresenter?.webView?.accessibilityLabel()
                    == "Preview of \(document.displayName ?? "")",
            "DS-70 the preview is labelled Preview of the document's name")

        document.usePlainTextLanguage()
        check(
            tab.viewMode == .source && tab.previewCoordinator == nil && tab.viewContainer.preview == nil,
            "changing the language back to plain text returns the tab to Source")
        check(
            tab.statusText == PreviewMessages.noLongerPreviewable,
            "and the status line says so quietly: \(tab.statusText)")
        check(
            NativeFixtureEnvironment.announcements.contains(PreviewMessages.noLongerPreviewable),
            "DS-72 the return to Source is announced")

        // A file's extension decides too: Save As to another type ends the preview.
        let (table, tableTab) = try open("moves.csv", "a,b\n1,2\n", in: root.appendingPathComponent("eligibility"))
        check(tableTab.setViewMode(.preview) && tableTab.viewMode == .preview, "a .csv document can show Preview")
        table.fileURL = root.appendingPathComponent("eligibility/moves.txt")
        check(tableTab.viewMode == .source, "a document renamed to a type with no preview returns to Source")
        document.close()
        table.close()
    }

    // MARK: Mode round trip

    private static func modeRoundTrip(root: URL, app: AppDelegate) throws {
        let lines = (1...400).map { "Line \($0) of the round trip document" }.joined(separator: "\n") + "\n"
        let (document, tab) = try open(
            "roundtrip.md", "# Round trip\n\n" + lines, in: root.appendingPathComponent("round"))
        let editor = tab.primaryEditor
        // Three edits make Undo history; one Undo leaves a Redo step as well.
        var states = [editor.text]
        for word in ["first ", "second ", "third "] {
            _ = editor.setSelectionAnchor(0, caret: 0)
            _ = editor.replaceSelection(word)
            states.append(editor.text)
        }
        check(editor.executeCommand(undo) && editor.text == states[2], "fixture: one Undo leaves two edits and a Redo")
        tab.clone(nil)
        let clone = try requireValue(tab.secondary, "fixture: clone split open")
        _ = editor.setSelectionAnchor(40, caret: 95)
        editor.scrollTo(documentLine: 120, subline: 0)
        _ = clone.setSelectionAnchor(300, caret: 310)
        clone.scrollTo(documentLine: 250, subline: 0)
        window(of: tab)?.makeFirstResponder(editor)
        settle(0.1)

        struct Snapshot: Equatable {
            var bytes: Data, revision: UInt, modified: Bool
            var anchor: Int, caret: Int, top: Int, cloneAnchor: Int, cloneCaret: Int, cloneTop: Int
            var url: URL?, documentCount: Int, undoName: String?, redoName: String?
        }
        func snapshot() -> Snapshot {
            Snapshot(
                bytes: editor.utf8Data, revision: editor.revision, modified: editor.modified,
                anchor: editor.selectionAnchor, caret: editor.selectionCaret, top: editor.firstVisibleLine,
                cloneAnchor: clone.selectionAnchor, cloneCaret: clone.selectionCaret, cloneTop: clone.firstVisibleLine,
                url: document.fileURL, documentCount: NSDocumentController.shared.documents.count,
                undoName: editor.historyName(redo: false), redoName: editor.historyName(redo: true))
        }
        let before = snapshot()
        check(
            before.top == 120 && before.cloneTop == 250,
            "fixture: both panes are scrolled (\(before.top), \(before.cloneTop))")
        let items = try viewModeItems()
        var intact = true, sawHiddenSource = true, sawPane = true
        for round in 0..<50 {
            // Alternate the two ways in: the menu command and the direct call.
            if round % 2 == 0 { tab.setDocumentViewMode(items[2]) } else { tab.setViewMode(.both) }
            intact = intact && tab.viewMode == .both && tab.secondary === clone && !tab.split.isHidden
            sawPane = sawPane && tab.viewContainer.preview != nil
            if round % 2 == 0 { tab.setDocumentViewMode(items[1]) } else { tab.setViewMode(.preview) }
            intact = intact && tab.viewMode == .preview && tab.secondary === clone && snapshot() == before
            sawHiddenSource = sawHiddenSource && tab.split.isHidden && tab.split.superview === tab.viewContainer
            if round % 2 == 0 { tab.setDocumentViewMode(items[0]) } else { tab.setViewMode(.source) }
            intact = intact && tab.viewMode == .source && tab.secondary === clone && tab.previewCoordinator == nil
            if round == 10 || round == 30 { settle(0.05) }
        }
        check(
            intact, "50 rounds of Source, Both, Preview, Source keep the clone split and the tab's state at every step")
        check(sawPane && sawHiddenSource, "Preview hides the source without removing it; Both shows a preview pane")
        let after = snapshot()
        check(after.bytes == before.bytes, "the document's bytes are identical after 50 rounds")
        check(
            after.revision == before.revision && after.modified == before.modified,
            "its revision and edited state are unchanged")
        check(
            after.anchor == before.anchor && after.caret == before.caret && after.top == before.top,
            "the selection and first visible line of the source are unchanged")
        check(
            after.cloneAnchor == before.cloneAnchor && after.cloneCaret == before.cloneCaret
                && after.cloneTop == before.cloneTop && tab.secondary === clone && clone.sharesDocument(with: editor),
            "the clone split is intact, with its own selection and scroll position")
        check(
            after.url == before.url && document.presentation === tab && tab.primaryEditor === editor
                && document.editor === editor && after.documentCount == before.documentCount,
            "the file, the document and its editor are the same objects; no other document was made")
        check(
            after.undoName == before.undoName && after.redoName == before.redoName, "Undo and Redo name the same steps")
        check(editor.executeCommand(undo) && editor.text == states[1], "Undo steps back exactly one edit")
        check(editor.executeCommand(undo) && editor.text == states[0], "and exactly one more")
        check(
            editor.executeCommand(redo) && editor.text == states[1] && editor.executeCommand(redo)
                && editor.text == states[2] && editor.executeCommand(redo) && editor.text == states[3],
            "Redo steps forward through all three edits, the one undone before the rounds included")

        // Focus and commands while the source is hidden.
        tab.setViewMode(.preview)
        waitCurrent(tab, "round trip preview")
        let pane = try requireValue(tab.previewCoordinator?.pane, "preview pane")
        let web = try requireValue(pane.webPresenter?.webView, "web view")
        check(
            (window(of: tab)?.firstResponder as? NSView)?.isDescendant(of: pane) == true,
            "Preview moves the keyboard to the preview")
        check(tab.keyboardFocusView === web, "a tab showing Preview takes the keyboard in its preview when activated")
        let beforeCommand = editor.text
        _ = editor.setSelectionAnchor(0, caret: 5)
        try tab.perform(command: "transform.invertCase")
        check(
            editor.text != beforeCommand && editor.text.hasPrefix("THIRD second"),
            "a text-changing command still acts on the document while only the preview shows")
        check(
            web.tryToPerform(NSSelectorFromString("undo:"), with: nil) && editor.text == beforeCommand,
            "Undo from the preview's keyboard focus undoes that command in the document")
        check(
            web.tryToPerform(NSSelectorFromString("redo:"), with: nil) && editor.text != beforeCommand,
            "and Redo applies it again")
        _ = editor.executeCommand(undo)
        tab.showFind(nil)
        check(
            tab.viewMode == .both && tab.findBarVisible && !tab.split.isHidden,
            "Find shows the source beside the preview first")
        tab.hideFind(nil)
        tab.setViewMode(.preview)
        check(!tab.findBarVisible, "Preview closes the find bar, which acts on the hidden source")
        tab.goToLine(nil)
        check(tab.viewMode == .both, "Go to Line shows the source beside the preview first")
        presentedFormWindow?.close()
        tab.setViewMode(.preview)
        app.searchController.showSearch(nil)
        check(tab.viewMode == .both, "Find and Replace shows the source beside the preview first")
        app.searchController.window?.orderOut(nil)

        // In Both, choosing Both again moves the keyboard between the two panes (DS-73).
        window(of: tab)?.makeFirstResponder(editor)
        tab.setDocumentViewMode(items[2])
        check(
            tab.previewHasFocus && tab.viewMode == .both, "View > Both while in Both moves the keyboard to the preview")
        tab.setDocumentViewMode(items[2])
        check(!tab.previewHasFocus && tab.activeEditor === editor, "and back to the source")
        document.close()
    }

    private static func window(of tab: EditorWindowController) -> NSWindow? { tab.hostWindow }

    // MARK: Markdown

    private static func unsavedMarkdown(root: URL, listener: LoopbackListener) throws {
        let folder = root.appendingPathComponent("markdown")
        let source =
            "# Alpha heading\n\nBody text.\n\n![remote](\(listener.base)/remote.png)\n\n"
            + (1...200).map { "Paragraph \($0).\n\n" }.joined()
        let url = try write(source, "notes.md", in: folder)
        let onDisk = try Data(contentsOf: url)
        let (document, tab) = try open(url)
        let documentsBefore = NSDocumentController.shared.documents.count
        check(tab.setViewMode(.both), "a Markdown document shows Both")
        waitCurrent(tab, "Markdown first render")
        let coordinator = try requireValue(tab.previewCoordinator, "coordinator")
        check(pageText(tab).contains("Alpha heading"), "the Markdown is rendered: the heading text is on the page")
        check(
            script(coordinator.pane.webPresenter?.webView, "document.querySelector('h1').tagName") as? String == "H1",
            "as a heading element, not as typed text")
        check(
            coordinator.pane.message == "1 external resource was blocked.",
            "the message row says the remote image was blocked: \(coordinator.pane.message ?? "nil")")

        picture(tab, "markdown")
        // Scroll the preview, then type: the preview follows without jumping to the top.
        let web = try requireValue(coordinator.pane.webPresenter?.webView, "web view")
        _ = script(web, "window.scrollTo(0, 900); window.scrollY")
        let appliedBefore = coordinator.appliedCount
        try replace("Alpha heading", with: "Beta heading", in: tab.primaryEditor)
        check(pageText(tab).contains("Alpha heading"), "the last rendering stays in place until the new one is ready")
        waitCurrent(tab, "Markdown after edit")
        check(
            pageText(tab).contains("Beta heading") && !pageText(tab).contains("Alpha heading"),
            "after typing pauses, the preview shows the unsaved heading")
        check(coordinator.appliedCount == appliedBefore + 1, "one edit caused one new rendering")
        wait("scroll position restored") { (script(web, "window.scrollY") as? Double ?? 0) > 800 }
        check(
            abs((script(web, "window.scrollY") as? Double ?? 0) - 900) < 2,
            "the preview keeps its scroll position across the new rendering")
        let onDiskNow = try Data(contentsOf: url)
        check(
            document.isDocumentEdited && tab.primaryEditor.modified && onDiskNow == onDisk,
            "the document is still unsaved and its file on disk is byte-identical")
        check(NSDocumentController.shared.documents.count == documentsBefore, "no other document was created")
        check(tab.primaryEditor.executeCommand(undo), "fixture: Undo")
        waitCurrent(tab, "Markdown after Undo")
        check(
            pageText(tab).contains("Alpha heading") && !pageText(tab).contains("Beta heading"),
            "Undo returns the rendered heading")
        settle(0.3)
        check(listener.connections == 1, "Markdown with a remote image made no network connection")
        document.close()
    }

    // MARK: HTML

    private static let pixel = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private static func staticHTML(root: URL, listener: LoopbackListener, opened: Box<[URL]>) throws {
        let folder = root.appendingPathComponent("site/pages")
        let outside = root.appendingPathComponent("site/outside")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try pixel.write(to: folder.appendingPathComponent("img/ok.png"))
        try pixel.write(to: outside.appendingPathComponent("secret.png"))
        try Data("body { margin-left: 37px; }\n@import url(\"\(listener.base)/imported-by-local.css\");\n".utf8)
            .write(to: folder.appendingPathComponent("style.css"))
        try Data("not an image".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("escape.png"),
            withDestinationURL: outside.appendingPathComponent("secret.png"))
        let base = listener.base
        let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <title>Fixture</title>
            <meta http-equiv="refresh" content="0; url=\(base)/refresh">
            <link rel="stylesheet" href="style.css">
            <link rel="stylesheet" href="\(base)/remote.css">
            <link rel="preconnect" href="\(base)">
            <link rel="prefetch" href="\(base)/prefetch">
            <style>
            @import url("\(base)/import.css");
            @font-face { font-family: Remote; src: url("\(base)/font.woff2"); }
            h1 { font-family: Remote, sans-serif; background: url("\(base)/background.png"); }
            </style>
            <script>document.title = "Script ran"; document.documentElement.setAttribute("data-ran", "inline");</script>
            <script src="\(base)/remote.js"></script>
            </head>
            <body onload="document.title = 'Onload ran'">
            <h1 id="heading">Static page</h1>
            <img id="ok" src="img/ok.png">
            <img id="remote" src="\(base)/remote.png" onerror="document.title = 'Onerror ran'">
            <img id="escape" src="escape.png">
            <img id="parent" src="../outside/secret.png">
            <img id="text" src="notes.txt">
            <img id="missing" src="img/missing.png">
            <iframe src="\(base)/frame.html"></iframe>
            <video src="\(base)/movie.mp4" autoplay></video>
            <a id="external" href="\(base)/clicked">external link</a>
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" height="20">
            <a id="drawn" href="\(base)/drawn"><text y="15">a</text></a>
            <a id="drawnOld" xlink:href="\(base)/drawn-old"><text x="20" y="15">b</text></a></svg>
            <a id="pinged" href="#heading" ping="\(base)/ping">anchor with a ping</a>
            <a id="local" href="other.html">local page</a>
            <a id="anchor" href="#heading">anchor</a>
            <form id="form" action="\(base)/form" method="post"><input name="q" value="1"></form>
            </body>
            </html>

            """
        let (document, tab) = try open(write(html, "page.html", in: folder))
        check(tab.setViewMode(.preview), "an HTML document shows Preview")
        waitCurrent(tab, "HTML render")
        settle(0.6)
        let pane = try requireValue(tab.previewCoordinator?.pane, "pane")
        let presenter = try requireValue(pane.webPresenter, "web presenter")
        let web = try requireValue(presenter.webView, "web view")
        let handler = presenter.handler
        check(
            tab.previewCoordinator?.renderCount == 1 && presenter.checkRecord.loadCount == 1 && presenter.checkRecord.contentLostCount == 0,
            "showing Preview rendered and loaded the page once")

        picture(tab, "html")
        check(
            listener.connections == 1,
            "HTML with external image, script, stylesheet, frame, font, @import, prefetch, ping, video and meta refresh made no network connection"
        )
        check(
            web.configuration.defaultWebpagePreferences.allowsContentJavaScript == false
                && !web.configuration.websiteDataStore.isPersistent && !web.isInspectable,
            "the web view has page JavaScript off, a non-persistent data store and no inspector")
        check(
            web.title == "Fixture" && script(web, "document.documentElement.getAttribute('data-ran')") is NSNull,
            "the inline script, onload and onerror handlers did not run: title is \(web.title ?? "nil")")
        check(
            script(web, "document.getElementById('heading').textContent") as? String == "Static page",
            "the application's own script world can read the page although page scripts are off")
        let served = handler.checkRecord.servedLocalFileNames.sorted()
        check(
            served == ["ok.png", "style.css"],
            "the scheme handler served exactly the local image and stylesheet: \(served)")
        check(
            (script(web, "document.getElementById('ok').naturalWidth") as? Int ?? 0) == 1,
            "the allowed local image loaded (natural width 1)")
        check(
            script(web, "getComputedStyle(document.body).marginLeft") as? String == "37px",
            "the allowed local stylesheet was applied")
        for id in ["remote", "escape", "parent", "text", "missing"] {
            check(
                (script(web, "document.getElementById('\(id)').naturalWidth") as? Int ?? -1) == 0,
                "image '\(id)' did not load")
        }
        check(
            handler.refusedLocalFiles == 3 && handler.missingLocalFiles == 1,
            "the symbolic link out of the folder, the ../ path and the text file were refused (\(handler.refusedLocalFiles)); one file was missing (\(handler.missingLocalFiles))"
        )
        let message = pane.message ?? ""
        check(
            message.contains("external resources were blocked.") && message.contains("scripts were not run.")
                && message.contains("1 local file could not be found.")
                && message.contains("3 local files were not loaded."),
            "the message row counts what was blocked, not run, missing and refused: \(message)")
        check(
            NativeFixtureEnvironment.announcements.contains(message),
            "DS-72 the message row's sentence is announced")
        let decisions = presenter.checkRecord.recentDecisions
        check(
            decisions.contains { $0.url?.absoluteString == "\(base)/refresh" && $0.decision == .cancel },
            "the meta refresh was attempted and cancelled by the navigation rule: \(decisions.map { "\($0.url?.absoluteString ?? "nil") \($0.decision)" })"
        )
        check(
            handler.checkRecord.pageServeCount == 1 && web.url?.scheme == PreviewScheme.name,
            "and the page was neither left nor loaded again (\(handler.checkRecord.recentRequestPaths.count) requests)")

        // Navigation: nothing leaves the page except a clicked external link, through the opener.
        let pageURL = web.url
        opened.value = []
        func unchanged(_ label: String) {
            settle(0.3)
            let trace = presenter.checkRecord.recentDecisions.suffix(3).map { "\($0.url?.absoluteString ?? "nil") \($0.decision)" }
            check(
                (script(web, "location.href") as? String) == pageURL?.absoluteString && web.title == "Fixture"
                    && opened.value.isEmpty
                    && handler.checkRecord.pageServeCount == 1 && listener.connections == 1,
                "navigation cancelled, nothing loaded, no connection: \(label) \(trace) served \(handler.checkRecord.pageServeCount) connections \(listener.connections - 1) title \(web.title ?? "nil")"
            )
        }
        _ = script(web, "document.getElementById('form').submit(); 1")
        unchanged("a form post")
        _ = script(web, "document.getElementById('local').click(); 1")
        unchanged("a link to a local page")
        web.load(URLRequest(url: URL(fileURLWithPath: "/etc/hosts")))
        unchanged("a file: load")
        web.load(URLRequest(url: URL(string: "javascript:document.title='url ran'")!))
        unchanged("a javascript: load")
        // An external link opens only after a pointer press and release on it. The events below
        // are made by the application's own script; a physical click is not exercised here.
        let press = """
            function pointer(type, id, count) {
              return document.getElementById(id).dispatchEvent(
                new MouseEvent(type, {bubbles: true, cancelable: true, view: window, detail: count}));
            }
            """
        _ = script(web, "document.getElementById('external').click(); 1")
        unchanged("an external link activated with no pointer press, as Return on a focused link does")
        _ = script(web, press + "pointer('click', 'external', 0); 1")
        unchanged("a click event with a click count of zero")
        _ = script(web, press + "pointer('mousedown', 'local', 1); pointer('click', 'external', 1); 1")
        unchanged("a press on one link and a click on another")
        _ = script(web, "document.getElementById('anchor').click(); 1")
        settle(0.2)
        check(
            web.url?.fragment == "heading" && handler.checkRecord.pageServeCount == 1,
            "an anchor inside the page is followed without a reload")
        _ = script(web, "document.getElementById('pinged').click(); 1")
        settle(0.4)
        check(listener.connections == 1, "a link's ping is not sent (\(listener.connections - 1))")
        _ = script(
            web, press + "pointer('mousedown', 'external', 1); pointer('mouseup', 'external', 1); pointer('click', 'external', 1); 1")
        wait("external link routed") { !opened.value.isEmpty }
        settle(0.5)
        check(
            opened.value == [URL(string: "\(base)/clicked")!],
            "a press and release of the pointer on an http link hands it to the opener, once: \(opened.value)")
        check(
            (script(web, "location.href") as? String)?.hasPrefix("texttank-preview:") == true
                && handler.checkRecord.pageServeCount == 1 && listener.connections == 1,
            "and the web view itself neither navigated nor made a connection for the click or its ping (\(listener.connections - 1))")
        opened.value = []
        _ = script(web, "document.getElementById('external').click(); 1")
        settle(0.3)
        check(opened.value.isEmpty, "the earlier press does not carry over to a later activation without one")
        // A link drawn inside an SVG, with either spelling of its address, behaves the same way.
        for (id, path) in [("drawn", "drawn"), ("drawnOld", "drawn-old")] {
            opened.value = []
            _ = script(web, press + "pointer('click', '\(id)', 1); 1")
            settle(0.3)
            check(
                opened.value.isEmpty && listener.connections == 1 && handler.checkRecord.pageServeCount == 1,
                "an SVG link clicked with no pointer press opens nothing and connects nowhere (\(id))")
            _ = script(web, press + "pointer('mousedown', '\(id)', 1); pointer('click', '\(id)', 1); 1")
            wait("SVG link routed") { !opened.value.isEmpty }
            settle(0.3)
            check(
                opened.value == [URL(string: "\(base)/\(path)")!] && listener.connections == 1,
                "a pressed SVG link is handed to the opener once and the web view makes no connection (\(id)): \(opened.value)")
        }
        opened.value = []
        // An http: load started through the web view's own API is not checked against the
        // listener: WebKit connects ahead of asking the navigation delegate for such a load, and
        // nothing in the application makes one. The rule itself is checked above as a function.
        let menu = NSMenu()
        for identifier in [
            "WKMenuItemIdentifierReload", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierDownloadLinkedFile"
        ] {
            let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            menu.addItem(item)
        }
        if let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)
        {
            web.willOpenMenu(menu, with: event)
            check(
                menu.items.map { $0.identifier?.rawValue } == ["WKMenuItemIdentifierCopy"],
                "the preview's context menu offers Copy and nothing that loads")
        }

        // An untitled HTML document may load no local file at all.
        let untitled = DocumentFactory.makeUntitled()
        untitled.editor.text =
            "<html><body><p id=p>Untitled page</p><img id=i src=\"\(folder.path)/img/ok.png\"><img src=img/ok.png></body></html>"
        check(untitled.applyLanguage("html", using: EditorServices.current?.languages), "fixture: HTML language")
        let untitledTab = try requireValue(untitled.presentation, "untitled tab")
        untitledTab.setViewMode(.preview)
        waitCurrent(untitledTab, "untitled HTML")
        settle(0.3)
        let untitledHandler = try requireValue(untitledTab.previewCoordinator?.pane.webPresenter?.handler, "handler")
        check(
            untitledHandler.checkRecord.servedLocalFileNames.isEmpty && untitledHandler.refusedLocalFiles == 2
                && pageText(untitledTab).contains("Untitled page"),
            "an untitled HTML document is previewed and is served no local file (refused \(untitledHandler.refusedLocalFiles))"
        )
        untitled.close()
        document.close()
    }

    // MARK: SVG

    private static func svg(root: URL, listener: LoopbackListener) throws {
        let base = listener.base
        let image = """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="40" height="30">
            <style>@import url("\(base)/svg.css"); rect { stroke: url("\(base)/paint.svg#p"); }</style>
            <script>document.title = "svg script ran"</script>
            <script xlink:href="\(base)/svg.js"/>
            <image href="\(base)/svg-image.png" width="10" height="10"/>
            <use href="\(base)/sprite.svg#a"/>
            <rect id="shape" width="40" height="30" fill="red" onload="alert(1)"/>
            </svg>

            """
        let (document, tab) = try open("art.svg", image, in: root.appendingPathComponent("svg"))
        check(tab.setViewMode(.both), "an SVG document shows Both")
        waitCurrent(tab, "SVG render")
        settle(0.5)
        let pane = try requireValue(tab.previewCoordinator?.pane, "pane")
        let presenter = try requireValue(pane.webPresenter, "web presenter")
        let web = try requireValue(presenter.webView, "web view")
        check(
            listener.connections == 1,
            "SVG with a script, an external image, use and @import made no network connection")
        check(
            presenter.handler.checkRecord.imageServeCount == 1
                && presenter.handler.checkRecord.lastImageLength == image.utf8.count,
            "the image is served once, from memory, at the length of the document's current text")
        check(
            (script(web, "document.querySelector('img').naturalWidth") as? Int ?? 0) == 40 && web.title == "art.svg",
            "it is shown through an img element at its own size, and its script did not run")
        let message = pane.message ?? ""
        check(
            message.contains("external resources were blocked.") && message.contains("scripts were not run."),
            "the message row says what the image cannot do: \(message)")

        try replace("fill=\"red\"", with: "fill=\"blue\" rx=\"4\"", in: tab.primaryEditor)
        waitCurrent(tab, "SVG after edit")
        picture(tab, "svg")
        let edited = tab.primaryEditor.text
        check(
            presenter.handler.checkRecord.imageServeCount == 2 && edited.contains("fill=\"blue\" rx=\"4\"")
                && presenter.handler.checkRecord.lastImageLength == edited.utf8.count
                && edited.utf8.count != image.utf8.count,
            "editing the fill renders again and serves an image of the new text's length")
        // The served bytes themselves are compared in "scheme handler responses".

        tab.primaryEditor.text = "<?xml version=\"1.0\"?>\n<note><to>someone</to></note>\n"
        waitCurrent(tab, "not an SVG")
        check(
            pane.explanation == SVGPolicy.notSVGMessage && presenter.view.isHidden
                && presenter.handler.checkRecord.imageServeCount == 2,
            "XML that is not SVG shows the sentence instead of an image: \(pane.explanation ?? "nil")")
        tab.primaryEditor.text = ""
        waitCurrent(tab, "empty document")
        check(pane.explanation == PreviewMessages.emptyDocument, "DS-85 an empty document says what to do next")
        settle(0.3)
        check(listener.connections == 1, "no SVG state made a network connection")
        document.close()
    }

    // MARK: Delimited text

    private static func delimited(root: URL) throws {
        let folder = root.appendingPathComponent("tables")
        let csv =
            "name,value,note\n\"a,b\",00123,=SUM(A1)\n\"line1\nline2\",+1,1e5\n,,\nshort\nx, y ,z,extra\n\"unterminated,1,2"
        let (document, tab) = try open("data.csv", csv, in: folder)
        check(tab.setViewMode(.preview), "a CSV document shows Preview")
        waitCurrent(tab, "CSV")
        let pane = try requireValue(tab.previewCoordinator?.pane, "pane")
        let presenter = try requireValue(pane.tablePresenter, "table presenter")
        let table = try requireValue(presenter.table, "parsed table")
        let expected: [[String]] = [
            ["name", "value", "note", ""], ["a,b", "00123", "=SUM(A1)", ""], ["line1\nline2", "+1", "1e5", ""],
            ["", "", "", ""], ["short", "", "", ""], ["x", " y ", "z", "extra"], ["unterminated,1,2", "", "", ""]
        ]
        check(
            table.rowCount == 7 && table.columnCount == 4,
            "CSV has 7 rows and 4 columns: \(table.rowCount) × \(table.columnCount)")
        check((0..<table.rowCount).map(table.row) == expected, "every CSV cell is the text exactly as written")
        check(table.rowLines == [1, 2, 3, 5, 6, 7, 8], "each row knows the source line it starts on: \(table.rowLines)")
        check(
            presenter.tableView.numberOfRows == 7 && presenter.tableView.numberOfColumns == 5
                && presenter.tableView.tableColumns.map(\.title) == ["Line", "A", "B", "C", "D"],
            "the table view has a line column and four lettered columns")
        func shown(_ row: Int, _ column: Int) -> String? {
            presenter.tableView(presenter.tableView, objectValueFor: presenter.tableView.tableColumns[column], row: row)
                as? String
        }
        check(
            shown(1, 2) == "00123" && shown(1, 3) == "=SUM(A1)" && shown(2, 2) == "+1" && shown(2, 3) == "1e5"
                && shown(5, 2) == " y " && shown(1, 1) == "a,b",
            "leading zeros, formula-like text, signs, exponents and spaces are shown as typed, never interpreted")
        check(
            shown(3, 1) == "" && shown(4, 2) == "" && shown(4, 4) == "",
            "empty cells and the cells a short row lacks are empty")
        check(shown(2, 0) == "3" && shown(3, 0) == "5", "the line column shows where each row starts")
        var cellRect = NSRect.zero
        check(
            shown(2, 1) == "line1⏎line2"
                && presenter.tableView(
                    presenter.tableView, toolTipFor: NSCell(), rect: &cellRect,
                    tableColumn: presenter.tableView.tableColumns[1],
                    row: 2, mouseLocation: .zero) == "line1\nline2",
            "a cell with a line break is drawn on one line with a mark; its tooltip is the whole value")
        let message = pane.message ?? ""
        check(
            message
                == "Row 7 opens a quoted value that is never closed. The rest of the document is shown as one value.",
            "the message row reports the quote that is never closed: \(message)")
        picture(tab, "csv")
        presenter.tableView.selectRowIndexes([1, 2], byExtendingSelection: false)
        check(
            presenter.selectedRowsText() == "a,b\t00123\t=SUM(A1)\n\"line1\nline2\"\t+1\t1e5",
            "Copy gives the selected rows as tab-separated text")
        check(
            presenter.tableView.responds(to: #selector(NSText.copy(_:)))
                && presenter.tableView.accessibilityLabel() == "Preview of data.csv"
                && presenter.tableView.accessibilityRole() == .table,
            "the table answers Copy, has the table role and is labelled after its document")
        check(tab.keyboardFocusView === presenter.tableView, "the table takes the keyboard in Preview")
        tab.setViewMode(.both)
        tab.hostWindow?.makeFirstResponder(presenter.tableView)
        tab.hostWindow?.selectKeyView(following: presenter.tableView)
        check(
            (tab.hostWindow?.firstResponder as? NSView)?.isDescendant(of: tab.split) == true,
            "DS-73 in Both, the key view after the table is the source editor (Tab leaves the table)")
        tab.setViewMode(.preview)

        // An edit keeps the selection where the rows still exist.
        tab.primaryEditor.text = "a,b\n1,2\n3,\"4\"x\n"
        waitCurrent(tab, "CSV after edit")
        check(
            presenter.table?.rowCount == 3 && presenter.tableView.selectedRowIndexes == IndexSet([1, 2])
                && presenter.tableView.numberOfColumns == 3,
            "a new parse replaces the rows and columns and keeps the selection")
        check(
            pane.message == "Row 3 has a quotation mark in an unexpected place. It is shown as written.",
            "a stray quotation mark is reported: \(pane.message ?? "nil")")
        document.close()

        let tsv = "a\tb\tc\n\"q\tr\"\t007\t\n,\t=1+1\t\"multi\nline\"\n"
        let (tabDocument, tabTab) = try open("data.tsv", tsv, in: folder)
        tabTab.setViewMode(.both)
        waitCurrent(tabTab, "TSV")
        let tsvTable = try requireValue(tabTab.previewCoordinator?.pane.tablePresenter?.table, "TSV table")
        check(
            (0..<tsvTable.rowCount).map(tsvTable.row) == [
                ["a", "b", "c"], ["q\tr", "007", ""], [",", "=1+1", "multi\nline"]
            ],
            "TSV: a quoted tab, a leading zero, an empty cell, a comma and an embedded line break are kept as written")
        check(
            tsvTable.columnCount == 3 && tsvTable.diagnostics.isEmpty && tabTab.previewCoordinator?.pane.message == nil,
            "well-formed TSV has no message row")
        tabDocument.close()
    }

    // MARK: JSON

    private static func json(root: URL) throws {
        let text = """
            {
              "a": 1,
              "a": 2,
              "big": 123456789012345678901234567890,
              "list": [true, null, {"deep": "x\\u00e9"}],
              "f": 1.0
            }

            """
        let (document, tab) = try open("data.json", text, in: root.appendingPathComponent("json"))
        check(tab.setViewMode(.preview), "a JSON document shows Preview")
        waitCurrent(tab, "JSON")
        let pane = try requireValue(tab.previewCoordinator?.pane, "pane")
        let presenter = try requireValue(pane.outlinePresenter, "outline presenter")
        let outline = presenter.outlineView
        func rows() -> [[String]] {
            (0..<outline.numberOfRows).map { row in
                outline.tableColumns.map { column in
                    presenter.outlineView(outline, objectValueFor: column, byItem: outline.item(atRow: row)) as? String
                        ?? "?"
                }
            }
        }
        check(
            rows() == [
                ["Document", "5 items"], ["a", "1"], ["a", "2"], ["big", "123456789012345678901234567890"],
                ["list", "3 items"], ["f", "1.0"]
            ],
            "the first level is open; names keep their order, duplicates and numbers exactly as written: \(rows())")
        check(pane.message == nil && pane.goToErrorButton.isHidden, "valid JSON has no message row")
        check(
            presenter.expand(path: [.member("list", occurrence: 0), .element(2)]),
            "fixture: open the list and the object inside it")
        check(
            rows().suffix(5) == [["0", "true"], ["1", "null"], ["2", "1 item"], ["deep", "xé"], ["f", "1.0"]],
            "array items are named by position; a string is shown decoded: \(rows().suffix(5))")
        let deepRow = try requireValue(rows().firstIndex(of: ["deep", "xé"]), "row of deep")
        var cellRect = NSRect.zero
        check(
            presenter.outlineView(
                outline, toolTipFor: NSCell(), rect: &cellRect, tableColumn: outline.tableColumns[1],
                item: outline.item(atRow: deepRow)!, mouseLocation: .zero) == "\"x\\u00e9\"",
            "the tooltip is the literal as written")
        outline.selectRowIndexes([deepRow], byExtendingSelection: false)
        check(
            outline.accessibilityRole() == .outline && outline.accessibilityLabel() == "Preview of data.json",
            "the tree has the outline role and is labelled after its document")

        // Make it invalid: an unquoted value where "f" had a number.
        try replace("\"f\": 1.0", with: "\"f\": oops", in: tab.primaryEditor)
        waitCurrent(tab, "invalid JSON")
        let broken = tab.primaryEditor.text
        let offset = broken.utf8.distance(from: broken.utf8.startIndex, to: broken.range(of: "oops")!.lowerBound)
        let message = pane.message ?? ""
        check(
            message.contains("line 6, column 8") && !pane.goToErrorButton.isHidden,
            "the message row gives the error with its line and column, and offers Go to Error: \(message)")
        check(
            rows().prefix(5) == [
                ["Document", "4 items"], ["a", "1"], ["a", "2"], ["big", "123456789012345678901234567890"],
                ["list", "3 items"]
            ],
            "everything read before the error is still shown: \(rows().prefix(5))")
        check(
            rows().contains(["deep", "xé"]) && outline.selectedRow == rows().firstIndex(of: ["deep", "xé"]),
            "the open rows and the selection are kept across the new parse")
        picture(tab, "json-invalid")
        check(tab.viewMode == .preview, "fixture: only the preview shows")
        pane.goToErrorButton.performClick(nil)
        check(
            tab.viewMode == .both && tab.primaryEditor.selectionCaret == offset
                && tab.primaryEditor.selectionAnchor == offset,
            "Go to Error shows the source and puts the caret on the byte where the JSON stopped being valid (\(tab.primaryEditor.selectionCaret) of \(offset))"
        )
        check(tab.primaryEditor.executeCommand(undo), "fixture: repair by Undo")
        waitCurrent(tab, "repaired JSON")
        check(
            pane.message == nil && pane.goToErrorButton.isHidden && rows().contains(["f", "1.0"])
                && rows().contains(["deep", "xé"]),
            "repairing the text clears the error and keeps the tree open")

        // Text that is not JSON from its first byte gives a tree with no value at all. The first
        // tree that has one still starts with its outermost row open.
        tab.primaryEditor.text = "x\n"
        waitCurrent(tab, "not JSON at all")
        check(
            presenter.tree != nil && presenter.tree?.root == nil && outline.numberOfRows == 0
                && !pane.goToErrorButton.isHidden,
            "text that is not JSON shows no rows and the error")
        tab.primaryEditor.text = "{\"a\":1,\"b\":[1,2]}\n"
        waitCurrent(tab, "first valid JSON after text that was not")
        check(
            rows() == [["Document", "2 items"], ["a", "1"], ["b", "2 items"]],
            "the first tree with a value opens its outermost row, even after a tree without one: \(rows())")
        // A row the person closed stays closed.
        outline.collapseItem(outline.item(atRow: 0))
        try replace("\"a\":1", with: "\"a\":12", in: tab.primaryEditor)
        waitCurrent(tab, "edit with the outermost row closed")
        check(rows() == [["Document", "2 items"]], "a row the person closed stays closed across a new parse: \(rows())")
        document.close()
    }

    // MARK: Staleness and lifetime

    private static func stalenessAndLifetime(root: URL, host: WorkspaceWindowController) throws {
        let folder = root.appendingPathComponent("lifetime")
        let (document, tab) = try open("typing.md", "# Start\n\ntext\n", in: folder)
        tab.setViewMode(.both)
        waitCurrent(tab, "typing start")
        let coordinator = try requireValue(tab.previewCoordinator, "coordinator")

        // Twenty revisions inside one debounce interval: one render, of the final text.
        coordinator.debounceInterval = { _ in 0.6 }
        let renders = coordinator.renderCount, applied = coordinator.appliedCount
        let firstRevision = tab.primaryEditor.revision
        for index in 1...20 {
            _ = tab.primaryEditor.setSelectionAnchor(tab.primaryEditor.byteLength, caret: tab.primaryEditor.byteLength)
            _ = tab.primaryEditor.replaceSelection("word\(index) ")
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        check(tab.primaryEditor.revision >= firstRevision + 20, "fixture: twenty revisions")
        check(coordinator.renderCount == renders, "no render starts while typing continues")
        waitCurrent(tab, "after rapid edits")
        check(
            coordinator.renderCount == renders + 1 && coordinator.appliedCount == applied + 1
                && pageText(tab).contains("word20"),
            "twenty rapid edits produce exactly one render, of the final text")
        coordinator.debounceInterval = { PreviewRenderer.debounceInterval(byteCount: $0) }

        // A slow render is pending when another tab becomes the group's active tab.
        let gate = RenderGate()
        coordinator.renderer = gate.renderer(holding: true)
        coordinator.debounceInterval = { _ in 0.01 }
        let appliedBeforeSwitch = coordinator.appliedCount
        try replace("# Start", with: "# Hidden change", in: tab.primaryEditor)
        wait("slow render started") { gate.started.value == 1 }
        let (other, otherTab) = try open("other.md", "# Other\n", in: folder)
        check(host.active === otherTab && !tab.isPresented, "fixture: the first tab is hidden behind another")
        wait("hidden tab's render cancelled") { gate.sawCancellation.value }
        check(gate.sawCancellation.value && coordinator.isIdle, "hiding the tab cancels its render; no work continues")
        gate.open.value = true
        try replace("# Hidden change", with: "# Changed while hidden", in: tab.primaryEditor)
        settle(0.4)
        check(
            coordinator.appliedCount == appliedBeforeSwitch && gate.started.value == 1 && coordinator.isIdle,
            "nothing is rendered or applied for a hidden tab, even when its document changes")
        coordinator.renderer = { PreviewRenderer.render($0) }
        coordinator.debounceInterval = { PreviewRenderer.debounceInterval(byteCount: $0) }
        let rendersBeforeReturn = coordinator.renderCount
        host.activate(tab)
        waitCurrent(tab, "tab shown again")
        check(
            coordinator.renderCount == rendersBeforeReturn + 1 && pageText(tab).contains("Changed while hidden"),
            "showing the tab again renders once, with the current text")
        other.close()
        _ = otherTab

        // The same document in a second group: typing there updates this tab's preview.
        check(host.setEditorLayout(.twoColumns), "fixture: two editor groups")
        let tabID = try requireValue(tab.tabID, "tab id")
        let secondID = try requireValue(host.openView(tabID, in: .second), "second view of the document")
        let second = try requireValue(host.presentation(for: secondID), "second adapter")
        check(
            second.viewMode == .source && tab.viewMode == .both,
            "a new view of a document starts in Source; the first keeps Both")
        waitCurrent(tab, "two groups")
        try replace("# Changed while hidden", with: "# Typed in the other group", in: second.primaryEditor)
        waitCurrent(tab, "edit from the other group")
        check(
            pageText(tab).contains("Typed in the other group"),
            "an edit made in another group's view reaches this tab's preview")
        host.closeTab(secondID, sender: nil)

        // Moving the tab to another group keeps its mode and its preview.
        let movedRenders = coordinator.renderCount
        host.moveTabs([tabID], target: tabID, to: .second)
        let movedID = try requireValue(
            host.model.groups.first { $0.slot == .second }?.tabs.first { $0.documentID == document.runtimeID }?.id,
            "moved tab")
        let moved = try requireValue(host.presentation(for: movedID), "moved adapter")
        check(
            moved === tab && moved.viewMode == .both && moved.previewCoordinator === coordinator && moved.isPresented,
            "a tab moved to another editor group keeps its mode, its adapter and its preview")
        waitCurrent(tab, "after move")
        check(
            coordinator.renderCount - movedRenders <= 1 && pageText(tab).contains("Typed in the other group"),
            "and renders at most once more (\(coordinator.renderCount - movedRenders)) with the right content")
        check(host.setEditorLayout(.single), "fixture: back to one group")

        document.close()
    }

    /// Weak references to everything a tab's preview owns.
    private final class Released {
        weak var coordinator: PreviewCoordinator?
        weak var pane: PreviewPane?
        weak var web: WKWebView?
        weak var presenter: PreviewWebPresenter?
        weak var handler: PreviewSchemeHandler?
        weak var document: TextDocument?
    }

    /// Closing the document while a render is running. Nothing in this function holds the tab,
    /// the coordinator or the web view strongly once the inner scope ends.
    private static func closeMidRender(root: URL) throws {
        let released = Released()
        let gate = RenderGate()
        try autoreleasepool {
            let (document, tab) = try open("closing.md", "# Open\n", in: root.appendingPathComponent("closing"))
            tab.setViewMode(.both)
            waitCurrent(tab, "closing start")
            let live = try requireValue(tab.previewCoordinator, "coordinator")
            released.coordinator = live
            released.pane = live.pane
            released.presenter = live.pane.webPresenter
            released.web = live.pane.webPresenter?.webView
            released.handler = live.pane.webPresenter?.handler
            released.document = document
            live.renderer = gate.renderer(holding: true)
            live.debounceInterval = { _ in 0.01 }
            try replace("# Open", with: "# Closing", in: tab.primaryEditor)
        }
        wait("render running at close") { gate.started.value == 1 }
        check(
            released.web != nil && released.coordinator != nil && released.handler != nil,
            "fixture: the web view, coordinator and scheme handler are alive before close")
        autoreleasepool { released.document?.close() }
        wait("running render cancelled by close") { gate.sawCancellation.value }
        check(gate.sawCancellation.value, "closing the document cancels the render that was running")
        gate.open.value = true
        wait("preview objects released", timeout: 15) {
            autoreleasepool { released.coordinator == nil && released.web == nil && released.pane == nil }
        }
        check(
            released.coordinator == nil && released.pane == nil && released.presenter == nil && released.handler == nil,
            "closing the document mid-render releases the coordinator, the pane and the scheme handler")
        check(released.web == nil, "and the web view")
    }

    // MARK: Limits and timing

    private static func limitsAndTiming(root: URL) throws {
        let folder = root.appendingPathComponent("limits")
        let limit = PreviewLimits.standard.maxSourceBytes

        // Over the limit: the sentence, and no render at all.
        let (large, largeTab) = try open("large.md", "# Large\n", in: folder)
        large.editor.text = String(repeating: "0123456789abcde\n", count: limit / 16 + 1)
        check(large.editor.byteLength > limit, "fixture: \(large.editor.byteLength) bytes is over the limit")
        largeTab.setViewMode(.both)
        let largeCoordinator = try requireValue(largeTab.previewCoordinator, "coordinator")
        waitCurrent(largeTab, "over the limit")
        check(
            largeCoordinator.pane.explanation == PreviewLimit.sourceTooLarge(maxBytes: limit).message
                && largeCoordinator.renderCount == 0 && largeCoordinator.pane.webPresenter == nil,
            "a document over 8 MiB shows the limit sentence and nothing is rendered: \(largeCoordinator.pane.explanation ?? "nil")"
        )
        large.close()

        // 5 MiB in Both: the parse runs off the main thread; applying the result is short.
        /// `secondEdit` is typed at byte 2 in place of the single space at the start.
        func measure(
            _ name: String, _ text: String, seed: String = "x\n", openRows: Int = 0, secondEdit: String? = nil
        ) throws {
            let (document, tab) = try open(name, seed, in: folder)
            tab.setViewMode(.both)
            waitCurrent(tab, "\(name) small")
            let coordinator = try requireValue(tab.previewCoordinator, "coordinator")
            let gate = RenderGate()
            coordinator.renderer = gate.renderer(holding: false)
            coordinator.debounceInterval = { _ in 0.05 }
            document.editor.text = text
            let bytes = document.editor.byteLength
            // While the render runs, the main thread stays free: count run-loop turns and the longest gap.
            var longestGap = 0.0, last = ProcessInfo.processInfo.systemUptime, turns = 0
            wait("\(name) rendered", timeout: 180) {
                let now = ProcessInfo.processInfo.systemUptime
                if gate.started.value > 0, gate.seconds.value == 0 {
                    longestGap = max(longestGap, now - last)
                    turns += 1
                }
                last = now
                return coordinator.isIdle && coordinator.isCurrent
            }
            let firstApply = coordinator.lastApplySeconds
            // The JSON tree is measured as a person sees it: its outermost row open, with every
            // one of its items a row, and some rows inside open as well.
            let outline = coordinator.pane.outlinePresenter?.outlineView
            if let outline {
                check(
                    outline.numberOfRows > 1 && outline.isItemExpanded(outline.item(atRow: 0)),
                    "\(name): the outermost row is open (\(outline.numberOfRows) rows)")
                // Open the last rows of the first level: the costliest to find again by name.
                for row in (outline.numberOfRows - openRows..<outline.numberOfRows).reversed() where openRows > 0 {
                    outline.expandItem(outline.item(atRow: row))
                }
            }
            let rowsBefore = outline?.numberOfRows ?? 0
            // One more character, which keeps every kind of document well formed, and the
            // rendering it causes: the ordinary case of typing with the preview open.
            let editOffset = secondEdit == nil ? 0 : 2
            _ = tab.primaryEditor.setSelectionAnchor(editOffset, caret: editOffset)
            let typingStart = ProcessInfo.processInfo.systemUptime
            _ = tab.primaryEditor.replaceSelection(secondEdit ?? " ")
            let typing = ProcessInfo.processInfo.systemUptime - typingStart
            wait("\(name) rendered again", timeout: 180) { coordinator.isIdle && coordinator.isCurrent }
            let secondApply = coordinator.lastApplySeconds
            print(
                String(
                    format:
                        "TIMING %@ %.1f MiB: render %.3f s off the main thread; apply on main %.4f s the first time and %.4f s after an edit; longest main-thread gap while rendering %.3f s over %d turns; one keystroke %.4f s (Debug build)",
                    name, Double(bytes) / 1_048_576, gate.seconds.value, firstApply, secondApply, longestGap,
                    turns, typing))
            check(!gate.ranOnMainThread.value && gate.started.value >= 1, "\(name): the parse ran off the main thread")
            check(
                firstApply < 0.25 && secondApply < 0.25,
                "\(name): applying the result took \(String(format: "%.4f", firstApply)) s, then \(String(format: "%.4f", secondApply)) s after an edit, of main-thread time"
            )
            if let outline, secondEdit == nil {
                check(
                    outline.numberOfRows == rowsBefore && outline.isItemExpanded(outline.item(atRow: 0)),
                    "\(name): the tree is as open after the edit as before it (\(outline.numberOfRows) of \(rowsBefore) rows)")
            } else if let outline {
                // Every member moved down one place, so each open row had to be found by name,
                // until the allowance for that was used up.
                let stillOpen = outline.numberOfRows - 2 - outline.numberOfChildren(ofItem: outline.item(atRow: 0)) + 1
                check(
                    outline.isItemExpanded(outline.item(atRow: 0)) && (1..<openRows).contains(stillOpen),
                    "\(name): after a member is added at the top, the outermost row stays open and as many rows inside as the allowance covers (\(stillOpen) of \(openRows))")
            }
            check(typing < 0.25, "\(name): a keystroke in Both returned in \(String(format: "%.4f", typing)) s")
            document.close()
        }
        let fiveMiB = 5 * 1024 * 1024
        let paragraph = "A paragraph of *representative* Markdown with a [link](https://example.com) and `code`.\n\n"
        try measure("big.md", String(repeating: paragraph, count: fiveMiB / paragraph.utf8.count))
        let row = "1001,Some Name,00123,=SUM(A1),\"quoted, value\",2026-11-23\n"
        try measure("big.csv", String(repeating: row, count: fiveMiB / row.utf8.count))
        let member = "{\"id\": 1001, \"name\": \"Some Name\", \"tags\": [\"a\", \"b\"], \"ok\": true},\n"
        let count = fiveMiB / member.utf8.count
        try measure(
            "big.json", "[\n" + String(repeating: member, count: count - 1) + "{\"last\": null}\n]\n",
            seed: "[true]\n", openRows: 50)
        // One object with 200,000 members, fifty of them open: finding a member again by name is
        // the costly case.
        let members = (0..<200_000).map { "\"k\($0)\": [\($0)]" }.joined(separator: ",\n")
        try measure("wide.json", "{\n" + members + "\n}\n", seed: "{\"seed\": true}\n", openRows: 50)
        // The costliest edit for the tree: a member added at the top of a large object moves every
        // other member, so open rows are found by name until the allowance is spent.
        let fewer = (0..<24_000).map { "\"k\($0)\": [\($0)]" }.joined(separator: ",\n")
        try measure(
            "moved.json", "{\n" + fewer + "\n}\n", seed: "{\"seed\": true}\n", openRows: 50,
            secondEdit: "\"added\": [0],\n")
    }

    // MARK: Session

    private static func sessionRestore(root: URL, host: WorkspaceWindowController) throws {
        let folder = root.appendingPathComponent("session")
        let (markdown, markdownTab) = try open("kept.md", "# Kept\n", in: folder)
        let (plain, plainTab) = try open("plain.txt", "plain\n", in: folder)
        func record(_ document: TextDocument) throws -> WorkspaceLayoutState.Tab {
            try requireValue(
                host.captureSessionLayout().groups.flatMap(\.tabs).first {
                    $0.documentID == DocumentID(document.recoveryID)
                },
                "session record for \(document.displayName ?? "")")
        }
        check(try record(markdown).viewMode == nil, "a tab in Source is captured without a view mode")
        markdownTab.setViewMode(.both)
        markdownTab.viewContainer.sourceFraction = 0.3
        var captured = try record(markdown)
        check(
            captured.viewMode == .both && abs((captured.previewSourceFraction ?? 0) - 0.3) < 0.001,
            "Both is captured with the divider's position")
        markdownTab.setViewMode(.preview)
        captured = try record(markdown)
        check(captured.viewMode == .preview, "Preview is captured")
        check(
            (try? host.captureSessionLayout().encoded()).flatMap { try? WorkspaceLayoutState.decoded($0) }
                == host.captureSessionLayout(), "the captured layout round-trips through the session format")

        markdownTab.setViewMode(.source)
        markdownTab.restoreSessionTab(captured)
        check(
            markdownTab.viewMode == .preview && markdownTab.split.isHidden, "restoring the record shows Preview again")
        var both = captured
        both.viewMode = .both
        both.previewSourceFraction = 0.7
        markdownTab.restoreSessionTab(both)
        check(
            markdownTab.viewMode == .both && abs(markdownTab.viewContainer.sourceFraction - 0.7) < 0.001,
            "restoring Both restores the divider's position")
        var older = both
        older.viewMode = nil
        older.previewSourceFraction = nil
        markdownTab.restoreSessionTab(older)
        check(markdownTab.viewMode == .source, "a record from before the field existed restores Source")

        // Restoring a whole layout gives the keyboard to the pane the session recorded, here
        // the clone pane, although the keyboard is in the tab's first pane when the restore runs
        // (as it is after documents are reopened).
        host.activate(markdownTab)
        markdownTab.clone(nil)
        let clone = try requireValue(markdownTab.secondary, "fixture: clone pane")
        host.window?.makeFirstResponder(clone)
        _ = clone.setSelectionAnchor(3, caret: 5)
        let saved = host.captureSessionLayout()
        check(
            try record(markdown).split?.secondaryActive == true && markdownTab.activeEditor === clone,
            "fixture: the session records the clone pane as the one in use")
        host.window?.makeFirstResponder(markdownTab.primaryEditor)
        let open = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
        check(
            host.restoreSessionLayout(
                saved, documents: Dictionary(uniqueKeysWithValues: open.map { (DocumentID($0.recoveryID), $0) })),
            "fixture: the layout is restored")
        check(
            host.active === markdownTab && markdownTab.activeEditor === markdownTab.secondary
                && (host.window?.firstResponder as? NSView)?.isDescendant(of: clone) == true,
            "a restored layout puts the keyboard in the saved clone pane, not in the pane that had it")
        check(
            host.captureSessionLayout() == saved,
            "and capturing again gives the same selections and panes as were saved")
        markdownTab.closeSplit(nil)

        var forPlain = try record(plain)
        forPlain.viewMode = .both
        plainTab.restoreSessionTab(forPlain)
        check(
            plainTab.viewMode == .source && plainTab.previewCoordinator == nil,
            "a restored mode is not applied to a document that no longer has a preview")
        markdown.close()
        plain.close()
    }

    // MARK: Switching from the tab

    private static func strip(of host: WorkspaceWindowController) throws -> DocumentTabStrip {
        try requireValue(host.tabStrips.first, "fixture: the focused group's tab strip")
    }
    private static func tabButton(_ tab: EditorWindowController, in strip: DocumentTabStrip) throws -> NSButton {
        let id = try requireValue(tab.tabID, "fixture: tab identity")
        return try requireValue(
            descendants(of: strip, as: NSButton.self).first { $0.identifier?.rawValue == "tab." + id.rawValue.uuidString },
            "fixture: the tab's own button")
    }
    private static func markButton(_ tab: EditorWindowController, in strip: DocumentTabStrip) throws -> NSButton {
        let id = try requireValue(tab.tabID, "fixture: tab identity")
        return try requireValue(
            descendants(of: strip, as: NSButton.self).first {
                $0.identifier?.rawValue == "tab.viewMode." + id.rawValue.uuidString
            }, "fixture: the tab's mark")
    }
    /// Moves the pointer, as the strip's tracking area reports it, to the middle of a tab's title.
    private static func hover(_ tab: EditorWindowController?, in strip: DocumentTabStrip) throws {
        guard let tab else {
            strip.pointerMoved(to: nil)
            return
        }
        let button = try tabButton(tab, in: strip)
        strip.pointerMoved(to: strip.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button))
    }
    /// True when the keyboard is in `view` or in one of its subviews (an editor's text area is
    /// a subview of the editor).
    private static func keyboard(in view: NSView, of host: WorkspaceWindowController) -> Bool {
        (host.window?.firstResponder as? NSView)?.isDescendant(of: view) == true
    }
    private static func viewModeItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.identifier?.rawValue.hasPrefix("tabs.command.viewMode.") == true }
    }
    private static func choose(_ item: NSMenuItem) {
        if let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
    }

    private static func tabContextMenu(root: URL, host: WorkspaceWindowController) throws {
        let folder = root.appendingPathComponent("tab-menu")
        let (notes, notesTab) = try open("notes.md", "# Notes\n\nfirst\n", in: folder)
        let (plain, plainTab) = try open("plain.txt", "plain text\n", in: folder)
        let commands = host.tabCommands
        let notesID = try requireValue(notesTab.tabID, "fixture: notes tab"), plainID = try requireValue(
            plainTab.tabID, "fixture: plain tab")
        check(host.active === plainTab && notesTab.viewMode == .source, "fixture: the plain-text tab is the active one")

        var items = viewModeItems(in: commands.contextMenu(for: notesID))
        check(
            items.map(\.title) == ["Source", "Preview", "Both"]
                && items.map { $0.identifier?.rawValue ?? "" }
                    == ["tabs.command.viewMode.source", "tabs.command.viewMode.preview", "tabs.command.viewMode.both"],
            "DS-20 a previewable tab's menu has Source, Preview and Both, titled as in the View menu, with stable identifiers")
        check(
            items.map(\.state) == [.on, .off, .off] && items.allSatisfy(\.isEnabled),
            "DS-22 the checkmark is on what that tab shows, and all three are enabled")
        let menu = commands.contextMenu(for: notesID)
        let first = try requireValue(menu.items.firstIndex { $0 === viewModeItems(in: menu).first }, "section start")
        check(
            first > 0 && menu.items[first - 1].isSeparatorItem
                && menu.items.filter { !$0.isSeparatorItem }.count <= 20,
            "the three items are a section of their own, and the menu stays within DS-23 (\(menu.items.filter { !$0.isSeparatorItem }.count) items)")
        check(
            viewModeItems(in: commands.contextMenu(for: plainID)).isEmpty,
            "DS-21 a tab whose document has no preview has no such section")

        // Choosing Preview for the tab that is not active changes that tab where it is.
        _ = plainTab.primaryEditor.setSelectionAnchor(2, caret: 5)
        _ = plainTab.primaryEditor.replaceSelection("PLAIN")
        _ = notesTab.primaryEditor.setSelectionAnchor(0, caret: 0)
        _ = notesTab.primaryEditor.replaceSelection("edited ")
        _ = notesTab.primaryEditor.setSelectionAnchor(3, caret: 6)
        host.window?.makeFirstResponder(plainTab.primaryEditor)
        struct State: Equatable {
            var text: String, revision: UInt, anchor: Int, caret: Int, modified: Bool
            @MainActor init(_ editor: TTEditor) {
                text = editor.text
                revision = editor.revision
                anchor = editor.selectionAnchor
                caret = editor.selectionCaret
                modified = editor.modified
            }
        }
        let before = (State(notesTab.primaryEditor), State(plainTab.primaryEditor))
        let responder = host.window?.firstResponder
        let selection = host.tabSelection.selected(in: host.model, group: host.model.focusedGroup)
        let announced = NativeFixtureEnvironment.announcements.count
        choose(items[1])
        check(notesTab.viewMode == .preview, "choosing Preview in a background tab's menu changes that tab")
        check(
            host.active === plainTab && plainTab.viewMode == .source && host.model.activeTab?.id == plainID,
            "the active tab stays active and stays in Source")
        check(host.window?.firstResponder === responder, "the keyboard focus does not move")
        check(
            host.tabSelection.selected(in: host.model, group: host.model.focusedGroup) == selection,
            "the tab selection is unchanged")
        check(
            State(notesTab.primaryEditor) == before.0 && State(plainTab.primaryEditor) == before.1,
            "neither document's text, revision, selection or edited state changes")
        check(
            NativeFixtureEnvironment.announcements.dropFirst(announced).contains("notes.md now shows Preview."),
            "DS-72 the change to a tab that is not showing is announced")
        check(
            plainTab.primaryEditor.executeCommand(undo) && plainTab.primaryEditor.text == "plain text\n"
                && plainTab.primaryEditor.executeCommand(redo) && plainTab.primaryEditor.text == before.1.text,
            "Undo in the active document still reverses its own last edit, and Redo restores it")
        check(
            notesTab.primaryEditor.executeCommand(undo) && notesTab.primaryEditor.text == "# Notes\n\nfirst\n"
                && notesTab.primaryEditor.executeCommand(redo) && notesTab.primaryEditor.text == before.0.text,
            "and the background document's Undo history is intact")
        items = viewModeItems(in: commands.contextMenu(for: notesID))
        check(items.map(\.state) == [.off, .on, .off], "the checkmark follows the tab to Preview")
        check(
            notesTab.previewCoordinator != nil && !notesTab.isPresented,
            "the background tab has its preview ready without having been shown")

        // The active tab's own menu behaves as the View menu does.
        host.activate(notesTab)
        host.window?.makeFirstResponder(notesTab.keyboardFocusView)
        choose(viewModeItems(in: commands.contextMenu(for: notesID))[0])
        check(
            notesTab.viewMode == .source && keyboard(in: notesTab.primaryEditor, of: host),
            "for the active tab Source returns the keyboard to the editor, as View > Source does")
        choose(viewModeItems(in: commands.contextMenu(for: notesID))[2])
        check(
            notesTab.viewMode == .both && keyboard(in: notesTab.primaryEditor, of: host)
                && plainTab.viewMode == .source, "and Both leaves it in the source")

        let stale = viewModeItems(in: commands.contextMenu(for: plainID))
        check(stale.isEmpty, "fixture: the plain tab still offers nothing")
        let captured = viewModeItems(in: commands.contextMenu(for: notesID))
        notes.close()
        choose(captured[0])
        check(
            !commands.setViewMode(.preview, target: notesID) && commands.viewMode(of: notesID) == nil
                && host.active === plainTab && plainTab.viewMode == .source,
            "a menu kept from a tab that has since closed changes nothing")
        plain.close()
    }

    private static func tabMark(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let folder = root.appendingPathComponent("tab-mark")
        let (notes, notesTab) = try open("notes.md", "# Notes\n", in: folder)
        let (plain, plainTab) = try open("plain.txt", "plain\n", in: folder)
        let (table, tableTab) = try open("table.csv", "a,b\n1,2\n", in: folder)
        let strip = try strip(of: host)
        let notesID = try requireValue(notesTab.tabID, "fixture: notes tab")
        let plainID = try requireValue(plainTab.tabID, "fixture: plain tab")
        let tableID = try requireValue(tableTab.tabID, "fixture: table tab")
        host.activate(plainTab)
        check(tableTab.setViewMode(.preview), "fixture: the table tab shows Preview")
        func layout(_ id: TabID) throws -> (title: NSRect, mark: NSRect, close: NSRect, markShown: Bool) {
            try requireValue(strip.tabLayout(id), "fixture: tab layout")
        }
        func width(_ id: TabID) throws -> CGFloat { try layout(id).close.maxX + 8 - (layout(id).title.minX - 8) }
        check(
            try width(notesID) >= DocumentTabStrip.hoverMarkMinimumTabWidth,
            "fixture: three tabs are wide enough for a mark under the pointer (\(try width(notesID)) pt)")

        // The three cases, with the pointer elsewhere.
        try hover(nil, in: strip)
        check(
            try !layout(notesID).markShown && markButton(notesTab, in: strip).isHidden,
            "a previewable tab in Source shows no mark while the pointer is elsewhere")
        check(
            try !layout(plainID).markShown && layout(plainID).title.width == width(plainID) - 48,
            "a tab with no preview has no mark and its title keeps the full width")
        check(
            try layout(tableID).markShown && !markButton(tableTab, in: strip).isHidden,
            "a tab in Preview always shows its mark")
        try hover(plainTab, in: strip)
        check(try !layout(plainID).markShown, "the pointer over a tab with no preview brings up no mark")
        try hover(notesTab, in: strip)
        var mark = try markButton(notesTab, in: strip)
        check(try layout(notesID).markShown && !mark.isHidden, "the pointer over a previewable tab in Source shows its mark")
        check(
            mark.accessibilityLabel() == "Show preview beside source for notes.md" && mark.toolTip == mark.accessibilityLabel()
                && mark.accessibilityRole() == .button && mark.image != nil,
            "DS-70 the mark is a button that names the document and the result, with the same tooltip")
        var frames = try layout(notesID)
        check(
            frames.mark.width == 28 && frames.mark.height == 28 && frames.close.width == 28 && frames.close.height == 28,
            "DS-74 the mark and the close button are 28 by 28 points")
        check(
            frames.mark.minX - frames.title.maxX == 4 && frames.close.minX - frames.mark.maxX == 4
                && !frames.title.intersects(frames.mark) && !frames.mark.intersects(frames.close),
            "DS-14 four points separate the title, the mark and the close button")
        let point = strip.convert(NSPoint(x: mark.bounds.midX, y: mark.bounds.midY), from: mark)
        check(
            strip.hitTest(strip.superview?.convert(point, from: strip) ?? point) === mark,
            "a press on the mark reaches the mark, not the tab's own button, so it cannot select or drag the tab")
        var children = (strip.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        let own = try tabButton(notesTab, in: strip)
        let index = try requireValue(children.firstIndex { $0 === own }, "fixture: the tab among the strip's children")
        check(
            children.count > index + 2 && children[index + 1] === mark
                && children[index + 2].accessibilityLabel() == "Close notes.md"
                && (strip.accessibilityChildrenInNavigationOrder() ?? []).compactMap { $0 as? NSView } == children,
            "the mark is one of the strip's accessibility children, between the tab and its close button")

        // A press on a tab that is not active changes that tab without selecting it.
        let selection = host.tabSelection.selected(in: host.model, group: host.model.focusedGroup)
        host.window?.makeFirstResponder(plainTab.primaryEditor)
        mark.performClick(nil)
        check(notesTab.viewMode == .both, "pressing the mark of a tab in Source shows Both")
        check(
            host.active === plainTab && host.model.activeTab?.id == plainID && !strip.isReordering
                && host.tabSelection.selected(in: host.model, group: host.model.focusedGroup) == selection
                && keyboard(in: plainTab.primaryEditor, of: host),
            "the pressed tab is not selected, nothing is dragged, and the keyboard stays where it was")
        try hover(nil, in: strip)
        mark = try markButton(notesTab, in: strip)
        check(
            try layout(notesID).markShown && mark.accessibilityLabel() == "Show source for notes.md"
                && mark.toolTip == "Show source for notes.md",
            "in Both the mark stays without the pointer and offers the way back to Source")
        check(
            try tabButton(notesTab, in: strip).accessibilityLabel() == "notes.md, showing Source and Preview"
                && tabButton(tableTab, in: strip).accessibilityLabel() == "table.csv, showing Preview"
                && tabButton(plainTab, in: strip).accessibilityLabel() == "plain.txt",
            "DS-14 a tab's own label says when it shows Preview or Both")
        mark.performClick(nil)
        check(
            try notesTab.viewMode == .source && !layout(notesID).markShown && host.active === plainTab
                && tabButton(notesTab, in: strip).accessibilityLabel() == "notes.md",
            "pressing the mark of a tab in Both returns it to Source, and the mark goes")
        children = (strip.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        check(!children.contains { $0 === mark }, "a mark that is not shown is not among the accessibility children")

        // Without a pointer: an action on the tab itself.
        var actions = try tabButton(notesTab, in: strip).accessibilityCustomActions() ?? []
        let show = try requireValue(
            actions.first { $0.name == "Show Preview Beside Source" }, "DS-73 a Source tab offers the preview as an action")
        check(
            show.handler?() == true && notesTab.viewMode == .both && host.active === plainTab,
            "the action shows Both without selecting the tab")
        actions = try tabButton(notesTab, in: strip).accessibilityCustomActions() ?? []
        let plainActions = try tabButton(plainTab, in: strip).accessibilityCustomActions() ?? []
        check(
            actions.contains { $0.name == "Show Source" } && !actions.contains { $0.name == "Show Preview Beside Source" }
                && !plainActions.contains { $0.name.hasPrefix("Show ") },
            "the action names what it will do next; a tab with no preview has none")

        // The mark follows a change made by any other route.
        host.activate(notesTab)
        let viewItems = try viewModeItems()
        notesTab.setDocumentViewMode(viewItems[0])
        check(try !layout(notesID).markShown, "View > Source removes the mark")
        notesTab.setDocumentViewMode(viewItems[1])
        check(
            try layout(notesID).markShown
                && tabButton(notesTab, in: strip).accessibilityLabel() == "notes.md, showing Preview",
            "View > Preview brings it back, and the tab's label follows")
        var record = try requireValue(
            host.captureSessionLayout().groups.flatMap(\.tabs).first { $0.documentID == DocumentID(notes.recoveryID) },
            "fixture: session record")
        record.viewMode = nil
        record.previewSourceFraction = nil
        notesTab.restoreSessionTab(record)
        check(try notesTab.viewMode == .source && !layout(notesID).markShown, "a restored Source removes the mark")
        record.viewMode = .both
        notesTab.restoreSessionTab(record)
        check(try notesTab.viewMode == .both && layout(notesID).markShown, "and a restored Both shows it")

        // Language: gaining a preview offers the mark, losing it removes mark and mode.
        let untitled = DocumentFactory.makeUntitled()
        let untitledTab = try requireValue(untitled.presentation, "untitled tab")
        let untitledID = try requireValue(untitledTab.tabID, "untitled tab identity")
        try hover(untitledTab, in: strip)
        check(try !layout(untitledID).markShown, "an untitled plain-text tab has no mark under the pointer")
        check(untitled.applyLanguage("markdown", using: app.languages), "fixture: Markdown language applied")
        check(
            try layout(untitledID).markShown && untitledTab.viewMode == .source,
            "choosing a previewable language offers the mark at once, and the tab stays in Source")
        try markButton(untitledTab, in: strip).performClick(nil)
        try hover(nil, in: strip)
        check(try untitledTab.viewMode == .both && layout(untitledID).markShown, "fixture: the untitled tab shows Both")
        untitled.usePlainTextLanguage()
        check(
            try untitledTab.viewMode == .source && !layout(untitledID).markShown
                && markButton(untitledTab, in: strip).isHidden,
            "changing the language to one with no preview removes the mark")
        try hover(untitledTab, in: strip)
        check(try !layout(untitledID).markShown, "and the pointer no longer brings one up")
        untitled.close()

        // At the minimum tab width the title keeps its room: no mark under the pointer, but the
        // mark that shows state stays.
        let window = try requireValue(host.window, "workspace window")
        let size = window.contentView?.bounds.size ?? .zero
        window.setContentSize(NSSize(width: 800, height: size.height))
        var fillers: [TextDocument] = []
        for number in 1...4 { fillers.append(try open("filler\(number).md", "# Filler\n", in: folder).0) }
        window.contentView?.layoutSubtreeIfNeeded()
        strip.layout()
        check(
            try width(notesID) < DocumentTabStrip.hoverMarkMinimumTabWidth && width(notesID) >= 130,
            "fixture: seven tabs in an 800-point window are below the width a pointer mark needs (\(try width(notesID)) pt)")
        notesTab.setViewMode(.source)
        try hover(notesTab, in: strip)
        frames = try layout(notesID)
        let narrow = try width(notesID)
        check(
            !frames.markShown && frames.title.width == narrow - 48,
            "at that width the pointer brings up no mark and the title keeps its full width (\(frames.title.width) pt)")
        try hover(nil, in: strip)
        notesTab.setViewMode(.both)
        frames = try layout(notesID)
        check(
            frames.markShown && frames.title.width >= 50 && frames.mark.minX - frames.title.maxX == 4
                && frames.close.minX - frames.mark.maxX == 4,
            "a tab in Both keeps its mark at the minimum width, with \(frames.title.width) pt left for the title")
        check(
            try tabButton(notesTab, in: strip).lineBreakMode == .byTruncatingTail,
            "and the title truncates at its tail")
        window.setContentSize(size)
        fillers.forEach { $0.close() }
        notes.close()
        plain.close()
        table.close()
    }

    // MARK: Toggle Preview

    private static func togglePreview(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let bar = try requireValue(NSApp.mainMenu, "menu bar")
        let view = try requireValue(bar.items.first { $0.title == "View" }?.submenu, "View menu")
        let toggle = try requireValue(
            view.items.first { $0.action == #selector(EditorWindowController.toggleDocumentPreview(_:)) },
            "View > Toggle Preview")
        check(
            view.items.firstIndex { $0 === toggle } == 3 && view.items[2].title == "Both" && view.items[4].isSeparatorItem
                && toggle.title == "Toggle Preview" && toggle.target == nil,
            "Toggle Preview is directly under Source, Preview and Both, and goes to the first responder")
        check(
            toggle.keyEquivalent == "V" && toggle.keyEquivalentModifierMask == .command && toggle is DefaultShortcutItem,
            "its shortcut is Shift-Command-V, a default that yields to a shortcut assigned in Settings")
        var chords: [String] = []
        func walk(_ menu: NSMenu, _ path: String) {
            for item in menu.items {
                let here = path + " > " + item.title
                var key = item.keyEquivalent, flags = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
                if key.count == 1, key != key.lowercased() {
                    key = key.lowercased()
                    flags.insert(.shift)
                }
                if key == "v", flags == [.command, .shift] { chords.append(here) }
                if let child = item.submenu { walk(child, here) }
            }
        }
        walk(bar, "")
        check(chords == [" > View > Toggle Preview"], "no other menu item uses Shift-Command-V: \(chords)")
        check(
            !EditorSettings.protectedShortcuts.contains("V") && !EditorCommand.defaultShortcuts.values.contains("V")
                && !SettingsController.reservedShortcuts(in: bar).contains("V"),
            "the key is not a protected, default or reserved editor shortcut, so saved shortcuts still load")
        var custom = app.settings.value
        custom.setShortcut("V", for: EditorCommand.upper.rawValue)
        try app.settings.save(custom)
        check(
            toggle.keyEquivalent.isEmpty && app.settings.ignoredShortcutBindings.isEmpty,
            "a person's own Shift-Command-V shortcut is kept, and Toggle Preview gives up the key")
        custom.setShortcut("", for: EditorCommand.upper.rawValue)
        try app.settings.save(custom)
        check(toggle.keyEquivalent == "V", "fixture: the default shortcut returns")
        check(
            view.items.filter { !$0.isSeparatorItem && !$0.isHidden }.count <= 20,
            "DS-23 View lists no more than twenty items (\(view.items.filter { !$0.isSeparatorItem && !$0.isHidden }.count))")

        let untitled = DocumentFactory.makeUntitled()
        let plainTab = try requireValue(untitled.presentation, "untitled tab")
        check(!host.validateMenuItem(toggle), "DS-21 Toggle Preview is disabled for a document with no preview")
        plainTab.toggleDocumentPreview(nil)
        check(plainTab.viewMode == .source, "and does nothing if it is sent anyway")
        untitled.close()

        let (document, tab) = try open("toggle.md", "# Toggle\n", in: root.appendingPathComponent("toggle"))
        check(host.active === tab && host.validateMenuItem(toggle), "Toggle Preview is enabled for a Markdown document")
        check(app.settings.toggledPreviewMode == .both, "fixture: no rendered mode has been chosen by hand yet")
        tab.toggleDocumentPreview(toggle)
        check(tab.viewMode == .both, "from Source the first Toggle Preview shows Both")
        tab.toggleDocumentPreview(toggle)
        check(tab.viewMode == .source && tab.previewCoordinator == nil, "from Both it returns to Source")
        let items = try viewModeItems()
        tab.setDocumentViewMode(items[1])
        check(tab.viewMode == .preview && app.settings.toggledPreviewMode == .preview, "choosing View > Preview is remembered")
        tab.toggleDocumentPreview(toggle)
        check(tab.viewMode == .source, "from Preview it returns to Source")
        tab.toggleDocumentPreview(toggle)
        check(tab.viewMode == .preview, "and from Source it now shows Preview, the mode used last")
        let stored = SettingsStore(url: app.settings.url)
        check(
            stored.loadError == nil && stored.value.lastRenderedPreviewMode == "preview"
                && stored.value.toggledPreviewMode == .preview,
            "the remembered mode is in the settings file, so it survives a relaunch")
        // Changes the person did not choose by hand are not remembered.
        tab.setViewMode(.source)
        tab.setViewMode(.both)
        tab.revealSource()
        check(app.settings.toggledPreviewMode == .preview, "a mode set by the app itself does not change what is remembered")
        tab.setViewMode(.source)
        let id = try requireValue(tab.tabID, "fixture: tab identity")
        check(
            host.tabCommands.setViewMode(.both, target: id) && app.settings.toggledPreviewMode == .both,
            "Both chosen from the tab is remembered like Both chosen from the View menu")

        // Recording a macro: the mode commands are view changes, and Toggle Preview is the same.
        let macros = app.macros
        host.window?.makeFirstResponder(tab.primaryEditor)
        tab.setViewMode(.source)
        macros.startRecording()
        check(macros.recordingStatus == .recording, "fixture: a macro is being recorded")
        tab.setDocumentViewMode(items[2])
        let afterMode = macros.recordingStatus
        tab.toggleDocumentPreview(toggle)
        tab.toggleDocumentPreview(toggle)
        check(
            afterMode == .recording && macros.recordingStatus == .recording && macros.discardReason == nil,
            "Toggle Preview leaves a recording as valid as the three mode commands do")
        // Finished through the non-presenting path: Stop Recording would show an alert for a
        // recording with no steps, and a check never puts a dialog on the desktop.
        rejects(
            "and neither is recorded as a step: the recording ends empty, not discarded",
            message: "No supported editing actions were recorded."
        ) { _ = try macros.finishRecording() }
        check(macros.recordingStatus == .idle, "fixture: the recording has ended")
        document.close()
    }

    // MARK: Open in, per format

    private static func openInPerFormat(root: URL, app: AppDelegate, host: WorkspaceWindowController) throws {
        let folder = root.appendingPathComponent("open-in")
        let samples: [(PreviewFormat, String, String)] = [
            (.markdown, "page.md", "# Page\n"), (.html, "page.html", "<p>Page</p>\n"),
            (.delimited, "rows.csv", "a,b\n1,2\n"), (.svg, "shape.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>\n"),
            (.json, "data.json", "{\"a\": 1}\n")
        ]
        func openFresh(_ url: URL) throws -> (TextDocument, EditorWindowController) {
            let document = try DocumentFactory.openCaptured(
                WorkspaceStore.captureRegularFile(url, maximumBytes: Int.max), from: url)
            return (document, try requireValue(document.presentation, "fixture: tab for \(url.lastPathComponent)"))
        }
        func setOpenMode(_ mode: DocumentViewMode, for format: PreviewFormat) throws {
            var value = app.settings.value
            value.setPreviewOpenMode(mode, for: format)
            try app.settings.save(value)
        }

        // Unchanged until the person changes it.
        for (format, name, text) in samples {
            let (document, tab) = try openFresh(write(text, name, in: folder))
            check(
                tab.viewMode == .source && tab.previewKind?.format == format,
                "with default settings \(name) opens in Source")
            document.close()
        }

        // Each of the five formats, with the other four left at Source.
        for (index, (format, name, _)) in samples.enumerated() {
            let wanted: DocumentViewMode = index.isMultiple(of: 2) ? .preview : .both
            try setOpenMode(wanted, for: format)
            let url = folder.appendingPathComponent(name)
            let (document, tab) = try openFresh(url)
            check(
                tab.viewMode == wanted && tab.previewCoordinator != nil && host.active === tab,
                "\(name) opens in \(wanted.rawValue) when Settings says so")
            check(
                wanted == .preview
                    ? tab.previewCoordinator.map { keyboard(in: $0.pane, of: host) } == true
                    : keyboard(in: tab.primaryEditor, of: host),
                "and the keyboard goes to what that tab shows")
            let other = samples[(index + 1) % samples.count]
            let (otherDocument, otherTab) = try openFresh(folder.appendingPathComponent(other.1))
            check(otherTab.viewMode == .source, "while \(other.1) still opens in Source")
            otherDocument.close()
            document.close()
            try setOpenMode(.source, for: format)
        }

        // The NSDocument route that File > Open, a dropped file and a file named on the command
        // line take: the document reads its file, is registered, and is then shown. This bare
        // check process has no document types, so the three steps are made here directly.
        try setOpenMode(.both, for: .markdown)
        let page = folder.appendingPathComponent("page.md")
        let viaController = try TextDocument(contentsOf: page, ofType: TextDocument.plainTextType)
        NSDocumentController.shared.addDocument(viaController)
        viaController.makeWindowControllers()
        viaController.showWindows()
        let controllerTab = try requireValue(viaController.presentation, "fixture: its tab")
        check(
            controllerTab.viewMode == .both && viaController.languageIdentifier == "markdown",
            "a Markdown file read by NSDocument and then registered shows Both")

        // A setting change leaves open tabs alone, and so does a tab changed by hand.
        try setOpenMode(.preview, for: .markdown)
        check(controllerTab.viewMode == .both, "changing the setting does not change a tab that is already open")
        controllerTab.setDocumentViewMode(try viewModeItems()[0])
        try setOpenMode(.both, for: .markdown)
        check(controllerTab.viewMode == .source, "nor a tab the person has returned to Source by hand")
        viaController.makeWindowControllers()
        viaController.showWindows()
        check(
            controllerTab.viewMode == .source && viaController.presentations.count == 1,
            "showing a document that is already open selects its tab as it is")

        // Untitled documents and Save As: no automatic switch.
        let untitled = DocumentFactory.makeUntitled()
        let untitledTab = try requireValue(untitled.presentation, "untitled tab")
        check(untitled.applyLanguage("markdown", using: app.languages), "fixture: Markdown language applied")
        check(
            untitledTab.viewMode == .source && untitledTab.previewKind == .markdown,
            "an untitled document whose language becomes Markdown stays in Source")
        let (text, textTab) = try openFresh(write("plain\n", "plain.txt", in: folder))
        text.fileURL = folder.appendingPathComponent("renamed.md")
        check(
            textTab.viewMode == .source && textTab.previewKind == .markdown,
            "a document saved under a previewable name stays in Source")
        untitled.close()
        text.close()

        // A reopened session keeps each tab's recorded mode, whatever the setting says.
        let (kept, keptTab) = try openFresh(write("# Kept\n", "kept.md", in: folder))
        keptTab.setViewMode(.preview)
        controllerTab.setViewMode(.source)
        check(keptTab.viewMode == .preview && controllerTab.viewMode == .source, "fixture: one tab in Preview, one in Source")
        let session = try OpenSessionLayout(host).diskLayout()
        check(
            session.files.count == 2 && session.layout.groups.flatMap(\.tabs).compactMap(\.viewMode) == [.preview],
            "fixture: the session records Preview for one tab and nothing for the other")
        kept.close()
        viaController.close()
        check(host.active == nil, "fixture: the workspace is empty before the session is reopened")
        let reopened = AutomaticSession(url: folder.appendingPathComponent("last-session.json")).reopen(session, in: host)
        check(reopened.notices.isEmpty && reopened.files.count == 2, "fixture: the session reopens both files \(reopened.notices)")
        let restoredKept = try requireValue(
            reopened.files[TextDocument.canonicalDiskURL(folder.appendingPathComponent("kept.md"))]
                ?? reopened.files.first { $0.key.lastPathComponent == "kept.md" }?.value, "fixture: kept.md reopened")
        let restoredPage = try requireValue(
            reopened.files.first { $0.key.lastPathComponent == "page.md" }?.value, "fixture: page.md reopened")
        check(
            restoredKept.presentation?.viewMode == .preview,
            "the tab the session recorded in Preview is restored in Preview, not in the setting's Both")
        check(
            restoredPage.presentation?.viewMode == .source,
            "and the tab the session recorded in Source stays in Source although Markdown now opens in Both")
        check(!PreviewOpenDefault.isSuspended, "the setting applies again once the session has been reopened")
        let (after, afterTab) = try openFresh(write("# After\n", "after.md", in: folder))
        check(afterTab.viewMode == .both, "a file opened after the session is restored opens in Both")
        after.close()
        restoredKept.close()
        restoredPage.close()

        // A settings file from before the choice existed, and one with a value this build does
        // not know, both open everything in Source.
        let older = try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/Settings.json"))
        for (label, bytes) in [
            ("an earlier settings file", older),
            (
                "a settings file with an unknown value",
                Data(
                    #"{"tabWidth":4,"wrap":false,"useTabs":true,"version":1,"appearance":"system","shortcuts":{},"previewOpenModes":{"markdown":"sideways"}}"#
                        .utf8)
            )
        ] {
            let url = folder.appendingPathComponent("settings-\(UUID().uuidString).json")
            try bytes.write(to: url)
            let loaded = SettingsController(url: url)
            check(
                loaded.loadError == nil
                    && PreviewFormat.allCases.allSatisfy { loaded.value.previewOpenMode(for: $0) == .source }
                    && loaded.toggledPreviewMode == .both, "\(label) loads and reads as Source for every format")
        }
        try setOpenMode(.source, for: .markdown)
        check(app.settings.value.previewOpenModes == nil, "fixture: the settings are back to Source everywhere")
    }

    // MARK: Scheme handler responses

    private static func schemeHandlerResponses(root: URL) throws {
        let folder = root.appendingPathComponent("responses")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try pixel.write(to: folder.appendingPathComponent("ok.png"))
        let handler = PreviewSchemeHandler()
        // The handler never looks at the web view it is called for; this one loads nothing.
        let unused = WKWebView(frame: .zero)
        let image = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"3\" height=\"2\"/>".utf8)
        func site(_ token: String, document: URL) -> PreviewSchemeHandler.Site {
            PreviewSchemeHandler.Site(
                page: PreviewPage(
                    pagePath: "/\(token)/", html: Data("<p>page \(token)</p>".utf8), imagePath: "/\(token).svg",
                    image: image, report: PreviewContentReport()),
                resolver: PreviewResourceResolver(documentURL: document))
        }
        func request(_ path: String, page token: String) -> RecordingSchemeTask {
            let task = RecordingSchemeTask(
                "texttank-preview://preview\(path)", page: "texttank-preview://preview/\(token)/")
            handler.webView(unused, start: task)
            wait("response for \(path)") { task.isDone }
            return task
        }
        let policy = StaticHTMLPolicy.contentSecurityPolicy()
        handler.site = site("first", document: folder.appendingPathComponent("page.html"))

        let page = request("/first/", page: "first")
        let picture = request("/first.svg", page: "first")
        let file = request("/first/ok.png", page: "first")
        for (name, task, type, body) in [
            ("the page", page, "text/html; charset=utf-8", Data("<p>page first</p>".utf8)),
            ("the SVG image", picture, "image/svg+xml", image), ("a local file", file, "image/png", pixel)
        ] {
            let headers = task.response
            check(
                task.failure == nil && headers?.statusCode == 200 && task.body == body
                    && headers?.value(forHTTPHeaderField: "Content-Type") == type,
                "\(name) is served with its bytes and type")
            check(
                headers?.value(forHTTPHeaderField: "Content-Security-Policy") == policy,
                "\(name) carries the content security policy as a response header")
            check(
                headers?.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff"
                    && headers?.value(forHTTPHeaderField: "Cache-Control") == "no-store",
                "\(name) is served no-store and nosniff")
        }
        check(
            handler.checkRecord.servedLocalFileNames == ["ok.png"] && handler.checkRecord.lastImageLength == image.count
                && handler.checkRecord.pageServeCount == 1 && handler.checkRecord.imageServeCount == 1,
            "the handler's record for the checks holds names, counts and a length, not bytes")
        let otherHost = RecordingSchemeTask(
            "texttank-preview://another-host/first/", page: "texttank-preview://another-host/first/")
        handler.webView(unused, start: otherHost)
        check(
            otherHost.body == page.body && otherHost.failure == nil,
            "the handler answers by path alone; the host of the address is not looked at")

        // Counts belong to the page that asked.
        let missing = request("/first/none.png", page: "first")
        check(
            missing.failure != nil && handler.missingLocalFiles == 1,
            "control: a file the current page asks for that is not there is counted")
        let late = RecordingSchemeTask(
            "texttank-preview://preview/first/also-none.png", page: "texttank-preview://preview/first/")
        handler.webView(unused, start: late)
        // The read is still running on its background task when the next page replaces this one.
        handler.site = site("second", document: folder.appendingPathComponent("page.html"))
        check(!late.isDone && handler.missingLocalFiles == 0, "fixture: the page was replaced while the file was read")
        wait("late read answered") { late.isDone }
        settle(0.1)
        check(
            late.failure != nil && handler.missingLocalFiles == 0 && handler.refusedLocalFiles == 0,
            "a file read that finishes after its page was replaced is not counted against the new page")
        _ = request("/second/none.png", page: "second")
        check(handler.missingLocalFiles == 1, "the new page's own missing file is counted")

        // A document saved directly in the home folder has no folder of its own.
        let home = FileManager.default.homeDirectoryForCurrentUser
        handler.site = site("third", document: home.appendingPathComponent("texttank-check-page.html"))
        let broad = request("/third/anything.png", page: "third")
        check(
            broad.failure != nil && handler.broadFolderLocalFiles == 1 && handler.refusedLocalFiles == 0
                && handler.missingLocalFiles == 0 && handler.checkRecord.servedLocalFileNames.isEmpty,
            "a document saved directly in the home folder is served no local file, and that is counted on its own")
        check(
            PreviewMessages.broadFolderLocalFiles(1)
                == "1 local file was not loaded because this document is saved directly in your home folder or at the top of the disk. Save the document in a folder of its own to load it."
                && PreviewMessages.broadFolderLocalFiles(2)?.hasPrefix("2 local files were not loaded because") == true
                && PreviewMessages.broadFolderLocalFiles(0) == nil,
            "DS-81 DS-83 its sentence says why and what to do next")
    }

    // MARK: Policy header

    /// Documents whose markup keeps the policy `<meta>` tag from taking effect. The policy must
    /// hold for each of them all the same, because the scheme handler sends it as a header.
    private static func policyHeader(root: URL, listener: LoopbackListener) throws {
        let folder = root.appendingPathComponent("policy")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try pixel.write(to: folder.appendingPathComponent("ok.png"))
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"9\" height=\"9\"/>".utf8).write(
            to: folder.appendingPathComponent("local.svg"))
        let (document, tab) = try open("policy.html", "<p id=\"marker\">start</p>\n", in: folder)
        check(tab.setViewMode(.preview), "fixture: Preview")
        waitCurrent(tab, "policy start")
        let presenter = try requireValue(tab.previewCoordinator?.pane.webPresenter, "web presenter")
        let web = try requireValue(presenter.webView, "web view")
        let handler = presenter.handler
        // The checks' own listener for what the policy refuses, in the application's script world.
        web.configuration.userContentController.addUserScript(
            WKUserScript(
                source: """
                    window.textTankViolations = [];
                    document.addEventListener('securitypolicyviolation', function (event) {
                      window.textTankViolations.push(event.violatedDirective + ' ' + event.blockedURI);
                    }, true);
                    """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))

        let dataImage = "data:image/png;base64," + pixel.base64EncodedString()
        let tail = """
            <p id="marker">shown</p>
            <img id="probe" src="\(dataImage)">
            <img id="ok" src="ok.png">
            <a id="rel" href="next.html">relative link</a>
            <iframe src="local.svg"></iframe>
            <object data="local.svg" type="image/svg+xml"></object>
            <form id="form" action="next.html"><input name="q" value="1"></form>

            """
        let cases: [(name: String, html: String)] = [
            ("a head tag after the body began", "<html><body><p>hi</p><head>" + tail),
            ("a head tag inside a title", "<title><head></title>" + tail),
            ("a head tag inside a text area", "<textarea><head></textarea>" + tail),
            ("an html tag after content", "<p>x</p><html>" + tail),
            ("a head tag inside a comment in a script", "<script><!--<script></script><head>--></script>" + tail),
            ("a head tag inside a template", "<template><head></template>" + tail),
            ("a head tag inside an svg element", "<svg><head></svg>" + tail),
            ("a head tag that is never finished", tail + "<head"),
            ("a base tag before the head", "<html><base href=\"\(listener.base)/\"><head>" + tail),
            ("an ordinary document", "<!DOCTYPE html><html><head><title>t</title></head><body>" + tail + "</body></html>")
        ]
        for (name, html) in cases {
            tab.primaryEditor.text = html
            waitCurrent(tab, name)
            settle(0.4)
            func value(_ source: String) -> Any? { script(web, source) }
            let violations = value("window.textTankViolations.join('|')") as? String ?? "none recorded"
            check(
                value("document.getElementById('marker').textContent") as? String == "shown",
                "\(name): the page is shown")
            check(
                violations.contains("img-src") && (value("document.getElementById('probe').naturalWidth") as? Int) == 0,
                "\(name): the policy is in force; it refused an image from a data: address (\(violations))")
            check(
                (value("document.getElementById('ok').naturalWidth") as? Int) == 1,
                "\(name): an image beside the document still loads, so the page is not simply blank")
            check(
                (value("document.getElementById('rel').href") as? String)?.hasPrefix("texttank-preview://") == true,
                "\(name): a relative address resolves inside the preview; no base tag is in effect")
            let paths = handler.checkRecord.recentRequestPaths
            check(
                violations.contains("frame-src") && violations.contains("object-src")
                    && !paths.contains { $0.hasSuffix("local.svg") }
                    && !handler.checkRecord.servedLocalFileNames.contains("local.svg"),
                "\(name): the policy refused the frame and the object, and neither was asked for: \(paths.map { $0.split(separator: "/").last ?? "" })")
            let served = handler.checkRecord.pageServeCount
            _ = value("document.getElementById('form').submit(); 1")
            settle(0.2)
            check(
                handler.checkRecord.pageServeCount == served
                    && (value("document.getElementById('marker').textContent") as? String) == "shown",
                "\(name): submitting the form goes nowhere")
        }
        settle(0.3)
        check(listener.connections == 1, "none of these documents made a network connection")
        document.close()
    }

    // MARK: Delivery guard

    /// A coordinator of its own, told about nothing: its tab's revision, kind and location are
    /// changed behind its back while a render is held, so that only the check made when the
    /// result arrives can notice.
    private static func deliveryGuard(root: URL) throws {
        let folder = root.appendingPathComponent("guard")
        let (document, _) = try open("guard.json", "{\"first\": 1}\n", in: folder)
        let editor: TTEditor = document.editor
        let kind = Box<PreviewKind?>(.json)
        let location = Box<URL?>(document.fileURL)
        let pane = PreviewPane(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let coordinator = PreviewCoordinator(
            pane: pane,
            tab: PreviewCoordinator.Tab(
                editor: { editor }, kind: { kind.value }, isLive: { true }, documentName: { "guard.json" },
                documentURL: { location.value }))
        coordinator.debounceInterval = { _ in 0 }
        func idleAndCurrent(_ label: String) -> Bool {
            wait("delivery guard: \(label)", timeout: 8) { coordinator.isIdle && coordinator.isCurrent }
        }
        /// Starts a render and holds it; `change` then alters the tab without telling the coordinator.
        func renderHeld(_ label: String, change: () -> Void) -> (started: Int, applied: Int) {
            let gate = RenderGate()
            coordinator.renderer = gate.renderer(holding: true)
            let applied = coordinator.appliedCount
            coordinator.tabStateChanged()
            wait("\(label): render started") { gate.started.value == 1 }
            let rendersBefore = coordinator.renderCount
            change()
            check(
                coordinator.renderCount == rendersBefore && !coordinator.isIdle,
                "\(label): fixture: the coordinator was not told, and the first render is still the one in flight")
            gate.open.value = true
            _ = idleAndCurrent(label)
            return (gate.started.value, coordinator.appliedCount - applied)
        }
        coordinator.tabStateChanged()
        _ = idleAndCurrent("first render")
        check(pane.outlinePresenter?.tree?.nodes.count == 2, "fixture: the first tree is shown")

        // Each case starts stale, so that tabStateChanged starts a render.
        editor.text = "{\"second\": [1, 2]}\n"
        var outcome = renderHeld("revision") { editor.text = "[1, 2, 3, 4]\n" }
        check(
            outcome.started == 2 && outcome.applied == 1 && pane.outlinePresenter?.tree?.nodes.count == 5,
            "a result for an older revision is dropped and the current text is rendered instead (\(outcome))")

        editor.text = "a,b\n1,2\n"
        outcome = renderHeld("kind") { kind.value = .delimited(",") }
        check(
            outcome.started == 2 && outcome.applied == 1 && pane.tablePresenter?.table?.rowCount == 2
                && pane.outlinePresenter?.scrollView.isHidden == true,
            "a result for a preview kind the document no longer has is dropped; the table is shown, not a tree (\(outcome))"
        )

        editor.text = "c,d\n3,4\n5,6\n"
        let savedAs = folder.appendingPathComponent("elsewhere/renamed.csv")
        outcome = renderHeld("location") { location.value = savedAs }
        check(
            outcome.started == 2 && outcome.applied == 1 && coordinator.isCurrent
                && pane.tablePresenter?.table?.rowCount == 3,
            "a result started before the document was saved somewhere else is dropped and rendered again for the new location (\(outcome))"
        )
        coordinator.invalidate()
        document.close()
    }

    // MARK: Content process loss

    private static func contentProcessLoss(root: URL) throws {
        let (document, tab) = try open("stops.md", "# Stops\n", in: root.appendingPathComponent("loss"))
        tab.setViewMode(.both)
        waitCurrent(tab, "before any loss")
        let coordinator = try requireValue(tab.previewCoordinator, "coordinator")
        let pane = coordinator.pane
        let presenter = try requireValue(pane.webPresenter, "web presenter")
        let web = try requireValue(presenter.webView, "web view")
        let renders = coordinator.renderCount
        check(PreviewCoordinator.contentLossLimit == 2, "fixture: the preview gives up at the second loss")

        // What WebKit calls when the web content process ends.
        presenter.webViewWebContentProcessDidTerminate(web)
        waitCurrent(tab, "after one loss")
        check(
            coordinator.renderCount == renders + 1 && pane.explanation == nil && pageText(tab).contains("Stops"),
            "after the web content process ends once, the page is rendered and shown again")
        presenter.webViewWebContentProcessDidTerminate(web)
        settle(0.5)
        check(
            coordinator.renderCount == renders + 1 && coordinator.isIdle
                && pane.explanation == PreviewMessages.stoppedRepeatedly,
            "after it ends a second time for the same text, nothing more is rendered and the pane says so: \(pane.explanation ?? "nil")"
        )
        check(
            NativeFixtureEnvironment.announcements.filter { $0 == PreviewMessages.stoppedRepeatedly }.count == 1,
            "DS-72 the sentence is announced, once")
        presenter.webViewWebContentProcessDidTerminate(web)
        tab.previewVisibilityChanged()
        settle(0.5)
        check(
            coordinator.renderCount == renders + 1 && presenter.checkRecord.contentLostCount == 3,
            "a third loss, and showing the tab again, still start no render: there is no loop")
        try replace("# Stops", with: "# Starts again", in: tab.primaryEditor)
        waitCurrent(tab, "edit after the losses")
        check(
            coordinator.renderCount == renders + 2 && pane.explanation == nil && pageText(tab).contains("Starts again"),
            "the next edit renders and shows the preview again")
        presenter.webViewWebContentProcessDidTerminate(web)
        waitCurrent(tab, "one loss of the new text")
        check(
            coordinator.renderCount == renders + 3 && pane.explanation == nil,
            "and a loss while showing the new text counts from one again")
        document.close()
    }

    // MARK: Status row of a Preview tab

    private static func descendants<View: NSView>(of view: NSView, as type: View.Type) -> [View] {
        view.subviews.flatMap { [$0 as? View].compactMap { $0 } + descendants(of: $0, as: type) }
    }

    /// Opening a status-row menu of a tab in the other editor group makes that tab the active
    /// one. A tab that shows Preview alone must take the keyboard in its preview, not in its
    /// hidden source, which would make it show Both.
    private static func statusRowKeepsPreview(root: URL, host: WorkspaceWindowController) throws {
        let folder = root.appendingPathComponent("status")
        let (previewed, previewTab) = try open("previewed.md", "# Previewed\n", in: folder)
        let (other, otherTab) = try open("other.md", "# Other\n", in: folder)
        check(host.setEditorLayout(.twoColumns), "fixture: two editor groups")
        let otherID = try requireValue(otherTab.tabID, "tab id")
        host.moveTabs([otherID], target: otherID, to: .second)
        let moved = try requireValue(
            host.model.groups.first { $0.slot == .second }?.tabs.first { $0.documentID == other.runtimeID }?.id,
            "moved tab")
        let second = try requireValue(host.presentation(for: moved), "tab in the second group")
        host.activate(previewTab)
        check(previewTab.setViewMode(.preview), "fixture: the first group's tab shows Preview")
        waitCurrent(previewTab, "previewed tab")
        host.activate(second)
        host.window?.makeFirstResponder(second.primaryEditor)
        settle(0.1)
        check(
            host.active === second && previewTab.isPresented && previewTab.viewMode == .preview
                && !previewTab.previewHasFocus,
            "fixture: the keyboard is in the other group; the Preview tab is on screen and not active")

        let row = try requireValue(
            descendants(of: previewTab.presentationRoot, as: StatusBadgeRow.self).first, "the tab's status row")
        let menu = row.menuProvider?(.encoding)
        settle(0.1)
        check(menu != nil && host.active === previewTab, "opening a status-row menu makes its tab the active one")
        check(
            previewTab.viewMode == .preview && previewTab.split.isHidden,
            "and a tab that shows Preview keeps showing Preview: \(previewTab.viewMode.rawValue)")
        check(
            previewTab.previewHasFocus,
            "the keyboard goes to the tab's preview, the view its typing would be seen in")
        // A tab that shows its source still takes the keyboard in its editor.
        let menuOfSource = descendants(of: second.presentationRoot, as: StatusBadgeRow.self).first?.menuProvider?(
            .encoding)
        settle(0.1)
        check(
            menuOfSource != nil && host.active === second
                && (host.window?.firstResponder as? NSView)?.isDescendant(of: second.split) == true,
            "a tab that shows Source takes the keyboard in its editor, as before")
        check(host.setEditorLayout(.single), "fixture: back to one group")
        previewed.close()
        other.close()
    }

    // MARK: Narrow pane

    /// At the narrowest pane the Go to Error button must not take the sentence's width (DS-67).
    private static func narrowPane() throws {
        guard case .invalid(let partial, let error) = JSONTree.parse("{\"a\": 1,\n\"b\": oops}", isCancelled: { false })
        else {
            Checks.fail("fixture: invalid JSON with an error", file: #filePath, line: #line)
            return
        }
        let minimum = DocumentViewContainer.minimumPaneWidth
        check(
            PreviewPane.stacksMessage(width: minimum, hasButton: true)
                && !PreviewPane.stacksMessage(width: minimum, hasButton: false)
                && !PreviewPane.stacksMessage(width: PreviewPane.stackedMessageWidth, hasButton: true),
            "the button goes under the sentence only when there is a button and the pane is narrow")
        func frames(width: CGFloat) -> (pane: PreviewPane, label: NSRect, button: NSRect, textHeight: CGFloat) {
            let pane = PreviewPane(frame: NSRect(x: 0, y: 0, width: width, height: 400))
            pane.show(.tree(partial, error: error, limit: nil), documentURL: nil)
            pane.layoutSubtreeIfNeeded()
            let label = pane.messageLabel.convert(pane.messageLabel.bounds, to: pane)
            let button = pane.goToErrorButton.convert(pane.goToErrorButton.bounds, to: pane)
            let needed =
                pane.messageLabel.cell?.cellSize(
                    forBounds: NSRect(x: 0, y: 0, width: label.width, height: 10_000)
                ).height ?? 0
            return (pane, label, button, needed)
        }
        let narrow = frames(width: minimum)
        check(
            narrow.pane.message == error.message && !narrow.pane.goToErrorButton.isHidden,
            "fixture: the pane shows the error sentence and Go to Error")
        check(
            narrow.label.width >= minimum - 21 && narrow.label.height + 0.5 >= narrow.textHeight,
            "DS-67 at \(Int(minimum)) points the sentence keeps the pane's width and shows all its lines: \(narrow.label) for text \(narrow.textHeight) pt tall"
        )
        check(
            !narrow.label.intersects(narrow.button) && narrow.button.maxY <= narrow.label.minY + 0.5
                && narrow.button.minX >= 0 && narrow.button.maxX <= minimum
                && narrow.button.width >= narrow.pane.goToErrorButton.fittingSize.width - 0.5,
            "DS-67 the button is under the sentence, whole and inside the pane: \(narrow.button)")
        let wide = frames(width: 600)
        check(
            wide.button.minX >= wide.label.maxX && wide.button.maxX <= 600 && wide.label.intersects(
                NSRect(x: 0, y: wide.button.minY, width: 600, height: wide.button.height)),
            "in a pane with room the button stays beside the sentence: \(wide.label) \(wide.button)")
        // The same pane follows a change of width.
        wide.pane.setFrameSize(NSSize(width: minimum, height: 400))
        wide.pane.layoutSubtreeIfNeeded()
        let relaid = wide.pane.messageLabel.convert(wide.pane.messageLabel.bounds, to: wide.pane)
        check(relaid.width >= minimum - 21, "a pane made narrow lays the row out again: \(relaid)")
    }

    // MARK: Fail closed

    private static func failClosed(root: URL) throws {
        let rules = PreviewContentRules.shared
        guard case .ready(let compiled) = rules.state else {
            Checks.fail("the rule list was compiled by the earlier checks", file: #filePath, line: #line)
            return
        }
        check(
            PreviewContentRules.source.contains("\"url-filter\": \".*\"")
                && PreviewContentRules.source.contains("block")
                && PreviewContentRules.source.contains("^texttank-preview:"),
            "the rule list blocks every load and exempts only the preview scheme")
        defer { rules.replaceStateForChecks(.ready(compiled)) }
        check(
            PreviewMessages.unavailable.contains("Nothing was loaded.")
                && PreviewMessages.unavailable.hasSuffix("Quit TextTank and open it again to try once more."),
            "DS-81 the sentence for rules that could not be prepared says what to do next")
        for (state, sentence) in [
            (PreviewContentRules.State.failed, PreviewMessages.unavailable),
            (PreviewContentRules.State.compiling, PreviewMessages.notReady)
        ] {
            rules.replaceStateForChecks(state)
            let announcedBefore = NativeFixtureEnvironment.announcements.filter { $0 == sentence }.count
            let (document, tab) = try open(
                "closed-\(sentence.count).md", "# Must not load\n", in: root.appendingPathComponent("closed"))
            tab.setViewMode(.both)
            wait("render handed to the presenter") {
                tab.previewCoordinator?.isIdle == true && tab.previewCoordinator?.isCurrent == true
            }
            settle(0.3)
            let pane = try requireValue(tab.previewCoordinator?.pane, "pane")
            check(
                pane.webPresenter?.webView == nil && pane.webPresenter?.handler.checkRecord.pageServeCount == 0
                    && pane.explanation == sentence,
                "without the rule list no web view is made and nothing is loaded: \(pane.explanation ?? "nil")")
            check(
                NativeFixtureEnvironment.announcements.filter { $0 == sentence }.count == announcedBefore + 1,
                "DS-72 the sentence shown in place of the page is announced, once")
            if case .compiling = state {
                rules.replaceStateForChecks(.ready(compiled))
                wait("page loads once the rules are ready") {
                    pane.webPresenter?.isSettled == true && pane.webPresenter?.webView != nil
                }
                check(
                    pageText(tab).contains("Must not load") && pane.explanation == nil,
                    "the page that waited is shown once the rule list is ready")
            }
            document.close()
        }
    }
}
