// SPDX-License-Identifier: GPL-3.0-or-later
// Audit package 4: behaviour pinned before refactoring. These sections run inside
// document-checks, after the sections in DocumentChecks.swift, and share its
// support directory, application delegate and document controller.
//
// Expected values here were written from the code's documented intent and then
// compared with what the build does. A `knownDefect` line marks behaviour the audit
// confirmed as wrong: it is not pinned as correct, and it fails when it is repaired.
import AppKit

extension DocumentChecks {
    typealias SectionRunner = (_ name:String,_ line:UInt,_ body:() throws -> Void) -> Void

    /// Sends a Scintilla message by number to the engine view inside a TTEditor.
    @MainActor static func sci(_ editor:TTEditor,_ message:UInt32,_ w:UInt=0,_ l:Int=0)->Int {
        typealias Message=@convention(c)(AnyObject,Selector,UInt32,UInt,Int)->Int
        let native=editor.subviews.first!,selector=NSSelectorFromString("message:wParam:lParam:")
        return unsafeBitCast(native.method(for:selector),to:Message.self)(native,selector,message,w,l)
    }
    static func rows(_ text:String)->[(String,String)] {
        var result:[(String,String)]=[],content=""
        for character in text {
            if character == "\r\n" || character == "\r" || character == "\n" { result.append((content,String(character)));content="" } else { content.append(character) }
        }
        if !content.isEmpty || result.isEmpty { result.append((content,"")) }
        return result
    }
    static func same(_ a:String,_ b:String)->Bool { a.utf8.elementsEqual(b.utf8) }

