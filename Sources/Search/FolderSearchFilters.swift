// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reference filter categories from FindReplaceDlg::getAndValidatePatterns and
/// Common.cpp matchInList/matchInExcludeDirList at the pinned source. Wildcards
/// are case-insensitive * and ?, with Windows *.* treated as all filenames.
/// Quoted tokens additionally support native filenames containing spaces.
struct FolderSearchFilters: Equatable, Sendable {
    let includes: [String], excludedFiles: [String], excludedTopFolders: [String], excludedAllFolders: [String]
    init(_ source: String) throws {
        guard source.utf8.count <= 16384, !source.contains("\0") else {
            throw FolderSearchError.invalidRequest("Filename filters exceed 16 KiB or contain NUL.")
        }
        var tokens: [String] = [], token = "", quoted = false
        for char in source {
            if char == "\"" {
                quoted.toggle()
            } else if !quoted && (char.isWhitespace || char == ";") {
                if !token.isEmpty {
                    tokens.append(token)
                    token = ""
                }
            } else {
                token.append(char)
            }
        }
        guard !quoted else { throw FolderSearchError.invalidRequest("Close the quote in the filename filter.") }
        if !token.isEmpty { tokens.append(token) }
        guard tokens.count <= 128, tokens.allSatisfy({ $0.utf16.count <= 512 }) else {
            throw FolderSearchError.invalidRequest("Use at most 128 filename patterns of 512 characters each.")
        }
        var include: [String] = [], files: [String] = [], top: [String] = [], all: [String] = []
        for token in tokens {
            let pattern: String
            if token.hasPrefix("!+\\") {
                pattern = String(token.dropFirst(3))
                all.append(pattern)
            } else if token.hasPrefix("!\\") {
                pattern = String(token.dropFirst(2))
                top.append(pattern)
            } else if token.hasPrefix("!") {
                pattern = String(token.dropFirst())
                files.append(pattern)
            } else {
                pattern = token
                include.append(pattern)
            }
            guard !pattern.isEmpty, !pattern.contains("/"), !pattern.contains("\\") else {
                throw FolderSearchError.invalidRequest(
                    "Filters match names, not paths. Use !\\name for root child folders or !+\\name at every depth.")
            }
        }
        includes = include.isEmpty ? ["*.*"] : include
        excludedFiles = files
        excludedTopFolders = top
        excludedAllFolders = all
    }
    func acceptsFile(_ name: String) -> Bool {
        includes.contains { Self.matches(name, $0) } && !excludedFiles.contains { Self.matches(name, $0) }
    }
    func excludesFolder(_ name: String, depth: Int) -> Bool {
        excludedAllFolders.contains { Self.matches(name, $0) }
            || (depth == 1 && excludedTopFolders.contains { Self.matches(name, $0) })
    }
    /// A name matches when it matches as precomposed (NFC) Unicode scalars, so a decomposed file
    /// name (an unzipped archive, a synced folder) meets a typed pattern and ? is one character;
    /// or as UTF-16 units, the Windows reference behaviour, so every pattern that matched before
    /// still does. An exclusion can therefore only protect more files than it did.
    /// Lowercase first: lowercasing can itself decompose (U+0130 becomes i and U+0307).
    static func matches(_ name: String, _ pattern: String) -> Bool {
        let name = name.lowercased(), pattern = (pattern == "*.*" ? "*" : pattern).lowercased()
        if wildcardMatch(Array(name.utf16), Array(pattern.utf16), any: 63, many: 42) { return true }
        let scalars = Array(name.precomposedStringWithCanonicalMapping.unicodeScalars),
            patternScalars = Array(pattern.precomposedStringWithCanonicalMapping.unicodeScalars)
        // Scalars, not Characters: a combining mark must not fuse with a literal "." or "*".
        return wildcardMatch(scalars, patternScalars, any: "?", many: "*")
    }
    /// Greedy wildcard backtracking uses constant auxiliary state, never regex.
    private static func wildcardMatch<Unit: Equatable>(_ input: [Unit], _ pattern: [Unit], any: Unit, many: Unit)
        -> Bool
    {
        var i = 0, p = 0, star: Int?, retry = 0
        while i < input.count {
            if p < pattern.count && (pattern[p] == any || pattern[p] == input[i]) {
                i += 1
                p += 1
            } else if p < pattern.count && pattern[p] == many {
                star = p
                p += 1
                retry = i
            } else if let s = star {
                retry += 1
                i = retry
                p = s + 1
            } else {
                return false
            }
        }
        while p < pattern.count && pattern[p] == many { p += 1 }
        return p == pattern.count
    }
}

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
struct FolderSearchSettings: Codable, Equatable {
    var version = 1
    var folder: URL?
    var workspaceScope = false, recursive = true, includeHidden = false
    var extensions = "", filters = "*.*"
    var options = SearchOptions()
    func validate() throws {
        guard version == 1, extensions.utf8.count <= 4096, options.query.utf16.count <= 65536,
            options.replacement.utf16.count <= 1048576
        else { throw FolderSearchError.invalidRequest("Unsupported or oversized saved folder search settings.") }
        if let folder {
            guard folder.isFileURL, (folder.host ?? "").isEmpty || folder.host == "localhost",
                !folder.path.contains("\0")
            else { throw FolderSearchError.invalidRequest("Saved search folder must be local.") }
        }
        _ = try FolderSearchFilters(filters)
    }
    static func load(_ defaults: UserDefaults) throws -> Self {
        guard let data = defaults.data(forKey: "TextTank.FolderSearch.v1") else { return Self() }
        guard data.count <= 2 * 1024 * 1024 else {
            throw FolderSearchError.invalidRequest("Saved folder search settings exceed their size limit.")
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    func save(_ defaults: UserDefaults) throws {
        try validate()
        defaults.set(try JSONEncoder().encode(self), forKey: "TextTank.FolderSearch.v1")
    }
}
