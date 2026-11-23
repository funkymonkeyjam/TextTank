// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

/// One row of the JSON outline: a node of the tree that is showing.
private final class JSONOutlineItem: NSObject {
    let node: Int
    init(node: Int) { self.node = node }
}

/// Finds, for a value of the tree that was showing, the same value in a newer tree.
///
/// A value is found through its parent: an array item is the item at the same position, and an
/// object member is the member at the same position when that one has the same name, which is
/// the usual case while a person types and costs one comparison. Only when the position holds
/// another name is the member looked for by name (and, where names repeat, by how many members
/// of that name come before it). That reads every name of the object in both trees, so it is
/// charged to an allowance; when the allowance is used up the remaining values are not found.
private struct JSONNodeMatcher {
    let old: JSONTree
    let new: JSONTree
    private(set) var comparisonsLeft: Int
    /// Values already looked for, with what was found.
    private var known: [Int: Int?] = [:]

    init(old: JSONTree, new: JSONTree, comparisonAllowance: Int) {
        self.old = old
        self.new = new
        comparisonsLeft = comparisonAllowance
    }

    /// The node of `new` that is the value `node` of `old`, or nil when it is gone.
    mutating func counterpart(of node: Int) -> Int? {
        if let found = known[node] { return found }
        // From the outermost value down to `node`; nesting is bounded by the JSON depth limit.
        var chain: [Int] = []
        var current: Int? = node
        while let step = current, known[step] == nil {
            chain.append(step)
            current = old.nodes[step].parent
        }
        for step in chain.reversed() {
            if let parent = old.nodes[step].parent {
                known[step] = (known[parent] ?? nil).flatMap { child(of: $0, matching: step) }
            } else {
                known[step] = new.root
            }
        }
        return known[node] ?? nil
    }

    private mutating func child(of newParent: Int, matching oldNode: Int) -> Int? {
        let position = old.nodes[oldNode].indexInParent
        let candidates = new.children(of: newParent)
        let samePosition = position < candidates.count ? candidates[candidates.startIndex + position] : nil
        guard let name = old.key(of: oldNode) else {
            return new.nodes[newParent].kind == .array ? samePosition : nil
        }
        guard new.nodes[newParent].kind == .object else { return nil }
        if let samePosition, new.key(of: samePosition) == name { return samePosition }
        guard let oldParent = old.nodes[oldNode].parent else { return nil }
        comparisonsLeft -= position + candidates.count
        guard comparisonsLeft >= 0 else { return nil }
        let occurrence = old.children(of: oldParent).prefix(position).filter { old.key(of: $0) == name }.count
        return candidates.filter { new.key(of: $0) == name }.dropFirst(occurrence).first
    }
}

