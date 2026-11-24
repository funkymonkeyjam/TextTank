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
    /// What the field's tooltip and accessibility help add to its text: for the position, the
    /// document's statistics.
    var detail = ""
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

/// The long operations the status row shows: a search of a large document, a search of a
/// folder. The row of every tab that shows the operation's document carries a progress
/// indicator and a Cancel button for it; an operation that belongs to no document is shown in
/// every tab. The owner of the work starts, updates and ends its operation here and keeps its
/// own cancellation; Cancel in the row calls that.
///
/// An operation is revealed only once it has run for `revealDelay`, so a search that returns at
/// once neither flashes an indicator nor speaks. Its start is announced when it is revealed;
/// its end is announced only if the owner gives the words, which it does when nothing else
/// announces the result (DS-36, DS-72). Progress steps are never announced. Progress is the
/// real fraction of the work or indeterminate (DS-51).
@MainActor final class StatusOperationCenter {
    static let shared = StatusOperationCenter()
    static let didChange = Notification.Name("TextTank.StatusOperationDidChange")
    struct Operation {
        let id: UUID
        /// What is running, in words: "Searching the document".
        let title: String
        /// The part that is done, from 0 to 1, or nil while the amount of work is unknown.
        var fraction: Double?
        let cancelLabel: String
        let cancel: @MainActor () -> Void
        fileprivate let scoped: Bool
        fileprivate weak var editor: TTEditor?
        fileprivate var revealed = false
    }
    /// How long an operation runs before it is shown and announced. Checks set this to zero.
    var revealDelay: TimeInterval = 0.3
    private(set) var operations: [Operation] = []
    /// - Parameters:
    ///   - editor: a view of the document the work is on; nil when it belongs to no document.
    ///   - cancelLabel: what the Cancel button does, for assistive technology: "Cancel search".
    @discardableResult func begin(
        _ title: String, in editor: TTEditor? = nil, cancelLabel: String, cancel: @escaping @MainActor () -> Void
    ) -> UUID {
        let id = UUID()
        operations.append(
            Operation(
                id: id, title: title, fraction: nil, cancelLabel: cancelLabel, cancel: cancel, scoped: editor != nil,
                editor: editor))
        if revealDelay <= 0 {
            reveal(id)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay) { [weak self] in self?.reveal(id) }
        }
        return id
    }
    private func reveal(_ id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }), !operations[index].revealed else { return }
        operations[index].revealed = true
        Announce.say(operations[index].title + ".")
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    /// Real progress: `done` of `total` units of the work. A total that is not positive leaves
    /// the indicator indeterminate. Rows are told only when the whole percentage changes.
    func update(_ id: UUID, done: Int, total: Int) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        let fraction = total > 0 ? min(1, max(0, Double(done) / Double(total))) : nil
        let before = operations[index].fraction.map { Int($0 * 100) }
        operations[index].fraction = fraction
        if operations[index].revealed, before != fraction.map({ Int($0 * 100) }) {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
    /// Ends an operation however it ended. `announce` is spoken only for an operation that was
    /// revealed; pass it when no other surface announces the outcome.
    func end(_ id: UUID, announce: String? = nil) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        let ended = operations.remove(at: index)
        guard ended.revealed else { return }
        if let announce { Announce.say(announce) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    /// The Cancel button of a row: asks the owner to cancel. The owner ends the operation.
    func cancel(_ id: UUID) { operations.first { $0.id == id }?.cancel() }
    /// The newest revealed operation a tab with these views shows.
    func operation(for views: [TTEditor]) -> Operation? {
        operations.last { operation in
            guard operation.revealed else { return false }
            guard operation.scoped else { return true }
            guard let editor = operation.editor else { return false }
            return views.contains { $0 === editor || $0.sharesDocument(with: editor) }
        }
    }
}

/// What the row shows for a running operation.
struct StatusProgress: Equatable {
    let id: UUID
    let title: String
    let fraction: Double?
    let cancelLabel: String
}

/// A follow-up to a status message, offered as a button in the row instead of as an
/// instruction in the message ("Show Changes"). `isCurrent` says whether it still applies; the
/// row drops it when it does not.
struct StatusFollowUp {
    let title: String
    /// The action and its scope, for assistive technology (DS-70).
    let accessibilityLabel: String
    let toolTip: String
    let run: @MainActor () -> Void
    let isCurrent: @MainActor () -> Bool
}

/// What every field of the status row is, whichever native control shows it.
@MainActor private protocol StatusFieldControl: NSControl {
    var field: StatusField { get }
    var measuredWidth: CGFloat { get }
    var shownText: String { get set }
}
extension StatusFieldControl {
    /// DS-74: every field is a target of the row's whole 28-point height. The text keeps the
    /// small system font and the primary control colour (DS-61).
    fileprivate func configureAsStatusField() {
        controlSize = .small
        font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        translatesAutoresizingMaskIntoConstraints = false
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: StatusBadgeRow.height).isActive = true
    }
}

