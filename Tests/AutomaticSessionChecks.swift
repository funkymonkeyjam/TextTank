import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

@MainActor enum AutomaticSessionChecks {
    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileReadUnknown) }
        return value
    }
    @MainActor private static func wrappedSplitChecks(_ host: WorkspaceWindowController, root: URL) throws {
        func paint(_ pane: TTEditor) throws {
            pane.layoutSubtreeIfNeeded()
            let rep = try required(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
            pane.cacheDisplay(in: pane.bounds, to: rep)
        }
        let line = String(repeating: "Orchid café 🌷 ", count: 1700)
        let samples = [("wrap-final.txt", line), ("wrap-safety.swift",
            String(repeating: "a", count: SizePolicy.standard.largeLineThreshold + 1))]
        var docs = [TextDocument]()
        defer { for document in docs { document.close() } }
        for (name, text) in samples {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            docs.append(try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(url), from: url, display: false))
        }
        let ids = docs.map { DocumentID($0.recoveryID) }
        let mapping = Dictionary(uniqueKeysWithValues: zip(ids, docs))
        var views = ids.map { id in
            var t = WorkspaceLayoutState.Tab(documentID: id, isPinned: false, anchorByte: 8, caretByte: 2, firstVisibleLine: 37)
            t.split = .init(otherAnchorByte: 0, otherCaretByte: 6, otherFirstVisibleLine: 0,
                otherHorizontalOffset: 25, activeHorizontalOffset: 0, secondaryActive: true, primaryFraction: 0.31)
            t.split?.activeWrapping = .wrapped(documentLine: 0, subline: 37)
            t.split?.otherWrapping = .unwrapped
            return t
        }
        views[1].split?.activeWrapping = .wrapped(documentLine: Int.max, subline: Int.max)
        views[1].split?.otherWrapping = .wrapped(documentLine: 0, subline: 12)
        var state = WorkspaceLayoutState(layout:.single, focusedGroup:.first,
            groups:[.init(slot:.first,activeTabIndex:1,tabs:views)])
        check(host.restoreSessionLayout(state, documents:mapping), "wrapped split layout accepted")
        let deferred = try required(docs[1].presentation)
        check(docs[1].deferredLargeFileLanguage != nil && !deferred.primaryEditor.wrap
            && deferred.secondary?.wrap == false && deferred.activeEditor.firstVisibleLine == 0,
            "a new large-file policy wins over both saved wrapping settings and unbounded offsets")
        let hidden = try required(docs[0].presentation)
        let captured = host.captureSessionLayout()
        check(captured.groups[0].tabs[0] == views[0], "a checkpoint before mounting retains the hidden split's wrap, viewport, and divider")
        host.activate(hidden)
        let a = hidden.primaryEditor, b = try required(hidden.secondary)
        check(host.captureSessionLayout().groups[0].tabs[0].split?.activeWrapping == .wrapped(documentLine: 0, subline: 37),
            "an immediate checkpoint after mounting retains a pending native wrap anchor")
        try paint(a); try paint(b)
        check(!a.wrap && b.wrap && b.firstVisibleDocumentLine == 0 && b.firstVisibleSubline == 37
            && b.firstVisibleLine == 37 && a.horizontalScrollOffset == 25,
            "the first real paints restore both distinct pane wrap settings and a final physical line's subrow")
        let width = hidden.split.bounds.width - hidden.split.dividerThickness
        check(abs(a.frame.width/width - 0.31) < 0.02 && a.selectionCaret == 6 && b.selectionCaret == 2,
            "off-center divider and both selections remain independent of the saved vertical scroll")
        b.scrollTo(documentLine: 0, subline: 24)
        a.wrap = true
        try paint(a); a.scrollTo(documentLine: 0, subline: 53)
        state = host.captureSessionLayout()
        check(state.groups[0].tabs[0].split?.activeWrapping == .wrapped(documentLine: 0, subline: 24)
            && state.groups[0].tabs[0].split?.otherWrapping == .wrapped(documentLine: 0, subline: 53),
            "capture stores independent wrapped locations for both panes")
        if var old = state.groups[0].tabs[0].split {
            old.activeWrapping = nil; old.otherWrapping = nil
            var legacy = state; legacy.groups[0].tabs[0].split = old
            check(host.restoreSessionLayout(legacy, documents:mapping) && a.wrap && b.wrap,
                "older split metadata keeps each pane's existing wrapping policy")
            try paint(a); try paint(b)
            check(a.firstVisibleLine == 53 && b.firstVisibleLine == 24,
                "legacy display rows on the last wrapped line survive without the new optional keys")
        }
        b.wrap = false
        try paint(b)
        check(host.restoreSessionLayout(state, documents: mapping), "the native view awaits a new wrap paint")
        _ = b.setSelectionAnchor(0, caret: 0)
        try paint(b)
        check(b.firstVisibleLine == 0 && b.selectionCaret == 0,
              "a new user caret wins over the unresolved restoration")
        var invalid = state
        invalid.groups[0].tabs[0].split?.otherWrapping = .wrapped(documentLine: 0, subline: -1)
        rejects("negative wrapped subrow invalidates the layout") { try invalid.validate() }
        var oversized = state
        oversized.groups[0].tabs[0].split?.activeWrapping = .wrapped(documentLine: Int.max, subline: Int.max)
        check(host.restoreSessionLayout(oversized,documents:mapping), "huge positive wrap positions remain clamped position requests")
        try paint(b)
        check(b.firstVisibleDocumentLine == 0 && b.firstVisibleLine < line.utf8.count &&
              docs[0].editor.checkedUTF8Data == Data(line.utf8) && !docs[0].isDocumentEdited,
              "native row clamping keeps shortened originals clean")
    }
    static func run(app: NSApplication, controller: TextDocumentController) throws {
        precondition(!AppStorage.permitsLegacyDefaults && controller.documents.isEmpty)
        let root = AppStorage.supportDirectory
        let metadata = AppStorage.url(.lastSession)
        @MainActor func delegate() -> AppDelegate {
            let d = AppDelegate()
            d.installEditorServices()
            d.buildMenus()
            return d
        }
        let first = delegate()
        first.restoreLaunchDocuments(review: { _ in }, report: { _ in check(false, "initial launch notice") })
        check(
            controller.documents.count == 1 && controller.documents[0].fileURL == nil,
            "empty first run creates one blank")
        controller.documents[0].close()
        let host = first.workspaceWindow
        try wrappedSplitChecks(host, root: root)
        var docs = [TextDocument](), urls = [URL](), expectedBytes = [Data]()
        for i in 0..<8 {
            let url = root.appendingPathComponent("original-\(i).txt")
            let text = "original content SALMON-\(i) 🦊\n" + String(repeating: "second line\n", count: 400)
            let bytes = i == 5 ? try required(text.data(using: .utf16LittleEndian)) : Data(text.utf8)
            try bytes.write(to: url)
            let read = try WorkspaceStore.captureRegularFile(url)
            docs.append(try DocumentFactory.openCaptured(read, from: url, as: i == 5 ? .utf16LE : nil, display: false))
            urls.append(url)
            expectedBytes.append(bytes)
        }
        let ids = docs.map { DocumentID($0.recoveryID) }
        let tabs = ids.enumerated().map { i, id in
            WorkspaceLayoutState.Tab(
                documentID: id, isPinned: i == 0 || i == 4,
                anchorByte: 200 + i, caretByte: 230 + i, firstVisibleLine: 7 + i)
        }
        let layout = WorkspaceLayoutState(
            layout: .twoColumns, focusedGroup: .second,
            groups: [
                .init(slot: .first, activeTabIndex: 1, tabs: Array(tabs[0..<4])),
                .init(slot: .second, activeTabIndex: 2, tabs: Array(tabs[4..<8]))
            ])
        check(
            host.restoreSessionLayout(layout, documents: Dictionary(uniqueKeysWithValues: zip(ids, docs))),
            "two-column setup")
        // A v1 tab without optional split metadata still opens as a single pane.
        check(host.presentations.allSatisfy { $0.secondary == nil }, "legacy v1 tabs restore one pane each")
        let backgroundSplit = try required(docs[3].presentation)
        let foregroundSplit = try required(docs[6].presentation)
        for presentation in [backgroundSplit, foregroundSplit] {
            presentation.clone(nil)
            let clone = try required(presentation.secondary)
            presentation.split.setPosition(presentation.split.bounds.width * 0.63, ofDividerAt: 0)
            presentation.primaryEditor.restoreClosedTabView(anchor: 43, caret: 32, firstVisibleLine: 3)
            clone.restoreClosedTabView(anchor: 83, caret: 74, firstVisibleLine: 8)
            presentation.primaryEditor.horizontalScrollOffset = 17
            clone.horizontalScrollOffset = 41
            if presentation === backgroundSplit { host.window?.makeFirstResponder(presentation.primaryEditor) }
        }
        // Return to the original group-active tabs without changing their last-focused panes.
        host.activate(try required(docs[1].presentation))
        host.activate(foregroundSplit)
        check(foregroundSplit.activeEditor === foregroundSplit.secondary, "setup focuses the clone in the active tab")
        let expected = host.captureSessionLayout()
        first.checkpointSession()
        let stop = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: metadata.path) && Date() < stop {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        let periodic = try LastSessionLayout.read(metadata)
        check(
            periodic?.layout == expected && periodic?.files.count == 8,
            "periodic production checkpoint preserves eight files and all group view metadata")
        let initialBytes = try Data(contentsOf: metadata)
        check(!String(decoding: initialBytes, as: UTF8.self).contains("SALMON"), "no document contents serialized")
        _ = docs[0].editor.replaceSelection("dirty unsaved text")
        let dirtyBytes = docs[0].editor.utf8Data
        let openDocuments = Set(controller.documents.map(ObjectIdentifier.init))
        var replies = [Bool](), requests = 0
        first.requestUnsavedReview = { _ in requests += 1 }
        first.replyToTerminate = { replies.append($0) }
        check(first.applicationShouldTerminate(app) == .terminateLater, "dirty quit defers to native review")
        guard spinUntil("first dirty quit to request native review", { requests >= 1 }) else { return }
        first.checkpointSession()
        first.reviewed(controller, didReviewAll: false, contextInfo: nil)
        let canceledBytes = try Data(contentsOf: metadata)
        check(requests == 1 && replies == [false], "cancel replies once to the first native review request")
        check(canceledBytes == initialBytes, "cancel retains the exact preceding periodic file")
        check(openDocuments.count == 8 && Set(controller.documents.map(ObjectIdentifier.init)) == openDocuments,
              "cancel keeps all eight original documents open")
        check(docs[0].isDocumentEdited && docs[0].editor.utf8Data == dirtyBytes
              && docs[0].editor.text.contains("dirty unsaved text"), "cancel retains the exact dirty editor contents")
        check(first.applicationShouldTerminate(app) == .terminateLater, "second dirty attempt still requires review")
        guard spinUntil("second dirty quit to request native review", { requests >= 2 }) else { return }
        check(requests == 2, "second dirty quit requests native review exactly once")
        // AppKit is allowed to have closed reviewed documents before the callback.
        docs[1].close()
        first.reviewed(controller, didReviewAll: true, contextInfo: nil)
        let final = try required(LastSessionLayout.read(metadata))
        check(
            replies == [false, true] && controller.documents.isEmpty && final.files.count == 8
                && final.layout.layout == .twoColumns,
            "committed dirty quit preserves captured tab removed during review before teardown")
        try FileManager.default.removeItem(at: urls[2])
        let second = delegate()
        var notices = [[String]](), draft: TextDocument?, beforeRecover: WorkspaceLayoutState?,
            savedDocs = [URL: TextDocument]()
        var recoveryError: Error?
        second.restoreLaunchDocuments(
            review: { originals in
                savedDocs = originals
                beforeRecover = second.workspaceWindow.captureSessionLayout()
                let active = second.workspaceWindow.active
                let responder = second.workspaceWindow.window?.firstResponder as? NSView
                let ownsFocus = active?.secondary.map { responder?.isDescendant(of: $0) == true } ?? false
                check(
                    active?.document === originals[urls[6]] && ownsFocus && active?.activeEditor === active?.secondary,
                    "restoration focuses the saved secondary Scintilla pane before recovery review")

                let snap = RecoverySnapshot(
                    id: UUID(), text: "RECOVER-ONLY-AVOCADO", format: FileFormat(),
                    originalURL: urls[6].absoluteString, revision: 14)
                do { draft = try second.openRecovered([snap], originals: originals).first } catch {
                    recoveryError = error
                }
            }, report: { notices.append($0) })
        if let recoveryError { throw recoveryError }
        check(
            notices.count == 1 && notices[0].count == 1 && notices[0][0].contains("original-2.txt"),
            "one notice for missing local file")
        let restored = try required(beforeRecover)
        check(
            restored.layout == .twoColumns && restored.focusedGroup == .second
                && restored.groups.map { $0.tabs.count } == [3, 4] && restored.groups.map(\.activeTabIndex) == [1, 2]
                && restored.groups.map { $0.tabs.map(\.isPinned) } == [
                    [true, false, false], [true, false, false, false]
                ],
            "originals reopen with two columns, mixed pins, active tabs and missing tab removed")
        let names = savedDocs.reduce(into: [DocumentID: String]()) {
            $0[DocumentID($1.value.recoveryID)] = $1.key.lastPathComponent
        }
        check(
            restored.groups.flatMap(\.tabs).compactMap { names[$0.documentID] }
                == [0, 1, 3, 4, 5, 6, 7].map { "original-\($0).txt" },
            "preserves per-group tab order after skipping a missing path")
        let pinned = try required(savedDocs.values.first { $0.fileURL?.lastPathComponent == "original-5.txt" })
        check(
            pinned.revertEncoding == .utf16LE && pinned.editor.text.hasPrefix("original content SALMON-5"),
            "noninteractive restore preserves a user-selected encoding for BOM-less UTF-16")
        let u6 = try required(savedDocs.first { $0.key.lastPathComponent == "original-6.txt" }?.value)
        let good = try Data(contentsOf: urls[6])
        check(
            good == expectedBytes[6] && u6.editor.checkedUTF8Data == good && draft?.fileURL == nil
                && draft?.editor.text == "RECOVER-ONLY-AVOCADO" && draft?.isDocumentEdited == true
                && draft?.recoveredOrigin?.contains("Group 2") == true,
            "recovered draft associates with reopened original group and keeps both byte streams distinct")
        check(
            controller.documents.count == 8
                && Set(
                    controller.documents.compactMap { ($0 as? TextDocument)?.presentation?.host }.map(
                        ObjectIdentifier.init)
                ).count == 1,
            "seven surviving originals plus one reviewed draft share one workspace and no blank")
        let positions = Dictionary(
            uniqueKeysWithValues: final.layout.groups.flatMap(\.tabs).map { ($0.documentID, $0) })
        let expectedByName = Dictionary(
            uniqueKeysWithValues: final.files.compactMap { item in
                positions[item.id].map { (item.url.lastPathComponent, $0) }
            })
        check(
            restored.groups.flatMap(\.tabs).allSatisfy { tab in
                guard let name = names[tab.documentID], let prior = expectedByName[name] else { return false }
                return tab.anchorByte == prior.anchorByte && tab.caretByte == prior.caretByte
                    && tab.firstVisibleLine == prior.firstVisibleLine
            }, "restored byte selections and first-visible lines match every surviving presentation")
        draft?.flushRecovery()
        let recoveries = try TextDocument.recovery.scan().snapshots
        check(
            recoveries.contains { $0.id == draft?.recoveryID && $0.originalURL == urls[6].absoluteString },
            "a second interrupted recovery retains its informational original path")
        draft?.close()
        let shown = try required(u6.presentation)
        let hidden = try required(savedDocs[urls[3]]?.presentation)
        let hiddenClone = try required(hidden.secondary)
        let shownClone = try required(shown.secondary)
        check(
            hidden.activeEditor === hidden.primaryEditor && shown.activeEditor === shownClone
                && shown.primaryEditor.selectionAnchor == 43 && shown.primaryEditor.selectionCaret == 32
                && shownClone.selectionAnchor == 83 && shownClone.selectionCaret == 74
                && hiddenClone.selectionAnchor == 83 && hiddenClone.selectionCaret == 74,
            "an inactive split tab and the active split retain each pane's directed byte range and focused side")
        for (presentation, clone, name) in [
            (shown, shownClone, "original-6.txt"), (hidden, hiddenClone, "original-3.txt")
        ] {
            second.workspaceWindow.activate(presentation)
            let fraction =
                presentation.primaryEditor.frame.width
                / (presentation.split.bounds.width - presentation.split.dividerThickness)
            let prior = try required(expectedByName[name]?.split)
            check(
                abs(fraction - prior.primaryFraction) < 0.02
                    && presentation.primaryEditor.firstVisibleLine == 3 && clone.firstVisibleLine == 8
                    && presentation.primaryEditor.horizontalScrollOffset == 17 && clone.horizontalScrollOffset == 41,
                "mounted split restores its divider and both native viewports " + name)
        }
        // A local file may become shorter, or an old byte position may now lie inside a scalar.
        let originalState = shown.sessionTab(documentID: DocumentID(u6.recoveryID), pinned: false)
        var stale = originalState
        let emojiByte = "original content SALMON-6 ".utf8.count
        stale.caretByte = emojiByte + 2
        stale.anchorByte = Int.max
        stale.split?.otherCaretByte = Int.max
        stale.split?.otherAnchorByte = emojiByte + 1
        stale.split?.otherFirstVisibleLine = Int.max
        stale.split?.otherHorizontalOffset = Int.max
        shown.restoreSessionTab(stale)
        let length = try required(u6.editor.checkedUTF8Data).count
        check(
            shownClone.selectionAnchor == length && shownClone.selectionCaret == emojiByte
                && shown.primaryEditor.selectionAnchor == emojiByte && shown.primaryEditor.selectionCaret == length
                && shown.primaryEditor.firstVisibleLine < 402 && shown.primaryEditor.horizontalScrollOffset < Int32.max,
            "each restored range clamps to existing UTF-8 and both viewports fit the current document")
        shown.restoreSessionTab(originalState)
        var invalid = expected
        invalid.groups[1].tabs[2].split?.primaryFraction = 1.2
        rejects("invalid optional divider geometry still refuses an invalid session layout") { try invalid.validate() }
        let prior = shown.primaryEditor.checkedUTF8Data
        let edited = shownClone.replaceSelection("shared clone smoke")
        check(
            edited && shown.primaryEditor.text.contains("shared clone smoke"), "restored split edits one shared buffer")
        shown.primaryEditor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(
            shownClone.checkedUTF8Data == prior && u6.isDocumentEdited == false,
            "Undo through the other restored pane returns to identical bytes and save point")
        second.workspaceWindow.activate(shown)
        shown.closeSplit(nil)
        check(
            second.applicationShouldTerminate(app) == .terminateNow && controller.documents.isEmpty,
            "ordinary clean quit commits before closing each document")
        let afterUnsplit = try required(LastSessionLayout.read(metadata))
        let remainingSplits = Set(
            afterUnsplit.layout.groups.flatMap(\.tabs).filter { $0.split != nil }.map(\.documentID))
        check(
            remainingSplits == Set(afterUnsplit.files.filter { $0.url == urls[3] }.map(\.id)),
            "the next accepted clean quit removes only the explicitly closed split")
        let saved = try Data(contentsOf: metadata)
        let third = delegate()
        let reused = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(urls[4]), from: urls[4], display: false)
        _ = reused.editor.replaceSelection("preexisting dirty startup buffer")
        let previous = reused.editor.checkedUTF8Data
        third.restoreLaunchDocuments(
            review: { originals in
                check(
                    originals.values.contains { $0 === reused } && reused.editor.checkedUTF8Data == previous
                        && reused.isDocumentEdited,
                    "explicit startup document reuses dirty instance and does not reload it")
            }, report: { _ in check(false, "unexpected notice reopening saved surviving paths") })
        check(
            controller.documents.count == 7 && third.workspaceWindow.active?.document === reused
                && third.workspaceWindow.model.layout == .single,
            "coexisting launch document retains focus and its layout with no duplicate")
        third.closeAllForTermination()
        let optOut = delegate()
        var options = optOut.settings.value
        check(options.reopensLastSession, "missing launch setting defaults to restore")
        let previousForms = Set(FormPanel.visible.map { ObjectIdentifier($0.window) })
        optOut.settings.showSettings(nil)
        func descendant(_ view: NSView) -> NSPopUpButton? {
            if view.identifier?.rawValue == "settings.atLaunch" { return view as? NSPopUpButton }
            return view.subviews.lazy.compactMap { descendant($0) }.first
        }
        let openedForms = FormPanel.visible.filter { !previousForms.contains(ObjectIdentifier($0.window)) }
        try require(
            openedForms.count == 1 && openedForms.first?.window.identifier?.rawValue == "TextTank.Settings",
            "showSettings presents one new Settings form for this launch preference")
        let form = openedForms[0]
        defer { form.close() }
        let popup = try required(form.window.contentView.flatMap { descendant($0) })
        check(popup.titleOfSelectedItem == "Reopen last session", "native Settings popup reflects the default")
        popup.selectItem(at: 1)
        let change = try required(popup.action)
        check(
            app.sendAction(change, to: popup.target, from: popup) && !optOut.settings.value.reopensLastSession,
            "native At launch change writes New document")
        form.close()
        let cold = try EditorSettings.decode(Data(contentsOf: optOut.settings.url))
        check(
            !cold.reopensLastSession,
            "cold settings decoder reads the persisted launch preference")
        optOut.restoreLaunchDocuments(
            review: { originals in
                check(
                    originals.isEmpty && controller.documents.isEmpty, "opt-out still runs recovery review before blank"
                )
            }, report: { _ in check(false, "unexpected notice for new-document preference") })
        check(
            controller.documents.count == 1 && controller.documents[0].fileURL == nil,
            "new-document preference opens exactly one blank")
        optOut.closeAllForTermination()
        options.reopenLastSession = true
        _ = try optOut.settings.save(options)
        let future = Data("{\"version\":99,\"files\":[],\"layout\":{}}".utf8)
        try future.write(to: metadata)
        let broken = delegate()
        var warnings = 0
        broken.restoreLaunchDocuments(review: { _ in }, report: { _ in warnings += 1 })
        broken.checkpointSession()
        check(
            broken.applicationShouldTerminate(app) == .terminateNow && warnings == 1,
            "unsupported automatic manifest permits normal clean quit and reports once")
        let preserved = try Data(contentsOf: metadata)
        check(preserved == future, "periodic and committed quit preserve unreadable/newer automatic session bytes")
        try saved.write(to: metadata)
        try checkPublication(in: root, host: broken.workspaceWindow)
        try AutomaticSessionQuitChecks.checkBoth(in: root)
        withExtendedLifetime([first, second]) {}
    }
    private static func checkPublication(in root: URL, host: WorkspaceWindowController) throws {
        let previous = try LastSessionLayout(
            files: [],
            layout: .init(
                layout: .twoColumns, focusedGroup: .first,
                groups: [
                    .init(slot: .first, activeTabIndex: nil, tabs: []),
                    .init(slot: .second, activeTabIndex: nil, tabs: [])
                ]))
        let known = try previous.encoded()
        var unknown = try required(JSONSerialization.jsonObject(with: known) as? [String: Any])
        unknown["futureProperty"] = "this spelling belongs to another writer"
        let equivalent = try JSONSerialization.data(withJSONObject: unknown, options: [.prettyPrinted])
        let future = Data("{\"version\":99,\"future\":18446744073709551617}".utf8)
        for (name, foreign, existing) in [
            ("future", future, true), ("invalid", Data([0xff, 0x00]), true),
            ("otherV1", equivalent, true), ("appeared", future, false)
        ] {
            let file = root.appendingPathComponent("owned-" + name + ".json")
            if existing { try known.write(to: file) }
            let writer = AutomaticSession(url: file)
            let opened = try writer.read()
            check((opened != nil) == existing, "distinguishes observed baseline and absent target " + name)
            try foreign.write(to: file, options: .atomic)
            var conflict: Error?
            writer.checkpoint(host) { conflict = $0 }
            let deadline = Date().addingTimeInterval(5)
            while conflict == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            let afterCheckpoint = try Data(contentsOf: file)
            let committed = try writer.commit(host)
            let afterQuit = try Data(contentsOf: file)
            check(
                conflict != nil && !committed && afterCheckpoint == foreign && afterQuit == foreign,
                "periodic checkpoint and accepted quit preserve exact newer or undecodable bytes " + name)
            if existing {
                try known.write(to: file, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: file)
            }
            let retried = try writer.commit(host)
            let actual = try LastSessionLayout.read(file)
            let desired = try OpenSessionLayout(host).diskLayout()
            check(
                retried && actual == desired,
                "restoring the observed prior content permits a fresh valid commit " + name)
        }
        let unseen = root.appendingPathComponent("unobserved.json")
        let unstarted = AutomaticSession(url: unseen)
        let skipped = try unstarted.commit(host)
        check(
            !skipped && !FileManager.default.fileExists(atPath: unseen.path),
            "writer that never observed its target cannot publish")
    }

}
