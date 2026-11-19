import Foundation
@testable import TextTankCore

@main struct TabIntegrationCoreChecks {
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
            var raw = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            for malformed in ["wrong shape", ["version": 99], NSNull()] as [Any] {
                raw["layoutState"] = malformed
                let result = try WorkspaceSession.decode(JSONSerialization.data(withJSONObject: raw))
                check(result.documents == session.documents, "T4 bad optional layout never loses content")
                check(
                    malformed is NSNull ? result.layoutStatus == .absent : result.layoutStatus == .invalid,
                    "T4 malformed optional layout classified")
            }
            raw = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
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
            let envelope = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
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
