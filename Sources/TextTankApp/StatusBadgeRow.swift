import AppKit

/// Borderless native buttons preserve keyboard and accessibility activation.
/// What the status bar shows about the whole text: its Unicode scalar count and the line endings
/// it contains ("" for none, "Mixed EOL" for more than one kind). One pass over the UTF-8 bytes,
/// safe on any queue; the bytes are valid UTF-8, so every byte that is not a continuation byte
/// starts one scalar.
enum StatusMetrics {
    static func scan(_ utf8: Data) -> (characters: Int, endings: String) {
        var count = 0, cr = false, lf = false, crlf = false, priorCR = false
        utf8.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                if byte & 0xC0 != 0x80 { count += 1 }
                if byte == 13 {
                    if priorCR { cr = true }
                    priorCR = true
                } else {
                    if byte == 10 { if priorCR { crlf = true } else { lf = true } } else if priorCR { cr = true }
                    priorCR = false
                }
            }
        }
        if priorCR { cr = true }
        let endings = [crlf ? "CRLF" : nil, lf ? "LF" : nil, cr ? "CR" : nil].compactMap { $0 }
        return (count, endings.count > 1 ? "Mixed EOL" : endings.first ?? "")
    }
}

/// Status identity is independent of its displayed text; repeated groups keep their historic IDs.
enum StatusField: String, CaseIterable {
    case document, bookmarks, language, position, characters, lines, selectedCharacters, selections, font, indent,
        encoding, eol, wrap, readOnly
    var identityGroup: String {
        switch self {
        case .characters, .lines: return "count"
        case .selectedCharacters, .selections: return "selection"
        case .readOnly: return "document"
        default: return rawValue
        }
    }
    var displayName: String {
        switch self {
        case .document: return Strings.text("status.document", "Document")
        case .bookmarks: return Strings.text("status.bookmarks", "Bookmarks")
        case .language: return Strings.text("status.language", "Language")
        case .position: return Strings.text("status.position", "Position")
        case .characters: return Strings.text("status.characters", "Character count")
        case .lines: return Strings.text("status.lines", "Line count")
        case .selectedCharacters: return Strings.text("status.selectedCharacters", "Selected characters")
        case .selections: return Strings.text("status.selections", "Selections")
        case .font: return Strings.text("status.font", "Text size")
        case .indent: return Strings.text("status.indent", "Indentation")
        case .encoding: return Strings.text("status.encoding", "Encoding")
        case .eol: return Strings.text("status.eol", "Line endings")
        case .wrap: return Strings.text("status.wrap", "Line wrapping")
        case .readOnly: return Strings.text("status.readOnly", "Document access")
        }
    }
}
struct StatusItem: Equatable {
    let field: StatusField
    let text: String
}

private final class StatusBadge: NSButton {
    var activate: ((StatusBadge) -> Void)?
    init(_ text: String) {
        super.init(frame: .zero)
        title = text
        isBordered = false
        bezelStyle = .regularSquare
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        contentTintColor = .secondaryLabelColor
        toolTip = text + " — click for options"
        setButtonType(.momentaryChange)
        target = self
        action = #selector(showOptions)
    }
    @objc private func showOptions() { activate?(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    var preferredWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: font!]).width) + 20 }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.10 : 0.035).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        super.draw(dirtyRect)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class StatusBadgeRow: NSView {
    var onActivate: ((StatusField, NSView) -> Void)?
    private var values: [StatusItem] = []
    private var badges: [StatusBadge] = []
    private var identities: [String] = []
    private var measuredWidth: CGFloat = -1
    override var isFlipped: Bool { true }
    func update(_ items: [StatusItem]) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.text("status.group", "Document status"))
        var counts: [String: Int] = [:]
        let ids = items.map { item -> String in
            let key = item.field.identityGroup, n = counts[key, default: 0]
            counts[key] = n + 1
            return "\(key).\(n)"
        }
        guard items != values || ids != identities else { return }
        let existing = Dictionary(uniqueKeysWithValues: zip(identities, badges))
        let updated = zip(items, ids).map { item, id -> StatusBadge in
            let badge = existing[id] ?? StatusBadge(item.text)
            badge.title = item.text
            let description = String(
                format: Strings.text("status.fieldValue", "%@: %@"), item.field.displayName, item.text)
            badge.toolTip = String(format: Strings.text("status.options", "%@. Show options."), description)
            badge.setAccessibilityLabel(description)
            // AppKit exposes the button cell, not its host view, in the native AX tree.
            badge.cell?.setAccessibilityLabel(description)
            badge.setAccessibilityHelp(Strings.text("status.showOptions", "Shows options for this field."))
            badge.identifier = NSUserInterfaceItemIdentifier("status." + id)
            badge.activate = { [weak self] button in self?.onActivate?(item.field, button) }
            if badge.superview == nil { addSubview(badge) }
            return badge
        }
        for (id, badge) in existing where !ids.contains(id) { badge.removeFromSuperview() }
        values = items
        identities = ids
        badges = updated
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    private func rows() -> [[StatusBadge]] {
        let width = max(1, bounds.width)
        var result: [[StatusBadge]] = [], row: [StatusBadge] = []
        var used: CGFloat = 0
        for badge in badges {
            let size = min(width, badge.preferredWidth)
            if !row.isEmpty && used + 6 + size > width {
                result.append(row)
                row = []
                used = 0
            }
            if !row.isEmpty { used += 6 }
            row.append(badge)
            used += size
        }
        if !row.isEmpty { result.append(row) }
        return result
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(max(1, rows().count)) * 26 - 4)
    }
    override func layout() {
        super.layout()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        for (index, row) in rows().enumerated() {
            let width =
                row.reduce(CGFloat(0)) { $0 + min(bounds.width, $1.preferredWidth) } + CGFloat(max(0, row.count - 1))
                * 6
            var x = bounds.width - width
            for badge in row {
                let size = min(bounds.width, badge.preferredWidth)
                badge.frame = NSRect(x: x, y: CGFloat(index) * 26, width: size, height: 22)
                x += size + 6
            }
        }
    }
}
