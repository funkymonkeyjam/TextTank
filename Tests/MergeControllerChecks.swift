// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge

@MainActor private final class MergeCheckLaunch: NSObject, NSApplicationDelegate {
    var onLaunch: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { onLaunch?() }
}
private actor MergeStageGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
@main struct MergeControllerChecks {
    struct Pair: Decodable { let name: String, before: String, after: String }
    @MainActor static func main() {
        do {
            let isolated = try IsolatedSupportDirectory("D2Controllers")
            NativeFixtureEnvironment.install()
            let documents = TextDocumentController(), app = NSApplication.shared, launch = MergeCheckLaunch()
            app.setActivationPolicy(.regular)
            app.delegate = launch
            launch.onLaunch = { Task { await runChecks(isolated, documents, app) } }
            withExtendedLifetime(launch) { app.run() }
            Checks.fail("Owned merge app stopped before completion", file: #filePath, line: #line)
        } catch { Checks.fail("Merge process setup: \(error)", file: #filePath, line: #line) }
        Checks.finish("MergeControllerChecks")
    }
    @MainActor private static func previewViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(previewViews)
    }

    @MainActor static func automationPreviewChecks(_ delegate: AppDelegate) async throws {
        let service = delegate.compare
        let showsWindows = service.showWindows
        service.showWindows = false
        defer { service.showWindows = showsWindows }
        let before = "old 雪\r\nkeep\r\nold\r\n", after = "new 雪\r\nkeep\r\nnew\r\n"
        let doc = DocumentFactory.makeUntitled(display: false, populate: { _ = $0.editor.loadDocumentText(before) })
        let other = DocumentFactory.makeUntitled(display: false, populate: { _ = $0.editor.loadDocumentText("neighbor") })
        defer { doc.close(); other.close() }
        var focused = doc.editor
        let automation = AutomationController(editorProvider: { focused }, newDocument: { _ in })
        automation.comparisonService = { service }
        var workflow = AutomationDefinition.example
        workflow.id = UUID()
        workflow.name = "Review saved text changes"
        workflow.input = .document
        workflow.output = .previewChanges
        workflow.steps = [.init(kind: .replaceLiteral, find: "old", replacement: "new")]
        workflow.previewBeforeApply = false
        try automation.persistLibrary(AutomationLibrary(workflows: [workflow]))
        func settle(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(predicate(), "saved automation comparison completed")
        }
        func openReview() async throws -> CompareController {
            focused = doc.editor
            let prior = service.windows
            try automation.runSavedAutomation(id: workflow.id)
            focused = other.editor
            try await settle { service.windows.contains { c in !prior.contains { $0 === c } && c.readyForMerge } }
            return try requireValue(service.windows.last, "automation result window")
        }
        doc.editor.resetUndoHistory()
        let review = try await openReview()
        check(review.merge.destination == .original && review.modified?.snapshot.bytes == Data(after.utf8)
              && review.original?.snapshot.bytes == Data(before.utf8), "saved workflow captured the original editor and exact transformed result")
        let projection = try requireValue(review.projection, "completed automation diff")
        check(review.merge.selectedBlocks == Set(projection.changes.blocks.indices) && review.merge.canPerform(.applySelected),
              "the first presentation selects its changes and allows individual blocks to be unticked")
        review.merge.applySelected()
        try await settle { !review.merge.isBusy && review.merge.lastOutcome == .applied }
        check(Data(doc.editor.text.utf8) == Data(after.utf8) && other.editor.text == "neighbor",
              "all selected changes target the captured document after focus changes")
        _ = doc.editor.executeCommand(.init(rawValue: "undo"))
        check(Data(doc.editor.text.utf8) == Data(before.utf8), "one Undo restores exact original bytes")
        review.close()
        let cancel = try await openReview()
        cancel.close()
        check(Data(doc.editor.text.utf8) == Data(before.utf8), "closing an unapplied review preserves the editor")
        check(doc.bulkReceipt?.before == Data(before.utf8) && doc.bulkReceipt?.after == Data(after.utf8),
              "Applied merge retains the actual before and after snapshots on its destination")
        let stale = try await openReview()
        stale.merge.perform(.selectAllChanges)
        _ = doc.editor.setSelectionAnchor(0, caret: 0)
        _ = doc.editor.replaceSelection("external ")
        stale.merge.applySelected()
        try await settle { !stale.merge.isBusy }
        check(doc.editor.text == "external " + before && other.editor.text == "neighbor",
              "stale automation output cannot overwrite a later edit")
        check(stale.modified?.canRetainForRefresh == false, "a frozen automation result cannot be rebound to a later document")
        stale.close()
        _ = doc.editor.loadDocumentText("outside old inside old remains")
        _ = doc.editor.setSelectionAnchor(8, caret: 11)
        workflow.input = .selection
        try automation.persistLibrary(AutomationLibrary(workflows: [workflow]))
        let selection = try await openReview()
        check(selection.modified?.snapshot.bytes == Data("outside new inside old remains".utf8),
              "selection output compares the projected whole document including unchanged text")
        selection.close()
        // A short captured selection avoids allocating a large editable preview control.
        let huge = "old" + String(repeating: "x", count: 8 * 1024 * 1024)
        _ = doc.editor.loadDocumentText(huge)
        _ = doc.editor.setSelectionAnchor(0, caret: 3)
        focused = doc.editor
        var sawReason = false
        let timeout = Date().addingTimeInterval(5)
        let dismiss = Timer(timeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow, let content = window.contentView else { return }
                let controls = previewViews(content)
                let explanation = controls.compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("8 MiB per side") })
                guard explanation || Date() > timeout, let cancel = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" })
                else { return }
                sawReason = explanation
                cancel.performClick(nil)
            }
        }
        RunLoop.main.add(dismiss, forMode: .modalPanel)
        defer { dismiss.invalidate() }
        try automation.runSavedAutomation(id: workflow.id)
        check(sawReason && doc.editor.text == huge && service.windows.isEmpty,
              "over-limit original describes the editable fallback and explicit Cancel preserves the captured editor")
    }

    @MainActor static func mergeRecordingChecks(_ delegate: AppDelegate, withoutRegistration: Bool = false) async throws
    {
        enum Scenario: CaseIterable {
            case apply, clone, unrelated, cancel, stale, readOnly, noChange, rejected, reentrant
        }
        let service = delegate.compare, recorder = delegate.macros
        let prepare = service.prepareSelectedChange, previousVisibility = service.showWindows
        let previousInvalidation = recorder.onInvalidated
        service.showWindows = false
        defer {
            service.showWindows = previousVisibility
            service.prepareSelectedChange = prepare
            recorder.onInvalidated = previousInvalidation
        }
        let stored = RecordedMacro(id: UUID(), name: "Existing macro", steps: [.insertText("keep")])
        try recorder.persist(MacroLibrary(macros: [stored]))
        let storage = AppStorage.url(.macros)
        @MainActor func newDocument() -> TextDocument {
            DocumentFactory.makeUntitled(display: false, populate: { _ = $0.editor.loadDocumentText("old\nkeep") })
        }
        @MainActor func insertReturn(in editor: TTEditor) throws {
            try require(
                editor.setSelectionAnchor(editor.byteLength, caret: editor.byteLength)
                    && editor.setLineEndingMode(.lf) && editor.executeCommand(.init(rawValue: "newLine")),
                "Record actual Return")
        }
        @MainActor func settle(_ comparison: CompareController) async throws {
            let ready = await waitUntil("comparison merge and rendering") {
                !comparison.isBusy && !comparison.hasPendingGeometry && !comparison.merge.isBusy
            }
            try require(ready, "Merge ready")
        }
        @MainActor func requireDiscard(_ recorder: MacroController) {
            do {
                _ = try recorder.finishRecording()
                check(false, "Applied merge cannot finish as a partial macro")
            } catch {
                check(
                    error.localizedDescription.contains(
                        withoutRegistration ? "without a recorded macro step" : "Applying selected comparison changes"),
                    "Finish explains the discarded merge recording")
            }
        }
        @MainActor func saveButton(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == "macro.save.confirm" { return button }
            for child in view.subviews { if let button = saveButton(child) { return button } }
            return nil
        }
        for scenario in Scenario.allCases {
            if withoutRegistration && scenario == .rejected { continue } // This case exercises the manual reservation.
            service.prepareSelectedChange = withoutRegistration ? nil : prepare
            var notices: [String] = []
            recorder.onInvalidated = { notices.append($0) }
            let destination = newDocument()
            let recordingDocument = scenario == .unrelated ? newDocument() : destination
            let presentation = try requireValue(recordingDocument.presentation, "Recording document presentation")
            delegate.workspaceWindow.activate(presentation, focus: false)
            if scenario == .clone { presentation.clone(nil) }
            let recordingView =
                scenario == .clone
                ? try requireValue(presentation.secondary, "Recording clone") : recordingDocument.editor
            try require(delegate.currentEditor === recordingView, "Recording starts in intended document and view")
            let target = destination.editor
            let prior: RecordedMacro?
            if scenario == .apply {
                recorder.startRecording()
                try insertReturn(in: recordingView)
                prior = try requireValue(recorder.finishRecording(), "Prior complete recording")
                _ = recordingView.executeCommand(.init(rawValue: "undo"))
            } else {
                prior = nil
            }
            let disk = try Data(contentsOf: storage)
            recorder.startRecording()
            try insertReturn(in: recordingView)
            let previousText = target.text, desired = previousText.replacingOccurrences(of: "old", with: "NEW")
            if scenario == .noChange {
                let request = ReviewRequest(capture: try ReviewSnapshotCapture.document(target))
                let handle = try requireValue(request.issue(edits: []), "Empty proposal")
                var prepared = false
                let outcome = handle.apply { editor in
                    prepared = true; return prepare?(editor)
                }
                check(
                    outcome == .noChange && !prepared && handle.bridgeInvocations == 0
                        && handle.apply() == .rejected(.alreadyUsed),
                    "No-change ticket consumed without touching recorder or bridge")
            } else {
                let opposite = try TextSnapshot(bytes: Data(desired.utf8), source: .freeText(UUID()), label: "Source")
                let comparison = try await service.open(
                    original: .document(try CompareDocumentInput(target)), modified: .snapshot(opposite))
                defer { comparison.window?.close() }
                try await settle(comparison)
                try require(
                    comparison.merge.chooseDestination(.original) && comparison.merge.setSelection([0]),
                    "Selected captured destination and block")
                let toolbar = try requireValue(comparison.window?.toolbar, "Compare toolbar")
                let item = try requireValue(
                    comparison.toolbar(
                        toolbar, itemForItemIdentifier: .init(CompareCommand.applySelected.rawValue),
                        willBeInsertedIntoToolbar: false), "Apply Selected toolbar command")
                let action = try requireValue(item.action, "Apply Selected action")
                let previousChange = target.onChange
                var reentered = false, provisionallyMarked = false
                defer {
                    target.onChange = previousChange; target.readOnly = false; service.prepareSelectedChange = prepare
                }
                if scenario == .reentrant {
                    target.onChange = {
                        previousChange?()
                        guard !reentered, target.text == desired else { return }
                        reentered = true
                        requireDiscard(recorder)
                        recorder.startRecording()
                    }
                }
                if scenario == .rejected {
                    service.prepareSelectedChange = { editor in
                        let finish = prepare?(editor)
                        provisionallyMarked = recorder.discardReason != nil
                        editor.readOnly = true
                        return finish
                    }
                }
                if scenario == .stale { try insertReturn(in: recordingView); comparison.pollSources() }
                if scenario == .readOnly { target.readOnly = true; comparison.pollSources() }
                check(
                    comparison.validateToolbarItem(item) == (scenario != .readOnly && scenario != .stale),
                    "Apply Selected validation \(scenario)")
                try require(NSApp.sendAction(action, to: item.target, from: item), "Native Apply Selected dispatch")
                if scenario == .cancel { comparison.perform(.cancel) }
                try await settle(comparison)
                switch scenario {
                case .cancel, .readOnly, .rejected, .stale:
                    let keptText = scenario == .stale ? previousText + "\n" : previousText
                    check(
                        target.text == keptText && comparison.merge.lastOutcome != .applied,
                        "Rejected or cancelled merge preserves destination \(scenario)")
                    if scenario == .rejected {
                        check(
                            provisionallyMarked && comparison.merge.lastOutcome == .failed,
                            "Final rejection rolls back only the provisional recorder failure")
                    }
                default:
                    check(
                        comparison.merge.lastOutcome == .applied && target.text == desired,
                        "Selected merge applied to captured destination \(scenario)")
                }
                if scenario == .reentrant {
                    try require(reentered, "Native onChange reentered recorder before dispatch returned")
                    try insertReturn(in: recordingView)
                }
            }
            check(try Data(contentsOf: storage) == disk, "Merge leaves saved macros unchanged \(scenario)")
            if scenario == .apply || scenario == .clone {
                check(
                    notices.count == 1 && notices.first == recorder.discardReason,
                    "Announce the committed discard once \(scenario)")
                check(
                    recorder.discardReason != nil, "Committed merge invalidates the destination recording \(scenario)")
                requireDiscard(recorder)
                _ = target.executeCommand(.init(rawValue: "undo"))
                check(
                    target.text == previousText && recordingView.text == previousText,
                    "One Undo restores exact destination across views \(scenario)")
            } else {
                let expected = Array(repeating: RecordedMacro.Step.insertText("\n"), count: scenario == .stale ? 2 : 1)
                check(
                    notices.count == (withoutRegistration && scenario == .reentrant ? 1 : 0),
                    "No spurious discard notice \(scenario)")
                check(
                    try recorder.finishRecording()?.steps == expected,
                    "Valid independent or unaffected recording retains actual Return \(scenario)")
            }
            if let prior {
                let item = try requireValue(
                    recorder.menu().item(withTitle: "Save Last Recording…"), "Save prior recording")
                let save = try requireValue(item.action, "Save last recording action")
                try require(
                    item.isEnabled && NSApp.sendAction(save, to: item.target, from: item), "Open saved recording form")
                let form = try requireValue(
                    FormPanel.visible.first { $0.window.identifier?.rawValue == "macro.save" }, "Macro Save form")
                let button = try requireValue(form.window.contentView.flatMap(saveButton), "Macro Save action")
                button.performClick(nil)
                check(
                    try MacroLibrary.decode(Data(contentsOf: storage)).macros == [stored, prior],
                    "Saving last recording preserves its ID and steps plus preexisting disk macro")
            }
        }
    }
    @MainActor static func runChecks(
        _ isolated: IsolatedSupportDirectory, _ documents: TextDocumentController, _ app: NSApplication
    ) async {
        await Checks.run("MergeControllerChecks") {
            let prior = EditorServices.current, delegate = AppDelegate()
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
            @MainActor func fresh(_ text: String) -> TextDocument {
                DocumentFactory.makeUntitled(display: false, populate: { _ = $0.editor.loadDocumentText(text) })
            }
            check(
                app.isRunning && NSDocumentController.shared === documents,
                "D2 owned native event loop/document controller")
            try await automationPreviewChecks(delegate)
            try await mergeRecordingChecks(delegate)
            try await mergeRecordingChecks(delegate, withoutRegistration: true)
            let pairs = try JSONDecoder().decode(
                [Pair].self, from: Data(contentsOf: TestPaths.fixtures.appendingPathComponent("review/corpus.json")))
            for pair in pairs {
                for side in [CompareSide.original, .modified] {
                    let a = fresh(pair.before), b = fresh(pair.after)
                    let ac = try ReviewSnapshotCapture.document(a.editor),
                        bc = try ReviewSnapshotCapture.document(b.editor)
                    let changes = await ReviewDiffEngine.compare(ac.snapshot, bc.snapshot)
                    let dest = side == .original ? a : b, captured = side == .original ? ac : bc
                    let source = side == .original ? bc.snapshot : ac.snapshot
                    dest.presentation?.clone(nil)
                    let clone = try requireValue(dest.presentation?.secondary, "D2 clone")
                    let before = dest.editor.utf8Data, revision = dest.editor.revision, format = dest.format,
                        insertionMode = dest.editor.statusInfo.eol
                    let plan = try await MergeCore.plan(
                        original: ac.snapshot, modified: bc.snapshot, changes: changes, destination: side,
                        parent: captured.snapshot, slice: nil, selected: Array(changes.blocks.indices))
                    let request = ReviewRequest(capture: captured)
                    let handle = try requireValue(request.issue(edits: plan.proposal.edits), "D2 one native handle")
                    let outcome = handle.apply()
                    check(
                        outcome == (before == source.bytes ? .noChange : .applied), "D2 native all apply \(pair.name)")
                    check(
                        dest.editor.utf8Data == source.bytes && clone.utf8Data == source.bytes,
                        "D2 native exact both clones")
                    check(
                        dest.format == format && dest.editor.statusInfo.eol == insertionMode
                            && clone.statusInfo.eol == insertionMode,
                        "D2 native encoding BOM and shared insertion mode unchanged")
                    check(handle.apply() == .rejected(.alreadyUsed), "D2 native handle single use")
                    if before != source.bytes {
                        clone.executeCommand(.init(rawValue: "undo"))
                        check(dest.editor.utf8Data == before, "D2 one Undo restores all exact")
                        dest.editor.executeCommand(.init(rawValue: "redo"))
                        check(clone.utf8Data == source.bytes, "D2 one Redo reapplies all exact")
                    } else {
                        check(dest.editor.revision == revision, "D2 no-op revision unchanged")
                    }
                }
            }
            let parent = fresh("before\nold\nafter\n"), capture = try ReviewSnapshotCapture.document(parent.editor)
            let slice = try TextSnapshot(bytes: Data("old\n".utf8), source: .freeText(UUID()), label: "selection")
            let replacement = try TextSnapshot(bytes: Data("NEW\r\n".utf8), source: .freeText(UUID()), label: "source")
            let difference = await ReviewDiffEngine.compare(slice, replacement)
            let plan = try await MergeCore.plan(
                original: slice, modified: replacement, changes: difference, destination: .original,
                parent: capture.snapshot, slice: 7..<11, selected: [0])
            let selectedHandle = try requireValue(
                ReviewRequest(capture: capture).issue(edits: plan.proposal.edits), "D2 slice handle")
            check(
                selectedHandle.apply() == .applied && parent.editor.text == "before\nNEW\r\nafter\n",
                "D2 native selection parent exact")
            parent.editor.executeCommand(.init(rawValue: "undo"))
            check(parent.editor.utf8Data == capture.snapshot.bytes, "D2 slice one Undo exact")
            for reason in ["edit", "readonly", "reload", "close", "clone"] {
                let doc = fresh("old\n"), c = try ReviewSnapshotCapture.document(doc.editor)
                let delta = await ReviewDiffEngine.compare(c.snapshot, replacement)
                let p = try await MergeCore.plan(
                    original: c.snapshot, modified: replacement, changes: delta, destination: .original,
                    parent: c.snapshot, slice: nil, selected: [0])
                let h = try requireValue(ReviewRequest(capture: c).issue(edits: p.proposal.edits), "D2 stale handle")
                switch reason {
                case "edit": doc.editor.text = "changed\n"
                case "readonly": doc.editor.readOnly = true
                case "reload": try doc.read(from: Data("old\n".utf8), ofType: TextDocument.plainTextType)
                case "close": doc.close()
                default:
                    doc.presentation?.clone(nil)
                    doc.presentation?.secondary?.text = "clone edit\n"
                }
                let bytes = doc.editor.utf8Data, revision = doc.editor.revision
                if case .rejected = h.apply() {
                    check(true, "D2 \(reason) stale refuses")
                } else {
                    check(false, "D2 \(reason) stale refuses")
                }
                check(
                    doc.editor.utf8Data == bytes && doc.editor.revision == revision,
                    "D2 refusal no byte/revision effect")
            }

            // Headless staged-output gate, before any D2 UI is wired.
            let output = isolated.url.appendingPathComponent("patch.diff"), oldOutput = Data("OLD".utf8),
                patchBytes = Data("PATCH\r\n".utf8)
            try oldOutput.write(to: output)
            let staged = try await Task.detached { try PrivateFileStore.prepareOutput(patchBytes, to: output) }.value
            check(try Data(contentsOf: output) == oldOutput, "D2 staging has no publication")
            try staged.commit()
            check(try Data(contentsOf: output) == patchBytes, "D2 guarded staged publication exact")
            let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
            check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "D2 output is0600")
            do {
                try staged.commit()
                check(false, "D2 duplicate ticket")
            } catch { check(true, "D2 single-use commit") }
            let cancelledOutput = try await Task.detached { try PrivateFileStore.prepareOutput(oldOutput, to: output) }
                .value
            cancelledOutput.cancel()
            cancelledOutput.cancel()
            check(try Data(contentsOf: output) == patchBytes, "D2 cancel staged output preserves previous bytes")
            do {
                try cancelledOutput.commit()
                check(false, "D2 cancelled publication")
            } catch { check(true, "D2 cancelled ticket refuses") }
            for fault in ["write", "sync", "close"] {
                do {
                    _ = try await Task.detached {
                        try PrivateFileStore.prepareOutput(
                            oldOutput, to: output,
                            synchronize: { fd in fault == "sync" ? -1 : fsync(fd) },
                            closeFile: { fd in
                                let result = Darwin.close(fd)
                                return fault == "close" ? -1 : result
                            },
                            writeChunk: { fd, bytes, count in fault == "write" ? 0 : Darwin.write(fd, bytes, count) })
                    }.value
                    check(false, "D2 staged \(fault) fault")
                } catch { check(true, "D2 staged \(fault) refuses") }
                check(try Data(contentsOf: output) == patchBytes, "D2 stage fault old bytes unchanged")
            }
            let targetSwap = try await Task.detached { try PrivateFileStore.prepareOutput(oldOutput, to: output) }.value
            try Data("other writer".utf8).write(to: output)
            do {
                try targetSwap.commit()
                check(false, "D2 changed target")
            } catch { check(true, "D2 final target metadata revalidation") }
            check(try Data(contentsOf: output) == Data("other writer".utf8), "D2 changed target retained")
            let expectedTarget = try PreparedFileIdentity.capture(output)
            try patchBytes.write(to: output)
            do {
                _ = try await Task.detached {
                    try PrivateFileStore.prepareOutput(oldOutput, to: output, expectedTarget: expectedTarget)
                }.value
                check(false, "D2 target changed before staging")
            } catch { check(true, "D2 panel-to-stage target guard") }
            let absentURL = isolated.url.appendingPathComponent("absent.diff")
            let absent = try await Task.detached { try PrivateFileStore.prepareOutput(oldOutput, to: absentURL) }.value
            try patchBytes.write(to: absentURL)
            do {
                try absent.commit()
                check(false, "D2 appeared target")
            } catch { check(true, "D2 absent-to-existing refuses") }
            let link = isolated.url.appendingPathComponent("link.diff")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
            do {
                _ = try await Task.detached { try PrivateFileStore.prepareOutput(oldOutput, to: link) }.value
                check(false, "D2 symlink stage")
            } catch { check(true, "D2 nofollow output target") }
            let folder = isolated.url.appendingPathComponent("parent"),
                moved = isolated.url.appendingPathComponent("parent-moved")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let nested = folder.appendingPathComponent("patch.diff")
            try oldOutput.write(to: nested)
            let parentTicket = try await Task.detached { try PrivateFileStore.prepareOutput(patchBytes, to: nested) }
                .value
            try FileManager.default.moveItem(at: folder, to: moved)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            do {
                try parentTicket.commit()
                check(false, "D2 parent swap")
            } catch { check(true, "D2 directory identity guard") }
            check(
                try Data(contentsOf: moved.appendingPathComponent("patch.diff")) == oldOutput,
                "D2 moved parent old output retained")
            check(!FileManager.default.fileExists(atPath: nested.path), "D2 new parent no publication")
            do {
                _ = try await Task.detached {
                    try PrivateFileStore.prepareOutput(oldOutput, to: output, isCancelled: { true })
                }.value
                check(false, "D2 pre-stage cancellation")
            } catch { check(true, "D2 no staging after cancel") }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: isolated.url.path).filter {
                $0.hasPrefix(".texttank-patch-")
            }
            let movedLeftovers = try FileManager.default.contentsOfDirectory(atPath: moved.path)
            check(
                leftovers.isEmpty && movedLeftovers.allSatisfy { !$0.hasPrefix(".texttank-patch-") },
                "D2 all failed/cancelled temp cleanup")
            try PrivateFileStore.write(oldOutput, to: output, maximumBytes: 32)
            check(try Data(contentsOf: output) == oldOutput, "D2 legacy atomic writer unchanged")

            // D2 native controller contract, added test-first after headless Gate A.
            var comparisonServices: [CompareService] = []
            defer { comparisonServices.flatMap(\.windows).forEach { $0.window?.close() } }
            @MainActor func comparison(_ a: CompareInput, _ b: CompareInput, visible: Bool = false) async throws -> CompareController {
                let service = CompareService()
                service.showWindows = visible
                comparisonServices.append(service)
                let window = try await service.open(original: a, modified: b)
                try await ready(window)
                return window
            }
            @MainActor func ready(_ comparison: CompareController) async throws {
                let deadline = ProcessInfo.processInfo.systemUptime + 10
                while (comparison.isBusy || comparison.hasPendingGeometry || comparison.merge.isBusy)
                    && ProcessInfo.processInfo.systemUptime < deadline
                {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                try require(
                    !comparison.isBusy && !comparison.hasPendingGeometry && !comparison.merge.isBusy,
                    "D2 native pipeline settles")
            }
            @MainActor func live(_ document: TextDocument, selected: Bool = false) throws -> CompareInput {
                .document(try CompareDocumentInput(document.editor, selection: selected))
            }
            @MainActor func value(_ text: String) throws -> CompareInput {
                .snapshot(try TextSnapshot(bytes: Data(text.utf8), source: .freeText(UUID()), label: "owned.txt"))
            }
            let dest = fresh("a\nkeep\nz\n"), opposite = fresh("A\nkeep\nZ\n")
            let cmp = try await comparison(live(dest), live(opposite))
            check(!cmp.merge.canPerform(.applySelected) && cmp.merge.destination == nil, "D2 no automatic destination")
            check(cmp.merge.chooseDestination(.original), "D2 explicit Original destination")
            check(cmp.merge.setSelection([0]) && cmp.merge.canPerform(.applySelected), "D2 selected block validates")
            cmp.perform(.next)
            check(cmp.statusText.contains(dest.displayName), "D2 navigation retains visible destination scope")
            let applyToolbar = NSToolbarItem(itemIdentifier: .init(CompareCommand.applySelected.rawValue))
            check(
                cmp.validateToolbarItem(applyToolbar) && applyToolbar.toolTip?.contains(dest.displayName) == true,
                "D2 Apply toolbar names explicit destination")
            cmp.merge.applySelected()
            check(cmp.merge.isBusy && !cmp.merge.canPerform(.applySelected), "D2 busy before first await")
            cmp.merge.applySelected()
            try await ready(cmp)
            check(
                cmp.merge.lastOutcome == .applied && dest.editor.text == "A\nkeep\nz\n",
                "D2 partial native controller exact selected")
            check(
                cmp.projection?.changes.blocks.count == 1 && cmp.merge.selectedBlocks.isEmpty && !cmp.outOfDate,
                "D2 fresh remaining comparison clears coordinates")
            check(cmp.merge.setSelection([0]), "D2 select recomputed new ordinal")
            cmp.merge.applySelected()
            try await ready(cmp)
            check(
                dest.editor.text == opposite.editor.text && cmp.projection?.changes.identical == true,
                "D2 controller sequence converges")
            dest.editor.executeCommand(.init(rawValue: "undo"))
            cmp.pollSources()
            check(cmp.outOfDate && !cmp.merge.canPerform(.applySelected), "D2 ordinary Undo stales comparison")
            check(cmp.merge.canPerform(.showDestination), "D2 Show Destination available when stale")
            cmp.perform(.refresh)
            try await ready(cmp)
            check(!cmp.outOfDate && cmp.projection?.changes.blocks.count == 1, "D2 explicit Refresh after Undo")
            let reverse = try await comparison(live(dest), live(opposite))
            check(reverse.merge.chooseDestination(.modified), "D2 explicit Modified destination")
            check(reverse.merge.setSelection([0]), "D2 reverse selection")
            reverse.merge.applySelected()
            try await ready(reverse)
            check(opposite.editor.utf8Data == dest.editor.utf8Data, "D2 reverse controller exact")
            let immutable = try await comparison(value("a\n"), value("b\n"))
            check(
                !immutable.merge.chooseDestination(.original) && !immutable.merge.chooseDestination(.modified),
                "D2 value sources never editable destinations")
            let sliceDoc = fresh("prefix\nold\nsuffix\n")
            sliceDoc.editor.setSelectionAnchor(7, caret: 11)
            let selected = try await comparison(live(sliceDoc, selected: true), value(""))
            check(
                selected.merge.chooseDestination(.original) && selected.merge.setSelection([0]),
                "D2 selection destination chooses parent")
            selected.merge.applySelected()
            try await ready(selected)
            check(
                sliceDoc.editor.text == "prefix\nsuffix\n" && selected.original?.snapshot.bytes.isEmpty == true
                    && !selected.outOfDate, "D2 empty postapply bound selection recomputes")
            let encodingDoc = fresh("old\n")
            encodingDoc.format = .init(encoding: .latin1)
            let encodingComparison = try await comparison(live(encodingDoc), value("emoji👩🏽‍💻\n"))
            check(
                encodingComparison.merge.chooseDestination(.original) && encodingComparison.merge.setSelection([0]),
                "D2 legacy destination chosen")
            encodingComparison.merge.applySelected()
            try await ready(encodingComparison)
            check(
                encodingDoc.editor.text == "old\n" && encodingComparison.merge.lastOutcome == .failed
                    && encodingDoc.format.encoding == .latin1, "D2 unrepresentable rejects atomically at application")
            for encoding in [FileEncoding.utf8, .utf16LE, .utf16BE] {
                let bomDoc = fresh("old\r\n"), expectedFormat = FileFormat(encoding: encoding, bom: true)
                bomDoc.format = expectedFormat
                let insertion = bomDoc.editor.statusInfo.eol
                let bomComparison = try await comparison(live(bomDoc), value("new\n"))
                check(
                    bomComparison.merge.chooseDestination(.original) && bomComparison.merge.setSelection([0]),
                    "D2 BOM destination chosen")
                bomComparison.merge.applySelected()
                try await ready(bomComparison)
                check(
                    bomDoc.editor.text == "new\n" && bomDoc.format == expectedFormat
                        && bomDoc.editor.statusInfo.eol == insertion,
                    "D2 representable merge preserves original encoding BOM and insertion mode")
            }
            let metadataDoc = fresh("old\n"), metadataCmp = try await comparison(live(metadataDoc), value("new\n"))
            check(
                metadataCmp.merge.chooseDestination(.original) && metadataCmp.merge.setSelection([0]),
                "D2 metadata selection setup")
            _ = metadataDoc.editor.setLineEndingMode(.crlf)
            metadataCmp.pollSources()
            check(
                metadataCmp.outOfDate && metadataCmp.merge.selectedBlocks.isEmpty
                    && !metadataCmp.merge.canPerform(.applySelected),
                "D2 metadata-only EOL change invalidates old comparison")
            let copy = try await comparison(value("a\r\nb"), value("a\nc\r"))
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            var copies = 0
            copy.merge.publishClipboard = { text in
                copies += 1
                board.clearContents()
                return board.setString(text, forType: .string)
            }
            check(copy.merge.canPerform(.copyPatch), "D2 complete value comparison can export")
            check(copies == 0, "D2 validation never publishes clipboard")
            copy.merge.copyPatch()
            try await ready(copy)
            let expectedPatch = try await UnifiedPatch.write(
                original: copy.original!.snapshot, modified: copy.modified!.snapshot, changes: copy.projection!.changes)
            check(
                copies == 1 && Data((board.string(forType: .string) ?? "").utf8) == expectedPatch,
                "D2 explicit private clipboard exact patch")
            let special = try await comparison(value("\u{feff}a\0\n"), value("\u{feff}b\0\n"))
            special.merge.publishClipboard = { text in
                board.clearContents()
                return board.setString(text, forType: .string)
            }
            special.merge.copyPatch()
            try await ready(special)
            let literalSpecial = Data(
                "--- a/owned.txt\n+++ b/owned.txt\n@@ -1,1 +1,1 @@\n-\u{feff}a\0\n+\u{feff}b\0\n".utf8)
            check(
                Data((board.string(forType: .string) ?? "").utf8) == literalSpecial,
                "D2 actual private clipboard preserves NUL and real FEFF payload")
            let exported = isolated.url.appendingPathComponent("controller-export.diff")
            copy.merge.choosePatchFile = { _ in exported }
            copy.merge.exportPatch()
            try await ready(copy)
            check(
                try copy.merge.lastOutcome == .exported && Data(contentsOf: exported) == expectedPatch,
                "D2 explicit file command exact patch")
            copy.merge.choosePatchFile = { _ in nil }
            copy.merge.exportPatch()
            try await ready(copy)
            check(
                try copy.merge.lastOutcome == .cancelled && Data(contentsOf: exported) == expectedPatch,
                "D2 export cancellation preserves old output")
            let protectedURL = isolated.url.appendingPathComponent("source.txt")
            try Data("disk\n".utf8).write(to: protectedURL)
            let saved = try DocumentFactory.openCaptured(
                WorkspaceStore.captureRegularFile(protectedURL), from: protectedURL, display: false)
            saved.editor.text = "draft\n"
            let savedInput = try CompareDocumentInput(saved.editor)
            let savedCmp = try await comparison(
                .document(savedInput), .savedFile(try CompareSavedFileInput(savedInput)))
            check(
                savedCmp.merge.chooseDestination(.original) && savedCmp.merge.setSelection([0]),
                "D2 tab/saved destination")
            let savedDiskIdentity = try PreparedFileIdentity.capture(protectedURL)
            savedCmp.merge.applySelected()
            try await ready(savedCmp)
            check(
                saved.editor.text == "disk\n" && !savedCmp.outOfDate && savedCmp.projection?.changes.identical == true,
                "D2 saved association rebinds known own apply without read")
            check(
                try saved.isDocumentEdited && PreparedFileIdentity.capture(protectedURL) == savedDiskIdentity,
                "D2 merge never saves or rewrites destination disk file")
            saved.editor.text = "new draft\n"
            savedCmp.perform(.refresh)
            try await ready(savedCmp)
            let alias = isolated.url.appendingPathComponent("source-hardlink.txt")
            try FileManager.default.linkItem(at: protectedURL, to: alias)
            savedCmp.merge.choosePatchFile = { _ in alias }
            savedCmp.merge.exportPatch()
            try await ready(savedCmp)
            check(
                try savedCmp.merge.lastOutcome == .failed && Data(contentsOf: protectedURL) == Data("disk\n".utf8),
                "D2 export refuses source hardlink")
            let movedURL = isolated.url.appendingPathComponent("moved-source.txt")
            let movedArchive = isolated.url.appendingPathComponent("moved-source-original.txt")
            let movedAlias = isolated.url.appendingPathComponent("moved-source-alias.txt")
            let capturedBytes = Data("captured\n".utf8), replacementBytes = Data("replacement\n".utf8)
            try capturedBytes.write(to: movedURL)
            let movedComparison = try await comparison(.file(movedURL), value("changed\n"))
            check(
                movedComparison.original?.snapshot.capturedFileIdentity != nil,
                "D2 actual file descriptor identity retained")
            try FileManager.default.moveItem(at: movedURL, to: movedArchive)
            try FileManager.default.linkItem(at: movedArchive, to: movedAlias)
            try replacementBytes.write(to: movedURL)
            movedComparison.merge.choosePatchFile = { _ in movedAlias }
            movedComparison.merge.exportPatch()
            try await ready(movedComparison)
            check(
                try movedComparison.merge.lastOutcome == .failed && Data(contentsOf: movedArchive) == capturedBytes
                    && Data(contentsOf: movedAlias) == capturedBytes && Data(contentsOf: movedURL) == replacementBytes,
                "D2 captured moved inode remains protected after original path replacement")
            for scenario in ["cancel", "edit", "close"] {
                let heldDoc = fresh("held old\n")
                let held = try await comparison(live(heldDoc), value("held new\n"))
                let outputURL = isolated.url.appendingPathComponent("held-" + scenario + ".patch")
                try oldOutput.write(to: outputURL)
                let gate = MergeStageGate()
                held.merge.choosePatchFile = { _ in outputURL }
                held.merge.stagePatchOutput = { data, url, expected, cancellation in
                    let real = try await Task.detached {
                        try PrivateFileStore.prepareOutput(
                            data, to: url, expectedTarget: expected, isCancelled: { cancellation.isCancelled })
                    }.value
                    await gate.wait()
                    return real
                }
                held.merge.exportPatch()
                let limit = ProcessInfo.processInfo.systemUptime + 10
                while !(await gate.entered) && ProcessInfo.processInfo.systemUptime < limit {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                let entered = await gate.entered
                try require(entered, "D2 real staged output reached final-commit boundary")
                check(try Data(contentsOf: outputURL) == oldOutput, "D2 held real staged output unpublished")
                switch scenario {
                case "edit":
                    heldDoc.editor.text = "intervening edit\n"
                    held.pollSources()
                case "close": held.window?.close()
                default: held.perform(.cancel)
                }
                await gate.release()
                while held.service?.hasActivePipeline == true && ProcessInfo.processInfo.systemUptime < limit {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                check(
                    held.service?.hasActivePipeline != true && held.merge.lastOutcome != .exported,
                    "D2 held stage \(scenario) drops late publication")
                check(try Data(contentsOf: outputURL) == oldOutput, "D2 final-guard \(scenario) preserves old file")
                check(
                    try FileManager.default.contentsOfDirectory(atPath: isolated.url.path).allSatisfy {
                        !$0.hasPrefix(".texttank-patch-")
                    }, "D2 held stage \(scenario) cleans real temp")
            }
            // Observe the real AppKit Save panel, then cancel through its normal action.
            NSApp.activate(ignoringOtherApps: true)
            let panelComparison = try await comparison(value("before"), value("after"), visible: true)
            var nativeSavePanel: NSSavePanel?
            panelComparison.merge.makeSavePanel = {
                let panel = NSSavePanel()
                nativeSavePanel = panel
                return panel
            }
            let canExport = await waitUntil("visible comparison to enable patch export") {
                panelComparison.window?.isVisible == true && panelComparison.merge.canPerform(.exportPatch)
            }
            try require(canExport, "D2 native export has a ready document window")
            panelComparison.merge.exportPatch()
            let panelDeadline = ProcessInfo.processInfo.systemUptime + 10
            while nativeSavePanel?.isVisible != true && ProcessInfo.processInfo.systemUptime < panelDeadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let actualPanel = try requireValue(nativeSavePanel, "D2 actual native save panel created")
            check(
                actualPanel.isVisible && panelComparison.window?.attachedSheet === actualPanel,
                "D2 actual save panel attached to comparison")
            check(
                actualPanel.message.contains("UTF-8") && actualPanel.message.contains("complete"),
                "D2 native export sheet explains encoding and scope")
            actualPanel.cancel(nil)
            try await ready(panelComparison)
            check(panelComparison.merge.lastOutcome == .cancelled, "D2 real native save panel Cancel")
            let sheetDoc = fresh("old\n")
            let sheetCmp = try await comparison(live(sheetDoc), value("new\n"), visible: true)
            check(sheetCmp.merge.chooseDestination(.original), "D2 sheet explicit destination")
            await waitUntil("visible comparison to enable change selection") {
                sheetCmp.window?.isVisible == true && sheetCmp.merge.canPerform(.selectChanges)
            }
            sheetCmp.merge.showSelectionSheet()
            let selectionSheet = try requireValue(sheetCmp.merge.sheet, "D2 native selection sheet")
            selectionSheet.window?.contentView?.layoutSubtreeIfNeeded()
            check(
                sheetCmp.window?.attachedSheet === selectionSheet.window && !selectionSheet.window!.canBecomeMain,
                "D2 auxiliary sheet native scoped owner")
            check(
                selectionSheet.table.numberOfRows == sheetCmp.projection?.changes.blocks.count,
                "D2 virtualized rows correspond to whole blocks")
            let checkbox = selectionSheet.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSButton
            check(
                checkbox?.accessibilityLabel()?.contains("Change 1") == true, "D2 actual checkbox scoped accessibility")
            checkbox?.performClick(nil)
            let selectedCheckbox = selectionSheet.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSButton
            check(
                sheetCmp.merge.selectedBlocks == [0] && selectedCheckbox?.state == .on,
                "D2 actual native checkbox selected non-colour cue")
            check(
                (selectedCheckbox?.accessibilityValue() as? NSNumber)?.intValue == 1,
                "D2 actual checkbox selected AX value")
            check(
                selectionSheet.destination.selectedItem?.title.contains(sheetDoc.displayName) == true,
                "D2 destination popup names exact document")
            selectionSheet.dismiss(cancelled: true)
            selectedCheckbox?.performClick(nil)
            check(sheetCmp.merge.selectedBlocks.isEmpty, "D2 retained dismissed checkbox cannot select a newer intent")

            check(
                cmp.window?.attachedSheet == nil && cmp.merge.selectedBlocks.isEmpty,
                "D2 native sheet Cancel releases selection")
        }
    }
}
