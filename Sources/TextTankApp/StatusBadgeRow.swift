import TextTankCore
import EditorBridge
import NativeSearch
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

/// A display prefix never substitutes the document's save state for an action result.
/// Callers with essential details after a variable name/path provide a semantic summary instead.
enum StatusMessageSummary {
    static func leadingWords(_ text: String, font: NSFont) -> String {
        var prefix = "", boundary = ""
        for character in text.prefix(256) {
            if character.isWhitespace && !prefix.isEmpty { boundary = prefix }
            let candidate = prefix + String(character)
            if ((candidate + "…") as NSString).size(withAttributes: [.font: font]).width > 420 {
                return boundary.isEmpty
                    ? Strings.text("status.messageDetails", "Message details are available.") : boundary + "…"
            }
            prefix = candidate
        }
        if prefix == text { return text }
        return boundary.isEmpty
            ? Strings.text("status.messageDetails", "Message details are available.") : boundary + "…"
    }
}

/// Native pop-up cells supply their own menu tracking, keyboard behavior and accessibility role.
private final class StatusPopup: NSPopUpButton {
    let field: StatusField
    var measuredWidth: CGFloat { max(24, ceil(intrinsicContentSize.width)) }
    init(field: StatusField) {
        self.field = field
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        controlSize = .small
        font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// One Auto Layout row. Less important fields disappear before the essential state or position
/// could be compressed. Their menus remain available inside Position.
final class StatusBadgeRow: NSView, NSMenuDelegate {
    var menuProvider: ((StatusField) -> NSMenu?)?
    private let stack = NSStackView()
    private let spacer = NSView()
    private let recording = NSButton(title: "", target: nil, action: nil)
    private weak var recorder: MacroController?
    func bindRecorder(_ controller: MacroController?) {
        guard recorder !== controller else { return }
        if let recorder {
            NotificationCenter.default.removeObserver(self, name: MacroController.recordingDidChange, object: recorder)
        }
        recorder = controller
        if let controller {
            NotificationCenter.default.addObserver(
                self, selector: #selector(refreshRecording), name: MacroController.recordingDidChange,
                object: controller)
        }
        refreshRecording()
    }
    @objc private func refreshRecording() {
        let status = recorder?.recordingStatus ?? .idle
        recording.isHidden = status == .idle
        recording.target = recorder
        recording.action = #selector(MacroController.stopRecording)
        switch status {
        case .idle: break
        case .recording:
            recording.title = "● Recording"
            recording.setAccessibilityLabel("Stop macro recording")
            recording.toolTip = "A macro is being recorded. Stop recording."
        case .discarded(let reason):
            recording.title = "Macro Discarded"
            recording.setAccessibilityLabel("Finish discarded macro recording")
            recording.toolTip = reason
        }
        recording.setAccessibilityHelp(recording.toolTip)
        needsLayout = true
    }
    private let diskAction = NSButton(title: "Reload…", target: nil, action: nil)
    private let diskCompare = NSButton(title: "Compare…", target: nil, action: nil)
    func setExternalAction(for observer: ExternalFileObservation) {
        if diskAction.superview == nil {
            diskAction.controlSize = .small
            diskAction.identifier = NSUserInterfaceItemIdentifier("status.reloadExternalFile")
            stack.insertArrangedSubview(diskAction, at: leadingLabel == nil ? 0 : 1)
            diskCompare.controlSize = .small
            diskCompare.identifier = NSUserInterfaceItemIdentifier("status.compareExternalFile")
            diskCompare.setAccessibilityLabel("Compare editor and changed file on disk")
            stack.insertArrangedSubview(diskCompare, at: leadingLabel == nil ? 1 : 2)
        }
        diskCompare.target = observer
        diskCompare.action = #selector(ExternalFileObservation.compare(_:))
        diskCompare.isHidden = !observer.offersComparison
        diskAction.target = observer
        diskAction.action = #selector(ExternalFileObservation.reload(_:))
        diskAction.isHidden = observer.actionTitle == nil
        if let title = observer.actionTitle {
            diskAction.title = title
            diskAction.setAccessibilityLabel(
                title == "Reload…" ? "Reload changed file from disk" : "Check file contents on disk")
        }
        needsLayout = true
    }

    let largeFileButton = NSButton(title: "Apply Language and Wrap Settings", target: nil, action: nil)
    var showsLargeFileAction: Bool {
        get { !largeFileButton.isHidden }
        set {
            guard newValue != showsLargeFileAction else { return }
            largeFileButton.isHidden = !newValue
            needsLayout = true
        }
    }
    private var popups: [StatusPopup] = []
    private var values: [StatusItem] = []
    private var leadingLabel: NSTextField?
    private var fullLeadingText = "Ready", compactLeadingText = "Ready"
    private var widths: [StatusField: NSLayoutConstraint] = [:]
    private var rebuildingMenu = false
    private(set) var collapsedFields: [StatusField] = []
    /// Position remains present at the supported 800-point minimum. Selection follows it in priority.
    static let collapseOrder: [StatusField] = [.language, .indent, .eol, .encoding, .selections, .selectedCharacters]
    private static let rowFields: Set<StatusField> = [
        .position, .selectedCharacters, .selections, .language, .indent, .encoding, .eol
    ]
    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("status.row")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.text("status.group", "Document status"))
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        largeFileButton.controlSize = .small
        largeFileButton.isHidden = true
        largeFileButton.toolTip = "Enable the detected language and your Wrap Lines setting for this large file."
        largeFileButton.setAccessibilityLabel("Enable language highlighting and normal wrapping for this large file")
        stack.addArrangedSubview(largeFileButton)
        recording.controlSize = .small
        recording.identifier = .init("status.macroRecording")
        recording.setContentCompressionResistancePriority(.required, for: .horizontal)
        recording.isHidden = true
        stack.addArrangedSubview(recording)
        stack.addArrangedSubview(spacer)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    func setLeadingStatus(_ label: NSTextField, fullText: String, compactText: String) {
        if leadingLabel !== label {
            leadingLabel?.removeFromSuperview()
            leadingLabel = label
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.lineBreakMode = .byTruncatingTail
            stack.insertArrangedSubview(label, at: 0)
        }
        fullLeadingText = fullText
        compactLeadingText = compactText
        label.stringValue = fullText
        ControlPresentation.label(fullText, control: label)
        needsLayout = true
    }
    func update(_ items: [StatusItem]) {
        let shown = items.filter { Self.rowFields.contains($0.field) }
        guard shown != values else { return }
        values = shown
        let prior = Dictionary(uniqueKeysWithValues: popups.map { ($0.field, $0) })
        var occurrences: [String: Int] = [:]
        popups = shown.map { item in
            let popup = prior[item.field] ?? StatusPopup(field: item.field)
            let menu = popup.menu ?? NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            popup.menu = menu
            if menu.items.isEmpty { menu.addItem(withTitle: item.text, action: nil, keyEquivalent: "") }
            menu.items[0].title = item.text
            popup.selectItem(at: 0)
            let group = item.field.identityGroup, number = occurrences[group, default: 0]
            occurrences[group] = number + 1
            popup.identifier = NSUserInterfaceItemIdentifier("status.\(group).\(number)")
            let description = String(
                format: Strings.text("status.fieldValue", "%@: %@"), item.field.displayName, item.text)
            ControlPresentation.label(
                String(format: Strings.text("status.options", "%@. Show options."), description), control: popup)
            let help = Strings.text("status.showOptions", "Shows options for this field.")
            popup.setAccessibilityHelp(help)
            popup.cell?.setAccessibilityHelp(help)
            popup.toolTip = String(format: Strings.text("status.options", "%@. Show options."), description)
            if popup.superview == nil { stack.addArrangedSubview(popup) }
            if let constraint = widths[item.field] {
                constraint.constant = popup.measuredWidth
            } else {
                let constraint = popup.widthAnchor.constraint(equalToConstant: popup.measuredWidth)
                constraint.isActive = true
                widths[item.field] = constraint
            }
            return popup
        }
        for (field, popup) in prior where !shown.contains(where: { $0.field == field }) {
            stack.removeArrangedSubview(popup)
            popup.removeFromSuperview()
            widths.removeValue(forKey: field)?.isActive = false
        }
        // Keep a stable visual order even when selection controls appear between existing fields.
        for popup in popups { stack.removeArrangedSubview(popup) }
        for popup in popups { stack.addArrangedSubview(popup) }
        needsLayout = true
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !rebuildingMenu, let popup = popups.first(where: { $0.menu === menu }) else { return }
        rebuildingMenu = true
        defer { rebuildingMenu = false }
        let title = values.first { $0.field == popup.field }?.text ?? popup.title
        menu.removeAllItems()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        if let supplied = menuProvider?(popup.field) {
            for item in supplied.items {
                supplied.removeItem(item)
                menu.addItem(item)
            }
        }
        popup.selectItem(at: 0)
    }
    override func layout() {
        guard let label = leadingLabel else {
            super.layout()
            return
        }
        var hidden = Set<StatusField>()
        func requiredWidth(_ text: String) -> CGFloat {
            let visible = popups.filter { !hidden.contains($0.field) }
            let textWidth =
                ceil(
                    (text as NSString).size(withAttributes: [
                        .font: label.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                    ]).width) + 2
            let actionWidth = [diskAction, diskCompare, largeFileButton, recording].filter { $0.superview != nil && !$0.isHidden }
                .reduce(
                    CGFloat(0)
                ) {
                    $0 + ceil($1.intrinsicContentSize.width) + stack.spacing
                }
            return textWidth + actionWidth + visible.reduce(0) { $0 + (widths[$1.field]?.constant ?? 0) }
                + CGFloat(visible.count + 1) * stack.spacing
        }
        func collapse(_ text: String) {
            hidden = []
            for field in Self.collapseOrder where requiredWidth(text) > max(0, bounds.width - 8) {
                if popups.contains(where: { $0.field == field }) { hidden.insert(field) }
            }
        }
        var text = fullLeadingText
        collapse(text)
        if requiredWidth(text) > max(0, bounds.width - 8) {
            // The full message remains the real native accessibility name and tooltip. Only
            // path/diagnostic prose yields to the concise essential save/failure state.
            text = compactLeadingText
            collapse(text)
        }
        collapsedFields = Self.collapseOrder.filter { hidden.contains($0) }
        for popup in popups {
            let shouldHide = hidden.contains(popup.field)
            if popup.isHidden != shouldHide { popup.isHidden = shouldHide }
        }
        if label.stringValue != text { label.stringValue = text }
        super.layout()
    }
}
