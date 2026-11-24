// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

/// Lays out one tab's source and preview for Source, Preview and Both.
///
/// The source view (the tab's own split view, which holds the editor and its clone) is always
/// the first arranged subview and is never removed or rebuilt: Preview only hides it, so its
/// selection, scroll position and clone split are untouched. The preview pane is added while
/// the tab shows Preview or Both and removed for Source.
///
/// In Both the divider can be dragged. `sourceFraction` is the source's share of the width; it
/// changes only when the person drags the divider, so resizing the window keeps the proportion.
/// Each pane keeps at least `minimumPaneWidth` while there is room for two; below that the
/// width is shared equally, so the panes never overlap (DS-67).
@MainActor final class DocumentViewContainer: NSSplitView, NSSplitViewDelegate {
    static let minimumPaneWidth: CGFloat = 120

    let source: NSView
    private(set) var preview: NSView?
    private(set) var mode = DocumentViewMode.source
    /// The source's share of the width in Both, from 0 to 1. Setting it lays the panes out again.
    var sourceFraction: Double {
        get { storedFraction }
        set {
            storedFraction = min(1, max(0, newValue))
            if mode == .both { adjustSubviews() }
        }
    }
    private var storedFraction = 0.5

    init(source: NSView) {
        self.source = source
        super.init(frame: .zero)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(source)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Shows `mode`. `preview` is the pane for Preview and Both, and nil for Source.
    func show(_ mode: DocumentViewMode, preview: NSView?) {
        precondition((mode == .source) == (preview == nil), "Source has no preview pane; the other modes have one")
        if self.preview !== preview {
            self.preview?.removeFromSuperview()
            self.preview = preview
            if let preview { addArrangedSubview(preview) }
        }
        self.mode = mode
        source.isHidden = mode == .preview
        adjustSubviews()
        layoutSubtreeIfNeeded()
    }

    // MARK: Layout

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard let preview, mode == .both else {
            // One pane fills the tab. A hidden source keeps its last frame, and with it the
            // widths of its own panes.
            (mode == .preview ? self.preview : source)?.frame = bounds
            return
        }
        let available = max(0, bounds.width - dividerThickness)
        let sourceWidth = Self.sourceWidth(available: available, fraction: sourceFraction)
        source.frame = NSRect(x: 0, y: 0, width: sourceWidth, height: bounds.height)
        preview.frame = NSRect(
            x: sourceWidth + dividerThickness, y: 0, width: available - sourceWidth, height: bounds.height)
    }

    /// The width given to the source when `available` points are shared by the two panes.
    static func sourceWidth(available: CGFloat, fraction: Double) -> CGFloat {
        guard available >= 2 * minimumPaneWidth else { return (available / 2).rounded(.down) }
        let wanted = (available * CGFloat(min(1, max(0, fraction)))).rounded()
        return min(available - minimumPaneWidth, max(minimumPaneWidth, wanted))
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat { max(Self.minimumPaneWidth, proposedMinimumPosition) }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat { min(proposedMaximumPosition, bounds.width - dividerThickness - Self.minimumPaneWidth) }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    /// Remembers the proportion only when the person moved the divider.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard mode == .both, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        let available = bounds.width - dividerThickness
        guard available >= 2 * Self.minimumPaneWidth else { return }
        // Stored without laying out again: the split view has just placed the panes itself.
        storedFraction = min(1, max(0, Double(source.frame.width / available)))
    }
}

/// The View menu commands that choose what a tab shows.
@MainActor enum DocumentViewCommands {
    static func title(_ mode: DocumentViewMode) -> String {
        switch mode {
        case .source: return Strings.text("view.mode.source", "Source")
        case .preview: return Strings.text("view.mode.preview", "Preview")
        case .both: return Strings.text("view.mode.both", "Both")
        }
    }

    static let toggleTitle = Strings.text("view.mode.toggle", "Toggle Preview")
    /// Shift-Command-V. It is a default that gives way to a shortcut the person assigned to the
    /// same key in Settings, as Save All and Actual Size do, so a settings file that already
    /// uses Shift-Command-V keeps working (DS-25 is not involved: no system shortcut has this key).
    static let toggleShortcut = MenuShortcut("V")

    /// Adds Source, Preview and Both, then Toggle Preview and a separator. The items go to the
    /// first responder; the active tab validates them, with a checkmark on the mode it shows
    /// (DS-22) and all four disabled for a document with no preview (DS-21).
    static func addItems(to menu: NSMenu) {
        for mode in DocumentViewMode.allCases {
            menu.addItem(
                title: title(mode), action: #selector(EditorWindowController.setDocumentViewMode(_:)),
                representedObject: mode.rawValue)
        }
        menu.addItem(
            title: toggleTitle, action: #selector(EditorWindowController.toggleDocumentPreview(_:)),
            fallback: toggleShortcut)
        menu.addItem(.separator())
    }
}
