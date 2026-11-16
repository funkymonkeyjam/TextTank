// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

package struct UserDefinedLanguage: Codable, Equatable {
    package init(
        name: String, extensions: String, version: String, global: [String: String], prefix: [String: String],
        keywords: [String: String], styles: [Style]
    ) {
        self.name = name
        self.extensions = extensions
        self.version = version
        self.global = global
        self.prefix = prefix
        self.keywords = keywords
        self.styles = styles
    }

    package struct Style: Codable, Equatable {
        package init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
        package var name: String, attributes: [String: String]
    }
    package var name: String, extensions: String, version: String
    package var global: [String: String], prefix: [String: String], keywords: [String: String], styles: [Style]
    static package let keywordNames = [
        "Comments", "Numbers, prefix1", "Numbers, prefix2", "Numbers, extras1", "Numbers, extras2", "Numbers, suffix1",
        "Numbers, suffix2", "Numbers, range", "Operators1", "Operators2", "Folders in code1, open",
        "Folders in code1, middle", "Folders in code1, close", "Folders in code2, open", "Folders in code2, middle",
        "Folders in code2, close", "Folders in comment, open", "Folders in comment, middle",
        "Folders in comment, close", "Keywords1", "Keywords2", "Keywords3", "Keywords4", "Keywords5", "Keywords6",
        "Keywords7", "Keywords8", "Delimiters"
    ]
    static package let styleNames = [
        "DEFAULT", "COMMENTS", "LINE COMMENTS", "NUMBERS", "KEYWORDS1", "KEYWORDS2", "KEYWORDS3", "KEYWORDS4",
        "KEYWORDS5", "KEYWORDS6", "KEYWORDS7", "KEYWORDS8", "OPERATORS", "FOLDER IN CODE1", "FOLDER IN CODE2",
        "FOLDER IN COMMENT", "DELIMITERS1", "DELIMITERS2", "DELIMITERS3", "DELIMITERS4", "DELIMITERS5", "DELIMITERS6",
        "DELIMITERS7", "DELIMITERS8"
    ]
    package func profile() throws -> LanguageProfile {
        let itemName = String(name.prefix(120))
        guard version == "2.1" || version == "2.0" else {
            throw LanguageError.invalid("Language “\(itemName)” requires UDL version 2.0 or 2.1.")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            throw LanguageError.invalid("The UDL language name must contain 1–120 characters.")
        }
        if let key = keywords.keys.first(where: { !Self.keywordNames.contains($0) }) {
            throw LanguageError.invalid(
                "Language “\(itemName)” has an unsupported keyword field “\(String(key.prefix(80)))”.")
        }
        guard Set(styles.map(\.name)).count == styles.count else {
            throw LanguageError.invalid("Language “\(itemName)” contains a repeated style name.")
        }
        if let style = styles.first(where: { !Self.styleNames.contains($0.name) }) {
            throw LanguageError.invalid(
                "Language “\(itemName)” has an unsupported style “\(String(style.name.prefix(80)))”.")
        }
        let globalFields: Set<String> = [
            "caseIgnored", "allowFoldOfComments", "foldCompact", "forcePureLC", "decimalSeparator"
        ]
        if let field = global.keys.first(where: { !globalFields.contains($0) }) {
            throw LanguageError.invalid(
                "Language “\(itemName)” has an unsupported global field “\(String(field.prefix(80)))”.")
        }
        let prefixFields = Set((1...8).map { "Keywords\($0)" })
        if let field = prefix.keys.first(where: { !prefixFields.contains($0) }) {
            throw LanguageError.invalid(
                "Language “\(itemName)” has an unsupported prefix field “\(String(field.prefix(80)))”.")
        }
        let styleFields: Set<String> = [
            "name", "styleID", "fgColor", "bgColor", "colorStyle", "fontName", "fontStyle", "fontSize", "nesting",
            Self.customColorAttribute
        ]
        for style in styles {
            if let field = style.attributes.keys.first(where: { !styleFields.contains($0) }) {
                throw LanguageError.invalid(
                    "Style “\(style.name)” of language “\(itemName)” has an unsupported field “\(String(field.prefix(80)))”."
                )
            }
        }
        let direct = [
            0: "comments", 1: "numberPrefix1", 2: "numberPrefix2", 3: "numberExtras1", 4: "numberExtras2",
            5: "numberSuffix1", 6: "numberSuffix2", 7: "numberRange", 8: "operators1", 10: "foldersInCode1Open",
            11: "foldersInCode1Middle", 12: "foldersInCode1Close", 27: "delimiters"
        ]
        var properties = ["fold": "1"], lists: [String: String] = [:], slot = 0
        for (i, key) in Self.keywordNames.enumerated() {
            let text = keywords[key] ?? ""
            if let property = direct[i] {
                guard text.utf8.count <= LanguageProfile.userListPropertyLimit else {
                    throw LanguageError.invalid(
                        "Keyword group “\(key)” of language “\(itemName)” exceeds \(LanguageProfile.userListPropertyLimit) bytes."
                    )
                }
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
                throw LanguageError.invalid(
                    "The “\(key)” setting of language “\(itemName)” must be a whole number from 0 to 2.")
            }
            properties["userDefine." + key] = String(value)
        }
        for i in 1...8 { properties["userDefine.prefixKeywords\(i)"] = prefix["Keywords\(i)"] == "yes" ? "1" : "0" }
        var converted: [LanguageProfile.Style] = []
        for style in styles {
            let id = Self.styleNames.firstIndex(of: style.name)!
            func trimmed(_ key: String) -> String {
                (style.attributes[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Notepad++ writes these attributes empty as readily as it omits them; both mean 0.
            func number(_ key: String, _ range: ClosedRange<Int>) throws -> Int {
                let raw = trimmed(key)
                if raw.isEmpty { return 0 }
                guard let value = Int(raw), range.contains(value) else {
                    throw LanguageError.invalid(
                        "Invalid UDL style parameters: style '\(style.name)': \(key) must be \(range.lowerBound)–\(range.upperBound)."
                    )
                }
                return value
            }
            let nesting = try number("nesting", 0...0x7ffffff), font = try number("fontStyle", 0...7)
            let color = trimmed("fgColor"), marker = style.attributes[Self.customColorAttribute]
            guard color.isEmpty || LanguageProfile.isHexColor(color) else {
                throw LanguageError.invalid(
                    "Invalid UDL style parameters: style '\(style.name)': fgColor must be six hexadecimal digits.")
            }
            guard marker == nil || marker == "0" || marker == "1" else {
                throw LanguageError.invalid(
                    "Invalid UDL style parameters: style '\(style.name)': \(Self.customColorAttribute) must be 0 or 1.")
            }
            properties[String(format: "userDefine.nesting.%02d", id)] = String(nesting)
            // The stored attributes keep the file's own size; only the applied style is normalised.
            // Absent, empty, zero, negative and non-finite sizes mean the editor's size.
            let size = Double(trimmed("fontSize")).flatMap { $0.isFinite && $0 > 0 ? min(max($0, 6), 72) : nil }
            converted.append(
                .init(
                    id: id, name: style.name, foreground: color.isEmpty ? "000000" : color, fontStyle: font,
                    useCustomColor: Self.usesCustomColor(color, colorStyle: trimmed("colorStyle"), marker: marker),
                    fontName: style.attributes["fontName"].flatMap { $0.isEmpty ? nil : $0 }, fontSize: size))
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
    /// TextTank's own WordsStyle attribute: the person's explicit "Use custom text color" choice in
    /// Syntax Style Settings ("1" or "0"), so that it survives Edit Current UDL and export/import.
    /// Notepad++ ignores attributes it does not know.
    static package let customColorAttribute = "texttankCustomColor"
    /// Whether an imported style keeps its fixed RGB. A real colour does. No colour, a colour
    /// the file marks as unused (`colorStyle` without the foreground bit) and the near-black or
    /// near-white a light-theme UDL uses for ordinary text carry no colour information, so those
    /// follow the appearance (nil) instead of pinning black text onto a dark background.
    static package func usesCustomColor(_ foreground: String, colorStyle: String, marker: String?) -> Bool? {
        if let marker { return marker == "1" }
        guard let value = UInt32(foreground, radix: 16), foreground.utf8.count == 6,
            (Int(colorStyle) ?? 3) & 1 != 0
        else { return nil }
        let channels = [(value >> 16) & 255, (value >> 8) & 255, value & 255]
        if channels.allSatisfy({ $0 <= 0x30 }) || channels.allSatisfy({ $0 >= 0xD0 }) { return nil }
        return true
    }
    /// The profile for this definition when it replaces `existing` (Edit Current UDL, or importing
    /// the same language again). Everything the XML can express comes from the XML. What it cannot
    /// express is kept: the function pattern, an explicit adaptive-colour choice for a style whose
    /// colour the XML did not change, and comment markers the person overrode in the profile editor.
    package func profile(preserving existing: LanguageProfile?) throws -> LanguageProfile {
        var profile = try profile()
        guard let existing else { return profile }
        profile.id = existing.id
        profile.functionPattern = existing.functionPattern
        for index in profile.styles.indices {
            guard let old = existing.styles.first(where: { $0.id == profile.styles[index].id }),
                old.useCustomColor == false,
                styles.first(where: { $0.name == profile.styles[index].name })?.attributes[Self.customColorAttribute]
                    == nil, old.foreground.caseInsensitiveCompare(profile.styles[index].foreground) == .orderedSame
            else { continue }
            profile.styles[index].useCustomColor = false
        }
        if let derived = try? existing.udl?.profile().comments, existing.comments != derived {
            profile.comments = existing.comments
        }
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
    static package func words(_ input: String) throws -> String {
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
                // As upstream setUserLexer: only text inside quotes arms the multi-part marker, so
                // leading spaces in a quoted group are dropped whatever came before the quote.
                if quote != nil { nonWhitespace = true }
            }
            index += 1
        }
        guard quote == nil, let result = String(bytes: output, encoding: .utf8) else {
            throw LanguageError.invalid("Unbalanced UDL keyword quotes or invalid text.")
        }
        return result
    }
    static package func decode(_ data: Data) throws -> [Self] {
        // XML has no U+0000, so a NUL byte means UTF-16 or UTF-32, which would hide a DTD from the
        // text scan below. The scan stays: nothing else rejects a DOCTYPE that declares nothing.
        guard data.count <= 2 * 1024 * 1024, !data.contains(0), let text = String(data: data, encoding: .utf8),
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
    package func encodedXML() throws -> Data {
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
    // The parser honours the encoding a file declares (UTF-7, for one), so a DTD can reach it past
    // the UTF-8 text scan in decode. Any declaration it reports ends the import.
    private func rejectDeclaration(_ parser: XMLParser) {
        error = LanguageError.invalid("UDL import accepts UTF-8 XML up to 2 MiB without DTD or external entities.")
        parser.abortParsing()
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        rejectDeclaration(parser)
    }
    func parser(
        _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?
    ) { rejectDeclaration(parser) }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
        rejectDeclaration(parser)
    }
    func parser(
        _ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
        type: String?, defaultValue: String?
    ) { rejectDeclaration(parser) }
    func parser(
        _ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?,
        systemID: String?, notationName: String?
    ) { rejectDeclaration(parser) }
    func parser(
        _ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?
    ) { rejectDeclaration(parser) }
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
