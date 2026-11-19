// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
import TextTankCore

/// Snapshot renderer with a native virtual-row scroller. Leading space is outside the engine,
/// so source line zero and an entirely empty side need no invented newline.
@MainActor final class ComparePane: NSView {
    let editor = TTEditor(frame: .zero)
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 18, height: 200))
    private let emptyLabel = NSTextField(labelWithString: "No source lines")
    var onScroll: ((Int) -> Void)?
    var onResize: (() -> Void)?
    var onFontChange: ((NSFont) -> Void)?
    private var lastFont: NSFont?
    var onExpand: ((Int) -> Void)?
    var foldRows: [(top: Int, height: Int, count: Int, index: Int)] = []
    private var foldButtons: [Int: NSButton] = [:]
    private(set) var top = 0
    var leadingRows = 0
    var totalRows = 1
    var isEmpty = false { didSet { emptyLabel.isHidden = !isEmpty } }
    private var oldSize = NSSize.zero
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(editor)
        addSubview(scroller)
        addSubview(emptyLabel)
        editor.comparisonPresentation = true
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .regular
        scroller.target = self
        scroller.action = #selector(scrollbar(_:))
        scroller.setAccessibilityLabel("Scroll comparison text")
        emptyLabel.setAccessibilityLabel("No source lines on this side")
        emptyLabel.isHidden = true
        editor.onComparisonViewportChange = { [weak self] in
            guard let self else { return }
            let font = self.editor.comparisonFont
            if self.lastFont != font {
                self.lastFont = font
                self.onFontChange?(font)
            }
            let value = self.leadingRows + self.editor.comparisonTopDisplayLine
            if self.top >= self.leadingRows && value != self.top {
                self.setTop(value)
                self.onScroll?(self.top)
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var lineHeight: Int { editor.comparisonLineHeight }
    var visibleRows: Int { max(1, Int(bounds.height) / max(1, lineHeight)) }
    func setTop(_ value: Int) {
        top = max(0, min(value, max(0, totalRows - visibleRows)))
        editor.comparisonTopDisplayLine = max(0, top - leadingRows)
        scroller.doubleValue = totalRows > visibleRows ? Double(top) / Double(totalRows - visibleRows) : 0
        scroller.knobProportion = min(1, Double(visibleRows) / Double(max(1, totalRows)))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = NSScroller.scrollerWidth(for: scroller.controlSize, scrollerStyle: scroller.scrollerStyle)
        let gap = min(bounds.height, CGFloat(max(0, leadingRows - top) * lineHeight))
        editor.frame = NSRect(x: 0, y: gap, width: max(0, bounds.width - width), height: max(0, bounds.height - gap))
        editor.isHidden = isEmpty || gap >= bounds.height
        scroller.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        emptyLabel.frame = NSRect(x: 12, y: 12, width: max(0, bounds.width - width - 24), height: 28)
        refreshFoldButtons()
        if oldSize != bounds.size {
            oldSize = bounds.size
            onResize?()
        }
    }
    override func scrollWheel(with event: NSEvent) {
        let delta =
            event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / CGFloat(lineHeight) : event.scrollingDeltaY
        setTop(top - Int(delta.rounded(.awayFromZero)))
        onScroll?(top)
    }
    func scroll(by rows: Int) {
        setTop(top + rows)
        onScroll?(top)
    }
    @objc private func scrollbar(_ sender: NSScroller) {
        switch sender.hitPart {
        case .incrementLine: scroll(by: 1)
        case .decrementLine: scroll(by: -1)
        case .incrementPage: scroll(by: visibleRows)
        case .decrementPage: scroll(by: -visibleRows)
        default:
            setTop(Int((Double(max(0, totalRows - visibleRows)) * sender.doubleValue).rounded()))
            onScroll?(top)
        }
    }
    private func refreshFoldButtons() {
        // Binary-search visible summaries instead of scanning all folds on every scroll tick.
        var lo = 0, hi = foldRows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if foldRows[mid].top + foldRows[mid].height < top { lo = mid + 1 } else { hi = mid }
        }
        var visible = Set<Int>(), i = lo
        while i < foldRows.count && foldRows[i].top <= top + visibleRows {
            let row = foldRows[i]
            visible.insert(row.index)
            let button = foldButtons[row.index] ?? NSButton(title: "", target: self, action: #selector(expand(_:)))
            if button.superview == nil {
                addSubview(button)
                foldButtons[row.index] = button
            }
            button.title = String(
                format: row.count == 1 ? "Expand 1 unchanged line" : "Expand %ld unchanged lines", row.count)
            button.setAccessibilityLabel(button.title)
            button.tag = row.index
            button.frame = NSRect(
                x: 8, y: CGFloat((row.top - top) * lineHeight), width: max(0, editor.frame.width - 16),
                height: CGFloat(max(28, row.height * lineHeight)))
            i += 1
        }
        for (id, button) in foldButtons where !visible.contains(id) {
            button.removeFromSuperview()
            foldButtons.removeValue(forKey: id)
        }
    }
    @objc private func expand(_ sender: NSButton) { onExpand?(sender.tag) }
    func releaseContent() {
        editor.onComparisonViewportChange = nil
        editor.clearComparisonPresentation()
        editor.readOnly = false
        editor.text = ""
        editor.resetUndoHistory()
        editor.setSavePoint()
        foldRows = []
        foldButtons.values.forEach { $0.removeFromSuperview() }
        foldButtons.removeAll()
    }
}
