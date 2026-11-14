// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Native ordered-step editing. Changes remain local until the caller saves the definition.
final class AutomationStepEditor {
    static func edit(_ original: AutomationDefinition) -> AutomationDefinition? {
        var draft = original
        while true {
            let alert = NSAlert(); alert.messageText = "Processing Steps — \(draft.name)"
            alert.informativeText = "Steps run from top to bottom. Add, edit, move or remove a step. Done returns the draft to the automation settings; Cancel discards these step edits."
            for title in ["Done", "Cancel", "Add", "Edit", "Move Up", "Move Down", "Remove"] { alert.addButton(withTitle:title) }
            let list = NSPopUpButton(frame:NSRect(x:0,y:0,width:560,height:28),pullsDown:false)
            for (index,step) in draft.steps.enumerated() {
                list.addItem(withTitle:"\(index + 1). \(step.kind.rawValue)\(step.find.map { " — " + $0.prefix(60) } ?? "")")
            }
            alert.accessoryView = list
            let choice = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let index = list.indexOfSelectedItem
            switch choice {
            case 0: return draft
            case 1: return nil
            case 2:
                if let step = editStep(.init(kind:.removeBlankLines)) { draft.steps.append(step) }
            case 3:
                if draft.steps.indices.contains(index),let step = editStep(draft.steps[index]) { draft.steps[index] = step }
            case 4:
                if index > 0 { draft.steps.swapAt(index,index-1) }
            case 5:
                if index >= 0,index + 1 < draft.steps.count { draft.steps.swapAt(index,index+1) }
            case 6:
                if draft.steps.indices.contains(index) { draft.steps.remove(at:index) }
            default: return nil
            }
        }
    }
    static func editStep(_ initial: AutomationDefinition.Step) -> AutomationDefinition.Step? {
        let alert = NSAlert(); alert.messageText = "Edit Processing Step"
        alert.informativeText = "Find applies to literal replacement and whole-line regex removal. Replacement applies only to literal replacement. Ask-at-run values use the saved text as a default and never execute code."
        alert.addButton(withTitle:"Save Step"); alert.addButton(withTitle:"Cancel")
        let kind = NSPopUpButton(); for value in AutomationDefinition.Step.Kind.allCases { kind.addItem(withTitle:value.rawValue) }; kind.selectItem(withTitle:initial.kind.rawValue)
        let find = NSTextField(string:initial.find ?? ""), replacement = NSTextField(string:initial.replacement ?? "")
        let askFind = NSButton(checkboxWithTitle:"Ask for Find each time",target:nil,action:nil), askReplacement = NSButton(checkboxWithTitle:"Ask for Replacement each time",target:nil,action:nil)
        askFind.state = initial.askForFind == true ? .on : .off; askReplacement.state = initial.askForReplacement == true ? .on : .off
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        for (label,control) in [("Step",kind as NSView),("Find",find),("Replacement",replacement)] {
            let row = NSStackView(views:[NSTextField(labelWithString:label),control]); control.widthAnchor.constraint(equalToConstant:430).isActive = true; stack.addArrangedSubview(row)
        }
        stack.addArrangedSubview(askFind); stack.addArrangedSubview(askReplacement); stack.frame = NSRect(x:0,y:0,width:560,height:170); alert.accessoryView = stack
        while alert.runModal() == .alertFirstButtonReturn {
            alert.window.makeFirstResponder(nil)
            guard let value = kind.titleOfSelectedItem, let typed = AutomationDefinition.Step.Kind(rawValue:value) else { return nil }
            let needsFind = typed == .replaceLiteral || typed == .removeMatchingLines
            let step = AutomationDefinition.Step(kind:typed,find:needsFind ? find.stringValue : nil,replacement:typed == .replaceLiteral ? replacement.stringValue : nil,askForFind:needsFind && askFind.state == .on,askForReplacement:typed == .replaceLiteral && askReplacement.state == .on)
            var probe = AutomationDefinition.example; probe.steps = [step]
            do { try probe.validate(); return step } catch { NSAlert(error:error).runModal() }
        }
        return nil
    }
}
