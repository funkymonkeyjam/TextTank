import AppKit
import EditorBridge
import NativeSearch
import TextTankCore

/// The find bar's options as one select-any control (DS-35). Words when the bar has room for
/// them, symbols when it does not; either way each segment has a tooltip and a spoken name.
final class FindOptionsControl: NSSegmentedControl {
    enum Option: Int, CaseIterable {
        case matchCase, wholeWord, regex
        var title: String {
            switch self {
            case .matchCase: return "Match case"
            case .wholeWord: return "Whole word"
            case .regex: return "Regex"
            }
        }
        /// The option's full name, for tooltips and assistive technology (DS-70).
        var name: String {
            switch self {
            case .matchCase: return "Match case"
            case .wholeWord: return "Whole word"
            case .regex: return "Regular expression"
            }
        }
        fileprivate var symbols: [String] {
            switch self {
            case .matchCase: return ["textformat"]
            case .wholeWord: return ["text.word.spacing", "character.textbox"]
            case .regex: return ["asterisk"]
            }
        }
        /// Shown only if the system has none of the symbols.
        fileprivate var shortTitle: String {
            switch self {
            case .matchCase: return "Aa"
            case .wholeWord: return "Word"
            case .regex: return ".*"
            }
        }
        fileprivate func help(on: Bool, mode: SearchOptions.Mode) -> String {
            switch self {
            case .matchCase:
                return on
                    ? "Match case is on: uppercase and lowercase letters must match. Click to turn it off."
                    : "Match case is off: uppercase and lowercase letters are treated alike. Click to turn it on."
            case .wholeWord:
                return on
                    ? "Whole word is on: only complete words are found. Click to turn it off."
                    : "Whole word is off: the Find text is also found inside longer words. Click to turn it on."
            case .regex:
                if on {
                    return "Regular expression is on: the Find text is a pattern. Click to search in Normal mode."
                }
                return mode == .extended
                    ? "Regular expression is off. The search mode is Extended, chosen in Find and Replace. Click to search with a pattern."
                    : "Regular expression is off: the search mode is Normal. Click to search with a pattern."
            }
        }
    }
    /// The narrowest segment is still a 28-point target (DS-74).
    private static let symbolSegmentWidth: CGFloat = 32
    private(set) var showsWords = true
    private(set) var wordsWidth: CGFloat = 0
    private(set) var symbolsWidth: CGFloat = 0
    private var mode = SearchOptions.Mode.normal
    override init(frame: NSRect) {
        super.init(frame: frame)
        segmentCount = Option.allCases.count
        trackingMode = .selectAny
        identifier = .init("editor.find.options")
        setAccessibilityLabel("Search options for Find in document")
        apply(words: false)
        symbolsWidth = ceil(fittingSize.width)
        apply(words: true)
        wordsWidth = ceil(fittingSize.width)
        describe()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    private func apply(words: Bool) {
        showsWords = words
        for option in Option.allCases {
            let segment = option.rawValue
            if words {
                setImage(nil, forSegment: segment)
                setLabel(option.title, forSegment: segment)
                setWidth(0, forSegment: segment)
            } else if let image = option.symbols.lazy.compactMap({
                NSImage(systemSymbolName: $0, accessibilityDescription: option.name)
            }).first {
                setLabel("", forSegment: segment)
                setImage(image, forSegment: segment)
                setWidth(Self.symbolSegmentWidth, forSegment: segment)
            } else {
                setImage(nil, forSegment: segment)
                setLabel(option.shortTitle, forSegment: segment)
                setWidth(Self.symbolSegmentWidth + 8, forSegment: segment)
            }
        }
    }
    func setShowsWords(_ words: Bool) {
        if words != showsWords { apply(words: words) }
    }
    func isOn(_ option: Option) -> Bool { isSelected(forSegment: option.rawValue) }
    /// Shows the shared options. `mode` is named when it is neither Normal nor Regex, so a mode
    /// chosen in the Find and Replace window is not hidden behind an unlit Regex segment.
    func show(matchCase: Bool, wholeWord: Bool, mode: SearchOptions.Mode) {
        setSelected(matchCase, forSegment: Option.matchCase.rawValue)
        setSelected(wholeWord, forSegment: Option.wholeWord.rawValue)
        setSelected(mode == .regularExpression, forSegment: Option.regex.rawValue)
        self.mode = mode
        describe()
    }
    /// What a click on the segment does: the option changes and the control sends its action.
    func toggle(_ option: Option) {
        setSelected(!isOn(option), forSegment: option.rawValue)
        describe()
        sendAction(action, to: target)
    }
    /// One tooltip per segment and one spoken value for the control (DS-70, DS-85). No option has
    /// a keyboard shortcut of its own, so none is named.
    func describe() {
        for option in Option.allCases {
            setToolTip(option.help(on: isOn(option), mode: mode), forSegment: option.rawValue)
        }
        var parts = Option.allCases.map { "\($0.name) \(isOn($0) ? "on" : "off")" }
        if mode == .extended { parts.append("Extended search mode") }
        setAccessibilityValue(parts.joined(separator: ", "))
    }
}

/// One row until Replace is disclosed, so the text keeps the room (DS-10). Every native Find
/// action remains visible at a group's 320-point minimum (DS-35, 67, 70-74).
final class EditorFindBar: NSView {
    /// The person's last choice for the Replace row, for the rest of this launch. Nil until the
    /// disclosure control is used: Find then opens with one row unless a replacement is in use.
    static var rememberedShowsReplace: Bool?
    private static let rowHeight: CGFloat = 24, rowPitch: CGFloat = 26, gap: CGFloat = 4
    private static let disclosureWidth: CGFloat = 24, countWidth: CGFloat = 124, minimumFindWidth: CGFloat = 180
    private let disclosure: NSButton, find: NSView, replace: NSView, navigation: NSView, count: NSView
    private let more: NSView, done: NSView
    private let options: FindOptionsControl, replaceActions: [NSButton]
    /// Called after the disclosure control is clicked, with the row's new state.
    var onDisclose: ((Bool) -> Void)?
    private(set) var showsReplace = false
    init(disclosure: NSButton, find: NSView, replace: NSView, navigation: NSView, count: NSView,
         options: FindOptionsControl, replaceActions: [NSButton], more: NSView, done: NSView) {
        self.disclosure = disclosure
        self.find = find
        self.replace = replace
        self.navigation = navigation
        self.count = count
        self.options = options
        self.replaceActions = replaceActions
        self.more = more
        self.done = done
        super.init(frame: .zero)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.identifier = .init("editor.find.disclosure")
        disclosure.target = self
        disclosure.action = #selector(disclose(_:))
        ([disclosure, find, count, options, navigation, more, done, replace] + replaceActions).forEach {
            addSubview($0)
        }
        applyReplaceVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    @objc private func disclose(_ sender: NSButton) { onDisclose?(sender.state == .on) }
    func setShowsReplace(_ shown: Bool) {
        guard shown != showsReplace else { return }
        showsReplace = shown
        applyReplaceVisibility()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    private func applyReplaceVisibility() {
        disclosure.state = showsReplace ? .on : .off
        ([replace] + replaceActions).forEach { $0.isHidden = !showsReplace }
        let help =
            showsReplace
            ? "Hide the Replace field and its buttons." : "Show the Replace field and its buttons under Find."
        disclosure.toolTip = help
        disclosure.setAccessibilityLabel("Replace in document")
        disclosure.setAccessibilityHelp(help)
    }
    private func fitting(_ view: NSView) -> CGFloat { ceil(view.fittingSize.width) }
    private struct Arrangement: Equatable {
        /// Find, the count, the options and the actions share the first row.
        var oneRow: Bool
        var words: Bool
    }
    /// Words for the options when the Find field keeps a usable width beside them, symbols when
    /// it would not, and a second row for the options and the count below that.
    private func arrangement(for width: CGFloat) -> Arrangement {
        let fixed =
            Self.disclosureWidth + Self.countWidth + fitting(navigation) + fitting(more) + fitting(done)
            + Self.gap * 6
        if width - fixed - options.wordsWidth >= Self.minimumFindWidth { return Arrangement(oneRow: true, words: true) }
        if width - fixed - options.symbolsWidth >= Self.minimumFindWidth {
            return Arrangement(oneRow: true, words: false)
        }
        // The second row holds the options, at least a short count and More.
        let beside = fitting(more) + 96 + Self.gap * 2
        return Arrangement(oneRow: false, words: width - beside >= options.wordsWidth)
    }
    private func rows(for width: CGFloat) -> Int { (arrangement(for: width).oneRow ? 1 : 2) + (showsReplace ? 1 : 0) }
    /// Three rows are only ever needed in a narrow group, which may also be the shortest one: a
    /// 320 × 200 group has 72 points for the bar above a 32-point editor and the 28-point status
    /// row. Three rows therefore sit without the 2-point gap that one or two rows have.
    private func pitch(rows: Int) -> CGFloat { rows > 2 ? Self.rowHeight : Self.rowPitch }
    /// 24 points with one row; 50 with Replace or at a narrow width; 72 with both.
    override var intrinsicContentSize: NSSize {
        let count = rows(for: bounds.width)
        return NSSize(
            width: NSView.noIntrinsicMetric, height: CGFloat(count - 1) * pitch(rows: count) + Self.rowHeight)
    }
    override func setFrameSize(_ newSize: NSSize) {
        let before = rows(for: bounds.width)
        super.setFrameSize(newSize)
        if before != rows(for: bounds.width) { invalidateIntrinsicContentSize() }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let shape = arrangement(for: bounds.width)
        options.setShowsWords(shape.words)
        var nextRow = 0
        let rowPitch = pitch(rows: rows(for: bounds.width))
        func takeRow() -> CGFloat {
            defer { nextRow += 1 }
            return bounds.height - Self.rowHeight - CGFloat(nextRow) * rowPitch
        }
        // Each row has at most one flexible field or label. Native control fitting sizes
        // preserve the labels across system font sizes and appearances.
        func row(_ views: [NSView], flexible: NSView?, from start: CGFloat, y: CGFloat) {
            let fixed = views.filter { $0 !== flexible }.reduce(CGFloat.zero) { $0 + width(of: $1) }
            let remaining = max(0, bounds.width - start - fixed - Self.gap * CGFloat(views.count - 1))
            var x = start
            for view in views {
                let width = view === flexible ? remaining : width(of: view)
                view.frame = NSRect(x: x, y: y, width: width, height: Self.rowHeight)
                x += width + Self.gap
            }
        }
        func width(of view: NSView) -> CGFloat {
            if view === disclosure { return Self.disclosureWidth }
            if view === count, shape.oneRow { return Self.countWidth }
            return fitting(view)
        }
        let first = takeRow()
        row(
            shape.oneRow ? [disclosure, find, count, options, navigation, more, done] : [disclosure, find, navigation, done],
            flexible: find, from: 0, y: first)
        if showsReplace {
            // Under the Find field and, where the row allows, exactly as wide.
            let y = takeRow()
            if shape.oneRow {
                var x = find.frame.minX
                for (view, width) in [(replace, find.frame.width)] + replaceActions.map({ ($0 as NSView, fitting($0)) }) {
                    view.frame = NSRect(x: x, y: y, width: width, height: Self.rowHeight)
                    x += width + Self.gap
                }
            } else {
                row([replace] + replaceActions, flexible: replace, from: find.frame.minX, y: y)
            }
        }
        if !shape.oneRow { row([options, count, more], flexible: count, from: 0, y: takeRow()) }
        count.centreTextVertically()
    }
}

extension NSView {
    /// A label given a control's row height draws its text at the top. This keeps the row's
    /// width and centres the label's own height in it, on the fields' and buttons' centre line.
    fileprivate func centreTextVertically() {
        let height = min(frame.height, ceil(fittingSize.height))
        frame = NSRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height).integral
    }
}

/// What was typed into Go to Line, read against the document's own line count.
enum GoToLineEntry: Equatable {
    /// Nothing typed yet.
    case empty
    /// A line the document has, and the column typed after a colon, if any. Both count from 1.
    case target(line: Int, column: Int?)
    /// The words to show under the field.
    case rejected(String)

