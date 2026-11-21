// SPDX-License-Identifier: GPL-3.0-or-later

/// Byte ceilings for operations on complete source and result snapshots. Input and
/// retained working storage are separate budgets, even where their defaults coincide.
package struct SizePolicy: Sendable {
    package static let standard = SizePolicy()
    package let reviewText = 8 * 1024 * 1024
    package let reviewWorkspace = 128 * 1024 * 1024
    package let reviewOutput = 32 * 1024 * 1024
    package let inlineWorkspace = 16 * 1024 * 1024
    package let inlineOutput = 8 * 1024 * 1024
    package let inlineSpan = 64 * 1024
    package let displayOutput = 64 * 1024 * 1024

    package let folderInput = 32 * 1024 * 1024
    package let folderTotal = 256 * 1024 * 1024
    package let folderReplacementOutput = 64 * 1024 * 1024
    package let searchSettings = 8 * 1024 * 1024
    package let workspacePreferences = 1024 * 1024
    package let workspaceSession = 512 * 1024 * 1024
    package let workspaceLayout = 4 * 1024 * 1024
    package let monitorContent = 32 * 1024 * 1024
    package let privateOutput = 32 * 1024 * 1024
    package let editorSettings = 1024 * 1024
    package let printConfirmation = 4 * 1024 * 1024
    package let recoverySmall = 8 * 1024 * 1024
    package let recoveryMedium = 32 * 1024 * 1024
    package let recoveryLarge = 128 * 1024 * 1024
    package let automaticRecovery = 256 * 1024 * 1024
    package let findHighlightLine = 1024 * 1024

    package let automationText = 32 * 1024 * 1024
    package let automationLibrary = 32 * 1024 * 1024
    package let automationRule = 1024 * 1024
    package let automationSample = 1024 * 1024
    package let macroLibrary = 32 * 1024 * 1024
    package let runArgument = 1024 * 1024
    package let runLibrary = 1024 * 1024
    package let runIO = 4 * 1024 * 1024
    package let utilitySelection = 16 * 1024 * 1024
    package let editorTransform = 16 * 1024 * 1024
    package let commentDocument = 16 * 1024 * 1024
    package let languageCatalog = 16 * 1024 * 1024
    package let languageKeywords = 1024 * 1024
    package let languageDefinition = 2 * 1024 * 1024
    package let functionNavigation = 2 * 1024 * 1024
    package let reminderItem = 1024 * 1024
    package let reminderJournal = 32 * 1024 * 1024

    package static func describe(_ bytes: Int) -> String {
        if bytes >= 1_048_576, bytes.isMultiple(of: 1_048_576) { return "\(bytes / 1_048_576) MiB" }
        if bytes >= 1024, bytes.isMultiple(of: 1024) { return "\(bytes / 1024) KiB" }
        return "\(bytes) bytes"
    }

    package var reviewTextNotice: String {
        "Comparison sources must fit within \(Self.describe(reviewText)) of UTF-8 text. Use a smaller source or copy a shorter excerpt into a new document."
    }
}
