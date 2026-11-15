// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct LanguageProfile: Codable, Equatable, Identifiable {
    struct Style: Codable, Equatable {
        var id: Int, name: String, foreground: String, fontStyle: Int
        var useCustomColor: Bool?
        var fontName: String?
        var fontSize: Double?
    }
    struct Comments: Codable, Equatable { var line: String?, blockOpen: String?, blockClose: String? }
    var id: String, title: String, lexer: String, extensions: [String], keywordLists: [String: String]
    var referenceKeywordClasses: [String: String]
    var properties: [String: String], styles: [Style]
    var functionPattern: String?
    var udl: UserDefinedLanguage?
    var comments: Comments?
    func validate() throws {
        guard !id.isEmpty, id.count <= 100, !title.isEmpty, title.count <= 150, !lexer.isEmpty, lexer.count <= 100,
            !lexer.contains("\0"), extensions.count <= 200,
            extensions.allSatisfy({ !$0.isEmpty && $0.count <= 100 && !$0.contains("/") && !$0.contains("\\") }),
            keywordLists.count <= 32,
            keywordLists.allSatisfy({
                Int($0.key).map { (0..<32).contains($0) } == true && $0.value.utf8.count <= 1048576
                    && !$0.value.contains("\0")
            }),
            properties.count <= 100,
            properties.allSatisfy({
                !$0.key.isEmpty && !$0.key.contains("\0") && !$0.value.contains("\0") && $0.value.count <= 4096
            }),
            styles.count <= 256,
            styles.allSatisfy({
                (0...255).contains($0.id) && (0...7).contains($0.fontStyle)
                    && $0.foreground.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
            })
        else { throw LanguageError.invalid("Invalid language profile fields or safety limits.") }
        for style in styles {
            if let name = style.fontName {
                guard name.count <= 150, !name.contains("\0") else {
                    throw LanguageError.invalid("Invalid syntax font name.")
                }
            }
            if let size = style.fontSize {
                guard size.isFinite, (6...72).contains(size) else {
                    throw LanguageError.invalid("Syntax font size must be 6–72 points.")
                }
            }
        }
        if let comments {
            for marker in [comments.line, comments.blockOpen, comments.blockClose].compactMap({ $0 }) {
                guard marker.utf8.count <= 100, !marker.contains("\n"), !marker.contains("\r"), !marker.contains("\0")
                else { throw LanguageError.invalid("Invalid comment delimiter.") }
            }
        }
        if let pattern = functionPattern {
            guard !pattern.isEmpty, pattern.count <= 2048 else {
                throw LanguageError.invalid("Function pattern must contain 1–2048 characters.")
            }
            let regex = try NSRegularExpression(pattern: pattern)
            guard regex.numberOfCaptureGroups >= 1 else {
                throw LanguageError.invalid("Function pattern requires capture group 1 for the symbol name.")
            }
        }
    }
    var completions: [String] {
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
struct LanguageCatalog: Codable, Equatable {
    var version: Int = 1
    var sourceCommit: String
    var sourceHashes: [String: String]
    var limitations: [String]
    var profiles: [LanguageProfile]
    func validate() throws {
        guard version == 1, profiles.count <= 500, Set(profiles.map(\.id)).count == profiles.count else {
            throw LanguageError.invalid("Unsupported language catalog or duplicate identifiers.")
        }
        for profile in profiles { try profile.validate() }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw LanguageError.invalid("Language catalog exceeds 16 MiB.") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    func detect(filename: String, text: String) -> String? {
        let name = (filename as NSString).lastPathComponent.lowercased()
        let special = [
            "makefile": "makefile", "gnumakefile": "makefile", "cmakelists.txt": "cmake", "dockerfile": "dockerfile",
            ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "bash"
        ]
        if let id = special[name], profiles.contains(where: { $0.id == id }) { return id }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty,
            let profile = profiles.first(where: { $0.extensions.contains(where: { $0.lowercased() == ext }) })
        {
            return profile.id
        }
        if text.hasPrefix("#!") {
            let first = String(text.prefix(512).split(whereSeparator: \.isNewline).first ?? "")
            for (marker, id) in [
                ("python", "python"), ("ruby", "ruby"), ("node", "javascript.js"), ("perl", "perl"), ("bash", "bash"),
                ("/sh", "bash")
            ] {
                if first.contains(marker), profiles.contains(where: { $0.id == id }) { return id }
            }
        }
        return nil
    }
}
enum LanguageError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let text) = self { return text }
        return nil
    }
}
struct LanguageSymbol: Equatable { let name: String, range: NSRange, line: Int }
enum LanguageFunctions {
    static func symbols(text: String, profile: LanguageProfile, timeLimit: TimeInterval = 0.1) throws
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
            let prefix = source.substring(to: range.location)
            let line =
                prefix.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").filter {
                    $0 == "\n"
                }.count + 1
            result.append(LanguageSymbol(name: source.substring(with: range), range: range, line: line))
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
