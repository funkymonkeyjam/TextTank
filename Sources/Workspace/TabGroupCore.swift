import Foundation

/// Pure identity-only publication plan. Runtime stages native views before installing result.
package struct TabGroupChange: Sendable {
    package let result: TabWorkspace
    package let retired: [TabID]
    package let created: [DocumentTab]
    package let createdSources: [TabID: TabID]
    package let resolved: [TabID: TabID]
    /// New slot -> surviving old slot. Absent entries require a new live group token.
    package let groupOrigins: [GroupSlot: GroupSlot]
    private let snapshot: TabWorkspace
    fileprivate init(
        _ before: TabWorkspace, _ after: TabWorkspace, origins: [GroupSlot: GroupSlot], mapping: [TabID: TabID] = [:]
    ) {
        snapshot = before
        result = after
        groupOrigins = origins
        let old = before.groups.flatMap(\.tabs), current = after.groups.flatMap(\.tabs)
        let oldIDs = Set(old.map(\.id)), newIDs = Set(current.map(\.id))
        retired = old.filter { !newIDs.contains($0.id) }.map(\.id)
        created = current.filter { !oldIDs.contains($0.id) }
        createdSources = Dictionary(
            uniqueKeysWithValues: created.compactMap { tab in
                let source =
                    mapping.first(where: { $0.value == tab.id })?.key
                    ?? old.first(where: { $0.documentID == tab.documentID })?.id
                return source.map { (tab.id, $0) }
            })
        var resolved = mapping
        for tab in old where resolved[tab.id] == nil {
            resolved[tab.id] = newIDs.contains(tab.id) ? tab.id : current.first { $0.documentID == tab.documentID }?.id
        }
        self.resolved = resolved
    }
    package func isCurrent(workspace: TabWorkspace) -> Bool { workspace == snapshot }
}

package struct TabGroupExtent: Equatable, Sendable {
    package let width: Double
    package let height: Double
    package init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
    package static let zero = TabGroupExtent(width: 0, height: 0)
}

package enum TabGroupGeometry {
    package static let minimumPane = TabGroupExtent(width: 320, height: 200)
    package static func minimumContent(
        _ layout: LayoutKind, normal: TabGroupExtent = TabGroupExtent(width: 800, height: 500),
        pickerHeight: Double = 36,
        divider: Double = 1
    ) -> TabGroupExtent {
        let columns: Double = layout == .twoColumns || layout == .grid2x2 ? 2 : 1
        let rows: Double = layout == .twoRows || layout == .grid2x2 ? 2 : 1
        return TabGroupExtent(
            width: max(normal.width, columns * minimumPane.width + (columns - 1) * divider),
            height: max(normal.height, rows * minimumPane.height + (rows - 1) * divider + pickerHeight))
    }
    package static func fits(_ required: TabGroupExtent, available: TabGroupExtent) -> Bool {
        [required.width, required.height, available.width, available.height].allSatisfy { $0.isFinite && $0 >= 0 }
            && required.width <= available.width && required.height <= available.height
    }
}

