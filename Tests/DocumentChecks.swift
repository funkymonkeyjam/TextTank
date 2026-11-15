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
        let settings=SettingsController(url:root.appendingPathComponent("Settings.json"))
        var configured=EditorSettings();configured.tabWidth=8;configured.useTabs=false;configured.wrap=true;configured.shortcuts=["upper":"u"]
        try settings.save(configured)
        try check(SettingsController(url:settings.url).value == configured,"versioned settings persist across controller restart")
        var conflict=configured;conflict.shortcuts=["upper":"d"]
        rejects("shortcut conflicts with default command binding") {try settings.save(conflict)}
        conflict.shortcuts=["upper":","]
        rejects("shortcut cannot steal Settings") {try settings.save(conflict)}
        conflict.shortcuts=["upper":"u","lower":"u"]
        rejects("duplicate custom shortcuts rejected") {try settings.save(conflict)}
        try check(SettingsController(url:settings.url).value == configured,"rejected settings retain prior on-disk configuration")
        conflict.version=99
        rejects("future settings version rejected") {try settings.save(conflict)}
        try check(EditorTransform.sortAscending.transform("b\r\na\n") == "a\r\nb\n","line sorting retains mixed separator positions")
        try check(EditorTransform.reverseLines.transform("a\nb") == "b\na","reverse retains absence of final EOL")
        try check(EditorTransform.uniqueLines.transform("a\na\nb\n") == "a\nb\n","duplicate removal preserves kept row separators")
        try check(EditorTransform.trimBoth.transform(" \tα  \r\n b\t") == "α\r\nb","trim preserves Unicode and EOL")
        try check(EditorTransform.uniqueLines.transform("é\ne\u{301}\n").utf8.elementsEqual("é\ne\u{301}\n".utf8),"duplicate removal preserves canonically equivalent distinct bytes")
        let transformed=TextDocument();transformed.editor.text="b\na\n";transformed.editor.resetUndoHistory()
        try EditorTransform.sortAscending.apply(to:transformed.editor)
        try check(transformed.editor.text == "a\nb\n","native line sorting changes authoritative buffer")
        transformed.editor.executeCommand("undo")
        try check(transformed.editor.text == "b\na\n","native line sorting one Undo")
        transformed.close()
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
        let columnRevision=document.editor.revision,columnSelections=document.editor.selectionRanges
        _ = document.editor.setSelectionAnchor(0,caret:1)
        try check(!EditorWindowController.applyColumn(["X"],to:document.editor,revision:columnRevision,selections:columnSelections),"column dialog stale selection cannot edit different range")
        try check(document.editor.text.utf8.elementsEqual(String(decoding:initial,as:UTF8.self).utf8),"rejected column leaves original bytes unchanged")
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
        let priorDelegate=app.delegate
        let cloneDelegate=AppDelegate();app.delegate=cloneDelegate
        var cloneSettings=EditorSettings();cloneSettings.wrap=true;cloneSettings.tabWidth=8;cloneSettings.useTabs=false
        try cloneDelegate.settings.save(cloneSettings)
        controller.clone(nil)
        try check(controller.secondary?.wrap == true && controller.secondary?.menu != nil,"new clone inherits persisted view settings and automation context")
        app.delegate=priorDelegate
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
        document.editor.replaceSelection("unsaved")
        rejects("reinterpretation refuses dirty editor without discard") { try document.reload(using:.latin1) }
        let protectedText=document.editor.text
        try Data([0xC3]).write(to:saved)
        rejects("invalid explicit reload preserves buffer") { try document.reload(using:.utf8,discard:true) }
        try check(document.editor.text == protectedText && document.isDocumentEdited,"failed reload preserves dirty text")
        try check(try document.diskState() == .changed,"external byte changes detected")
        try Data([0x63,0x61,0x66,0xE9]).write(to:saved)
        try document.reload(using:.latin1,discard:true)
        try check(document.editor.text == "café" && document.format.encoding == .latin1,"explicit encoding reinterpretation reads disk bytes")
        try check(!document.isDocumentEdited && !document.editor.modified,"successful reload resets dirty state")
        try check(try document.diskState() == .unchanged,"reload updates external-change baseline")
        document.editor.readOnly=true
        try Data("locked reload".utf8).write(to:saved)
        try document.reload(using:.utf8)
        try check(document.editor.text == "locked reload" && document.editor.readOnly,"explicit reload works while retaining read-only flag")
        document.close()
        try check(!window.isVisible,"closing document hides its native window")
        NotificationCenter.default.post(name:NSWindow.didUpdateNotification,object:window)
        app.updateWindows()
        try check(controller.focusObserver == nil && controller.automationObserver == nil,"close removes callbacks before document detaches")
        try check(controller.activeEditor === document.editor,"late retained controller access does not force-cast detached document")
        try check(window.standardWindowButton(.closeButton)?.isHidden == false,"native close control is visible")
        let closeControl = controller.toolbar(NSToolbar(identifier:"test"),itemForItemIdentifier:.init("TextTank.CloseTab"),willBeInsertedIntoToolbar:true)
        try check((closeControl?.view as? NSButton)?.title == "Close Tab","explicit close button remains accessible outside titlebar")
        let snapshotText = "\u{FEFF}café😀\n2 eggs\0"
        let snapshot=SessionDocument(id:UUID(),originalURL:saved,text:snapshotText,format:FileFormat(encoding:.utf16LE,bom:true),isDirty:true,selection:SessionSelection(anchorByte:snapshotText.utf8.count,caretByte:3),bookmarks:[1],language:"python",originalSHA256:WorkspaceStore.fingerprint(try Data(contentsOf:saved)))
        let session=WorkspaceSession(id:UUID(),name:"Native session regression",documents:[snapshot],activeDocumentID:snapshot.id)
        let originalBytes=try Data(contentsOf:saved)
        let restored=try WorkspaceController().restore(session)
        try check(restored.count == 1 && restored[0].editor.text == snapshotText,"session restores Unicode FEFF NUL snapshot into native editor")
        try check(restored[0].fileURL == nil && restored[0].isDocumentEdited,"session snapshot is unsaved and detached from original")
        try check(try Data(contentsOf:saved) == originalBytes,"session restore never overwrites original file")
        try check(restored[0].editor.selectionAnchor == snapshotText.utf8.count && restored[0].editor.selectionCaret == 3,"session restores reversed byte selection")
        try check(restored[0].editor.bookmarkLines.map(\.intValue) == [1],"session restores bookmark lines")
        try check(restored[0].format == snapshot.format && restored[0].languageIdentifier == "python","session restores encoding and language metadata")
        let recoveredSession = try TextDocument.recovery.loadAll().first { $0.id == restored[0].recoveryID }
        try check(recoveredSession?.text == snapshotText,"restored session has durable recovery snapshot")
        let recaptured=try WorkspaceController().capture(name:"Captured native documents")
        try check(recaptured.documents.contains { $0.text == snapshotText && $0.selection == snapshot.selection },"session capture reads authoritative editor selection and contents")
        let printRevision=restored[0].editor.revision
        let printOperation=try restored[0].printOperation(withSettings:[:])
        try check((printOperation.view as? NSTextView)?.string == snapshotText,"native print view contains exact authoritative Unicode text")
        try check(restored[0].editor.revision == printRevision && restored[0].isDocumentEdited,"preparing print does not change editor or dirty state")
        let emptySnapshot=SessionDocument(id:UUID(),text:"",format:FileFormat(encoding:.utf8,bom:false),isDirty:true,selection:SessionSelection(anchorByte:0,caretByte:0))
        let emptySession=WorkspaceSession(id:UUID(),name:"Empty restored document",documents:[emptySnapshot])
        let emptyRestored=try WorkspaceController().restore(emptySession)
        let emptyRecovery=try TextDocument.recovery.loadAll().first { $0.id == emptyRestored[0].recoveryID }
        try check(emptyRestored[0].isDocumentEdited && emptyRecovery?.text == "","empty dirty session restoration retains a recovery snapshot")
        emptyRestored.forEach { $0.close() }
        restored.forEach { $0.close() }
        let tabA=TextDocument(), tabB=TextDocument()
        for doc in [tabA,tabB] { NSDocumentController.shared.addDocument(doc);doc.makeWindowControllers();doc.showWindows() }
        let winA=tabA.windowControllers[0].window!,winB=tabB.windowControllers[0].window!
        try check(!winA.isVisible && winB.isVisible,"only selected compact tab is visible")
        winB.setFrame(NSRect(x:150,y:150,width:900,height:650),display:true)
        winA.makeKeyAndOrderFront(nil)
        try check(winA.isVisible && !winB.isVisible,"switching tabs changes visible document")
        if !NSScreen.screens.isEmpty {try check(winA.frame == winB.frame,"switching tabs preserves window geometry")} else { print("SKIP window geometry: no screen in native test process") }
        let tabsController=tabA.windowControllers[0] as! EditorWindowController
        tabsController.refreshStatusDetails()
        let buttons=descendants(winA.contentView!).compactMap{$0 as? NSButton}
        let closeB=buttons.first{$0.toolTip == "Close \(winB.title)"}!
        let plus=buttons.first{$0.toolTip == "New tab (⌘N)"}!
        try check(plus.frame.minX<500,"new-tab button follows compact tabs rather than window edge")
        try check(winA.tabbingMode == .disallowed,"native full-width tab strip disabled")
        let heldFrame=winA.frame
        tabA.close()
        try check(winB.isVisible,"closing active tab reveals next")
        if !NSScreen.screens.isEmpty {try check(winB.frame == heldFrame,"closing active tab preserves window geometry")}
        tabB.close()
        let remaining=NSDocumentController.shared.documents.count
        closeB.performClick(nil)
        try check(NSDocumentController.shared.documents.count == remaining,"stale tab close cannot retarget another document")
        let termination = AppDelegate().applicationShouldTerminate(app)
        try check(termination == .terminateNow,"clean application quit does not wait for async reply")
        try check(NSDocumentController.shared.documents.isEmpty,"clean quit leaves no owned documents")
        print("PASS DocumentChecks: \(checks) assertions; native AppKit/Scintilla and isolated scratch files")
    }
}
