// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

/// DS-D9: unsaved untitled text survives a quit. Every quit here goes through the application
/// delegate's own terminate path with the two AppKit calls observed, so no review is presented.
@MainActor enum UnsavedWorkChecks {
    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileReadUnknown) }
        return value
    }
    private struct Place: Equatable {
        let name: String, group: GroupSlot, pinned: Bool, anchor: Int, caret: Int
    }
    /// Tab order, group, pin state and selection, with each tab named by what it shows.
    private static func places(_ host: WorkspaceWindowController, _ names: [UUID: String]) -> [Place] {
        let files = Dictionary(
            uniqueKeysWithValues: host.presentations.compactMap { $0.document as? TextDocument }.map {
                ($0.recoveryID, $0.fileURL?.lastPathComponent)
            })
        return host.captureSessionLayout().groups.flatMap { group in
            group.tabs.map { tab in
                let id = tab.documentID.rawValue
                return Place(
                    name: names[id] ?? (files[id] ?? nil) ?? "?", group: group.slot, pinned: tab.isPinned,
                    anchor: tab.anchorByte, caret: tab.caretByte)
            }
        }
    }
    static func untitledSurvivesQuit(app: NSApplication, controller: TextDocumentController) throws {
        precondition(!AppStorage.permitsLegacyDefaults && controller.documents.isEmpty)
        let root = AppStorage.supportDirectory, metadata = AppStorage.url(.lastSession)
        let store = TextDocument.recovery
        @MainActor func delegate() -> AppDelegate {
            let d = AppDelegate()
            d.installEditorServices()
            d.buildMenus()
            return d
        }
        func inventory(_ ids: [UUID]) throws -> RecoveryInventory {
            RecoveryInventory(headers: try store.scanHeaders().headers.filter { ids.contains($0.id) }, issues: [])
        }
        func document(_ id: UUID) -> TextDocument? {
            controller.documents.compactMap { $0 as? TextDocument }.first { $0.recoveryID == id }
        }
        func quiet(_ host: WorkspaceWindowController) -> Bool {
            NSApp.modalWindow == nil && host.window?.attachedSheet == nil
        }
        let first = delegate()
        first.restoreLaunchDocuments(review: { _ in }, report: { _ in check(false, "V9 initial launch notice") })
        controller.documents.forEach { $0.close() }
        let host = first.workspaceWindow
        let fileURL = root.appendingPathComponent("kept-file.txt")
        try Data("file body\nsecond\n".utf8).write(to: fileURL)

        let one = DocumentFactory.makeUntitled()
        _ = one.editor.replaceSelection("alpha KIWI\r\nsecond line café 🥝\r\n")
        one.editor.setLineEndingMode(.crlf)
        try one.convertEncoding(to: "utf16LE")
        try require(one.applyLanguage("swift", using: first.languages), "V9 fixture: a language is chosen")
        let file = try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(fileURL), from: fileURL)
        let two = DocumentFactory.makeUntitled()
        _ = two.editor.replaceSelection("beta PLUM")
        let pinned = try required(one.presentation?.tabID)
        host.activate(try required(one.presentation))
        host.setPinnedTabs([pinned], target: pinned, pinned: true)
        _ = one.editor.setSelectionAnchor(3, caret: 7)
        _ = two.editor.setSelectionAnchor(5, caret: 1)
        host.activate(try required(two.presentation))
        let ids = [one.recoveryID, two.recoveryID], names = [ids[0]: "one", ids[1]: "two"]
        let before = places(host, names)
        let bytes = [try required(one.editor.checkedUTF8Data), try required(two.editor.checkedUTF8Data)]
        try require(
            before.map(\.name).sorted() == ["kept-file.txt", "one", "two"] && before.first?.pinned == true
                && before.first?.name == "one",
            "V9 fixture: a pinned untitled tab, a file and a second untitled tab")
        check(
            one.isDocumentEdited && two.isDocumentEdited && !one.isHeldForQuit && !file.isDocumentEdited,
            "V9 outside a quit an untitled document is edited as ever, so closing its tab still asks")

        var requests = 0, replies = [Bool]()
        first.requestUnsavedReview = { _ in requests += 1 }
        first.replyToTerminate = { replies.append($0) }
        check(
            first.applicationShouldTerminate(app) == .terminateNow && requests == 0 && replies.isEmpty
                && controller.documents.isEmpty,
            "V9 quitting with unsaved untitled text presents no review and terminates at once")
        let saved = try required(LastSessionLayout.read(metadata))
        check(
            saved.version == 2 && saved.files.map(\.url.lastPathComponent) == ["kept-file.txt"]
                && Set(saved.untitled?.map(\.id.rawValue) ?? []) == Set(ids)
                && saved.untitled?.first { $0.id.rawValue == ids[0] }?.language == "swift"
                && saved.untitled?.first { $0.id.rawValue == ids[0] }?.lineEnding == "CRLF"
                && saved.untitled?.first { $0.id.rawValue == ids[1] }?.language == nil
                && saved.untitled?.first { $0.id.rawValue == ids[1] }?.lineEnding == "LF",
            "V9 the committed session names both untitled documents with language and line ending")
        check(
            !String(decoding: try Data(contentsOf: metadata), as: UTF8.self).contains("KIWI"),
            "V9 the session file holds no document text")
        let copies = try ids.map { try store.load(id: $0) }
        check(
            zip(copies, bytes).allSatisfy { Data($0.text.utf8) == $1 }
                && copies[0].format == FileFormat(encoding: .utf16LE, bom: true) && copies[0].originalURL == nil,
            "V9 each untitled document's exact text and encoding are its recovery copy after the quit")

        // Relaunch.
        let second = delegate()
        var liveAtReview = Set<UUID>()
        second.restoreLaunchDocuments(
            recovery: try inventory(ids),
            review: { _ in
                liveAtReview = Set(controller.documents.compactMap { ($0 as? TextDocument)?.recoveryID })
            }, report: { _ in check(false, "V9 unexpected session notice at relaunch") })
        let r1 = try requireValue(document(ids[0]), "V9 first untitled document reopened")
        let r2 = try requireValue(document(ids[1]), "V9 second untitled document reopened")
        let rf = try requireValue(
            controller.documents.compactMap { $0 as? TextDocument }.first { $0.fileURL != nil },
            "V9 the file reopened")
        check(
            controller.documents.count == 3 && liveAtReview.isSuperset(of: ids) && quiet(second.workspaceWindow),
            "V9 relaunch reopens the untitled documents before the recovery review, with no question")
        check(
            r1.editor.checkedUTF8Data == bytes[0] && r2.editor.checkedUTF8Data == bytes[1],
            "V9 relaunch restores each untitled document's exact text")
        check(
            r1.fileURL == nil && r2.fileURL == nil && r1.isDocumentEdited && r2.isDocumentEdited
                && r1.recoveredOrigin == nil && r1.displayName.hasPrefix("Untitled"),
            "V9 restored documents are still untitled and still marked edited")
        check(
            r1.format == FileFormat(encoding: .utf16LE, bom: true) && r1.editor.statusInfo.eol == .crlf
                && r1.languageIdentifier == "swift" && r2.format == FileFormat(encoding: .utf8, bom: false)
                && r2.editor.statusInfo.eol == .lf && r2.languageIdentifier == LanguageProfile.plainTextID,
            "V9 relaunch restores encoding, line endings and language")
        check(
            places(second.workspaceWindow, names) == before,
            "V9 relaunch restores tab order, group, pin state, caret and selection")
        check(
            second.workspaceWindow.active?.document === r2, "V9 relaunch returns to the tab that was active")
        check(
            second.workspaceWindow.lastTabMessage == AppDelegate.restoredUntitledNotice(2)
                && AppDelegate.restoredUntitledNotice(2).contains("2 untitled documents")
                && AppDelegate.restoredUntitledNotice(1).contains("1 untitled document "),
            "V9 a status message, not an alert, says that unsaved text was restored")
        r1.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(
            r1.editor.checkedUTF8Data == bytes[0],
            "V9 limitation: a recovery copy holds no Undo history, so Undo has nothing to undo after relaunch")
        check(
            try store.load(id: ids[0]).revision > copies[0].revision,
            "V9 a reopened document's later copies supersede the one that was kept")

        // A copy that cannot be written and verified falls back to the review for that document.
        second.requestUnsavedReview = { _ in requests += 1 }
        second.replyToTerminate = { replies.append($0) }
        r1.dependencies.beforeQuitHold = { throw POSIXError(.EIO) }
        _ = r2.editor.replaceSelection(" more")
        let grown = try required(r2.editor.checkedUTF8Data)
        check(second.applicationShouldTerminate(app) == .terminateLater, "V9 a failed flush defers the quit to the review")
        guard spinUntil("V9 the review request after a failed flush", { requests == 1 }) else { return }
        check(
            r1.isDocumentEdited && !r1.isHeldForQuit && r1.lastRecoveryError != nil && r2.isHeldForQuit
                && !r2.isDocumentEdited && controller.documents.filter(\.isDocumentEdited).count == 1,
            "V9 the review asks about exactly the document whose copy failed")
        check(
            r2.currentSaveStateStatus.hasPrefix("Edited"),
            "V9 a held document's status still says Edited while the review is open")
        second.reviewed(controller, didReviewAll: false, contextInfo: nil)
        check(
            replies == [false] && controller.documents.count == 3 && r1.isDocumentEdited && r2.isDocumentEdited
                && !r2.isHeldForQuit && r2.editor.checkedUTF8Data == grown,
            "V9 cancelling that review leaves every document open and edited")

        // A file with unsaved edits keeps its review; the untitled documents are not part of it.
        r1.dependencies.beforeQuitHold = nil
        _ = rf.editor.replaceSelection("DIRTY ")
        let fileCopy = rf.recoveryID
        check(second.applicationShouldTerminate(app) == .terminateLater, "V9 an edited file still defers the quit to the review")
        guard spinUntil("V9 the review request for an edited file", { requests == 2 }) else { return }
        check(
            rf.isDocumentEdited && r1.isHeldForQuit && r2.isHeldForQuit
                && controller.documents.filter(\.isDocumentEdited).map { $0 as? TextDocument } == [rf],
            "V9 the review covers the edited file only")
        // Fix round 1, finding 1. AppKit's review closes a held document as clean while the file's
        // review can still be cancelled. That close is only noted.
        let placed = places(second.workspaceWindow, names), revisionBefore = r1.editor.revision
        r1.close()
        check(
            r1.isOpen && r1.quitCloseDeferred && !controller.documents.contains(r1)
                && second.workspaceWindow.presentations.contains { $0.document === r1 }
                && places(second.workspaceWindow, names) == placed,
            "F1 a close during a quit that can still be cancelled leaves the held tab where it is")
        second.reviewed(controller, didReviewAll: false, contextInfo: nil)
        check(
            replies == [false, false] && controller.documents.contains(r1) && controller.documents.count == 3
                && r1.isDocumentEdited && !r1.isHeldForQuit && !r1.quitCloseDeferred
                && r1.editor.checkedUTF8Data == bytes[0] && r1.editor.revision == revisionBefore
                && places(second.workspaceWindow, names) == placed,
            "F1 the cancelled quit leaves that document open, registered and edited, with nothing changed")
        check(second.applicationShouldTerminate(app) == .terminateLater, "F1 fixture: the quit is asked for again")
        guard spinUntil("F1 the second review request", { requests == 3 }) else { return }
        r1.close()
        check(r1.isOpen && r1.isHeldForQuit, "F1 the held document is still open until the quit is certain")
        // As if the person chose Don't Save for the file.
        second.reviewed(controller, didReviewAll: true, contextInfo: nil)
        let afterReview = try required(LastSessionLayout.read(metadata))
        check(!r1.isOpen, "F1 once the quit is certain the noted close is carried out")
        check(
            replies == [false, false, true] && controller.documents.isEmpty && afterReview.untitled?.count == 2
                && afterReview.files.count == 1,
            "V9 the reviewed quit keeps both untitled documents in the session")
        check(
            try Data(store.load(id: ids[1]).text.utf8) == grown && Data(contentsOf: fileURL) == Data("file body\nsecond\n".utf8)
                && (try? store.load(id: fileCopy)) == nil,
            "V9 the kept copy is the latest text; the file is unchanged and its discarded draft is gone")

        // The setting off: exactly the earlier behaviour.
        let third = delegate()
        var options = third.settings.value
        check(options.keepsUntitledOnQuit, "V9 the setting is on unless it is stored off")
        options.keepUntitledOnQuit = false
        _ = try third.settings.save(options)
        var offered = Set<UUID>()
        third.restoreLaunchDocuments(
            recovery: try inventory(ids),
            review: { _ in
                offered = Set(ids).subtracting(controller.documents.compactMap { ($0 as? TextDocument)?.recoveryID })
            }, report: { _ in check(false, "V9 unexpected notice with the setting off") })
        check(
            controller.documents.count == 1 && controller.documents[0].fileURL != nil && offered == Set(ids)
                && third.workspaceWindow.lastTabMessage != AppDelegate.restoredUntitledNotice(2),
            "V9 off: untitled copies are not reopened silently; they are left for the Recover question")
        let asked = DocumentFactory.makeUntitled()
        _ = asked.editor.replaceSelection("ask about me")
        asked.flushRecovery()
        let askedID = asked.recoveryID
        third.requestUnsavedReview = { _ in requests += 1 }
        third.replyToTerminate = { replies.append($0) }
        check(third.applicationShouldTerminate(app) == .terminateLater, "V9 off: an edited untitled document defers the quit")
        guard spinUntil("V9 off: the review request", { requests == 4 }) else { return }
        check(asked.isDocumentEdited && !asked.isHeldForQuit, "V9 off: the review asks about the untitled document")
        third.reviewed(controller, didReviewAll: true, contextInfo: nil)
        let offSession = try required(LastSessionLayout.read(metadata))
        check(
            controller.documents.isEmpty && offSession.version == 1 && offSession.untitled == nil
                && (try? store.load(id: askedID)) == nil,
            "V9 off: the discarded untitled document's copy is deleted and the session lists files only")
        check(
            try ids.map { try store.load(id: $0).text.utf8.count } == [bytes[0].count, grown.count],
            "V9 off: copies kept by an earlier quit are not touched")

        // On again. No session names the two copies now, as after a crash: they still reopen.
        options.keepUntitledOnQuit = nil
        _ = try third.settings.save(options)
        let fourth = delegate()
        fourth.restoreLaunchDocuments(
            recovery: try inventory(ids), review: { _ in },
            report: { _ in check(false, "V9 unexpected notice after a crash-style launch") })
        let c1 = try requireValue(document(ids[0]), "V9 crash-style launch reopened the first copy")
        let c2 = try requireValue(document(ids[1]), "V9 crash-style launch reopened the second copy")
        check(
            controller.documents.count == 3 && c1.editor.checkedUTF8Data == bytes[0]
                && c2.editor.checkedUTF8Data == grown && c1.isDocumentEdited && c2.isDocumentEdited
                && c1.fileURL == nil && quiet(fourth.workspaceWindow)
                && fourth.workspaceWindow.lastTabMessage == AppDelegate.restoredUntitledNotice(2),
            "V9 untitled copies that no session names reopen silently, with the same notice")
        check(
            places(fourth.workspaceWindow, names).map(\.name) == ["kept-file.txt", "one", "two"],
            "V9 they open as tabs after the session's own, oldest copy first")

        // Bounds: a document beyond them is asked about, never dropped.
        fourth.requestUnsavedReview = { _ in requests += 1 }
        fourth.replyToTerminate = { replies.append($0) }
        fourth.keptUntitledLimits.count = 1
        check(fourth.applicationShouldTerminate(app) == .terminateLater, "V9 over the count bound the quit is reviewed")
        guard spinUntil("V9 the review request over the count bound", { requests == 5 }) else { return }
        check(
            c1.isHeldForQuit && !c2.isHeldForQuit && c2.isDocumentEdited,
            "V9 the count bound keeps the first tab and asks about the next")
        fourth.reviewed(controller, didReviewAll: false, contextInfo: nil)
        fourth.keptUntitledLimits = (count: 256, bytes: bytes[0].count + grown.count - 1)
        check(fourth.applicationShouldTerminate(app) == .terminateLater, "V9 over the size bound the quit is reviewed")
        guard spinUntil("V9 the review request over the size bound", { requests == 6 }) else { return }
        check(
            c1.isHeldForQuit && !c2.isHeldForQuit && c2.isDocumentEdited && c2.editor.checkedUTF8Data == grown,
            "V9 the size bound asks about the document that does not fit and keeps its text")
        fourth.reviewed(controller, didReviewAll: false, contextInfo: nil)
        fourth.keptUntitledLimits = (
            count: SizePolicy.standard.keptUntitledCount, bytes: SizePolicy.standard.keptUntitledTotal
        )

        let extra = DocumentFactory.makeUntitled()
        _ = extra.editor.replaceSelection("about to be saved under a name")
        let extraID = extra.recoveryID
        // Text typed while the review is open is written again before anything closes.
        _ = rfEdit(controller)?.editor.replaceSelection("X")
        check(fourth.applicationShouldTerminate(app) == .terminateLater, "V9 fixture: a review is open")
        guard spinUntil("V9 the review request before a late edit", { requests == 7 }) else { return }
        _ = c2.editor.replaceSelection(" late")
        let late = try required(c2.editor.checkedUTF8Data)
        // Fix round 1, finding 5: a held document that is saved under a name before it closes is
        // a file. Its recovery copy must not bring it back as a second, untitled tab.
        let named = try requireValue(document(extraID), "F5 fixture: the third untitled document")
        check(named.isHeldForQuit && (try? store.load(id: extraID)) != nil, "F5 fixture: it is held, with a verified copy")
        named.fileURL = root.appendingPathComponent("became-a-file.txt")
        fourth.reviewed(controller, didReviewAll: true, contextInfo: nil)
        let afterNaming = try required(LastSessionLayout.read(metadata))
        check(
            (try? store.load(id: extraID)) == nil && Set(afterNaming.untitled?.map(\.id.rawValue) ?? []) == Set(ids)
                && afterNaming.files.contains { $0.url.lastPathComponent == "became-a-file.txt" },
            "F5 a held document that became a file leaves no recovery copy and is not named as untitled")
        check(
            try controller.documents.isEmpty && Data(store.load(id: ids[1]).text.utf8) == late,
            "V9 an edit made during the review is in the kept copy")

        // A kept copy that can no longer be read is left for the Recover question.
        let body = try required(
            FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).first {
                $0.lastPathComponent.hasPrefix(ids[1].uuidString + ".") && $0.pathExtension == "utf8"
            })
        var damaged = try Data(contentsOf: body)
        damaged[0] ^= 0x01
        try damaged.write(to: body)
        let fifth = delegate()
        var unopened = Set<UUID>()
        fifth.restoreLaunchDocuments(
            recovery: try inventory(ids),
            review: { _ in
                unopened = Set(ids).subtracting(controller.documents.compactMap { ($0 as? TextDocument)?.recoveryID })
            }, report: { _ in })
        check(
            document(ids[0])?.editor.checkedUTF8Data == bytes[0] && unopened == [ids[1]]
                && FileManager.default.fileExists(atPath: body.path)
                && fifth.workspaceWindow.lastTabMessage == AppDelegate.restoredUntitledNotice(1),
            "V9 a damaged copy is not opened and not deleted; the readable one is restored")
        fifth.closeAllForTermination()
        for file in try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        where ids.contains(where: { file.lastPathComponent.hasPrefix($0.uuidString) }) {
            try FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: metadata)
        withExtendedLifetime([first, second, third, fourth, fifth]) {}
    }
    private static func rfEdit(_ controller: TextDocumentController) -> TextDocument? {
        controller.documents.compactMap { $0 as? TextDocument }.first { $0.fileURL != nil }
    }
}
