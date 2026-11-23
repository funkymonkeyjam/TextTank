import Foundation

package struct DocumentID: Hashable, Codable, Sendable {
    package let rawValue: UUID
    package init(_ value: UUID = UUID()) { rawValue = value }
}
package struct TabID: Hashable, Codable, Sendable {
    package let rawValue: UUID
    package init(_ value: UUID = UUID()) { rawValue = value }
}
package enum GroupSlot: Int, CaseIterable, Codable, Sendable { case first = 1, second, third, fourth }
package enum LayoutKind: String, CaseIterable, Codable, Sendable {
    case single, twoColumns, twoRows, grid2x2
    package var groupCount: Int {
        switch self {
        case .single: return 1
        case .twoColumns, .twoRows: return 2
        case .grid2x2: return 4
        }
    }
}
package struct DocumentTab: Equatable, Sendable {
    package let id: TabID
    package let documentID: DocumentID
    package var isPinned = false
}
package struct EditorGroup: Equatable, Sendable {
    package init(slot: GroupSlot, tabs: [DocumentTab] = [], activeTab: TabID? = nil) {
        self.slot = slot
        self.tabs = tabs
        self.activeTab = activeTab
    }
    package let slot: GroupSlot
    package var tabs: [DocumentTab] = []
    package var activeTab: TabID?
}
package enum TabModelError: Error, Equatable { case invalid, closeReviewRequired }
package struct TabRemoval: Equatable, Sendable {
    let documentID: DocumentID
    let isFinalView: Bool
}

/// Contains identities only. Validation happens on a copy before every mutation is published.
package struct TabWorkspace: Equatable, Sendable {
    package init(
        layout: LayoutKind = .single, groups: [EditorGroup] = [EditorGroup(slot: .first)],
        focusedGroup: GroupSlot = .first
    ) {
        self.layout = layout
        self.groups = groups
        self.focusedGroup = focusedGroup
    }
    package var layout: LayoutKind = .single
    package var groups: [EditorGroup] = [EditorGroup(slot: .first)]
    package var focusedGroup: GroupSlot = .first
    package var activeTab: DocumentTab? {
        guard let group = groups.first(where: { $0.slot == focusedGroup }) else { return nil }
        return group.tabs.first { $0.id == group.activeTab }
    }
    package func validate(openDocuments: Set<DocumentID>) throws {
        guard groups.count == layout.groupCount,
            groups.map(\.slot) == Array(GroupSlot.allCases.prefix(layout.groupCount)),
            groups.contains(where: { $0.slot == focusedGroup })
        else { throw TabModelError.invalid }
        var ids = Set<TabID>(), documents = Set<DocumentID>()
        for group in groups {
            guard
                (group.tabs.isEmpty && group.activeTab == nil)
                    || (!group.tabs.isEmpty && group.tabs.contains(where: { $0.id == group.activeTab }))
            else { throw TabModelError.invalid }
            var seen = Set<DocumentID>(), unpinned = false
            for tab in group.tabs {
                guard ids.insert(tab.id).inserted, seen.insert(tab.documentID).inserted,
                    openDocuments.contains(tab.documentID), !(unpinned && tab.isPinned)
                else { throw TabModelError.invalid }
                if !tab.isPinned { unpinned = true }
                documents.insert(tab.documentID)
            }
        }
        guard documents == openDocuments else { throw TabModelError.invalid }
    }
    @discardableResult package mutating func open(_ document: DocumentID, openDocuments: Set<DocumentID>) throws
        -> TabID
    {
        var next = self
        guard let index = next.groups.firstIndex(where: { $0.slot == focusedGroup }) else {
            throw TabModelError.invalid
        }
        let id: TabID
        if let existing = next.groups[index].tabs.first(where: { $0.documentID == document }) {
            id = existing.id
        } else {
            id = TabID()
            next.groups[index].tabs.append(DocumentTab(id: id, documentID: document))
        }
        next.groups[index].activeTab = id
        try next.validate(openDocuments: openDocuments)
        self = next
        return id
    }
    package mutating func activate(_ tab: TabID, openDocuments: Set<DocumentID>) throws {
        var next = self
        guard let index = next.groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == tab }) }) else {
            throw TabModelError.invalid
        }
        next.focusedGroup = next.groups[index].slot
        next.groups[index].activeTab = tab
        try next.validate(openDocuments: openDocuments)
        self = next
    }
    @discardableResult package mutating func remove(_ tab: TabID, reviewed: Bool, openDocuments: Set<DocumentID>) throws
        -> TabRemoval
    {
        try validate(openDocuments: openDocuments)
        var next = self
        guard let gi = groups.firstIndex(where: { $0.tabs.contains(where: { $0.id == tab }) }),
            let ti = groups[gi].tabs.firstIndex(where: { $0.id == tab })
        else { throw TabModelError.invalid }
        let doc = groups[gi].tabs[ti].documentID
        let final = groups.flatMap(\.tabs).filter { $0.documentID == doc }.count == 1
        guard !final || reviewed else { throw TabModelError.closeReviewRequired }
        next.groups[gi].tabs.remove(at: ti)
        if next.groups[gi].activeTab == tab {
            next.groups[gi].activeTab =
                next.groups[gi].tabs.isEmpty ? nil : next.groups[gi].tabs[min(ti, next.groups[gi].tabs.count - 1)].id
        }
        var remaining = openDocuments
        if final { remaining.remove(doc) }
        try next.validate(openDocuments: remaining)
        self = next
        return TabRemoval(documentID: doc, isFinalView: final)
    }
    package mutating func cycle(_ direction: Int, openDocuments: Set<DocumentID>) throws {
        try validate(openDocuments: openDocuments)
        guard let group = groups.first(where: { $0.slot == focusedGroup }), !group.tabs.isEmpty,
            let index = group.tabs.firstIndex(where: { $0.id == group.activeTab })
        else { return }
        let count = group.tabs.count, step = direction % count
        try activate(group.tabs[(index + step + count) % count].id, openDocuments: openDocuments)
    }
}

