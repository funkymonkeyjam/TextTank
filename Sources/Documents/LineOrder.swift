// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The two line orders shared by the Edit menu sort commands and the automation sort rules,
/// so the same choice gives the same order in both places.
enum LineOrder {
    /// The default order, matching Notepad++: Swift string order, which compares Unicode
    /// scalar values. Capitals sort before lowercase and accented letters after "z".
    static func codePointAscending(_ a: String, _ b: String) -> Bool { a < b }
    /// The order Finder uses for file names in the current locale: case and accents are
    /// secondary and runs of digits compare as numbers. Lines the locale treats as equal fall
    /// back to byte order, so the result never depends on the sort algorithm.
    static func localizedAscending(_ a: String, _ b: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.utf8.lexicographicallyPrecedes(b.utf8)
        }
    }
}
