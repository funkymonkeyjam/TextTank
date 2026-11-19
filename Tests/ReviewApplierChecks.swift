// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

private final class ReviewOwnedGate: @unchecked Sendable {
    let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var paused = false
    var isReached: Bool { reached.wait(timeout: .now()) == .success }
    func once() {
        lock.lock()
        let shouldPause = !paused
        paused = true
        lock.unlock()
        if shouldPause {
            reached.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }
}

@MainActor private final class ReviewWeakEditor {
    weak var value: TTEditor?
    init(_ value: TTEditor?) { self.value = value }
}

@main struct ReviewApplierChecks {
    @MainActor static func main() async {
        await Checks.run("ReviewApplierChecks") {
            let isolated = try IsolatedSupportDirectory("ReviewFoundation")
            let documents = TextDocumentController()
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            NativeFixtureEnvironment.install()
            let prior = EditorServices.current
            let delegate = AppDelegate()
            delegate.installEditorServices()
            LanguageController.bundledCatalogURL = TestPaths.resources.appendingPathComponent("LanguageProfiles.json")
            let host = delegate.workspaceWindow
            defer {
                host.tabCommands.isTerminating = true
                documents.documents.forEach { $0.close() }
                host.window?.orderOut(nil)
                EditorServices.current = prior
                NativeFixtureEnvironment.restore()
                isolated.restore()
            }
            @MainActor func fresh(_ text: String = "alpha beta\n") -> TextDocument {
                DocumentFactory.makeUntitled(display: false, populate: { $0.editor.text = text })
            }
            @MainActor func capture(_ doc: TextDocument) throws -> ReviewDocumentCapture {
                try ReviewSnapshotCapture.document(doc.editor)
            }
            @MainActor func edit(
                _ capture: ReviewDocumentCapture, _ lo: Int = 0, _ hi: Int = 5, _ text: String = "OMEGA"
            )
                -> ReviewEdit
            {
                .init(
                    range: .init(snapshot: capture.snapshot.id, lower: lo, upper: hi),
                    expected: capture.snapshot.bytes.subdata(in: lo..<hi), replacement: Data(text.utf8))
            }
            struct State: Equatable {
                let bytes: Data, revision: UInt, modified: Bool, selections: [[SessionSelection]]
                @MainActor init(_ doc: TextDocument) {
                    bytes = doc.editor.utf8Data
                    revision = doc.editor.revision
                    modified = doc.editor.modified
                    selections = doc.presentations.flatMap(\.views).map {
                        $0.selectionRanges.map { .init(anchorByte: $0.anchor, caretByte: $0.caret) }
                    }
                }
            }
            check(NSDocumentController.shared === documents, "F0 owned document controller")
            let d = fresh("\u{feff}a\0\r\né")
            let c = try capture(d)
            check(c.snapshot.bytes == Data("\u{feff}a\0\r\né".utf8), "F0 synchronous exact native capture")
            check(
                c.snapshot.document?.revision == d.editor.revision && c.snapshot.document?.loadEpoch == d.loadEpoch,
                "F0 atomic revision/epoch capture")
            let before = State(d)
            _ = try capture(d)
            check(State(d) == before, "F0 capture nonmutating")
            d.presentation?.clone(nil)
            let clone = try requireValue(d.presentation?.secondary, "F0 actual local clone")
            let cc = try ReviewSnapshotCapture.document(clone)
            check(
                cc.snapshot.source == c.snapshot.source && cc.snapshot.id != c.snapshot.id,
                "F0 clone source identity shared")
            let request = ReviewRequest(capture: c)
            let h = try requireValue(request.issue(edits: [edit(c, 3, 4, "B\0\u{feff}")]), "F0 issued exact handle")
            let after = Data("\u{feff}B\0\u{feff}\0\r\né".utf8)
            check(h.apply() == .applied && d.editor.utf8Data == after, "F0 one native FEFF/NUL batch")
            check(h.apply() == .rejected(.alreadyUsed), "F0 applied ticket single-use")
            clone.executeCommand(.init(rawValue: "undo"))
            check(d.editor.utf8Data == before.bytes, "F0 Undo from clone exact")
            d.editor.executeCommand(.init(rawValue: "redo"))
            check(clone.utf8Data == after, "F0 Redo through other view exact")
            check(request.issue(edits: []) == nil, "F0 no old ProposalID reissue")
            for kind in ["empty", "identical", "readonly", "revision", "range", "bytes", "text", "budget", "cancel"] {
                let doc = fresh("history base")
                doc.editor.replaceDocumentText("alpha beta\n")
                doc.editor.replaceDocumentText("existing redo branch")
                doc.editor.executeCommand(.init(rawValue: "undo"))
                let cap = try capture(doc)
                doc.presentation?.clone(nil)
                let sibling = try requireValue(doc.presentation?.secondary, "F0 rejection clone")
                _ = sibling.setSelectionRanges([.init(anchor: 8, caret: 3)])
                let req = ReviewRequest(capture: cap)
                var edits = [edit(cap)]
                var reason: ReviewApplyResult = .noChange
                switch kind {
                case "empty": edits = []
                case "identical": edits = [edit(cap, 0, 5, "alpha")]
                case "readonly":
                    sibling.readOnly = true
                    reason = .rejected(.readOnly)
                case "revision":
                    sibling.replaceDocumentText("changed")
                    reason = .rejected(.revisionChanged)
                case "range":
                    edits = [
                        .init(
                            range: .init(snapshot: cap.snapshot.id, lower: 1, upper: Int.max), expected: Data(),
                            replacement: Data())
                    ]
                    reason = .rejected(.invalidRange)
                case "bytes":
                    edits = [.init(range: edits[0].range, expected: Data("WRONG".utf8), replacement: Data())]
                    reason = .rejected(.bytesChanged)
                case "text":
                    edits = [.init(range: edits[0].range, expected: edits[0].expected, replacement: Data([0xff]))]
                    reason = .rejected(.invalidText)
                case "budget":
                    edits = Array(repeating: edit(cap), count: 100_001)
                    reason = .rejected(.budgetExceeded)
                default: reason = .rejected(.cancelled)
                }
                let handle = try requireValue(req.issue(edits: edits), "F0 issue \(kind)")
                if kind == "cancel" { req.cancel() }
                let state = State(doc), copied = handle
                check(handle.apply() == reason, "F0 typed result \(kind)")
                check(State(doc) == state, "F0 all-view state preserved \(kind)")
                check(handle.bridgeInvocations == 0, "F0 rejected/no-op never calls bridge \(kind)")
                check(copied.apply() == .rejected(.alreadyUsed), "F0 shared ticket consumed \(kind)")
                sibling.readOnly = false
                if kind != "revision" {
                    sibling.executeCommand(.init(rawValue: "redo"))
                    check(doc.editor.text == "existing redo branch", "F0 prior Redo branch preserved \(kind)")
                    doc.editor.executeCommand(.init(rawValue: "undo"))
                    check(doc.editor.text == "alpha beta\n", "F0 Redo undone exactly \(kind)")
                    sibling.executeCommand(.init(rawValue: "undo"))
                    check(doc.editor.text == "history base", "F0 prior Undo branch preserved \(kind)")
                } else {
                    sibling.executeCommand(.init(rawValue: "undo"))
                    check(doc.editor.text == "alpha beta\n", "F0 changed-revision prior Undo preserved")
                    doc.editor.executeCommand(.init(rawValue: "redo"))
                    check(doc.editor.text == "changed", "F0 changed-revision prior Redo preserved")
                }
            }
            for insertion in [true, false] {
                let doc = fresh("ab"), cap = try capture(doc)
                let handle = try requireValue(
                    ReviewRequest(capture: cap).issue(edits: [
                        edit(cap, insertion ? 1 : 0, insertion ? 1 : 2, insertion ? "é" : "")
                    ]), "F0 insertion/deletion handle")
                check(
                    handle.apply() == .applied && doc.editor.text == (insertion ? "aéb" : ""),
                    "F0 isolated insertion/deletion")
                doc.editor.executeCommand(.init(rawValue: "undo"))
                check(doc.editor.text == "ab", "F0 insertion/deletion one Undo")
            }
            let multi = fresh(), mc = try capture(multi)
            let mh = try requireValue(
                ReviewRequest(capture: mc).issue(edits: [edit(mc, 0, 5, "A"), edit(mc, 6, 10, "B")]), "F0 multi handle")
            var reentrant: ReviewApplyResult?
            let old = multi.editor.onChange
            multi.editor.onChange = {
                MainActor.assumeIsolated {
                    reentrant = mh.apply()
                    old?()
                }
            }
            check(mh.apply() == .applied && multi.editor.text == "A B\n", "F0 batch atomic")
            check(reentrant == .rejected(.alreadyUsed), "F0 synchronous onChange reentry consumed")
            multi.editor.onChange = old
            multi.editor.executeCommand(.init(rawValue: "undo"))
            check(multi.editor.text == "alpha beta\n", "F0 batch one Undo exact")
            multi.editor.executeCommand(.init(rawValue: "redo"))
            check(multi.editor.text == "A B\n", "F0 batch one Redo exact")
            // Surviving presentation resolves captured document; original editor can really release.
            var origin: TextDocument? = fresh()
            let survivorDoc = origin!, cap = try capture(survivorDoc)
            let tab = host.model.groups.flatMap(\.tabs).first { $0.documentID == survivorDoc.runtimeID }!.id
            _ = host.setEditorLayout(.twoColumns)
            let second = try requireValue(host.openView(tab, in: .second), "F0 second presentation")
            let retired = ReviewWeakEditor(host.presentation(for: tab)?.primaryEditor)
            let survive = try requireValue(ReviewRequest(capture: cap).issue(edits: [edit(cap)]), "F0 surviving handle")
            host.closeTab(tab, sender: nil)
            origin = nil
            check(host.presentation(for: second) != nil && retired.value == nil, "F0 cold nonfinal original release")
            check(
                survive.apply() == .applied && survivorDoc.editor.text == "OMEGA beta\n",
                "F0 surviving representative apply")
            let closing = fresh(), closedCap = try capture(closing)
            let closedHandle = try requireValue(
                ReviewRequest(capture: closedCap).issue(edits: [edit(closedCap)]), "F0 closed handle")
            closing.close()
            check(closedHandle.apply() == .rejected(.closed), "F0 final close rejects")
            // An identical successful reload is stale even if the engine revision did not change.
            let url = isolated.url.appendingPathComponent("reload.txt")
            try Data("alpha beta\n".utf8).write(to: url)
            let loaded = try DocumentFactory.openCaptured(
                WorkspaceStore.captureRegularFile(url), from: url, display: false)
            let lc = try capture(loaded),
                lh = try requireValue(ReviewRequest(capture: lc).issue(edits: [edit(lc)]), "F0 reload handle")
            try loaded.revert(toContentsOf: url, ofType: TextDocument.plainTextType)
            let state = State(loaded)
            check(lh.apply() == .rejected(.reloaded) && State(loaded) == state, "F0 identical reload epoch")
            let file = try await ReviewSnapshotCapture.file(url)
            check(
                file.bytes == Data("alpha beta\n".utf8) && file.format == FileFormat(), "F0 bounded strict file capture"
            )
            let injected = try ReviewSnapshotCapture.clipboard { Data("\u{feff}\0".utf8) }
            check(injected.bytes == Data("\u{feff}\0".utf8), "F0 explicit injected clipboard only")
            let malformed = isolated.url.appendingPathComponent("invalid.txt")
            try Data([0xff]).write(to: malformed)
            do {
                _ = try await ReviewSnapshotCapture.file(malformed)
                check(false, "F0 malformed file rejects")
            } catch { check(true, "F0 malformed file rejects") }
            let link = isolated.url.appendingPathComponent("symlink.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            do {
                _ = try await ReviewSnapshotCapture.file(link)
                check(false, "F0 no-follow capture")
            } catch { check(true, "F0 no-follow capture") }
            let comparison = fresh(), captured = try capture(comparison), review = ReviewRequest(capture: captured)
            let replacement = try TextSnapshot(
                bytes: Data("different\n".utf8), source: .freeText(UUID()), label: "owned")
            let result = await review.compare(to: replacement)
            let full = try requireValue(result, "F0 off-main request complete delivery")
            let completeHandle = try requireValue(
                review.issue(changes: full, modified: replacement), "F0 complete-only proposal")
            check(
                completeHandle.apply() == .applied && comparison.editor.text == "different\n",
                "F0 captured compare/proposal path")
            let staleDoc = fresh(), staleCapture = try capture(staleDoc),
                staleRequest = ReviewRequest(capture: staleCapture)
            let gate = ReviewOwnedGate()
            let worker = Task {
                await staleRequest.compare(
                    to: replacement,
                    hooks: .init(checkpoint: { phase, _ in
                        if phase == .lines { gate.once() }
                    }))
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            var paused = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                if gate.isReached {
                    paused = true
                    break
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            if !paused { gate.release.signal() }
            try require(paused, "F0 controlled worker barrier reached within owned deadline")
            // Edit without cancelling: only live stamp validation can reject this result.
            staleDoc.presentation?.clone(nil)
            staleDoc.presentation?.secondary?.replaceDocumentText("edited during worker")
            let staleState = State(staleDoc)
            gate.release.signal()
            let late = await worker.value
            check(
                late == nil && State(staleDoc) == staleState,
                "F0 edit-during-compute stale delivery dropped without cancellation")
            for operation in ["cancel", "supersede"] {
                let live = fresh(), captured = try capture(live), request = ReviewRequest(capture: captured)
                let gate = ReviewOwnedGate()
                let old = Task {
                    await request.compare(
                        to: replacement,
                        hooks: .init(checkpoint: { phase, _ in
                            if phase == .delivery { gate.once() }
                        }))
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                var paused = false
                while ProcessInfo.processInfo.systemUptime < deadline {
                    if gate.isReached {
                        paused = true
                        break
                    }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                if operation == "cancel" {
                    request.cancel()
                } else {
                    let newest = await request.compare(to: replacement)
                    check(newest?.completeness == .complete, "F0 newest generation remains deliverable")
                }
                gate.release.signal()
                try require(paused, "F0 completed-worker delivery barrier reached")
                let discarded = await old.value
                check(discarded == nil, "F0 late \(operation) result discarded")
            }
        }
    }
}