    /// "Lines are 1–120." The same sentence ends every message, so the range is always in view.
    static func range(_ lines: Int) -> String {
        lines == 1 ? "This document has 1 line." : "Lines are 1–\(Strings.number(lines))."
    }
    static func hint(_ lines: Int) -> String { "\(range(lines)) Add a colon for a column, such as 12:4." }
    /// Shown after text that held the caret, the selection or the top line was deleted from
    /// another view or by an automation while the field was open.
    static func displaced(_ lines: Int) -> String {
        "The text changed. Escape goes back to the nearest place left to where the caret was. \(range(lines))"
    }
    /// Shown while the line typed is hidden in a fold: the preview leaves folding alone.
    static func folded(_ line: Int) -> String {
        "Line \(Strings.number(line)) is in folded text. Press Return to unfold it and go there."
    }
    /// `line` or `line:column` in ASCII digits. A colon with nothing after it yet is the line alone.
    static func parse(_ text: String, lines: Int) -> GoToLineEntry {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty { return .empty }
        let parts = typed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        func digits(_ part: String) -> Bool { !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) } }
        guard digits(parts[0]), parts.count == 1 || parts[1].isEmpty || digits(parts[1]) else {
            return .rejected("Enter a line number, such as 12 or 12:4. \(range(lines))")
        }
        guard let line = Int(parts[0]), line >= 1, line <= lines else {
            let shown = parts[0].count > 12 ? "that number" : "line \(parts[0])"
            return .rejected("There is no \(shown). \(range(lines))")
        }
        guard parts.count == 2, !parts[1].isEmpty else { return .target(line: line, column: nil) }
        // A column past the end of the line goes to the end of the line.
        guard let column = Int(parts[1]) else { return .target(line: line, column: Int(Int32.max)) }
        guard column >= 1 else { return .rejected("Columns start at 1. Enter a line and a column, such as 12:4.") }
        return .target(line: line, column: column)
    }
}

