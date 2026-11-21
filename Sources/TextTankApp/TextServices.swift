import AppKit
import TextTankCore

/// Services supplies an invocation pasteboard. The general clipboard is independent of this exchange.
@MainActor final class TextServices: NSObject {
    private let newDocument: @MainActor (String) -> Void
    private let choose: @MainActor ([AutomationDefinition]) -> AutomationDefinition?

    init(
        newDocument: @escaping @MainActor (String) -> Void,
        choose: (@MainActor ([AutomationDefinition]) -> AutomationDefinition?)? = nil
    ) {
        self.newDocument = newDocument
        self.choose = choose ?? Self.chooseAutomation
    }

    private static func chooseAutomation(_ choices: [AutomationDefinition]) -> AutomationDefinition? {
        let popup = NSPopUpButton(frame: .init(x: 0, y: 0, width: 320, height: 28))
        for choice in choices { popup.menu?.addItem(NSMenuItem(title: choice.name, action: nil, keyEquivalent: "")) }
        popup.selectItem(at: 0)
        popup.setAccessibilityLabel("Saved automation")
        let alert = TTAlert()
        alert.messageText = "Run a TextTank automation on the selected text"
        alert.informativeText = "The result is returned to the app that supplied the selection."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel", role: .cancel)
        guard alert.runModal() == .alertFirstButtonReturn, choices.indices.contains(popup.indexOfSelectedItem) else {
            return nil
        }
        return choices[popup.indexOfSelectedItem]
    }

    private func selection(_ board: NSPasteboard) throws -> String {
        guard let text = board.string(forType: .string) else {
            throw AutomationError.invalid("The service requires selected plain text.")
        }
        return text
    }

    @objc(newTextTankDocument:userData:error:)
    func newTextTankDocument(
        _ board: NSPasteboard, userData: String?, error failure: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        do { newDocument(try selection(board)) } catch { failure.pointee = error.localizedDescription as NSString }
    }

    @objc(runTextTankAutomation:userData:error:)
    func runTextTankAutomation(
        _ board: NSPasteboard, userData: String?, error failure: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        do {
            let generation = board.changeCount
            let input = try selection(board)
            let library = try AutomationLibrary.forSuppliedText()
            let options = library.workflows.filter { (try? $0.requireSuppliedText()) != nil }
            guard !options.isEmpty else {
                throw AutomationError.invalid(
                    "No saved automation accepts supplied text without a prompt or external output.")
            }
            guard let chosen = choose(options) else { return }
            try chosen.requireSuppliedText()
            let result = try chosen.transform(input)
            guard board.changeCount == generation, let current = board.string(forType: .string),
                current.utf8.elementsEqual(input.utf8)
            else {
                throw AutomationError.invalid("The calling app changed its selection during the service.")
            }
            guard board.setString(result, forType: .string) else {
                throw AutomationError.invalid("The calling app could not receive the transformed text.")
            }
        } catch { failure.pointee = error.localizedDescription as NSString }
    }
}
