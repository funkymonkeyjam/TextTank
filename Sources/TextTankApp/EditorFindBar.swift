import AppKit
import EditorBridge
import NativeSearch
import TextTankCore

/// All native Find actions remain visible at a group's 320-point minimum (DS-35,70-74).
final class EditorFindBar: NSView {
    private let controls: [NSView]
    init(controls: [NSView]) {
        self.controls = controls
        super.init(frame: .zero)
        controls.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    private var compact: Bool { bounds.width < 852 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: compact ? 74 : 24) }
    override func setFrameSize(_ newSize: NSSize) {
        let wasCompact = compact
        super.setFrameSize(newSize)
        if wasCompact != compact { invalidateIntrinsicContentSize() }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard controls.count == 7 else { return }
        let w = bounds.width
        if compact {
            controls[0].frame = NSRect(x: 0, y: 52, width: max(0, w - 54), height: 22)
            controls[5].frame = NSRect(x: max(0, w - 50), y: 52, width: 50, height: 22)
            controls[1].frame = NSRect(x: 0, y: 26, width: max(0, w - 136), height: 22)
            controls[4].frame = NSRect(x: max(0, w - 132), y: 26, width: 132, height: 22)
            controls[2].frame = NSRect(x: 0, y: 0, width: 110, height: 22)
            controls[3].frame = NSRect(x: 114, y: 0, width: 60, height: 22)
            controls[6].frame = NSRect(x: 180, y: 0, width: max(0, w - 180), height: 22)
        } else {
            let widths: [CGFloat] = [max(160, w - 678), 150, 100, 58, 126, 48, 120]
            var x: CGFloat = 0
            for (control, width) in zip(controls, widths) {
                control.frame = NSRect(x: x, y: 0, width: width, height: 24)
                x += width + 8
            }
        }
    }
}

/// A preview owns only its temporary indicator and a selection it can still identify.
@MainActor final class InlineFindPreview {
    weak var editor: TTEditor?
    let revision: UInt
    private static let paintLineLimit = 1_048_576
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
                publish: @escaping @MainActor (String, String?) -> Void) {
        cancelPending()
        guard !options.query.isEmpty else { clearHighlights(); restoreSelection(); publish("", nil); return }
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
                    try SearchController.preview(data, options: options, openingCaret: caret, cancellation: flag)
                }.value
                guard !flag.cancelled, isCurrent(), EditorLifetime.isOpen(editor), editor.revision == self.revision else { return }
                let detail = self.show(result, in: editor, openingLineLength: lineLength)
                publish(result.countText, detail)
            } catch {
                guard !flag.cancelled, isCurrent() else { return }
                self?.clearHighlights()
                self?.restoreSelection()
                publish(error.localizedDescription, nil)
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
