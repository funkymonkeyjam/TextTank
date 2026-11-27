// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

package enum ExternalChangePolicy: String, Codable, Sendable, CaseIterable {
    case ask, reloadIfUnmodified, ignore
}

/// Persisted format, version 1 or 2; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
/// Version 2 differs only in what `shortcuts` may hold (`ShortcutCore.swift`), and a file is
/// written as version 2 only while it holds such an entry.
package struct EditorSettings: Codable, Equatable {
    package init(
        version: Int = 1, tabWidth: Int = 4, useTabs: Bool = true, wrap: Bool = false, appearance: String = "system",
        shortcuts: [String: String] = [:]
    ) {
        self.version = version
        self.tabWidth = tabWidth
        self.useTabs = useTabs
        self.wrap = wrap
        self.appearance = appearance
        self.shortcuts = shortcuts
    }

    package var version: Int
    package var tabWidth: Int
    package var useTabs: Bool
    package var fontName: String?
    package var fontSize: Double?
    package var defaultZoom: Int?
    package var basePointSize: Double { fontSize ?? 14 }
    package var initialZoom: Int { defaultZoom ?? 0 }
    package var currentLineHighlight: Bool?
    package var currentLineHighlightEnabled: Bool { currentLineHighlight ?? true }
    package var indentGuides: Bool?
    package var indentGuidesEnabled: Bool { indentGuides ?? true }
    package var braceHighlight: Bool?
    package var braceHighlightEnabled: Bool { braceHighlight ?? true }
    package var autoPair: Bool?
    package var autoPairEnabled: Bool { autoPair ?? false }
    package var autoIndent: Bool?
    package var autoIndentEnabled: Bool { autoIndent ?? true }
    /// View > Show Line Numbers, Show Whitespace and Show Line Endings, for every editor view.
    /// A file without these members shows line numbers and hides both kinds of mark.
    package var lineNumbers: Bool?
    package var lineNumbersEnabled: Bool { lineNumbers ?? true }
    package var showWhitespace: Bool?
    package var showWhitespaceEnabled: Bool { showWhitespace ?? false }
    package var showLineEndings: Bool?
    package var showLineEndingsEnabled: Bool { showLineEndings ?? false }
    /// View > Show > Change Bars (DS-D13), for every editor view: a narrow margin marks the
    /// lines changed since the document was opened. Off unless the member is `true`.
    package var changeBars: Bool?
    package var changeBarsEnabled: Bool { changeBars ?? false }
    /// View > Centered Text Column (DS-D13), for every editor view, and the column's width in
    /// characters of the editor font. Off unless `centeredColumn` is `true`; a missing width is
    /// 90. A stored width outside 40...240 is read as the nearest bound and is not rewritten.
    package var centeredColumn: Bool?
    package var centeredColumnEnabled: Bool { centeredColumn ?? false }
    package var centeredColumnWidth: Int?
    static package let centeredColumnWidths = 40...240
    static package let standardCenteredColumnWidth = 90
    package var centeredColumnCharacters: Int {
        min(
            max(centeredColumnWidth ?? Self.standardCenteredColumnWidth, Self.centeredColumnWidths.lowerBound),
            Self.centeredColumnWidths.upperBound)
    }
    package var reopenLastSession: Bool?
    package var reopensLastSession: Bool { reopenLastSession ?? true }
    /// DS-D9. Quitting keeps each edited untitled document as a verified recovery copy and
    /// reopens it at the next launch, without asking. Off gives the earlier Save / Delete /
    /// Cancel review at quit. A missing member reads as on.
    package var keepUntitledOnQuit: Bool?
    package var keepsUntitledOnQuit: Bool { keepUntitledOnQuit ?? true }
    /// DS-D10. Each save of a file keeps a private earlier version (twenty a file, thirty days,
    /// 200 MB in all). Off keeps nothing new; versions already kept stay until they are cleared
    /// or expire. A missing member reads as on.
    package var keepLocalHistory: Bool?
    package var keepsLocalHistory: Bool { keepLocalHistory ?? true }
    package var wrap: Bool
    package var appearance: String
    package var externalChangePolicy: ExternalChangePolicy?
    package var diskChangeBehavior: ExternalChangePolicy { externalChangePolicy ?? .ask }
    /// What a document of each preview format shows when it is opened into a new tab: a
    /// `PreviewFormat` raw value to a `DocumentViewMode` raw value, both as text.
    ///
    /// Tolerated, and read as Source: the member missing or null; a format with no entry; an
    /// entry whose text is not `source`, `preview` or `both` (the match is exact, so `Preview`
    /// is not known either); an entry for a format this build does not list, which is kept.
    /// Not tolerated: a member that is not an object, or an entry that is not text. Like any
    /// other member of the wrong JSON type it fails the whole file, which is then left unchanged
    /// behind the usual "could not be read" notice. The same holds for `lastRenderedPreviewMode`:
    /// any text other than `preview` reads as Both, and a value that is not text fails the file.
    package var previewOpenModes: [String: String]?
    package func previewOpenMode(for format: PreviewFormat) -> DocumentViewMode {
        (previewOpenModes?[format.rawValue]).flatMap(DocumentViewMode.init(rawValue:)) ?? .source
    }
    /// Source is recorded by leaving the format out, as a tab's session record does.
    mutating package func setPreviewOpenMode(_ mode: DocumentViewMode, for format: PreviewFormat) {
        var modes = previewOpenModes ?? [:]
        modes[format.rawValue] = mode == .source ? nil : mode.rawValue
        previewOpenModes = modes.isEmpty ? nil : modes
    }
    /// Preview or Both, whichever the person chose last; Toggle Preview returns to it. Anything
    /// else, including a missing member, reads as Both.
    package var lastRenderedPreviewMode: String?
    package var toggledPreviewMode: DocumentViewMode {
        lastRenderedPreviewMode == DocumentViewMode.preview.rawValue ? .preview : .both
    }
    /// "Sync scrolling in Both": while a tab shows Both, scrolling the source scrolls its
    /// preview to the matching place and the reverse. On unless the member is `false`; a
    /// missing or null member reads as on. A value that is not a Boolean fails the file.
    package var syncPreviewScrolling: Bool?
    package var syncsPreviewScrolling: Bool { syncPreviewScrolling ?? true }
    /// A command identifier to its shortcut. Version 1: one of the twelve editor commands to one
    /// printable character, meaning Command, with AppKit's uppercase convention for Shift.
    /// Version 2 also allows any command of the menu bar, text such as `ctrl+opt+k` (see
    /// `MenuShortcut.init(storedText:)`), and an empty value for a default that was taken away.
    package var shortcuts: [String: String]
    static package let commands = EditorCommand.shortcutIdentifiers
    static package let reserved: Set<String> = [
        "a", "c", "v", "x", "z", "Z", "s", "S", "n", "o", "w", "q", "p", "f", "F", "g", "G", "P", "m", "[", "]", "+",
        "-", ",", "h", "l"
    ]
    /// Empty/default removes an override; the version-1 wire vocabulary never stores an empty key.
    /// `assignShortcut` is the route for the commands and keys version 1 cannot hold.
    mutating package func setShortcut(_ key: String, for id: String) {
        if key.isEmpty || key == EditorCommand.defaultShortcuts[id] {
            shortcuts.removeValue(forKey: id)
        } else {
            shortcuts[id] = key
        }
        if (1...2).contains(version) { version = requiredVersion }
    }
    package func shortcut(for id: String) -> String { shortcuts[id] ?? EditorCommand.defaultShortcuts[id] ?? "" }
    static package func validShortcutKey(_ key: String) -> Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 }
    }
    // System Find selection and window cycling are protected even before a main menu exists.
    static package let protectedShortcuts = reserved.union(["e", "`"])
    package func validate(reservedKeys: Set<String> = Self.protectedShortcuts) throws {
        try validate(context: ShortcutContext(reservedKeys: reservedKeys))
    }
    /// The same deterministic validation supplies identity to editors and errors to strict saves.
    /// An implicit default cannot be edited in isolation; identify its conflicting explicit override.
    package func shortcutValidationFailure(reservedKeys: Set<String>) -> ShortcutValidationFailure? {
        shortcutValidationFailure(context: ShortcutContext(reservedKeys: reservedKeys))
    }
    /// Strict decode remains available to validation/import callers; tolerant startup is explicit.
    static package func decode(_ data: Data) throws -> Self {
        try PersistedFormat.check(data, context: "Editor settings")
        let settings = try JSONDecoder().decode(Self.self, from: data)
        try settings.validate()
        return settings
    }
    static package func load(_ data: Data, reservedKeys: Set<String>) throws -> (
        settings: Self, issues: [ShortcutLoadIssue]
    ) {
        try load(data, context: ShortcutContext(reservedKeys: reservedKeys))
    }
    package func toleratingShortcuts(reservedKeys: Set<String>) throws -> (settings: Self, issues: [ShortcutLoadIssue])
    {
        try toleratingShortcuts(context: ShortcutContext(reservedKeys: reservedKeys))
    }
}
package struct ShortcutLoadIssue: Equatable {
    package init(
        command: String, key: String, reason: Reason, title: String? = nil, ownerTitle: String? = nil,
        detail: String? = nil
    ) {
        self.command = command
        self.key = key
        self.reason = reason
        self.title = title
        self.ownerTitle = ownerTitle
        self.detail = detail
    }

    package enum Reason: Equatable { case unavailable, invalid, reserved, duplicate(String) }
    package let command: String, key: String, reason: Reason
    /// Where the menu bar lists the command and the one it conflicts with, when that is known.
    package let title: String?, ownerTitle: String?
    /// Why the key cannot be used, in whole sentences, when the reason is the key itself.
    package let detail: String?
    package var message: String {
        let title = title ?? EditorCommand(rawValue: command)?.title ?? "Unavailable command"
        let kept = "Other settings remain in use. The settings file has not been changed."
        switch reason {
        case .unavailable:
            return "A saved shortcut for a command that is no longer available was ignored. " + kept
        case .invalid:
            if let detail { return "The saved shortcut for “\(title)” was ignored. \(detail) " + kept }
            return "The saved shortcut for “\(title)” is not a shortcut TextTank can use and was ignored. " + kept
        case .reserved:
            if let detail { return "The saved shortcut for “\(title)” was ignored. \(detail) " + kept }
            return "The saved shortcut for “\(title)” is reserved for another action and was ignored. " + kept
        case .duplicate(let owner):
            let ownerTitle = ownerTitle ?? EditorCommand(rawValue: owner)?.title ?? "another command"
            return "The saved shortcut for “\(title)” conflicts with “\(ownerTitle)” and was ignored. " + kept
        }
    }
}
package enum SettingsError: Error, LocalizedError, Equatable {
    case invalid, invalidFont, conflict, unreadable, tabWidth, unknownShortcut, invalidShortcut, changedOnDisk,
        ambiguousViewPreference, centeredColumnWidth
    case duplicateShortcut(first: String, second: String, key: String)
    /// Two commands on one key. `first` and `second` are the commands as the menu bar lists
    /// them and `shortcut` is the key in words.
    case shortcutClash(first: String, second: String, shortcut: String)
    package var errorDescription: String? {
        switch self {
        case .shortcutClash(let first, let second, let shortcut):
            return
                "\(shortcut) is assigned to both “\(first)” and “\(second)”. Choose a different shortcut. The settings were not changed."
        case .ambiguousViewPreference:
            return
                "The saved preference is ambiguous. Check Settings.json for duplicate preference keys, then try again."
        case .changedOnDisk: return "The settings file changed before this edit finished. Try the command again."
        case .tabWidth: return "Tab width must be a whole number from 1 to 32. The settings were not changed."
        case .centeredColumnWidth:
            return
                "Column width must be a whole number of characters from \(EditorSettings.centeredColumnWidths.lowerBound) to \(EditorSettings.centeredColumnWidths.upperBound). The settings were not changed."
        case .invalidFont: return "Choose a font name, a size from 6 to 72 points and a default zoom from −10 to 60."
        case .invalid: return "Unsupported settings version or value. Existing settings have not been replaced."
        case .conflict:
            return
                "That shortcut is reserved for another action. Choose a different key. The settings were not changed."
        case .unknownShortcut: return "This command cannot be assigned a shortcut. The settings were not changed."
        case .invalidShortcut:
            return
                "That is not a shortcut TextTank can use. Record it again with Command or Control and a key. The settings were not changed."
        case .duplicateShortcut(let first, let second, let key):
            let firstTitle = EditorCommand(rawValue: first)?.title ?? "another command"
            let secondTitle = EditorCommand(rawValue: second)?.title ?? "another command"
            return
                "Command-\(key) is assigned to both “\(firstTitle)” and “\(secondTitle)”. Choose a different shortcut. The settings were not changed."
        case .unreadable: return "The saved settings could not be read. The original file is preserved."
        }
    }
}

