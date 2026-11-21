// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Persisted format, version 1; see "Persisted formats" in docs/architecture.md. A new field
/// must be Optional or decoded with decodeIfPresent in an extension, or old files stop loading.
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
    package var wrap: Bool
    package var appearance: String
    // Key equivalents use AppKit's uppercase convention for Shift.
    package var shortcuts: [String: String]
    static package let commands = EditorCommand.shortcutIdentifiers
    static package let reserved: Set<String> = [
        "a", "c", "v", "x", "z", "Z", "s", "S", "n", "o", "w", "q", "p", "f", "F", "g", "G", "P", "m", "[", "]", "+",
        "-", ",", "h", "l"
    ]
    /// Empty/default removes an override; the version-1 wire vocabulary never stores an empty key.
    mutating package func setShortcut(_ key: String, for id: String) {
        if key.isEmpty || key == EditorCommand.defaultShortcuts[id] {
            shortcuts.removeValue(forKey: id)
        } else {
            shortcuts[id] = key
        }
    }
    package func shortcut(for id: String) -> String { shortcuts[id] ?? EditorCommand.defaultShortcuts[id] ?? "" }
    static package func validShortcutKey(_ key: String) -> Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 }
    }
    // System Find selection and window cycling are protected even before a main menu exists.
    static package let protectedShortcuts = reserved.union(["e", "`"])
    package func validate(reservedKeys: Set<String> = Self.protectedShortcuts) throws {
        guard version == 1, (1...32).contains(tabWidth), ["system", "light", "dark"].contains(appearance) else {
            throw SettingsError.invalid
        }
        if let fontName {
            guard !fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fontName.utf8.count <= 200,
                fontName.rangeOfCharacter(from: .controlCharacters) == nil
            else { throw SettingsError.invalidFont }
        }
        guard basePointSize.isFinite, (6...72).contains(basePointSize), (-10...60).contains(initialZoom)
        else { throw SettingsError.invalidFont }
        if let failure = shortcutValidationFailure(reservedKeys: reservedKeys) { throw failure.error }
    }
    /// The same deterministic validation supplies identity to editors and errors to strict saves.
    /// An implicit default cannot be edited in isolation; identify its conflicting explicit override.
    package func shortcutValidationFailure(reservedKeys: Set<String>) -> ShortcutValidationFailure? {
        var effective = EditorCommand.defaultShortcuts
        effective.merge(shortcuts) { _, new in new }
        var owners: [String: String] = [:]
        for id in effective.keys.sorted() {
            let key = effective[id] ?? ""
            guard Self.commands.contains(id) else { return .init(command: id, error: .unknownShortcut) }
            guard Self.validShortcutKey(key) else { return .init(command: id, error: .invalidShortcut) }
            guard !reservedKeys.contains(key) else { return .init(command: id, error: .conflict) }
            if let owner = owners[key] {
                let command = shortcuts[id] == nil ? owner : id
                return .init(command: command, error: .duplicateShortcut(first: owner, second: id, key: key))
            }
            owners[key] = id
        }
        return nil
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
        try PersistedFormat.check(data, context: "Editor settings")
        return try JSONDecoder().decode(Self.self, from: data).toleratingShortcuts(reservedKeys: reservedKeys)
    }
    package func toleratingShortcuts(reservedKeys: Set<String>) throws -> (settings: Self, issues: [ShortcutLoadIssue])
    {
        var result = self
        result.shortcuts = [:]
        // Core schema/values are never repaired, guessed or made lenient.
        try result.validate(reservedKeys: reservedKeys)
        var issues: [String: ShortcutLoadIssue] = [:]
        for id in shortcuts.keys.sorted() {
            guard let key = shortcuts[id] else { continue }
            let reason: ShortcutLoadIssue.Reason?
            if !Self.commands.contains(id) {
                reason = .unavailable
            } else if !Self.validShortcutKey(key) {
                reason = .invalid
            } else if reservedKeys.contains(key) {
                reason = .reserved
            } else {
                reason = nil
            }
            if let reason {
                issues[id] = .init(command: id, key: key, reason: reason)
            } else {
                result.shortcuts[id] = key
            }
        }
        // Removing a conflicting override can restore a default key. Re-evaluate until stable;
        // there are only twelve assignable commands, and every iteration removes an override.
        while true {
            var effective = EditorCommand.defaultShortcuts
            effective.merge(result.shortcuts) { _, new in new }
            let groups = Dictionary(grouping: effective.keys, by: { effective[$0] ?? "" })
            var removed = false
            for key in groups.keys.sorted() {
                let ids = (groups[key] ?? []).sorted()
                guard ids.count > 1 else { continue }
                let winner = ids.first { result.shortcuts[$0] == nil } ?? ids[0]
                for id in ids where id != winner {
                    if result.shortcuts.removeValue(forKey: id) != nil {
                        issues[id] = .init(command: id, key: key, reason: .duplicate(winner))
                        removed = true
                    }
                }
            }
            if !removed { break }
        }
        try result.validate(reservedKeys: reservedKeys)
        return (result, issues.values.sorted { $0.command < $1.command })
    }
}
package struct ShortcutLoadIssue: Equatable {
    package init(command: String, key: String, reason: Reason) {
        self.command = command
        self.key = key
        self.reason = reason
    }

    package enum Reason: Equatable { case unavailable, invalid, reserved, duplicate(String) }
    package let command: String, key: String, reason: Reason
    package var message: String {
        let title = EditorCommand(rawValue: command)?.title ?? "Unavailable command"
        switch reason {
        case .unavailable:
            return
                "A saved shortcut for a command that is no longer available was ignored. Other settings remain in use. The settings file has not been changed."
        case .invalid:
            return
                "The saved shortcut for “\(title)” is not one supported printable character and was ignored. Other settings remain in use. The settings file has not been changed."
        case .reserved:
            return
                "The saved shortcut for “\(title)” is reserved for another action and was ignored. Other settings remain in use. The settings file has not been changed."
        case .duplicate(let owner):
            let ownerTitle = EditorCommand(rawValue: owner)?.title ?? "another command"
            return
                "The saved shortcut for “\(title)” conflicts with “\(ownerTitle)” and was ignored. Other settings remain in use. The settings file has not been changed."
        }
    }
}
package enum SettingsError: Error, LocalizedError, Equatable {
    case invalid, invalidFont, conflict, unreadable, tabWidth, unknownShortcut, invalidShortcut, changedOnDisk,
        ambiguousViewPreference
    case duplicateShortcut(first: String, second: String, key: String)
    package var errorDescription: String? {
        switch self {
        case .ambiguousViewPreference:
            return
                "The saved View preference is ambiguous. Check Settings.json for duplicate preference keys, then try again."
        case .changedOnDisk: return "The settings file changed before this edit finished. Try the command again."
        case .tabWidth: return "Tab width must be a whole number from 1 to 32. The settings were not changed."
        case .invalidFont: return "Choose a font name, a size from 6 to 72 points and a default zoom from −10 to 60."
        case .invalid: return "Unsupported settings version or value. Existing settings have not been replaced."
        case .conflict:
            return
                "That shortcut is reserved for another action. Choose a different key. The settings were not changed."
        case .unknownShortcut: return "This command cannot be assigned a shortcut. The settings were not changed."
        case .invalidShortcut: return "A shortcut must be one printable ASCII character. The settings were not changed."
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
    package init(command: String, error: SettingsError) {
        self.command = command
        self.error = error
    }

    package let command: String
    package let error: SettingsError
    package var errorDescription: String? {
        let title = EditorCommand(rawValue: command)?.title ?? "Unavailable command"
        switch error {
        case .invalidShortcut:
            return "The shortcut for “\(title)” must be one printable ASCII character. The settings were not changed."
        case .conflict:
            return
                "The shortcut for “\(title)” is reserved for another action. Choose a different key. The settings were not changed."
        default: return error.localizedDescription
        }
    }
}

/// A working copy keeps edits made for earlier popup rows; selection is never inferred from a title.
package struct SettingsShortcutDraft {
    private(set) package var settings: EditorSettings
    private(set) package var selected: String
    package init(_ settings: EditorSettings) {
        self.settings = settings
        selected =
            EditorCommand.allCases.filter(\.isShortcutAssignable).sorted { $0.title < $1.title }.first?.rawValue ?? ""
    }
    mutating package func select(_ id: String, committing key: String) -> String {
        settings.setShortcut(key, for: selected)
        selected = id
        return settings.shortcut(for: id)
    }
    mutating package func commit(_ key: String) { settings.setShortcut(key, for: selected) }
    mutating package func clear() -> String {
        settings.setShortcut("", for: selected)
        return settings.shortcut(for: selected)
    }
}
package enum EditorViewPreference: String {
    case autoIndent, autoPair, braceHighlight, currentLineHighlight, indentGuides
    fileprivate func enabled(in settings: EditorSettings) -> Bool {
        switch self {
        case .autoIndent: return settings.autoIndentEnabled
        case .autoPair: return settings.autoPairEnabled
        case .braceHighlight: return settings.braceHighlightEnabled
        case .currentLineHighlight: return settings.currentLineHighlightEnabled
        case .indentGuides: return settings.indentGuidesEnabled
        }
    }
    /// The caller has already decoded and validated the complete settings object. Locate only
    /// this top-level member. Unrelated JSON values never pass through NSNumber or NSString.
    fileprivate func setting(_ enabled: Bool, in data: Data) throws -> Data {
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
        var depth = 0, i = 0, endOfObject: Int?, valueRange: Range<Int>?
        while i < ascii.count {
            switch ascii[i] {
            case 123, 91: depth += 1 // { [
            case 125, 93: // } ]
                if depth == 1 && ascii[i] == 125 { endOfObject = i }
                depth -= 1
            case 34: // A string. Escape pairs cannot close it.
                let start = i
                i += 1
                while i < ascii.count, ascii[i] != 34 { i += ascii[i] == 92 ? 2 : 1 }
                guard i < ascii.count else { throw SettingsError.ambiguousViewPreference }
                let end = i + 1, colon = nextToken(end)
                if depth == 1, colon < ascii.count, ascii[colon] == 58,
                    end - start <= rawValue.utf8.count * 6 + 2,
                    let name = try? JSONDecoder().decode(String.self, from: Data(ascii[start..<end])),
                    name.utf8.elementsEqual(rawValue.utf8)
                {
                    let begin = nextToken(colon + 1)
                    guard valueRange == nil, begin < ascii.count else { throw SettingsError.ambiguousViewPreference }
                    let rest = ascii[begin...]
                    guard let token = ["true", "false", "null"].first(where: { rest.starts(with: $0.utf8) }) else {
                        throw SettingsError.ambiguousViewPreference
                    }
                    valueRange = begin..<(begin + token.utf8.count)
                }
            default: break
            }
            i += 1
        }
        guard let endOfObject else { throw SettingsError.ambiguousViewPreference }
        let value = enabled ? "true" : "false"
        let range = valueRange ?? endOfObject..<endOfObject
        let text: String
        if valueRange != nil {
            text = value
        } else {
            var last = endOfObject - 1
            while last >= 0 && whitespace(ascii[last]) { last -= 1 }
            guard last >= 0 else { throw SettingsError.ambiguousViewPreference }
            let comma = ascii[last] == 44 || ascii[last] == 123 ? "" : ","
            text = comma + "\"" + rawValue + "\":" + value
        }
        var encoded = [UInt8](repeating: 0, count: width * text.utf8.count)
        for (index, byte) in text.utf8.enumerated() { encoded[index * width + lane] = byte }
        var output = data
        output.replaceSubrange((range.lowerBound * width)..<(range.upperBound * width), with: encoded)
        return output
    }
}

/// Foundation-only persistence and failed-load policy. UI/application effects belong to its caller.
final package class SettingsStore {
    private(set) package var value = EditorSettings()
    private var diskBytes: Data?
    private var unreadableIdentity: FileSignature?
    /// Compare exactly the bytes last read or written, including an absent preferences file.
    package func fileIsCurrent() throws -> Bool {
        if diskBytes == nil, loadError != nil {
            var info = stat()
            if lstat(url.path, &info) == 0 { return FileSignature(info) == unreadableIdentity }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return unreadableIdentity == nil
        }
        do { return try WorkspaceStore.readRegularFile(url, maximumBytes: 1024 * 1024) == diskBytes } catch
            where error.isFileNotFound
        { return diskBytes == nil }
    }
    private(set) package var ignoredShortcutBindings: [ShortcutLoadIssue] = []
    package var shortcutLoadNotice: String? {
        ignoredShortcutBindings.isEmpty ? nil : ignoredShortcutBindings.map(\.message).joined(separator: "\n\n")
    }
    package func reconcileShortcuts(reservedKeys: Set<String>) {
        guard loadError == nil else { return }
        do {
            let loaded = try value.toleratingShortcuts(reservedKeys: reservedKeys)
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
    package init(url: URL? = nil, reservedKeys: Set<String> = EditorSettings.protectedShortcuts) {
        self.url = url ?? AppStorage.url(.settings)
        loadState = StoreLoadState(url: self.url, displayName: "Editor settings")
        do {
            let data = try WorkspaceStore.readRegularFile(self.url, maximumBytes: 1024 * 1024)
            diskBytes = data
            let loaded = try EditorSettings.load(data, reservedKeys: reservedKeys)
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
        guard loadError == nil, ignoredShortcutBindings.isEmpty else { throw SettingsError.unreadable }
        func currentBytes() throws -> Data? {
            do { return try WorkspaceStore.readRegularFile(url, maximumBytes: 1024 * 1024) } catch
                where error.isFileNotFound
            { return nil }
        }
        let source = try currentBytes()
        let data = try source ?? JSONEncoder().encode(EditorSettings())
        func validated(_ bytes: Data) throws -> EditorSettings {
            let loaded = try EditorSettings.load(bytes, reservedKeys: reservedKeys)
            guard loaded.issues.isEmpty else { throw SettingsError.unreadable }
            return loaded.settings
        }
        let latest = try validated(data)
        let enabled = preference.enabled(in: latest)
        let requested = try update(enabled)
        func requireUnchanged() throws {
            guard try currentBytes() == source else { throw SettingsError.changedOnDisk }
        }
        if enabled == requested {
            try requireUnchanged()
            diskBytes = source
            value = latest
            return
        }
        let result = try preference.setting(requested, in: data)
        let accepted = try validated(result)
        try PrivateFileStore.prepareDirectory(url.deletingLastPathComponent())
        try PrivateFileStore.write(
            result, to: url, maximumBytes: 1024 * 1024, temporaryPrefix: ".settings-", beforeCommit: requireUnchanged)
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
        _ settings: EditorSettings, replacingUnreadable: Bool = false,
        reservedKeys: Set<String> = EditorSettings.protectedShortcuts
    ) throws -> URL? {
        try settings.validate(reservedKeys: reservedKeys)
        if loadError != nil && !replacingUnreadable { throw SettingsError.unreadable }
        try PrivateFileStore.prepareDirectory(url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(settings)
        let priorError = loadError
        var backup: URL?
        if loadError != nil || !ignoredShortcutBindings.isEmpty {
            // A tolerant load never rewrites implicitly. The first explicit repair save retains
            // the original file with the same strict no-link and rollback guarantees.
            do { backup = try loadState.moveAside(allowSymbolicLink: false, tag: "unreadable") } catch PrivateFileError
                .unsafeLocation
            { throw WorkspaceError.unsafeLocation }
        }
        do { try PrivateFileStore.write(data, to: url, maximumBytes: 1024 * 1024, temporaryPrefix: ".settings-") } catch
        {
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