    @MainActor static func pinning(root:URL,app:NSApplication,sessionDelegate:AppDelegate,section:SectionRunner) {
        // F252
        section("every line and case transform",#line) {
            let table:[(EditorTransform,String,String,String)]=[
                (.sortAscending,"b\r\na\nc","a\r\nb\nc","ascending sort keeps each separator in place and adds no final line ending"),
                (.sortDescending,"b\r\na\nc","c\r\nb\na","descending sort keeps each separator in place"),
                (.sortCaseInsensitive,"b\nA\na\nB\n","A\na\nb\nB\n","case-insensitive sort keeps input order between rows that differ only in case"),
                (.sortLength,"ccc\ne\u{301}e\u{301}\nz\n","z\ne\u{301}e\u{301}\nccc\n","length sort counts characters, not bytes or scalars"),
                (.reverseLines,"a\r\nb\rc\n","c\r\nb\ra\n","reverse keeps the separator sequence"),
                (.uniqueLines,"a\nA\na\r\nb","a\nA\nb","duplicate removal is case-sensitive and drops the later row with its separator"),
                (.removeEmptyLines,"a\n\nb\r\n\r\n \nc","a\nb\r\n \nc","empty rows go with their separators; a whitespace-only row is not empty"),
                (.trimLeading," \ta \n\tb","a \nb","leading trim removes spaces and tabs only at the start of each row"),
                (.trimBoth,"\u{3000}a \n b\t\r\n","\u{3000}a\nb\r\n","trim removes ASCII space and tab only, not other Unicode spaces"),
                (.invertCase,"Hello W\u{F6}rld 1 \u{1F600}\r\n","hELLO w\u{D6}RLD 1 \u{1F600}\r\n","invert case swaps cased letters and leaves digits, emoji and line endings"),
                (.titleCase,"hello wORLD\r\nsecond line","Hello World\r\nSecond Line","title case capitalizes each word and keeps line endings"),
            ]
            check(Set(table.map{$0.0}) == Set(EditorTransform.allCases),"the transform table covers every EditorTransform case")
            for (transform,input,expected,label) in table {
                let output=transform.transform(input)
                if !check(same(output,expected),"\(transform.rawValue): \(label)") { print("NOTE \(transform.rawValue) produced \(output.debugDescription)") }
            }
            check(same(EditorTransform.sortAscending.transform("e\u{301}\n\u{E9}\n"),"e\u{301}\n\u{E9}\n") && same(EditorTransform.sortAscending.transform("\u{E9}\ne\u{301}\n"),"\u{E9}\ne\u{301}\n"),"canonically equivalent rows sort as equal and keep their input order and bytes")
            check(same(EditorTransform.removeEmptyLines.transform("\n\n"),"") && same(EditorTransform.sortAscending.transform(""),"") && same(EditorTransform.reverseLines.transform("only"),"only"),"transforms accept empty, all-empty and single-row input")
            // apply(to:) paths
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:300),styleMask:.titled,backing:.buffered,defer:false)
            let editor=TTEditor(frame:NSRect(x:0,y:0,width:500,height:300));window.contentView=editor
            editor.text="c\nb\na\nz\ny\n";editor.resetUndoHistory();editor.setSavePoint()
            _ = editor.setSelectionAnchor(0,caret:6)
            try EditorTransform.sortAscending.apply(to:editor)
            check(editor.text == "a\nb\nc\nz\ny\n","a transform with a selection changes only the selected rows")
            editor.executeCommand("undo")
            check(editor.text == "c\nb\na\nz\ny\n" && !editor.modified,"selection transform is one Undo back to the save point")
            _ = editor.setSelectionAnchor(6,caret:6);editor.text="a\nb\n";editor.resetUndoHistory();editor.setSavePoint()
            let sortedRevision=editor.revision
            try EditorTransform.sortAscending.apply(to:editor)
            check(editor.revision == sortedRevision && !editor.modified,"a transform that changes nothing makes no edit")
            editor.text="b\na\n";editor.resetUndoHistory();editor.setSavePoint();editor.readOnly=true
            let lockedRevision=editor.revision
            rejects("transform refuses a read-only document",message:"Choose one selection in a writable document") { try EditorTransform.sortAscending.apply(to:editor) }
            check(editor.text == "b\na\n" && editor.revision == lockedRevision,"refused read-only transform leaves text and revision unchanged")
            editor.readOnly=false
            try require(editor.setSelectionRanges([["anchor":0,"caret":1],["anchor":2,"caret":3]]),"fixture: two selections")
            rejects("transform refuses multiple selections",message:"Choose one selection in a writable document") { try EditorTransform.reverseLines.apply(to:editor) }
            check(editor.text == "b\na\n" && editor.revision == lockedRevision && editor.selectionCount == 2,"refused multi-selection transform leaves text, revision and selections unchanged")
            let oversize=String(repeating:"a",count:16*1024*1024+1)
            editor.text=oversize;editor.resetUndoHistory();_ = editor.setSelectionAnchor(0,caret:0);let oversizeRevision=editor.revision
            rejects("transform refuses more than 16 MiB",message:"Select at most 16 MiB") { try EditorTransform.invertCase.apply(to:editor) }
            check(editor.revision == oversizeRevision && editor.text.utf8.count == oversize.utf8.count,"refused oversize transform leaves the buffer unchanged")
            editor.text=""
        }
        // G354
        section("shared Unicode fixtures",#line) {
            let idempotent:[EditorTransform]=[.sortAscending,.sortDescending,.sortCaseInsensitive,.sortLength,.uniqueLines,.removeEmptyLines,.trimLeading,.trimBoth,.titleCase]
            let reordering:[EditorTransform]=[.sortAscending,.sortDescending,.sortCaseInsensitive,.sortLength,.reverseLines]
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:300),styleMask:.titled,backing:.buffered,defer:false)
            let editor=TTEditor(frame:NSRect(x:0,y:0,width:500,height:300));window.contentView=editor
            for (name,text) in UnicodeFixtures.all {
                let before=rows(text)
                check(idempotent.allSatisfy{ same($0.transform($0.transform(text)),$0.transform(text)) },"\(name): every sorting, filtering, trimming and title transform is stable when repeated")
                check(reordering.allSatisfy{ transform in
                    let after=rows(transform.transform(text))
                    return after.map{$0.1} == before.map{$0.1} && after.map{Data($0.0.utf8)}.sorted{$0.lexicographicallyPrecedes($1)} == before.map{Data($0.0.utf8)}.sorted{$0.lexicographicallyPrecedes($1)}
                },"\(name): reordering transforms keep every row's exact bytes and the separator sequence")
                check(same(EditorTransform.reverseLines.transform(EditorTransform.reverseLines.transform(text)),text),"\(name): reversing twice restores the exact bytes")
                editor.text=text
                check(same(editor.text,text) && editor.statusInfo["lines"]?.intValue == UnicodeFixtures.lineBreaks(in:text)+1,"\(name): the editor keeps the exact bytes and counts only CR, LF and CRLF as line breaks")
            }
            // The line model is CR, LF and CRLF only. Swift's isNewline and NSString's line
            // APIs also break on these characters, so a rewrite on top of them would change this.
            let single="b"+UnicodeFixtures.nonBreakingSeparators.joined(separator:"a")+"c"
            check(EditorTransform.allCases.filter{ $0 != .invertCase && $0 != .titleCase }.allSatisfy{ same($0.transform(single),single) },"U+2028, U+2029, U+0085, VT and FF are not line breaks for any line transform")
            check(rows(single).count == 1 && UnicodeFixtures.lineBreaks(in:single) == 0,"fixture: the separator row has no CR or LF")
            var automation=AutomationDefinition.example
            automation.steps=[.init(kind:.sortLines)]
            check(same(try automation.transform("b\u{2028}y\na\u{85}x\n"),"a\u{85}x\nb\u{2028}y\n"),"automation sort does not split rows at U+2028 or U+0085")
            automation.steps=[.init(kind:.removeBlankLines)]
            check(same(try automation.transform("a\u{2028}\u{2029}\n\nb\n"),"a\u{2028}\u{2029}\nb\n"),"automation blank-line removal does not treat U+2028 or U+2029 as a row")
            automation.steps=[.init(kind:.trimWhitespace)]
            check(same(try automation.transform(" \(UnicodeFixtures.zwjEmoji) \n\t\(UnicodeFixtures.nfd)\0 \n"),"\(UnicodeFixtures.zwjEmoji)\n\(UnicodeFixtures.nfd)\0\n"),"automation trim keeps ZWJ emoji, combining marks and NUL intact")
            automation.steps=[.init(kind:.removeLinesContaining,find:"needle")]
            check(same(try automation.transform("\(UnicodeFixtures.astralLetter) needle\n\(UnicodeFixtures.astralLetter) keep\n"),"\n\(UnicodeFixtures.astralLetter) keep\n"),"automation contains-filter empties the matching row beside an astral letter and keeps its separator")
            automation.steps=[.init(kind:.removeLinesStartingWith,find:UnicodeFixtures.zwjEmoji)]
            check(same(try automation.transform("\(UnicodeFixtures.zwjEmoji) gone\nkept \(UnicodeFixtures.zwjEmoji)\n"),"\nkept \(UnicodeFixtures.zwjEmoji)\n"),"automation starts-with filter matches a whole ZWJ emoji prefix and keeps the row separator")
            // Confirmed defects (G354 and the findings it lists). Each states the repaired behaviour.
            automation.steps=[.init(kind:.deduplicateLines)]
            knownDefect("G354","automation dedupe keeps canonically equivalent rows whose bytes differ, as Remove Duplicate Lines does",fixed:same(try automation.transform("\(UnicodeFixtures.nfc)\n\(UnicodeFixtures.nfd)\n"),"\(UnicodeFixtures.nfc)\n\(UnicodeFixtures.nfd)\n"))
            knownDefect("G354","Invert Case applied twice restores the original text for \u{DF}",fixed:same(EditorTransform.invertCase.transform(EditorTransform.invertCase.transform("stra\u{DF}e")),"stra\u{DF}e"))
            knownDefect("G354","a filename glob typed precomposed matches a decomposed file name",fixed:FolderSearchFilters.matches("caf\(UnicodeFixtures.nfd).txt","caf\(UnicodeFixtures.nfc).*"))
            var word=SearchOptions();word.query="cat";word.wholeWord=true;word.matchCase=true
            knownDefect("G354","literal whole-word search does not match inside a word that continues with an astral letter",fixed:try SearchCore.search("\(UnicodeFixtures.astralLetter)cat cat",options:word).hits.count == 1)
            word.mode = .regularExpression
            knownDefect("G354","regex whole-word search does not match inside a word that continues with an astral letter",fixed:try SearchCore.search("\(UnicodeFixtures.astralLetter)cat cat",options:word).hits.count == 1)
            var half=SearchOptions();half.query="\\uD83D";half.mode = .extended;half.matchCase=true
            let halfHits=(try? SearchCore.search("a\u{1F600}b",options:half).hits) ?? []
            check(halfHits.isEmpty,"an extended-mode escape for half a surrogate pair does not match inside a character")
        }
        // F243
        section("launch recovery and dirty quit",#line) {
            let namedURL=root.appendingPathComponent("recovery-original.txt"),originalBytes=Data("on disk".utf8)
            try originalBytes.write(to:namedURL)
            let namedFormat=FileFormat(encoding:.utf16LE,bom:true),namedText="named \u{1F600}\r\nwork",untitledText="untitled work\n"
            let named=RecoverySnapshot(id:UUID(),text:namedText,format:namedFormat,originalURL:namedURL.absoluteString,revision:41)
            let untitled=RecoverySnapshot(id:UUID(),text:untitledText,format:FileFormat(encoding:.utf8,bom:false),originalURL:nil,revision:3)
            try TextDocument.recovery.save(named);try TextDocument.recovery.save(untitled)
            let opened=try sessionDelegate.openRecovered([named,untitled])
            try require(opened.count == 2,"fixture: both snapshots opened")
            check(opened[0].recoveryID == named.id && opened[0].editor.text == namedText && opened[0].format == namedFormat && opened[0].isDocumentEdited && opened[0].fileURL == nil,"launch recovery maps a named UTF-16 snapshot to an unsaved untitled document with its id, text and format")
            check(opened[1].recoveryID == untitled.id && opened[1].editor.text == untitledText && opened[1].format == untitled.format && opened[1].isDocumentEdited && opened[1].fileURL == nil,"launch recovery maps an untitled UTF-8 snapshot the same way")
            check(opened.allSatisfy{ NSDocumentController.shared.documents.contains($0) && $0.windowControllers.count == 1 },"recovered documents are registered and have a window controller")
            // The first write lands on originalURL nil. RecoveryStore rejects an equal revision whose
            // metadata differs, so this is the case that separates revision+1 from revision.
            opened[0].flushRecovery()
            let firstWrite=try TextDocument.recovery.load(id:named.id)
            check(opened[0].lastRecoveryError == nil && firstWrite.revision > 41 && firstWrite.originalURL == nil && firstWrite.text == namedText && firstWrite.format == namedFormat,"a recovered document's first flush, before any edit, is accepted at a later revision and detached from the original path")
            opened[0].editor.replaceSelection("edited ");opened[0].flushRecovery()
            let secondWrite=try TextDocument.recovery.load(id:named.id)
            check(secondWrite.revision > firstWrite.revision && secondWrite.text == opened[0].editor.text && opened[0].lastRecoveryError == nil,"an edit after recovery is flushed at a higher revision with the edited text")
            // An empty snapshot is the case where setting the text does not advance the editor's
            // own revision, so only the +1 on the snapshot revision makes the first write later.
            let emptyNamed=RecoverySnapshot(id:UUID(),text:"",format:FileFormat(),originalURL:namedURL.absoluteString,revision:9)
            try TextDocument.recovery.save(emptyNamed)
            let emptyOpened=try sessionDelegate.openRecovered([emptyNamed])
            let emptyWrite=try TextDocument.recovery.load(id:emptyNamed.id)
            check(emptyOpened[0].lastRecoveryError == nil && emptyWrite.revision > 9 && emptyWrite.originalURL == nil && emptyOpened[0].isDocumentEdited,"an empty named snapshot is rewritten at a later revision on recovery, not rejected as stale")
            check(try Data(contentsOf:namedURL) == originalBytes,"launch recovery never writes the original file")
            let good=RecoverySnapshot(id:UUID(),text:"before the bad one",format:FileFormat(),originalURL:nil,revision:1)
            let overflowing=RecoverySnapshot(id:UUID(),text:"x",format:FileFormat(),originalURL:nil,revision:UInt64.max)
            let never=RecoverySnapshot(id:UUID(),text:"after the bad one",format:FileFormat(),originalURL:nil,revision:1)
            let openBefore=NSDocumentController.shared.documents.count
            rejects("a snapshot whose revision cannot advance stops launch recovery",expecting:RecoveryError.invalidSnapshot) { _ = try sessionDelegate.openRecovered([good,overflowing,never]) }
            let survivors=NSDocumentController.shared.documents.compactMap{$0 as? TextDocument}
            check(NSDocumentController.shared.documents.count == openBefore+1 && survivors.contains{ $0.recoveryID == good.id && $0.editor.text == "before the bad one" } && !survivors.contains{ $0.recoveryID == never.id || $0.recoveryID == overflowing.id },"snapshots opened before a failing one stay open; the failing one and those after it are not opened")
            survivors.forEach{ $0.close() }
            check(try !TextDocument.recovery.loadAll().contains{ [named.id,untitled.id,good.id].contains($0.id) },"closing recovered documents removes their snapshots")
            // Dirty quit: the review request and the reply are observed, never presented or sent.
            let quitting=AppDelegate();var reviews=0,replies:[Bool]=[]
            quitting.requestUnsavedReview={ delegate in if delegate === quitting { reviews += 1 } }
            quitting.replyToTerminate={ replies.append($0) }
            let dirty=TextDocument();NSDocumentController.shared.addDocument(dirty);dirty.editor.text="unsaved at quit"
            let clean=TextDocument();NSDocumentController.shared.addDocument(clean)
            check(quitting.applicationShouldTerminate(app) == .terminateLater && reviews == 0 && NSDocumentController.shared.documents.count == 2,"quit with an unsaved document waits for the review and closes nothing yet")
            spinUntil("the unsaved-documents review to be requested"){ reviews == 1 }
            RunLoop.current.run(until:Date().addingTimeInterval(0.05))
            check(reviews == 1 && replies.isEmpty,"the unsaved-documents review is requested exactly once and nothing is replied before it finishes")
            quitting.reviewed(NSDocumentController.shared,didReviewAll:false,contextInfo:nil)
            check(replies == [false] && NSDocumentController.shared.documents.count == 2 && dirty.editor.text == "unsaved at quit" && dirty.isDocumentEdited,"a cancelled review replies false and leaves every document open with its text")
            quitting.reviewed(NSDocumentController.shared,didReviewAll:true,contextInfo:nil)
            check(replies == [false,true] && NSDocumentController.shared.documents.isEmpty,"a completed review closes every document and replies true")
        }
        // G342
        section("split view focus and per-view state",#line) {
            let priorDelegate=app.delegate,splitDelegate=AppDelegate();app.delegate=splitDelegate
            defer { app.delegate=priorDelegate }
            var viewSettings=EditorSettings();viewSettings.tabWidth=8;viewSettings.useTabs=false
            try splitDelegate.settings.save(viewSettings)
            defer { try? splitDelegate.settings.save(EditorSettings()) }
            let url=root.appendingPathComponent("split-view.txt");try Data("zero\none\ntwo\n".utf8).write(to:url)
            let document=TextDocument();document.fileURL=url;document.fileType="Plain Text"
            NSDocumentController.shared.addDocument(document)
            try document.read(from:try Data(contentsOf:url),ofType:"Plain Text")
            document.makeWindowControllers();document.showWindows()
            let controller=try requireValue(document.windowControllers.first as? EditorWindowController,"fixture: editor window controller"),window=try requireValue(controller.window,"fixture: window")
            let primaryStatus=document.editor.statusInfo
            check(primaryStatus["tabWidth"]?.intValue == 8 && primaryStatus["useTabs"]?.boolValue == false,"the primary view takes the saved tab settings")
            weak var released:TTEditor?
            try autoreleasepool {
                controller.clone(nil)
                let clone=try requireValue(controller.secondary,"fixture: clone view");released=clone
                check(controller.activeEditor === clone && controller.lastEditor === clone,"a new clone becomes the active editor")
                let cloneStatus=clone.statusInfo
                check(cloneStatus["tabWidth"]?.intValue == 8 && cloneStatus["useTabs"]?.boolValue == false && document.editor.statusInfo["tabWidth"]?.intValue == 8 && document.editor.statusInfo["useTabs"]?.boolValue == false,"the clone takes the saved tab settings and the primary view keeps its own")
                clone.configureTabWidth(2,useTabs:true)
                // Scintilla keeps tab width and tabs-or-spaces in the document, so a clone cannot
                // differ from the primary view, although the status menu calls them view settings.
                check(document.editor.statusInfo["tabWidth"]?.intValue == 2 && document.editor.statusInfo["useTabs"]?.boolValue == true && clone.statusInfo["tabWidth"]?.intValue == 2,"tab settings changed through the clone apply to the shared document and so to both views")
                clone.configureTabWidth(8,useTabs:false)
                check(window.makeFirstResponder(document.editor) && controller.activeEditor === document.editor && controller.lastEditor === document.editor,"focusing the primary view makes it the active editor")
                check(window.makeFirstResponder(clone) && controller.activeEditor === clone,"focusing the clone makes it the active editor again")
                window.makeFirstResponder(nil)
                check(controller.activeEditor === clone,"with no editor focused the last focused view stays active")
                let cloneRevision=clone.revision,primaryRevision=document.editor.revision
                _ = clone.setSelectionAnchor(0,caret:0);clone.replaceSelection("c")
                _ = document.editor.setSelectionAnchor(0,caret:0);document.editor.replaceSelection("p")
                check(document.editor.text == "pczero\none\ntwo\n" && clone.text == document.editor.text,"edits from either view land in the one shared buffer")
                check(clone.revision > cloneRevision && document.editor.revision > primaryRevision && clone.revision-cloneRevision == document.editor.revision-primaryRevision,"both views' revision counters advance by the same amount for edits from either side")
                check(clone.revision == document.editor.revision,"the two views report the same revision")
                document.editor.executeCommand("undo");clone.executeCommand("undo")
                check(document.editor.text == "zero\none\ntwo\n" && !document.isDocumentEdited,"undo from each view returns the shared buffer to its save point")
                let indicatorAllOnFor:UInt32=2506,searchIndicator=1<<20
                check(document.editor.setSearchHighlights([NSValue(range:NSRange(location:0,length:4))]) && sci(clone,indicatorAllOnFor,1) & searchIndicator != 0 && sci(clone,indicatorAllOnFor,5) & searchIndicator == 0,"a search highlight set through the primary view is present in the clone")
                clone.clearSearchHighlights()
                check(sci(document.editor,indicatorAllOnFor,1) & searchIndicator == 0,"clearing highlights through the clone clears them in the primary view")
                clone.replaceSelection("dirty before reload")
                try Data("reloaded with a clone open\n".utf8).write(to:url)
                try document.reload(using:.utf8,discard:true)
                check(document.editor.text == "reloaded with a clone open\n" && clone.text == document.editor.text && !document.isDocumentEdited && !clone.modified,"reload with a clone open replaces the text in both views and clears the dirty state")
                check(clone.revision == document.editor.revision,"the two views report the same revision after a reload")
                document.editor.readOnly=true
                let item=NSMenuItem(title:"Read Only",action:nil,keyEquivalent:"");document.toggleReadOnly(item)
                check(!document.editor.readOnly && !clone.readOnly && item.state == .off,"Read Only toggles both views together")
                check(window.makeFirstResponder(clone) && controller.activeEditor === clone,"fixture: the clone is active before the split closes")
                controller.closeSplit(nil)
                check(controller.secondary == nil && controller.activeEditor === document.editor && controller.lastEditor === document.editor,"closing the split returns the active editor to the primary view")
            }
            for _ in 0..<10 where released != nil { autoreleasepool { window.displayIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.05)) } }
            // A bare TTEditor, one sharing this document and one removed from a split view in a
            // plain window are all released (probed while writing this check); the clone made by
            // EditorWindowController.clone is not. What still holds it has not been identified.
            weak var bare:TTEditor?
            autoreleasepool { let editor=TTEditor(frame:NSRect(x:0,y:0,width:100,height:100));editor.shareDocument(with:document.editor);bare=editor }
            check(bare == nil,"a view that shared the document and was dropped is released")
            knownDefect("G342","the closed clone view is released",fixed:released == nil)
            check(document.editor.text == "reloaded with a clone open\n" && !document.isDocumentEdited,"closing the split keeps the buffer and its clean state")
            document.close()
        }
        // G355: one committed file per persisted format, written by the build of 15 November 2026
        // through the production writers. Each must keep decoding, through the production
        // reader, to exactly these values. Adding a non-optional field to a persisted type
        // without a decoder for old files fails here. TEXTTANK_WRITE_PERSISTENCE_FIXTURES=1
        // rewrites the files; do that only for a deliberate, versioned format change.
        section("persisted format golden fixtures",#line) {
            let folder=TestPaths.fixtures.appendingPathComponent("persistence",isDirectory:true)
            let writing=ProcessInfo.processInfo.environment["TEXTTANK_WRITE_PERSISTENCE_FIXTURES"] != nil
            let scratch=root.appendingPathComponent("persistence-scratch",isDirectory:true)
            try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
            if writing { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true) }
            func golden(_ name:String,_ produce:()throws->Data)throws->Data {
                let url=folder.appendingPathComponent(name)
                if writing { try produce().write(to:url);print("WROTE \(url.path)") }
                return try Data(contentsOf:url)
            }
            func copy(_ data:Data,_ name:String)throws->URL { let url=scratch.appendingPathComponent(name);try data.write(to:url);return url }
            let stamp=Date(timeIntervalSinceReferenceDate:784_000_000),idA=UUID(uuidString:"11111111-2222-4333-8444-555555555555")!,idB=UUID(uuidString:"66666666-7777-4888-9999-AAAAAAAAAAAA")!
            let suiteName="TextTankPersistenceFixtures-"+UUID().uuidString
            let defaults=try requireValue(UserDefaults(suiteName:suiteName),"fixture: isolated defaults suite");defer { defaults.removePersistentDomain(forName:suiteName) }

            var settings=EditorSettings();settings.tabWidth=8;settings.useTabs=false;settings.wrap=true;settings.appearance="dark";settings.shortcuts=["upper":"u","joinLines":"J"]
            let settingsBytes=try golden("Settings.json") { let url=scratch.appendingPathComponent("write-Settings.json");try SettingsController(url:url).save(settings);return try Data(contentsOf:url) }
            let settingsReader=SettingsController(url:try copy(settingsBytes,"Settings.json"))
            check(try EditorSettings.decode(settingsBytes) == settings && settingsReader.value == settings && settingsReader.loadError == nil,"golden Settings.json decodes to the recorded editor settings")

            var search=SearchOptions();search.query="([a-z]+)=(\\d+)";search.replacement="$1:$2";search.mode = .regularExpression;search.matchCase=true;search.wholeWord=true;search.dotMatchesNewline=true;search.wrap=false
            let searchBytes=try golden("SearchOptions.json") {
                // The Find window writes its options when an action reads the controls.
                let writer=SearchController(defaults:defaults)
                writer.queryField.stringValue=search.query;writer.replacementField.stringValue=search.replacement;writer.mode.selectItem(at:search.mode.rawValue)
                writer.caseButton.state = .on;writer.wordButton.state = .on;writer.dotButton.state = .on;writer.wrapButton.state = .off
                writer.findAll(nil);writer.cancel(nil)
                return try requireValue(defaults.data(forKey:"TextTank.Search.v1"),"fixture: the Find window saved its options")
            }
            defaults.set(searchBytes,forKey:"TextTank.Search.v1")
            let finder=SearchController(defaults:defaults)
            check(try JSONDecoder().decode(SearchOptions.self,from:searchBytes) == search && finder.queryField.stringValue == search.query && finder.replacementField.stringValue == search.replacement && finder.mode.indexOfSelectedItem == 2 && finder.caseButton.state == .on && finder.wordButton.state == .on && finder.dotButton.state == .on && finder.wrapButton.state == .off,"golden Find options decode and restore every Find-window control")

            var folderSettings=FolderSearchSettings();folderSettings.folder=URL(fileURLWithPath:"/Users/Shared/TextTank Fixture/project",isDirectory:true);folderSettings.workspaceScope=true;folderSettings.recursive=false;folderSettings.includeHidden=true;folderSettings.extensions="txt, swift";folderSettings.filters="*.swift !*Tests* !+\\build";folderSettings.options=search
            let folderBytes=try golden("FolderSearchSettings.json") { try folderSettings.save(defaults);return try requireValue(defaults.data(forKey:"TextTank.FolderSearch.v1"),"fixture: folder settings saved") }
            defaults.set(folderBytes,forKey:"TextTank.FolderSearch.v1")
            check(try FolderSearchSettings.load(defaults) == folderSettings,"golden Find-in-Folder settings decode to the recorded values")

            var browser=WorkspaceBrowserState();browser.folders=[URL(fileURLWithPath:"/Users/Shared/TextTank Fixture/project",isDirectory:true),URL(fileURLWithPath:"/Users/Shared/TextTank Fixture/notes",isDirectory:true)];browser.recent=[URL(fileURLWithPath:"/Users/Shared/TextTank Fixture/project/caf\u{E9} \u{1F600}.txt")]
            let browserBytes=try golden("WorkspaceBrowser.json") { let url=scratch.appendingPathComponent("write-WorkspaceBrowser.json");try WorkspaceBrowserStore(url:url).save(browser);return try Data(contentsOf:url) }
            let browserReader=WorkspaceBrowserStore(url:try copy(browserBytes,"WorkspaceBrowser.json"))
            check(browserReader.loadError == nil && browserReader.state == browser,"golden workspace browser state decodes to the recorded folders and recent files")

            let runs=[ConfiguredRun(id:idA,name:"Word count",executable:"/usr/bin/wc",arguments:["-w","{file}"]),ConfiguredRun(id:idB,name:"Shell filter",executable:"/bin/zsh",arguments:["-c","sort | uniq"],shellMode:true),ConfiguredRun(id:UUID(uuidString:"BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF")!,name:"Extension",executable:"/usr/local/bin/texttank-extension",arguments:["{selection}"],extensionMode:true)]
            let runBytes=try golden("RunLibrary.json") { try ConfiguredRun.encodeLibrary(runs) }
            check(try ConfiguredRun.decodeLibrary(runBytes) == runs,"golden Run library decodes to the recorded commands, including shell and extension modes")

            let sessionText="\u{FEFF}caf\u{E9}\u{1F600}\r\n2 eggs\0"
            let sessionDocument=SessionDocument(id:idA,originalURL:URL(fileURLWithPath:"/Users/Shared/TextTank Fixture/project/list.txt"),text:sessionText,format:FileFormat(encoding:.utf16LE,bom:true),isDirty:true,selection:SessionSelection(anchorByte:sessionText.utf8.count,caretByte:3),bookmarks:[0,1],language:"python",originalSHA256:String(repeating:"ab",count:32))
            var session=WorkspaceSession(id:idB,name:"Golden session",documents:[sessionDocument],activeDocumentID:idA);session.savedAt=stamp
            let sessionBytes=try golden("Session.texttanksession") { let url=scratch.appendingPathComponent("write.texttanksession");try WorkspaceStore.save(session,to:url);return try Data(contentsOf:url) }
            check(try WorkspaceStore.load(from:copy(sessionBytes,"Session.texttanksession")) == session,"golden session file decodes to the recorded dirty document with bookmarks, selection and format")

            var snapshot=RecoverySnapshot(id:idA,text:sessionText,format:FileFormat(encoding:.windows1252,bom:false),originalURL:"file:///Users/Shared/TextTank%20Fixture/project/list.txt",revision:42);snapshot.savedAt=stamp
            let snapshotBytes=try golden("RecoverySnapshot.json") { let store=RecoveryStore(directory:scratch.appendingPathComponent("write-recovery",isDirectory:true));try store.save(snapshot);return try Data(contentsOf:store.fileURL(for:idA)) }
            let recoveryReader=RecoveryStore(directory:scratch.appendingPathComponent("read-recovery",isDirectory:true))
            try FileManager.default.createDirectory(at:recoveryReader.fileURL(for:idA).deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try snapshotBytes.write(to:recoveryReader.fileURL(for:idA));try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:recoveryReader.fileURL(for:idA).path)
            let scanned=try recoveryReader.scan()
            if !check(scanned.issues.isEmpty && scanned.snapshots == [snapshot],"golden recovery snapshot is found by a scan and decodes to the recorded text, format and revision") { print("NOTE recovery scan issues \(scanned.issues.map(\.message))") }

            let batch=ReminderBatch(id:idA,destinationID:"calendar-1",destinationTitle:"Groceries",destinationSource:"iCloud",rows:[ReminderRow(id:idB,title:"2 eggs",status:.confirmed,reminderID:"reminder-9",message:nil),ReminderRow(id:idA,title:"\u{BD} cup flour",status:.uncertain,reminderID:nil,message:"Save was interrupted")],createdAt:stamp)
            let batchBytes=try golden("ReminderBatch.json") { try RemindersConnector.encodedJournal(batch) }
            let decodedBatch=try JSONDecoder().decode(ReminderBatch.self,from:batchBytes)
            check(decodedBatch.schemaVersion == 1 && decodedBatch.id == idA && decodedBatch.destinationID == "calendar-1" && decodedBatch.destinationTitle == "Groceries" && decodedBatch.destinationSource == "iCloud" && decodedBatch.createdAt == stamp && decodedBatch.rows.map(\.id) == [idB,idA] && decodedBatch.rows.map(\.title) == ["2 eggs","\u{BD} cup flour"] && decodedBatch.rows.map(\.status) == [.confirmed,.uncertain] && decodedBatch.rows.map(\.reminderID) == ["reminder-9",nil] && decodedBatch.rows.map(\.message) == [nil,"Save was interrupted"],"golden reminder journal decodes to the recorded batch and row states")

            let macro=RecordedMacro(id:idA,name:"Golden macro",steps:[.init(kind:.insertText,text:"caf\u{E9}"),.init(kind:.command,command:"lineEnd"),.init(kind:.findLiteral,text:"x",matchCase:true,backwards:false),.init(kind:.replaceSelection,text:"y"),.init(kind:.search,search:.init(query:"a+",replacement:"b",mode:2,matchCase:true,wholeWord:false,dotMatchesNewline:false,wrap:true,action:"replaceAll"))])
            let macros=MacroLibrary(macros:[macro])
            let macroBytes=try golden("MacroLibrary.json") { try macros.encoded() }
            check(try MacroLibrary.decode(macroBytes) == macros,"golden macro library decodes to the recorded steps of every kind")

            var definition=AutomationDefinition(id:idA,name:"Golden automation",input:.selection,steps:[.init(kind:.removeMatchingLines,find:"^#"),.init(kind:.replaceLiteral,find:"a",replacement:"b",askForFind:true,askForReplacement:false),.init(kind:.trimWhitespace)],output:.newDocument,previewBeforeApply:true,pinToToolbar:true)
            definition.shortcut="g";definition.destinationID="list-1"
            let automations=AutomationLibrary(workflows:[definition])
            let automationBytes=try golden("Automations.json") { try automations.encoded() }
            check(try AutomationLibrary.decode(automationBytes) == automations,"golden automation library decodes to the recorded definition with every optional field")

            let language=UserDefinedLanguage(name:"Golden language",extensions:"gold",version:"2.1",global:["caseIgnored":"yes","forcePureLC":"0","decimalSeparator":"0"],prefix:["Keywords1":"yes"],keywords:["Keywords1":"alpha beta","Comments":"00// 01 02 03/* 04*/"],styles:[.init(name:"DEFAULT",attributes:["fgColor":"000000","fontStyle":"0"]),.init(name:"KEYWORDS1",attributes:["fgColor":"0000FF","fontStyle":"1"])])
            let catalogBytes=try golden("LanguageCatalog.json") { try LanguageCatalog(sourceCommit:"golden-fixture",sourceHashes:["LanguageProfiles.json":"00ff"],limitations:["fixture only"],profiles:[try language.profile()]).encoded() }
            let catalog=try LanguageCatalog.decode(catalogBytes)
            check(catalog.version == 1 && catalog.sourceCommit == "golden-fixture" && catalog.sourceHashes == ["LanguageProfiles.json":"00ff"] && catalog.limitations == ["fixture only"] && catalog.profiles.count == 1 && catalog.profiles[0].title == "Golden language" && catalog.profiles[0].lexer == "user" && catalog.profiles[0].id.hasPrefix("udl.") && catalog.profiles[0].extensions == ["gold"] && catalog.profiles[0].keywordLists["7"] == "alpha beta" && catalog.profiles[0].properties["userDefine.prefixKeywords1"] == "1" && catalog.profiles[0].properties["userDefine.isCaseIgnored"] == "1" && catalog.profiles[0].styles.map(\.name) == ["DEFAULT","KEYWORDS1"] && catalog.profiles[0].udl == language,"golden language catalog decodes to the recorded user-defined profile")
            let present=Set(try FileManager.default.contentsOfDirectory(atPath:folder.path))
            check(present == ["Settings.json","SearchOptions.json","FolderSearchSettings.json","WorkspaceBrowser.json","RunLibrary.json","Session.texttanksession","RecoverySnapshot.json","ReminderBatch.json","MacroLibrary.json","Automations.json","LanguageCatalog.json"],"every committed persistence fixture is decoded by a check")
            check(!writing,"persistence fixtures were not rewritten by this run")
        }
        // F251
        section("menu and command wiring",#line) {
            let document=TextDocument();NSDocumentController.shared.addDocument(document);document.makeWindowControllers();document.showWindows()
            let controller=try requireValue(document.windowControllers.first as? EditorWindowController,"fixture: editor window controller"),window=try requireValue(controller.window,"fixture: window")
            sessionDelegate.buildMenus()
            let bar=try requireValue(NSApp.mainMenu,"fixture: buildMenus installs a main menu")
            func walk(_ menu:NSMenu,_ path:String)->[(String,NSMenuItem)] { menu.items.flatMap{ item -> [(String,NSMenuItem)] in
                let here=path.isEmpty ? item.title : path+" > "+item.title
                return (item.action == nil || item.hasSubmenu ? [] : [(here,item)])+(item.submenu.map{ walk($0,here) } ?? [])
            } }
            let items=walk(bar,"")
            check(bar.items.map(\.title) == ["TextTank","File","Workspace","Encoding","Edit","Search","Run","Text Utilities","View","Language","Macros","Automations","Window"],"the menu bar has the expected top-level menus in order")
            // Items without a target go to the first responder. The chain is walked here from the
            // editor that would be focused, so the check does not depend on the test process
            // being allowed to hold the key window.
            var chain:[NSObject]=[];var responder:NSResponder?=document.editor.subviews.first
            while let current=responder { chain.append(current);responder=current.nextResponder }
            chain += [window,controller,document,NSApp,sessionDelegate,NSDocumentController.shared]
            let innermost=descendants(document.editor).filter{ $0.acceptsFirstResponder }
            chain = innermost+chain
            var dead:[String]=[]
            for (path,item) in items {
                guard let action=item.action else { continue }
                if let target=item.target { if (target as? NSObject)?.responds(to:action) != true { dead.append(path) } }
                else if !chain.contains(where:{ $0.responds(to:action) }) { dead.append(path) }
            }
            if !check(dead.isEmpty,"every menu item with an action reaches an object that implements it") { print("NOTE dead menu items: \(dead)") }
            check(items.count >= 100,"the walk reaches the whole menu tree (\(items.count) items with actions)")
            func represented(_ action:Selector)->[String] { items.filter{ $0.1.action == action }.compactMap{ $0.1.representedObject as? String } }
            // The editor command names accepted by TTEditor's dispatch. Each one is executed by
            // name in bridge-checks ("every editor command by name"); a name missing here is a
            // menu item that would do nothing, because executeCommand ignores unknown names.
            let dispatch:Set<String>=["undo","redo","cut","copy","paste","selectAll","duplicateLine","deleteLine","transposeLine","indent","unindent","upper","lower","duplicateSelection","deleteWordLeft","deleteWordRight","deleteLineLeft","deleteLineRight","zoomIn","zoomOut","moveLineUp","moveLineDown","rectangularSelection","streamSelection","addNextOccurrence","selectAllOccurrences","clearAdditionalSelections","foldAll","unfoldAll","showWhitespace","toggleEOL","toggleLineNumbers","toggleOvertype","joinLines","trimTrailing","gotoMatchingBrace","selectMatchingBrace","bookmarkToggle","bookmarkNext","bookmarkPrevious"]
            let commands=represented(#selector(EditorWindowController.command(_:)))
            let unknown=commands.filter{ id in id.hasPrefix("transform.") ? EditorTransform(rawValue:String(id.dropFirst(10))) == nil : !dispatch.contains(id) }
            if !check(unknown.isEmpty && commands.count >= 40,"every editor command menu item names a transform or a command the bridge dispatches") { print("NOTE unknown command names: \(unknown)") }
            check(Set(commands.filter{ $0.hasPrefix("transform.") }.map{ String($0.dropFirst(10)) }) == Set(EditorTransform.allCases.map(\.rawValue)),"every EditorTransform case has a menu item")
            let comments=represented(#selector(EditorWindowController.comment(_:)))
            check(Set(comments) == Set(CommentCommand.allCases.map(\.rawValue)) && comments.count == CommentCommand.allCases.count,"every comment menu item names a CommentCommand")
            let reloads=represented(#selector(TextDocument.reloadEncoding(_:)))
            check(Set(reloads) == Set(FileEncoding.allCases.map(\.rawValue)) && reloads.allSatisfy{ FileEncoding(rawValue:$0) != nil },"every Reload-as item names a FileEncoding")
            check(represented(#selector(EditorWindowController.convertEOL(_:))) == ["LF","CRLF","CR"],"line-ending conversion items carry LF, CRLF and CR")
            // Convert-to-encoding: each code maps to the format its title promises.
            let expectedFormats:[String:FileFormat]=["utf8":FileFormat(encoding:.utf8,bom:false),"utf8bom":FileFormat(encoding:.utf8,bom:true),"utf16LE":FileFormat(encoding:.utf16LE,bom:true),"utf16BE":FileFormat(encoding:.utf16BE,bom:true),"windows1252":FileFormat(encoding:.windows1252,bom:false),"latin1":FileFormat(encoding:.latin1,bom:false)]
            let conversions=items.filter{ $0.1.action == #selector(TextDocument.convertEncoding(_:)) }.map{ $0.1 }
            check(Set(conversions.compactMap{ $0.representedObject as? String }) == Set(expectedFormats.keys) && conversions.count == expectedFormats.count,"Convert-to items carry exactly the known encoding codes")
            let sample="caf\u{E9} text\r\n"
            for item in conversions.reversed() {
                guard let code=item.representedObject as? String,let expected=expectedFormats[code] else { continue }
                let converting=TextDocument();converting.editor.text=sample;converting.editor.resetUndoHistory()
                let revision=converting.editor.revision
                converting.format=FileFormat(encoding:code == "latin1" ? .utf8 : .latin1,bom:false)
                converting.convertEncoding(item)
                check(converting.format == expected && converting.editor.text == sample && converting.editor.revision == revision && converting.isDocumentEdited == (expected != converting.savedFormat),"Convert to \(code) changes the format, keeps the text and marks the document edited unless that is its saved format")
                check(try converting.data(ofType:"Plain Text") == FileCodec.encode(sample,format:expected),"Convert to \(code) saves the bytes FileCodec produces for that format")
                converting.close()
            }
            // Line-ending conversion and wrap through the real actions.
            document.editor.text="a\r\nb\rc\n";document.editor.resetUndoHistory()
            for (mode,expected,eol) in [("CRLF","a\r\nb\r\nc\r\n",0),("CR","a\rb\rc\r",1),("LF","a\nb\nc\n",2)] {
                let item=try requireValue(items.first{ $0.1.action == #selector(EditorWindowController.convertEOL(_:)) && $0.1.representedObject as? String == mode }?.1,"fixture: \(mode) menu item")
                controller.convertEOL(item)
                check(same(document.editor.text,expected) && document.editor.statusInfo["eol"]?.intValue == eol,"Convert Line Endings to \(mode) rewrites every ending and switches the insertion ending")
            }
            let wrapped=controller.activeEditor.wrap;controller.toggleWrap(nil)
            check(controller.activeEditor.wrap == !wrapped,"Wrap Lines toggles the active view");controller.toggleWrap(nil)
            let upper=try requireValue(items.first{ $0.1.representedObject as? String == "upper" }?.1,"fixture: Uppercase menu item")
            document.editor.text="abc def";_ = document.editor.setSelectionAnchor(0,caret:3)
            controller.command(upper)
            check(document.editor.text == "ABC def","an editor command menu item runs its command on the active editor")
            let sort=try requireValue(items.first{ $0.1.representedObject as? String == "transform.sortAscending" }?.1,"fixture: sort menu item")
            document.editor.text="b\na\n";controller.command(sort)
            check(document.editor.text == "a\nb\n","a transform menu item runs its transform on the active editor")
            // Column insert: the success path of applyColumn, with one Undo.
            document.editor.text="x\nx\nx\n";document.editor.resetUndoHistory();document.editor.setSavePoint()
            try require(document.editor.setSelectionRanges([["anchor":0,"caret":1],["anchor":2,"caret":3],["anchor":4,"caret":4]]),"fixture: three column selections")
            let columnRevision=document.editor.revision,columnSelections=document.editor.selectionRanges
            check(EditorWindowController.applyColumn(["1","2","3"],to:document.editor,revision:columnRevision,selections:columnSelections) && document.editor.text == "1\n2\n3x\n","column insertion replaces each selection with its own value in selection order")
            document.editor.executeCommand("undo")
            check(document.editor.text == "x\nx\nx\n" && !document.editor.modified,"column insertion is one Undo back to the save point")
            check(!EditorWindowController.applyColumn(["1","2","3"],to:document.editor,revision:columnRevision,selections:columnSelections),"a column insertion captured before an edit is refused afterwards")
            document.editor.text="";document.close()
        }
    }
}
