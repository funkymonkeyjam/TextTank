// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin

final class LanguageController: NSObject, NSMenuDelegate {
    private let editorProvider: () -> TTEditor?
    private let languageProvider: () -> String
    private let setLanguage: (String) -> Void
    /// The other views of the document `editor` shows: the other pane of a split view. Injected,
    /// like `openDocuments`, so this file needs no application types.
    var siblingViews: (TTEditor) -> [TTEditor] = { _ in [] }
    /// One view of every open document, with that document's language identifier.
    var openDocuments: () -> [(language: String, editor: TTEditor)] = { [] }
    private(set) var catalog: LanguageCatalog?
    private var loadError: Error?
    private let storage: URL
    private var navigator: LanguageFunctionController?
    init(
        editorProvider: @escaping () -> TTEditor?, languageProvider: @escaping () -> String,
        setLanguage: @escaping (String) -> Void
    ) {
        self.editorProvider = editorProvider
        self.languageProvider = languageProvider
        self.setLanguage = setLanguage
        let base =
            ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TextTank", isDirectory: true)
        storage = base.appendingPathComponent("LanguageProfiles.json")
        super.init()
        do {
            let bundled =
                Bundle.main.url(forResource: "LanguageProfiles", withExtension: "json")
                ?? URL(fileURLWithPath: "Resources/LanguageProfiles.json")
            catalog = try LanguageCatalog.decode(
                Self.readRegular(FileManager.default.fileExists(atPath: storage.path) ? storage : bundled))
            if let defaults = try? LanguageCatalog.decode(Self.readRegular(bundled)) {
                for index in catalog!.profiles.indices where catalog!.profiles[index].comments == nil {
                    catalog!.profiles[index].comments =
                        defaults.profiles.first { $0.id == catalog!.profiles[index].id }?.comments
                }
            }
        } catch { loadError = error }
    }
    func menu() -> NSMenu {
        let menu = NSMenu(title: "Language")
        menu.delegate = self
        func add(_ name: String, _ action: Selector) {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Complete Word", #selector(complete))
        add("Function List…", #selector(functions))
        add("Show Keyword Help", #selector(callTip))
        add("Syntax Style Settings…", #selector(styleSettings))
        add("Edit Language Profiles…", #selector(configure))
        add("Import Notepad++ UDL…", #selector(importUDL))
        add("Edit Current UDL…", #selector(editUDL))
        add("Export Current UDL…", #selector(exportUDL))
        menu.addItem(.separator())
        let available = Set(TTEditor.availableLanguages())
        for profile in (catalog?.profiles ?? []).sorted(by: {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }) where available.contains(profile.lexer) {
            let item = NSMenuItem(title: profile.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            menu.addItem(item)
        }
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = self.menu()
        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }
    @objc private func importUDL() {
        do {
            if let loadError { throw loadError }
            guard var proposed = catalog else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let imported = try UserDefinedLanguage.decode(Self.readRegular(url))
            for definition in imported {
                let profile = try definition.profile()
                if let index = proposed.profiles.firstIndex(where: { $0.id == profile.id }) {
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
        } catch { NSAlert(error: error).runModal() }
    }
    @objc private func editUDL() {
        do {
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
            alert.addButton(withTitle: "Cancel")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 420))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isRichText = false
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.autoresizingMask = [.width]
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            scroll.documentView = text
            text.string = String(data: try definition.encodedXML(), encoding: .utf8)!
            alert.accessoryView = scroll
            while alert.runModal() == .alertFirstButtonReturn {
                do {
                    let definitions = try UserDefinedLanguage.decode(Data(text.string.utf8))
                    guard definitions.count == 1 else {
                        throw LanguageError.invalid("Edit exactly one UDL in this window.")
                    }
                    var profile = try definitions[0].profile()
                    profile.id = id
                    proposed.profiles[index] = profile
                    try persist(proposed)
                    reapply([id])
                    return
                } catch { NSAlert(error: error).runModal() }
            }
        } catch { NSAlert(error: error).runModal() }
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
        } catch { NSAlert(error: error).runModal() }
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
        guard let profile = catalog?.profiles.first(where: { $0.id == identifier }),
            TTEditor.availableLanguages().contains(profile.lexer)
        else { return false }
        // One bridge call, one lexing pass: lists from the previous profile are cleared inside it.
        var lists: [NSNumber: String] = [:]
        for (index, words) in profile.keywordLists {
            if let index = Int(index) { lists[NSNumber(value: index)] = words }
        }
        editor.setLanguage(profile.lexer, keywordLists: lists, properties: profile.properties)
        for style in profile.styles {
            editor.setSyntaxStyle(
                style.id, foreground: Self.color(style), background: nil, bold: style.fontStyle & 1 != 0,
                italic: style.fontStyle & 2 != 0)
            if style.fontName != nil || style.fontSize != nil {
                editor.setSyntaxFont(
                    style.id,
                    name: style.fontName ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName,
                    size: style.fontSize ?? 12)
            }
        }
        return true
    }
    private static func color(_ style: LanguageProfile.Style) -> NSColor {
        if style.useCustomColor == true { return rgb(style.foreground) }
        // Keep native dynamic contrast unless the user selected a fixed RGB color.
        return NSColor(
            name: nil,
            dynamicProvider: { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let name = style.name.uppercased()
                if name.contains("COMMENT") {
                    return dark
                        ? NSColor(calibratedRed: 0.62, green: 0.72, blue: 0.64, alpha: 1)
                        : NSColor(calibratedRed: 0.25, green: 0.39, blue: 0.28, alpha: 1)
                }
                if name.contains("STRING") || name.contains("CHARACTER") {
                    return dark
                        ? NSColor(calibratedRed: 0.88, green: 0.75, blue: 0.52, alpha: 1)
                        : NSColor(calibratedRed: 0.48, green: 0.28, blue: 0.08, alpha: 1)
                }
                if name.contains("WORD") || name.contains("KEYWORD") || name.contains("INSTRUCTION")
                    || name.contains("TYPE")
                {
                    return dark
                        ? NSColor(calibratedRed: 0.65, green: 0.82, blue: 1, alpha: 1)
                        : NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.55, alpha: 1)
                }
                if name.contains("NUMBER") {
                    return dark
                        ? NSColor(calibratedRed: 0.86, green: 0.69, blue: 0.96, alpha: 1)
                        : NSColor(calibratedRed: 0.44, green: 0.19, blue: 0.55, alpha: 1)
                }
                return .textColor
            })
    }
    func profile(identifier: String) -> LanguageProfile? { catalog?.profiles.first { $0.id == identifier } }
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
        let name = font.stringValue
        guard let points = Double(size.stringValue), (6...72).contains(points), NSFont(name: name, size: points) != nil,
            let chosen = color.usingColorSpace(.sRGB)
        else { throw LanguageError.invalid("Enter an installed font name and a size between 6 and 72 points.") }
        var style = original
        style.fontName = name
        style.fontSize = points
        style.useCustomColor = custom
        style.fontStyle = (bold ? 1 : 0) + (italic ? 2 : 0)
        style.foreground = String(
            format: "%02X%02X%02X", Int((chosen.redComponent * 255).rounded()),
            Int((chosen.greenComponent * 255).rounded()), Int((chosen.blueComponent * 255).rounded()))
        return style
    }
    @objc func styleSettings() {
        do {
            if let loadError { throw loadError }
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
            choose.addButton(withTitle: "Cancel")
            let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28), pullsDown: false)
            for style in proposed.profiles[profileIndex].styles { selector.addItem(withTitle: style.name) }
            choose.accessoryView = selector
            guard choose.runModal() == .alertFirstButtonReturn, selector.indexOfSelectedItem >= 0 else { return }
            let styleIndex = selector.indexOfSelectedItem
            var style = proposed.profiles[profileIndex].styles[styleIndex]
            let edit = TTAlert()
            edit.messageText = "\(proposed.profiles[profileIndex].title) — \(style.name)"
            edit.informativeText =
                "Choose a font and size. Custom RGB stays fixed in light/dark appearances; turn it off to use the adaptive native syntax palette. Changes affect this language only."
            edit.addButton(withTitle: "Save")
            edit.addButton(withTitle: "Cancel")
            let
                font = NSTextField(
                    string: style.fontName ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName),
                size = NSTextField(string: String(style.fontSize ?? 12))
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
                    let name = style.fontName!, points = style.fontSize!
                    proposed.profiles[profileIndex].styles[styleIndex] = style
                    // Keep exported UDL font/color data in step with native style edits.
                    if var udl = proposed.profiles[profileIndex].udl,
                        let index = udl.styles.firstIndex(where: { $0.name == style.name })
                    {
                        udl.styles[index].attributes["fontName"] = name
                        udl.styles[index].attributes["fontSize"] = String(points)
                        udl.styles[index].attributes["fontStyle"] = String(style.fontStyle)
                        udl.styles[index].attributes["fgColor"] = style.foreground
                        proposed.profiles[profileIndex].udl = udl
                    }
                    try persist(proposed)
                    reapply([proposed.profiles[profileIndex].id])
                    return
                } catch { NSAlert(error: error).runModal() }
            }
        } catch { NSAlert(error: error).runModal() }
    }
    @objc private func selectLanguage(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let editor = editorProvider(),
            applyToDocument(identifier: id, through: editor)
        else { return }
        setLanguage(id)
    }
    @objc func complete() {
        guard let editor = editorProvider(),
            let profile = catalog?.profiles.first(where: { $0.id == languageProvider() })
        else { return }
        editor.showCompletions(profile.completions)
    }
    @objc func callTip() {
        guard let editor = editorProvider(),
            let profile = catalog?.profiles.first(where: { $0.id == languageProvider() })
        else { return }
        editor.showCallTip("\(profile.title): \(profile.completions.prefix(30).joined(separator:", "))")
    }
    @objc func functions() {
        do {
            if let loadError { throw loadError }
            guard let editor = editorProvider(),
                let profile = catalog?.profiles.first(where: { $0.id == languageProvider() })
            else { throw LanguageError.invalid("Choose a language first.") }
            guard profile.functionPattern != nil else {
                throw LanguageError.invalid(
                    "This profile has no native function pattern yet. Add a bounded pattern with symbol capture group 1 in Edit Language Profiles. Reference function-list parser parity remains incomplete."
                )
            }
            let text = editor.text, revision = editor.revision
            let symbols = try LanguageFunctions.symbols(text: text, profile: profile)
            navigator = LanguageFunctionController(editor: editor, text: text, revision: revision, symbols: symbols)
            navigator?.showWindow(nil)
        } catch { NSAlert(error: error).runModal() }
    }
    @objc func configure() {
        do {
            if let loadError { throw loadError }
            guard let catalog else { return }
            let alert = TTAlert()
            alert.messageText = "Language Profiles"
            alert.informativeText =
                "Edit native lexer keywords, properties, style emphasis, extension detection and optional function patterns (capture group 1 is the name). This JSON profile format is not Notepad++ UDL XML. Imported files never execute code. Preserve identifiers to keep session language choices."
            for title in ["Save", "Cancel", "Import…", "Export…"] { alert.addButton(withTitle: title) }
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 420))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isRichText = false
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.autoresizingMask = [.width]
            scroll.documentView = text
            text.string = String(data: try catalog.encoded(), encoding: .utf8)!
            alert.accessoryView = scroll
            while true {
                let choice = alert.runModal()
                if choice == .alertSecondButtonReturn { return }
                do {
                    if choice.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 2 {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            text.string = String(
                                data: try LanguageCatalog.decode(Self.readRegular(url)).encoded(), encoding: .utf8)!
                        }
                        continue
                    }
                    let proposed = try LanguageCatalog.decode(Data(text.string.utf8))
                    if choice.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "TextTank-LanguageProfiles.json"
                        if panel.runModal() == .OK, let url = panel.url {
                            try proposed.encoded().write(to: url, options: .atomic)
                        }
                        continue
                    }
                    try persist(proposed)
                    // The whole catalog may have changed.
                    reapply(nil)
                    return
                } catch { NSAlert(error: error).runModal() }
            }
        } catch { NSAlert(error: error).runModal() }
    }
    func persist(_ proposed: LanguageCatalog) throws {
        if let loadError { throw loadError }
        let bytes = try proposed.encoded(), directory = storage.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard
            try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType
                == .typeDirectory
        else { throw LanguageError.invalid("Language storage must be a regular directory.") }
        if FileManager.default.fileExists(atPath: storage.path) { _ = try Self.readRegular(storage) }
        let temp = directory.appendingPathComponent(".languages-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
        }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        try handle.close()
        guard rename(temp.path, storage.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        catalog = proposed
    }
    private static func readRegular(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16 * 1024 * 1024 else {
            throw LanguageError.invalid("Language input must be a regular file up to 16 MiB.")
        }
        let bytes = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 16 * 1024 * 1024 else { throw LanguageError.invalid("Language input exceeds 16 MiB.") }
        return bytes
    }
}

