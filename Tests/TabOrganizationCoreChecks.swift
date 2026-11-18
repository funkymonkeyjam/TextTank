import Foundation
@testable import TextTankCore

@main struct TabOrganizationCoreChecks {
    static func main() {
        Checks.run("TabOrganizationCoreChecks") {
            let docs = (0..<6).map { _ in DocumentID() }
            let tabs = docs.enumerated().map {
                DocumentTab(id: TabID(), documentID: $0.element, isPinned: $0.offset < 2)
            }
            let all = Set(docs)
            let baseline = TabWorkspace(groups: [EditorGroup(slot: .first, tabs: tabs, activeTab: tabs[5].id)])
            func order(_ m: TabWorkspace) -> [Int] { m.groups[0].tabs.map { docs.firstIndex(of: $0.documentID)! } }
            var m = baseline
            let changed = try m.setPinned([tabs[3].id], in: .first, pinned: true, openDocuments: all)
            check(changed == [tabs[3].id] && order(m) == [0, 1, 3, 2, 4, 5], "T2 pin moves to end of pinned prefix")
            check(
                m.activeTab?.id == tabs[5].id && m.focusedGroup == .first,
                "T2 pin preserves active and focused identity")
            _ = try m.setPinned([tabs[0].id], in: .first, pinned: false, openDocuments: all)
            check(order(m) == [1, 3, 0, 2, 4, 5], "T2 unpin moves to start of ordinary region")
            try m.validate(openDocuments: all)
            check(m.activeTab?.id == tabs[5].id, "T2 unpin preserves active")
            m = baseline
            _ = try m.setPinned([tabs[5].id, tabs[2].id], in: .first, pinned: true, openDocuments: all)
            check(order(m) == [0, 1, 2, 5, 3, 4], "T2 batch pin uses visible order rather than supplied order")
            _ = try m.setPinned([tabs[2].id, tabs[0].id], in: .first, pinned: false, openDocuments: all)
            check(order(m) == [1, 5, 0, 2, 3, 4], "T2 batch unpin retains visible order")
            let unchanged = m
            check(
                try m.setPinned([tabs[0].id], in: .first, pinned: false, openDocuments: all).isEmpty && m == unchanged,
                "T2 repeated pin state changes no ordering")
            m = baseline
            check(
                !m.canMoveTab(tabs[0].id, direction: -1) && m.canMoveTab(tabs[0].id, direction: 1),
                "T2 first pin left edge")
            check(!m.canMoveTab(tabs[1].id, direction: 1), "T2 last pin cannot cross boundary")
            check(!m.canMoveTab(tabs[2].id, direction: -1), "T2 first ordinary cannot cross boundary")
            check(!m.canMoveTab(tabs[5].id, direction: 1), "T2 last ordinary right edge")
            check(
                !m.canMoveTab(TabID(), direction: 1) && !m.canMoveTab(tabs[2].id, direction: Int.min),
                "T2 invalid move is disabled")
            try m.reorderTab(tabs[0].id, to: Int.max, openDocuments: all)
            check(order(m) == [1, 0, 2, 3, 4, 5], "T2 pinned drag clamps to final pin position")
            try m.reorderTab(tabs[5].id, to: Int.min, openDocuments: all)
            check(order(m) == [1, 0, 5, 2, 3, 4], "T2 ordinary drag clamps to first ordinary position")
            check(m.activeTab?.id == tabs[5].id, "T2 reorder active tab preserves active identity")
            try m.reorderTab(tabs[3].id, to: 5, openDocuments: all)
            check(order(m) == [1, 0, 5, 2, 4, 3], "T2 final-index reorder within ordinary region")
            let stable = m
            rejects("T2 stale pin rejects atomically") {
                _ = try m.setPinned([TabID()], in: .first, pinned: true, openDocuments: all)
            }
            check(m == stable, "T2 stale pin publishes no partial change")
            rejects("T2 stale reorder rejects atomically") { try m.reorderTab(TabID(), to: 0, openDocuments: all) }
            check(m == stable, "T2 stale reorder publishes no partial change")
            try m.activate(tabs[4].id, openDocuments: all)
            check(order(m) == order(stable), "T2 activation does not change order")
            let shared = DocumentTab(id: TabID(), documentID: docs[0])
            var two = TabWorkspace(
                layout: .twoColumns,
                groups: [baseline.groups[0], EditorGroup(slot: .second, tabs: [shared], activeTab: shared.id)],
                focusedGroup: .second)
            _ = try two.setPinned([tabs[3].id], in: .first, pinned: true, openDocuments: all)
            check(
                !two.groups[1].tabs[0].isPinned && two.focusedGroup == .second && two.groups[1].activeTab == shared.id,
                "T2 pin belongs to view and does not move group focus")
            try two.reorderTab(tabs[3].id, to: 0, openDocuments: all)
            check(two.focusedGroup == .second, "T2 reorder does not change focused group")
            m = baseline
            let opened = DocumentID()
            let newID = try m.open(opened, openDocuments: all.union([opened]))
            check(
                m.groups[0].tabs.last?.id == newID && m.groups[0].tabs.last?.isPinned == false,
                "T2 ordinary open appends unpinned")
            let facts = Dictionary(
                uniqueKeysWithValues: docs.map { ($0, TabCloseFact(modified: true, fileBacked: true, missing: false)) })
            for cmd in [TabCommand.closeOthers, .closeLeft, .closeRight, .closeGroup, .closeSaved] {
                let p = try TabClosePlan.make(cmd, target: tabs[4].id, workspace: baseline, facts: facts)
                check(
                    !p.tabs.contains(tabs[0].id) && !p.tabs.contains(tabs[1].id),
                    "T2 bulk planner keeps pinned " + cmd.rawValue)
            }
            let explicit = try TabClosePlan.make(.close, target: tabs[0].id, workspace: baseline, facts: facts)
            check(
                explicit.tabs == [tabs[0].id] && explicit.modifiedDocuments == [docs[0]],
                "T2 pinned explicit close keeps review")
            var history = ClosedTabHistory()
            let rec = ClosedTabRecord(
                url: URL(fileURLWithPath: "/owned/pinned.txt"), group: .first, index: 99,
                pinned: true, anchor: 0, caret: 0, firstVisibleLine: 0, fingerprint: nil)
            history.push(rec)
            check(history.latest?.pinned == true, "T2 history retains pinned flag")
            m = baseline
            try m.place(tabs[5].id, in: .first, index: rec.index, pinned: rec.pinned, openDocuments: all)
            check(
                m.groups[0].tabs[2].id == tabs[5].id && m.groups[0].tabs[2].isPinned,
                "T2 pinned reopen index clamps into prefix")
        }
    }
}
