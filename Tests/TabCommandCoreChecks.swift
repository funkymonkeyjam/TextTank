import Foundation
@testable import TextTankCore

@main struct TabCommandCoreChecks {
    static func main() {
        Checks.run("TabCommandCoreChecks") {
            let docs = (0..<5).map { _ in DocumentID() }
            let tabs = docs.enumerated().map {
                DocumentTab(id: TabID(), documentID: $0.element, isPinned: $0.offset == 0)
            }
            let model = TabWorkspace(groups: [EditorGroup(slot: .first, tabs: tabs, activeTab: tabs[4].id)])
            var facts = Dictionary(
                uniqueKeysWithValues: docs.map { ($0, TabCloseFact(modified: false, fileBacked: true, missing: false)) }
            )
            facts[docs[1]] = TabCloseFact(modified: true, fileBacked: true, missing: false)
            facts[docs[3]] = TabCloseFact(modified: false, fileBacked: false, missing: false)
            facts[docs[4]] = TabCloseFact(modified: false, fileBacked: true, missing: true)
            for (command, expected) in [
                (TabCommand.closeOthers, [1, 3, 4]), (.closeLeft, [1]), (.closeRight, [3, 4]),
                (.closeGroup, [1, 2, 3, 4]), (.closeSaved, [2]), (.close, [2])
            ] {
                let plan = try TabClosePlan.make(command, target: tabs[2].id, workspace: model, facts: facts)
                check(plan.tabs == expected.map { tabs[$0].id }, "exact inactive-target planner " + command.rawValue)
                check(
                    plan.modifiedDocuments == (expected.contains(1) ? [docs[1]] : []),
                    "modified subset " + command.rawValue)
                check(plan.isCurrent(workspace: model, facts: facts), "fresh plan validates " + command.rawValue)
            }
            let pinned = try TabClosePlan.make(.close, target: tabs[0].id, workspace: model, facts: facts)
            check(pinned.tabs == [tabs[0].id], "single Close includes pinned target")
            check(
                try TabClosePlan.make(.closeLeft, target: tabs[1].id, workspace: model, facts: facts).tabs.isEmpty,
                "only pinned left is disabled")
            check(
                try TabClosePlan.make(.closeRight, target: tabs[4].id, workspace: model, facts: facts).tabs.isEmpty,
                "last target right is disabled")
            var one = TabWorkspace(groups: [EditorGroup(slot: .first, tabs: [tabs[0]], activeTab: tabs[0].id)])
            check(
                try TabClosePlan.make(
                    .closeGroup, target: tabs[0].id, workspace: one, facts: [docs[0]: facts[docs[0]]!]
                ).tabs.isEmpty, "all pinned group is disabled")
            let plan = try TabClosePlan.make(.closeOthers, target: tabs[2].id, workspace: model, facts: facts)
            var changed = facts
            changed[docs[3]] = TabCloseFact(modified: true, fileBacked: false, missing: false)
            check(!plan.isCurrent(workspace: model, facts: changed), "planned clean becoming dirty invalidates")
            var reordered = model
            reordered.groups[0].tabs.swapAt(1, 2)
            check(!plan.isCurrent(workspace: reordered, facts: facts), "reorder invalidates captured plan")
            reordered = model
            reordered.groups[0].tabs.removeLast()
            check(!plan.isCurrent(workspace: reordered, facts: facts), "closed planned target invalidates")
            var focus = model
            focus.groups[0].activeTab = tabs[0].id
            check(plan.isCurrent(workspace: focus, facts: facts), "focus does not retarget captured structural plan")
            rejects("stale clicked identity rejects") {
                _ = try TabClosePlan.make(.closeOthers, target: TabID(), workspace: model, facts: facts)
            }
            let other = DocumentTab(id: TabID(), documentID: docs[1])
            let multi = TabWorkspace(
                layout: .twoColumns,
                groups: [model.groups[0], EditorGroup(slot: .second, tabs: [other], activeTab: other.id)])
            let shared = try TabClosePlan.make(.closeGroup, target: tabs[2].id, workspace: multi, facts: facts)
            check(
                !shared.finalDocuments.contains(docs[1]) && shared.modifiedDocuments.isEmpty,
                "outside surviving view needs no decision")
            let a = DocumentTab(id: TabID(), documentID: docs[1]), b = DocumentTab(id: TabID(), documentID: docs[1])
            let both = TabWorkspace(
                layout: .twoColumns,
                groups: [
                    EditorGroup(slot: .first, tabs: [a], activeTab: a.id),
                    EditorGroup(slot: .second, tabs: [b], activeTab: b.id)
                ])
            let dedup = try TabClosePlan.selected(
                [a.id, b.id], target: a.id, workspace: both, facts: [docs[1]: facts[docs[1]]!])
            check(
                dedup.finalDocuments == [docs[1]] && dedup.modifiedDocuments == [docs[1]],
                "shared final views deduplicate decisions")
            var placed = model
            try placed.place(tabs[4].id, in: .first, index: 0, pinned: false, openDocuments: Set(docs))
            check(
                placed.groups[0].tabs.map(\.id) == [tabs[0].id, tabs[4].id, tabs[1].id, tabs[2].id, tabs[3].id],
                "restore unpinned clamps to pin prefix")
            try placed.place(tabs[2].id, in: .first, index: 999, pinned: true, openDocuments: Set(docs))
            check(placed.groups[0].tabs[1].id == tabs[2].id, "restore pinned clamps to leading region")
            var history = ClosedTabHistory()
            for i in 0..<21 {
                _ = history.push(
                    ClosedTabRecord(
                        url: URL(fileURLWithPath: "/owned/\(i)"), group: .first, index: i, pinned: false, anchor: i,
                        caret: i, firstVisibleLine: i, fingerprint: nil))
            }
            check(
                ClosedTabHistory.capacity == 20 && history.records.count == 20 && history.records.first?.index == 1,
                "history20evicts oldest")
            let last = try requireValue(history.latest, "history newest")
            check(last.index == 20 && history.consume(last.id) && history.latest?.index == 19, "history is LIFO")
            check(
                !history.consume(last.id) && history.records.count == 19, "stale consume does not remove another record"
            )
            check(!history.setFingerprint("old", for: last.id), "late consumed fingerprint is rejected")
            let top = try requireValue(history.latest, "history top")
            check(
                history.setFingerprint("new", for: top.id) && history.latest?.fingerprint == "new",
                "identity guarded fingerprint update")
            let utf8 = Data("a🙂éZ".utf8)
            for (offset, expected) in [(-5, 0), (0, 0), (2, 1), (4, 1), (6, 5), (99, 8)] {
                check(ClosedTabHistory.clampOffset(offset, in: utf8) == expected, "UTF8offset clamp \(offset)")
            }
            one.groups[0].tabs[0].isPinned = false
            check(
                try TabClosePlan.make(
                    .closeOthers, target: tabs[0].id, workspace: one, facts: [docs[0]: facts[docs[0]]!]
                ).tabs.isEmpty, "single tab Other disabled")
        }
    }
}
