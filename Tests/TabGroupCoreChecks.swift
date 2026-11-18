import Foundation
@testable import TextTankCore

@main struct TabGroupCoreChecks {
    static func main() {
        Checks.run("TabGroupCoreChecks") {
            let docs = (0..<8).map { _ in DocumentID() }
            let a1 = DocumentTab(id: TabID(), documentID: docs[0], isPinned: true)
            let b1 = DocumentTab(id: TabID(), documentID: docs[1])
            let c2 = DocumentTab(id: TabID(), documentID: docs[2], isPinned: true)
            let d2 = DocumentTab(id: TabID(), documentID: docs[3])
            let a2 = DocumentTab(id: TabID(), documentID: docs[0])
            let e3 = DocumentTab(id: TabID(), documentID: docs[4], isPinned: true)
            let f3 = DocumentTab(id: TabID(), documentID: docs[5])
            let g4 = DocumentTab(id: TabID(), documentID: docs[6], isPinned: true)
            let h4 = DocumentTab(id: TabID(), documentID: docs[7])
            let b4 = DocumentTab(id: TabID(), documentID: docs[1])
            let fixtures: [(LayoutKind, [EditorGroup], GroupSlot)] = [
                (.single, [EditorGroup(slot: .first, tabs: [a1, b1], activeTab: b1.id)], .first),
                (
                    .twoColumns,
                    [
                        EditorGroup(slot: .first, tabs: [a1, b1], activeTab: b1.id),
                        EditorGroup(slot: .second, tabs: [c2, d2, a2], activeTab: a2.id)
                    ], .second
                ),
                (
                    .twoRows,
                    [
                        EditorGroup(slot: .first, tabs: [a1, b1], activeTab: b1.id),
                        EditorGroup(slot: .second, tabs: [c2, d2, a2], activeTab: a2.id)
                    ], .second
                ),
                (
                    .grid2x2,
                    [
                        EditorGroup(slot: .first, tabs: [a1, b1], activeTab: b1.id),
                        EditorGroup(slot: .second, tabs: [c2, d2, a2], activeTab: a2.id),
                        EditorGroup(slot: .third, tabs: [e3, f3], activeTab: f3.id),
                        EditorGroup(slot: .fourth, tabs: [g4, h4, b4], activeTab: b4.id)
                    ], .fourth
                )
            ]
            for (kind, groups, focus) in fixtures {
                let m = TabWorkspace(layout: kind, groups: groups, focusedGroup: focus)
                let open = Set(groups.flatMap(\.tabs).map(\.documentID))
                for destination in LayoutKind.allCases {
                    let plan = try m.planLayout(destination, openDocuments: open), next = plan.result
                    try next.validate(openDocuments: open)
                    check(
                        next.layout == destination && next.groups.count == destination.groupCount,
                        "T3 layout count \(kind) to \(destination)")
                    if destination.groupCount >= kind.groupCount {
                        check(
                            Array(next.groups.prefix(groups.count)) == groups && next.focusedGroup == focus,
                            "T3 expansion/orientation retains exact group state")
                        check(plan.retired.isEmpty, "T3 expansion retires no tab")
                    } else if destination == .single {
                        let expected = kind == .grid2x2 ? [a1, c2, e3, g4, d2, f3, h4, b4] : [c2, b1, d2, a2]
                        check(next.groups[0].tabs == expected, "T3 literal Single retention/pin/order \(kind)")
                        check(
                            next.activeTab?.id == (kind == .grid2x2 ? b4.id : a2.id),
                            "T3 exact focused view wins Single")
                    } else {
                        check(
                            next.groups[0].tabs == [a1, e3, g4, b1, f3, h4] && next.groups[1] == groups[1],
                            "T3 literal Grid to two retention/pin/order")
                        check(
                            next.focusedGroup == .first && next.activeTab?.id == b1.id,
                            "T3 removed focus resolves destination duplicate")
                    }
                    check(plan.isCurrent(workspace: m), "T3 plan captures exact starting workspace")
                }
            }
            var grid = TabWorkspace(layout: .grid2x2, groups: fixtures[3].1, focusedGroup: .fourth)
            let all = Set(docs)
            grid.groups[0].activeTab = a1.id
            check(
                try grid.planLayout(.twoColumns, openDocuments: all).result.activeTab?.id == b1.id,
                "T3 inactive destination duplicate becomes active after removed focus")
            grid.focusedGroup = .third
            check(
                try grid.planLayout(.twoRows, openDocuments: all).result.activeTab?.id == f3.id,
                "T3 unique removed active transfers and focuses")
            grid.groups[3] = EditorGroup(slot: .fourth)
            grid.focusedGroup = .fourth
            let partial = Set(grid.groups.flatMap(\.tabs).map(\.documentID))
            check(
                try grid.planLayout(.twoColumns, openDocuments: partial).result.activeTab?.id == a1.id,
                "T3 removed empty focus keeps destination active")
            let aa = (0..<4).map { DocumentTab(id: TabID(), documentID: docs[0], isPinned: $0 % 2 == 0) }
            let shared = TabWorkspace(
                layout: .grid2x2,
                groups: GroupSlot.allCases.enumerated().map {
                    EditorGroup(slot: $0.element, tabs: [aa[$0.offset]], activeTab: aa[$0.offset].id)
                }, focusedGroup: .fourth)
            let winner = try shared.planLayout(.single, openDocuments: [docs[0]])
            check(
                winner.result.groups[0].tabs == [aa[3]] && Set(winner.retired) == Set(aa.prefix(3).map(\.id)),
                "T3 global focused winner excludes every earlier duplicate")
            let m = TabWorkspace(layout: .twoColumns, groups: fixtures[1].1, focusedGroup: .first)
            let opened = Set(m.groups.flatMap(\.tabs).map(\.documentID))
            let move = try m.planMove([a1.id, b1.id], target: b1.id, to: .second, openDocuments: opened)
            check(
                move.result.groups[0].tabs.isEmpty && move.result.groups[1].tabs == [c2, d2, a2, b1],
                "T3 batch move appends unique ordinary and retains destination duplicate")
            check(
                move.resolved[a1.id] == a2.id && move.retired == [a1.id] && move.result.activeTab?.id == b1.id,
                "T3 move duplicate retires source and focuses resolved clicked target")
            check(
                move.result.layout == m.layout && move.result.focusedGroup == .second,
                "T3 last-source move keeps empty group/layout")
            let pinMove = try m.planMove([a1.id], target: a1.id, to: .second, openDocuments: opened)
            check(
                pinMove.result.activeTab?.id == a2.id && pinMove.result.groups[1].tabs == m.groups[1].tabs,
                "T3 duplicate move keeps destination pin/index")
            let add = try m.planAdditionalView(b1.id, to: .second, openDocuments: opened)
            let added = try requireValue(add.created.first, "T3 additional view created")
            check(
                added.documentID == b1.documentID && !added.isPinned && added.id != b1.id,
                "T3 additional view distinct unpinned identity sharing document")
            check(
                add.result.groups[1].tabs.last == added && add.result.activeTab?.id == added.id,
                "T3 additional view ordinary append and focus")
            let existing = try m.planAdditionalView(a1.id, to: .second, openDocuments: opened)
            check(
                existing.created.isEmpty && existing.result.activeTab?.id == a2.id,
                "T3 existing destination focus adds no tab")
            rejects("T3 stale batch is atomic") {
                _ = try m.planMove([a1.id, TabID()], target: a1.id, to: .second, openDocuments: opened)
            }
            rejects("T3 same-group move invalid") {
                _ = try m.planMove([a1.id], target: a1.id, to: .first, openDocuments: opened)
            }
            for slot in [GroupSlot.first, .second] {
                let closed = try m.planCloseGroup(slot, openDocuments: opened)
                check(
                    closed.result.layout == .single && closed.result.groups[0].slot == .first,
                    "T3 two-pane Close Group normalizes survivor")
                check(Set(closed.result.groups[0].tabs.map(\.documentID)) == opened, "T3 close group loses no document")
                check(
                    closed.groupOrigins[.first] == (slot == .first ? .second : .first),
                    "T3 surviving runtime group origin retained")
            }
            let closedGrid = try shared.planCloseGroup(.fourth, openDocuments: [docs[0]])
            check(
                closedGrid.result.layout == .grid2x2 && closedGrid.result.groups[3].tabs.isEmpty
                    && closedGrid.result.focusedGroup == .first,
                "T3 confirmed Grid close empties pane and focuses destination")
            check(closedGrid.result.activeTab?.id == aa[0].id, "T3 Grid close resolves duplicate active")
            var focused = m
            try focused.focusGroup(.second, openDocuments: opened)
            check(
                focused.activeTab?.id == a2.id && focused.groups[0].activeTab == b1.id,
                "T3 focus preserves other group active")
            let empty = TabWorkspace(layout: .twoColumns, groups: [m.groups[0], EditorGroup(slot: .second)])
            var emptyFocus = empty
            try emptyFocus.focusGroup(.second, openDocuments: [docs[0], docs[1]])
            check(
                emptyFocus.activeTab == nil && emptyFocus.focusedGroup == .second,
                "T3 empty focused group is valid nil target")
            check(
                TabGroupGeometry.minimumContent(.grid2x2, normal: .zero, pickerHeight: 36, divider: 1)
                    == CGSize(width: 641, height: 437), "T3 pure Grid minimum includes chrome exactly once")
            check(
                TabGroupGeometry.minimumContent(.single) == CGSize(width: 800, height: 500),
                "T3 normal Single minimum preserved")
            check(
                !TabGroupGeometry.fits(CGSize(width: 800, height: 500), available: CGSize(width: 799, height: 500)),
                "T3 screen refusal compares exact required content")
            check(
                !TabGroupGeometry.fits(
                    CGSize(width: 800, height: 500), available: CGSize(width: Double.nan, height: 500)),
                "T3 nonfinite screen input refuses")
        }
    }
}
