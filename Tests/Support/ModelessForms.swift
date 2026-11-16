@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
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

/// Explicit effects owned by the native test host; production defaults remain unchanged.
enum NativeFixtureEnvironment {
    static var announcements: [String] = []
    static var recoveryFailureNotice: ((TextDocument, Error) -> Void)?
    private static var board: NSPasteboard?
    private static var previous: RuntimeDependencies?
    static func install() {
        precondition(!AppStorage.permitsLegacyDefaults, "Install owned support isolation before runtime effects")
        previous = RuntimeEnvironment.dependencies
        var effects = RuntimeDependencies()
        effects.windowAnimation = .none
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
