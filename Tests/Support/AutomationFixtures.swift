@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
// A recipe-shaped automation for checks. The app ships no recipe automation; a suite that
// needs a strict marker-based cleanup adds this file to its swiftc line. The identifier and
// name are the fixture's own, so launching a controller never retires it as a factory item.
import Foundation

extension AutomationDefinition {
    static var recipeFixture: AutomationDefinition {
        AutomationDefinition(
            id: UUID(uuidString: "5C0FFEE5-7E57-4F1C-8A5E-0123456789AB")!, name: "Recipe cleanup fixture",
            input: .document,
            steps: [
                Step(kind: .clearLinesMatching, find: recipeHeadingPattern),
                Step(kind: .keepMarkedListRows), Step(kind: .clearMarkdownHeadings), Step(kind: .removeListMarkers),
                Step(kind: .removeMarkdownFormatting), Step(kind: .removeCheckboxMarkers),
                Step(kind: .removeNoteReferences), Step(kind: .trimWhitespace), Step(kind: .removeBlankLines)
            ],
            output: .editor, previewBeforeApply: false, pinToToolbar: true)
    }
}
