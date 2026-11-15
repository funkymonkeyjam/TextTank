// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// An auxiliary tool window: Find and Replace, Find in Folder, the Function List, a Run result.
///
/// A panel cannot become main, so the document window stays main while the tool window is key
/// and the document's menu commands (Save, Convert Encoding, Close Split View) keep working.
/// It does not float and it stays on screen when the application is deactivated: a long folder
/// search or a command's output must not vanish when the person switches to another app.
final class ToolPanel: NSPanel {
    /// Asked when Escape is pressed. Returning false keeps the panel open, for a window whose
    /// closing would stop running work or discard a result that has not been applied.
    var allowsEscapeToClose: () -> Bool = { true }
    /// AppKit leaves panels out of the Window menu. A panel with no command that shows it again
    /// (the Function List, a Run result) sets this, so that it can still be reached when the
    /// document window covers it. AppKit removes the item when the panel is hidden or closed.
    var listedInWindowMenu = false
    init(contentRect: NSRect, styleMask: NSWindow.StyleMask) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        hidesOnDeactivate = false
        isFloatingPanel = false
    }
    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        listInWindowMenu()
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        listInWindowMenu()
    }
    private func listInWindowMenu() {
        // Adds the item, or only renames it when the panel already has one.
        if listedInWindowMenu, isVisible { NSApp.changeWindowsItem(self, title: title, filename: false) }
    }
    override func cancelOperation(_ sender: Any?) {
        guard allowsEscapeToClose() else {
            NSSound.beep()
            return
        }
        // The same path as the close button and File > Close, so the delegate is told.
        performClose(sender)
    }
}

/// A result list whose selected row can be opened from the keyboard. A double-click keeps using
/// the table's own `doubleAction` and `clickedRow`; this adds only Return and Enter, and only
/// while the table itself has keyboard focus.
final class ActivatingTableView: NSTableView {
    var onActivate: ((Int) -> Void)?
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty, selectedRow >= 0, let onActivate {
            onActivate(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

/// Remembers window positions across launches under a name per kind of window.
///
/// AppKit's own frame autosave allows one window per name at a time. Document tabs are separate
/// windows that share one frame, and a Function List or Run result window is created anew each
/// time, so the frame is saved here whenever a visible window with the name moves or is resized.
enum WindowFrames {
    /// Where frames are kept. Only the bundled application keeps them: a check executable has no
    /// bundle identifier, so a check run neither reads nor leaves window positions unless it
    /// supplies defaults of its own.
    static var defaults: UserDefaults? = Bundle.main.bundleIdentifier == nil ? nil : .standard
    private static var trackerKey = 0

    static func defaultsKey(_ name: String) -> String { "TextTank Window Frame " + name }
    static func description(of window: NSWindow) -> String { NSStringFromRect(window.frame) }
    /// A saved frame is used only if enough of it is on a screen that is connected now to see
    /// the window and take hold of its title bar.
    static func isUsable(_ frame: NSRect) -> Bool {
        guard frame.width >= 100, frame.height >= 100 else { return false }
        return NSScreen.screens.contains { screen in
            let visible = screen.visibleFrame.intersection(frame)
            return visible.width >= 100 && visible.height >= 100 && frame.maxY <= screen.visibleFrame.maxY + 1
        }
    }
    /// Applies the frame saved under `name`, if there is one, and keeps it saved from now on.
    static func track(_ window: NSWindow, as name: String) {
        guard let defaults else { return }
        if let saved = defaults.string(forKey: defaultsKey(name)).map(NSRectFromString), isUsable(saved) {
            window.setFrame(saved, display: false)
            // A restored position is where the person left the window; do not offset it.
            window.windowController?.shouldCascadeWindows = false
        }
        objc_setAssociatedObject(
            window, &trackerKey, FrameTracker(window: window, name: name, defaults: defaults),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private final class FrameTracker: NSObject {
    private weak var window: NSWindow?
    private let name: String, defaults: UserDefaults
    init(window: NSWindow, name: String, defaults: UserDefaults) {
        self.window = window
        self.name = name
        self.defaults = defaults
        super.init()
        for notification in [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(save), name: notification, object: window)
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func save() {
        // A hidden document tab keeps whatever frame it had when it was last shown.
        guard let window, window.isVisible, !window.inLiveResize else { return }
        defaults.set(WindowFrames.description(of: window), forKey: WindowFrames.defaultsKey(name))
    }
}
