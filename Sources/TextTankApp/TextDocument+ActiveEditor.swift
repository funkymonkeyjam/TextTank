import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

extension TextDocument {
    /// The view of this document the person last worked in: the focused pane of a split view,
    /// otherwise the primary view. Views share one document; focus remains per presentation.
    var activeEditor: TTEditor { presentation?.activeEditor ?? editor }
}
