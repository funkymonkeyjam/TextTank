// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import TextTankCore
import EditorBridge

/// A capture owns values and only a weak exact document, never the originating presentation.
@MainActor final class ReviewDocumentCapture {
    let snapshot: TextSnapshot
    private weak var document: TextDocument?
    fileprivate init(_ editor: TTEditor) throws {
        guard let document = EditorLifetime.document(for: editor), document.isOpen,
            !document.presentations.isEmpty, document.windowForSheet != nil
        else { throw ReviewRejection.closed }
        guard editor.byteLength <= ReviewDiffPolicy.default.maximumInputBytes else {
            throw ReviewRejection.budgetExceeded
        }
        let bytes = editor.utf8Data
        let target = DocumentTarget(
            documentID: document.runtimeID, revision: editor.revision,
            loadEpoch: document.loadEpoch, byteLength: bytes.count,
            selections: editor.selectionRanges.map { .init(anchorByte: $0.anchor, caretByte: $0.caret) })
        snapshot = try TextSnapshot(
            bytes: bytes, source: .document(document.runtimeID), label: document.displayName,
            document: target, format: document.format)
        self.document = document
    }
    func resolve() throws -> (TextDocument, TTEditor) {
        guard let document, document.isOpen, !document.presentations.isEmpty, document.windowForSheet != nil,
            document.runtimeID == snapshot.document?.documentID,
            EditorLifetime.document(for: document.editor) === document
        else { throw ReviewRejection.closed }
        return (document, document.editor)
    }
    func validateCurrent() throws {
        let (doc, editor) = try resolve()
        guard doc.loadEpoch == snapshot.document?.loadEpoch else { throw ReviewRejection.reloaded }
        guard editor.revision == snapshot.document?.revision else { throw ReviewRejection.revisionChanged }
    }
}
@MainActor enum ReviewSnapshotCapture {
    static func document(_ editor: TTEditor) throws -> ReviewDocumentCapture { try ReviewDocumentCapture(editor) }
    /// This API reads only when explicitly called. The caller supplies its chosen clipboard adapter.
    static func clipboard(read: () throws -> Data) throws -> TextSnapshot {
        try TextSnapshot(bytes: read(), source: .clipboard(UUID()), label: "Clipboard")
    }
    nonisolated static func file(_ url: URL, as encoding: FileEncoding? = nil) async throws -> TextSnapshot {
        try await Task.detached {
            // The same bounded descriptor-anchored no-follow reader, retaining its actual
            // opened-file identity even when unsettled metadata cannot stand in for bytes.
            let captured = try PrivateFileStore.readSample(
                url, maximumBytes: SizePolicy.standard.reviewText, parent: .selectedInput)
            let decoded =
                try encoding.map { try FileCodec.decode(captured.data, encoding: $0) }
                ?? FileCodec.decode(captured.data)
            guard decoded.text.utf8.count <= SizePolicy.standard.reviewText else {
                throw ReviewRejection.budgetExceeded
            }
            return try TextSnapshot(
                bytes: Data(decoded.text.utf8), source: .file(UUID()), label: url.lastPathComponent,
                format: decoded.format, capturedFileIdentity: FileSignature(captured.before))
        }.value
    }
}
