// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The common versioned-library codec. Each value still owns its schema, validation,
/// byte envelope, diagnostic vocabulary and encoding options; storage policy stays outside.
package protocol VersionedLibrary: Codable {
    static var maximumBytes: Int { get }
    static var libraryContext: String { get }
    static var librarySizeError: Error { get }
    static var libraryEncodingOptions: JSONEncoder.OutputFormatting { get }
    func validate() throws
}

extension VersionedLibrary {
    static package var libraryEncodingOptions: JSONEncoder.OutputFormatting {
        [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }
    static package func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw librarySizeError }
        try PersistedFormat.check(data, context: libraryContext)
        let value = try JSONInputFailure.decode(Self.self, from: data, context: libraryContext)
        try value.validate()
        return value
    }
    package func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = Self.libraryEncodingOptions
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw Self.librarySizeError }
        return data
    }
}
