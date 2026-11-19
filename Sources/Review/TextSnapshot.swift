// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package struct SnapshotID: Hashable, Sendable {
    package let rawValue: UUID
    package init() { rawValue = UUID() }
}
package enum ReviewSourceID: Equatable, Sendable {
    case document(DocumentID), file(UUID), clipboard(UUID), checkpoint(UUID), freeText(UUID)
}
package enum ReviewRejection: String, Error, Sendable {
    case closed, readOnly, revisionChanged, reloaded, bytesChanged, invalidRange, invalidText, budgetExceeded,
        cancelled, alreadyUsed, incomplete
}
package enum ReviewUTF8 {
    /// Strict scalar validation, with no replacement/normalization or BOM consumption.
    package static func valid(_ data: Data) -> Bool {
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var i = 0
            while i < b.count {
                let c = b[i]
                if c < 0x80 {
                    i += 1
                    continue
                }
                let n: Int
                if c >= 0xc2 && c <= 0xdf {
                    n = 2
                } else if c >= 0xe0 && c <= 0xef {
                    n = 3
                } else if c >= 0xf0 && c <= 0xf4 {
                    n = 4
                } else {
                    return false
                }
                guard n <= b.count - i else { return false }
                let second = b[i + 1]
                guard second >= 0x80 && second <= 0xbf,
                    !(c == 0xe0 && second < 0xa0), !(c == 0xed && second > 0x9f),
                    !(c == 0xf0 && second < 0x90), !(c == 0xf4 && second > 0x8f)
                else { return false }
                for j in 2..<n { if b[i + j] < 0x80 || b[i + j] > 0xbf { return false } }
                i += n
            }
            return true
        }
    }
    package static func text(_ data: Data) -> String? {
        guard valid(data) else { return nil }
        // Unlike NSString's encoding initializer, this retains a leading U+FEFF.
        return String(decoding: data, as: UTF8.self)
    }
    static func slice(_ data: Data, _ lower: Int, _ upper: Int) -> Data {
        data.withUnsafeBytes { Data($0[lower..<upper]) }
    }
    static func boundary(_ data: Data, _ offset: Int) -> Bool {
        guard offset >= 0, offset <= data.count else { return false }
        return offset == data.count
            || data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in (raw[offset] & 0xc0) != 0x80 }
    }
}
package struct TextSnapshot: Sendable {
    package let id: SnapshotID
    package let bytes: Data
    package let source: ReviewSourceID
    package let document: DocumentTarget?
    package let label: String
    package let format: FileFormat?
    package init(
        bytes: Data, source: ReviewSourceID, label: String, document: DocumentTarget? = nil,
        format: FileFormat? = nil
    ) throws {
        guard bytes.count <= ReviewDiffPolicy.default.maximumInputBytes else { throw ReviewRejection.budgetExceeded }
        guard ReviewUTF8.valid(bytes) else { throw ReviewRejection.invalidText }
        if case .document(let identity) = source {
            guard let document, document.documentID == identity, document.byteLength == bytes.count else {
                throw ReviewRejection.invalidRange
            }
            try document.validate()
        } else if document != nil {
            throw ReviewRejection.invalidRange
        }
        id = SnapshotID()
        self.bytes = bytes.withUnsafeBytes { Data($0) }
        self.source = source
        self.document = document
        self.label = label
        self.format = format
    }
}
package struct ReviewByteRange: Equatable, Sendable {
    package let snapshot: SnapshotID
    package let lower: Int
    package let upper: Int
    package init(snapshot: SnapshotID, lower: Int, upper: Int) {
        self.snapshot = snapshot
        self.lower = lower
        self.upper = upper
    }
}
package struct ReviewLineTable: Sendable {
    package let ranges: [ReviewByteRange]
    package init(snapshot: TextSnapshot) throws {
        let meter = ReviewMeter(.correctness, token: ReviewCancellation(), hooks: .init())
        ranges = try ReviewLines(snapshot, meter: meter).ranges.map {
            .init(snapshot: snapshot.id, lower: $0.lower, upper: $0.upper)
        }
    }
}
