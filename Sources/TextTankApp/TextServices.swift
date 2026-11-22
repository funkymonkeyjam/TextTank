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

    private final class Choice: NSObject {
        var selectedID: UUID?

        @objc func selectItem(_ sender: NSMenuItem) {
            selectedID = sender.representedObject as? UUID
        }
    }

    private static func chooseAutomation(_ choices: [AutomationDefinition]) -> AutomationDefinition? {
        let selection = Choice()
        let menu = NSMenu(title: "Run TextTank Automation")
        menu.addItem(.sectionHeader(title: "Run on Selected Text"))
        for workflow in choices {
            let item = menu.addItem(
                withTitle: "Run “\(workflow.name)”", action: #selector(Choice.selectItem(_:)), keyEquivalent: "")
            item.target = selection
            item.representedObject = workflow.id
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cancel", action: #selector(Choice.selectItem(_:)), keyEquivalent: "").target =
            selection
        // Services needs its pasteboard reply before returning. Native menu tracking waits for
        // this invocation's explicit choice while allowing Escape or a click outside to cancel.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return choices.first { $0.id == selection.selectedID }
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
            let latest = try AutomationLibrary.forSuppliedText()
            guard let workflow = latest.workflows.first(where: { $0.id == chosen.id }),
                try AutomationLibrary(workflows: [workflow]).encoded()
                    == AutomationLibrary(workflows: [chosen]).encoded()
            else {
                throw AutomationError.invalid(
                    "The saved automation changed while you were choosing it. Try the service again.")
            }
            try workflow.requireSuppliedText()
            let result = try workflow.transform(input)
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
