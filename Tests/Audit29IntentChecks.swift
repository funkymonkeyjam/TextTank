import AppKit

@MainActor enum Audit29IntentChecks {
    static func run() throws {
        let previous = EditorServices.current
        defer { EditorServices.current = previous }
        let composition = AppDelegate()
        composition.installEditorServices()
        let document = DocumentFactory.makeUntitled()
        defer { document.close() }
        document.editor.text = "int main() { return 1; }"
        let window = try requireValue(
            document.windowControllers.first as? EditorWindowController,
            "F186 fixture: document controller")
        composition.noteActive(window)
        window.clone(nil)
        let siblingViews = composition.languages.siblingViews
        var applications = 0
        composition.languages.siblingViews = { editor in
            applications += 1
            return siblingViews(editor)
        }
        let item = try requireValue(
            composition.languages.menu().items.first {
                ($0.representedObject as? String) == "cpp"
            }, "F186 fixture: C++ language action")
        let revision = document.editor.revision, bytes = document.editor.utf8Data
        check(
            NSApp.sendAction(item.action!, to: item.target, from: item)
                && document.languageIdentifier == "cpp" && applications == 1,
            "F186 the real language action records its state notification without applying the lexer twice")
        check(
            document.editor.revision == revision && document.editor.utf8Data == bytes,
            "F186 language intent leaves authoritative bytes and revision unchanged")
        check(
            document.applyLanguage("python", using: composition.languages)
                && document.languageIdentifier == "python" && applications == 2,
            "F186 explicit document language intent applies once then records the successful identifier")
        check(
            !document.applyLanguage("audit29-unavailable-profile", using: composition.languages)
                && document.languageIdentifier == "python" && applications == 2,
            "F186 a rejected language intent changes neither the identifier nor lexer application count")
        window.setStatusMessage("Owned status fixture")
        window.appendStatusMessage("; complete")
        check(
            window.statusText == "Owned status fixture; complete" && document.editor.revision == revision,
            "F186 status intent updates only the owned label and leaves the document untouched")
    }
    static func checkMenuTargets(_ menu: NSMenu, composition: AppDelegate) throws {
        let rows =
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf:
                        TestPaths.fixtures.appendingPathComponent("menu-tree-wave-3.json"))) as! [[String: String]]
        let commands = rows.filter { $0["target"] == "explicit" && $0["action"] != "submenuAction:" }
        var wrong: [String] = []
        for row in commands {
            let path = row["position"]!.split(separator: ".").map { Int($0)! }
            var current = menu
            var item: NSMenuItem?
            for (depth, index) in path.enumerated() {
                guard current.items.indices.contains(index) else { break }
                item = current.items[index]
                if depth + 1 < path.count, let submenu = item?.submenu { current = submenu }
            }
            let expected: AnyObject?
            switch path[0] {
            case 0: expected = composition.settings
            case 1: expected = composition.workspace
            case 2: expected = composition.workspaceBrowser
            case 5:
                switch path[1] {
                case 1: expected = composition.searchController
                case 5: expected = composition.folderSearch
                default: expected = composition
                }
            case 6: expected = composition.runner
            case 7: expected = composition.utilities
            case 9: expected = composition.languages
            case 10: expected = composition.macros
            case 11: expected = composition.automations
            case 12: expected = composition
            default: expected = nil
            }
            if expected == nil || item?.target !== expected { wrong.append(row["position"]!) }
        }
        check(
            commands.count > 100 && wrong.isEmpty,
            "F274/F276 every explicit command target is its actual composition-root instance (wrong: \(wrong))")
    }
}
