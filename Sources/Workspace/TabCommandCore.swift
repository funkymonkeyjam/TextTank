import Foundation

package enum TabCommand: String, CaseIterable, Sendable {
    case newToRight, reopen, close, closeOthers, closeLeft, closeRight, closeGroup, closeSaved, pin, moveLeft,
        moveRight, reveal, copyPath
    package var title: String {
        switch self {
        case .newToRight: return "New Tab to Right"
        case .reopen: return "Reopen Closed Tab"
        case .close: return "Close Tab"
        case .closeOthers: return "Close Other Tabs"
        case .closeLeft: return "Close Tabs to the Left"
        case .closeRight: return "Close Tabs to the Right"
        case .closeGroup: return "Close All in Group"
        case .closeSaved: return "Close Saved Tabs"
        case .pin: return "Pin Tab"
        case .moveLeft: return "Move Tab Left"
        case .moveRight: return "Move Tab Right"
        case .reveal: return "Reveal in Finder"
        case .copyPath: return "Copy File Path"
        }
    }
    package var isBulkClose: Bool { [.closeOthers, .closeLeft, .closeRight, .closeGroup, .closeSaved].contains(self) }
}
package struct TabCloseFact: Equatable, Sendable {
    package let modified: Bool
    package let fileBacked: Bool
    package let missing: Bool
    package init(modified: Bool, fileBacked: Bool, missing: Bool) {
        self.modified = modified
        self.fileBacked = fileBacked
        self.missing = missing
    }
}
package struct TabClosePlan: Sendable {
    package let command: TabCommand
    package let target: TabID
    package let group: GroupSlot
    package let tabs: [TabID]
    package let finalDocuments: [DocumentID]
    package let modifiedDocuments: [DocumentID]
    private let snapshot: TabWorkspace
    private let facts: [DocumentID: TabCloseFact]
    static package func make(
        _ command: TabCommand, target: TabID, workspace: TabWorkspace,
        facts: [DocumentID: TabCloseFact]
    ) throws -> Self {
        try workspace.validate(openDocuments: Set(facts.keys))
        guard let group = workspace.groups.first(where: { $0.tabs.contains { $0.id == target } }),
            let index = group.tabs.firstIndex(where: { $0.id == target })
        else { throw TabModelError.invalid }
        let selected = group.tabs.enumerated().filter { i, tab in
            if command == .close { return tab.id == target }
            guard !tab.isPinned else { return false }
            switch command {
            case .closeOthers: return tab.id != target
            case .closeLeft: return i < index
            case .closeRight: return i > index
            case .closeGroup: return true
            case .closeSaved:
                guard let fact = facts[tab.documentID] else { return false }
                return !fact.modified && fact.fileBacked && !fact.missing
            default: return false
            }
        }.map { $0.element.id }
        return try selectedPlan(selected, command: command, target: target, workspace: workspace, facts: facts)
    }
    static package func selected(
        _ tabs: [TabID], target: TabID, workspace: TabWorkspace,
        facts: [DocumentID: TabCloseFact]
    ) throws -> Self {
        try selectedPlan(tabs, command: .closeGroup, target: target, workspace: workspace, facts: facts)
    }
    private static func selectedPlan(
        _ selected: [TabID], command: TabCommand, target: TabID,
        workspace: TabWorkspace, facts: [DocumentID: TabCloseFact]
    ) throws -> Self {
        try workspace.validate(openDocuments: Set(facts.keys))
        let all = workspace.groups.flatMap(\.tabs), chosen = Set(selected)
        guard Set(all.map(\.id)).isSuperset(of: chosen), chosen.count == selected.count,
            let group = workspace.groups.first(where: { $0.tabs.contains { $0.id == target } })
        else { throw TabModelError.invalid }
        let ordered = all.filter { chosen.contains($0.id) }
        var seen = Set<DocumentID>()
        let final = ordered.compactMap { tab -> DocumentID? in
            guard seen.insert(tab.documentID).inserted,
                all.filter({ $0.documentID == tab.documentID }).allSatisfy({ chosen.contains($0.id) })
            else { return nil }
            return tab.documentID
        }
        return Self(
            command: command, target: target, group: group.slot, tabs: ordered.map(\.id),
            finalDocuments: final, modifiedDocuments: final.filter { facts[$0]?.modified == true }, snapshot: workspace,
            facts: facts)
    }
    package func isCurrent(workspace: TabWorkspace, facts current: [DocumentID: TabCloseFact]) -> Bool {
        guard (try? workspace.validate(openDocuments: Set(current.keys))) != nil,
            workspace.layout == snapshot.layout, workspace.groups.count == snapshot.groups.count,
            zip(workspace.groups, snapshot.groups).allSatisfy({ $0.slot == $1.slot && $0.tabs == $1.tabs })
        else { return false }
        let selected = Set(tabs)
        for tab in workspace.groups.flatMap(\.tabs) where selected.contains(tab.id) {
            guard let now = current[tab.documentID], let old = facts[tab.documentID], !(!old.modified && now.modified)
            else { return false }
            if command == .closeSaved && (now.modified || !now.fileBacked || now.missing) { return false }
        }
        return true
    }
}

