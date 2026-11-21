import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

@MainActor enum AutomaticSessionChecks {
    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileReadUnknown) }
        return value
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
        var docs = [TextDocument](), urls = [URL](), expectedBytes = [Data]()
        for i in 0..<8 {
            let url = root.appendingPathComponent("original-\(i).txt")
            let text = "original content SALMON-\(i)\n" + String(repeating: "second line\n", count: 400)
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
        var replies = [Bool](), requests = 0
        first.requestUnsavedReview = { _ in requests += 1 }
        first.replyToTerminate = { replies.append($0) }
        check(first.applicationShouldTerminate(app) == .terminateLater, "dirty quit defers to native review")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        first.checkpointSession()
        first.reviewed(controller, didReviewAll: false, contextInfo: nil)
        let canceledBytes = try Data(contentsOf: metadata)
        check(
            requests == 1 && replies == [false] && canceledBytes == initialBytes && controller.documents.count == 8
                && docs[0].editor.text.contains("dirty unsaved text"),
            "cancel retains all dirty work and exact preceding periodic file")
        check(first.applicationShouldTerminate(app) == .terminateLater, "second dirty attempt still requires review")
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
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
        check(
            second.applicationShouldTerminate(app) == .terminateNow && controller.documents.isEmpty,
            "ordinary clean quit commits before closing each document")
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
