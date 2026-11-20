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
        }
    }
}
