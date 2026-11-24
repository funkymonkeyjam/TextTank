import Foundation
@testable import TextTankCore

@main struct TabIntegrationCoreChecks {
    /// DS-D9: the automatic session names kept untitled documents only in a version-2 record.
    static func keptUntitledSessionRecords() throws {
        func fixture(_ name: String) throws -> Data {
            try Data(contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/" + name))
        }
        let before = try fixture("LastSession.json")
        let old = try LastSessionLayout.decode(before)
        check(
            old.version == 1 && old.untitled == nil && old.files.map(\.path) == ["/synthetic/notes.txt"]
                && old.layout.groups[0].tabs.count == 1,
            "V9 a last-session file written before the decision loads as it did")
        check(try old.encoded() == before, "V9 a session with no kept untitled document is written byte for byte as before")
        check(
            try LastSessionLayout(files: old.files, untitled: [], layout: old.layout).encoded() == before,
            "V9 the new initializer without untitled documents writes version 1")
        let bytes = try fixture("LastSession-untitled.json")
        let kept = try LastSessionLayout.decode(bytes)
        let tabs = kept.layout.groups.flatMap(\.tabs)
        check(
            kept.version == 2 && kept.files.count == 1 && kept.untitled?.count == 2
                && kept.untitled?.map(\.language) == ["swift", nil]
                && kept.untitled?.map(\.lineEnding) == ["CRLF", "LF"],
            "V9 golden record names two untitled documents with language and line ending")
        check(
            tabs.map(\.documentID) == [kept.untitled![0].id, kept.files[0].id, kept.untitled![1].id]
                && tabs.map(\.isPinned) == [true, false, false] && tabs[0].caretByte == 7 && tabs[0].anchorByte == 3
                && kept.layout.groups.map(\.tabs.count) == [2, 1],
            "V9 golden record keeps untitled tabs in order, group and pin state with their selection")
        check(try kept.encoded() == bytes, "V9 golden version-2 record round trips through the production encoder")
        check(!String(decoding: bytes, as: UTF8.self).contains("text"), "V9 the session record holds no document text")
        let only = try kept.untitledOnly()
        check(
            only.files.isEmpty && only.untitled == kept.untitled && only.version == 2
                && only.layout.groups.map(\.tabs.count) == [1, 1],
            "V9 a launch set to a new document still gets the kept untitled tabs, without the files")
        check(try old.untitledOnly().version == 1, "V9 untitled-only of a files-only record is an empty version-1 record")
        var raw = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        raw["version"] = 1
        rejects("V9 untitled entries are refused in a version-1 record") {
            _ = try LastSessionLayout.decode(JSONSerialization.data(withJSONObject: raw))
        }
        raw = try JSONSerialization.jsonObject(with: before) as! [String: Any]
        raw["version"] = 2
        rejects("V9 a version-2 record must name an untitled document") {
            _ = try LastSessionLayout.decode(JSONSerialization.data(withJSONObject: raw))
        }
        raw = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var entries = raw["untitled"] as! [[String: Any]]
        entries[1]["lineEnding"] = "NEL"
        raw["untitled"] = entries
        rejects("V9 an unknown line ending is refused") {
            _ = try LastSessionLayout.decode(JSONSerialization.data(withJSONObject: raw))
        }
        entries[1]["lineEnding"] = "LF"
        entries[1]["id"] = (raw["files"] as! [[String: Any]])[0]["id"]
        raw["untitled"] = entries
        rejects("V9 one identity cannot be both a file and an untitled document") {
            _ = try LastSessionLayout.decode(JSONSerialization.data(withJSONObject: raw))
        }
        rejects("V9 an untitled tab without a record is refused") {
            _ = try LastSessionLayout.decode(
                JSONSerialization.data(withJSONObject: {
                    var value = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    value["untitled"] = [(value["untitled"] as! [[String: Any]])[0]]
                    return value
                }()))
        }
        let settings = try EditorSettings.decode(fixture("Settings.json"))
        check(
            settings.keepUntitledOnQuit == nil && settings.keepsUntitledOnQuit,
            "V9 a settings file without the key keeps unsaved untitled documents when quitting")
        var off = settings
        off.keepUntitledOnQuit = false
        let reread = try EditorSettings.decode(JSONEncoder().encode(off))
        check(!reread.keepsUntitledOnQuit, "V9 the stored key turns the behaviour off")
        check(
            SizePolicy.standard.keptUntitledTotal == 512 * 1024 * 1024 && SizePolicy.standard.keptUntitledCount == 256
                && SizePolicy.standard.automaticRecovery == 256 * 1024 * 1024,
            "V9 the documented bounds for kept untitled text")
    }
    static func main() {
        Checks.run("TabIntegrationCoreChecks") {
            let doc = DocumentID(), reopened = DocumentID()
            let target = DocumentTarget(
                documentID: doc, revision: 7, loadEpoch: 2, byteLength: 20,
                selections: [SessionSelection(anchorByte: 8, caretByte: 3)])
            try target.validate()
            check(target.resolve(in: [doc]) == doc, "T4 target resolves exact open identity")
            check(target.resolve(in: [reopened]) == nil, "T4 reopened path cannot revive old identity")
            check(target.isCurrent(documentID: doc, revision: 7, loadEpoch: 2), "T4 exact revision and load epoch")
            check(!target.isCurrent(documentID: doc, revision: 8, loadEpoch: 2), "T4 edited or undone revision stale")
            check(!target.isCurrent(documentID: doc, revision: 7, loadEpoch: 3), "T4 identical reload epoch stale")
            check(
                !target.isCurrent(documentID: reopened, revision: 7, loadEpoch: 2), "T4 another document never matches")
            var workspace = TabWorkspace()
            let tab = try workspace.open(doc, openDocuments: [doc])
            for layout in LayoutKind.allCases {
                workspace = try workspace.planLayout(layout, openDocuments: [doc]).result
                check(target.resolve(in: [doc]) == doc, "T4 target survives layout \(layout)")
            }
            workspace = try workspace.planLayout(.twoColumns, openDocuments: [doc]).result
            let shared = try workspace.planAdditionalView(tab, to: .second, openDocuments: [doc])
            workspace = shared.result
            _ = try workspace.remove(tab, reviewed: false, openDocuments: [doc])
            check(target.resolve(in: [doc]) == doc, "T4 nonfinal view close retains target")
            _ = try workspace.remove(workspace.groups[1].tabs[0].id, reviewed: true, openDocuments: [doc])
            check(target.resolve(in: []) == nil, "T4 final view close invalidates target")
            try keptUntitledSessionRecords()
            let legacyBytes = try Data(
                contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/Session.texttanksession"))
            let old = try WorkspaceSession.decode(legacyBytes)
            check(old.layoutStatus == .absent && old.layoutState == nil, "T4 old session has absent optional layout")
            check(try old.encoded() == legacyBytes, "T4 old golden bytes unchanged")
            let bytes = try Data(
                contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/SessionLayout.texttanksession"))
            let session = try WorkspaceSession.decode(bytes)
            guard case .valid(let layout) = session.layoutStatus else { throw TabModelError.invalid }
            check(layout.layout == .grid2x2 && layout.focusedGroup == .second, "T4 new golden layout decoded")
            check(
                session.documents.count == 2 && layout.groups.flatMap(\.tabs).count == 3,
                "T4 shared view stores document content once")
            check(try session.encoded() == bytes, "T4 new golden round trip uses production encoder")
            // JSONSerialization's NSString bridge strips a leading FEFF. Keep the exact BOM
            // golden oracle above, and use separate ASCII content for envelope mutations.
            var mutationSession = session
            mutationSession.documents[0].text = "plain\nsnapshot"
            mutationSession.documents[0].selection = SessionSelection(anchorByte: 5, caretByte: 0)
            let mutationBytes = try mutationSession.encoded()
            var raw = try JSONSerialization.jsonObject(with: mutationBytes) as! [String: Any]
            for malformed in ["wrong shape", ["version": 99], NSNull()] as [Any] {
                raw["layoutState"] = malformed
                let result = try WorkspaceSession.decode(JSONSerialization.data(withJSONObject: raw))
                check(result.documents == mutationSession.documents, "T4 bad optional layout never loses content")
                check(
                    malformed is NSNull ? result.layoutStatus == .absent : result.layoutStatus == .invalid,
                    "T4 malformed optional layout classified")
            }
            raw = try JSONSerialization.jsonObject(with: mutationBytes) as! [String: Any]
            var invalidLayout = raw["layoutState"] as! [String: Any]
            invalidLayout["layout"] = "futureLayout"
            raw["layoutState"] = invalidLayout
            check(
                try WorkspaceSession.decode(JSONSerialization.data(withJSONObject: raw)).layoutStatus == .invalid,
                "T4 unknown layout enum is recoverable")
            var bad = session
            bad.layoutState!.groups[0].tabs[0].documentID = DocumentID()
            check(bad.layoutStatus == .invalid, "T4 unknown saved document detected")
            bad = session
            bad.layoutState!.groups[0].tabs.removeLast()
            bad.layoutState!.groups[0].activeTabIndex = 0
            check(bad.layoutStatus == .invalid, "T4 omitted saved document detected")
            bad = session
            bad.layoutState!.groups[0].tabs.reverse()
            check(bad.layoutStatus == .invalid, "T4 pinned prefix violation detected")
            bad = session
            bad.layoutState!.groups[0].tabs.append(bad.layoutState!.groups[0].tabs[0])
            check(bad.layoutStatus == .invalid, "T4 duplicate in same group detected")
            bad = session
            bad.documents[0].selection.caretByte = 1
            rejects("T4 malformed legacy document selection remains fatal") { try bad.validate() }
            for version in [0, 2, 99] {
                var future = session.layoutState!
                future = WorkspaceLayoutState(
                    version: version, layout: future.layout, focusedGroup: future.focusedGroup, groups: future.groups)
                bad = session
                bad.layoutState = future
                check(bad.layoutStatus == .invalid, "T4 valid-shaped unsupported layout version rejected")
            }
            for index in [-1, 2, 999] {
                bad = session
                bad.layoutState!.groups[0].activeTabIndex = index
                check(bad.layoutStatus == .invalid, "T4 out-of-range active index rejected")
            }
            bad = session
            bad.layoutState!.groups[0].activeTabIndex = nil
            check(bad.layoutStatus == .invalid, "T4 nonempty group needs active index")
            bad = session
            bad.layoutState!.groups[0].tabs[0].anchorByte = -1
            check(bad.layoutStatus == .invalid, "T4 negative view offset invalid")
            bad = session
            bad.layoutState!.groups.swapAt(0, 1)
            check(bad.layoutStatus == .invalid, "T4 unordered slots invalid")
            let envelope = try JSONSerialization.jsonObject(with: mutationBytes) as! [String: Any]
            for key in ["schemaVersion", "id", "name", "documents", "savedAt"] {
                var missing = envelope
                missing.removeValue(forKey: key)
                rejects("T4 required legacy envelope field never defaulted: \(key)") {
                    _ = try WorkspaceSession.decode(JSONSerialization.data(withJSONObject: missing))
                }
            }
            rejects("T4 negative target offset") {
                try DocumentTarget(
                    documentID: doc, revision: 7, byteLength: 2,
                    selections: [SessionSelection(anchorByte: -1, caretByte: 0)]
                ).validate()
            }
            let ids = session.documents.map { DocumentID($0.id) }, runtime = [DocumentID(), DocumentID()]
            var before = TabWorkspace()
            _ = try before.open(runtime[0], openDocuments: [runtime[0]])
            _ = try before.open(runtime[1], openDocuments: Set(runtime))
            var threeViews = layout
            threeViews.groups[2].tabs = [threeViews.groups[1].tabs[0]]
            threeViews.groups[2].activeTabIndex = 0
            let plan = try before.planSessionLayout(
                threeViews, documentIDs: Dictionary(uniqueKeysWithValues: zip(ids, runtime)),
                openDocuments: Set(runtime))
            check(
                plan.result.groups.flatMap(\.tabs).filter { $0.documentID == runtime[0] }.count == 3,
                "T4 session plans all shared views against one runtime identity")
            check(
                plan.created.count == 2 && Set(plan.createdSources.values).count == 1,
                "T4 multiple created views have one source without a lossy one-to-one map")
            check(
                plan.result.focusedGroup == .second && plan.result.groups[0].tabs.first?.isPinned == true,
                "T4 session plans focus and pins exactly")
            rejects("T4 alias saved IDs cannot map to one runtime document") {
                _ = try before.planSessionLayout(
                    layout, documentIDs: [ids[0]: runtime[0], ids[1]: runtime[0]], openDocuments: Set(runtime))
            }
            rejects("T4 missing saved document mapping rejected before publication") {
                _ = try before.planSessionLayout(layout, documentIDs: [ids[0]: runtime[0]], openDocuments: Set(runtime))
            }
            Checks.summary { "PASS TabIntegrationCoreChecks: \(Checks.count) assertions" }
        }
    }
}