/// Shows JSON as a read-only tree of names and values.
///
/// Rows are made when their parent is opened, so a tree at the value limit costs little until
/// it is explored. When the document is parsed again, the rows that were open and the selected
/// row are found again in the new tree (`JSONNodeMatcher`), so typing does not close the tree.
@MainActor final class PreviewOutlinePresenter: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scrollView = NSScrollView()
    let outlineView = NSOutlineView()
    private(set) var tree: JSONTree?
    /// The row objects made so far, by node. Most stay nil: a row exists once its parent is opened.
    private var items: [JSONOutlineItem?] = []
    /// The nodes whose rows are open, kept in step by the outline view's notifications. A new
    /// parse reads this instead of asking every row of a long tree whether it is open.
    private var openNodes: Set<Int> = []

    /// One step from a value to one of its children: the member's name and which of the members
    /// with that name it is (names may repeat), or the position in an array.
    enum PathStep: Hashable {
        case member(String, occurrence: Int)
        case element(Int)
    }

    /// The most open rows that are opened again after a new parse.
    static let rememberedRows = 2_000
    /// The most member names read, for one new parse, to find members whose position changed. A
    /// member that has moved inside an object with very many members is costly to find again by
    /// name; when the allowance is used up the remaining rows are simply left closed.
    static let comparisonAllowance = 100_000
    static let displayLimit = 1_000
    private static let nameColumn = NSUserInterfaceItemIdentifier("preview.json.name")
    private static let valueColumn = NSUserInterfaceItemIdentifier("preview.json.value")

    override init() {
        super.init()
        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = Strings.text("preview.json.nameColumn", "Name")
        name.width = 220
        name.minWidth = 80
        name.isEditable = false
        let value = NSTableColumn(identifier: Self.valueColumn)
        value.title = Strings.text("preview.json.valueColumn", "Value")
        value.width = 360
        value.minWidth = 80
        value.isEditable = false
        for column in [name, value] {
            if let cell = column.dataCell as? NSTextFieldCell {
                cell.lineBreakMode = .byTruncatingTail
                cell.usesSingleLineMode = true
            }
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = name
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsColumnReordering = false
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.style = .plain
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    /// Replaces the tree, keeping open rows and the selection where their values still exist.
    /// The outermost value is opened the first time there is one: a tree with no value at all,
    /// which is what text that is not JSON from its first byte gives, has no row to keep open
    /// or closed, so the tree after it starts open too.
    func show(_ newTree: JSONTree) {
        let oldTree = tree
        let open = oldTree.map(openRowNodes(in:)) ?? []
        let selected = selectedNode
        tree = newTree
        items = Array(repeating: nil, count: newTree.nodes.count)
        openNodes = []
        outlineView.reloadData()
        guard let root = newTree.root else { return }
        guard let oldTree, oldTree.root != nil else {
            outlineView.expandItem(item(root))
            return
        }
        var matcher = JSONNodeMatcher(old: oldTree, new: newTree, comparisonAllowance: Self.comparisonAllowance)
        // Parents have lower numbers than their children, so each row finds its parent open.
        for node in open {
            if let match = matcher.counterpart(of: node) { outlineView.expandItem(item(match)) }
        }
        if let selected, let match = matcher.counterpart(of: selected) {
            let row = outlineView.row(forItem: item(match))
            if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    // MARK: Open rows

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? JSONOutlineItem { openNodes.insert(item.node) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? JSONOutlineItem { openNodes.remove(item.node) }
    }

    /// The nodes of the open rows that are on screen (every row above them open too), in
    /// document order, at most `rememberedRows` of them.
    private func openRowNodes(in tree: JSONTree) -> [Int] {
        var nodes: [Int] = []
        for node in openNodes.sorted() {
            guard nodes.count < Self.rememberedRows else { break }
            var isShowing = true
            var ancestor = tree.nodes[node].parent
            while let above = ancestor, isShowing {
                isShowing = openNodes.contains(above)
                ancestor = tree.nodes[above].parent
            }
            if isShowing { nodes.append(node) }
        }
        return nodes
    }

    private var selectedNode: Int? {
        guard outlineView.selectedRow >= 0 else { return nil }
        return (outlineView.item(atRow: outlineView.selectedRow) as? JSONOutlineItem)?.node
    }

    /// The node at `path` from the outermost value, or nil when the tree does not have it.
    func node(at path: [PathStep], in tree: JSONTree) -> Int? {
        guard var current = tree.root else { return nil }
        for step in path {
            let children = tree.children(of: current)
            switch step {
            case .element(let position):
                guard tree.nodes[current].kind == .array, position < children.count else { return nil }
                current = children[children.startIndex + position]
            case .member(let name, let occurrence):
                guard tree.nodes[current].kind == .object else { return nil }
                let matches = children.lazy.filter { tree.key(of: $0) == name }
                guard let found = matches.dropFirst(occurrence).first else { return nil }
                current = found
            }
        }
        return current
    }

    /// Opens the row at `path` and every row above it. Called only by the checks.
    @discardableResult func expand(path: [PathStep]) -> Bool {
        guard let tree else { return false }
        for length in 0...path.count {
            guard let node = node(at: Array(path.prefix(length)), in: tree) else { return false }
            outlineView.expandItem(item(node))
        }
        return true
    }

    // MARK: Text

    /// What the Name column shows: the member's name, the position in an array, or "Document"
    /// for the outermost value.
    func name(of node: Int) -> String {
        guard let tree else { return "" }
        if let name = tree.key(of: node) { return Self.clipped(name) }
        if tree.nodes[node].parent == nil { return Strings.text("preview.json.root", "Document") }
        return Strings.number(tree.nodes[node].indexInParent)
    }

    /// What the Value column shows: the value as the core displays it, never converted.
    func value(of node: Int) -> String {
        guard let tree else { return "" }
        return Self.clipped(tree.displayValue(of: node))
    }

    private static func clipped(_ text: String) -> String {
        let single = text.contains(where: \.isNewline) ? String(text.map { $0.isNewline ? " " : $0 }) : text
        return single.count > displayLimit ? String(single.prefix(displayLimit)) + "…" : single
    }

    private func item(_ node: Int) -> JSONOutlineItem {
        if let existing = items[node] { return existing }
        let created = JSONOutlineItem(node: node)
        items[node] = created
        return created
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let tree, let root = tree.root else { return 0 }
        guard let item = item as? JSONOutlineItem else { return root < tree.nodes.count ? 1 : 0 }
        return tree.nodes[item.node].childCount
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let tree, let root = tree.root else { return NSNull() }
        guard let parent = item as? JSONOutlineItem else { return self.item(root) }
        let children = tree.children(of: parent.node)
        return self.item(children[children.startIndex + index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let tree, let item = item as? JSONOutlineItem else { return false }
        return tree.nodes[item.node].childCount > 0
    }

    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?)
        -> Any?
    {
        guard let item = item as? JSONOutlineItem, let tableColumn else { return nil }
        return tableColumn.identifier == Self.nameColumn ? name(of: item.node) : value(of: item.node)
    }

    /// The value exactly as written in the document, for a string shown decoded or cut short.
    func outlineView(
        _ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?,
        item: Any, mouseLocation: NSPoint
    ) -> String {
        guard let tree, let item = item as? JSONOutlineItem, tableColumn?.identifier == Self.valueColumn,
            !tree.nodes[item.node].isContainer
        else { return "" }
        let raw = tree.rawText(of: item.node)
        return raw.count > 4 * Self.displayLimit ? String(raw.prefix(4 * Self.displayLimit)) + "…" : raw
    }

    /// The sentences for the message row: the syntax error, then any limit.
    static func summary(error: JSONSyntaxError?, limit: PreviewLimit?) -> String? {
        PreviewMessages.joined([error?.message, limit?.message])
    }
}