/// Native pop-up cells supply their own menu tracking, keyboard behavior and accessibility role.
private final class StatusPopup: NSPopUpButton, StatusFieldControl {
    let field: StatusField
    var measuredWidth: CGFloat { max(24, ceil(intrinsicContentSize.width)) }
    var shownText: String {
        get { menu?.items.first?.title ?? "" }
        set {
            if menu?.items.isEmpty != false { menu?.addItem(withTitle: newValue, action: nil, keyEquivalent: "") }
            menu?.items[0].title = newValue
            selectItem(at: 0)
        }
    }
    init(field: StatusField) {
        self.field = field
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        configureAsStatusField()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// A field that runs one command when it is clicked or pressed: Go to Line for the position,
/// the language chooser for the language. A borderless native button, so the keyboard and
/// assistive technology activate it as they do any other.
private final class StatusButton: NSButton, StatusFieldControl {
    let field: StatusField
    var measuredWidth: CGFloat { max(24, ceil(intrinsicContentSize.width) + 8) }
    var shownText: String {
        get { title }
        // A borderless button dims its plain title in a window that is not key. The primary
        // label colour is set outright so the text reads the same as the fields beside it (DS-61).
        set {
            attributedTitle = NSAttributedString(
                string: newValue,
                attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: font ?? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                ])
        }
    }
    init(field: StatusField) {
        self.field = field
        super.init(frame: .zero)
        setButtonType(.momentaryChange)
        isBordered = false
        configureAsStatusField()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

/// One Auto Layout row. Each field does one thing: the position runs Go to Line, the language
/// opens the language chooser, and indentation, encoding, line endings and the selection each
/// open a menu of their own commands. Less important fields leave the row before the essential
/// state or position could be compressed; a field that has left is listed in the More menu at
/// the row's trailing edge, so nothing is out of reach at a narrow width (DS-67).
final class StatusBadgeRow: NSView, NSMenuDelegate {
    /// DS-74: the default size of a Mac control.
    static let height: CGFloat = 28
    /// The fields that run a command directly; every other field opens a menu.
    static let commandFields: Set<StatusField> = [.position, .language]
    var menuProvider: ((StatusField) -> NSMenu?)?
    /// Runs the command of a field in `commandFields`.
    var onCommand: ((StatusField) -> Void)?
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

    // MARK: Progress and follow-up

    static let progressIdentifier = "status.progress", cancelIdentifier = "status.cancelOperation"
    static let followUpIdentifier = "status.followUp"
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let followUpButton = NSButton(title: "", target: nil, action: nil)
    private(set) var progress: StatusProgress?
    /// Called with the operation's identity when its Cancel button is pressed.
    var onCancelOperation: ((UUID) -> Void)?
    private var followUp: StatusFollowUp?
    /// Shows a small progress indicator and a Cancel button for a running operation, or removes
    /// them. The indicator is determinate when the operation reports a real fraction (DS-51).
    func setProgress(_ value: StatusProgress?) {
        guard value != progress else { return }
        let wasShown = progress != nil
        progress = value
        progressBar.isHidden = value == nil
        cancelButton.isHidden = value == nil
        guard let value else {
            progressBar.stopAnimation(nil)
            needsLayout = true
            return
        }
        if let fraction = value.fraction {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            progressBar.doubleValue = fraction
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        }
        progressBar.setAccessibilityLabel(value.title)
        progressBar.toolTip = value.title
        cancelButton.setAccessibilityLabel(value.cancelLabel)
        cancelButton.cell?.setAccessibilityLabel(value.cancelLabel)
        cancelButton.toolTip = value.cancelLabel
        if !wasShown { needsLayout = true }
    }
    @objc private func cancelShownOperation(_ sender: Any?) {
        if let progress { onCancelOperation?(progress.id) }
    }
    /// Offers a follow-up as a button beside the status message, or withdraws it.
    func setFollowUp(_ value: StatusFollowUp?) {
        followUp = value
        followUpButton.isHidden = value == nil
        if let value {
            followUpButton.title = value.title
            followUpButton.setAccessibilityLabel(value.accessibilityLabel)
            followUpButton.cell?.setAccessibilityLabel(value.accessibilityLabel)
            followUpButton.toolTip = value.toolTip
        }
        needsLayout = true
    }
    @objc private func runFollowUp(_ sender: Any?) { followUp?.run() }

    let largeFileButton = NSButton(title: "Apply Language and Wrap Settings", target: nil, action: nil)
    var showsLargeFileAction: Bool {
        get { !largeFileButton.isHidden }
        set {
            guard newValue != showsLargeFileAction else { return }
            largeFileButton.isHidden = !newValue
            needsLayout = true
        }
    }
    private var popups: [any StatusFieldControl] = []
    /// Lists the fields that did not fit. Hidden while every field is shown.
    private let overflow = NSPopUpButton(frame: .zero, pullsDown: true)
    static let overflowIdentifier = "status.more"
    private var values: [StatusItem] = []
    private var leadingLabel: NSTextField?
    private var fullLeadingText = "Ready", compactLeadingText = "Ready"
    private var widths: [StatusField: NSLayoutConstraint] = [:]
    private var rebuildingMenu = false
    private static let progressWidth: CGFloat = 72
    private var overflowWidth: CGFloat { max(24, ceil(overflow.intrinsicContentSize.width)) }
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
        followUpButton.controlSize = .small
        followUpButton.identifier = .init(Self.followUpIdentifier)
        followUpButton.target = self
        followUpButton.action = #selector(runFollowUp(_:))
        followUpButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        followUpButton.isHidden = true
        stack.addArrangedSubview(followUpButton)
        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isIndeterminate = true
        progressBar.identifier = .init(Self.progressIdentifier)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: Self.progressWidth).isActive = true
        progressBar.isHidden = true
        stack.addArrangedSubview(progressBar)
        cancelButton.controlSize = .small
        cancelButton.identifier = .init(Self.cancelIdentifier)
        cancelButton.target = self
        cancelButton.action = #selector(cancelShownOperation(_:))
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        cancelButton.isHidden = true
        stack.addArrangedSubview(cancelButton)
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
        overflow.isBordered = false
        overflow.controlSize = .small
        overflow.identifier = NSUserInterfaceItemIdentifier(Self.overflowIdentifier)
        overflow.translatesAutoresizingMaskIntoConstraints = false
        overflow.setContentCompressionResistancePriority(.required, for: .horizontal)
        overflow.heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        let more = NSMenu()
        more.delegate = self
        more.autoenablesItems = false
        let face = more.addItem(withTitle: "", action: nil, keyEquivalent: "")
        face.image = NSImage(
            systemSymbolName: "ellipsis.circle", accessibilityDescription: "More status fields")
        if face.image == nil { face.title = "More" }
        overflow.menu = more
        let moreName = "More status fields. Shows the fields that do not fit."
        ControlPresentation.label(moreName, control: overflow)
        // The same help every status pull-down carries, on the control and on its cell, which is
        // the element assistive technology reads.
        let moreHelp = "Shows the status fields that do not fit in the window."
        overflow.setAccessibilityHelp(moreHelp)
        overflow.cell?.setAccessibilityHelp(moreHelp)
        overflow.toolTip = moreHelp
        // In the row only while a field has collapsed: a hidden control would still be a status
        // control with no element for assistive technology to reach.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height)
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
            let control: any StatusFieldControl = prior[item.field] ?? makeControl(item.field)
            control.shownText = item.text
            let group = item.field.identityGroup, number = occurrences[group, default: 0]
            occurrences[group] = number + 1
            control.identifier = NSUserInterfaceItemIdentifier("status.\(group).\(number)")
            let description = String(
                format: Strings.text("status.fieldValue", "%@: %@"), item.field.displayName, item.text)
            // DS-70: the name says what the field shows and what activating it does.
            let name: String, help: String
            switch item.field {
            case .position:
                name = description + ". Go to line."
                help = "Opens Go to Line." + (item.detail.isEmpty ? "" : " " + item.detail)
                control.toolTip = "Go to Line…" + (item.detail.isEmpty ? "" : "\n" + item.detail)
            case .language:
                name = description + ". Choose language."
                help = "Opens the language chooser."
                control.toolTip = description + ". Choose a language for this document."
            default:
                name = String(format: Strings.text("status.options", "%@. Show options."), description)
                help = Strings.text("status.showOptions", "Shows options for this field.")
                control.toolTip = name
            }
            ControlPresentation.label(name, control: control)
            control.setAccessibilityHelp(help)
            control.cell?.setAccessibilityHelp(help)
            if control.superview == nil { stack.addArrangedSubview(control) }
            if let constraint = widths[item.field] {
                constraint.constant = control.measuredWidth
            } else {
                let constraint = control.widthAnchor.constraint(equalToConstant: control.measuredWidth)
                constraint.isActive = true
                widths[item.field] = constraint
            }
            return control
        }
        for (field, control) in prior where !shown.contains(where: { $0.field == field }) {
            stack.removeArrangedSubview(control)
            control.removeFromSuperview()
            widths.removeValue(forKey: field)?.isActive = false
        }
        // Keep a stable visual order even when selection controls appear between existing fields.
        // The More menu stays at the trailing edge.
        for control in popups { stack.removeArrangedSubview(control) }
        for control in popups { stack.addArrangedSubview(control) }
        if overflow.superview != nil {
            stack.removeArrangedSubview(overflow)
            stack.addArrangedSubview(overflow)
        }
        needsLayout = true
    }
    private func makeControl(_ field: StatusField) -> any StatusFieldControl {
        guard Self.commandFields.contains(field) else {
            let popup = StatusPopup(field: field)
            let menu = NSMenu()
            menu.delegate = self
            menu.autoenablesItems = false
            popup.menu = menu
            return popup
        }
        let button = StatusButton(field: field)
        button.target = self
        button.action = #selector(runFieldCommand(_:))
        return button
    }
    @objc private func runFieldCommand(_ sender: Any?) {
        if let button = sender as? StatusButton {
            onCommand?(button.field)
        } else if let raw = (sender as? NSMenuItem)?.representedObject as? String, let field = StatusField(rawValue: raw)
        {
            onCommand?(field)
        }
    }
    /// What the More menu lists now: one entry per field that did not fit, in the row's order.
    /// A menu field keeps its own menu as a submenu; a command field is the command itself.
    func overflowItems() -> [NSMenuItem] {
        values.filter { collapsedFields.contains($0.field) }.map { value in
            let description = String(
                format: Strings.text("status.fieldValue", "%@: %@"), value.field.displayName, value.text)
            if Self.commandFields.contains(value.field) {
                let item = NSMenuItem(
                    title: description + "…", action: #selector(runFieldCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value.field.rawValue
                return item
            }
            let item = NSMenuItem(title: description, action: nil, keyEquivalent: "")
            item.submenu = menuProvider?(value.field)
            item.isEnabled = item.submenu != nil
            return item
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !rebuildingMenu else { return }
        rebuildingMenu = true
        defer { rebuildingMenu = false }
        if menu === overflow.menu {
            // The first item is the pull-down's own face.
            while menu.items.count > 1 { menu.removeItem(at: 1) }
            overflowItems().forEach(menu.addItem)
            return
        }
        guard let popup = popups.first(where: { ($0 as? NSPopUpButton)?.menu === menu }) as? StatusPopup else { return }
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
            // The action buttons, the follow-up and a running operation's indicator and Cancel
            // keep their width; fields collapse and the message shortens to make room for them.
            let buttons = [diskAction, diskCompare, followUpButton, cancelButton, largeFileButton, recording]
            let actionWidth =
                buttons.filter { $0.superview != nil && !$0.isHidden }.reduce(CGFloat(0)) {
                    $0 + ceil($1.intrinsicContentSize.width) + stack.spacing
                } + (progressBar.isHidden ? 0 : Self.progressWidth + stack.spacing)
            // Once a field has left the row the More menu takes its own place in it.
            let more = hidden.isEmpty ? 0 : overflowWidth + stack.spacing
            return textWidth + actionWidth + more + visible.reduce(0) { $0 + (widths[$1.field]?.constant ?? 0) }
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
        if hidden.isEmpty, overflow.superview != nil {
            stack.removeArrangedSubview(overflow)
            overflow.removeFromSuperview()
        } else if !hidden.isEmpty, overflow.superview == nil {
            stack.addArrangedSubview(overflow)
        }
        if label.stringValue != text { label.stringValue = text }
        super.layout()
    }
}
