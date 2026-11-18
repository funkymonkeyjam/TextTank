import Foundation

package enum TabSelectionGesture: Sendable { case plain, toggle, range }

/// Transient view selection. Deliberately absent from session and recovery codecs.
package struct TabSelectionState: Equatable, Sendable {
    private var groups: [GroupSlot: Set<TabID>] = [:]
    package init() {}
    package func selected(in workspace: TabWorkspace, group slot: GroupSlot) -> Set<TabID> {
        guard let group = workspace.groups.first(where: { $0.slot == slot }) else { return [] }
        var result = (groups[slot] ?? []).intersection(group.tabs.map(\.id))
        if let active = group.activeTab { result.insert(active) }
        return result
    }
    package mutating func collapse(in workspace: TabWorkspace, group: GroupSlot? = nil) {
        let slot = group ?? workspace.focusedGroup
        groups[slot] = Set(workspace.groups.first(where: { $0.slot == slot })?.activeTab.map { [$0] } ?? [])
    }
    package mutating func reconcile(from old: TabWorkspace, to new: TabWorkspace) {
        for group in old.groups {
            let before = selected(in: old, group: group.slot)
            let live = Set(new.groups.first(where: { $0.slot == group.slot })?.tabs.map(\.id) ?? [])
            if !before.isSubset(of: live) {
                collapse(in: new, group: group.slot)
            } else {
                groups[group.slot] = before.intersection(live)
            }
        }
        groups = groups.filter { slot, _ in new.groups.contains { $0.slot == slot } }
    }
    package mutating func apply(
        _ id: TabID, gesture: TabSelectionGesture, workspace: inout TabWorkspace,
        openDocuments: Set<DocumentID>
    ) throws {
        try workspace.validate(openDocuments: openDocuments)
        guard let group = workspace.groups.first(where: { $0.tabs.contains { $0.id == id } }),
            let index = group.tabs.firstIndex(where: { $0.id == id }),
            let anchor = group.tabs.firstIndex(where: { $0.id == group.activeTab })
        else { throw TabModelError.invalid }
        var next = workspace, chosen = selected(in: workspace, group: group.slot)
        switch gesture {
        case .plain:
            chosen = [id]
            try next.activate(id, openDocuments: openDocuments)
        case .range:
            chosen = Set(group.tabs[min(index, anchor)...max(index, anchor)].map(\.id))
        case .toggle:
            if chosen.contains(id) {
                if id != group.activeTab {
                    chosen.remove(id)
                } else if chosen.count > 1 {
                    chosen.remove(id)
                    let replacement =
                        group.tabs.dropFirst(index + 1).first { chosen.contains($0.id) }
                        ?? group.tabs.prefix(index).reversed().first { chosen.contains($0.id) }
                    guard let replacement else { throw TabModelError.invalid }
                    try next.activate(replacement.id, openDocuments: openDocuments)
                }
            } else {
                chosen.insert(id)
            }
        }
        try next.validate(openDocuments: openDocuments)
        groups[group.slot] = chosen
        workspace = next
    }
}

/// Captures a menu's identities once. Later selection changes cannot broaden it.
package struct TabTargetCapture: Sendable {
    package let target: TabID
    package let group: GroupSlot
    private let capturedMembers: Set<TabID>
    private let capturedKeeping: Set<TabID>
    package init(target: TabID, workspace: TabWorkspace, selection: TabSelectionState) throws {
        guard let group = workspace.groups.first(where: { $0.tabs.contains { $0.id == target } }) else {
            throw TabModelError.invalid
        }
        self.target = target
        self.group = group.slot
        let selected = selection.selected(in: workspace, group: group.slot)
        capturedMembers = selected.contains(target) ? selected : [target]
        capturedKeeping = selected.count > 1 ? selected.union([target]) : [target]
    }
    private func live(in workspace: TabWorkspace) -> Set<TabID>? {
        guard let current = workspace.groups.first(where: { $0.slot == group }),
            current.tabs.contains(where: { $0.id == target })
        else { return nil }
        return Set(current.tabs.map(\.id))
    }
    package func members(in workspace: TabWorkspace) -> Set<TabID>? {
        live(in: workspace).map { capturedMembers.intersection($0) }
    }
    package func keeping(in workspace: TabWorkspace) -> Set<TabID>? {
        live(in: workspace).map { capturedKeeping.intersection($0) }
    }
}