/// What one tab shows of its document. `source` is the editable text and the default; `preview`
/// is the read-only rendered view alone; `both` shows them side by side. The raw values are part
/// of the version-1 session format (docs/tab-model.md).
package enum DocumentViewMode: String, Codable, Sendable, CaseIterable {
    case source, preview, both
}

/// Presentation metadata shared by explicit and automatic sessions; contains no document bytes.
package struct WorkspaceLayoutState: Codable, Equatable, Sendable {
    /// The tab's existing fields still describe its active pane for earlier v1 readers.
    /// Clone creates a vertical divider. The other pane shares the same document.
    package enum PaneWrapping: Codable, Equatable, Sendable {
        case unwrapped
        case wrapped(documentLine: Int, subline: Int)

        var valid: Bool {
            if case let .wrapped(line, subline) = self { return line >= 0 && subline >= 0 }
            return true
        }
    }
    package struct Split: Codable, Equatable, Sendable {
        package var activeWrapping: PaneWrapping?
        package var otherWrapping: PaneWrapping?
        package var otherAnchorByte: Int
        package var otherCaretByte: Int
        package var otherFirstVisibleLine: Int
        package var otherHorizontalOffset: Int
        package var activeHorizontalOffset: Int
        package var secondaryActive: Bool
        package var primaryFraction: Double

        package init(
            otherAnchorByte: Int, otherCaretByte: Int, otherFirstVisibleLine: Int,
            otherHorizontalOffset: Int, activeHorizontalOffset: Int, secondaryActive: Bool,
            primaryFraction: Double
        ) {
            self.otherAnchorByte = otherAnchorByte
            self.otherCaretByte = otherCaretByte
            self.otherFirstVisibleLine = otherFirstVisibleLine
            self.otherHorizontalOffset = otherHorizontalOffset
            self.activeHorizontalOffset = activeHorizontalOffset
            self.secondaryActive = secondaryActive
            self.primaryFraction = primaryFraction
        }
    }
    package struct Tab: Codable, Equatable, Sendable {
        package var documentID: DocumentID
        package var isPinned: Bool
        package var anchorByte: Int
        package var caretByte: Int
        package var firstVisibleLine: Int
        package var split: Split?
        /// Which of Source, Preview or Both the tab shows. Absent in files written before the
        /// field existed and for a tab that shows Source, so those files are unchanged.
        package var viewMode: DocumentViewMode?
        /// The share of the tab's width given to the source while the tab shows Both, from 0 to 1.
        package var previewSourceFraction: Double?
        package init(documentID: DocumentID, isPinned: Bool, anchorByte: Int, caretByte: Int, firstVisibleLine: Int) {
            self.documentID = documentID
            self.isPinned = isPinned
            self.anchorByte = anchorByte
            self.caretByte = caretByte
            self.firstVisibleLine = firstVisibleLine
        }
    }
    package struct Group: Codable, Equatable, Sendable {
        package var slot: GroupSlot
        package var activeTabIndex: Int?
        package var tabs: [Tab]
        package init(slot: GroupSlot, activeTabIndex: Int?, tabs: [Tab]) {
            self.slot = slot
            self.activeTabIndex = activeTabIndex
            self.tabs = tabs
        }
    }
    package let version: Int
    package var layout: LayoutKind
    package var focusedGroup: GroupSlot
    package var groups: [Group]
    package init(version: Int = 1, layout: LayoutKind, focusedGroup: GroupSlot, groups: [Group]) {
        self.version = version
        self.layout = layout
        self.focusedGroup = focusedGroup
        self.groups = groups
    }
    package func validate() throws {
        guard version == 1, groups.count == layout.groupCount,
            groups.map(\.slot) == Array(GroupSlot.allCases.prefix(layout.groupCount)),
            groups.contains(where: { $0.slot == focusedGroup })
        else { throw TabModelError.invalid }
        for group in groups {
            guard
                (group.tabs.isEmpty && group.activeTabIndex == nil)
                    || (group.activeTabIndex.map { group.tabs.indices.contains($0) } == true)
            else { throw TabModelError.invalid }
            var seen = Set<DocumentID>(), unpinned = false
            for tab in group.tabs {
                guard seen.insert(tab.documentID).inserted, !(unpinned && tab.isPinned),
                    tab.anchorByte >= 0, tab.caretByte >= 0, tab.firstVisibleLine >= 0
                else { throw TabModelError.invalid }
                if let split = tab.split {
                    guard split.otherAnchorByte >= 0, split.otherCaretByte >= 0, split.otherFirstVisibleLine >= 0,
                        split.otherHorizontalOffset >= 0, split.activeHorizontalOffset >= 0,
                        split.activeWrapping?.valid != false, split.otherWrapping?.valid != false,
                        (0...1).contains(split.primaryFraction)
                    else { throw TabModelError.invalid }
                }
                if let fraction = tab.previewSourceFraction {
                    guard (0...1).contains(fraction) else { throw TabModelError.invalid }
                }
                if !tab.isPinned { unpinned = true }
            }
        }
    }
    package func encoded() throws -> Data {
        try validate()
        return try JSONEncoder().encode(self)
    }
    static func decoded(_ data: Data) throws -> Self {
        let state = try JSONDecoder().decode(Self.self, from: data)
        try state.validate()
        return state
    }
}