/// Go to Line as one field in the find bar's place (DS-10, DS-44): a label, the field, the valid
/// range or what is wrong with the entry in words (DS-45), and the two ways out.
final class EditorGoToLineBar: NSView {
    private static let rowHeight: CGFloat = 24, rowPitch: CGFloat = 26, gap: CGFloat = 4, fieldWidth: CGFloat = 96
    let label = NSTextField(labelWithString: "Go to line:")
    let field = NSTextField()
    /// Announced when it changes: the range, or why the entry cannot be used (DS-72).
    let message = AnnouncingLabel(labelWithString: "")
    let goButton = NSButton(title: "Go", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// Escape while a button of the bar has the keyboard (DS-73).
    var onCancel: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = .init("editor.goToLine")
        field.identifier = .init("goToLine.line")
        // On the cell as well: the cell is the element assistive technology is given (DS-70).
        field.setAccessibilityLabel("Line number in Go to Line")
        field.cell?.setAccessibilityLabel("Line number in Go to Line")
        message.identifier = .init("goToLine.message")
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.setAccessibilityLabel("Lines in document")
        goButton.identifier = .init("goToLine.go")
        goButton.setAccessibilityLabel("Go to the line entered")
        goButton.cell?.setAccessibilityLabel("Go to the line entered")
        cancelButton.identifier = .init("goToLine.cancel")
        cancelButton.setAccessibilityLabel("Close Go to Line and return to where the caret was")
        cancelButton.cell?.setAccessibilityLabel("Close Go to Line and return to where the caret was")
        [label, field, message, goButton, cancelButton].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    /// Shows the range, or the reason an entry is rejected. A rejected entry also marks the field
    /// with the same words as its help and tooltip; the label is never the only carrier (DS-45, DS-62).
    func show(_ text: String, rejected: Bool) {
        message.textColor = rejected ? .labelColor : .secondaryLabelColor
        message.toolTip = text
        field.toolTip = rejected ? text : nil
        field.setAccessibilityHelp(rejected ? text : nil)
        message.setAccessibilityLabel(rejected ? "Input needs correction in Go to Line" : "Lines in document")
        message.stringValue = text
    }
    var entryIsMarked: Bool { field.toolTip != nil }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    /// One row while the message fits beside the field; below that it has a row of its own, so
    /// the range is not cut short in a narrow group (DS-67).
    private var compact: Bool { bounds.width < 700 }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: compact ? Self.rowPitch + Self.rowHeight : Self.rowHeight)
    }
    override func setFrameSize(_ newSize: NSSize) {
        let wasCompact = compact
        super.setFrameSize(newSize)
        if wasCompact != compact { invalidateIntrinsicContentSize() }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        func fitting(_ view: NSView) -> CGFloat { ceil(view.fittingSize.width) }
        let top = bounds.height - Self.rowHeight
        var x: CGFloat = 0
        for (view, width) in [(label as NSView, fitting(label)), (field, Self.fieldWidth)] {
            view.frame = NSRect(x: x, y: top, width: width, height: Self.rowHeight)
            x += width + Self.gap
        }
        var trailing = bounds.width
        for button in [cancelButton, goButton] {
            let width = fitting(button)
            trailing -= width
            button.frame = NSRect(x: trailing, y: top, width: width, height: Self.rowHeight)
            trailing -= Self.gap
        }
        message.frame =
            compact
            ? NSRect(x: 0, y: 0, width: bounds.width, height: Self.rowHeight)
            : NSRect(x: x, y: top, width: max(0, trailing - x), height: Self.rowHeight)
        label.centreTextVertically()
        message.centreTextVertically()
    }
}

