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
        Checks.section("SVG") { try svg(root: root, listener: listener) }
        Checks.section("delimited text") { try delimited(root: root) }
        Checks.section("JSON") { try json(root: root) }
        Checks.section("staleness and lifetime") { try stalenessAndLifetime(root: root, host: host) }
        Checks.section("close during a render") { try closeMidRender(root: root) }
        Checks.section("limits and timing") { try limitsAndTiming(root: root) }
        Checks.section("session capture and restore") { try sessionRestore(root: root, host: host) }
        Checks.section("fail closed") { try failClosed(root: root) }
        settle(0.5)
        check(
            listener.connections == allowedConnections,
            "no preview made any network connection in the whole run (listener saw \(listener.connections - allowedConnections))"
        )
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
            Array(view.items.prefix(3)).map(\.title) == ["Source", "Preview", "Both"] && view.items[3].isSeparatorItem,
            "the three commands and a separator open the View menu")

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
            <link rel="dns-prefetch" href="\(base)">
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
            tab.previewCoordinator?.renderCount == 1 && presenter.loadCount == 1 && presenter.contentLostCount == 0,
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
        let served = handler.servedLocalFiles.map(\.lastPathComponent).sorted()
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
        check(
            handler.pageServeCount == 1,
            "the meta refresh did not reload the page: \(handler.recentRequestPaths.count) requests, \(presenter.recentDecisions.map { "\($0.url?.absoluteString ?? "nil") \($0.decision)" })"
        )

        // Navigation: nothing leaves the page except a clicked external link, through the opener.
        let pageURL = web.url
        opened.value = []
        func unchanged(_ label: String) {
            settle(0.3)
            let trace = presenter.recentDecisions.suffix(3).map { "\($0.url?.absoluteString ?? "nil") \($0.decision)" }
            check(
                (script(web, "location.href") as? String) == pageURL?.absoluteString && web.title == "Fixture"
                    && opened.value.isEmpty
                    && handler.pageServeCount == 1 && listener.connections == 1,
                "navigation cancelled, nothing loaded, no connection: \(label) \(trace) served \(handler.pageServeCount) connections \(listener.connections - 1) title \(web.title ?? "nil")"
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
        _ = script(web, "document.getElementById('anchor').click(); 1")
        settle(0.2)
        check(
            web.url?.fragment == "heading" && handler.pageServeCount == 1,
            "an anchor inside the page is followed without a reload")
        _ = script(web, "document.getElementById('pinged').click(); 1")
        settle(0.4)
        check(listener.connections == 1, "a link's ping is not sent (\(listener.connections - 1))")
        _ = script(web, "document.getElementById('external').click(); 1")
        wait("external link routed") { !opened.value.isEmpty }
        check(
            opened.value == [URL(string: "\(base)/clicked")!],
            "a clicked http link is handed to the opener, once: \(opened.value)")
        settle(0.5)
        check(
            listener.connections == 1,
            "and the web view itself made no connection for the click or its ping (\(listener.connections - 1))")
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
            untitledHandler.servedLocalFiles.isEmpty && untitledHandler.refusedLocalFiles == 2
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
            presenter.handler.imageServeCount == 1 && presenter.handler.lastServedImage == Data(image.utf8),
            "the image is the document's current text, served from memory as an image")
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
        let servedText = String(decoding: presenter.handler.lastServedImage ?? Data(), as: UTF8.self)
        check(
            presenter.handler.imageServeCount == 2 && servedText.contains("fill=\"blue\" rx=\"4\"")
                && !servedText.contains("fill=\"red\""),
            "editing the fill renders again and serves the new image bytes")

        tab.primaryEditor.text = "<?xml version=\"1.0\"?>\n<note><to>someone</to></note>\n"
        waitCurrent(tab, "not an SVG")
        check(
            pane.explanation == SVGPolicy.notSVGMessage && presenter.view.isHidden
                && presenter.handler.imageServeCount == 2,
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
        func measure(_ name: String, _ text: String) throws {
            let (document, tab) = try open(name, "x\n", in: folder)
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
            _ = tab.primaryEditor.setSelectionAnchor(0, caret: 0)
            let typingStart = ProcessInfo.processInfo.systemUptime
            _ = tab.primaryEditor.replaceSelection("y")
            let typing = ProcessInfo.processInfo.systemUptime - typingStart
            print(
                String(
                    format:
                        "TIMING %@ %.1f MiB: render %.3f s off the main thread; apply on main %.4f s; longest main-thread gap while rendering %.3f s over %d turns; one keystroke %.4f s (Debug build)",
                    name, Double(bytes) / 1_048_576, gate.seconds.value, coordinator.lastApplySeconds, longestGap,
                    turns, typing))
            check(!gate.ranOnMainThread.value && gate.started.value >= 1, "\(name): the parse ran off the main thread")
            check(
                coordinator.lastApplySeconds < 0.25,
                "\(name): applying the result took \(String(format: "%.4f", coordinator.lastApplySeconds)) s of main-thread time"
            )
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
        try measure("big.json", "[\n" + String(repeating: member, count: count - 1) + "{\"last\": null}\n]\n")
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

        var forPlain = try record(plain)
        forPlain.viewMode = .both
        plainTab.restoreSessionTab(forPlain)
        check(
            plainTab.viewMode == .source && plainTab.previewCoordinator == nil,
            "a restored mode is not applied to a document that no longer has a preview")
        markdown.close()
        plain.close()
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
        for (state, sentence) in [
            (PreviewContentRules.State.failed, PreviewMessages.unavailable),
            (PreviewContentRules.State.compiling, PreviewMessages.notReady)
        ] {
            rules.replaceStateForChecks(state)
            let (document, tab) = try open(
                "closed-\(sentence.count).md", "# Must not load\n", in: root.appendingPathComponent("closed"))
            tab.setViewMode(.both)
            wait("render handed to the presenter") {
                tab.previewCoordinator?.isIdle == true && tab.previewCoordinator?.isCurrent == true
            }
            settle(0.3)
            let pane = try requireValue(tab.previewCoordinator?.pane, "pane")
            check(
                pane.webPresenter?.webView == nil && pane.webPresenter?.handler.pageServeCount == 0
                    && pane.explanation == sentence,
                "without the rule list no web view is made and nothing is loaded: \(pane.explanation ?? "nil")")
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
