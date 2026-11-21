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

    package var reviewTextNotice: String {
        "Comparison sources must fit within \(reviewText / (1024 * 1024)) MiB of UTF-8 text. Use a smaller source or copy a shorter excerpt into a new document."
    }
}
