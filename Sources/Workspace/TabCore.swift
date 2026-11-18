import Foundation

struct DocumentID: Hashable, Codable, Sendable { let rawValue: UUID; init(_ value: UUID = UUID()) { rawValue = value } }
struct TabID: Hashable, Codable, Sendable { let rawValue: UUID; init(_ value: UUID = UUID()) { rawValue = value } }
enum GroupSlot: Int, CaseIterable, Codable, Sendable { case first = 1, second, third, fourth }
enum LayoutKind: String, CaseIterable, Codable, Sendable {
    case single, twoColumns, twoRows, grid2x2
    var groupCount: Int { switch self { case .single: return 1; case .twoColumns, .twoRows: return 2; case .grid2x2: return 4 } }
}
struct DocumentTab: Equatable, Sendable {
    let id: TabID
    let documentID: DocumentID
    var isPinned = false
}
struct EditorGroup: Equatable, Sendable {
    let slot: GroupSlot
    var tabs: [DocumentTab] = []
    var activeTab: TabID?
}
enum TabModelError: Error, Equatable { case invalid, closeReviewRequired }
struct TabRemoval: Equatable, Sendable { let documentID: DocumentID; let isFinalView: Bool }

/// Contains identities only. Validation happens on a copy before every mutation is published.
struct TabWorkspace: Equatable, Sendable {
    var layout: LayoutKind = .single
    var groups: [EditorGroup] = [EditorGroup(slot: .first)]
    var focusedGroup: GroupSlot = .first
    var activeTab: DocumentTab? {
        guard let group = groups.first(where: { $0.slot == focusedGroup }) else { return nil }
        return group.tabs.first { $0.id == group.activeTab }
    }
    func validate(openDocuments: Set<DocumentID>) throws {
        guard groups.count == layout.groupCount, groups.map(\.slot) == Array(GroupSlot.allCases.prefix(layout.groupCount)),
            groups.contains(where: { $0.slot == focusedGroup }) else { throw TabModelError.invalid }
        var ids = Set<TabID>(), documents = Set<DocumentID>()
        for group in groups {
            guard (group.tabs.isEmpty && group.activeTab == nil)
                || (!group.tabs.isEmpty && group.tabs.contains(where: { $0.id == group.activeTab })) else { throw TabModelError.invalid }
            var seen = Set<DocumentID>(), unpinned = false
            for tab in group.tabs {
                guard ids.insert(tab.id).inserted, seen.insert(tab.documentID).inserted,
                    openDocuments.contains(tab.documentID), !(unpinned && tab.isPinned) else { throw TabModelError.invalid }
                if !tab.isPinned { unpinned = true }; documents.insert(tab.documentID)
            }
        }
        guard documents == openDocuments else { throw TabModelError.invalid }
    }
    @discardableResult mutating func open(_ document: DocumentID, openDocuments: Set<DocumentID>) throws -> TabID {
        var next = self
        guard let index = next.groups.firstIndex(where: { $0.slot == focusedGroup }) else { throw TabModelError.invalid }
        let id: TabID
        if let existing = next.groups[index].tabs.first(where: { $0.documentID == document }) { id = existing.id }
        else { id = TabID(); next.groups[index].tabs.append(DocumentTab(id: id, documentID: document)) }
        next.groups[index].activeTab = id
        try next.validate(openDocuments: openDocuments); self = next; return id
    }
    mutating func activate(_ tab: TabID, openDocuments: Set<DocumentID>) throws {
        var next = self
        guard let index = next.groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == tab }) }) else { throw TabModelError.invalid }
        next.focusedGroup = next.groups[index].slot; next.groups[index].activeTab = tab
        try next.validate(openDocuments: openDocuments); self = next
    }
    @discardableResult mutating func remove(_ tab: TabID, reviewed: Bool, openDocuments: Set<DocumentID>) throws -> TabRemoval {
        try validate(openDocuments: openDocuments)
        var next = self
        guard let gi = groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == tab }) }),
            let ti = groups[gi].tabs.firstIndex(where: { $0.id == tab }) else { throw TabModelError.invalid }
        let doc = groups[gi].tabs[ti].documentID
        let final = groups.flatMap(\.tabs).filter { $0.documentID == doc }.count == 1
        guard !final || reviewed else { throw TabModelError.closeReviewRequired }
        next.groups[gi].tabs.remove(at: ti)
        if next.groups[gi].activeTab == tab {
            next.groups[gi].activeTab = next.groups[gi].tabs.isEmpty ? nil : next.groups[gi].tabs[min(ti, next.groups[gi].tabs.count - 1)].id
        }
        var remaining = openDocuments; if final { remaining.remove(doc) }
        try next.validate(openDocuments: remaining); self = next
        return TabRemoval(documentID: doc, isFinalView: final)
    }
    mutating func cycle(_ direction: Int, openDocuments: Set<DocumentID>) throws {
        try validate(openDocuments: openDocuments)
        guard let group = groups.first(where: { $0.slot == focusedGroup }), !group.tabs.isEmpty,
            let index = group.tabs.firstIndex(where: { $0.id == group.activeTab }) else { return }
        let count = group.tabs.count, step = direction % count
        try activate(group.tabs[(index + step + count) % count].id, openDocuments: openDocuments)
    }
}

/// Codec only: no session or recovery storage reads or writes are connected to this value.
struct WorkspaceLayoutState: Codable, Equatable, Sendable {
    struct Tab: Codable, Equatable, Sendable {
        var documentID: DocumentID
        var isPinned: Bool
        var anchorByte: Int
        var caretByte: Int
        var firstVisibleLine: Int
    }
    struct Group: Codable, Equatable, Sendable {
        var slot: GroupSlot
        var activeTabIndex: Int?
        var tabs: [Tab]
    }
    let version: Int
    var layout: LayoutKind
    var focusedGroup: GroupSlot
    var groups: [Group]
    func validate() throws {
        guard version == 1, groups.count == layout.groupCount,
            groups.map(\.slot) == Array(GroupSlot.allCases.prefix(layout.groupCount)),
            groups.contains(where: { $0.slot == focusedGroup }) else { throw TabModelError.invalid }
        for group in groups {
            guard (group.tabs.isEmpty && group.activeTabIndex == nil)
                || (group.activeTabIndex.map { group.tabs.indices.contains($0) } == true) else { throw TabModelError.invalid }
            var seen = Set<DocumentID>(), unpinned = false
            for tab in group.tabs {
                guard seen.insert(tab.documentID).inserted, !(unpinned && tab.isPinned),
                    tab.anchorByte >= 0, tab.caretByte >= 0, tab.firstVisibleLine >= 0 else { throw TabModelError.invalid }
                if !tab.isPinned { unpinned = true }
            }
        }
    }
    func encoded() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
    static func decoded(_ data: Data) throws -> Self { let state = try JSONDecoder().decode(Self.self, from: data); try state.validate(); return state }
}
