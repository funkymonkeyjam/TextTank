// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

struct UserDefinedLanguage: Codable, Equatable {
    struct Style: Codable, Equatable { var name: String, attributes: [String: String] }
    var name: String, extensions: String, version: String
    var global: [String: String], prefix: [String: String], keywords: [String: String], styles: [Style]
    static let keywordNames = [
        "Comments", "Numbers, prefix1", "Numbers, prefix2", "Numbers, extras1", "Numbers, extras2", "Numbers, suffix1",
        "Numbers, suffix2", "Numbers, range", "Operators1", "Operators2", "Folders in code1, open",
        "Folders in code1, middle", "Folders in code1, close", "Folders in code2, open", "Folders in code2, middle",
        "Folders in code2, close", "Folders in comment, open", "Folders in comment, middle",
        "Folders in comment, close", "Keywords1", "Keywords2", "Keywords3", "Keywords4", "Keywords5", "Keywords6",
        "Keywords7", "Keywords8", "Delimiters"
    ]
    static let styleNames = [
        "DEFAULT", "COMMENTS", "LINE COMMENTS", "NUMBERS", "KEYWORDS1", "KEYWORDS2", "KEYWORDS3", "KEYWORDS4",
        "KEYWORDS5", "KEYWORDS6", "KEYWORDS7", "KEYWORDS8", "OPERATORS", "FOLDER IN CODE1", "FOLDER IN CODE2",
        "FOLDER IN COMMENT", "DELIMITERS1", "DELIMITERS2", "DELIMITERS3", "DELIMITERS4", "DELIMITERS5", "DELIMITERS6",
        "DELIMITERS7", "DELIMITERS8"
    ]
    func profile() throws -> LanguageProfile {
        guard version == "2.1" || version == "2.0", !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            name.count <= 120, keywords.keys.allSatisfy({ Self.keywordNames.contains($0) }),
            Set(styles.map(\.name)).count == styles.count, styles.allSatisfy({ Self.styleNames.contains($0.name) })
        else { throw LanguageError.invalid("Unsupported UDL version, name, keyword or style field.") }
        guard
            Set(global.keys).isSubset(of: [
                "caseIgnored", "allowFoldOfComments", "foldCompact", "forcePureLC", "decimalSeparator"
            ]), Set(prefix.keys).isSubset(of: Set((1...8).map { "Keywords\($0)" })),
            styles.allSatisfy({
                Set($0.attributes.keys).isSubset(of: [
                    "name", "styleID", "fgColor", "bgColor", "colorStyle", "fontName", "fontStyle", "fontSize",
                    "nesting"
                ])
            })
        else { throw LanguageError.invalid("Unknown UDL setting attributes.") }
        let direct = [
            0: "comments", 1: "numberPrefix1", 2: "numberPrefix2", 3: "numberExtras1", 4: "numberExtras2",
            5: "numberSuffix1", 6: "numberSuffix2", 7: "numberRange", 8: "operators1", 10: "foldersInCode1Open",
            11: "foldersInCode1Middle", 12: "foldersInCode1Close", 27: "delimiters"
        ]
        var properties = ["fold": "1"], lists: [String: String] = [:], slot = 0
        for (i, key) in Self.keywordNames.enumerated() {
            let text = keywords[key] ?? ""
            if let property = direct[i] {
                properties["userDefine." + property] = text
            } else {
                lists[String(slot)] = try Self.words(text)
                slot += 1
            }
        }
        for key in ["caseIgnored", "allowFoldOfComments", "foldCompact"] {
            properties["userDefine." + (key == "caseIgnored" ? "isCaseIgnored" : key)] =
                global[key] == "yes" ? "1" : "0"
        }
        for key in ["forcePureLC", "decimalSeparator"] {
            guard let value = Int(global[key] ?? "0"), (0...2).contains(value) else {
                throw LanguageError.invalid("Invalid UDL numeric setting.")
            }
            properties["userDefine." + key] = String(value)
        }
        for i in 1...8 { properties["userDefine.prefixKeywords\(i)"] = prefix["Keywords\(i)"] == "yes" ? "1" : "0" }
        var converted: [LanguageProfile.Style] = []
        for style in styles {
            let id = Self.styleNames.firstIndex(of: style.name)!
            guard let nesting = Int(style.attributes["nesting"] ?? "0"), (0...0x7ffffff).contains(nesting),
                let font = Int(style.attributes["fontStyle"] ?? "0")
            else { throw LanguageError.invalid("Invalid UDL style parameters.") }
            properties[String(format: "userDefine.nesting.%02d", id)] = String(nesting)
            converted.append(
                .init(
                    id: id, name: style.name, foreground: style.attributes["fgColor"] ?? "000000", fontStyle: font,
                    useCustomColor: true, fontName: style.attributes["fontName"].flatMap { $0.isEmpty ? nil : $0 },
                    fontSize: style.attributes["fontSize"].flatMap { Double($0) }))
        }
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let profile = LanguageProfile(
            id: "udl." + digest.prefix(24), title: name, lexer: "user",
            extensions: extensions.split(whereSeparator: \.isWhitespace).map(String.init), keywordLists: lists,
            referenceKeywordClasses: keywords, properties: properties, styles: converted, functionPattern: nil,
            udl: self,
            comments: .init(
                line: Self.simpleComment(keywords["Comments"] ?? "", code: "00"),
                blockOpen: Self.simpleComment(keywords["Comments"] ?? "", code: "03"),
                blockClose: Self.simpleComment(keywords["Comments"] ?? "", code: "04")))
        try profile.validate()
        return profile
    }
    private static func simpleComment(_ text: String, code: String) -> String? {
        // Editing uses the first simple delimiter; lexer properties retain the complete UDL grammar.
        guard let token = text.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix(code) }),
            token.count > 2
        else { return nil }
        return String(token.dropFirst(2))
    }
    /// Notepad++ multi-part quoted words encode spaces as vertical-tab/backspace markers.
    static func words(_ input: String) throws -> String {
        let chars = Array(input.utf8)
        var output: [UInt8] = [], quote: UInt8? = nil, nonWhitespace = false, index = 0
        while index < chars.count {
            let c = chars[index]
            if c == 92, index + 1 < chars.count, [34, 39, 92].contains(chars[index + 1]) {
                output.append(chars[index + 1])
                index += 2
                continue
            }
            if (c == 34 || c == 39) && (quote == nil || quote == c) {
                quote = quote == nil ? c : nil
                index += 1
                continue
            }
            if let q = quote, c <= 32 {
                if nonWhitespace, index > 0, index + 1 < chars.count, chars[index - 1] != q, chars[index + 1] != q,
                    chars[index + 1] > 32
                {
                    output.append(q == 34 ? 11 : 8)
                }
            } else {
                output.append(c)
                if c > 32 { nonWhitespace = true }
            }
            index += 1
        }
        guard quote == nil, let result = String(bytes: output, encoding: .utf8) else {
            throw LanguageError.invalid("Unbalanced UDL keyword quotes or invalid text.")
        }
        return result
    }
    static func decode(_ data: Data) throws -> [Self] {
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
            text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
            text.range(of: "<!ENTITY", options: .caseInsensitive) == nil
        else {
            throw LanguageError.invalid("UDL import accepts UTF-8 XML up to 2 MiB without DTD or external entities.")
        }
        let parser = XMLParser(data: data), delegate = UDLParser()
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.error == nil, !delegate.languages.isEmpty else {
            throw delegate.error ?? parser.parserError ?? LanguageError.invalid("No valid UDL definitions found.")
        }
        for item in delegate.languages { _ = try item.profile() }
        return delegate.languages
    }
    func encodedXML() throws -> Data {
        _ = try profile()
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func attributes(_ values: [String: String]) -> String {
            values.sorted { $0.key < $1.key }.map { "\($0.key)=\"\(escape($0.value))\"" }.joined(separator: " ")
        }
        var xml =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<NotepadPlus><UserLang name=\"\(escape(name))\" ext=\"\(escape(extensions))\" udlVersion=\"\(version)\"><Settings><Global \(attributes(global))/><Prefix \(attributes(prefix))/></Settings><KeywordLists>"
        for name in Self.keywordNames { xml += "<Keywords name=\"\(name)\">\(escape(keywords[name] ?? ""))</Keywords>" }
        xml += "</KeywordLists><Styles>"
        for style in styles {
            var fields = style.attributes
            fields["name"] = style.name
            xml += "<WordsStyle \(attributes(fields))/>"
        }
        xml += "</Styles></UserLang></NotepadPlus>\n"
        return Data(xml.utf8)
    }
}
private final class UDLParser: NSObject, XMLParserDelegate {
    var languages: [UserDefinedLanguage] = [], error: Error?
    private var current: UserDefinedLanguage?, keyword: String?, text = "", depth = 0
    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        depth += 1
        if depth > 8 {
            error = LanguageError.invalid("UDL XML nesting exceeds limit.")
            parser.abortParsing()
            return
        }
        switch name {
        case "UserLang":
            if current != nil || languages.count >= 200 {
                error = LanguageError.invalid("Invalid nested or excessive UDL definitions.")
                parser.abortParsing()
                return
            }
            current = UserDefinedLanguage(
                name: attributes["name"] ?? "", extensions: attributes["ext"] ?? "",
                version: attributes["udlVersion"] ?? "", global: [:], prefix: [:], keywords: [:], styles: [])
        case "Global": current?.global = attributes
        case "Prefix": current?.prefix = attributes
        case "Keywords":
            keyword = attributes["name"]
            text = ""
        case "WordsStyle": current?.styles.append(.init(name: attributes["name"] ?? "", attributes: attributes))
        case "NotepadPlus", "Settings", "KeywordLists", "Styles": break
        default:
            error = LanguageError.invalid("Unknown UDL XML element \(name).")
            parser.abortParsing()
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if keyword != nil { text += string } }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if keyword != nil, let value = String(data: data, encoding: .utf8) { text += value }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "Keywords", let keyword {
            current?.keywords[keyword] = text
            self.keyword = nil
            text = ""
        }
        if name == "UserLang", var current {
            for key in UserDefinedLanguage.keywordNames {
                if current.keywords[key] == nil { current.keywords[key] = "" }
            }
            languages.append(current)
            self.current = nil
        }
        depth -= 1
    }
}
