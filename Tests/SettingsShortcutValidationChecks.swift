// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Actual modal controls, shared by document acceptance and the bounded standalone regression.
enum SettingsShortcutValidationChecks {
    struct Scenario {
        let name: String, first: String, key: String, second: String, secondKey: String
        let expected: String, expectedKey: String
        var initial = EditorSettings()
        var clearFirst = false
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor static func run(root: URL) {
        var restoredDefault = EditorSettings()
        restoredDefault.shortcuts = ["duplicateLine": "j", "upper": "d"]
        let scenarios = [
            Scenario(name: "invalid", first: "upper", key: "??", second: "deleteLine", secondKey: "k", expected: "upper", expectedKey: "??"),
            Scenario(name: "reserved", first: "upper", key: "q", second: "deleteLine", secondKey: "k", expected: "upper", expectedKey: "q"),
            Scenario(name: "duplicate", first: "upper", key: "k", second: "deleteLine", secondKey: "k", expected: "upper", expectedKey: "k"),
            Scenario(name: "restored-default", first: "duplicateLine", key: "", second: "deleteLine", secondKey: "k", expected: "upper", expectedKey: "d", initial: restoredDefault, clearFirst: true),
            Scenario(name: "implicit-default", first: "deleteLine", key: "d", second: "upper", secondKey: "u", expected: "deleteLine", expectedKey: "d")
        ]
        for scenario in scenarios {
            Checks.section("earlier shortcut row: " + scenario.name) {
                let url = root.appendingPathComponent("shortcut-validation-" + scenario.name + ".json")
                let controller = SettingsController(url: url)
                try controller.save(scenario.initial)
                let original = try Data(contentsOf: url)
                var stage = 0, correctRow = false, keptDrafts = false
                let deadline = Date().addingTimeInterval(10)
                let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        guard let window = NSApp.modalWindow, let content = window.contentView else { return }
                        if Date() > deadline { NSApp.abortModal(); return }
                        let views = descendants(content)
                        guard let popup = views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.identifier?.rawValue == "settings.shortcut.command" }),
                            let key = views.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "settings.shortcut.key" }) else { return }
                        @MainActor func select(_ id: String) {
                            guard let entry = popup.itemArray.first(where: { $0.representedObject as? String == id }) else { return }
                            popup.select(entry)
                            if let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
                        }
                        if stage == 0 {
                            select(scenario.first)
                            if scenario.clearFirst {
                                views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "settings.shortcut.clear" }?.performClick(nil)
                            } else { key.stringValue = scenario.key }
                            select(scenario.second)
                            key.stringValue = scenario.secondKey
                            stage = 1
                            views.compactMap { $0 as? NSButton }.first { $0.title == "Save" }?.performClick(nil)
                        } else if stage == 1 && views.contains(where: { $0.accessibilityLabel() == "Input needs correction" }) {
                            correctRow = popup.selectedItem?.representedObject as? String == scenario.expected
                                && key.stringValue == scenario.expectedKey && key.accessibilityHelp() != nil
                                && window.firstResponder === key.currentEditor()
                            select(scenario.second)
                            keptDrafts = key.stringValue == scenario.secondKey
                            select(scenario.first)
                            let firstValue = scenario.clearFirst ? EditorCommand.defaultShortcuts[scenario.first] ?? "" : scenario.key
                            keptDrafts = keptDrafts && key.stringValue == firstValue
                            stage = 2
                            views.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }?.performClick(nil)
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                controller.showSettings(nil)
                timer.invalidate()
                check(correctRow, "DS45 " + scenario.name + " shortcut selects, shows and marks the actual offending command field")
                check(stage == 2 && keptDrafts, "DS45 " + scenario.name + " validation retains every popup draft and restored default")
                check(try Data(contentsOf: url) == original && controller.value == scenario.initial, "DS45 " + scenario.name + " rejection and Cancel preserve original settings bytes/model")
            }
        }
    }
}
