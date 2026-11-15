// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Shared explicit recovery for app-owned settings/libraries. Checks inject reveal; merely
/// loading an unreadable file never opens Finder, renames data, or retries a write.
enum StoreRecovery {
    static var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    static func ensureWritable(_ state: StoreLoadState, allowSymbolicLink: Bool = true) throws -> Bool {
        guard let error = state.error else { return true }
        let alert = TTAlert()
        alert.alertStyle = .warning
        alert.messageText = "TextTank could not read “\(state.displayName)”"
        alert.informativeText =
            "The entry at “\(state.url.path)” has not been changed. Reveal it in Finder, or move it aside to start again. Moving it aside renames the entry next to the original; nothing is deleted.\n\n\(error.localizedDescription)"
        let move = alert.addButton(withTitle: "Move Aside and Start Again")
        move.hasDestructiveAction = true
        move.identifier = NSUserInterfaceItemIdentifier("store.recover.move")
        alert.addButton(withTitle: "Reveal in Finder").identifier = NSUserInterfaceItemIdentifier(
            "store.recover.reveal")
        alert.addButton(withTitle: "Cancel", role: .cancel).identifier = NSUserInterfaceItemIdentifier(
            "store.recover.cancel")
        enum Choice { case move, reveal, cancel }
        switch alert.choice([Choice.move, .reveal, .cancel]) {
        case .move:
            try state.moveAside(allowSymbolicLink: allowSymbolicLink)
            return true
        case .reveal:
            reveal(state.url)
            return false
        default: return false
        }
    }
    static func confirmPreferenceReset(_ state: StoreLoadState) -> Bool {
        if state.error != nil {
            do { return try ensureWritable(state) } catch {
                TTAlert.present(error)
                return false
            }
        }
        let alert = TTAlert()
        alert.messageText = "Reset “\(state.displayName)”?"
        alert.informativeText =
            "This resets the saved search text, replacement text and options. Documents are not changed. Any previous settings file is moved aside, not deleted. An older shared preference entry is left untouched."
        let reset = alert.addButton(withTitle: "Reset Saved Settings")
        reset.hasDestructiveAction = true
        reset.identifier = NSUserInterfaceItemIdentifier("store.reset.confirm")
        alert.addButton(withTitle: "Cancel", role: .cancel).identifier = NSUserInterfaceItemIdentifier(
            "store.reset.cancel")
        enum Choice { case reset, cancel }
        return alert.choice([Choice.reset, .cancel]) == .reset
    }
}
