import Foundation
@testable import TextTankCore

@main struct TabSelectionCoreChecks {
    static func main() {
        Checks.run("TabSelectionCoreChecks") {
            let docs = (0..<5).map { _ in DocumentID() }
            let tabs = docs.enumerated().map {
                DocumentTab(id: TabID(), documentID: $0.element, isPinned: $0.offset == 0)
            }
            let all = Set(docs)
            let initial = TabWorkspace(groups: [EditorGroup(slot: .first, tabs: tabs, activeTab: tabs[2].id)])
            var m = initial, s = TabSelectionState()
            func selected() -> Set<TabID> { s.selected(in: m, group: .first) }
            check(selected() == [tabs[2].id], "T2 default selection is active")
            try s.apply(tabs[0].id, gesture: .toggle, workspace: &m, openDocuments: all)
            check(
                selected() == [tabs[0].id, tabs[2].id] && m.activeTab?.id == tabs[2].id,
                "T2 Command adds without activation")
            try s.apply(tabs[4].id, gesture: .toggle, workspace: &m, openDocuments: all)
            let captured = try TabTargetCapture(target: tabs[0].id, workspace: m, selection: s)
            check(captured.members(in: m) == [tabs[0].id, tabs[2].id, tabs[4].id], "T2 capture includes selected pin")
            let outside = try TabTargetCapture(target: tabs[1].id, workspace: m, selection: s)
            check(outside.members(in: m) == [tabs[1].id], "T2 outside target is single")
            check(
                outside.keeping(in: m) == [tabs[0].id, tabs[1].id, tabs[2].id, tabs[4].id],
                "T2 outside Close Other preserves selection and target")
            try s.apply(tabs[2].id, gesture: .toggle, workspace: &m, openDocuments: all)
            check(
                selected() == [tabs[0].id, tabs[4].id] && m.activeTab?.id == tabs[4].id,
                "T2 toggling active selects next selected right")
            try s.apply(tabs[4].id, gesture: .toggle, workspace: &m, openDocuments: all)
            check(
                selected() == [tabs[0].id] && m.activeTab?.id == tabs[0].id,
                "T2 toggling last selected active chooses left")
            try s.apply(tabs[0].id, gesture: .toggle, workspace: &m, openDocuments: all)
            check(selected() == [tabs[0].id], "T2 sole active cannot be deselected")
            try s.apply(tabs[3].id, gesture: .range, workspace: &m, openDocuments: all)
            check(
                selected() == Set(tabs.prefix(4).map(\.id)) && m.activeTab?.id == tabs[0].id,
                "T2 Shift uses active anchor without activation")
            try s.apply(tabs[2].id, gesture: .plain, workspace: &m, openDocuments: all)
            check(selected() == [tabs[2].id] && m.activeTab?.id == tabs[2].id, "T2 plain activates and collapses")
            check(
                captured.members(in: m) == [tabs[0].id, tabs[2].id, tabs[4].id], "T2 menu never retargets new selection"
            )
            let before = m
            _ = try m.remove(tabs[4].id, reviewed: true, openDocuments: all)
            s.reconcile(from: before, to: m)
            check(selected() == [tabs[2].id], "T2 unselected disappearance leaves selection")
            check(captured.members(in: m) == [tabs[0].id, tabs[2].id], "T2 capture prunes disappeared member")
            let beforeTargetGone = m
            _ = try m.remove(tabs[0].id, reviewed: true, openDocuments: all.subtracting([docs[4]]))
            check(
                captured.members(in: m) == nil && captured.keeping(in: m) == nil,
                "T2 vanished clicked target invalidates whole capture")
            s.reconcile(from: beforeTargetGone, to: m)
            m = initial
            s = TabSelectionState()
            try s.apply(tabs[4].id, gesture: .toggle, workspace: &m, openDocuments: all)
            let old = m
            _ = try m.remove(tabs[4].id, reviewed: true, openDocuments: all)
            s.reconcile(from: old, to: m)
            check(selected() == [tabs[2].id], "T2 selected disappearance collapses to active")
            let stale = s, stable = m
            rejects("T2 invalid selection target rejects") {
                try s.apply(TabID(), gesture: .plain, workspace: &m, openDocuments: all.subtracting([docs[4]]))
            }
            check(s == stale && m == stable, "T2 selection mutation is atomic")
            let facts = Dictionary(
                uniqueKeysWithValues: docs.map { ($0, TabCloseFact(modified: true, fileBacked: true, missing: false)) })
            let plan = try TabClosePlan.selected(
                [tabs[0].id, tabs[2].id], target: tabs[2].id, workspace: initial, facts: facts)
            check(
                plan.tabs == [tabs[0].id, tabs[2].id] && plan.modifiedDocuments == [docs[0], docs[2]],
                "T2 explicit selected close includes pins and reviews each document")
            let other = try TabClosePlan.make(
                .closeOthers, target: tabs[2].id, workspace: initial, facts: facts, keeping: [tabs[2].id, tabs[4].id])
            check(other.tabs == [tabs[1].id, tabs[3].id], "T2 Close Other keeps every selected and pin")
            rejects("T2 Close Other rejects stale keeper") {
                _ = try TabClosePlan.make(
                    .closeOthers, target: tabs[2].id, workspace: initial, facts: facts, keeping: [TabID()])
            }
            let shared = DocumentTab(id: TabID(), documentID: docs[0])
            let two = TabWorkspace(
                layout: .twoColumns,
                groups: [initial.groups[0], EditorGroup(slot: .second, tabs: [shared], activeTab: shared.id)])
            check(s.selected(in: two, group: .second) == [shared.id], "T2 selection is per group")
            let nonfinal = try TabClosePlan.selected(
                [tabs[0].id, tabs[2].id], target: tabs[2].id, workspace: two, facts: facts)
            check(nonfinal.finalDocuments == [docs[2]], "T2 selected close reviews only final document views")
        }
    }
}