package struct ShortcutValidationFailure: LocalizedError {
    package init(command: String, error: SettingsError, title: String? = nil, detail: String? = nil) {
        self.command = command
        self.error = error
        self.title = title
        self.detail = detail
    }

    package let command: String
    package let error: SettingsError
    /// The command as the menu bar lists it, and why its key was refused, when known.
    package let title: String?, detail: String?
    package var errorDescription: String? {
        let title = title ?? EditorCommand(rawValue: command)?.title ?? "Unavailable command"
        switch error {
        case .invalidShortcut:
            return "The shortcut for “\(title)” cannot be used. "
                + (detail ?? "Record it again with Command or Control and a key.") + " The settings were not changed."
        case .conflict:
            return "The shortcut for “\(title)” is reserved for another action. "
                + (detail ?? "Choose a different key.") + " The settings were not changed."
        default: return error.localizedDescription
        }
    }
}

package enum EditorViewPreference: String {
    case autoIndent, autoPair, braceHighlight, currentLineHighlight, indentGuides
    /// View > Preview > Sync Scrolling in Both, and the Settings row of the same name
    /// (docs/preview-model.md).
    case syncPreviewScrolling
    case lineNumbers, showWhitespace, showLineEndings
    /// View > Show > Change Bars and View > Centered Text Column (DS-D13).
    case changeBars, centeredColumn
    package func enabled(in settings: EditorSettings) -> Bool {
        switch self {
        case .autoIndent: return settings.autoIndentEnabled
        case .autoPair: return settings.autoPairEnabled
        case .braceHighlight: return settings.braceHighlightEnabled
        case .currentLineHighlight: return settings.currentLineHighlightEnabled
        case .indentGuides: return settings.indentGuidesEnabled
        case .syncPreviewScrolling: return settings.syncsPreviewScrolling
        case .lineNumbers: return settings.lineNumbersEnabled
        case .showWhitespace: return settings.showWhitespaceEnabled
        case .showLineEndings: return settings.showLineEndingsEnabled
        case .changeBars: return settings.changeBarsEnabled
        case .centeredColumn: return settings.centeredColumnEnabled
        }
    }
}
extension EditorCommand {
    /// The stored choice behind a View command that applies to every editor view, not just the
    /// focused one. Nil for every other command, zoom and folding included.
    package var viewPreference: EditorViewPreference? {
        switch self {
        case .toggleLineNumbers: return .lineNumbers
        case .showWhitespace: return .showWhitespace
        case .toggleEOL: return .showLineEndings
        default: return nil
        }
    }
}
/// Only recognized values being edited pass through the encoder. Preserve every other
/// member's original bytes, including unknown numbers and the source's Unicode encoding.
private enum SettingsJSON {
    static func updating(_ old: EditorSettings, to new: EditorSettings, in data: Data) throws -> Data {
        let encoder = JSONEncoder()
        func fields(_ value: EditorSettings) throws -> [String: String] {
            let bytes = try encoder.encode(value)
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw SettingsError.invalid
            }
            return try object.mapValues {
                let bytes = try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys])
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        let before = try fields(old), after = try fields(new)
        var edits: [String: String] = [:]
        for key in Set(before.keys).union(after.keys) where before[key] != after[key] {
            edits[key] = after[key] ?? "null"
        }
        return try replacing(edits, in: data)
    }

    static func replacing(_ edits: [String: String], in data: Data) throws -> Data {
        guard !edits.isEmpty else { return data }
        let bytes = Array(data)
        guard bytes.count >= 4 else { throw SettingsError.ambiguousViewPreference }
        // Project structural ASCII from the original JSON code units, including BOM-bearing
        // and BOM-less UTF-16/32. Splice original byte offsets to retain exact Unicode and numbers.
        let width: Int, lane: Int
        if bytes.starts(with: [0xff, 0xfe, 0, 0]) || bytes[1...3].allSatisfy({ $0 == 0 }) {
            (width, lane) = (4, 0)
        } else if bytes.starts(with: [0, 0, 0xfe, 0xff]) || bytes[0...2].allSatisfy({ $0 == 0 }) {
            (width, lane) = (4, 3)
        } else if bytes.starts(with: [0xff, 0xfe]) || bytes[1] == 0 {
            (width, lane) = (2, 0)
        } else if bytes.starts(with: [0xfe, 0xff]) || bytes[0] == 0 {
            (width, lane) = (2, 1)
        } else {
            (width, lane) = (1, 0)
        }
        guard bytes.count.isMultiple(of: width) else { throw SettingsError.ambiguousViewPreference }
        let ascii =
            width == 1
            ? bytes
            : stride(from: 0, to: bytes.count, by: width).map { start -> UInt8 in
                for digit in 0..<width where digit != lane && bytes[start + digit] != 0 { return 0xff }
                return bytes[start + lane]
            }
        func whitespace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        func nextToken(_ start: Int) -> Int {
            var i = start
            while i < ascii.count && whitespace(ascii[i]) { i += 1 }
            return i
        }
        func endOfString(_ start: Int) throws -> Int {
            var i = start + 1
            while i < ascii.count, ascii[i] != 34 { i += ascii[i] == 92 ? 2 : 1 }
            guard i < ascii.count else { throw SettingsError.invalid }
            return i + 1
        }
        // The canonical decoder has already validated this source. Only locate value boundaries.
        func endOfValue(_ start: Int) throws -> Int {
            var depth = 0, i = start
            while i < ascii.count {
                switch ascii[i] {
                case 34: i = try endOfString(i)
                case 91, 123:
                    depth += 1
                    i += 1
                case 44 where depth == 0: return i
                case 93, 125:
                    if depth == 0 { return i }
                    depth -= 1
                    i += 1
                default:
                    if depth == 0 && whitespace(ascii[i]) { return i }
                    i += 1
                }
                if depth == 0 && (ascii[start] == 34 || ascii[start] == 91 || ascii[start] == 123) { return i }
            }
            throw SettingsError.invalid
        }
        let encoding: String.Encoding
        switch (width, lane) {
        case (2, 0): encoding = .utf16LittleEndian
        case (2, _): encoding = .utf16BigEndian
        case (4, 0): encoding = .utf32LittleEndian
        case (4, _): encoding = .utf32BigEndian
        default: encoding = .utf8
        }
        var seen: Set<String> = [], changes: [(Range<Int>, String)] = []
        guard let open = ascii.firstIndex(of: 123) else { throw SettingsError.invalid }
        var i = nextToken(open + 1)
        let longestKey = edits.keys.map { $0.utf8.count }.max() ?? 0
        while i < ascii.count, ascii[i] == 34 {
            let end = try endOfString(i), colon = nextToken(end)
            guard colon < ascii.count && ascii[colon] == 58 else { throw SettingsError.invalid }
            let begin = nextToken(colon + 1)
            guard begin < ascii.count else { throw SettingsError.invalid }
            let next = try endOfValue(begin)
            if end - i <= longestKey * 6 + 2,
                let key = try? JSONDecoder().decode(String.self, from: Data(ascii[i..<end])),
                let replacement = edits[key]
            {
                guard seen.insert(key).inserted else { throw SettingsError.ambiguousViewPreference }
                changes.append((begin..<next, replacement))
            }
            i = nextToken(next)
            if i < ascii.count && ascii[i] == 44 { i = nextToken(i + 1) }
        }
        guard i < ascii.count && ascii[i] == 125 else { throw SettingsError.invalid }
        let additions = edits.keys.filter { !seen.contains($0) }.sorted().map { "\"\($0)\":\(edits[$0]!)" }
        if !additions.isEmpty {
            var last = i - 1
            while last > open && whitespace(ascii[last]) { last -= 1 }
            let comma = ascii[last] == 44 || ascii[last] == 123 ? "" : ","
            changes.append((i..<i, comma + additions.joined(separator: ",")))
        }
        var output = Data(), cursor = 0
        for (range, newValue) in changes {
            guard let value = newValue.data(using: encoding) else { throw SettingsError.invalid }
            output.append(data[cursor..<(range.lowerBound * width)])
            output.append(value)
            cursor = range.upperBound * width
        }
        output.append(data[cursor..<data.count])
        return output
    }
}

