@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

/// Old dialog checks now drive the actual modeless window after the command returns.
/// The modal-panel run-loop mode delivers their existing owned timers, not an app-modal session.
@MainActor var presentedFormWindow: NSWindow? {
    if let modal = NSApp.modalWindow { return modal }
    var window = FormPanel.frontWindow
    while let sheet = window?.attachedSheet { window = sheet }
    return window
}
@MainActor func waitForModelessForms(
    timeout: TimeInterval = 10, excluding: Set<ObjectIdentifier> = [], file: StaticString = #filePath,
    line: UInt = #line
) {
    let deadline = Date().addingTimeInterval(timeout)
    @MainActor func pending() -> [FormPanel] { FormPanel.visible.filter { !excluding.contains(ObjectIdentifier($0)) } }
    while !pending().isEmpty && Date() < deadline {
        _ = RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.01))
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    if !pending().isEmpty {
        check(false, "modeless form completes through its native controls", file: file, line: line)
        for form in pending() { form.close() }
    }
}

/// Drives the real list → child editor → explicit outer Save/Cancel route. No product
/// compatibility controls or application-modal loop are involved.
@MainActor final class ManagerChildRoute {
    private let managerID: String, openerID: String, childID: String
    private let commit: Bool
    private var opened = false, sawChild = false
    init(managerID: String, openerID: String, childID: String, commit: Bool) {
        self.managerID = managerID
        self.openerID = openerID
        self.childID = childID
        self.commit = commit
    }
    func step(_ window: NSWindow, views: [NSView], edit: () -> Void) -> Bool {
        if window.identifier?.rawValue == managerID {
            if !opened {
                guard
                    let opener = views.compactMap({ $0 as? NSButton }).first(where: {
                        $0.identifier?.rawValue == openerID && $0.isEnabled
                    })
                else { return false }
                opened = true
                opener.performClick(nil)
            } else if sawChild {
                let id = managerID + (commit ? ".save" : ".cancel")
                guard
                    let button = views.compactMap({ $0 as? NSButton }).first(where: {
                        $0.identifier?.rawValue == id && $0.isEnabled
                    })
                else { return false }
                button.performClick(nil)
                return !window.isVisible
            }
            return false
        }
        if window.identifier?.rawValue == childID {
            opened = true
            sawChild = true
        }
        edit()
        return false
    }
}

/// Explicit effects owned by the native test host; production defaults remain unchanged.
@MainActor enum NativeFixtureEnvironment {
    static var announcements: [String] = []
    static var recoveryFailureNotice: ((TextDocument, Error) -> Void)?
    private static var board: NSPasteboard?
    private static var previous: RuntimeDependencies?
    static func install() {
        WorkspaceRoom.simulateScreenFromEnvironment()
        precondition(!AppStorage.permitsLegacyDefaults, "Install owned support isolation before runtime effects")
        previous = RuntimeEnvironment.dependencies
        var effects = RuntimeDependencies()
        effects.windowAnimation = NSWindow.AnimationBehavior.none
        effects.document = {
            DocumentDependencies(recoveryFailureNotice: { document, error in
                guard let notice = recoveryFailureNotice else { return false }
                notice(document, error)
                return true
            })
        }
        effects.announce = { text, _ in announcements.append(text) }
        effects.readFindText = { findBoard().string(forType: .string) ?? "" }
        effects.writeFindText = { text in
            let pasteboard = findBoard()
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        effects.generalPasteboard = { nil }
        RuntimeEnvironment.dependencies = effects
    }
    private static func findBoard() -> NSPasteboard {
        if let board { return board }
        let created = NSPasteboard.withUniqueName()
        board = created
        return created
    }
    static func restore() {
        board?.releaseGlobally()
        board = nil
        announcements = []
        recoveryFailureNotice = nil
        RuntimeEnvironment.dependencies = previous
        previous = nil
    }
}

/// Room for the workspace window that does not depend on the display the checks run on.
///
/// The product asks its screen whether the docked sidebar, or an editor layout, fits. On a small
/// display (a hosted runner at about 1024 by 768) the sidebar's 1061-point minimum does not, so a
/// fixture that needs the sidebar shown must say what room its window has. `grant` does that
/// through the host's own injection point and returns the call that puts it back. The cases that
/// are deliberately too small keep injecting their own sizes.
///
/// What AppKit itself limits, measured on a titled window: a visible window's height is cut to
/// its screen on every resize; its width is not, except when a hidden window is ordered in, and
/// then never below `contentMinSize`; a hidden window is not limited at all. `resize` therefore
/// requires the width it asked for and reports the height it got.
///
/// `TEXTTANK_SIMULATED_SCREEN=WIDTHxHEIGHT` makes every workspace window in the process measure
/// against a display with that much content room, which is how a small runner is reproduced.
@MainActor enum WorkspaceRoom {
    static let generous = TabGroupExtent(width: 2400, height: 1400)
    static func simulateScreenFromEnvironment() {
        guard let text = ProcessInfo.processInfo.environment["TEXTTANK_SIMULATED_SCREEN"] else { return }
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        precondition(parts.count == 2 && parts.allSatisfy { $0 > 0 }, "TEXTTANK_SIMULATED_SCREEN must be WIDTHxHEIGHT")
        let size = TabGroupExtent(width: parts[0], height: parts[1])
        WorkspaceWindowController.simulatedScreenContent = { size }
        print("NOTE simulated screen content: \(Int(size.width)) by \(Int(size.height))")
    }
    /// Gives `host` room for any layout with the sidebar. Call the result to restore what was there.
    static func grant(_ host: WorkspaceWindowController, _ room: TabGroupExtent = generous) -> () -> Void {
        let previous = host.sidebarAvailableContent
        host.sidebarAvailableContent = { room }
        return { host.sidebarAvailableContent = previous }
    }
    /// Sets the window's content size. The width must be honoured; the height may be cut to the
    /// display by AppKit and is returned as it is.
    @discardableResult static func resize(
        _ window: NSWindow, to size: NSSize, file: StaticString = #filePath, line: UInt = #line
    ) throws -> NSSize {
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        let actual = window.contentView?.bounds.size ?? .zero
        try require(
            abs(actual.width - size.width) < 0.5,
            "fixture: the window is \(Int(size.width)) points wide whatever the display (got \(Int(actual.width)))",
            file: file, line: line)
        return actual
    }
}
