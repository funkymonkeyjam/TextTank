// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension AutomationDefinition {
    /// Explicit, editable rules for the user's four supplied ingredient examples.
    /// Loaded into a draft only; existing saved automations are never migrated.
    /// Preserves the earlier Markdown/browser cleanup rules. Section labels ending
    /// with a colon are removed by a visible, bounded whole-line pattern; ordinary
    /// unmarked ingredient rows are retained. Only the four explicitly listed note
    /// suffixes are removed beyond ordinary Note-number references. Parenthetical
    /// quantities/substitutions remain intact; this is not arbitrary-recipe inference.
    static var shoppingRecipeSteps:[Step] {
        [
            .init(kind:.removeMatchingLines,find:#"(?i)^[ \t]*(?:Ingredients|Cups|Metric|Garnish[ \t]*\(optional\))[ \t]*$"#),
            .init(kind:.removeMatchingLines,find:#"^[ \t]*[\p{L}][^:]*:[ \t]*$"#),
            .init(kind:.removeMarkdownHeadings),
            .init(kind:.removeLinesEqualTo,find:"Yellow Rice"),
            .init(kind:.removeLinesEqualTo,find:"Chicken Shawarma"),
            .init(kind:.removeLinesEqualTo,find:"White Sauce"),
            .init(kind:.removeLinesEqualTo,find:"Toppings"),
            .init(kind:.removeListMarkers),.init(kind:.removeMarkdownFormatting),
            .init(kind:.removeCheckboxMarkers),.init(kind:.removeNoteReferences),
            .init(kind:.replaceLiteral,find:" (do not use white button mushrooms, as they have far less flavor), finely chopped",replacement:""),
            .init(kind:.replaceLiteral,find:" , (cut in half lengthways)",replacement:""),
            .init(kind:.replaceLiteral,find:" , (chopped)",replacement:""),
            .init(kind:.replaceLiteral,find:" , (optional)",replacement:""),
            .init(kind:.trimWhitespace),.init(kind:.removeBlankLines)
        ]
    }
}