/// Where the text was when Go to Line opened, so that typing can show a line and anything but
/// Return can put the caret, every selection, the scroll position and the folding back exactly.
/// The editor holds the place and moves it with every edit to the document, so a change made
/// from another view or by an automation while the field is open never makes the previewed
/// line the place to go back to.
@MainActor final class LineJumpPreview {
    weak var editor: TTEditor?
    /// The text as last read by the field; a different revision means it changed underneath.
    private(set) var revision: UInt
    private let topSubline: Int, horizontalOffset: Int
    /// The preview has moved the caret, so there is something to put back.
    private var moved = false
    init(_ editor: TTEditor) {
        self.editor = editor
        revision = editor.revision
        topSubline = editor.firstVisibleSubline
        horizontalOffset = editor.horizontalScrollOffset
        editor.holdPlace()
    }
    private var current: TTEditor? {
        guard let editor, EditorLifetime.isOpen(editor) else { return nil }
        return editor
    }
    /// The document changed underneath. True when text that held the caret, a selection end or
    /// the top line was deleted, so the place to go back to is the nearest one left; also when
    /// the view now shows another document and there is no place to go back to.
    func noteDocumentChanged() -> Bool {
        guard let editor = current else { return false }
        revision = editor.revision
        return editor.heldPlaceDisplaced || editor.heldSelectionSnapshot == nil
    }
    /// Shows the line without it counting as a jump: nothing is recorded, nothing is unfolded,
    /// and a macro recording in this view is left alone because the caret is not moved while one
    /// runs (F277). Returns the line the caret was put on: the fold header that holds a line
    /// hidden in a fold; nil when nothing was shown.
    @discardableResult func show(line: Int, column: Int?, recording: Bool) -> Int? {
        guard !recording, let editor = current else { return nil }
        let shown = editor.preview(line: line, column: column ?? 1)
        guard shown > 0 else { return nil }
        moved = true
        return shown
    }
    func restoreSelection() {
        guard moved, let editor = current, let held = editor.heldSelectionSnapshot else { return }
        _ = editor.restoreSelectionSnapshot(held)
        moved = false
    }
    /// After the bar has left and the editor has its height back.
    func restoreScroll() {
        guard let editor = current else { return }
        let topLine = editor.heldTopDocumentLine
        guard topLine >= 0 else { return }
        if editor.firstVisibleDocumentLine != topLine || editor.firstVisibleSubline != topSubline {
            editor.scrollTo(documentLine: topLine, subline: topSubline)
        }
        if editor.horizontalScrollOffset != horizontalOffset { editor.horizontalScrollOffset = horizontalOffset }
    }
    /// The field is closed; the editor stops following the place.
    func end() { current?.releaseHeldPlace() }
}

