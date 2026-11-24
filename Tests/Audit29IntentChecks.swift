@testable import TextTankCore
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

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
            composition.languages.languageMenuItems().first {
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
    /// Every explicitly targeted command reaches its owner. The owner is found from the command's
    /// identity (its action, and its shortcut where two owners share an action), never from its
    /// position, so regrouping a menu cannot hide a wrong target.
    static func checkMenuTargets(_ menu: NSMenu, composition: AppDelegate) throws {
        let owners: [(owner: AnyObject, actions: [String])] = [
            (
                composition,
                [
                    "installCommandLine:", "findNextShared:", "findPreviousShared:", "actualSize:",
                    "performCompareCommand:", "nextDocumentTab:", "previousDocumentTab:", "performTabCommand:",
                    "clearLocalHistory:"
                ]
            ),
            (
                composition.settings,
                [
                    "showSettings:", "toggleAutoIndent:", "toggleAutoPair:", "toggleBraceHighlight:",
                    "toggleCurrentLineHighlight:", "toggleIndentGuides:"
                ]
            ),
            (composition.workspace, ["saveSession:", "openSession:"]),
            (composition.workspaceBrowser, ["show:", "quickOpen:", "addFolder:", "toggleMonitor:", "reloadMonitored:"]),
            (
                composition.automations,
                [
                    "pasteAction:", "manageAction", "paletteAction", "reminderHistory", "restoreDefaultsAction",
                    "showPalette", "runAction:"
                ]
            ),
            (composition.compare, ["showPicker:", "markCurrent:", "compareCurrent:", "compareVisibleTabs:"]),
            (composition.runner, ["configure:", "manage:", "addSample:", "cancel:"]),
            (composition.utilities, ["run:", "hexOptions:", "convertNumber:", "exportStyled:"]),
            (composition.workspaceWindow.groupCommands, ["invoke:"]),
            (composition.workspaceWindow.areaFocus, ["moveFocusToNextArea:", "moveFocusToPreviousArea:"]),
            (
                composition.languages,
                [
                    "complete", "functions", "callTip", "styleSettings", "configure", "importUDL", "editUDL",
                    "exportUDL", "selectLanguage:"
                ]
            ),
            (
                composition.macros,
                ["startRecording", "stopRecording", "playLast", "saveLast", "manage", "playAgain", "playSaved:"]
            )
        ]
        func owner(of item: NSMenuItem) -> AnyObject? {
            let action = item.action.map(NSStringFromSelector) ?? ""
            // Find and Replace and Find in Folder share a selector; their shortcuts tell them apart.
            if action == "showSearch:" {
                return item.keyEquivalentModifierMask == [.command, .option]
                    ? composition.searchController : composition.folderSearch
            }
            // A saved Run command is a UUID; a text utility is its case name.
            if action == "run:", (item.representedObject as? String).flatMap(UUID.init(uuidString:)) != nil {
                return composition.runner
            }
            return owners.first { $0.actions.contains(action) }?.owner
        }
        func commands(_ menu: NSMenu, _ path: String) -> [(path: String, item: NSMenuItem)] {
            menu.items.flatMap { item -> [(path: String, item: NSMenuItem)] in
                let here = path.isEmpty ? item.title : path + " > " + item.title
                if let submenu = item.submenu { return commands(submenu, here) }
                return item.target == nil || item.action == nil ? [] : [(here, item)]
            }
        }
        let explicit = commands(menu, "")
        let wrong = explicit.filter { owner(of: $0.item) == nil || $0.item.target !== owner(of: $0.item) }.map(\.path)
        check(
            explicit.count > 100 && wrong.isEmpty,
            "F274/F276 every explicit command target is its actual composition-root instance (wrong: \(wrong))")
    }
}
