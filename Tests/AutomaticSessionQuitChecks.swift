import AppKit
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
        delegate.buildMenus()
        delegate.restoreLaunchDocuments(review: { _ in }, report: { _ in self.require(false, "startup notice") })
        documents.documents.forEach { $0.close() }
        func open(_ name: String) throws -> TextDocument {
            let u = AppStorage.supportDirectory.appendingPathComponent(name + ".txt")
            try Data(name.utf8).write(to: u)
            return try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(u), from: u, display: false)
        }
        first = try open("first")
        second = try open("second")
        delegate.checkpointSession()
        let limit = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: AppStorage.url(.lastSession).path) && Date() < limit {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        before = try Data(contentsOf: AppStorage.url(.lastSession))
        _ = first.editor.replaceSelection("DIRTY")
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
    func pressReview() {
        guard !chosen else { return }
        func descend(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descend) }
        let buttons = NSApp.windows.filter { $0.isVisible || $0.sheetParent != nil }.compactMap(\.contentView).flatMap(
            descend
        ).compactMap { $0 as? NSButton }
        if let b = buttons.first(where: {
            $0.title == expected || (expected == "Don’t Save" && ["Don't Save", "Discard"].contains($0.title))
        }) {
            chosen = true
            print("ACTUAL choice", b.title)
            fflush(stdout)
            b.performClick(nil)
        }
    }
}
@MainActor enum AutomaticSessionQuitChecks {
    static func runChild(mode: String) -> Never {
        precondition(["fresh", "cancel"].contains(mode) && !AppStorage.permitsLegacyDefaults)
        alarm(30)
        let documents = TextDocumentController(), app = NSApplication.shared
        let host = QuitHost(documents, mode: mode)
        app.delegate = host
        withExtendedLifetime(host) { app.run() }
        exit(1)
    }
    static func checkBoth(in root: URL) throws {
        for mode in ["fresh", "cancel"] {
            let scratch = root.appendingPathComponent("native-quit-" + mode)
            let support = scratch.appendingPathComponent("support")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
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
