@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import EditorBridge
import NativeSearch

/// Old dialog checks now drive the actual modeless window after the command returns.
/// The modal-panel run-loop mode delivers their existing owned timers, not an app-modal session.
var presentedFormWindow: NSWindow? {
    if let modal = NSApp.modalWindow { return modal }
    var window = FormPanel.frontWindow
    while let sheet = window?.attachedSheet { window = sheet }
    return window
}
func waitForModelessForms(
    timeout: TimeInterval = 10, excluding: Set<ObjectIdentifier> = [], file: StaticString = #filePath,
    line: UInt = #line
) {
    let deadline = Date().addingTimeInterval(timeout)
    func pending() -> [FormPanel] { FormPanel.visible.filter { !excluding.contains(ObjectIdentifier($0)) } }
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
