import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

@MainActor private final class QuitHost: NSObject, NSApplicationDelegate {
    let documents: TextDocumentController
    let delegate = AppDelegate()
    let mode: String
    var expected = "Don’t Save", chosen = false
    var first: TextDocument!, second: TextDocument!, closeButton: NSButton!
    var expectedNames = [String]()
    var before = Data()
    var expectedUntitled = ""
    var presses = 0
    init(_ documents: TextDocumentController, mode: String) {
        self.documents = documents
        self.mode = mode
    }
    func require(_ yes: Bool, _ label: String) {
        print(yes ? "PASS" : "FAIL", label)
        fflush(stdout)
        if !yes { exit(1) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        print("GENUINE AppKit applicationShouldTerminate", documents.documents.count)
        return delegate.applicationShouldTerminate(sender)
    }
    func applicationWillTerminate(_ notification: Notification) {
        do {
            let s = try requireValue(LastSessionLayout.read(AppStorage.url(.lastSession)), "final session on disk")
            if mode.hasPrefix("held-cancel") {
                // The second quit went ahead: one review, for the file, and the untitled text kept.
                require(
                    presses == 2, "the two quits pressed Cancel once and Don’t Save once, and nothing else was asked")
                require(
                    s.version == 2 && s.untitled?.count == 1 && s.files.count == 2,
                    "the committed quit names the untitled document beside the files")
                let id = try requireValue(s.untitled?.first?.id.rawValue, "kept untitled identity")
                require(
                    s.layout.layout == .twoColumns && s.layout.groups[1].tabs.map(\.documentID.rawValue) == [id],
                    "the untitled tab is still alone in the second group")
                require(
                    try TextDocument.recovery.load(id: id).text == expectedUntitled,
                    "the recovery copy on disk is the untitled document's text")
                require(
                    try Data(contentsOf: AppStorage.supportDirectory.appendingPathComponent("first.txt"))
                        == Data("first".utf8), "the file's discarded edit was not written")
                print("PASS GENUINE", mode)
                fflush(stdout)
                return
            }
            if mode.hasPrefix("untitled") {
                // DS-D9: the genuine terminate path asked nothing and kept the untitled text.
                require(!chosen, "no review appeared for unsaved untitled text")
                require(
                    s.version == 2 && s.untitled?.count == 1 && s.files.count == 2,
                    "committed native quit names the untitled document beside the files")
                let id = try requireValue(s.untitled?.first?.id.rawValue, "kept untitled identity")
                require(
                    s.layout.groups[0].tabs.map(\.documentID.rawValue).firstIndex(of: id) == 1
                        && s.layout.groups[0].tabs[1].caretByte == 4,
                    "the untitled tab keeps its place between the files and its caret")
                require(
                    try TextDocument.recovery.load(id: id).text == expectedUntitled,
                    "the recovery copy on disk is the untitled document's text")
                print("PASS GENUINE", mode)
                fflush(stdout)
                return
            }
            require(
                s.files.map { $0.url.lastPathComponent }.sorted() == expectedNames.sorted(),
                "committed native quit retained the open file paths")
            for (name, value) in [("first.txt", "first"), ("second.txt", "second")] {
                require(
                    try Data(contentsOf: AppStorage.supportDirectory.appendingPathComponent(name)) == Data(value.utf8),
                    "disk original unchanged " + name)
            }
            require(!NSApp.isActive, "native process stayed nonactivating")
            print("PASS GENUINE", mode)
            fflush(stdout)
        } catch {
            print("FAIL", error)
            fflush(stdout)
            exit(1)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await start() } catch {
                print("FAIL", error)
                fflush(stdout)
                exit(1)
            }
        }
    }
    func start() async throws {
        precondition(
            !AppStorage.permitsLegacyDefaults && NSApp.activationPolicy() == .prohibited
                && NSDocumentController.shared === documents)
        LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
        delegate.installEditorServices()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        if mode == "untitled-relaunch" {
            try await relaunchWithKeptUntitled()
            return
        }
        require(
            documents.documents.isEmpty && !NSApp.windows.contains(where: \.isVisible)
                && !FileManager.default.fileExists(atPath: AppStorage.url(.lastSession).path),
            "cold background invocation creates no editor or visible window")
        let foreground = Notification(name: NSApplication.didBecomeActiveNotification)
        delegate.applicationDidBecomeActive(foreground)
        let restoreDeadline = Date().addingTimeInterval(5)
        while documents.documents.isEmpty && Date() < restoreDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let initial = documents.documents.first
        require(
            initial != nil && documents.documents.count == 1,
            "foreground restores the single ordinary first-run document")
        delegate.applicationDidBecomeActive(foreground)
        require(
            documents.documents.count == 1 && documents.documents.first === initial,
            "repeated activation preserves the same first window")
        documents.documents.forEach { $0.close() }
        func open(_ name: String) throws -> TextDocument {
            let u = AppStorage.supportDirectory.appendingPathComponent(name + ".txt")
            try Data(name.utf8).write(to: u)
            return try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(u), from: u, display: false)
        }
        if mode.hasPrefix("held-cancel") {
            try await heldUntitledSurvivesCancelledQuit(open)
            return
        }
        first = try open("first")
        if mode == "untitled" {
            let kept = DocumentFactory.makeUntitled(display: false)
            expectedUntitled = "UNTITLED KEPT 🥝\nsecond line"
            _ = kept.editor.replaceSelection(expectedUntitled)
            _ = kept.editor.setSelectionAnchor(4, caret: 4)
        }
        second = try open("second")
        delegate.checkpointSession()
        let limit = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: AppStorage.url(.lastSession).path) && Date() < limit {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        before = try Data(contentsOf: AppStorage.url(.lastSession))
        if mode != "untitled" { _ = first.editor.replaceSelection("DIRTY") }
        closeButton = delegate.workspaceWindow.window!.standardWindowButton(.closeButton)!
        expectedNames = ["first.txt", "second.txt"]
        if mode == "cancel" { expected = "Cancel" }
        let t = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pressReview() }
        }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .modalPanel)
        print("ACTUAL red", mode)
        fflush(stdout)
        closeButton.performClick(nil)
        if mode == "cancel" {
            let stop = Date().addingTimeInterval(10)
            while (!chosen || NSApp.modalWindow != nil || delegate.workspaceWindow.window?.attachedSheet != nil)
                && Date() < stop
            { try await Task.sleep(nanoseconds: 10_000_000) }
            let data = try Data(contentsOf: AppStorage.url(.lastSession))
            require(
                chosen && first.isOpen && first.isDocumentEdited && data == before,
                "native Cancel preserves dirty buffer and prior exact checkpoint")
            expectedNames = documents.documents.compactMap { $0.fileURL?.lastPathComponent }
            chosen = false
            expected = "Don’t Save"
            print("SECOND red", expectedNames)
            fflush(stdout)
            closeButton.performClick(nil)
        }
    }
    /// The real launch path: recovery scan, session restore, no recovery question.
    func relaunchWithKeptUntitled() async throws {
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        let deadline = Date().addingTimeInterval(8)
        while documents.documents.count < 3 && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let open = documents.documents.compactMap { $0 as? TextDocument }
        let kept = try requireValue(open.first { $0.fileURL == nil }, "the untitled document reopened at launch")
        let host = delegate.workspaceWindow
        require(
            open.count == 3 && NSApp.modalWindow == nil && host.window?.attachedSheet == nil,
            "launch reopened two files and the untitled document without a question")
        require(
            kept.editor.text == "UNTITLED KEPT 🥝\nsecond line" && kept.isDocumentEdited
                && kept.editor.selectionCaret == 4 && kept.editor.selectionAnchor == 4,
            "launch restored the untitled text, still edited, with its caret")
        require(
            host.presentations.map { ($0.document as? TextDocument)?.fileURL?.lastPathComponent ?? "untitled" }
                == ["first.txt", "untitled", "second.txt"],
            "launch restored the tab order")
        require(
            host.lastTabMessage == AppDelegate.restoredUntitledNotice(1), "a status message says text was restored")
        _ = kept.editor.replaceSelection("AGAIN ")
        _ = kept.editor.setSelectionAnchor(4, caret: 4)
        expectedUntitled = kept.editor.text
        closeButton = host.window!.standardWindowButton(.closeButton)!
        let t = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pressReview() }
        }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .modalPanel)
        print("ACTUAL red", mode)
        fflush(stdout)
        closeButton.performClick(nil)
    }
    /// Finding 1 of fix round 1. An edited untitled document and a file with unsaved edits, in two
    /// groups: the quit is cancelled at the file's review. Nothing may have closed, and the
    /// untitled tab must be exactly as it was. The second quit then goes ahead.
    /// Mode: held-cancel-<untitledFirst|fileFirst>-<red|quit>.
    func heldUntitledSurvivesCancelledQuit(_ open: (String) throws -> TextDocument) async throws {
        let untitledFirst = mode.contains("untitledFirst"), red = mode.hasSuffix("red")
        func makeUntitled() -> TextDocument {
            let document = DocumentFactory.makeUntitled(display: false)
            _ = document.editor.replaceSelection("held text\n")
            _ = document.editor.replaceSelection("second edit 🥝")
            _ = document.editor.setSelectionAnchor(7, caret: 2)
            return document
        }
        var untitled: TextDocument!
        if untitledFirst { untitled = makeUntitled() }
        first = try open("first")
        second = try open("second")
        if !untitledFirst { untitled = makeUntitled() }
        let host = delegate.workspaceWindow
        require(
            host.setEditorLayout(.twoColumns, availableContent: TabGroupExtent(width: 4000, height: 3000)),
            "fixture: two editor groups")
        let tab = try requireValue(untitled.presentation?.tabID, "fixture: the untitled tab")
        host.moveTabs([tab], target: tab, to: .second)
        _ = first.editor.replaceSelection("DIRTY")
        host.activate(try requireValue(first.presentation, "fixture: the file's tab"))
        expectedUntitled = untitled.editor.text
        let layout = host.captureSessionLayout(), revision = untitled.editor.revision
        let open = documents.documents.map(ObjectIdentifier.init)
        require(
            layout.layout == .twoColumns && layout.groups[1].tabs.count == 1 && untitled.isDocumentEdited,
            "fixture: the edited untitled document is alone in the second group")
        closeButton = host.window!.standardWindowButton(.closeButton)!
        func quit() {
            print("ACTUAL", red ? "red" : "quit", mode)
            fflush(stdout)
            if red { closeButton.performClick(nil) } else { NSApp.terminate(nil) }
        }
        expected = "Cancel"
        let t = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pressReview() }
        }
        RunLoop.main.add(t, forMode: .common)
        RunLoop.main.add(t, forMode: .modalPanel)
        // terminate(_:) does not return while the review is up when it is called directly.
        DispatchQueue.main.async { quit() }
        let stop = Date().addingTimeInterval(10)
        while (!chosen || NSApp.modalWindow != nil || host.window?.attachedSheet != nil) && Date() < stop {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        require(chosen && presses == 1, "the cancelled quit asked once, about the file")
        require(
            Set(documents.documents.map(ObjectIdentifier.init)) == Set(open) && untitled.isOpen && first.isOpen
                && second.isOpen,
            "after the cancelled quit every document is still open and registered")
        require(host.captureSessionLayout() == layout, "every tab is in its group and place, with its selection")
        require(
            untitled.isDocumentEdited && !untitled.isHeldForQuit && untitled.editor.text == expectedUntitled
                && untitled.editor.revision == revision && untitled.editor.selectionAnchor == 7
                && untitled.editor.selectionCaret == 2 && untitled.presentation?.tabID == tab,
            "the untitled document is still edited, with its text, caret and selection untouched")
        @MainActor func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { all($0) } }
        let strip = host.window?.contentView.map { all($0) } ?? []
        require(
            strip.contains {
                ($0.accessibilityLabel() ?? "").hasPrefix("Untitled")
                    && ($0.accessibilityLabel() ?? "").contains("dited")
            },
            "the untitled tab still says it is edited")
        untitled.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        require(untitled.editor.text == "held text\n", "Undo still has the untitled document's history")
        untitled.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "redo"))
        _ = untitled.editor.setSelectionAnchor(7, caret: 2)
        require(untitled.editor.text == expectedUntitled, "and Redo")
        require(first.isDocumentEdited && first.editor.text == "DIRTYfirst", "the file keeps its unsaved edit")
        chosen = false
        expected = "Don’t Save"
        DispatchQueue.main.async { quit() }
    }
    func pressReview() {
        guard !chosen else { return }
        func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
        // Only a review: a sheet or an app-modal window. The workspace window has buttons of its
        // own with these titles (the status row's Cancel), and they are not an answer to a review.
        let buttons = NSApp.windows.filter { $0.sheetParent != nil || $0 === NSApp.modalWindow }.compactMap(
            \.contentView
        ).flatMap(descend).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        if let b = buttons.first(where: {
            $0.title == expected || (expected == "Don’t Save" && ["Don't Save", "Discard", "Delete"].contains($0.title))
        }) {
            chosen = true
            presses += 1
            print("ACTUAL choice", b.title)
            fflush(stdout)
            b.performClick(nil)
        }
    }
}
@MainActor enum AutomaticSessionQuitChecks {
    static func runChild(mode: String) -> Never {
        precondition(
            (["fresh", "cancel", "untitled", "untitled-relaunch"].contains(mode) || mode.hasPrefix("held-cancel-"))
                && !AppStorage.permitsLegacyDefaults)
        alarm(30)
        let documents = TextDocumentController(), app = NSApplication.shared
        let host = QuitHost(documents, mode: mode)
        app.delegate = host
        withExtendedLifetime(host) { app.run() }
        exit(1)
    }
    static func checkBoth(in root: URL) throws {
        for mode in ["fresh", "cancel"] {
            try runGenuine([mode], in: root.appendingPathComponent("native-quit-" + mode))
        }
    }
    /// DS-D9 through AppKit's own terminate: a quit with unsaved untitled text, then a launch
    /// from what that quit left, then a second quit. Both processes share one support folder.
    static func checkUntitled(in root: URL) throws {
        try runGenuine(["untitled", "untitled-relaunch"], in: root.appendingPathComponent("native-quit-untitled"))
    }
    /// A cancelled quit closes nothing: both orders of opening, the red button and Quit.
    static func checkHeldCancel(in root: URL) throws {
        for order in ["untitledFirst", "fileFirst"] {
            for trigger in ["red", "quit"] {
                let mode = "held-cancel-\(order)-\(trigger)"
                try runGenuine([mode], in: root.appendingPathComponent("native-quit-" + mode))
            }
        }
    }
    private static func runGenuine(_ modes: [String], in scratch: URL) throws {
        let support = scratch.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for mode in modes {
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--automatic-session-quit", mode]
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = scratch.path
            environment["TEXTTANK_SUPPORT_DIRECTORY"] = support.path
            child.environment = environment
            child.standardOutput = output
            child.standardError = output
            try child.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            let report = String(decoding: bytes, as: UTF8.self)
            print(report)
            check(
                child.terminationReason == .exit && child.terminationStatus == 0
                    && report.split(separator: "\n").contains(Substring("PASS GENUINE " + mode)),
                "genuine native red close and process termination " + mode)
        }
    }
}
