// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

/// The table view of a delimited-text preview. Copy puts the selected rows on the pasteboard.
final class PreviewTableView: NSTableView {
    var copyRows: (() -> Void)?

    @objc func copy(_ sender: Any?) { copyRows?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// Shows comma- or tab-separated text as a read-only table.
///
/// Every cell is the text exactly as written; nothing is interpreted as a number, a date or a
/// formula. Cells are read from the `DelimitedTable` when a row comes into view, so a table of
/// a hundred thousand rows costs no more to show than a small one. The first row is data.
@MainActor final class PreviewTablePresenter: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = PreviewTableView()
    private(set) var table: DelimitedTable?

    var onSelection: (([Range<Int>]) -> Void)?
    private var restoring = false

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoring, !scrollView.isHidden, let table else { return }
        let ranges = tableView.selectedRowIndexes.rangeView.compactMap { rows -> Range<Int>? in
            guard rows.lowerBound >= 0, rows.upperBound <= table.rowCount else { return nil }
            return table.rowSourceRanges[rows.lowerBound].lowerBound..<table.rowSourceRanges[rows.upperBound - 1].upperBound
        }
        if !ranges.isEmpty { onSelection?(ranges) }
    }

    /// The longest text put in a cell or a tooltip. The table itself keeps the whole value.
    static let displayLimit = 1_000
    /// Shown in place of a line break inside a cell, which is drawn on one line.
    static let lineBreakMark = "⏎"
    private static let lineColumn = NSUserInterfaceItemIdentifier("preview.table.line")

    override init() {
        super.init()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.copyRows = { [weak self] in self?.copySelectedRows() }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    /// Replaces the table. The selection and scroll position are kept where the rows still exist.
    func show(_ newTable: DelimitedTable) {
        restoring = true
        defer { restoring = false }
        let selection = tableView.selectedRowIndexes
        let columnsChanged = table?.columnCount != newTable.columnCount || tableView.tableColumns.isEmpty
        table = newTable
        if columnsChanged { rebuildColumns(count: newTable.columnCount) }
        tableView.reloadData()
        let kept = selection.filteredIndexSet { $0 < newTable.rowCount }
        tableView.selectRowIndexes(kept, byExtendingSelection: false)
    }

    // MARK: Following the source

    /// The zero-based source line row `row` starts on. A value with a line break inside its
    /// quotation marks makes a row span several lines; the row is still found from any of them.
    func sourceLine(ofRow row: Int) -> Int? {
        guard let table, row >= 0, row < table.rowCount else { return nil }
        return table.rowLines[row] - 1
    }

    /// The row that zero-based source `line` belongs to: the last row that starts on or before
    /// it. A binary search over the rows' starting lines.
    func row(forSourceLine line: Int) -> Int? {
        guard let table, table.rowCount > 0 else { return nil }
        var low = 0
        var high = table.rowCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if table.rowLines[middle] - 1 <= line { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private func rebuildColumns(count: Int) {
        tableView.tableColumns.forEach(tableView.removeTableColumn)
        let line = NSTableColumn(identifier: Self.lineColumn)
        line.title = Strings.text("preview.table.lineColumn", "Line")
        line.headerToolTip = Strings.text(
            "preview.table.lineColumn.help", "The line of the document that each row starts on.")
        line.width = 56
        line.isEditable = false
        (line.dataCell as? NSTextFieldCell)?.alignment = .right
        (line.dataCell as? NSTextFieldCell)?.textColor = .secondaryLabelColor
        tableView.addTableColumn(line)
        for index in 0..<count {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = Self.columnTitle(index)
            column.headerToolTip = String(
                format: Strings.text("preview.table.column.help", "Column %@"), Strings.number(index + 1))
            column.width = 140
            column.minWidth = 40
            column.isEditable = false
            if let cell = column.dataCell as? NSTextFieldCell {
                cell.lineBreakMode = .byTruncatingTail
                cell.usesSingleLineMode = true
            }
            tableView.addTableColumn(column)
        }
    }

    /// Spreadsheet-style column letters: A to Z, then AA, AB and so on.
    static func columnTitle(_ index: Int) -> String {
        var remaining = index
        var letters: [Character] = []
        repeat {
            letters.insert(Character(UnicodeScalar(UInt8(65 + remaining % 26))), at: 0)
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return String(letters)
    }

    /// The text drawn for a cell: the value as written, on one line, cut to `displayLimit`.
    func displayText(row: Int, column: Int) -> String {
        guard let table, row < table.rowCount else { return "" }
        return Self.singleLine(table.cell(row: row, column: column))
    }

    static func singleLine(_ value: String) -> String {
        var text = value.count > displayLimit ? String(value.prefix(displayLimit)) + "…" : value
        if text.contains(where: \.isNewline) {
            text = String(text.map { $0.isNewline ? Character(lineBreakMark) : $0 })
        }
        return text
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { table?.rowCount ?? 0 }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let table, let tableColumn, row < table.rowCount else { return nil }
        if tableColumn.identifier == Self.lineColumn { return Strings.number(table.rowLines[row]) }
        guard let column = Int(tableColumn.identifier.rawValue) else { return nil }
        return displayText(row: row, column: column)
    }

    /// The whole value, for a cell that is cut short or holds more than one line.
    func tableView(
        _ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, row: Int,
        mouseLocation: NSPoint
    ) -> String {
        guard let table, let tableColumn, let column = Int(tableColumn.identifier.rawValue), row < table.rowCount
        else { return "" }
        let value = table.cell(row: row, column: column)
        return value.count > 4 * Self.displayLimit ? String(value.prefix(4 * Self.displayLimit)) + "…" : value
    }

    // MARK: Copy

    /// The selected rows as tab-separated text, one row per line. A value that contains a tab, a
    /// line break or a quotation mark is wrapped in quotation marks, so the rows paste back as
    /// the same cells.
    func selectedRowsText() -> String {
        guard let table else { return "" }
        // Only the cells the row has: a short row is not padded with cells it never had.
        let lines = tableView.selectedRowIndexes.filter { $0 < table.rowCount }.map { row in
            (0..<table.cellCount(inRow: row)).map { Self.quotedForTabs(table.cell(row: row, column: $0)) }
                .joined(separator: "\t")
        }
        return lines.joined(separator: "\n")
    }

    private static func quotedForTabs(_ value: String) -> String {
        guard value.contains(where: { $0 == "\t" || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func copySelectedRows() {
        guard let board = RuntimeEnvironment.current.generalPasteboard() else { return }
        board.clearContents()
        board.setString(selectedRowsText(), forType: .string)
    }

    /// The sentences for the message row: limits first, then quoting problems.
    static func summary(of table: DelimitedTable) -> String? {
        var sentences: [String?] = table.limitsReached.map(\.message)
        sentences.append(table.diagnostics.first?.message)
        sentences.append(PreviewMessages.moreQuotingProblems(table.diagnosticCount - 1))
        return PreviewMessages.joined(sentences)
    }
}
