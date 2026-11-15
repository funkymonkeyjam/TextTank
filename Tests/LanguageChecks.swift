// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@main struct LanguageChecks {
    static func main() {
        Checks.run("LanguageChecks") {
            let catalog = try LanguageCatalog.decode(
                Data(contentsOf: TestPaths.resources.appendingPathComponent("LanguageProfiles.json")))
            check(catalog.profiles.count == 96, "all 96 source definitions retained")
            check(catalog.sourceCommit == "61246e5741fd7c59352f3feb5ccc7e33e4594d15", "reference source pinned")
            check(try LanguageCatalog.decode(catalog.encoded()) == catalog, "catalog roundtrip")
            check(catalog.detect(filename: "HELLO.PY", text: "") == "python", "case-insensitive extension detection")
            check(
                catalog.detect(filename: "CMakeLists.txt", text: "") == "cmake", "special filename beats txt extension")
            check(
                catalog.detect(filename: "script", text: "#!/usr/bin/env python3\n") == "python",
                "bounded shebang detection")
            check(catalog.detect(filename: "unknown.zzzz", text: "") == nil, "unknown file remains explicit choice")
            let python = try requireValue(
                catalog.profiles.first { $0.id == "python" }, "fixture: python profile exists")
            check(python.completions.contains("def"), "source keywords supply completion")
            let symbols = try LanguageFunctions.symbols(
                text: "# café\r\nclass Example:\r\n    def work(self):\r\n        return 1\r\n", profile: python)
            check(
                symbols.map(\.name) == ["Example", "work"] && symbols.map(\.line) == [2, 3],
                "function navigation Unicode CRLF line offsets")
            check(
                try LanguageFunctions.symbols(text: "# def fake():\nvalue = 'def fake()'", profile: python).isEmpty,
                "basic anchored parser avoids inline false positives")
            var invalid = python
            invalid.functionPattern = "["
            rejects("malformed function pattern") { try invalid.validate() }
            invalid = python
            invalid.functionPattern = "def"
            rejects("missing symbol capture") { try invalid.validate() }
            invalid = python
            invalid.keywordLists = ["32": "bad"]
            rejects("out-of-range keyword index") { try invalid.validate() }
            invalid = python
            invalid.properties = ["bad\0": "value"]
            rejects("NUL lexer property") { try invalid.validate() }
            invalid = python
            invalid.functionPattern = "(a+)+$"
            let start = ProcessInfo.processInfo.systemUptime
            rejects("pathological custom function pattern", where: { $0 is LanguageError }) {
                _ = try LanguageFunctions.symbols(
                    text: String(repeating: "a", count: 32) + "!", profile: invalid, timeLimit: 0.05)
            }
            check(ProcessInfo.processInfo.systemUptime - start < 10, "function parser time bound")
            var duplicate = catalog
            duplicate.profiles.append(python)
            rejects("duplicate profile id") { try duplicate.validate() }
            let udl = Data(
                """
                <?xml version="1.0"?><NotepadPlus><UserLang name="Custom Test" ext="sample" udlVersion="2.1"><Settings><Global caseIgnored="yes" forcePureLC="0" decimalSeparator="0"/><Prefix Keywords1="no"/></Settings><KeywordLists><Keywords name="Keywords1">hello world</Keywords><Keywords name="Comments">00// 01 02 03/* 04*/</Keywords><Keywords name="Delimiters">00&quot; 01\\ 02&quot; 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23</Keywords></KeywordLists><Styles><WordsStyle name="KEYWORDS1" fgColor="0000FF" fontStyle="1" nesting="0"/></Styles></UserLang></NotepadPlus>
                """.utf8)
            let definitions = try UserDefinedLanguage.decode(udl), profile = try definitions[0].profile()
            check(
                profile.lexer == "user" && profile.keywordLists["7"] == "hello world"
                    && profile.properties["userDefine.isCaseIgnored"] == "1", "UDL maps keyword slot7 and case settings"
            )
            check(
                try UserDefinedLanguage.decode(definitions[0].encodedXML())[0].profile() == profile,
                "UDL export reimport preserves native profile")
            check(
                try UserDefinedLanguage.words("\"else if\" 'end if'") == "else\u{b}if end\u{8}if",
                "UDL quoted multipart keyword encoding")
            rejects("UDL external entity rejection") {
                _ = try UserDefinedLanguage.decode(
                    Data("<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><NotepadPlus/>".utf8))
            }
            rejects("UDL malformed XML") { _ = try UserDefinedLanguage.decode(Data("<NotepadPlus>".utf8)) }
            rejects("UDL unbalanced keyword quotes") { _ = try UserDefinedLanguage.words("\"open") }
            // F81: a user-defined language wins an extension a built-in profile also lists.
            check(catalog.detect(filename: "notes.txt", text: "") == "normal", "txt is Plain Text without a UDL")
            var withUDL = catalog, claiming = profile
            claiming.extensions = ["TXT", "h"]
            withUDL.profiles.append(claiming)
            check(
                withUDL.detect(filename: "notes.txt", text: "") == claiming.id
                    && withUDL.detect(filename: "x.h", text: "") == claiming.id,
                "imported UDL wins an extension a built-in profile lists")
            check(
                withUDL.detect(filename: "CMakeLists.txt", text: "") == "cmake",
                "special filename still beats a UDL that claims txt")
            check(
                withUDL.detect(filename: "HELLO.PY", text: "") == "python",
                "UDL precedence leaves other extensions alone"
            )
            // F95: the interpreter is parsed from the shebang line, not found as a substring.
            for (line, expected) in [
                ("#!/bin/sh\n", "bash"), ("#!/bin/bash -e\n", "bash"), ("#!/usr/bin/python3.11\n", "python"),
                ("#!/usr/bin/env node\n", "javascript.js"), ("#!/usr/bin/perl -w\n", "perl"),
                ("#!/usr/bin/env ruby\n", "ruby"), ("#!/usr/bin/env sh\n", "bash"), ("#!/bin/zsh\n", "bash"),
                ("#!/usr/bin/env zsh\n", "bash"), ("#!/usr/bin/env -S python3 -u\n", "python"),
                ("#! /bin/sh\n", "bash"), ("#!/opt/pythonapps/bin/ruby\n", "ruby"),
                ("#!/usr/bin/env PYTHONPATH=/x ipython\r\nprint(1)", "python"),
                ("#!/usr/local/bin/ts-node", "javascript.js"),
                ("#!/usr/bin/python-3\n", "python")
            ] {
                check(
                    catalog.detect(filename: "script", text: line) == expected,
                    "shebang \(line.debugDescription) detects \(expected)")
            }
            for line in ["#!/opt/node/bin/unknowninterp\n", "#!/shared/bin/foo\n", "#!\n/bin/sh\n", "#!/usr/bin/env\n"]
            {
                check(
                    catalog.detect(filename: "script", text: line) == nil,
                    "shebang \(line.debugDescription) names no known interpreter")
            }
            check(
                catalog.detect(filename: "script", text: "#!" + String(repeating: " ", count: 600) + "/bin/sh\n")
                    == nil,
                "shebang parsing reads only the bounded first 512 characters")
            check(
                catalog.detect(filename: "x.rb", text: "#!/usr/bin/env python\n") == "ruby",
                "extension still beats shebang"
            )
            check(
                catalog.detect(filename: "Dockerfile", text: "") == nil,
                "Dockerfile has no bundled profile; the entry is a hook for user catalogs")
            var docker = catalog
            docker.profiles.append(python)
            docker.profiles[docker.profiles.count - 1].id = "dockerfile"
            docker.profiles[docker.profiles.count - 1].extensions = []
            check(
                docker.detect(filename: "Dockerfile", text: "") == "dockerfile",
                "a user catalog with a dockerfile profile gets Dockerfile detection")
            check(
                catalog.detect(filename: ".zprofile", text: "") == "bash"
                    && catalog.detect(filename: ".profile", text: "") == "bash", "shell start-up files detect as shell")
            // F80: line numbers are counted incrementally and agree with a count from the start.
            func referenceLine(_ text: String, _ location: Int) -> Int {
                var line = 1, previous: UInt16 = 0
                for unit in text.utf16.prefix(location) {
                    if unit == 13 || (unit == 10 && previous != 13) { line += 1 }
                    previous = unit
                }
                return line
            }
            let mixed =
                "def a():\r\n\rdef b():\n\n\r\ndef c():\rdef d():\r\n\r\n    def é():\n# 🙂\r\nclass F:\n\rdef g():"
            let mixedSymbols = try LanguageFunctions.symbols(text: mixed, profile: python)
            check(
                mixedSymbols.map(\.name) == ["a", "b", "c", "d", "é", "F", "g"]
                    && mixedSymbols.map(\.line) == mixedSymbols.map { referenceLine(mixed, $0.range.location) }
                    && mixedSymbols.map(\.line) == [1, 3, 6, 7, 9, 11, 13],
                "function list lines count CR, LF and CRLF once each (\(mixedSymbols.map(\.line)))")
            let bigUnit =
                String(repeating: "# padding that makes the document large enough to matter\r\n", count: 3)
                + "def name():\n    pass\r"
            let big = String(repeating: bigUnit, count: 1024 * 1024 / bigUnit.utf8.count)
            let scale = Double(ProcessInfo.processInfo.environment["TEXTTANK_PERF_BUDGET_SCALE"] ?? "") ?? 1
            let bigStart = ProcessInfo.processInfo.systemUptime
            let bigSymbols = try LanguageFunctions.symbols(text: big, profile: python, timeLimit: 2 * scale)
            let bigTime = ProcessInfo.processInfo.systemUptime - bigStart
            check(
                bigSymbols.count == 1024 * 1024 / bigUnit.utf8.count && bigSymbols.count > 5000
                    && bigSymbols.last?.line == referenceLine(big, bigSymbols.last!.range.location),
                "function list of a 1 MiB file with \(bigSymbols.count) symbols stays inside its time limit (\(String(format: "%.3f", bigTime)) s)"
            )
            // G333: only text inside quotes arms the multi-part marker, as upstream setUserLexer does.
            for (input, expected) in [
                ("foo \"  bar\"", "foo bar"), ("\"  else if  \"", "else\u{b}if"), ("'end if '", "end\u{8}if"),
                ("x ' y z'", "x y\u{8}z"), ("\"it's ok\"", "it's\u{b}ok"), ("a\\\"b \\\\ c\\'d", "a\"b \\ c'd"),
                ("\"é ü\"", "é\u{b}ü")
            ] {
                check(
                    try UserDefinedLanguage.words(input) == expected,
                    "UDL keyword quoting \(input.debugDescription) gives \(expected.debugDescription)")
            }
            // F82, F98: tolerant import of minor style fields, strict where it matters.
            func udlXML(styles: String, keywords: String = "<Keywords name=\"Keywords1\">hello world</Keywords>")
                -> Data
            {
                Data(
                    "<?xml version=\"1.0\"?><NotepadPlus><UserLang name=\"Minor Fields\" ext=\"minor\" udlVersion=\"2.1\"><Settings><Global caseIgnored=\"no\"/><Prefix/></Settings><KeywordLists>\(keywords)</KeywordLists><Styles>\(styles)</Styles></UserLang></NotepadPlus>"
                        .utf8)
            }
            func importedStyle(_ attributes: String, name: String = "KEYWORDS1") throws -> LanguageProfile.Style {
                let made = try UserDefinedLanguage.decode(
                    udlXML(styles: "<WordsStyle name=\"\(name)\" \(attributes)/>"))[0].profile()
                return try requireValue(made.styles.first, "fixture: imported style")
            }
            check(
                try importedStyle("fontStyle=\"1\"").useCustomColor != true,
                "UDL style with no fgColor follows the appearance")
            check(
                try importedStyle("fgColor=\"000000\"", name: "DEFAULT").useCustomColor != true,
                "UDL black default text follows the appearance")
            check(
                try importedStyle("fgColor=\"FFFFFF\"").useCustomColor != true
                    && importedStyle("fgColor=\"FF0000\" colorStyle=\"2\"").useCustomColor != true,
                "UDL near-white and foreground-disabled colours follow the appearance")
            let blue = try importedStyle("fgColor=\"0000FF\"")
            check(blue.useCustomColor == true && blue.foreground == "0000FF", "UDL chromatic colour stays fixed")
            let verbatim = try UserDefinedLanguage.decode(
                udlXML(styles: "<WordsStyle name=\"DEFAULT\" fgColor=\"000000\" bgColor=\"FFFFFF\" colorStyle=\"1\"/>"))[
                    0]
            let verbatimXML = String(decoding: try verbatim.encodedXML(), as: UTF8.self)
            check(
                verbatimXML.contains("fgColor=\"000000\"") && verbatimXML.contains("bgColor=\"FFFFFF\"")
                    && verbatimXML.contains("colorStyle=\"1\""),
                "UDL export keeps fgColor, bgColor and colorStyle verbatim")
            check(
                try importedStyle("fgColor=\"000000\" texttankCustomColor=\"1\"").useCustomColor == true
                    && importedStyle("fgColor=\"0000FF\" texttankCustomColor=\"0\"").useCustomColor == false,
                "an explicit custom-colour choice stored in the UDL overrides the import rule")
            let emptyNumbers = try importedStyle("fgColor=\"0000FF\" fontStyle=\"\" nesting=\" \"")
            check(emptyNumbers.fontStyle == 0, "UDL empty fontStyle and nesting mean 0")
            check(
                try importedStyle("fontSize=\"\"").fontSize == nil && importedStyle("fontSize=\"0\"").fontSize == nil
                    && importedStyle("fontSize=\"nan\"").fontSize == nil
                    && importedStyle("fontSize=\"inf\"").fontSize == nil
                    && importedStyle("fontSize=\"-4\"").fontSize == nil,
                "UDL empty, zero and non-finite font sizes mean the editor size")
            check(
                try importedStyle("fontSize=\"5\"").fontSize == 6 && importedStyle("fontSize=\"200\"").fontSize == 72
                    && importedStyle("fontSize=\"11.5\"").fontSize == 11.5,
                "UDL font size is clamped to 6–72 for the applied style")
            let small = try UserDefinedLanguage.decode(
                udlXML(styles: "<WordsStyle name=\"KEYWORDS1\" fontSize=\"5\"/>"))[0]
            check(
                try UserDefinedLanguage.decode(small.encodedXML())[0].profile() == small.profile()
                    && String(decoding: small.encodedXML(), as: UTF8.self).contains("fontSize=\"5\""),
                "UDL export keeps the file's own font size")
            for (attributes, field) in [
                ("fontStyle=\"x\"", "fontStyle"), ("fontStyle=\"8\"", "fontStyle"), ("nesting=\"-1\"", "nesting"),
                ("fgColor=\"12345\"", "fgColor"), ("fgColor=\"GGGGGG\"", "fgColor")
            ] {
                rejects(
                    "UDL \(attributes) is rejected naming the style",
                    where: { $0.localizedDescription.contains("KEYWORDS1") && $0.localizedDescription.contains(field) }
                ) { _ = try importedStyle(attributes) }
            }
            var strict = python
            strict.styles = [.init(id: 1, name: "X", foreground: "000000", fontStyle: 0, fontSize: 5)]
            rejects("profile validation stays strict about font size") { try strict.validate() }
            strict.styles = [.init(id: 1, name: "X", foreground: "00000G", fontStyle: 0)]
            rejects("profile validation stays strict about colours") { try strict.validate() }
            strict.styles = [.init(id: 1, name: "X", foreground: "0000000", fontStyle: 0)]
            rejects("profile validation rejects a seven-digit colour") { try strict.validate() }
            strict.styles = [.init(id: 1, name: "X", foreground: "000000", fontStyle: 8)]
            rejects("profile validation stays strict about font style") { try strict.validate() }
            let longOperators = String(repeating: "+ ", count: 2500)
            let longList = try UserDefinedLanguage.decode(
                udlXML(styles: "", keywords: "<Keywords name=\"Operators1\">\(longOperators)</Keywords>"))[0].profile()
            check(
                longList.properties["userDefine.operators1"]?.count == 5000,
                "a 5,000-character UDL Operators1 list imports")
            rejects("an oversized UDL Operators1 list is rejected by name", message: "Operators1") {
                _ = try UserDefinedLanguage.decode(
                    udlXML(
                        styles: "",
                        keywords: "<Keywords name=\"Operators1\">\(String(repeating: "+ ", count: 40000))</Keywords>"))
            }
            strict = python
            strict.properties["lexer.python.extra"] = String(repeating: "x", count: 4097)
            rejects("an ordinary 4,097-character property is still rejected") { try strict.validate() }
            strict.properties = ["userDefine.operators1": String(repeating: "x", count: 5000)]
            rejects("the larger list bound applies to the user lexer only") { try strict.validate() }
            var oversized = longList
            oversized.properties["userDefine.operators1"] = String(repeating: "x", count: 65537)
            rejects("a user list property beyond the new bound is rejected") { try oversized.validate() }
            oversized.properties["userDefine.operators1"] = "+"
            oversized.properties["userDefine.isCaseIgnored"] = String(repeating: "1", count: 4097)
            rejects("other user lexer properties keep the 4,096 bound") { try oversized.validate() }
            // F99: Edit Current UDL and re-import keep what the XML cannot express.
            var customised = profile
            customised.id = "udl.kept-identifier"
            customised.functionPattern = "(?m)^fn (\\w+)"
            customised.styles[0].useCustomColor = false
            customised.comments?.line = "#"
            let edited = try UserDefinedLanguage.decode(
                Data(
                    String(decoding: udl, as: UTF8.self).replacingOccurrences(of: "hello world", with: "hello there")
                        .utf8))[0]
            let merged = try edited.profile(preserving: customised)
            check(
                merged.functionPattern == customised.functionPattern && merged.styles[0].useCustomColor == false
                    && merged.comments?.line == "#" && merged.comments?.blockOpen == "/*"
                    && merged.keywordLists["7"] == "hello there" && merged.id == "udl.kept-identifier"
                    && merged.udl == edited, "editing a UDL keeps function pattern, colour choice and comment override")
            check((try? merged.validate()) != nil, "merged UDL profile validates")
            let recoloured = try UserDefinedLanguage.decode(
                Data(String(decoding: udl, as: UTF8.self).replacingOccurrences(of: "0000FF", with: "AA5500").utf8))[0]
                .profile(preserving: customised)
            check(
                recoloured.styles[0].useCustomColor == true && recoloured.styles[0].foreground == "AA5500",
                "a colour changed in the UDL XML is used, not the old adaptive choice")
            var derivedComments = profile
            derivedComments.functionPattern = nil
            let recommented = try UserDefinedLanguage.decode(
                Data(String(decoding: udl, as: UTF8.self).replacingOccurrences(of: "00// ", with: "00-- ").utf8))[0]
                .profile(preserving: derivedComments)
            check(recommented.comments?.line == "--", "comment markers edited in the UDL XML still take effect")
            check(
                try definitions[0].profile(preserving: nil) == profile,
                "with nothing to preserve the UDL profile is unchanged")
            // F144: a DTD cannot reach the parser behind an encoding the text scan does not read.
            // A complete definition behind the DTD, so that nothing but the DTD is a reason to refuse it.
            let dtd = String(decoding: udl, as: UTF8.self).replacingOccurrences(
                of: "<?xml version=\"1.0\"?>", with: "<?xml version=\"1.0\"?><!DOCTYPE N [<!ENTITY a \"x\">]>")
            check(dtd.contains("<!DOCTYPE") && dtd.contains("<UserLang"), "fixture: the DTD sample is a whole UDL")
            rejects("UDL UTF-16 LE without BOM carrying a DTD", message: "DTD") {
                _ = try UserDefinedLanguage.decode(dtd.data(using: .utf16LittleEndian)!)
            }
            rejects("UDL UTF-16 BE without BOM carrying a DTD", message: "DTD") {
                _ = try UserDefinedLanguage.decode(dtd.data(using: .utf16BigEndian)!)
            }
            let utf7 = Data(
                ("<?xml version=\"1.0\" encoding=\"UTF-7\"?>+ADwAIQ-DOCTYPE NotepadPlus +AFsAPAAh-ENTITY a +ACI-x+ACIAPgBdAD4-"
                    + "<NotepadPlus><UserLang name=\"Seven\" ext=\"s\" udlVersion=\"2.1\"><Settings><Global caseIgnored=\"no\"/></Settings><KeywordLists><Keywords name=\"Keywords1\">a</Keywords></KeywordLists><Styles></Styles></UserLang></NotepadPlus>")
                    .utf8)
            rejects("UDL declaring UTF-7 with an escaped DTD", message: "DTD") {
                _ = try UserDefinedLanguage.decode(utf7)
            }
            rejects("UDL DOCTYPE with no declarations") {
                _ = try UserDefinedLanguage.decode(
                    Data(
                        String(decoding: udl, as: UTF8.self).replacingOccurrences(
                            of: "<NotepadPlus>", with: "<!DOCTYPE NotepadPlus><NotepadPlus>"
                        ).utf8))
            }
            check(
                try UserDefinedLanguage.decode(Data([0xEF, 0xBB, 0xBF]) + udl)[0].profile() == profile,
                "UDL with a UTF-8 byte order mark still imports")
            check(
                try UserDefinedLanguage.decode(
                    Data(
                        String(decoding: udl, as: UTF8.self).replacingOccurrences(
                            of: "<?xml version=\"1.0\"?>", with: "<?xml version=\"1.0\" encoding=\"Windows-1252\"?>"
                        ).utf8))[0].profile() == profile, "UDL declaring Windows-1252 still imports")
            // F77, G365: the stored file holds only changes, merged over the bundled catalog.
            var changedCatalog = catalog
            let pythonIndex = try requireValue(
                catalog.profiles.firstIndex { $0.id == "python" }, "fixture: python index")
            changedCatalog.profiles[pythonIndex].styles[0].foreground = "123456"
            changedCatalog.profiles[pythonIndex].styles[0].useCustomColor = true
            changedCatalog.profiles[0].title = "My plain language"
            changedCatalog.profiles.removeAll { $0.id == "cobol" }
            changedCatalog.profiles.append(customised)
            let overrides = LanguageOverrides(changing: catalog, to: changedCatalog)
            let overridesBytes = try overrides.encoded()
            check(
                overrides.changed.map(\.id) == ["normal", "python"] && overrides.added.map(\.id) == [customised.id]
                    && overrides.removed == ["cobol"] && overrides.order == nil
                    && overrides.changed[1].keywordLists == nil && overrides.changed[1].styles != nil
                    && overrides.basedOnSourceCommit == catalog.sourceCommit && overridesBytes.count < 40_000,
                "only the changed fields of changed profiles are stored (\(overridesBytes.count) bytes)")
            check(
                try LanguageCatalog.load(stored: overridesBytes, over: catalog) == changedCatalog,
                "stored changes merge back to exactly the edited catalog")
            // A later app version: one more language, a corrected keyword list, a new comment marker.
            var later = catalog
            later.sourceCommit = "later"
            later.profiles[pythonIndex].keywordLists["0"] = "corrected keywords"
            later.profiles[0].extensions = ["txt", "text"]
            var added = python
            added.id = "brand-new"
            added.title = "Brand New"
            added.extensions = ["brandnew"]
            later.profiles.insert(added, at: 5)
            let upgraded = try LanguageCatalog.load(stored: overridesBytes, over: later)
            let upgradedPython = try requireValue(
                upgraded.profiles.first { $0.id == "python" }, "fixture: upgraded python")
            check(
                upgraded.profiles.contains { $0.id == "brand-new" } && upgraded.sourceCommit == "later"
                    && upgradedPython.keywordLists["0"] == "corrected keywords"
                    && upgradedPython.styles[0].foreground == "123456"
                    && upgraded.profiles[0].title == "My plain language"
                    && upgraded.profiles[0].extensions == ["txt", "text"]
                    && !upgraded.profiles.contains { $0.id == "cobol" } && upgraded.profiles.last == customised,
                "a later bundled catalog reaches every field the user left alone, and user changes still win")
            // A full copy written before overrides existed still loads, with every customisation.
            var fork = changedCatalog
            for index in fork.profiles.indices where fork.profiles[index].udl == nil {
                fork.profiles[index].comments = nil
            }
            let forkBytes = try fork.encoded()
            let migrated = try LanguageCatalog.load(stored: forkBytes, over: catalog)
            check(
                migrated.profiles.count == 97 && migrated.profiles.contains { $0.id == "cobol" }
                    && migrated.profiles.first { $0.id == "python" }
                        == changedCatalog.profiles.first { $0.id == "python" }
                    && migrated.profiles.first { $0.id == "python" }?.styles[0].foreground == "123456"
                    && migrated.profiles[0].title == "My plain language"
                    && migrated.profiles[0].comments == catalog.profiles[0].comments
                    && migrated.profiles.first { $0.id == customised.id } == customised
                    && migrated.profiles.allSatisfy { $0.comments != nil },
                "a full-copy file keeps user edits, gains bundled languages it lacks and inherits missing comments")
            let migratedLater = try LanguageCatalog.load(stored: forkBytes, over: later)
            check(
                migratedLater.profiles.contains { $0.id == "brand-new" }
                    && migratedLater.profiles.first { $0.id == "python" }?.styles[0].foreground == "123456"
                    && migratedLater.profiles[0].title == "My plain language",
                "a full-copy file that lacks a bundled identifier gains it, and its edited profile is not reverted")
            var uncommented = catalog
            uncommented.profiles[pythonIndex].comments = nil
            uncommented.profiles[pythonIndex].functionPattern = nil
            uncommented.profiles[0].comments = .init()
            let uncommentedStored = try LanguageOverrides(changing: catalog, to: uncommented).encoded()
            let uncommentedBack = try LanguageCatalog.load(stored: uncommentedStored, over: later)
            check(
                uncommentedBack.profiles.first { $0.id == "python" }?.comments == nil
                    && uncommentedBack.profiles.first { $0.id == "python" }?.functionPattern == nil
                    && uncommentedBack.profiles[0].comments == .init() && uncommentedBack.profiles[1].comments != nil,
                "removed comments and function pattern stay removed; an empty comments object means none")
            var reordered = catalog
            reordered.profiles.swapAt(1, 40)
            let reorderedStored = LanguageOverrides(changing: catalog, to: reordered)
            check(
                try reorderedStored.changed.isEmpty && reorderedStored.order?.count == 96
                    && LanguageCatalog.load(stored: try reorderedStored.encoded(), over: catalog) == reordered,
                "a reordered catalog keeps its order")
            check(
                LanguageOverrides(changing: catalog, to: catalog)
                    == LanguageOverrides(basedOnSourceCommit: catalog.sourceCommit, changed: [], added: [], removed: []),
                "an unchanged catalog stores no changes")
            let golden = try Data(
                contentsOf: TestPaths.fixtures.appendingPathComponent("persistence/LanguageCatalog.json"))
            let goldenCatalog = try LanguageCatalog.decode(golden),
                goldenLoaded = try LanguageCatalog.load(stored: golden, over: catalog)
            check(
                goldenLoaded.profiles.count == 96 + goldenCatalog.profiles.count
                    && goldenCatalog.profiles.allSatisfy { goldenLoaded.profiles.contains($0) }
                    && goldenLoaded.sourceCommit == catalog.sourceCommit
                    && LanguageOverrides(changing: catalog, to: goldenLoaded).added == goldenCatalog.profiles,
                "the golden full-copy catalog keeps every profile through the move to overrides")
            var badOverrides = overrides
            badOverrides.overridesVersion = 2
            let encoder = JSONEncoder()
            rejects("unsupported overrides version") {
                _ = try LanguageCatalog.load(stored: encoder.encode(badOverrides), over: catalog)
            }
            badOverrides = overrides
            badOverrides.added.append(customised)
            rejects("duplicate added identifiers") {
                _ = try LanguageCatalog.load(stored: encoder.encode(badOverrides), over: catalog)
            }
            badOverrides = overrides
            badOverrides.changed[0].title = ""
            rejects("an override that makes a profile invalid") {
                _ = try LanguageCatalog.load(stored: encoder.encode(badOverrides), over: catalog)
            }
            rejects("stored catalog version 2") {
                _ = try LanguageCatalog.load(
                    stored: Data(
                        String(decoding: forkBytes, as: UTF8.self).replacingOccurrences(
                            of: "\"version\" : 1", with: "\"version\" : 2"
                        ).utf8),
                    over: catalog)
            }
            let handwritten = try LanguageCatalog.decode(
                Data(
                    "{\"version\":1,\"profiles\":[{\"id\":\"mine\",\"title\":\"Mine\",\"lexer\":\"null\",\"extensions\":[],\"keywordLists\":{},\"referenceKeywordClasses\":{},\"properties\":{},\"styles\":[]}]}"
                        .utf8))
            check(
                handwritten.profiles.map(\.id) == ["mine"] && handwritten.sourceCommit.isEmpty,
                "a catalog written by hand needs no provenance fields")
            rejects("catalog without a version") { _ = try LanguageCatalog.decode(Data("{\"profiles\":[]}".utf8)) }
            check(
                LanguageProfile.canonicalID("null") == "normal" && LanguageProfile.canonicalID(nil) == "normal"
                    && LanguageProfile.canonicalID("python") == "python"
                    && catalog.profiles.contains { $0.id == LanguageProfile.plainTextID && $0.lexer == "null" },
                "one plain-text identifier; the legacy session value maps to it")
            Checks.summary {
                "PASS LanguageChecks: \(Checks.count) assertions; data/navigation core, not complete lexer semantics"
            }
        }
    }
}
