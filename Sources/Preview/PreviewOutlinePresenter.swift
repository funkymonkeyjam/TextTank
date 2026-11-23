// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

/// One row of the JSON outline: a node of the tree that is showing.
private final class JSONOutlineItem: NSObject {
    let node: Int
    init(node: Int) { self.node = node }
}

/// Shows JSON as a read-only tree of names and values.
///
/// Rows are made when their parent is opened, so a tree at the value limit costs little until
/// it is explored. When the document is parsed again, the rows that were open and the selected
/// row are found again by their path of names and positions, so typing does not close the tree.
@MainActor final class PreviewOutlinePresenter: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let scrollView = NSScrollView()
    let outlineView = NSOutlineView()
    private(set) var tree: JSONTree?
    private var items: [Int: JSONOutlineItem] = [:]

    /// One step from a value to one of its children: the member's name and which of the members
    /// with that name it is (names may repeat), or the position in an array.
    enum PathStep: Hashable {
        case member(String, occurrence: Int)
        case element(Int)
    }

    /// The most open rows that are remembered across a new parse.
    static let rememberedRows = 2_000
    /// The most member names compared while remembering and finding rows for one new parse. A
    /// row inside an object with very many members is costly to find again by name; when the
    /// allowance is used up the remaining rows are simply left closed.
    static let comparisonAllowance = 200_000
    private var comparisonsLeft = 0
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

    /// Replaces the tree, keeping open rows and the selection where their paths still exist.
    /// The first time, the outermost value is opened.
    func show(_ newTree: JSONTree) {
        let hadTree = tree != nil
        comparisonsLeft = Self.comparisonAllowance
        let open = expandedPaths()
        let selected = selectedPath()
        tree = newTree
        items = [:]
        outlineView.reloadData()
        guard let root = newTree.root else { return }
        if hadTree {
            // Parents come before their children in row order, so each path finds its parent open.
            for path in open {
                if let node = node(at: path, in: newTree) { outlineView.expandItem(item(node)) }
            }
        } else {
            outlineView.expandItem(item(root))
        }
        if let selected, let node = node(at: selected, in: newTree) {
            let row = outlineView.row(forItem: item(node))
            if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    // MARK: Paths

    /// The paths of the open rows, in row order, at most `rememberedRows` of them.
    func expandedPaths() -> [[PathStep]] {
        guard let tree else { return [] }
        var paths: [[PathStep]] = []
        for row in 0..<outlineView.numberOfRows {
            guard paths.count < Self.rememberedRows, comparisonsLeft > 0 else { break }
            guard let item = outlineView.item(atRow: row) as? JSONOutlineItem, outlineView.isItemExpanded(item)
            else { continue }
            paths.append(path(to: item.node, in: tree))
        }
        return paths
    }

    func selectedPath() -> [PathStep]? {
        guard let tree, outlineView.selectedRow >= 0,
            let item = outlineView.item(atRow: outlineView.selectedRow) as? JSONOutlineItem
        else { return nil }
        return path(to: item.node, in: tree)
    }

    /// The path from the outermost value to `node`. The outermost value has the empty path.
    func path(to node: Int, in tree: JSONTree) -> [PathStep] {
        var steps: [PathStep] = []
        var current = node
        while let parent = tree.nodes[current].parent {
            if let name = tree.key(of: current) {
                comparisonsLeft -= tree.nodes[current].indexInParent
                let earlier = tree.children(of: parent).prefix(tree.nodes[current].indexInParent)
                let occurrence = earlier.filter { tree.key(of: $0) == name }.count
                steps.append(.member(name, occurrence: occurrence))
            } else {
                steps.append(.element(tree.nodes[current].indexInParent))
            }
            current = parent
        }
        return steps.reversed()
    }

    /// The node at `path`, or nil when the tree no longer has it.
    func node(at path: [PathStep], in tree: JSONTree) -> Int? {
        guard var current = tree.root else { return nil }
        for step in path {
            let children = tree.children(of: current)
            switch step {
            case .element(let position):
                guard tree.nodes[current].kind == .array, position < children.count else { return nil }
                current = children[children.startIndex + position]
            case .member(let name, let occurrence):
                guard tree.nodes[current].kind == .object, comparisonsLeft > 0 else { return nil }
                comparisonsLeft -= children.count
                let matches = children.lazy.filter { tree.key(of: $0) == name }
                guard let found = matches.dropFirst(occurrence).first else { return nil }
                current = found
            }
        }
        return current
    }

    /// Opens the row at `path` and every row above it. For checks and for restoring state.
    @discardableResult func expand(path: [PathStep]) -> Bool {
        guard let tree else { return false }
        comparisonsLeft = Self.comparisonAllowance
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
