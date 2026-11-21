import AppKit

/// All native Find actions remain visible at a group's 320-point minimum (DS-35,70-74).
final class EditorFindBar: NSView {
    private let controls: [NSView]
    init(controls: [NSView]) {
        self.controls = controls
        super.init(frame: .zero)
        controls.forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
    private var compact: Bool { bounds.width < 820 }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: compact ? 74 : 24) }
    override func setFrameSize(_ newSize: NSSize) {
        let wasCompact = compact
        super.setFrameSize(newSize)
        if wasCompact != compact { invalidateIntrinsicContentSize() }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard controls.count == 6 else { return }
        let w = bounds.width
        if compact {
            controls[0].frame = NSRect(x: 0, y: 52, width: max(0, w - 54), height: 22)
            controls[5].frame = NSRect(x: max(0, w - 50), y: 52, width: 50, height: 22)
            controls[1].frame = NSRect(x: 0, y: 26, width: max(0, w - 136), height: 22)
            controls[4].frame = NSRect(x: max(0, w - 132), y: 26, width: 132, height: 22)
            controls[2].frame = NSRect(x: 0, y: 0, width: 110, height: 22)
            controls[3].frame = NSRect(x: 114, y: 0, width: 60, height: 22)
        } else {
            let widths: [CGFloat] = [max(200, w - 590), 160, 110, 60, 132, 50]
            var x: CGFloat = 0
            for (control, width) in zip(controls, widths) {
                control.frame = NSRect(x: x, y: 0, width: width, height: 24)
                x += width + 8
            }
        }
    }
}
