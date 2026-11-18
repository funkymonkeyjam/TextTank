import Foundation

extension TabWorkspace {
    /// Move only changed views, in current visible order, to the common boundary.
    /// Active/focused identities are deliberately independent of organisation.
    @discardableResult package mutating func setPinned(
        _ ids: Set<TabID>, in slot: GroupSlot, pinned: Bool, openDocuments: Set<DocumentID>
    ) throws -> [TabID] {
        try validate(openDocuments: openDocuments)
        guard let gi = groups.firstIndex(where: { $0.slot == slot }),
            ids.isSubset(of: Set(groups[gi].tabs.map(\.id)))
        else { throw TabModelError.invalid }
        let moving = groups[gi].tabs.filter { ids.contains($0.id) && $0.isPinned != pinned }
        guard !moving.isEmpty else { return [] }
        let changed = Set(moving.map(\.id))
        let remaining = groups[gi].tabs.filter { !changed.contains($0.id) }
        let boundary = remaining.prefix { $0.isPinned }.count
        var next = self
        let placed = moving.map { tab -> DocumentTab in
            var result = tab
            result.isPinned = pinned
            return result
        }
        next.groups[gi].tabs = Array(remaining.prefix(boundary)) + placed + Array(remaining.dropFirst(boundary))
        try next.validate(openDocuments: openDocuments)
        self = next
        return moving.map(\.id)
    }
    package func canMoveTab(_ id: TabID, direction: Int) -> Bool {
        guard direction == -1 || direction == 1,
            let group = groups.first(where: { $0.tabs.contains { $0.id == id } }),
            let index = group.tabs.firstIndex(where: { $0.id == id })
        else { return false }
        let boundary = group.tabs.prefix { $0.isPinned }.count
        let lower = group.tabs[index].isPinned ? 0 : boundary
        let upper = group.tabs[index].isPinned ? boundary - 1 : group.tabs.count - 1
        return direction < 0 ? index > lower : index < upper
    }
    /// `index` is the final visible index. A pointer insertion slot is converted
    /// by the strip before this call; both pointer and keyboard use this mutation.
    package mutating func reorderTab(_ id: TabID, to index: Int, openDocuments: Set<DocumentID>) throws {
        try validate(openDocuments: openDocuments)
        guard let gi = groups.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
            let old = groups[gi].tabs.firstIndex(where: { $0.id == id })
        else { throw TabModelError.invalid }
        let boundary = groups[gi].tabs.prefix { $0.isPinned }.count
        let lower = groups[gi].tabs[old].isPinned ? 0 : boundary
        let upper = groups[gi].tabs[old].isPinned ? boundary - 1 : groups[gi].tabs.count - 1
        let destination = min(upper, max(lower, index))
        guard destination != old else { return }
        var next = self
        let moving = next.groups[gi].tabs.remove(at: old)
        next.groups[gi].tabs.insert(moving, at: destination)
        try next.validate(openDocuments: openDocuments)
        self = next
    }
}
