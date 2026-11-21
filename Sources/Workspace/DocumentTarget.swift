import Foundation

/// Immutable document coordinates, captured by the main-actor runtime before work starts.
/// Runtime identity is never a path, tab, group or view. A reload epoch also rejects an
/// identical-byte reload that need not advance Scintilla's modification revision.
package struct DocumentTarget: Equatable, Sendable {
    package let documentID: DocumentID
    package let revision: UInt
    package let loadEpoch: UInt
    package let byteLength: Int
    package let selections: [SessionSelection]
    package init(
        documentID: DocumentID, revision: UInt, loadEpoch: UInt = 0, byteLength: Int,
        selections: [SessionSelection]
    ) {
        self.documentID = documentID
        self.revision = revision
        self.loadEpoch = loadEpoch
        self.byteLength = byteLength
        self.selections = selections
    }
    package func validate() throws {
        guard byteLength >= 0, !selections.isEmpty, selections.count <= 10_000,
            selections.allSatisfy({
                $0.anchorByte >= 0 && $0.caretByte >= 0
                    && $0.anchorByte <= byteLength && $0.caretByte <= byteLength
            })
        else { throw TabModelError.invalid }
    }
    package func resolve(in openDocuments: Set<DocumentID>) -> DocumentID? {
        openDocuments.contains(documentID) ? documentID : nil
    }
    package func isCurrent(documentID: DocumentID, revision: UInt, loadEpoch: UInt) -> Bool {
        self.documentID == documentID && self.revision == revision && self.loadEpoch == loadEpoch
    }
}
