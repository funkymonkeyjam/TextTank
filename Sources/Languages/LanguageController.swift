import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin

/// The Syntax Highlighting menu. Its contents follow the catalog, so it is rebuilt only when that changed.
private final class LanguageMenu: NSMenu {
    var generation = -1
}
/// The languages a person chose most recently, newest first, kept in the private support
/// folder so the chooser can offer them again after a relaunch.
///
/// The file holds language identifiers only. It is a convenience, so a failure to read or
/// write it is never an alert (DS-40); the chooser then works from the list in memory. A file
/// this version cannot read because a later one wrote it is left as it is.
@MainActor final class LanguageRecentsStore {
    static let limit = 5
    static let maximumBytes = 16 * 1024
    private struct File: Codable {
        var version: Int
        var languages: [String]
    }
    let url: URL
    private(set) var ids: [String] = []
    private var replaceable = true
    init(url: URL? = nil) {
        self.url = url ?? AppStorage.url(.languageRecents)
        do {
            let data = try PrivateFileStore.read(self.url, maximumBytes: Self.maximumBytes)
            guard let file = try? JSONDecoder().decode(File.self, from: data) else { return }
            if file.version == 1 { ids = Self.bounded(file.languages) } else { replaceable = false }
        } catch where error.isFileNotFound {} catch {
            // Too large, not a regular file or not readable: do not write over what is there.
            replaceable = false
        }
    }
    private static func bounded(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return Array(ids.filter { !$0.isEmpty && $0.utf8.count <= 256 && seen.insert($0).inserted }.prefix(limit))
    }
    func note(_ id: String) {
        let previous = ids
        ids = Self.bounded([id] + ids)
        guard replaceable, ids != previous else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(File(version: 1, languages: ids))
            try PrivateFileStore.prepareDirectory(url.deletingLastPathComponent())
            try PrivateFileStore.write(data, to: url, maximumBytes: Self.maximumBytes)
        } catch {}
    }
}
@MainActor final class LanguageController: NSObject, NSMenuDelegate {
    private let editorProvider: () -> TTEditor?
    private let languageProvider: () -> String
    private let setLanguage: (String) -> Void
    /// The other views of the document `editor` shows: the other pane of a split view. Injected,
    /// like `openDocuments`, so this file needs no application types.
    var siblingViews: (TTEditor) -> [TTEditor] = { _ in [] }
    /// One view of every open document, with that document's language identifier.
    var openDocuments: () -> [(language: String, editor: TTEditor)] = { [] }
    private(set) var catalog: LanguageCatalog? {
        didSet {
            profileIndex = catalog?.indexByID() ?? [:]
            menuEntries = nil
            generation += 1
        }
    }
    /// The catalog shipped with the app, decoded once. User changes are stored as differences from it.
    private var bundled: LanguageCatalog?
    private var profileIndex: [String: Int] = [:]
    private var menuEntries: [(title: String, id: String)]?
    private var generation = 0
    /// Why the stored LanguageProfiles.json, or the bundled catalog, could not be used.
    let loadState: StoreLoadState
    private(set) var loadError: Error? {
        get { loadState.error }
        set { loadState.error = newValue }
    }
    /// True when the stored file is the one that failed. The bundled catalog is then in use, the
    /// file is left exactly as it is, and nothing is saved until it has been moved aside.
    private(set) var storageDamaged = false
    /// Shown once at launch, like the settings notice: without it imported languages and style
    /// changes would simply be missing until a Language dialog was opened.
    var loadFailureMessage: String? {
        guard storageDamaged, let loadError else { return nil }
        return
            "The saved language profiles could not be read, so the built-in languages are in use. The file has not been changed. Open any Language settings command to move it aside.\n\nReason: \(loadError.localizedDescription)\n\nFile: \(storage.path)"
    }
    private let storage: URL
    private var navigator: LanguageFunctionController?
    /// Called with the reason when a caret jump that macros cannot record has happened (F277).
    var onUnrecordableCommand: ((String) -> Void)?
    /// Where the bundled catalog is. Check executables have no bundle and set this to the
    /// repository's copy before they construct a controller or an AppDelegate.
    static var bundledCatalogURL = Bundle.main.url(forResource: "LanguageProfiles", withExtension: "json")
    convenience init(
        editorProvider: @escaping () -> TTEditor?, languageProvider: @escaping () -> String,
        setLanguage: @escaping (String) -> Void
    ) {
        self.init(
            editorProvider: editorProvider, languageProvider: languageProvider,
            setLanguage: setLanguage, bundledCatalog: Self.bundledCatalogURL)
    }
    init(
        editorProvider: @escaping () -> TTEditor?, languageProvider: @escaping () -> String,
        setLanguage: @escaping (String) -> Void, bundledCatalog: URL?
    ) {
        self.editorProvider = editorProvider
        self.languageProvider = languageProvider
        self.setLanguage = setLanguage
        storage = AppStorage.url(.languages)
        loadState = StoreLoadState(url: storage, displayName: "Language profiles")
        super.init()
        load(bundledCatalog)
    }
    /// Reads the bundled catalog once, then the user's changes over it.
    private func load(_ bundledCatalog: URL?) {
        let defaults: LanguageCatalog
        do {
            guard let bundledCatalog else {
                throw LanguageError.invalid("The language catalog is missing from the application.")
            }
            defaults = try LanguageCatalog.decode(Self.readRegular(bundledCatalog))
        } catch {
            loadError = error
            return
        }
        bundled = defaults
        do {
            catalog = try LanguageCatalog.load(stored: Self.readRegular(storage, parent: .strict), over: defaults)
        } catch  where error.isFileNotFound { catalog = defaults } catch {
            // The bundled languages keep working; the unreadable file is never overwritten.
            catalog = defaults
            loadError = error
            storageDamaged = true
        }
    }
    /// The Syntax Highlighting menu: Normal Text, the languages in alphabetical ranges, then the
    /// style and profile settings (DS-23).
    func menu() -> NSMenu {
        let menu = LanguageMenu(title: "Syntax Highlighting")
        menu.delegate = self
        populate(menu)
        return menu
    }
    func completeWordMenuItem() -> NSMenuItem { commandItem("Complete Word", #selector(complete)) }
    func functionListMenuItem() -> NSMenuItem { commandItem("Function List…", #selector(functions)) }
    func keywordHelpMenuItem() -> NSMenuItem { commandItem("Show Keyword Help", #selector(callTip)) }
    private func commandItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
    private func populate(_ menu: LanguageMenu) {
        menu.removeAllItems()
        // The filterable chooser comes first: it is the quick way to a language by name. The
        // ranges below keep every profile, the internal ones included, one level down (DS-23).
        // No target: the document window that has the keyboard answers, as it does for Go to
        // Line, and the item is disabled when there is none (DS-21).
        menu.addItem(NSMenuItem(title: "Choose Language…", action: #selector(chooseLanguage(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        var languages = languageMenuItems()
        if let plain = languages.firstIndex(where: { $0.representedObject as? String == LanguageProfile.plainTextID }) {
            menu.addItem(languages.remove(at: plain))
            menu.addItem(.separator())
        }
        var next = languages.startIndex
        for range in Self.alphabeticalRanges(languages.map(\.title)) {
            let parent = NSMenuItem(title: range.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: range.title)
            languages[next..<next + range.count].forEach(submenu.addItem)
            next += range.count
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(styleSettingsMenuItem())
        menu.addItem(commandItem("Edit Language Profiles…", #selector(configure)))
        let userDefined = NSMenu(title: "User-Defined Languages")
        userDefined.addItem(commandItem("Import Notepad++ UDL…", #selector(importUDL)))
        userDefined.addItem(commandItem("Edit Current UDL…", #selector(editUDL)))
        userDefined.addItem(commandItem("Export Current UDL…", #selector(exportUDL)))
        let userDefinedItem = NSMenuItem(title: userDefined.title, action: nil, keyEquivalent: "")
        userDefinedItem.submenu = userDefined
        menu.addItem(userDefinedItem)
        menu.generation = generation
    }
    /// Splits titles that are already in menu order into runs of at most `limit` (DS-23), titled
    /// by the initial letters they hold: "A–C" or "S". Initial letters stay whole and the runs
    /// are evened out, so that the last is not a stub. Only a letter with more than `limit`
    /// titles of its own is divided, into runs titled by two letters: "Pa–Pe".
    static func alphabeticalRanges(_ titles: [String], limit: Int = 20) -> [(title: String, count: Int)] {
        func initial(_ title: String) -> String { String(title.prefix(1)).uppercased() }
        func twoLetters(_ title: String) -> String { initial(title) + title.dropFirst().prefix(1) }
        let wanted = max(1, (titles.count + limit - 1) / limit)
        let even = min(limit, (titles.count + wanted - 1) / wanted)
        var runs: [(first: String, last: String, count: Int)] = []
        var start = titles.startIndex
        while start < titles.endIndex {
            let letter = initial(titles[start])
            let end = titles[start...].firstIndex { initial($0) != letter } ?? titles.endIndex
            let count = end - start
            if count > limit {
                let pieces = (count + limit - 1) / limit, size = (count + pieces - 1) / pieces
                for from in stride(from: start, to: end, by: size) {
                    let to = min(from + size, end)
                    runs.append((twoLetters(titles[from]), twoLetters(titles[to - 1]), to - from))
                }
            } else if let last = runs.last, last.count + count <= even {
                runs[runs.count - 1] = (last.first, letter, last.count + count)
            } else {
                runs.append((letter, letter, count))
            }
            start = end
        }
        return runs.map { ($0.first == $0.last ? $0.first : $0.first + "–" + $0.last, $0.count) }
    }
    /// Checks the active document's language, and the range that holds it (DS-22).
    private func markCurrentLanguage(in menu: NSMenu) {
        let current = editorProvider() == nil ? nil : languageProvider()
        for item in menu.items {
            if let range = item.submenu {
                let languages = range.items.filter { $0.action == #selector(selectLanguage(_:)) }
                languages.forEach { $0.state = $0.representedObject as? String == current ? .on : .off }
                if !languages.isEmpty { item.state = languages.contains { $0.state == .on } ? .on : .off }
            } else if item.action == #selector(selectLanguage(_:)) {
                item.state = item.representedObject as? String == current ? .on : .off
            }
        }
    }
    func styleSettingsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Syntax Style Settings…", action: #selector(styleSettings), keyEquivalent: "")
        item.target = self
        return item
    }
    /// Every profile whose lexer is linked, by the name a person reads (DS-24). The sorted list
    /// is kept until the catalog changes.
    private func sortedEntries() -> [(title: String, id: String)] {
        if menuEntries == nil {
            let available = Set(TTEditor.availableLanguages())
            menuEntries = (catalog?.profiles ?? []).filter { available.contains($0.lexer) }
                .map { ($0.displayName, $0.id) }
                .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        }
        return menuEntries ?? []
    }
    /// The name shown for a language wherever one is named: the status bar, the chooser and the
    /// Syntax Highlighting menu. An identifier with no profile is Plain Text or, for a language
    /// whose profile has since been removed, the identifier that was stored.
    func displayName(identifier: String) -> String {
        profile(identifier: identifier)?.displayName
            ?? (identifier == LanguageProfile.plainTextID ? "Plain Text" : identifier)
    }
    /// One item per profile whose lexer is linked, by display name.
    func languageMenuItems() -> [NSMenuItem] {
        return sortedEntries().map {
            let item = NSMenuItem(title: $0.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = $0.id
            return item
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let menu = menu as? LanguageMenu else { return }
        if menu.generation != generation { populate(menu) }
        markCurrentLanguage(in: menu)
    }
    /// No item here has a key equivalent, so a key press never needs this menu brought up to date.
    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool { false }
    /// Moves the stored file that could not be read to a sibling name and returns that name. The
    /// node itself is renamed, never copied or followed, so a symbolic link is moved as a link.
    /// Until this has run, `persist` refuses to write.
    @discardableResult func quarantineDamagedStorage() throws -> URL {
        guard storageDamaged else { throw LanguageError.invalid("The language profiles file is not damaged.") }
        guard let destination = try loadState.moveAside(tag: "damaged") else {
            throw LanguageError.invalid("The language profiles entry no longer exists.")
        }
        storageDamaged = false
        loadError = nil
        return destination
    }
    /// The gate in front of every dialog that ends in a save. False means the person cancelled.
    private func ensureWritable() throws -> Bool {
        guard let loadError else { return true }
        guard storageDamaged else { throw loadError }
        guard try StoreRecovery.ensureWritable(loadState) else { return false }
        storageDamaged = false
        return true
    }

    @objc private func importUDL() {
        do {
            guard try ensureWritable() else { return }
            guard var proposed = catalog else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let imported = try UserDefinedLanguage.decode(Self.readRegular(url))
            for definition in imported {
                var profile = try definition.profile()
                if let index = proposed.profiles.firstIndex(where: { $0.id == profile.id }) {
                    profile = try definition.profile(preserving: proposed.profiles[index])
                    proposed.profiles[index] = profile
                } else {
                    proposed.profiles.append(profile)
                }
            }
            try persist(proposed)
            // An import can replace a profile that open documents already use.
            reapply(Set(try imported.map { try $0.profile().id }))
            if let first = imported.first, let editor = editorProvider() {
                let id = try first.profile().id
                if applyToDocument(identifier: id, through: editor) { setLanguage(id) }
            }
        } catch { TTAlert.present(error) }
    }
    @objc private func editUDL() {
        do {
            guard try ensureWritable() else { return }
            guard var proposed = catalog,
                let index = proposed.profiles.firstIndex(where: { $0.id == languageProvider() }),
                let definition = proposed.profiles[index].udl
            else { throw LanguageError.invalid("Choose an imported user-defined language first.") }
            let id = proposed.profiles[index].id
            let alert = TTAlert()
            alert.messageText = "Edit User-Defined Language"
            alert.informativeText =
                "Edit the UDL 2.x XML settings, keyword groups, comments, folding, delimiters and styles. Save validates the entire definition before changing it. Renaming here preserves the saved language identifier."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel", role: .cancel)
            let content = JSONLibraryEditor.makeTextView(size: NSSize(width: 700, height: 420))
            let scroll = content.scroll, text = content.editor
            text.setAccessibilityLabel("User-defined language XML")
            text.string = String(data: try definition.encodedXML(), encoding: .utf8)!
            alert.accessoryView = scroll
            while alert.runModal() == .alertFirstButtonReturn {
                do {
                    let definitions = try UserDefinedLanguage.decode(Data(text.string.utf8))
                    guard definitions.count == 1 else {
                        throw LanguageError.invalid("Edit exactly one UDL in this window.")
                    }
                    var profile = try definitions[0].profile(preserving: proposed.profiles[index])
                    profile.id = id
                    proposed.profiles[index] = profile
                    try persist(proposed)
                    reapply([id])
                    return
                } catch { TTAlert.present(error) }
            }
        } catch { TTAlert.present(error) }
    }
    @objc private func exportUDL() {
        do {
            guard let definition = catalog?.profiles.first(where: { $0.id == languageProvider() })?.udl else {
                throw LanguageError.invalid("Choose an imported user-defined language first.")
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "TextTank-UserLanguage.xml"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try definition.encodedXML().write(to: url, options: .atomic)
        } catch { TTAlert.present(error) }
    }
    func detect(filename: String, text: String) -> String? { catalog?.detect(filename: filename, text: text) }
    /// Applies a profile to a whole document. The lexer, keyword lists and properties belong to
    /// the document and are installed once, through `editor`; styles and fonts belong to a view,
    /// so every other view of the document then copies them. Applying the profile to a second
    /// view instead would install the lexer and lex the document a second time.
    @discardableResult func applyToDocument(identifier: String, through editor: TTEditor) -> Bool {
        guard apply(identifier: identifier, to: editor) else { return false }
        for view in siblingViews(editor) { view.adoptSyntaxStyles(from: editor) }
        return true
    }
    /// After the catalog changed: re-applies the named profiles (nil for every profile) to each
    /// open document that uses one, in all of its views. Documents on other profiles are left
    /// alone. A profile that no longer exists or has no lexer is skipped, as `apply` reports.
    func reapply(_ identifiers: Set<String>?) {
        var targets = openDocuments()
        if let editor = editorProvider(), !targets.contains(where: { $0.editor.sharesDocument(with: editor) }) {
            targets.append((languageProvider(), editor))
        }
        for target in targets where identifiers?.contains(target.language) ?? true {
            applyToDocument(identifier: target.language, through: target.editor)
        }
    }
    @discardableResult func apply(identifier: String, to editor: TTEditor) -> Bool {
        guard let profile = profile(identifier: identifier), TTEditor.availableLanguages().contains(profile.lexer)
        else { return false }
        // One bridge call, one lexing pass: lists from the previous profile are cleared inside it.
        var lists: [NSNumber: String] = [:]
        for (index, words) in profile.keywordLists {
            if let index = Int(index) { lists[NSNumber(value: index)] = words }
        }
        editor.setLanguage(profile.lexer, keywordLists: lists, properties: profile.properties)
        for style in profile.styles {
            editor.setSyntaxStyle(
                style.id, foreground: Self.color(style, imported: profile.udl != nil), background: nil,
                bold: style.fontStyle & 1 != 0,
                italic: style.fontStyle & 2 != 0)
            if style.fontName != nil || style.fontSize != nil {
                let face = style.fontName.flatMap { NSFont(name: $0, size: style.fontSize ?? 14)?.fontName }
                editor.setSyntaxFont(
                    style.id, faceOverride: face, sizeOverride: style.fontSize.map(NSNumber.init(value:)))
            }
        }
        return true
    }
    /// Keep Notepad++'s lexer style IDs and category names; resolve their presentation for
    /// this editor appearance. Fixed user/UDL RGB values remain explicit overrides.
    private static func color(_ style: LanguageProfile.Style, imported: Bool) -> NSColor {
        if style.useCustomColor == true { return rgb(style.foreground) }
        if imported { return .textColor }
        guard let category = SyntaxColor.category(style) else { return .textColor }
        let pair = category.colors, light = rgb(pair.light), dark = rgb(pair.dark)
        return NSColor(
            name: nil,
            dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
    }
    private enum SyntaxColor {
        case comment, string, keyword, type, function, number, property, tag, attribute
        case variable, `operator`, directive, escape, error

        // All pairs exceed 4.5:1 on the editor's paper/carbon backgrounds (DS-60/61).
        // Category separation is checked against actual Scintilla output in both appearances.
        var colors: (light: String, dark: String) {
            switch self {
            case .comment: return ("426B38", "89B66B")
            case .string: return ("A33A00", "F2A567")
            case .keyword: return ("6037C9", "B49AFF")
            case .type: return ("00676B", "51D4CF")
            case .function: return ("756400", "F8DD54")
            case .number: return ("AD235F", "F18EC8")
            case .property: return ("075DB4", "77B7FF")
            case .tag: return ("344CC5", "8EA8FF")
            case .attribute: return ("006F00", "A5F34D")
            case .variable: return ("334D7D", "B8D9EF")
            case .operator: return ("48545D", "C4CBC8")
            case .directive: return ("C0001B", "FF727C")
            case .escape: return ("006244", "64D9B3")
            case .error: return ("820000", "FF4E5E")
            }
        }
        static func category(_ style: LanguageProfile.Style) -> Self? {
            let name = style.name.uppercased()
            func has(_ fragments: String...) -> Bool { fragments.contains { name.contains($0) } }
            // Specific categories precede overlapping names, e.g. COMMENT DOC KEYWORD,
            // TYPE WORD, STRING ESCAPE, and FUNCTION COMMENT.
            if has("ERROR", "ILLEGAL", "BAD STRING", "WRONG") { return .error }
            if has("COMMENT", "BLOCKQUOTE") || name == "POD" { return .comment }
            if has("ESCAPE", "REGEX", "ENTITY") { return .escape }
            if has("PREPROC", "DIRECTIVE", "DECORATOR", "PRAGMA", "ANNOTATION", "IFDEF") { return .directive }
            if has("FRONT MATTER MARKER") { return .operator }
            if has("ATTRIBUTE") { return .attribute }
            if has("PROPERTY", "VALUE NAME", "FRONT MATTER KEY") || name == "KEY" { return .property }
            if has("TAG", "XML START", "XML END", "SGML COMMAND") { return .tag }
            if has("BUILTIN", "BUILT-IN", "BUILIN", "FUNC", "METHOD", "DEF NAME", "CALLABLE", "CMDLET") {
                return .function
            }
            if has("TYPE", "CLASS NAME", "ENUM", "INTERFACE") || ["CLASS", "STRUCT", "STRUCTURE"].contains(name) {
                return .type
            }
            if has("VAR", "SCALAR", "PARAMETER", "REGISTER") { return .variable }
            if has(
                "STRING", "CHARACTER", "TRIPLE", "HEREDOC", "VERBATIM", "BACKTICK", "TEMPLATE LIT.",
                "INLINE CODE", "CODE BLOCK", "FRONT MATTER") || name == "CHAR"
            {
                return .string
            }
            if has("NUMBER", "DIGIT", "CONSTANT", "LITERAL", "BOOL", "MONEY") { return .number }
            if has("KEYWORD", "INSTRUCTION", "RESERVED", "STATEMENT", "HEADER", "HEADING")
                || ["WORD", "WORD2", "CONTROL", "RETURN", "H1", "H2", "H3", "H4", "H5", "H6"].contains(name)
            {
                return .keyword
            }
            if has("OPERATOR", "DELIMITER", "SYMBOL", "BRACE", "HRULE") { return .operator }
            if has("LINK", "URI", "URL", "ULIST", "OLIST", "LIST ITEM") { return .property }
            if has("STRONG") { return .type }
            if has("EMPHASIS") || name.hasPrefix("EM1") || name.hasPrefix("EM2") { return .number }
            // Less common source categories retain their original hue family instead of
            // silently losing a chromatic Notepad++ style. Neutral source styles stay text.
            guard let value = UInt32(style.foreground, radix: 16) else { return nil }
            let r = Int((value >> 16) & 255), g = Int((value >> 8) & 255), b = Int(value & 255)
            guard max(r, g, b) - min(r, g, b) >= 32 else { return nil }
            if r >= g && r >= b { return g >= b ? .string : .number }
            if g >= r && g >= b { return b >= r ? .type : .comment }
            return r >= g ? .keyword : .property
        }
    }
    func profile(identifier: String) -> LanguageProfile? {
        guard let index = profileIndex[identifier], let profiles = catalog?.profiles, profiles.indices.contains(index)
        else { return nil }
        return profiles[index]
    }
    private static func rgb(_ hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16) ?? 0
        return NSColor(
            srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255, alpha: 1)
    }
    static func readStyle(
        _ original: LanguageProfile.Style, font: NSTextField, size: NSTextField, color: NSColor, custom: Bool,
        bold: Bool, italic: Bool, window: NSWindow
    ) throws -> LanguageProfile.Style {
        window.makeFirstResponder(nil)
        // A blank field follows the editor's font or size. The two are independent in Scintilla.
        let name = font.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            sizeText = NumericInput.text(size).trimmingCharacters(in: .whitespacesAndNewlines)
        let points = NumericInput.number(size)
        guard sizeText.isEmpty || points.map({ (6...72).contains($0) }) == true,
            name.isEmpty || NSFont(name: name, size: points ?? 12) != nil, let chosen = color.usingColorSpace(.sRGB)
        else {
            throw LanguageError.invalid(
                "Enter an installed font name and a size between 6 and 72 points, or leave a field blank to follow the editor."
            )
        }
        var style = original
        style.fontName = name.isEmpty ? nil : name
        style.fontSize = sizeText.isEmpty ? nil : points
        style.useCustomColor = custom
        style.fontStyle = (bold ? 1 : 0) + (italic ? 2 : 0)
        style.foreground = String(
            format: "%02X%02X%02X", Int((chosen.redComponent * 255).rounded()),
            Int((chosen.greenComponent * 255).rounded()), Int((chosen.blueComponent * 255).rounded()))
        return style
    }
    /// One row per style, in array order. `addItem(withTitle:)` would drop an earlier row with the
    /// same title, and the selected index is used as the index into `styles`.
    static func populateStylePicker(_ selector: NSPopUpButton, styles: [LanguageProfile.Style]) {
        selector.removeAllItems()
        var seen = Set<String>()
        for style in styles {
            var title = style.name.isEmpty ? "Style \(style.id)" : style.name
            if !seen.insert(title).inserted { title += " (style \(style.id))" }
            selector.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        if !styles.isEmpty { selector.selectItem(at: 0) }
    }
    /// Carries a saved style into the embedded UDL, so Edit Current UDL and export keep it.
    nonisolated static func mirror(_ style: LanguageProfile.Style, into udl: inout UserDefinedLanguage) {
        guard let index = udl.styles.firstIndex(where: { $0.name == style.name }) else { return }
        udl.styles[index].attributes["fontName"] = style.fontName
        udl.styles[index].attributes["fontSize"] = style.fontSize.map { String($0) }
        udl.styles[index].attributes["fontStyle"] = String(style.fontStyle)
        udl.styles[index].attributes["fgColor"] = style.foreground
        udl.styles[index].attributes[UserDefinedLanguage.customColorAttribute] =
            style.useCustomColor == true ? "1" : "0"
    }
    @objc func styleSettings() {
        do {
            guard try ensureWritable() else { return }
            guard var proposed = catalog,
                let profileIndex = proposed.profiles.firstIndex(where: { $0.id == languageProvider() })
            else { throw LanguageError.invalid("Choose a language first.") }
            if proposed.profiles[profileIndex].styles.isEmpty {
                proposed.profiles[profileIndex].styles = [
                    .init(id: 0, name: "DEFAULT", foreground: "15201F", fontStyle: 0)
                ]
            }
            let choose = TTAlert()
            choose.messageText = "Syntax Style Settings"
            choose.informativeText = "Choose the syntax category to customize for this language."
            choose.addButton(withTitle: "Edit")
            choose.addButton(withTitle: "Cancel", role: .cancel)
            let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28), pullsDown: false)
            selector.setAccessibilityLabel("Syntax style to customize")
            Self.populateStylePicker(selector, styles: proposed.profiles[profileIndex].styles)
            choose.accessoryView = selector
            guard choose.runModal() == .alertFirstButtonReturn, selector.indexOfSelectedItem >= 0 else { return }
            let styleIndex = selector.indexOfSelectedItem
            var style = proposed.profiles[profileIndex].styles[styleIndex]
            let edit = TTAlert()
            edit.messageText = "\(proposed.profiles[profileIndex].displayName) — \(style.name)"
            edit.informativeText =
                "Choose a font and size, or leave either blank to follow the editor. Custom RGB stays fixed in light/dark appearances; turn it off to use "
                + (proposed.profiles[profileIndex].udl == nil
                    ? "the adaptive native syntax palette" : "the editor's text color, which follows the appearance")
                + ". Changes affect this language only."
            edit.addButton(withTitle: "Save")
            edit.addButton(withTitle: "Cancel", role: .cancel)
            let font = NSTextField(string: style.fontName ?? ""),
                size = NSTextField(string: style.fontSize.map { NumericInput.editable($0) } ?? "")
            NumericInput.configure(size, fractional: true)
            font.placeholderString = "Editor font"
            size.placeholderString = "Editor size"
            let color = NSColorWell()
            color.color = Self.rgb(style.foreground)
            let custom = NSButton(checkboxWithTitle: "Use custom text color", target: nil, action: nil)
            custom.state = style.useCustomColor == true ? .on : .off
            let bold = NSButton(checkboxWithTitle: "Bold", target: nil, action: nil),
                italic = NSButton(checkboxWithTitle: "Italic", target: nil, action: nil)
            bold.state = style.fontStyle & 1 != 0 ? .on : .off
            italic.state = style.fontStyle & 2 != 0 ? .on : .off
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            for (label, control) in [("Font name", font as NSView), ("Size (6–72 pt)", size), ("Text color", color)] {
                control.setAccessibilityLabel(label)
                let row = NSStackView(views: [NSTextField(labelWithString: label), control])
                control.widthAnchor.constraint(equalToConstant: 300).isActive = true
                stack.addArrangedSubview(row)
            }
            for control in [custom, bold, italic] { stack.addArrangedSubview(control) }
            stack.frame = NSRect(x: 0, y: 0, width: 460, height: 220)
            edit.accessoryView = stack
            while edit.runModal() == .alertFirstButtonReturn {
                do {
                    style = try Self.readStyle(
                        style, font: font, size: size, color: color.color, custom: custom.state == .on,
                        bold: bold.state == .on, italic: italic.state == .on, window: edit.window)
                    proposed.profiles[profileIndex].styles[styleIndex] = style
                    // Keep exported UDL font/color data in step with native style edits.
                    if var udl = proposed.profiles[profileIndex].udl {
                        Self.mirror(style, into: &udl)
                        proposed.profiles[profileIndex].udl = udl
                    }
                    try persist(proposed)
                    reapply([proposed.profiles[profileIndex].id])
                    return
                } catch { TTAlert.present(error) }
            }
        } catch { TTAlert.present(error) }
    }
    @objc private func selectLanguage(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let editor = editorProvider() else { return }
        select(identifier: id, in: editor)
    }
    /// The one route by which a person's choice of language is applied, from the menu or the
    /// chooser. False, with nothing changed and nothing remembered, when the profile is gone or
    /// its lexer is not linked.
    @discardableResult private func select(identifier id: String, in editor: TTEditor) -> Bool {
        guard applyToDocument(identifier: id, through: editor) else { return false }
        setLanguage(id)
        recentsStore.note(id)
        return true
    }

    // MARK: Language chooser

    /// The language the document's name and first line suggest, for the chooser's first row.
    var detectedLanguage: () -> String? = { nil }
    /// The window the chooser is a sheet on: the workspace window.
    var chooserParent: () -> NSWindow? = { nil }
    /// Shows the chooser. Checks replace this so that no sheet is put on the desktop.
    var presentChooser: @MainActor (ChoicePanel, NSWindow?) -> Void = { $0.show(parent: $1) }
    /// Where the recently chosen languages are kept; nil for the private support folder.
    var recentsURL: URL?
    private(set) lazy var recentsStore = LanguageRecentsStore(url: recentsURL)
    private(set) var chooser: ChoicePanel?
    static let chooserIdentifier = "language.chooser"
    static let chooserEmptyMessage = "No matching languages"

    /// The chooser's rows before anything is typed: the detected language, then the languages
    /// chosen most recently, then every other language by name. A language is listed once.
    /// Internal profiles are left out; a recent or detected one that is no longer available is too.
    func chooserRows(current: String?, detected: String?, recent: [String]) -> [ChoicePanel.Row] {
        let internalIDs = LanguageProfile.internalIDs
        let entries = sortedEntries().filter { !internalIDs.contains($0.id) }
        let names = Dictionary(entries.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var listed = Set<String>(), rows: [ChoicePanel.Row] = []
        func add(_ id: String, _ kind: String, _ spoken: String) {
            guard let name = names[id], listed.insert(id).inserted else { return }
            let marks = [kind, id == current ? "Current" : ""].filter { !$0.isEmpty }
            let spokenMarks = [spoken, id == current ? "Current language" : ""].filter { !$0.isEmpty }
            rows.append(
                .init(
                    id: id, title: name, accessory: marks.joined(separator: " · "),
                    accessoryLabel: spokenMarks.joined(separator: ", ")))
        }
        if let detected { add(detected, "Detected", "Detected for this document") }
        for id in recent { add(id, "Recent", "Recently chosen") }
        for entry in entries { add(entry.id, "", "") }
        return rows
    }
    /// Narrows the rows to those whose name contains what was typed, or whose identifier starts
    /// with it ("cpp" finds C++). An exact name comes first, then names that start with the
    /// text; within each, the order above is kept.
    static func filterChooserRows(_ rows: [ChoicePanel.Row], matching text: String) -> [ChoicePanel.Row] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        func rank(_ row: ChoicePanel.Row) -> Int? {
            if row.title.localizedCaseInsensitiveCompare(query) == .orderedSame { return 0 }
            if row.title.range(of: query, options: [.caseInsensitive, .anchored]) != nil { return 1 }
            if row.title.localizedCaseInsensitiveContains(query) { return 2 }
            return row.id.range(of: query, options: [.caseInsensitive, .anchored]) != nil ? 3 : nil
        }
        return rows.enumerated().compactMap { index, row in rank(row).map { ($0, index, row) } }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }
    /// View > Syntax Highlighting > Choose Language… and the language field of the status bar.
    /// Return applies the selected language to the document the chooser was opened for; Escape
    /// or Cancel closes it with nothing changed.
    @objc func chooseLanguage(_ sender: Any?) {
        if let chooser {
            chooser.showAgain()
            return
        }
        guard let editor = editorProvider() else { return }
        let parent = chooserParent()
        guard parent?.attachedSheet == nil else { return }
        let panel = ChoicePanel(
            title: "Choose Language", identifier: Self.chooserIdentifier, action: "Use Language",
            filterLabel: "Search languages")
        chooser = panel
        // The list as it was when the chooser opened: choosing closes it.
        let rows = chooserRows(current: languageProvider(), detected: detectedLanguage(), recent: recentsStore.ids)
        panel.rows = { rows }
        panel.filteredRows = { Self.filterChooserRows(rows, matching: $0) }
        panel.emptyMessage = Self.chooserEmptyMessage
        panel.onClose = { [weak self] in self?.chooser = nil }
        panel.choose = { [weak self, weak editor] id in
            guard let self, let editor, self.editorProvider() === editor else {
                throw FormFailure.documentChanged
            }
            guard self.select(identifier: id, in: editor) else {
                throw LanguageError.invalid("This language is no longer available. Choose another.")
            }
            // DS-72: the only visible result is the status bar's language field.
            Announce.say("Syntax highlighting set to \(self.displayName(identifier: id)).", from: parent)
            return true
        }
        presentChooser(panel, parent)
    }
    @objc func complete() {
        guard let editor = editorProvider(), let profile = profile(identifier: languageProvider()) else { return }
        editor.showCompletions(profile.completions)
    }
    @objc func callTip() {
        guard let editor = editorProvider(), let profile = profile(identifier: languageProvider()) else { return }
        editor.showCallTip("\(profile.displayName): \(profile.completions.prefix(30).joined(separator:", "))")
    }
    @objc func functions() {
        do {
            // Read-only: works on the bundled catalog while a damaged stored file waits to be moved aside.
            guard let editor = editorProvider(), let profile = profile(identifier: languageProvider()) else {
                throw loadError ?? LanguageError.invalid("Choose a language first.")
            }
            guard profile.functionPattern != nil else {
                throw LanguageError.invalid(
                    "This profile has no native function pattern yet. Add a bounded pattern with symbol capture group 1 in Edit Language Profiles. Reference function-list parser parity remains incomplete."
                )
            }
            let text = editor.text, revision = editor.revision
            let symbols = try LanguageFunctions.symbols(text: text, profile: profile)
            navigator = LanguageFunctionController(editor: editor, text: text, revision: revision, symbols: symbols)
            navigator?.onNavigate = { [weak self] in
                self?.onUnrecordableCommand?("Function-list navigation is not recorded in macros yet.")
            }
            navigator?.showWindow(nil)
        } catch { TTAlert.present(error) }
    }
    var jsonFilePanels = JSONLibraryEditor.FilePanels.standard
    @objc func configure() {
        do {
            guard try ensureWritable() else { return }
            guard let catalog else { return }
            try JSONLibraryEditor.edit(
                catalog,
                configuration: .init(
                    title: "Language Profiles",
                    information:
                        "Edit native lexer keywords, properties, style emphasis, extension detection and optional function patterns (capture group 1 is the name). This JSON profile format is not Notepad++ UDL XML. Imported files never execute code. Preserve identifiers to keep session language choices. Only your changes are saved, so built-in languages you leave alone follow later versions of TextTank. Removing a profile's \"comments\" turns comment commands off for it; an empty object does the same.",
                    accessibilityLabel: "Language profiles JSON", exportName: "TextTank-LanguageProfiles.json",
                    identifier: "language.json", size: NSSize(width: 700, height: 420)),
                panels: jsonFilePanels,
                current: {
                    guard let live = self.catalog else { throw FormFailure.changed }
                    return live
                }, read: { try Self.readRegular($0) },
                save: { proposed in
                    try self.persist(proposed)
                    self.reapply(nil)
                })
        } catch { TTAlert.present(error) }
    }
    /// Saves what `proposed` changes in the bundled catalog. Never shows UI and never moves files:
    /// while the stored file is unreadable it throws and leaves that file byte for byte as it is.
    func persist(_ proposed: LanguageCatalog) throws {
        try loadState.requireWritable()
        guard let bundled else { throw LanguageError.invalid("The language catalog is missing from the application.") }
        try proposed.validate()
        let overrides = LanguageOverrides(changing: bundled, to: proposed)
        // What is written must read back as exactly the profiles that were asked for.
        let merged = try overrides.applied(to: bundled)
        guard PersistedValue.equal(merged.profiles, proposed.profiles) else {
            throw LanguageError.invalid("Language profiles could not be stored without loss; nothing was saved.")
        }
        let bytes = try overrides.encoded()
        try PrivateFileStore.prepareDirectory(storage.deletingLastPathComponent())
        // Re-read an existing entry so a late unsafe substitution cannot be overwritten.
        do {
            let existing = try Self.readRegular(storage, parent: .strict)
            _ = try LanguageCatalog.load(stored: existing, over: bundled)
        } catch  where error.isFileNotFound {} catch {
            loadError = error
            storageDamaged = true
            throw error
        }
        try PrivateFileStore.write(
            bytes, to: storage, maximumBytes: LanguageCatalog.maximumBytes,
            temporaryPrefix: ".languages-")
        catalog = merged
    }
    nonisolated private static func readRegular(_ url: URL, parent: PrivateFileStore.ParentPolicy = .selectedInput)
        throws -> Data
    {
        do {
            return try PrivateFileStore.read(url, maximumBytes: LanguageCatalog.maximumBytes, parent: parent)
        } catch PrivateFileError.unsafeLocation {
            throw LanguageError.invalid("Choose a regular local language file up to \(SizePolicy.describe(LanguageCatalog.maximumBytes)).")
        } catch PrivateFileError.tooLarge {
            throw LanguageError.invalid("Language input exceeds \(SizePolicy.describe(LanguageCatalog.maximumBytes)). Split the catalog or choose a smaller file.")
        }
    }
}

final class LanguageFunctionController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) weak var editor: TTEditor?
    private var retirementObserver: NSObjectProtocol?
    private let text: String, revision: UInt, symbols: [LanguageSymbol]
    /// Called after a row moved the caret.
    var onNavigate: (() -> Void)?
    let table = ActivatingTableView(),
        status = NSTextField(
            labelWithString:
                "Double-click a symbol, or select it and press Return, to navigate. Basic pattern-based navigation; not a compiler index."
        )
    init(editor: TTEditor, text: String, revision: UInt, symbols: [LanguageSymbol]) {
        self.editor = editor
        self.text = text
        self.revision = revision
        self.symbols = symbols
        // A panel, so the document window stays main while the list is key. Escape closes it.
        let window = ToolPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled, .closable, .resizable])
        super.init(window: window)
        // The list is about the document; when its split pane closes it follows the remaining view.
        retirementObserver = NotificationCenter.default.addObserver(
            forName: .TTEditorWillRetire, object: nil, queue: nil
        ) { [weak self] note in
            precondition(Thread.isMainThread)
            let successor = note.userInfo?[TTEditorSuccessorKey] as? TTEditor
            let retiring = note.object as? TTEditor
            MainActor.assumeIsolated {
                guard let self, self.editor === retiring else { return }
                self.editor = successor
            }
        }
        window.title = "Function List"
        window.listedInWindowMenu = true
        window.isReleasedWhenClosed = false
        let col = NSTableColumn(identifier: .init("symbol"))
        col.title = "Line · Symbol"
        col.width = 550
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        // Return on the selected row does what a double-click on it does.
        table.onActivate = { [weak self] row in self?.open(row: row) }
        table.setAccessibilityLabel("Functions and symbols")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [status, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        window.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        window.initialFirstResponder = table
        WindowFrames.track(window, as: "TextTank.FunctionList")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    deinit {
        precondition(Thread.isMainThread)
        MainActor.assumeIsolated {
            if let retirementObserver { NotificationCenter.default.removeObserver(retirementObserver) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { symbols.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        symbols.indices.contains(row) ? "\(symbols[row].line) · \(symbols[row].name)" : nil
    }
    /// A double-click. `clickedRow` is -1 for the header and the empty area below the rows.
    @objc func openSelected() { open(row: table.clickedRow) }
    /// What a double-click or Return on a listed symbol does.
    func open(row: Int) {
        guard symbols.indices.contains(row), let editor else { return }
        if Self.navigate(symbols[row], text: text, revision: revision, editor: editor) {
            onNavigate?()
        } else {
            status.stringValue = "The document changed or closed. Refresh the function list."
        }
    }
    static func navigate(_ symbol: LanguageSymbol, text: String, revision: UInt, editor: TTEditor) -> Bool {
        guard EditorLifetime.isOpen(editor), editor.revision == revision, editor.text == text,
            let range = Range(symbol.range, in: text)
        else { return false }
        let start = text[..<range.lowerBound].utf8.count, end = text[..<range.upperBound].utf8.count
        guard editor.setSelectionAnchor(start, caret: end) else { return false }
        EditorLifetime.activate(editor)
        return true
    }
}
