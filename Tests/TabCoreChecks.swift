import Foundation
@testable import TextTankCore

@main struct TabCoreChecks {
    static func main() {
        Checks.run("TabCoreChecks") {
            let a = DocumentID(), b = DocumentID(), c = DocumentID()
            var workspace = TabWorkspace()
            var open = Set<DocumentID>()
            try workspace.validate(openDocuments: open)
            open.insert(a)
            let ta = try workspace.open(a, openDocuments: open)
            open.insert(b)
            let tb = try workspace.open(b, openDocuments: open)
            open.insert(c)
            let tc = try workspace.open(c, openDocuments: open)
            check(workspace.groups[0].tabs.map(\.documentID) == [a, b, c], "new tabs append in visible order")
            check(
                try workspace.open(b, openDocuments: open) == tb && workspace.groups[0].tabs.count == 3,
                "opening existing focuses identity")
            try workspace.cycle(1, openDocuments: open)
            check(workspace.activeTab?.id == tc, "cycle next")
            try workspace.cycle(1, openDocuments: open)
            check(workspace.activeTab?.id == ta, "cycle wraps")
            try workspace.cycle(-1, openDocuments: open)
            check(workspace.activeTab?.id == tc, "cycle backwards wraps")
            let before = workspace
            rejects("final view requires review") { _ = try workspace.remove(tc, reviewed: false, openDocuments: open) }
            check(workspace == before, "rejected remove leaves workspace byte-for-value unchanged")
            rejects("invalid activation rejects") { try workspace.activate(TabID(), openDocuments: open) }
            check(workspace == before, "rejected activation changes nothing")
            let result = try workspace.remove(tc, reviewed: true, openDocuments: open)
            open.remove(c)
            check(result.isFinalView && workspace.activeTab?.id == tb, "active last close chooses left")
            try workspace.activate(ta, openDocuments: open)
            _ = try workspace.remove(ta, reviewed: true, openDocuments: open)
            open.remove(a)
            check(workspace.activeTab?.id == tb, "active first close chooses right")
            var middle = before
            try middle.activate(tb, openDocuments: [a, b, c])
            _ = try middle.remove(tb, reviewed: true, openDocuments: [a, b, c])
            check(middle.activeTab?.id == tc, "active middle chooses right")
            var multi = TabWorkspace(
                layout: .twoColumns,
                groups: [
                    EditorGroup(slot: .first, tabs: [DocumentTab(id: ta, documentID: a)], activeTab: ta),
                    EditorGroup(slot: .second, tabs: [DocumentTab(id: tb, documentID: a)], activeTab: tb)
                ], focusedGroup: .first)
            let nonfinal = try multi.remove(ta, reviewed: false, openDocuments: [a])
            check(
                !nonfinal.isFinalView && multi.groups[1].tabs.count == 1, "nonfinal view removes without close review")
            func invalid(_ mutate: (inout TabWorkspace) -> Void, _ name: String) {
                var value = before
                mutate(&value)
                rejects(name) { try value.validate(openDocuments: [a, b, c]) }
            }
            invalid({ $0.groups[0].activeTab = nil }, "I5 active required")
            invalid({ $0.groups[0].tabs[1].isPinned = true }, "I4 pinned prefix")
            invalid({ $0.groups.append($0.groups[0]) }, "I6 group count")
            invalid({ $0.focusedGroup = .fourth }, "I6 focused slot")
            invalid({ $0.groups[0].tabs.append($0.groups[0].tabs[0]) }, "I2/I7 duplicate identity")
            rejects("I7 missing open document") { try before.validate(openDocuments: [a, b]) }
            for kind in LayoutKind.allCases {
                let state = WorkspaceLayoutState(
                    version: 1, layout: kind, focusedGroup: .first,
                    groups: Array(GroupSlot.allCases.prefix(kind.groupCount)).map { slot in
                        WorkspaceLayoutState.Group(
                            slot: slot, activeTabIndex: 0,
                            tabs: [
                                .init(documentID: a, isPinned: true, anchorByte: 1, caretByte: 7, firstVisibleLine: 2)
                            ])
                    })
                let bytes = try state.encoded()
                check(try WorkspaceLayoutState.decoded(bytes) == state, "layout round trip \(kind)")
                var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                json.removeValue(forKey: "version")
                rejects("missing version rejects \(kind)") {
                    _ = try WorkspaceLayoutState.decoded(JSONSerialization.data(withJSONObject: json))
                }
                json["version"] = 2
                rejects("unknown version rejects \(kind)") {
                    _ = try WorkspaceLayoutState.decoded(JSONSerialization.data(withJSONObject: json))
                }
                func bad(_ name: String, _ change: (inout WorkspaceLayoutState) -> Void) {
                    var v = state
                    change(&v)
                    rejects(name) { _ = try v.encoded() }
                }
                // V4: a pane's own zoom is optional, bounded and absent at the default.
                let plain = String(decoding: bytes, as: UTF8.self)
                check(!plain.contains("oom"), "a tab at the default zoom is written without a zoom field \(kind)")
                check(
                    try WorkspaceLayoutState.decoded(bytes).groups[0].tabs[0].zoom == nil,
                    "a record without a zoom reads as the default zoom \(kind)")
                for level in [-10, -1, 0, 7, 60] {
                    var zoomed = state
                    zoomed.groups[0].tabs[0].zoom = level
                    zoomed.groups[0].tabs[0].split = .init(
                        otherAnchorByte: 0, otherCaretByte: 0, otherFirstVisibleLine: 0, otherHorizontalOffset: 0,
                        activeHorizontalOffset: 0, secondaryActive: false, primaryFraction: 0.5)
                    zoomed.groups[0].tabs[0].split?.otherZoom = 50 - level
                    check(
                        try WorkspaceLayoutState.decoded(zoomed.encoded()) == zoomed,
                        "layout round trip keeps zoom \(level) and the other pane's \(kind)")
                }
                bad("zoom above 60") { $0.groups[0].tabs[0].zoom = 61 }
                bad("zoom below -10") { $0.groups[0].tabs[0].zoom = -11 }
                bad("other pane zoom out of range") {
                    $0.groups[0].tabs[0].split = .init(
                        otherAnchorByte: 0, otherCaretByte: 0, otherFirstVisibleLine: 0, otherHorizontalOffset: 0,
                        activeHorizontalOffset: 0, secondaryActive: false, primaryFraction: 0.5)
                    $0.groups[0].tabs[0].split?.otherZoom = 61
                }
                bad("negative anchor") { $0.groups[0].tabs[0].anchorByte = -1 }
                bad("negative caret") { $0.groups[0].tabs[0].caretByte = -1 }
                bad("negative line") { $0.groups[0].tabs[0].firstVisibleLine = -1 }
                bad("invalid active") { $0.groups[0].activeTabIndex = 1 }
                bad("missing active") { $0.groups[0].activeTabIndex = nil }
                bad("duplicate document") { $0.groups[0].tabs.append($0.groups[0].tabs[0]) }
                bad("broken pin prefix") { v in
                    var t = v.groups[0].tabs[0]
                    t.documentID = b
                    t.isPinned = false
                    v.groups[0].tabs.insert(t, at: 0)
                }
                bad("invalid focused group") {
                    $0.focusedGroup = .fourth
                    $0.groups.removeLast()
                }
                bad("wrong group count") { $0.groups.append($0.groups[0]) }
                if kind.groupCount > 1 { bad("duplicate slot") { $0.groups[1].slot = .first } }
            }
            // V4: the golden session was written before a tab could record its zoom.
            let golden = try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: TestPaths.fixtures.appendingPathComponent(
                        "persistence/SessionLayout.texttanksession")))
            let goldenLayout = try WorkspaceLayoutState.decoded(
                JSONSerialization.data(withJSONObject: (golden as? [String: Any])?["layoutState"] ?? [:]))
            check(
                goldenLayout.groups.flatMap(\.tabs).count == 3
                    && goldenLayout.groups.flatMap(\.tabs).allSatisfy { $0.zoom == nil && $0.split == nil },
                "the golden session layout decodes unchanged, every tab at the default zoom")
            _ = try workspace.remove(tb, reviewed: true, openDocuments: open)
            try workspace.validate(openDocuments: [])
            check(workspace.activeTab == nil, "last close keeps empty workspace")
        }
    }
}
