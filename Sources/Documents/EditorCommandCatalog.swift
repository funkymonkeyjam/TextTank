// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Stable editor identifiers are storage and bridge contracts. Menu placement remains literal;
/// recording and shortcut assignment are explicit security/behavior subsets, never inferred from a title.
package enum EditorCommand: String, CaseIterable {
    case addNextOccurrence, backTab, bookmarkNext, bookmarkPrevious, bookmarkToggle, cancel, charLeft, charLeftExtend,
        charRight, charRightExtend, clearAdditionalSelections, copy, cut, deleteBack, deleteForward, deleteLine,
        deleteLineLeft, deleteLineRight, deleteWordLeft, deleteWordRight, documentEnd, documentEndExtend, documentStart,
        documentStartExtend, duplicateLine, duplicateSelection, foldAll, gotoMatchingBrace, home, homeDisplay,
        homeExtend, indent, joinLines, lineCopy, lineCut, lineDown, lineDownExtend, lineEnd, lineEndDisplay,
        lineEndExtend, lineUp, lineUpExtend, lower, moveLineDown, moveLineUp, newLine, pageDown, pageDownExtend, pageUp,
        pageUpExtend, paraDown, paraDownExtend, paraUp, paraUpExtend, paste, rectangularSelection, redo, selectAll,
        selectAllOccurrences, selectMatchingBrace, showWhitespace, streamSelection, tab, toggleEOL, toggleLineNumbers,
        toggleOvertype, transposeLine, trimTrailing, undo, unfoldAll, unindent, upper, vcHome, vcHomeExtend, wordLeft,
        wordLeftExtend, wordPartLeft, wordPartLeftExtend, wordPartRight, wordPartRightExtend, wordRight,
        wordRightExtend, zoomIn, zoomOut
    package var isRecordable: Bool {
        switch self {
        case .backTab, .cancel, .charLeft, .charLeftExtend, .charRight, .charRightExtend, .copy, .cut, .deleteBack,
            .deleteForward, .deleteLine, .deleteLineLeft, .deleteLineRight, .deleteWordLeft, .deleteWordRight,
            .documentEnd, .documentEndExtend, .documentStart, .documentStartExtend, .duplicateLine, .duplicateSelection,
            .home, .homeDisplay, .homeExtend, .indent, .lineCopy, .lineCut, .lineDown, .lineDownExtend, .lineEnd,
            .lineEndDisplay, .lineEndExtend, .lineUp, .lineUpExtend, .lower, .moveLineDown, .moveLineUp, .newLine,
            .pageDown, .pageDownExtend, .pageUp, .pageUpExtend, .paraDown, .paraDownExtend, .paraUp, .paraUpExtend,
            .paste, .selectAll, .tab, .transposeLine, .unindent, .upper, .vcHome, .vcHomeExtend, .wordLeft,
            .wordLeftExtend, .wordPartLeft, .wordPartLeftExtend, .wordPartRight, .wordPartRightExtend, .wordRight,
            .wordRightExtend:
            return true
        default: return false
        }
    }
    package var isViewOnly: Bool {
        switch self {
        case .foldAll, .showWhitespace, .toggleEOL, .toggleLineNumbers, .unfoldAll, .zoomIn, .zoomOut: return true
        default: return false
        }
    }
    package var isShortcutAssignable: Bool {
        switch self {
        case .bookmarkNext, .bookmarkPrevious, .bookmarkToggle, .deleteLine, .duplicateLine, .joinLines, .lower,
            .moveLineDown, .moveLineUp, .transposeLine, .trimTrailing, .upper:
            return true
        default: return false
        }
    }
    package var isToggle: Bool {
        switch self {
        case .showWhitespace, .toggleEOL, .toggleLineNumbers, .toggleOvertype, .bookmarkToggle,
            .rectangularSelection, .streamSelection:
            return true
        default: return false
        }
    }
    package var title: String {
        switch self {
        case .addNextOccurrence: return "Add Next Occurrence"
        case .backTab: return "Back Tab"
        case .bookmarkNext: return "Next Bookmark"
        case .bookmarkPrevious: return "Previous Bookmark"
        case .bookmarkToggle: return "Toggle Bookmark"
        case .cancel: return "Clear Additional Selections"
        case .charLeft: return "Move Left"
        case .charLeftExtend: return "Char Left Extend"
        case .charRight: return "Move Right"
        case .charRightExtend: return "Char Right Extend"
        case .clearAdditionalSelections: return "Clear Additional Selections"
        case .copy: return "Copy"
        case .cut: return "Cut"
        case .deleteBack: return "Delete Backward"
        case .deleteForward: return "Delete Forward"
        case .deleteLine: return "Delete Line"
        case .deleteLineLeft: return "Delete to Line Start"
        case .deleteLineRight: return "Delete to Line End"
        case .deleteWordLeft: return "Delete Word Left"
        case .deleteWordRight: return "Delete Word Right"
        case .documentEnd: return "Move to Document End"
        case .documentEndExtend: return "Document End Extend"
        case .documentStart: return "Move to Document Start"
        case .documentStartExtend: return "Document Start Extend"
        case .duplicateLine: return "Duplicate Line"
        case .duplicateSelection: return "Duplicate Selection"
        case .foldAll: return "Fold All"
        case .gotoMatchingBrace: return "Matching Brace"
        case .home: return "Move to Line Start"
        case .homeDisplay: return "Home Display"
        case .homeExtend: return "Home Extend"
        case .indent: return "Indent"
        case .joinLines: return "Join Selected Lines"
        case .lineCopy: return "Copy Line"
        case .lineCut: return "Cut Line"
        case .lineDown: return "Move Down"
        case .lineDownExtend: return "Line Down Extend"
        case .lineEnd: return "Move to Line End"
        case .lineEndDisplay: return "Line End Display"
        case .lineEndExtend: return "Line End Extend"
        case .lineUp: return "Move Up"
        case .lineUpExtend: return "Line Up Extend"
        case .lower: return "Lowercase"
        case .moveLineDown: return "Move Line Down"
        case .moveLineUp: return "Move Line Up"
        case .newLine: return "Insert New Line"
        case .pageDown: return "Page Down"
        case .pageDownExtend: return "Page Down Extend"
        case .pageUp: return "Page Up"
        case .pageUpExtend: return "Page Up Extend"
        case .paraDown: return "Para Down"
        case .paraDownExtend: return "Para Down Extend"
        case .paraUp: return "Para Up"
        case .paraUpExtend: return "Para Up Extend"
        case .paste: return "Paste"
        case .rectangularSelection: return "Rectangular Selection"
        case .redo: return "Redo"
        case .selectAll: return "Select All"
        case .selectAllOccurrences: return "Select All Occurrences"
        case .selectMatchingBrace: return "Select to Matching Brace"
        case .showWhitespace: return "Show Whitespace"
        case .streamSelection: return "Stream Selection"
        case .tab: return "Insert Tab"
        case .toggleEOL: return "Show Line Endings"
        case .toggleLineNumbers: return "Show Line Numbers"
        case .toggleOvertype: return "Toggle Overtype"
        case .transposeLine: return "Transpose Lines"
        case .trimTrailing: return "Trim Trailing Whitespace"
        case .undo: return "Undo"
        case .unfoldAll: return "Unfold All"
        case .unindent: return "Unindent"
        case .upper: return "Uppercase"
        case .vcHome: return "Move to First Text on Line"
        case .vcHomeExtend: return "Select to First Text on Line"
        case .wordLeft: return "Move One Word Left"
        case .wordLeftExtend: return "Word Left Extend"
        case .wordPartLeft: return "Word Part Left"
        case .wordPartLeftExtend: return "Word Part Left Extend"
        case .wordPartRight: return "Word Part Right"
        case .wordPartRightExtend: return "Word Part Right Extend"
        case .wordRight: return "Move One Word Right"
        case .wordRightExtend: return "Word Right Extend"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        }
    }
    static package let recordableIdentifiers = Set(allCases.filter(\.isRecordable).map(\.rawValue))
    static package let viewOnlyIdentifiers = Set(allCases.filter(\.isViewOnly).map(\.rawValue))
    static package let shortcutIdentifiers = Set(allCases.filter(\.isShortcutAssignable).map(\.rawValue))
    static package let defaultShortcuts: [String: String] = [EditorCommand.duplicateLine.rawValue: "d"]
    package var defaultShortcut: String { Self.defaultShortcuts[rawValue] ?? "" }
    /// Fixed system/editor menu keys remain distinct from assignable override defaults.
    package var defaultMenuShortcut: String {
        switch self {
        case .undo: return "z"
        case .redo: return "Z"
        case .cut: return "x"
        case .copy: return "c"
        case .paste: return "v"
        case .selectAll: return "a"
        case .indent: return "]"
        case .unindent: return "["
        case .zoomIn: return "+"
        case .zoomOut: return "-"
        default: return defaultShortcut
        }
    }
}

/// An invalid routed identifier never changes the editor or starts a recording action.
package enum EditorCommandFailure: LocalizedError {
    case unsupported
    package var errorDescription: String? {
        "This editor command is unavailable. Nothing was changed. Choose another command from the menu."
    }
}