/// What a live preview shows in the bar's count label: a count, or why there is none.
struct InlineFindPublication {
    var count = ""
    var detail: String?
    /// The whole document holds no match of the Find text.
    var foundNothing = false
    var failure: Error?
}

/// A preview owns only its temporary indicator and a selection it can still identify.
@MainActor final class InlineFindPreview {
    weak var editor: TTEditor?
    let revision: UInt
    private static let paintLineLimit = SizePolicy.standard.findHighlightLine
    private let openingCaret: Int
    private let original: [TTSelectionRange]
    private let mayMoveSelection: Bool
    private var selectionAtPublication: NSRange?
    private var painted = false
    private var pending: Task<Void, Never>?
    private var cancellation: TTSearchCancellation?
    private var snapshot: Data?
    init(_ editor: TTEditor) {
        self.editor = editor
        revision = editor.revision
        openingCaret = editor.selectionCaret
        original = editor.selectionRanges
        mayMoveSelection = !editor.selectionIsRectangular
    }
    private func stillOwnsSelection(_ editor: TTEditor) -> Bool {
        guard !editor.selectionIsRectangular else { return false }
        if let range = selectionAtPublication {
            return editor.selectionCount == 1 && editor.selectionAnchor == range.location
                && editor.selectionCaret == NSMaxRange(range)
        }
        let current = editor.selectionRanges
        return original.count == current.count && zip(original, current).allSatisfy {
            $0.anchor == $1.anchor && $0.caret == $1.caret
        }
    }
    private func restoreSelection() {
        guard let editor, editor.revision == revision, selectionAtPublication != nil,
              stillOwnsSelection(editor) else { return }
        _ = editor.setSelectionRanges(original)
        selectionAtPublication = nil
    }
    private func cancelPending() {
        cancellation?.cancel()
        cancellation = nil
        pending?.cancel()
        pending = nil
    }
    private func clearHighlights() {
        if painted { _ = editor?.setFindPreviewHighlights([]); painted = false }
    }
    func cancel(restore: Bool) {
        cancelPending()
        clearHighlights()
        if restore { restoreSelection() }
    }
    func search(options: SearchOptions, isCurrent: @escaping @MainActor () -> Bool,
        publish: @escaping @MainActor (InlineFindPublication) -> Void
    ) {
        cancelPending()
        guard !options.query.isEmpty else {
            clearHighlights()
            restoreSelection()
            publish(InlineFindPublication())
            return
        }
        let controller = EditorServices.current?.searchController
        let unitLimit = controller?.largeDocumentUnits ?? SearchCore.maximumTextUnits
        let chunkBytes = controller?.largeChunkBytes ?? SearchCore.largeChunkBytes
        // Replace the previous paint in one publication. Clearing and repainting on separate
        // frames would ask Scintilla to lay out a long physical line twice on each keystroke.
        let flag = TTSearchCancellation()
        cancellation = flag
        pending = Task { @MainActor [weak self] in
            do {
                // A near-megabyte single line needs more of the latency budget for native painting.
                guard let editor = self?.editor, let caret = self?.openingCaret else { return }
                let lineLength = editor.findPreviewLineLength(atByte: UInt(caret))
                let largePaint = lineLength > 256 * 1024 && lineLength <= Self.paintLineLimit
                try await Task.sleep(nanoseconds: largePaint ? 45_000_000 : 90_000_000)
                guard let self, !flag.cancelled, isCurrent(),
                      EditorLifetime.isOpen(editor), editor.revision == self.revision else { return }
                if self.snapshot == nil { self.snapshot = editor.checkedUTF8Data }
                guard let data = self.snapshot else { throw SearchFailure.positionMapping }
                let result = try await Task.detached(priority: .userInitiated) {
                    try SearchController.preview(
                        data, options: options, openingCaret: caret, cancellation: flag, unitLimit: unitLimit,
                        chunkBytes: chunkBytes)
                }.value
                guard !flag.cancelled, isCurrent(), EditorLifetime.isOpen(editor), editor.revision == self.revision else { return }
                let detail = self.show(result, in: editor, openingLineLength: lineLength)
                publish(
                    InlineFindPublication(
                        count: result.countText, detail: detail, foundNothing: result.foundNothing))
            } catch {
                guard !flag.cancelled, isCurrent() else { return }
                self?.clearHighlights()
                self?.restoreSelection()
                publish(InlineFindPublication(count: error.localizedDescription, failure: error))
            }
        }
    }
    private func show(_ result: SearchController.InlinePreview, in editor: TTEditor, openingLineLength: UInt) -> String? {
        // A passive invalidation makes Scintilla lay out the complete visible physical line.
        // Keep typing responsive on giant unbroken lines; explicit Return still navigates.
        guard max(openingLineLength, editor.findPreviewLongestVisibleLine) <= Self.paintLineLimit else {
            clearHighlights()
            restoreSelection()
            return result.selected == nil ? nil : "Highlights are limited on very long lines. Press Return to select a match."
        }
        let hits = result.highlights.filter { $0.length > 0 }
        let marks = hits.compactMap { hit -> TTByteRange? in
            guard editor.findPreviewLineLength(atByte: UInt(hit.location)) <= Self.paintLineLimit else { return nil }
            return TTByteRange(location: hit.location, length: hit.length)
        }
        if painted || !marks.isEmpty {
            painted = editor.setFindPreviewHighlights(marks) && !marks.isEmpty
        }
        if let selected = result.selected, editor.findPreviewLineLength(atByte: UInt(selected.location)) <= Self.paintLineLimit {
            if mayMoveSelection, EditorServices.current?.macros?.isRecording(in: editor) != true,
               stillOwnsSelection(editor), editor.setSelectionAnchor(selected.location, caret: NSMaxRange(selected)) {
                selectionAtPublication = selected
            }
        } else { restoreSelection() }
        return marks.count < hits.count ? "Highlights are limited on very long lines. Press Return to select a match." : nil
    }

}
