// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package struct LanguageProfile: Codable, Equatable, Identifiable {
    package init(
        id: String, title: String, lexer: String, extensions: [String], keywordLists: [String: String],
        referenceKeywordClasses: [String: String], properties: [String: String], styles: [Style],
        functionPattern: String? = nil, udl: UserDefinedLanguage? = nil, comments: Comments? = nil
    ) {
        self.id = id
        self.title = title
        self.lexer = lexer
        self.extensions = extensions
        self.keywordLists = keywordLists
        self.referenceKeywordClasses = referenceKeywordClasses
        self.properties = properties
        self.styles = styles
        self.functionPattern = functionPattern
        self.udl = udl
        self.comments = comments
    }

    package struct Style: Codable, Equatable {
        package init(
            id: Int, name: String, foreground: String, fontStyle: Int, useCustomColor: Bool? = nil,
            fontName: String? = nil, fontSize: Double? = nil
        ) {
            self.id = id
            self.name = name
            self.foreground = foreground
            self.fontStyle = fontStyle
            self.useCustomColor = useCustomColor
            self.fontName = fontName
            self.fontSize = fontSize
        }

        package var id: Int, name: String, foreground: String, fontStyle: Int
        package var useCustomColor: Bool?
        package var fontName: String?
        package var fontSize: Double?
    }
    package struct Comments: Codable, Equatable {
        package init(line: String? = nil, blockOpen: String? = nil, blockClose: String? = nil) {
            self.line = line
            self.blockOpen = blockOpen
            self.blockClose = blockClose
        }
        package var line: String?, blockOpen: String?, blockClose: String?
    }
    package var id: String, title: String, lexer: String, extensions: [String], keywordLists: [String: String]
    package var referenceKeywordClasses: [String: String]
    package var properties: [String: String], styles: [Style]
    package var functionPattern: String?
    package var udl: UserDefinedLanguage?
    package var comments: Comments?
    /// The one "no language" identifier: the bundled Plain Text profile. Sessions and recovery
    /// snapshots written before it existed say "null"; `canonicalID` maps those on load.
    static package let plainTextID = "normal"
    static package func canonicalID(_ stored: String?) -> String {
        guard let stored, stored != "null" else { return plainTextID }
        return stored
    }
    /// The UDL lists that travel as lexer properties. They hold whole Notepad++ keyword groups, so
    /// they get a larger bound than ordinary properties, and only for the user lexer.
    static package let userListProperties: Set<String> = Set(
        [
            "comments", "numberPrefix1", "numberPrefix2", "numberExtras1", "numberExtras2", "numberSuffix1",
            "numberSuffix2", "numberRange", "operators1", "foldersInCode1Open", "foldersInCode1Middle",
            "foldersInCode1Close", "delimiters"
        ].map { "userDefine." + $0 })
    static package let userListPropertyLimit = 65536
    static package func isHexColor(_ text: String) -> Bool {
        text.utf8.count == 6
            && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    package func validate() throws {
        let languageName = String(title.prefix(150))
        guard !id.isEmpty, id.count <= 100 else {
            throw LanguageError.invalid("Language “\(languageName)” must use a profile name of 1–100 characters.")
        }
        guard !title.isEmpty, title.count <= 150 else {
            throw LanguageError.invalid("Language “\(languageName)” must use a display name of 1–150 characters.")
        }
        guard !lexer.isEmpty, lexer.count <= 100, !lexer.contains("\0") else {
            throw LanguageError.invalid(
                "Language “\(languageName)” must use a lexer name of 1–100 characters without a NUL character.")
        }
        guard extensions.count <= 200 else {
            throw LanguageError.invalid("Language “\(languageName)” must contain at most 200 extensions.")
        }
        for (index, ext) in extensions.enumerated() {
            guard !ext.isEmpty, ext.count <= 100, !ext.contains("/"), !ext.contains("\\") else {
                throw LanguageError.invalid(
                    "Extension \(index + 1) of language “\(languageName)” must contain 1–100 characters without a path separator."
                )
            }
        }
        guard keywordLists.count <= 32 else {
            throw LanguageError.invalid("Language “\(languageName)” must contain at most 32 keyword lists.")
        }
        for (key, value) in keywordLists {
            guard Int(key).map({ (0..<32).contains($0) }) == true, value.utf8.count <= 1048576,
                !value.contains("\0")
            else {
                throw LanguageError.invalid(
                    "Keyword list “\(String(key.prefix(40)))” of language “\(languageName)” must use a number from 0 to 31 and contain at most 1 MiB without NUL characters."
                )
            }
        }
        guard properties.count <= 100 else {
            throw LanguageError.invalid("Language “\(languageName)” must contain at most 100 properties.")
        }
        for (key, value) in properties {
            let validSize =
                lexer == "user" && Self.userListProperties.contains(key)
                ? value.utf8.count <= Self.userListPropertyLimit : value.count <= 4096
            guard !key.isEmpty, !key.contains("\0"), !value.contains("\0"), validSize else {
                throw LanguageError.invalid(
                    "Property “\(String(key.prefix(60)))” of language “\(languageName)” has an empty name, a NUL character or exceeds its size limit."
                )
            }
        }
        guard styles.count <= 256 else {
            throw LanguageError.invalid("Language “\(languageName)” must contain at most 256 styles.")
        }
        for style in styles {
            guard (0...255).contains(style.id) else {
                throw LanguageError.invalid("Language “\(languageName)” must use style numbers from 0 to 255.")
            }
            guard (0...7).contains(style.fontStyle) else {
                throw LanguageError.invalid(
                    "Language “\(languageName)” must use a font-style value from 0 to 7 for style \(style.id).")
            }
            guard Self.isHexColor(style.foreground) else {
                throw LanguageError.invalid(
                    "Language “\(languageName)” has an invalid style \(style.id) foreground. Enter exactly six hexadecimal digits."
                )
            }
        }
        for style in styles {
            if let name = style.fontName {
                guard name.count <= 150, !name.contains("\0") else {
                    throw LanguageError.invalid(
                        "The font name of style \(style.id) in language “\(languageName)” must be at most 150 characters without a NUL character."
                    )
                }
            }
            if let size = style.fontSize {
                guard size.isFinite, (6...72).contains(size) else {
                    throw LanguageError.invalid(
                        "The font size of style \(style.id) in language “\(languageName)” must be 6–72 points.")
                }
            }
        }
        if let comments {
            for marker in [comments.line, comments.blockOpen, comments.blockClose].compactMap({ $0 }) {
                guard marker.utf8.count <= 100, !marker.contains("\n"), !marker.contains("\r"), !marker.contains("\0")
                else {
                    throw LanguageError.invalid(
                        "Comment delimiters in language “\(languageName)” must be at most 100 bytes without a line break or NUL character."
                    )
                }
            }
        }
        if let pattern = functionPattern {
            guard !pattern.isEmpty, pattern.count <= 2048 else {
                throw LanguageError.invalid(
                    "The function pattern of language “\(languageName)” must contain 1–2048 characters.")
            }
            let regex: NSRegularExpression
            do { regex = try NSRegularExpression(pattern: pattern) } catch {
                throw LanguageError.invalid(
                    "The function pattern of language “\(languageName)” could not be compiled. \(error.localizedDescription)"
                )
            }
            guard regex.numberOfCaptureGroups >= 1 else {
                throw LanguageError.invalid(
                    "The function pattern of language “\(languageName)” requires capture group 1 for the symbol name.")
            }
        }
    }
    package var completions: [String] {
        Array(
            Set(
                keywordLists.values.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter {
                    !$0.contains("\0")
                })
        ).sorted()
    }
}
/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
package struct LanguageCatalog: VersionedLibrary, Equatable {
    package init(
        version: Int = 1, sourceCommit: String, sourceHashes: [String: String], limitations: [String],
        profiles: [LanguageProfile]
    ) {
        self.version = version
        self.sourceCommit = sourceCommit
        self.sourceHashes = sourceHashes
        self.limitations = limitations
        self.profiles = profiles
    }

    static package let libraryContext = "Language profiles"
    static package var librarySizeError: Error { LanguageError.invalid("Language catalog exceeds 16 MiB.") }
    package var version: Int
    package var sourceCommit: String
    package var sourceHashes: [String: String]
    package var limitations: [String]
    package var profiles: [LanguageProfile]
    package func validate() throws {
        guard version == 1 else { throw LanguageError.invalid("Language profiles require version 1.") }
        guard profiles.count <= 500 else { throw LanguageError.invalid("Keep at most 500 language profiles.") }
        var seen = Set<String>()
        for profile in profiles {
            guard seen.insert(profile.id).inserted else {
                throw LanguageError.invalid("Language “\(String(profile.title.prefix(150)))” appears more than once.")
            }
            try profile.validate()
        }
    }
    /// The reader's size limit; writers check against the same constant.
    static package let maximumBytes = 16 * 1024 * 1024
    /// The catalog a stored LanguageProfiles.json stands for. The current format holds only the
    /// user's changes (`LanguageOverrides`); a file written before that is a full copy of the
    /// catalog, and is read as the changes it makes to today's bundled catalog.
    static package func load(stored data: Data, over bundled: LanguageCatalog) throws -> Self {
        guard data.count <= maximumBytes else { throw LanguageError.invalid("Language catalog exceeds 16 MiB.") }
        try PersistedFormat.check(data, context: "Language profiles")
        struct Probe: Decodable { var overridesVersion: Int? }
        if try JSONInputFailure.decode(Probe.self, from: data, context: "Language profiles").overridesVersion != nil {
            return try JSONInputFailure.decode(LanguageOverrides.self, from: data, context: "Language profile changes")
                .applied(to: bundled)
        }
        return try LanguageOverrides(changing: bundled, to: decode(data), fullCopy: true).applied(to: bundled)
    }
    /// Profiles are kept in an array for order; lookups by identifier go through this.
    package func indexByID() -> [String: Int] {
        Dictionary(profiles.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    package func detect(filename: String, text: String) -> String? {
        let name = (filename as NSString).lastPathComponent.lowercased()
        // "dockerfile" names no bundled profile (Lexilla has no such lexer). It is a hook: a user
        // catalog that adds a profile with that identifier gets Dockerfile detection.
        let special = [
            "makefile": "makefile", "gnumakefile": "makefile", "cmakelists.txt": "cmake", "dockerfile": "dockerfile",
            ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "bash", ".zprofile": "bash", ".zshenv": "bash",
            ".profile": "bash"
        ]
        if let id = special[name], profiles.contains(where: { $0.id == id }) { return id }
        let ext = (name as NSString).pathExtension
        // As in Notepad++, a user-defined language wins an extension a built-in profile also lists.
        let matches: (LanguageProfile) -> Bool = { $0.extensions.contains { $0.lowercased() == ext } }
        if !ext.isEmpty,
            let profile = profiles.first(where: { $0.udl != nil && matches($0) }) ?? profiles.first(where: matches)
        {
            return profile.id
        }
        if let interpreter = Self.interpreter(shebang: text), let id = Self.interpreters[interpreter],
            profiles.contains(where: { $0.id == id })
        {
            return id
        }
        return nil
    }
    private static let interpreters = [
        "python": "python", "pythonw": "python", "ipython": "python", "ruby": "ruby", "jruby": "ruby",
        "node": "javascript.js", "nodejs": "javascript.js", "ts-node": "javascript.js", "perl": "perl", "bash": "bash",
        "rbash": "bash", "sh": "bash", "zsh": "bash", "dash": "bash", "ksh": "bash", "ash": "bash"
    ]
    /// The interpreter a `#!` line names: the basename of the command, or of the command `env`
    /// runs, lowercased and without a version suffix (digits, dots and CPython build flags). Only the first 512 characters are read.
    static package func interpreter(shebang text: String) -> String? {
        guard text.hasPrefix("#!") else { return nil }
        let first = text.prefix(512).split(whereSeparator: \.isNewline).first ?? ""
        var tokens = first.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)[...]
        func basename(_ path: String) -> String { (path as NSString).lastPathComponent.lowercased() }
        guard var name = tokens.popFirst().map(basename) else { return nil }
        if name == "env" {
            while let option = tokens.first, option.hasPrefix("-") || option.contains("=") { tokens.removeFirst() }
            guard let command = tokens.first else { return nil }
            name = basename(command)
        }
        var stem = Substring(name)
        // CPython build flags after the version, as in python3.12m or python3.13t.
        let flags = stem.reversed().prefix { "dmut".contains($0) }.count
        if flags > 0, flags <= 3, stem.dropLast(flags).last?.isNumber == true { stem.removeLast(flags) }
        while let last = stem.last, last.isASCII, last.isNumber || last == "." { stem.removeLast() }
        if stem.count < name.count, stem.last == "-" { stem.removeLast() }
        return stem.isEmpty ? nil : String(stem)
    }
}
extension LanguageCatalog {
    private enum CodingKeys: String, CodingKey { case version, sourceCommit, sourceHashes, limitations, profiles }
    /// The provenance fields describe the bundled catalog. A catalog written by hand or by
    /// another tool need not invent them.
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: values.decode(Int.self, forKey: .version),
            sourceCommit: values.decodeIfPresent(String.self, forKey: .sourceCommit) ?? "",
            sourceHashes: values.decodeIfPresent([String: String].self, forKey: .sourceHashes) ?? [:],
            limitations: values.decodeIfPresent([String].self, forKey: .limitations) ?? [],
            profiles: values.decode([LanguageProfile].self, forKey: .profiles))
    }
}
/// What the user changed, stored as LanguageProfiles.json in Application Support and merged over
/// the bundled catalog at load. Persisted format, version 1 (`overridesVersion`); a new field
/// must be Optional. Only differences are stored, so a later bundled catalog (new languages,
/// corrected keyword lists, new profile fields) reaches every profile field the user left alone.
package struct LanguageOverrides: Codable, Equatable {
    package init(
        overridesVersion: Int = 1, basedOnSourceCommit: String, changed: [Profile], added: [LanguageProfile],
        removed: [String], order: [String]? = nil
    ) {
        self.overridesVersion = overridesVersion
        self.basedOnSourceCommit = basedOnSourceCommit
        self.changed = changed
        self.added = added
        self.removed = removed
        self.order = order
    }

    /// One bundled profile's changed fields. A nil field follows the bundled profile.
    package struct Profile: Codable, Equatable {
        package init(
            id: String, title: String? = nil, lexer: String? = nil, extensions: [String]? = nil,
            keywordLists: [String: String]? = nil, referenceKeywordClasses: [String: String]? = nil,
            properties: [String: String]? = nil, styles: [LanguageProfile.Style]? = nil, functionPattern: String? = nil,
            udl: UserDefinedLanguage? = nil, comments: LanguageProfile.Comments? = nil, cleared: [String]? = nil
        ) {
            self.id = id
            self.title = title
            self.lexer = lexer
            self.extensions = extensions
            self.keywordLists = keywordLists
            self.referenceKeywordClasses = referenceKeywordClasses
            self.properties = properties
            self.styles = styles
            self.functionPattern = functionPattern
            self.udl = udl
            self.comments = comments
            self.cleared = cleared
        }

        package var id: String
        package var title: String?, lexer: String?, extensions: [String]?, keywordLists: [String: String]?
        package var referenceKeywordClasses: [String: String]?, properties: [String: String]?
        package var styles: [LanguageProfile.Style]?, functionPattern: String?, udl: UserDefinedLanguage?
        package var comments: LanguageProfile.Comments?
        /// Optional fields ("functionPattern", "udl", "comments") the user removed from a profile
        /// whose bundled version has them. Absent means inherit; listed here means none.
        package var cleared: [String]?
    }
    package var overridesVersion: Int
    /// The bundled catalog the changes were last written against.
    package var basedOnSourceCommit: String
    package var changed: [Profile]
    /// Profiles with identifiers the bundled catalog does not have: imported UDLs and custom profiles.
    package var added: [LanguageProfile]
    /// Bundled identifiers the user deleted.
    package var removed: [String]
    /// Every identifier in the user's order, stored only when it differs from the bundled order
    /// followed by the added profiles.
    package var order: [String]?

    package func validate() throws {
        guard overridesVersion == 1, basedOnSourceCommit.count <= 200, changed.count <= 500, added.count <= 500,
            removed.count <= 500, (order?.count ?? 0) <= 1000, Set(changed.map(\.id)).count == changed.count,
            Set(added.map(\.id)).count == added.count,
            changed.allSatisfy({
                Set($0.cleared ?? []).isSubset(of: ["functionPattern", "udl", "comments"])
            })
        else { throw LanguageError.invalid("Unsupported language overrides or duplicate identifiers.") }
    }
    /// The bundled catalog with these changes applied. A change to an identifier the bundled
    /// catalog no longer has cannot be applied and is left out; everything else is validated as
    /// a whole catalog.
    package func applied(to bundled: LanguageCatalog) throws -> LanguageCatalog {
        try validate()
        let changes = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0) }), gone = Set(removed)
        var byID: [String: LanguageProfile] = [:], natural: [String] = []
        for original in bundled.profiles where !gone.contains(original.id) {
            var profile = original
            if let change = changes[original.id] {
                let cleared = Set(change.cleared ?? [])
                if let value = change.title { profile.title = value }
                if let value = change.lexer { profile.lexer = value }
                if let value = change.extensions { profile.extensions = value }
                if let value = change.keywordLists { profile.keywordLists = value }
                if let value = change.referenceKeywordClasses { profile.referenceKeywordClasses = value }
                if let value = change.properties { profile.properties = value }
                if let value = change.styles { profile.styles = value }
                if let value = change.functionPattern { profile.functionPattern = value }
                if let value = change.udl { profile.udl = value }
                if let value = change.comments { profile.comments = value }
                if cleared.contains("functionPattern") { profile.functionPattern = nil }
                if cleared.contains("udl") { profile.udl = nil }
                if cleared.contains("comments") { profile.comments = nil }
            }
            if byID.updateValue(profile, forKey: profile.id) == nil { natural.append(profile.id) }
        }
        // The user's profile wins an identifier a later bundled catalog also started to use.
        for profile in added where byID.updateValue(profile, forKey: profile.id) == nil { natural.append(profile.id) }
        var ids = natural
        if let order {
            var seen = Set<String>()
            ids = order.filter { byID[$0] != nil && seen.insert($0).inserted }
            ids += natural.filter { !seen.contains($0) }
        }
        let catalog = LanguageCatalog(
            sourceCommit: bundled.sourceCommit, sourceHashes: bundled.sourceHashes, limitations: bundled.limitations,
            profiles: ids.compactMap { byID[$0] })
        try catalog.validate()
        return catalog
    }
    package func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= LanguageCatalog.maximumBytes else {
            throw LanguageError.invalid("Language profiles exceed 16 MiB and could not be read back.")
        }
        return data
    }
}
package enum LanguageError: LocalizedError {
    case invalid(String)
    package var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        }
    }
}
package struct LanguageSymbol: Equatable {
    package init(name: String, range: NSRange, line: Int) {
        self.name = name
        self.range = range
        self.line = line
    }
    package let name: String, range: NSRange, line: Int
}
package enum LanguageFunctions {
    static package func symbols(text: String, profile: LanguageProfile, timeLimit: TimeInterval = 0.1) throws
        -> [LanguageSymbol]
    {
        guard let pattern = profile.functionPattern else { return [] }
        guard text.utf8.count <= 2 * 1024 * 1024 else {
            throw LanguageError.invalid("Function navigation currently accepts documents up to 2 MiB.")
        }
        try profile.validate()
        let regex = try NSRegularExpression(pattern: pattern)
        let started = ProcessInfo.processInfo.systemUptime
        var timedOut = false, result: [LanguageSymbol] = []
        let source = text as NSString
        // Lines are counted once, forwards from the previous symbol. CR, LF and CRLF each end one line.
        var units: [UInt16] = [], line = 1, counted = 0
        func lineNumber(at location: Int) -> Int {
            if units.isEmpty { units = Array(text.utf16) }
            if location < counted {
                // A capture before the previous one (a look-ahead pattern): count from the start again.
                line = 1
                counted = 0
            }
            var index = counted
            while index < location {
                let unit = units[index]
                // The LF of a CRLF pair was counted with its CR, wherever the counting paused.
                if unit == 13 || (unit == 10 && (index == 0 || units[index - 1] != 13)) { line += 1 }
                index += 1
            }
            counted = index
            return line
        }
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.length))
        { match, _, stop in
            if ProcessInfo.processInfo.systemUptime - started > timeLimit {
                timedOut = true
                stop.pointee = true
                return
            }
            guard let match, match.numberOfRanges > 1 else { return }
            let range = match.range(at: 1)
            guard range.location != NSNotFound, Range(range, in: text) != nil else { return }
            result.append(
                LanguageSymbol(name: source.substring(with: range), range: range, line: lineNumber(at: range.location)))
            if result.count >= 10000 {
                timedOut = true
                stop.pointee = true
            }
        }
        guard !timedOut else {
            throw LanguageError.invalid(
                "Function navigation exceeded its time or result limit. Simplify the pattern or narrow the document.")
        }
        return result
    }
}
extension LanguageOverrides {
    /// The changes that turn `bundled` into `catalog`. A `fullCopy` is a catalog file written
    /// before overrides existed: an identifier it lacks was added to the bundled catalog later
    /// rather than deleted, and a profile without `comments` predates that field.
    package init(changing bundled: LanguageCatalog, to catalog: LanguageCatalog, fullCopy: Bool = false) {
        let base = bundled.indexByID()
        var changed: [Profile] = [], added: [LanguageProfile] = []
        for profile in catalog.profiles {
            guard let index = base[profile.id] else {
                added.append(profile)
                continue
            }
            let original = bundled.profiles[index]
            if PersistedValue.equal(profile, original) { continue }
            var change = Profile(id: profile.id), cleared: [String] = []
            if !PersistedValue.equal(profile.title, original.title) { change.title = profile.title }
            if !PersistedValue.equal(profile.lexer, original.lexer) { change.lexer = profile.lexer }
            if !PersistedValue.equal(profile.extensions, original.extensions) { change.extensions = profile.extensions }
            if !PersistedValue.equal(profile.keywordLists, original.keywordLists) {
                change.keywordLists = profile.keywordLists
            }
            if !PersistedValue.equal(profile.referenceKeywordClasses, original.referenceKeywordClasses) {
                change.referenceKeywordClasses = profile.referenceKeywordClasses
            }
            if !PersistedValue.equal(profile.properties, original.properties) { change.properties = profile.properties }
            if !PersistedValue.equal(profile.styles, original.styles) { change.styles = profile.styles }
            if !PersistedValue.equal(profile.functionPattern, original.functionPattern) {
                change.functionPattern = profile.functionPattern
                if profile.functionPattern == nil { cleared.append("functionPattern") }
            }
            if !PersistedValue.equal(profile.udl, original.udl) {
                change.udl = profile.udl
                if profile.udl == nil { cleared.append("udl") }
            }
            if !PersistedValue.equal(profile.comments, original.comments) {
                change.comments = profile.comments
                if profile.comments == nil, !fullCopy { cleared.append("comments") }
            }
            if !cleared.isEmpty { change.cleared = cleared }
            if !PersistedValue.equal(change, Profile(id: profile.id)) { changed.append(change) }
        }
        let kept = Set(catalog.profiles.map(\.id))
        let removed = fullCopy ? [] : bundled.profiles.map(\.id).filter { !kept.contains($0) }
        let stored = catalog.profiles.map(\.id)
        let natural = bundled.profiles.map(\.id).filter { kept.contains($0) } + added.map(\.id)
        self.init(
            basedOnSourceCommit: bundled.sourceCommit, changed: changed, added: added, removed: removed,
            order: PersistedValue.equal(stored, natural) ? nil : stored)
    }
}
