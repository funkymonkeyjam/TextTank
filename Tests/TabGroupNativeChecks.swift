import AppKit
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

@MainActor private final class GroupCheckContext {
    let isolated: IsolatedSupportDirectory
    init() throws { isolated = try IsolatedSupportDirectory("TabGroupProcess") }
}
@MainActor private final class GroupCheckDelegate: NSObject, NSApplicationDelegate {
    var launched: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ note: Notification) { launched?() }
}
@MainActor private final class RetiredGroupViews {
    weak var primary: TTEditor?
    weak var clone: TTEditor?
    weak var adapter: EditorWindowController?
}
@MainActor enum TabGroupNativeChecks {
    static func runApplicationProcess() -> Never {
        do {
            let context = try GroupCheckContext()
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            NativeFixtureEnvironment.install()
            let documents = TextDocumentController(), app = NSApplication.shared, delegate = GroupCheckDelegate()
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            delegate.launched = {
                let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        Checks.run("TabGroupNativeChecks") {
                            defer {
                                context.isolated.restore()
                                NativeFixtureEnvironment.restore()
                            }
                            check(
                                NSDocumentController.shared === documents && app.isRunning,
                                "T3 owned actual AppKit controller/loop")
                            try run(root: context.isolated.url)
                            Checks.summary { "PASS TabGroupNativeChecks: \(Checks.count) native assertions" }
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .default)
            }
            withExtendedLifetime(delegate) { app.run() }
        } catch { Checks.fail("T3 native setup: \(error)", file: #filePath, line: #line) }
        Checks.finish("TabGroupNativeChecks")
    }
    static func run(root: URL) throws {
        let priorDelegate = NSApp.delegate, priorServices = EditorServices.current,
            front = NSWorkspace.shared.frontmostApplication
        let app = AppDelegate()
        NSApp.delegate = app
        app.installEditorServices()
        app.buildMenus()
        let host = app.workspaceWindow, commands = host.tabCommands
        let window = try requireValue(host.window, "T3 owned host")
        NSApp.activate(ignoringOtherApps: true)
        defer {
            commands.isTerminating = true
            NSDocumentController.shared.documents.forEach { $0.close() }
            commands.isTerminating = false
            commands.clearHistory()
            window.orderOut(nil)
            EditorServices.current = priorServices
            NSApp.delegate = priorDelegate
            front?.activate(options: [.activateAllWindows])
        }
        check(
            host.model.groups[0].tabs.isEmpty && NSDocumentController.shared.documents.isEmpty,
            "T3 cold host has no prewarmed document or removed Clone")
        let retired = RetiredGroupViews()
        @MainActor func openSharedAndCloseOriginal(_ document: TextDocument) throws -> TabID {
            let a = try requireValue(document.presentation, "T3 original adapter")
            let aid = try requireValue(host.model.activeTab?.id, "T3 original TabID")
            a.clone(nil)
            retired.primary = a.primaryEditor
            retired.clone = a.secondary
            retired.adapter = a
            check(host.setEditorLayout(.twoColumns), "T3 internal two-group layout accepted")
            let bid = try requireValue(host.openView(aid, in: .second), "T3 distinct additional view")
            let b = try requireValue(host.presentation(for: bid), "T3 second adapter")
            b.clone(nil)
            check(
                a.primaryEditor !== b.primaryEditor && b.primaryEditor.sharesDocument(with: a.primaryEditor),
                "T3 distinct primary editors share actual Scintilla document")
            check(
                a.secondary != nil && b.secondary != nil && b.secondary!.sharesDocument(with: a.primaryEditor),
                "T3 both tab-local Clones share document")
            check(a.isPresented && b.isPresented, "T3 cold release has both real group presentations mounted")
            host.closeTab(aid, sender: nil)
            check(
                document.isOpen && host.model.groups.flatMap(\.tabs).count == 1 && window.attachedSheet == nil,
                "T3 non-final original tab close never prompts or closes document")
            check(document.editor === b.primaryEditor, "T3 surviving primary receives document service ownership")
            return bid
        }
        let (document, bid) = try autoreleasepool {
            let document = DocumentFactory.makeUntitled()
            document.editor.text = "one\ntwo\nthree\n"
            document.presentation?.showWindow(nil)
            return (document, try openSharedAndCloseOriginal(document))
        }
        // Drain setup’s native temporary collections, without prewarming any removal.
        spinUntil("T3 cold original primary Clone and adapter release") {
            retired.primary == nil && retired.clone == nil && retired.adapter == nil
        }
        check(
            retired.primary == nil && retired.clone == nil && retired.adapter == nil,
            "T3 R13 cold original views weak-release without warming or hidden editor")
        let b = try requireValue(host.presentation(for: bid), "T3 surviving adapter")
        let old = b.primaryEditor.text, oldRevision = b.primaryEditor.revision
        b.secondary!.text = "changed through surviving Clone"
        check(
            b.primaryEditor.text == "changed through surviving Clone" && document.editor.text == b.primaryEditor.text
                && document.isDocumentEdited, "T3 surviving Clone edit updates one dirty shared document")
        check(
            b.primaryEditor.revision > oldRevision && b.primaryEditor.revision == b.secondary!.revision,
            "T3 promotion preserves coherent increasing revision")
        b.primaryEditor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(
            b.primaryEditor.text == old && b.secondary!.text == old, "T3 Undo from surviving primary reverts Clone edit"
        )
        check(NSDocumentController.shared.documents.count == 1, "T3 additional views retain exactly one NSDocument")
        let surface = try requireValue(host.groupSurfaces[.second], "T3 second native surface")
        let priorFrame = surface.frame
        surface.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        surface.layoutSubtreeIfNeeded()
        b.showFind(nil)
        surface.layoutSubtreeIfNeeded()
        b.presentationRoot.layoutSubtreeIfNeeded()
        for control in [b.findField, b.replaceField, b.caseBox, b.findNextButton, b.replaceMatchButton] as [NSView] {
            let rect = b.presentationRoot.convert(control.bounds, from: control)
            check(
                b.presentationRoot.bounds.insetBy(dx: -1, dy: -1).contains(rect) && !control.isHidden,
                "T3 all essential Find controls fit 320x200 group: \(type(of:control))")
        }
        print(
            "T3 narrow geometry surface=\(surface.frame) root=\(b.presentationRoot.frame) split=\(b.split.frame) primary=\(b.primaryEditor.frame) clone=\(String(describing:b.secondary?.frame))"
        )
        fflush(stdout)
        check(
            b.split.frame.height >= 30 && b.primaryEditor.frame.width >= 100,
            "T3 minimum pane retains visible editor with Find")
        b.hideFind(nil)
        surface.frame = priorFrame
        surface.layoutSubtreeIfNeeded()
        // This cold process intentionally starts with release; additional cases follow only after it passes.
    }
}
