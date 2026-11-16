import Foundation

/// These same checks also compile and run without AppKit or an editor bridge.
enum DocumentCoreChecks {
    static func run(root: URL) throws {
        let url = root.appendingPathComponent("audit29-foundation-settings.json")
        let store = SettingsStore(url: url)
        check(
            store.loadError == nil && store.value == EditorSettings(),
            "F285 a Foundation settings store reads defaults without creating or presenting anything")
        var value = EditorSettings()
        value.tabWidth = 6
        value.useTabs = false
        value.setShortcut("k", for: "deleteLine")
        try store.save(value)
        check(
            SettingsStore(url: url).value == value,
            "F285 the Foundation store saves and reloads the unchanged settings schema")
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
            .intValue
        check(mode == 0o600, "F285 extracted settings writes retain exact private permissions")
        let invalid = Data("{\"version\":2}".utf8)
        try invalid.write(to: url)
        let unreadable = SettingsStore(url: url)
        rejects("F285 a Foundation failed-load latch refuses a save") { try unreadable.save(value) }
        check(
            try Data(contentsOf: url) == invalid,
            "F285 the extracted store preserves the unreadable original bytes")
        check(
            EditorTransform.removeEmptyLines.transform("one\n\ntwo\r\n") == "one\ntwo\r\n",
            "F285 pure line transforms need neither AppKit nor an editor instance")
        let catalog = try LanguageCatalog.decode(
            Data(contentsOf: TestPaths.resources.appendingPathComponent("LanguageProfiles.json")))
        let python = try requireValue(catalog.profiles.first { $0.id == "python" }, "F285 fixture: Python comments")
        let plan = try CommentCommand.lineComment.plan(
            text: "value\n", selections: [["anchor": 0, "caret": 0]], profile: python)
        check(
            plan.text == "# value\n" && plan.edits.count == 1,
            "F285 pure comment planning exposes the same bounded edit plan without AppKit")
    }
}
