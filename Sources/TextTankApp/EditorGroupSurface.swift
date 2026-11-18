import AppKit
import TextTankCore

/// Native group chrome and split geometry (DS-14,41-43,70-74). No document ownership.
final class EditorGroupSurface: NSView {
    let generation = UUID()
    var slot: GroupSlot
    weak var host: WorkspaceWindowController?
    let strip = DocumentTabStrip()
    let content = NSView()
    private let heading = NSButton()
    private let placeholder = NSStackView()
    private(set) weak var mounted: NSView?
    init(slot: GroupSlot, host: WorkspaceWindowController) {
        self.slot = slot
        self.host = host
        super.init(frame: .zero)
        strip.host = host
        strip.groupSlot = slot
        heading.isBordered = false
        heading.alignment = .left
        heading.target = self
        heading.action = #selector(focusGroup(_:))
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let label = NSTextField(wrappingLabelWithString: "Open a document or create a new one.")
        let new = NSButton(title: "New", target: self, action: #selector(newDocument(_:)))
        let open = NSButton(title: "Open…", target: self, action: #selector(openDocument(_:)))
        placeholder.orientation = .vertical
        placeholder.spacing = 8
        [label, new, open].forEach { placeholder.addArrangedSubview($0) }
        [heading, strip, content].forEach { addSubview($0) }
        content.addSubview(placeholder)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    @objc private func focusGroup(_ sender: Any?) { host?.focusGroup(slot) }
    @objc private func newDocument(_ sender: Any?) {
        host?.focusGroup(slot)
        NSDocumentController.shared.newDocument(sender)
    }
    @objc private func openDocument(_ sender: Any?) {
        host?.focusGroup(slot)
        NSDocumentController.shared.openDocument(sender)
    }
    override func mouseDown(with event: NSEvent) { host?.focusGroup(slot) }
    func refresh() {
        strip.groupSlot = slot
        strip.refresh()
        let name = host?.groupLabel(slot) ?? "Group \(slot.rawValue)"
        let focused = host?.model.focusedGroup == slot
        heading.title = (focused ? "▶ " : "   ") + name
        heading.setAccessibilityLabel(name + (focused ? ", focused" : ""))
        setAccessibilityLabel("Editor " + name.lowercased())
        needsLayout = true
    }
    func mount(_ root: NSView?) {
        if mounted !== root {
            mounted?.removeFromSuperview()
            mounted = root
            if let root { content.addSubview(root) }
        }
        placeholder.isHidden = root != nil
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let h = min(20, bounds.height)
        heading.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        strip.frame = NSRect(x: 0, y: max(0, bounds.height - h - 36), width: bounds.width, height: 36)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - h - 36))
        mounted?.frame = content.bounds
        placeholder.frame = NSRect(
            x: 12, y: max(0, (content.bounds.height - 110) / 2), width: max(0, content.bounds.width - 24), height: 110)
    }
}

final class EditorGroupContainer: NSView, NSSplitViewDelegate {
    private var root: NSView?
    private var splitMinimum: [ObjectIdentifier: CGFloat] = [:]
    private(set) var dividers: [NSSplitView] = []
    func configure(_ layout: LayoutKind, surfaces: [EditorGroupSurface]) {
        surfaces.forEach { $0.removeFromSuperview() }
        root?.removeFromSuperview()
        dividers = []
        splitMinimum = [:]
        func split(_ vertical: Bool, _ children: [NSView], minimum: CGFloat) -> NSSplitView {
            let v = NSSplitView()
            v.isVertical = vertical
            v.dividerStyle = .thin
            v.delegate = self
            children.forEach { v.addArrangedSubview($0) }
            splitMinimum[ObjectIdentifier(v)] = minimum
            dividers.append(v)
            return v
        }
        switch layout {
        case .single: root = surfaces[0]
        case .twoColumns: root = split(true, surfaces, minimum: 320)
        case .twoRows: root = split(false, surfaces, minimum: 200)
        case .grid2x2:
            let top = split(true, Array(surfaces[0...1]), minimum: 320)
            let bottom = split(true, Array(surfaces[2...3]), minimum: 320)
            root = split(false, [top, bottom], minimum: 200)
        }
        if let root {
            addSubview(root)
            root.frame = bounds
            root.autoresizingMask = [.width, .height]
        }
        needsLayout = true
        // Native dividers retain their positions until configure is called for a layout change.
        layoutSubtreeIfNeeded()
        dividers.reversed().forEach {
            $0.adjustSubviews()
            $0.setPosition(($0.isVertical ? $0.bounds.width : $0.bounds.height) / 2, ofDividerAt: 0)
        }
    }
    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat { max(proposedMinimumPosition, splitMinimum[ObjectIdentifier(splitView)] ?? 0) }
    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(
            proposedMaximumPosition,
            (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height)
                - (splitMinimum[ObjectIdentifier(splitView)] ?? 0) - splitView.dividerThickness)
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
}