extension TabWorkspace {
    /// Internal placement for New Right/reopen, not a drag, pin or group UI.
    package mutating func place(
        _ id: TabID, in slot: GroupSlot, index: Int, pinned: Bool,
        openDocuments: Set<DocumentID>
    ) throws {
        try validate(openDocuments: openDocuments)
        var next = self
        guard let source = next.groups.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
            let ti = next.groups[source].tabs.firstIndex(where: { $0.id == id }),
            let destination = next.groups.firstIndex(where: { $0.slot == slot })
        else { throw TabModelError.invalid }
        var tab = next.groups[source].tabs.remove(at: ti)
        tab.isPinned = pinned
        if next.groups[source].activeTab == id {
            next.groups[source].activeTab =
                next.groups[source].tabs.isEmpty
                ? nil : next.groups[source].tabs[min(ti, next.groups[source].tabs.count - 1)].id
        }
        let prefix = next.groups[destination].tabs.prefix { $0.isPinned }.count
        let lower = pinned ? 0 : prefix, upper = pinned ? prefix : next.groups[destination].tabs.count
        next.groups[destination].tabs.insert(tab, at: min(upper, max(lower, index)))
        if next.groups[destination].activeTab == nil { next.groups[destination].activeTab = id }
        try next.validate(openDocuments: openDocuments)
        self = next
    }
}
package struct ClosedTabRecord: Equatable, Sendable {
    package let id: UUID
    package let url: URL
    package let group: GroupSlot
    package let index: Int
    package let pinned: Bool
    package let anchor: Int
    package let caret: Int
    package let firstVisibleLine: Int
    package var fingerprint: String?
    package init(
        id: UUID = UUID(), url: URL, group: GroupSlot, index: Int, pinned: Bool,
        anchor: Int, caret: Int, firstVisibleLine: Int, fingerprint: String?
    ) {
        self.id = id
        self.url = url
        self.group = group
        self.index = index
        self.pinned = pinned
        self.anchor = anchor
        self.caret = caret
        self.firstVisibleLine = firstVisibleLine
        self.fingerprint = fingerprint
    }
}
package struct ClosedTabHistory: Sendable {
    static package let capacity = 20
    package private(set) var records: [ClosedTabRecord] = []
    package init() {}
    package var latest: ClosedTabRecord? { records.last }
    @discardableResult package mutating func push(_ record: ClosedTabRecord) -> ClosedTabRecord? {
        records.append(record)
        return records.count > Self.capacity ? records.removeFirst() : nil
    }
    @discardableResult package mutating func consume(_ id: UUID) -> Bool {
        guard records.last?.id == id else { return false }
        records.removeLast()
        return true
    }
    @discardableResult package mutating func setFingerprint(_ value: String?, for id: UUID) -> Bool {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return false }
        records[i].fingerprint = value
        return true
    }
    static package func clampOffset(_ value: Int, in utf8: Data) -> Int {
        var p = min(utf8.count, max(0, value))
        while p > 0 && p < utf8.count && utf8[utf8.startIndex + p] & 0xc0 == 0x80 { p -= 1 }
        return p
    }
}
