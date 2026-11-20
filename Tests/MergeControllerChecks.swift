// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankCore
@testable import TextTankRuntime
import EditorBridge

@MainActor private final class MergeCheckLaunch: NSObject, NSApplicationDelegate {
    var onLaunch: (() -> Void)?
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { onLaunch?() }
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
                    let before = dest.editor.utf8Data, revision = dest.editor.revision, format = dest.format
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
                    check(dest.format == format, "D2 native format unchanged")
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
        }
    }
}