final class LanguageFunctionController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) weak var editor: TTEditor?
    private var retirementObserver: NSObjectProtocol?
    private let text: String, revision: UInt, symbols: [LanguageSymbol]
    private let table = NSTableView(),
        status = NSTextField(
            labelWithString: "Double-click a symbol to navigate. Basic pattern-based navigation; not a compiler index.")
    init(editor: TTEditor, text: String, revision: UInt, symbols: [LanguageSymbol]) {
        self.editor = editor
        self.text = text
        self.revision = revision
        self.symbols = symbols
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        // The list is about the document; when its split pane closes it follows the remaining view.
        retirementObserver = NotificationCenter.default.addObserver(
            forName: .TTEditorWillRetire, object: editor, queue: nil
        ) { [weak self] note in self?.editor = note.userInfo?[TTEditorSuccessorKey] as? TTEditor }
        window.title = "Function List"
        window.isReleasedWhenClosed = false
        let col = NSTableColumn(identifier: .init("symbol"))
        col.title = "Line · Symbol"
        col.width = 550
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    deinit { if let retirementObserver { NotificationCenter.default.removeObserver(retirementObserver) } }
    func numberOfRows(in tableView: NSTableView) -> Int { symbols.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        symbols.indices.contains(row) ? "\(symbols[row].line) · \(symbols[row].name)" : nil
    }
    @objc private func openSelected() {
        guard symbols.indices.contains(table.clickedRow), let editor else { return }
        if !Self.navigate(symbols[table.clickedRow], text: text, revision: revision, editor: editor) {
            status.stringValue = "The document changed or closed. Refresh the function list."
        }
    }
    static func navigate(_ symbol: LanguageSymbol, text: String, revision: UInt, editor: TTEditor) -> Bool {
        guard editor.window != nil, editor.revision == revision, editor.text == text,
            let range = Range(symbol.range, in: text)
        else { return false }
        let start = text[..<range.lowerBound].utf8.count, end = text[..<range.upperBound].utf8.count
        guard editor.setSelectionAnchor(start, caret: end) else { return false }
        editor.window?.makeKeyAndOrderFront(nil)
        editor.window?.makeFirstResponder(editor)
        return true
    }
}
