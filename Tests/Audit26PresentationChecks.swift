@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

enum Audit26PresentationChecks {
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    /// These fixtures install timers only on RunLoop.main. Transport a Sendable actor-bound
    /// action, rather than capturing AppKit objects directly in Timer's nonisolated callback.
    @MainActor private static func mainTimer(
        _ interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void
    ) -> Timer {
        Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
    }
    @MainActor private static func nativeAttribute(_ element: Any, _ name: String, argument: String? = nil) -> String {
        guard let object = element as? NSObject else { return "" }
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return "" }
        let result = argument.map { object.perform(selector, with: $0) } ?? object.perform(selector)
        return result?.takeUnretainedValue() as? String ?? ""
    }
    /// NSButton hosts can be ignored while their NSButtonCells are the real accessible controls.
    /// Inspect the native unignored tree, descending the group when it is exposed.
    @MainActor private static func checkNativeStatus(_ row: NSView) {
        let roots = NSAccessibility.unignoredChildrenForOnlyChild(from: row)
        let exposedGroup = roots.contains { ($0 as AnyObject) === row }
        check(
            exposedGroup && row.isAccessibilityElement() && row.accessibilityRole() == .group
                && row.accessibilityLabel() == "Document status",
            "G401 native unignored status tree contains its named group")
        var nativeChildren: [Any] = [], seen = Set<ObjectIdentifier>()
        func collect(_ element: Any) {
            guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            nativeChildren.append(element)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] {
                children.forEach(collect)
            }
        }
        roots.forEach(collect)
        let controls = descendants(row).compactMap { $0 as? NSPopUpButton }.filter {
            $0.identifier?.rawValue.hasPrefix("status.") == true
        }
        check(
            !controls.isEmpty && nativeChildren.count >= controls.count,
            "G401 native group exposes every visible status control")
        for control in controls {
            let expected = NSAccessibility.unignoredChildrenForOnlyChild(from: control)
            let actual = nativeChildren.first { child in
                expected.contains { ($0 as AnyObject) === (child as AnyObject) }
            }
            let name = actual.map { nativeAttribute($0, "accessibilityLabel") } ?? ""
            let description =
                actual.map { nativeAttribute($0, "accessibilityAttributeValue:", argument: "AXDescription") } ?? ""
            let role = actual.map { nativeAttribute($0, "accessibilityRole") } ?? ""
            let help = actual.map { nativeAttribute($0, "accessibilityHelp") } ?? ""
            let scopedName = control.accessibilityLabel() ?? ""
            print(
                "AX_STATUS_ELEMENT", control.identifier!.rawValue, "role=", role, "modernLabel=", name,
                "legacyDescription=", description, "help=",
                help)
            check(
                actual != nil && !scopedName.isEmpty
                    && name == scopedName
                    && role == NSAccessibility.Role.menuButton.rawValue && !help.isEmpty,
                "G401 real native status element has scoped name, native menu-button role and options help: \(control.identifier!.rawValue)"
            )
        }
    }
    @MainActor static func run() throws {
        let search = SearchController(
            preferencesURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]!)
                .appendingPathComponent("audit26-find.json"))
        for (field, label) in [
            (search.queryField as NSView, "Find in document"),
            (search.replacementField, "Replace matches with"),
            (search.mode, "Search mode"), (search.scope, "Search scope")
        ] {
            check(field.accessibilityLabel() == label, "G392 populated search input has scoped label: \(label)")
        }
        search.window?.close()
        let automation = AutomationController(editorProvider: { nil }, newDocument: { _ in })
        let first = automation.makeToolbarItem()
        let second = automation.makeToolbarItem()
        for launcher in [first, second] {
            let menu = launcher.menu
            menu.title = "Renamed display title"
            automation.menuNeedsUpdate(menu)
            check(
                menu.items.first?.representedObject == nil && menu.items.first?.title == "Automations",
                "G390 each renamed launcher keeps its non-action placeholder")
        }
        check(
            automation.contextMenu().items.first?.representedObject is String,
            "G390 context menu starts with an invocation, not a launcher placeholder")
        let automationURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]!)
            .appendingPathComponent("Automations.json")
        let originalLibrary = try AutomationLibrary.decode(Data(contentsOf: automationURL))
        var ordinary = AutomationDefinition.recipeFixture, favorite = AutomationDefinition.remindersExample
        ordinary.name = "First saved"
        ordinary.pinToToolbar = false
        favorite.name = "Second saved favorite"
        favorite.pinToToolbar = true
        try automation.persistLibrary(AutomationLibrary(workflows: [ordinary, favorite]))
        func invocationIDs(_ menu: NSMenu) -> [String] {
            menu.items.compactMap { item in
                guard let id = item.representedObject as? String, UUID(uuidString: id) != nil else { return nil }
                return id
            }
        }
        check(
            invocationIDs(automation.menu()) == [ordinary.id.uuidString, favorite.id.uuidString],
            "G416 menu bar retains saved order independent of favorite state")
        check(
            invocationIDs(automation.contextMenu()) == [favorite.id.uuidString, ordinary.id.uuidString],
            "G416 editor context menu puts favorites first")
        let favoriteLauncher = automation.makeToolbarItem()
        check(
            invocationIDs(favoriteLauncher.menu) == [favorite.id.uuidString, ordinary.id.uuidString],
            "G416 toolbar launcher puts favorites first")
        check(
            AutomationDefinition.advancedHelp.contains(AutomationDefinition.favoriteHelp)
                && !AutomationDefinition.advancedHelp.contains("in the Automations menus"),
            "G416 advanced help states current favorite scope accurately")
        var paletteSeen = false, paletteOrder = false, paletteTimedOut = false
        let paletteDeadline = Date().addingTimeInterval(5)
        let paletteTimer = mainTimer(0.05) {
            if Date() > paletteDeadline {
                paletteTimedOut = true
                NSApp.abortModal()
                return
            }
            guard let content = presentedFormWindow?.contentView else { return }
            let views = descendants(content)
            guard let table = views.compactMap({ $0 as? NSTableView }).first,
                let cancel = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" })
            else { return }
            paletteSeen = true
            paletteOrder =
                (0..<table.numberOfRows).compactMap {
                    table.view(atColumn: 0, row: $0, makeIfNecessary: true)?.identifier?.rawValue
                } == [ordinary.id.uuidString, favorite.id.uuidString]
            cancel.performClick(nil)
        }
        RunLoop.main.add(paletteTimer, forMode: .modalPanel)
        automation.showPalette()
        waitForModelessForms(timeout: 5)
        paletteTimer.invalidate()
        check(
            paletteSeen && paletteOrder && !paletteTimedOut,
            "G416 actual Run Automation palette keeps saved order and Cancel invokes nothing")
        try automation.persistLibrary(originalLibrary)
        for count in [0, 1, 2] {
            for truncated in [false, true] {
                let noun = count == 1 ? "entry" : "entries"
                let expected =
                    "\(count) hidden, symbolic-link or special \(noun) skipped"
                    + (truncated ? "; 2,000-entry listing limit reached." : ".")
                check(
                    Strings.workspaceSkipped(count, truncated: truncated, limit: 2000) == expected,
                    "DS84 workspace complete template covers count and truncation")
            }
        }
        let doc = TextDocument()
        doc.makeWindowControllers()
        doc.showWindows()
        defer { doc.close() }
        let controller = doc.windowControllers.first as! EditorWindowController
        controller.refreshStatusDetails()
        let badges = descendants(controller.hostWindow!.contentView!).compactMap { $0 as? NSPopUpButton }
            .filter { $0.identifier?.rawValue.hasPrefix("status.") == true }
        check(
            !badges.isEmpty
                && badges.allSatisfy { !($0.accessibilityLabel() ?? "").isEmpty && $0.accessibilityLabel() != $0.title },
            "G401 every status badge has a descriptive accessibility label")
        let nativeRow = try requireValue(
            descendants(controller.hostWindow!.contentView!).first { $0.accessibilityLabel() == "Document status" },
            "fixture: native status row")
        checkNativeStatus(nativeRow)

        for n in [0, 1, 2] {
            check(
                Strings.count(n, .match) == "\(n) \(n == 1 ? "match" : "matches")",
                "G394 zero/one/many standalone counts")
            for documents in [1, 2] {
                for truncated in [false, true] {
                    let expected =
                        "\(n) \(n == 1 ? "match" : "matches") in \(documents) \(documents == 1 ? "document" : "documents")"
                        + (truncated ? "; result limit reached." : ".")
                    check(
                        Strings.found(n, documents: documents, truncated: truncated) == expected,
                        "G394/DS84 complete count sentence in no-bundle fallback")
                }
            }
        }
        for localeID in ["en_US", "de_DE", "ar_EG"] {
            let locale = Locale(identifier: localeID)
            for value in [6.0, 12.125, 72.0] {
                let spelling = NumericInput.editable(value, locale: locale)
                check(
                    Strings.decimal(spelling, fractional: true, locale: locale) == value,
                    "G399 lossless localized editable number \(localeID)")
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.usesGroupingSeparator = false
                formatter.maximumFractionDigits = 20
                let formatted = formatter.string(from: NSNumber(value: value))!
                check(
                    Strings.decimal(formatted, fractional: true, locale: locale) == value,
                    "G399 formatter output parses fully including localized digits \(localeID)")
            }
        }
        for localeID in ["en_US", "de_DE", "ar_EG"] {
            let field = NSTextField()
            NumericInput.configure(field, fractional: true, locale: Locale(identifier: localeID))
            field.objectValue = NSNumber(value: 12.125)
            check(
                NumericInput.number(field) == 12.125,
                "G399 numeric-object formatter roundtrip remains exact in \(localeID)")
            field.stringValue = "invalid width"
            check(
                field.stringValue == "invalid width" && NumericInput.number(field) == nil,
                "G399 programmatic invalid draft remains visible and fails full validation")
        }
        for bad in ["12junk", "12.5x", "12,5", "1,234", "1.2.3", "NaN", "inf", "1e2", "-12", "12 3"] {
            check(
                Strings.decimal(bad, fractional: true, locale: Locale(identifier: "en_US")) == nil,
                "G399 rejects the entire malformed numeric draft: \(bad)")
        }
        check(
            Strings.integer("12.5") == nil && Strings.integer("9007199254740993") == 9007199254740993,
            "G399 integer grammar rejects fractions without rounding large integers")
        let font = NSTextField(string: ""), size = NSTextField(string: "12,125")
        NumericInput.configure(size, fractional: true, locale: Locale(identifier: "de_DE"))
        let original = LanguageProfile.Style(id: 0, name: "DEFAULT", foreground: "000000", fontStyle: 0)
        let localized = try LanguageController.readStyle(
            original, font: font, size: size, color: .black,
            custom: false, bold: false, italic: false, window: controller.hostWindow!)
        check(localized.fontSize == 12.125, "G399 actual style form parses comma locale without quantizing")
        let unchanged = NSTextField(string: NumericInput.editable(12.125))
        NumericInput.configure(unchanged, fractional: true)
        check(
            try LanguageController.readStyle(
                original, font: font, size: unchanged, color: .black,
                custom: false, bold: false, italic: false, window: controller.hostWindow!
            ).fontSize == 12.125,
            "G399 opening and saving a fractional style size retains the exact Double")
        let popup = NSPopUpButton()
        ControlPresentation.populate(popup, choices: [("a", "Same title"), ("b", "Same title")], selected: "b")
        popup.item(at: 1)?.title = "Renamed"
        check(
            popup.numberOfItems == 2 && ControlPresentation.selectedID(popup) == "b",
            "G390 duplicate/renamed display titles retain represented choice identity")
        for target in FileFormat.convertTargets {
            try doc.convertEncoding(to: target.code)
            check(
                doc.format == target.format && !target.title.isEmpty,
                "F180 typed conversion target keeps exact encoding/BOM")
        }
        let beforeFormat = doc.format, beforeText = doc.editor.text
        rejects("F180 unknown encoding never silently converts to UTF-8") { try doc.convertEncoding(to: "unknown") }
        check(
            doc.format == beforeFormat && doc.editor.text == beforeText,
            "F180 invalid conversion preserves document and format")
        let text = "\t😀e\u{301}\r\nx\ry\n"
        doc.editor.text = text
        for width in [4, 8] {
            doc.editor.configureTabWidth(width, useTabs: true)
            let locations = (0...text.utf16.count).filter {
                SearchCore.byteRange(NSRange(location: $0, length: 0), in: text) != nil
            }
            let positions = try SearchCore.displayPositions(
                locations, in: text, tabWidth: width, cancellation: TTSearchCancellation())
            for (location, position) in zip(locations, positions) {
                let byte = SearchCore.byteRange(NSRange(location: location, length: 0), in: text)!.location
                _ = doc.editor.setSelectionAnchor(byte, caret: byte)
                let info = doc.editor.statusInfo
                check(
                    position.line == info.line && position.column == info.column,
                    "G346 display position agrees with native at scalar/CRLF boundary \(location), tab width \(width)")
            }
        }
        rejects("G346 position mapping remains cancellable") {
            let token = TTSearchCancellation()
            token.cancel()
            _ = try SearchCore.displayPositions([0], in: text, tabWidth: 4, cancellation: token)
        }
        let sortInput = "ab\né\ne\u{301}\n👨‍👩‍👧‍👦\n"
        doc.editor.text = sortInput
        doc.editor.resetUndoHistory()
        try controller.perform(command: "transform.sortLength")
        check(doc.editor.text == "é\nab\ne\u{301}\n👨‍👩‍👧‍👦\n", "G346 length sort uses scalar count, with stable ties")
        _ = doc.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
        check(doc.editor.text.utf8.elementsEqual(sortInput.utf8), "G346 Unicode length sort is one native Undo action")

        var acted = false, timedOut = false, cancelled = false
        let alert = TTAlert(), numeric = NSTextField(string: "12")
        NumericInput.configure(numeric, fractional: true)
        numeric.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        numeric.setAccessibilityLabel("Numeric cancellation fixture")
        alert.accessoryView = numeric
        alert.addButton(withTitle: "Save")
        let cancel = alert.addButton(withTitle: "Cancel", role: .cancel)
        alert.window.initialFirstResponder = numeric
        let deadline = Date().addingTimeInterval(5)
        let timer = mainTimer(0.05) {
            if Date() > deadline {
                timedOut = true
                NSApp.abortModal()
                return
            }
            guard NSApp.modalWindow === alert.window, !acted else { return }
            acted = true
            numeric.selectText(nil)
            for character in "12junk" {
                let value = String(character)
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: alert.window.windowNumber,
                    context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: 0)!
                alert.window.sendEvent(event)
            }
            cancel.performClick(nil)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        cancelled = alert.runModal() == .alertSecondButtonReturn
        timer.invalidate()
        check(acted && !timedOut && cancelled, "G399 actual Cancel escapes a numeric form with invalid active editing")
        check(
            NumericInput.number(numeric) == nil && NumericInput.text(numeric).contains("junk"),
            "G399 invalid active numeric draft remains complete rather than saving a parsed prefix")

        let retry = TTAlert(), draft = NSTextField(string: "16")
        NumericInput.configure(draft)
        draft.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        draft.setAccessibilityLabel("Numeric retry fixture")
        retry.accessoryView = draft
        let save = retry.addButton(withTitle: "Save")
        let leave = retry.addButton(withTitle: "Cancel", role: .cancel)
        var retryStage = 0, retryKept = false, retryTimedOut = false
        let retryDeadline = Date().addingTimeInterval(5)
        let retryTimer = mainTimer(0.05) {
            if Date() > retryDeadline {
                retryTimedOut = true
                NSApp.abortModal()
                return
            }
            guard NSApp.modalWindow === retry.window else { return }
            if retryStage == 0 {
                draft.stringValue = "invalid width"
                retryStage = 1
                save.performClick(nil)
            } else if retryStage == 1 {
                retryKept = draft.stringValue == "invalid width"
                retryStage = 2
                leave.performClick(nil)
            }
        }
        RunLoop.main.add(retryTimer, forMode: .modalPanel)
        while retry.runModal() == .alertFirstButtonReturn {
            if NumericInput.integer(draft) != nil { break }
            retry.showValidation(SettingsError.tabWidth, field: draft)
        }
        retryTimer.invalidate()
        check(
            retryStage == 2 && !retryTimedOut && retryKept,
            "G399 rejected numeric Save redisplays the complete invalid draft before Cancel")

        let state = StoreLoadState(
            url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]!)
                .appendingPathComponent("write-failure.json"), displayName: "Write-failure settings")
        state.error = FileOperationFailure(EACCES, operation: "save settings", path: state.url.path)
        var recoveryHeading = false, recoveryCancelled = false
        let recoveryDeadline = Date().addingTimeInterval(5)
        let recoveryTimer = mainTimer(0.05) {
            if Date() > recoveryDeadline {
                NSApp.abortModal()
                return
            }
            guard let content = presentedFormWindow?.contentView else { return }
            let views = descendants(content)
            recoveryHeading = views.compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == "TextTank could not use “Write-failure settings”"
            }
            if let cancel = views.compactMap({ $0 as? NSButton }).first(where: {
                $0.identifier?.rawValue == "store.recover.cancel"
            }) {
                recoveryCancelled = true
                cancel.performClick(nil)
            }
        }
        RunLoop.main.add(recoveryTimer, forMode: .modalPanel)
        let writable = try StoreRecovery.ensureWritable(state)
        recoveryTimer.invalidate()
        check(
            recoveryHeading && recoveryCancelled && !writable && state.error != nil,
            "G398 write failure recovery has condition-accurate wording and Cancel preserves its latch")

    }
}