/// Foundation-only persistence and failed-load policy. UI/application effects belong to its caller.
final package class SettingsStore {
    private(set) package var value = EditorSettings()
    private var diskBytes: Data?
    private var unreadableIdentity: FileSignature?
    /// Compare exactly the bytes last read or written, including an absent preferences file.
    private func currentBytes() throws -> Data? {
        do { return try WorkspaceStore.readRegularFile(url, maximumBytes: SizePolicy.standard.editorSettings) } catch
            where error.isFileNotFound
        { return nil }
    }
    package func fileIsCurrent() throws -> Bool {
        if diskBytes == nil, loadError != nil {
            var info = stat()
            if lstat(url.path, &info) == 0 { return FileSignature(info) == unreadableIdentity }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return unreadableIdentity == nil
        }
        return try currentBytes() == diskBytes
    }
    private(set) package var ignoredShortcutBindings: [ShortcutLoadIssue] = []
    package var shortcutLoadNotice: String? {
        ignoredShortcutBindings.isEmpty ? nil : ignoredShortcutBindings.map(\.message).joined(separator: "\n\n")
    }
    /// The commands of the menu bar, once the caller knows them. While this is set it replaces
    /// the version-1 `reservedKeys` every call still names, so each of them checks shortcuts
    /// against the same commands.
    package var shortcutContext: ShortcutContext?
    private func context(_ reservedKeys: Set<String>) -> ShortcutContext {
        shortcutContext ?? ShortcutContext(reservedKeys: reservedKeys)
    }
    package func reconcileShortcuts(reservedKeys: Set<String>) {
        guard loadError == nil else { return }
        do {
            let loaded = try value.toleratingShortcuts(context: context(reservedKeys))
            value = loaded.settings
            ignoredShortcutBindings += loaded.issues
        } catch { loadError = error }
    }
    package let loadState: StoreLoadState
    private(set) package var loadError: Error? {
        get { loadState.error }
        set { loadState.error = newValue }
    }
    package let url: URL
    package init(
        url: URL? = nil, reservedKeys: Set<String> = EditorSettings.protectedShortcuts,
        context: ShortcutContext? = nil
    ) {
        shortcutContext = context
        self.url = url ?? AppStorage.url(.settings)
        loadState = StoreLoadState(url: self.url, displayName: "Editor settings")
        do {
            let data = try WorkspaceStore.readRegularFile(self.url, maximumBytes: SizePolicy.standard.editorSettings)
            diskBytes = data
            let loaded = try EditorSettings.load(data, context: context ?? ShortcutContext(reservedKeys: reservedKeys))
            value = loaded.settings
            ignoredShortcutBindings = loaded.issues
        } catch  where error.isFileNotFound {} catch {
            var info = stat()
            if lstat(self.url.path, &info) == 0 { unreadableIdentity = FileSignature(info) }
            loadError = error
        }
    }
    /// A View command changes one Boolean in the latest valid v1 JSON object. Preserve other
    /// members, including ones this build does not recognize. Recheck the source before rename.
    package func updateViewPreference(
        _ preference: EditorViewPreference, reservedKeys: Set<String> = EditorSettings.protectedShortcuts,
        _ update: (Bool) throws -> Bool
    ) throws {
        try updateMember(preference.rawValue, reservedKeys: reservedKeys) { latest in
            let current = preference.enabled(in: latest)
            let requested = try update(current)
            return current == requested ? nil : (requested ? "true" : "false")
        }
    }
    package func updateExternalChangePolicy(
        from displayed: ExternalChangePolicy, to requested: ExternalChangePolicy,
        reservedKeys: Set<String> = EditorSettings.protectedShortcuts
    ) throws {
        try updateMember("externalChangePolicy", reservedKeys: reservedKeys) { latest in
            guard latest.diskChangeBehavior == displayed || latest.diskChangeBehavior == requested else {
                throw SettingsError.changedOnDisk
            }
            return latest.diskChangeBehavior == requested ? nil : "\"" + requested.rawValue + "\""
        }
    }
    package func updateLaunchPreference(from displayed: Bool, to requested: Bool, reservedKeys: Set<String>) throws {
        try updateMember("reopenLastSession", reservedKeys: reservedKeys) { latest in
            guard latest.reopensLastSession == displayed || latest.reopensLastSession == requested else {
                throw SettingsError.changedOnDisk
            }
            return latest.reopensLastSession == requested ? nil : (requested ? "true" : "false")
        }
    }
    /// Settings > Open in, for one preview format. Formats this build does not list are kept.
    package func updatePreviewOpenMode(
        for format: PreviewFormat, from displayed: DocumentViewMode, to requested: DocumentViewMode,
        reservedKeys: Set<String> = EditorSettings.protectedShortcuts
    ) throws {
        try updateMember("previewOpenModes", reservedKeys: reservedKeys) { latest in
            let current = latest.previewOpenMode(for: format)
            guard current == displayed || current == requested else { throw SettingsError.changedOnDisk }
            guard current != requested else { return nil }
            var changed = latest
            changed.setPreviewOpenMode(requested, for: format)
            let bytes = try JSONSerialization.data(
                withJSONObject: changed.previewOpenModes ?? [:], options: [.sortedKeys])
            return String(decoding: bytes, as: UTF8.self)
        }
    }
    /// Remembers the rendered mode chosen last, for Toggle Preview. Source is never recorded.
    package func updateLastRenderedPreviewMode(
        _ mode: DocumentViewMode, reservedKeys: Set<String> = EditorSettings.protectedShortcuts
    ) throws {
        guard mode != .source else { return }
        try updateMember("lastRenderedPreviewMode", reservedKeys: reservedKeys) { latest in
            latest.lastRenderedPreviewMode == mode.rawValue ? nil : "\"" + mode.rawValue + "\""
        }
    }
    private func updateMember(
        _ key: String, reservedKeys: Set<String>, edit: (EditorSettings) throws -> String?
    ) throws {
        guard loadError == nil, ignoredShortcutBindings.isEmpty else { throw SettingsError.unreadable }
        let source = try currentBytes()
        let data = try source ?? JSONEncoder().encode(EditorSettings())
        func validated(_ bytes: Data) throws -> EditorSettings {
            let loaded = try EditorSettings.load(bytes, context: context(reservedKeys))
            guard loaded.issues.isEmpty else { throw SettingsError.unreadable }
            return loaded.settings
        }
        let latest = try validated(data)
        func requireUnchanged() throws {
            guard try currentBytes() == source else { throw SettingsError.changedOnDisk }
        }
        guard let requested = try edit(latest) else {
            try requireUnchanged()
            diskBytes = source
            value = latest
            return
        }
        let result = try SettingsJSON.replacing([key: requested], in: data)
        let accepted = try validated(result)
        try PrivateFileStore.prepareDirectory(url.deletingLastPathComponent())
        try PrivateFileStore.write(
            result, to: url, maximumBytes: SizePolicy.standard.editorSettings, temporaryPrefix: ".settings-",
            beforeCommit: requireUnchanged)
        diskBytes = result
        value = accepted
    }

    /// What the user is told at launch when the settings file could not be read. Every load
    /// schema/security failure gets the same two facts: defaults are in use and the file has
    /// not been changed. Tolerated shortcut-only issues have a separate notice and retained values.
    package var loadFailureMessage: String? {
        loadError.map {
            "The saved settings could not be read, so default settings are in use. The settings file has not been changed.\n\nReason: \($0.localizedDescription)\n\nFile: \(url.path)"
        }
    }
    /// Never overwrites a settings file that failed to load unless the caller has the user's
    /// explicit confirmation. With confirmation the unread file is first moved aside, intact,
    /// under a unique sibling name; it is renamed rather than copied because the load may have
    /// failed on size or permissions. Returns the backup location when one was made.
    @discardableResult package func save(
        _ settings: EditorSettings, replacingUnreadable: Bool = false, requiringCurrent: Bool = false,
        reservedKeys: Set<String> = EditorSettings.protectedShortcuts
    ) throws -> URL? {
        // The file says version 2 only while a shortcut needs it, so a file an older TextTank
        // could read stays one it can read.
        var settings = settings
        if (1...2).contains(settings.version) { settings.version = settings.requiredVersion }
        let context = context(reservedKeys)
        try settings.validate(context: context)
        if loadError != nil && !replacingUnreadable { throw SettingsError.unreadable }
        try PrivateFileStore.prepareDirectory(url.deletingLastPathComponent())
        let ordinary = loadError == nil && ignoredShortcutBindings.isEmpty
        // Full configuration callers supply all known values. Live form edits additionally
        // require their displayed generation; both protect the bytes used for publication.
        let source = ordinary ? try currentBytes() : nil
        if ordinary && requiringCurrent && source != diskBytes { throw SettingsError.changedOnDisk }
        let data: Data
        if let source {
            let prior = try EditorSettings.load(source, context: context)
            guard prior.issues.isEmpty else { throw SettingsError.unreadable }
            data = try SettingsJSON.updating(prior.settings, to: settings, in: source)
            let loaded = try EditorSettings.load(data, context: context)
            guard loaded.settings == settings && loaded.issues.isEmpty else { throw SettingsError.invalid }
        } else {
            data = try JSONEncoder().encode(settings)
        }
        func requireCurrent() throws {
            guard try currentBytes() == source else { throw SettingsError.changedOnDisk }
        }
        if ordinary, data == source {
            try requireCurrent()
            diskBytes = source
            value = settings
            return nil
        }
        let priorError = loadError
        var backup: URL?
        if loadError != nil || !ignoredShortcutBindings.isEmpty {
            // A tolerant load never rewrites implicitly. The first explicit repair save retains
            // the original file with the same strict no-link and rollback guarantees.
            do { backup = try loadState.moveAside(allowSymbolicLink: false, tag: "unreadable") } catch PrivateFileError
                .unsafeLocation
            { throw WorkspaceError.unsafeLocation }
        }
        do {
            try PrivateFileStore.write(
                data, to: url, maximumBytes: SizePolicy.standard.editorSettings, temporaryPrefix: ".settings-",
                beforeCommit: { if ordinary { try requireCurrent() } })
        } catch {
            // Put the original back so a failed replacement leaves the folder as it was.
            if let backup { _ = renamex_np(backup.path, url.path, UInt32(RENAME_EXCL)) }
            loadError = priorError
            throw error
        }
        diskBytes = data
        unreadableIdentity = nil
        value = settings
        loadError = nil
        ignoredShortcutBindings = []
        return backup
    }
}