extension TabWorkspace {
    package mutating func focusGroup(_ slot: GroupSlot, openDocuments: Set<DocumentID>) throws {
        try validate(openDocuments: openDocuments)
        guard groups.contains(where: { $0.slot == slot }) else { throw TabModelError.invalid }
        var next = self
        next.focusedGroup = slot
        try next.validate(openDocuments: openDocuments)
        self = next
    }
    private var groupOrigins: [GroupSlot: GroupSlot] {
        Dictionary(uniqueKeysWithValues: groups.map { ($0.slot, $0.slot) })
    }
    private func activeAfterRemoval(_ group: EditorGroup, remaining: [DocumentTab]) -> TabID? {
        if let active = group.activeTab, remaining.contains(where: { $0.id == active }) { return active }
        let index = group.tabs.firstIndex { $0.id == group.activeTab } ?? 0
        let ids = Set(remaining.map(\.id))
        return group.tabs.dropFirst(index).first { ids.contains($0.id) }?.id ?? remaining.last?.id
    }
    private func merged(_ destination: EditorGroup, tabs: [DocumentTab], winner: DocumentTab? = nil) -> EditorGroup {
        var result = destination
        if let winner { result.tabs.removeAll { $0.documentID == winner.documentID && $0.id != winner.id } }
        for tab in tabs {
            if let winner, tab.documentID == winner.documentID && tab.id != winner.id { continue }
            guard !result.tabs.contains(where: { $0.documentID == tab.documentID }) else { continue }
            let index = tab.isPinned ? result.tabs.prefix { $0.isPinned }.count : result.tabs.count
            result.tabs.insert(tab, at: index)
        }
        if !result.tabs.contains(where: { $0.id == result.activeTab }) { result.activeTab = result.tabs.first?.id }
        return result
    }
    package func planLayout(_ layout: LayoutKind, openDocuments: Set<DocumentID>) throws -> TabGroupChange {
        try validate(openDocuments: openDocuments)
        var next = self
        next.layout = layout
        let count = layout.groupCount
        if count >= groups.count {
            for slot in GroupSlot.allCases.prefix(count).dropFirst(groups.count) {
                next.groups.append(EditorGroup(slot: slot))
            }
        } else {
            next.groups = Array(groups.prefix(count))
            let oldFocus = groups.first { $0.slot == focusedGroup }
            let focusedTab = oldFocus?.tabs.first { $0.id == oldFocus?.activeTab }
            let winner = layout == .single ? focusedTab : nil
            // Filter losing copies globally before any removed group's earlier copy can win.
            let incoming = groups.dropFirst(count).flatMap(\.tabs).filter { tab in
                guard let winner else { return true }
                return tab.documentID != winner.documentID || tab.id == winner.id
            }
            next.groups[0] = merged(next.groups[0], tabs: incoming, winner: winner)
            if layout == .single, let winner {
                next.focusedGroup = .first
                next.groups[0].activeTab = winner.id
            } else if !next.groups.contains(where: { $0.slot == focusedGroup }) {
                next.focusedGroup = .first
                if let focusedTab,
                    let resolved = next.groups[0].tabs.first(where: { $0.documentID == focusedTab.documentID })
                {
                    next.groups[0].activeTab = resolved.id
                }
            }
        }
        try next.validate(openDocuments: openDocuments)
        let origins = groupOrigins.filter { slot, _ in next.groups.contains { $0.slot == slot } }
        return TabGroupChange(self, next, origins: origins)
    }
    package func planMove(_ ids: [TabID], target: TabID, to destination: GroupSlot, openDocuments: Set<DocumentID>)
        throws -> TabGroupChange
    {
        try validate(openDocuments: openDocuments)
        let chosen = Set(ids)
        guard !ids.isEmpty, chosen.count == ids.count, chosen.contains(target),
            let si = groups.firstIndex(where: { $0.tabs.contains { $0.id == target } }),
            let di = groups.firstIndex(where: { $0.slot == destination }), si != di,
            chosen.isSubset(of: Set(groups[si].tabs.map(\.id)))
        else { throw TabModelError.invalid }
        var next = self
        let moving = groups[si].tabs.filter { chosen.contains($0.id) }
        next.groups[si].tabs.removeAll { chosen.contains($0.id) }
        next.groups[si].activeTab = activeAfterRemoval(groups[si], remaining: next.groups[si].tabs)
        next.groups[di] = merged(groups[di], tabs: moving)
        var mapping: [TabID: TabID] = [:]
        for tab in moving { mapping[tab.id] = next.groups[di].tabs.first { $0.documentID == tab.documentID }?.id }
        next.groups[di].activeTab = mapping[target]
        next.focusedGroup = destination
        try next.validate(openDocuments: openDocuments)
        return TabGroupChange(self, next, origins: groupOrigins, mapping: mapping)
    }
    package func planAdditionalView(_ source: TabID, to destination: GroupSlot, openDocuments: Set<DocumentID>) throws
        -> TabGroupChange
    {
        try validate(openDocuments: openDocuments)
        guard let si = groups.firstIndex(where: { $0.tabs.contains { $0.id == source } }),
            let original = groups[si].tabs.first(where: { $0.id == source }),
            let di = groups.firstIndex(where: { $0.slot == destination }), si != di
        else { throw TabModelError.invalid }
        var next = self
        let existing = groups[di].tabs.first { $0.documentID == original.documentID }
        let view = existing ?? DocumentTab(id: TabID(), documentID: original.documentID)
        if existing == nil { next.groups[di].tabs.append(view) }
        next.groups[di].activeTab = view.id
        next.focusedGroup = destination
        try next.validate(openDocuments: openDocuments)
        return TabGroupChange(self, next, origins: groupOrigins, mapping: [source: view.id])
    }
    package func planCloseGroup(_ slot: GroupSlot, openDocuments: Set<DocumentID>) throws -> TabGroupChange {
        try validate(openDocuments: openDocuments)
        guard groups.count > 1, let si = groups.firstIndex(where: { $0.slot == slot }),
            !(layout == .grid2x2 && groups[si].tabs.isEmpty),
            let di = groups.firstIndex(where: { $0.slot != slot })
        else { throw TabModelError.invalid }
        let oldActive = groups[si].tabs.first { $0.id == groups[si].activeTab }
        var dest = merged(groups[di], tabs: groups[si].tabs)
        if focusedGroup == slot, let oldActive {
            dest.activeTab = dest.tabs.first { $0.documentID == oldActive.documentID }?.id
        }
        var next = self, origins = groupOrigins
        if groups.count == 2 {
            next.layout = .single
            next.groups = [EditorGroup(slot: .first, tabs: dest.tabs, activeTab: dest.activeTab)]
            next.focusedGroup = .first
            origins = [.first: groups[di].slot]
        } else {
            next.groups[di] = dest
            next.groups[si] = EditorGroup(slot: slot)
            if focusedGroup == slot { next.focusedGroup = groups[di].slot }
        }
        try next.validate(openDocuments: openDocuments)
        return TabGroupChange(self, next, origins: origins)
    }
}

