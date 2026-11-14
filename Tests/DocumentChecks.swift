// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@main struct DocumentChecks {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool,_ label:String) throws {
        guard try condition() else { fatalError("FAILED: \(label)") }; checks += 1
        print("PASS \(label)"); fflush(stdout)
    }
    @MainActor static func rejects(_ label:String,_ work:() throws -> Void) {
        do { try work(); fatalError("FAILED expected rejection: \(label)") } catch { checks += 1; print("PASS \(label): \(error.localizedDescription)"); fflush(stdout) }
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func inspectGeometry(_ editor: TTEditor, label: String) throws {
        for view in descendants(editor) {
            print("GEOMETRY \(label) \(type(of:view)) frame=\(view.frame) bounds=\(view.bounds) visible=\(view.visibleRect)")
        }
        fflush(stdout)
        let contents = descendants(editor).compactMap { ($0 as? NSScrollView)?.documentView }
        try check(contents.count == 1,"\(label) one Scintilla content view")
        guard let content = contents.first else { return }
        try check(content.visibleRect.width > 100 && content.visibleRect.height > 100,"\(label) content viewport has visible area")
        try check(content.frame.minY >= 0 && content.frame.minX >= 0,"\(label) content origin not offscreen")
        if let scroll = descendants(editor).first(where: { $0 is NSScrollView }) as? NSScrollView {
            try check(scroll.contentView.bounds.minY >= 0 && scroll.contentView.bounds.minY < content.frame.height,"\(label) clip origin inside content")
        }
    }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TextTankDocumentChecks-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        setenv("TEXTTANK_SUPPORT_DIRECTORY",root.appendingPathComponent("support").path,1)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        print("SCREENS \(NSScreen.screens.map { $0.frame })"); fflush(stdout)
        let automation = AutomationController(editorProvider:{nil},newDocument:{_ in fatalError("Saving must not run a workflow")})
        let configuration = AutomationLibrary(workflows:[.example])
        try automation.persistLibrary(configuration)
        let support = root.appendingPathComponent("support"), configurationURL = support.appendingPathComponent("Automations.json")
        let supportMode = (try FileManager.default.attributesOfItem(atPath:support.path)[.posixPermissions] as! NSNumber).intValue
        let configMode = (try FileManager.default.attributesOfItem(atPath:configurationURL.path)[.posixPermissions] as! NSNumber).intValue
        try check(supportMode == 0o700 && configMode == 0o600,"automation configuration private at creation")
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:configurationURL.path)
        try automation.persistLibrary(configuration)
        let replacedConfigMode = (try FileManager.default.attributesOfItem(atPath:configurationURL.path)[.posixPermissions] as! NSNumber).intValue
        try check(replacedConfigMode == 0o600,"automation atomic replacement restores private metadata")
        let configBytes = try Data(contentsOf:configurationURL)
        try check(AutomationLibrary.decode(configBytes) == configuration,"private automation save retains exact definition")
        try FileManager.default.removeItem(at:configurationURL)
        let alternate = root.appendingPathComponent("untouched-config.json"); try configBytes.write(to:alternate)
        try FileManager.default.createSymbolicLink(at:configurationURL,withDestinationURL:alternate)
        rejects("automation persistence rejects symlink target") { try automation.persistLibrary(configuration) }
        try check(Data(contentsOf:alternate) == configBytes,"automation symlink target unchanged")
        try FileManager.default.removeItem(at:configurationURL)
        let bomDocument = TextDocument()
        let doubleBOM = Data([0xEF,0xBB,0xBF,0xEF,0xBB,0xBF,0x61])
        try bomDocument.read(from:doubleBOM,ofType:"Plain Text")
        try check(bomDocument.editor.text == "\u{FEFF}a","file BOM stripped once, content FEFF preserved in editor")
        try check(bomDocument.data(ofType:"Plain Text") == doubleBOM,"native document double BOM exact byte roundtrip")
        bomDocument.close()
        let original = root.appendingPathComponent("document.txt")
        let initial = Data("first\r\nsecond\n👩🏽‍💻\0\r".utf8)
        try initial.write(to:original)
        let document = TextDocument(); document.fileURL = original; document.fileType = "Plain Text"
        NSDocumentController.shared.addDocument(document)
        try document.read(from:initial,ofType:"Plain Text")
        try check(document.data(ofType:"Plain Text") == initial,"native document exact bytes roundtrip")
        document.makeWindowControllers()
        print("OBSERVED controllers=\(document.windowControllers.count) windows=\(NSApp.windows.count)"); fflush(stdout)
        try check(document.windowControllers.count == 1,"NSDocument owns one window controller")
        guard let controller = document.windowControllers.first as? EditorWindowController, let window = controller.window else { fatalError("missing controller/window") }
        try check(controller.document === document && window.windowController === controller,"native controller document/window ownership")
        document.showWindows()
        window.orderFront(nil)
        try check(window.isVisible,"native window visible after showWindows")
        try check(window.contentView != nil && document.editor.window === window,"editor attached to visible document window")
        document.editor.executeCommand("selectAll"); document.editor.replaceSelection("local edits 😀\r\n")
        try check(document.editor.modified && document.isDocumentEdited,"editing marks engine and NSDocument dirty")
        document.flushRecovery()
        try check(TextDocument.recovery.load(id:document.recoveryID).text == document.editor.text,"native edits flush exact recovery snapshot")
        try Data("external edit".utf8).write(to:original)
        rejects("external conflict refuses overwrite") { try document.writeSafely(to:original,ofType:"Plain Text",for:.saveOperation) }
        try check(Data(contentsOf:original) == Data("external edit".utf8),"external bytes preserved after conflict")
        try check(document.editor.modified && document.isDocumentEdited,"failed save remains dirty")
        try check(document.editor.text == "local edits 😀\r\n","failed save retains local edits")
        let blocked = root.appendingPathComponent("blocked"); try Data("not a directory".utf8).write(to:blocked)
        rejects("native save denied path") { try document.writeSafely(to:blocked.appendingPathComponent("child.txt"),ofType:"Plain Text",for:.saveAsOperation) }
        try check(document.editor.modified && document.isDocumentEdited,"denied-path save remains dirty")
        let saved = root.appendingPathComponent("saved-as.txt")
        try document.writeSafely(to:saved,ofType:"Plain Text",for:.saveAsOperation)
        try check(Data(contentsOf:saved) == Data("local edits 😀\r\n".utf8),"native Save As writes exact editor bytes")
        try check(!document.editor.modified && !document.isDocumentEdited,"successful save clears engine/document dirty state")
        document.fileURL = saved
        document.editor.executeCommand("selectAll"); document.editor.replaceSelection("copy-only text")
        let copy = root.appendingPathComponent("copy.txt")
        try document.writeSafely(to:copy,ofType:"Plain Text",for:.saveToOperation)
        try check(Data(contentsOf:copy) == Data("copy-only text".utf8),"Save Copy writes exact bytes")
        try check(document.editor.modified && document.isDocumentEdited,"Save Copy retains source dirty state")
        try check(Data(contentsOf:saved) == Data("local edits 😀\r\n".utf8),"Save Copy does not overwrite source")
        document.editor.executeCommand("undo")
        try FileManager.default.setAttributes([.posixPermissions:0o640],ofItemAtPath:saved.path)
        document.editor.executeCommand("selectAll"); document.editor.replaceSelection("normal save")
        try document.writeSafely(to:saved,ofType:"Plain Text",for:.saveOperation)
        try check(Data(contentsOf:saved) == Data("normal save".utf8),"normal Save writes existing file")
        let mode = (try FileManager.default.attributesOfItem(atPath:saved.path)[.posixPermissions] as! NSNumber).intValue
        try check(mode == 0o640,"native Save preserves file permission metadata")
        document.editor.executeCommand("selectAll"); document.editor.replaceSelection("local edits 😀\r\n")
        try document.writeSafely(to:saved,ofType:"Plain Text",for:.saveOperation)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        print("APP-GEOMETRY window=\(window.frame) root=\(String(describing:window.contentView?.frame)) split=\(controller.split.frame) rootAmbiguous=\(window.contentView?.hasAmbiguousLayout ?? false)"); fflush(stdout)
        try inspectGeometry(document.editor,label:"before-clone")
        controller.clone(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let clone = controller.secondary else { fatalError("clone missing") }
        try inspectGeometry(document.editor,label:"source-after-clone")
        try inspectGeometry(clone,label:"clone")
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            content.cacheDisplay(in:content.bounds,to:bitmap)
            if let png = bitmap.representation(using:.png,properties:[:]) { try png.write(to:URL(fileURLWithPath:"build/tests/document-clone.png")) }
        }
        clone.executeCommand("selectAll"); clone.replaceSelection("clone changed shared document")
        try check(document.editor.text == clone.text,"clone changes authoritative shared bytes")
        try check(document.isDocumentEdited && document.editor.modified,"clone notifications mark owner dirty")
        controller.closeSplit(nil)
        try check(controller.secondary == nil && document.editor.text == "clone changed shared document","closing clone preserves owner buffer")
        document.editor.executeCommand("undo")
        try check(document.editor.text == "local edits 😀\r\n","shared undo survives closing clone")
        document.editor.executeCommand("selectAll"); document.editor.replaceSelection("unsaved before read")
        try document.read(from:Data("reloaded".utf8),ofType:"Plain Text")
        document.editor.executeCommand("undo")
        try check(document.editor.text == "reloaded" && !document.editor.modified,"read resets undo history and engine dirty state")
        document.editor.executeCommand("selectAll"); document.editor.replaceSelection("unsaved before actual revert")
        try Data("reverted from disk".utf8).write(to:saved)
        try document.revert(toContentsOf:saved,ofType:"Plain Text")
        document.editor.executeCommand("undo")
        try check(document.editor.text == "reverted from disk","actual NSDocument revert replaces text and clears undo")
        try check(!document.editor.modified && !document.isDocumentEdited,"actual NSDocument revert clears both dirty states")
        document.close()
        try check(!window.isVisible,"closing document hides its native window")
        let termination = AppDelegate().applicationShouldTerminate(app)
        try check(termination == .terminateNow,"clean application quit does not wait for async reply")
        try check(NSDocumentController.shared.documents.isEmpty,"clean quit leaves no owned documents")
        print("PASS DocumentChecks: \(checks) assertions; native AppKit/Scintilla and isolated scratch files")
    }
}