extension TabWorkspace {
    /// Saved document identifiers are mapped to fresh runtime documents before publication.
    /// Several new views can share one existing source; no lossy one-to-one view map is used.
    package func planSessionLayout(
        _ state: WorkspaceLayoutState,
        documentIDs: [DocumentID: DocumentID],
        openDocuments: Set<DocumentID>
    ) throws -> TabGroupChange {
        try validate(openDocuments: openDocuments)
        try state.validate()
        let savedIDs = Set(state.groups.flatMap(\.tabs).map(\.documentID))
        guard savedIDs == Set(documentIDs.keys), Set(documentIDs.values) == openDocuments,
            documentIDs.count == openDocuments.count
        else { throw TabModelError.invalid }
        let previous = groups.flatMap(\.tabs)
        var reused = Set<DocumentID>()
        let restored = try state.groups.map { group -> EditorGroup in
            let tabs = try group.tabs.map { saved -> DocumentTab in
                guard let runtimeID = documentIDs[saved.documentID],
                    let source = previous.first(where: { $0.documentID == runtimeID })
                else { throw TabModelError.invalid }
                let id = reused.insert(runtimeID).inserted ? source.id : TabID()
                return DocumentTab(id: id, documentID: runtimeID, isPinned: saved.isPinned)
            }
            return EditorGroup(slot: group.slot, tabs: tabs, activeTab: group.activeTabIndex.map { tabs[$0].id })
        }
        let result = TabWorkspace(layout: state.layout, groups: restored, focusedGroup: state.focusedGroup)
        try result.validate(openDocuments: openDocuments)
        let origins = Dictionary(
            uniqueKeysWithValues: result.groups.compactMap { group in
                groups.contains(where: { $0.slot == group.slot }) ? (group.slot, group.slot) : nil
            })
        return TabGroupChange(self, result, origins: origins)
    }
}
