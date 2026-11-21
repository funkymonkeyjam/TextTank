import AppKit
@testable import TextTankCore
@testable import TextTankRuntime

@MainActor enum ExternalFilePolicyChecks {
    static func run(in root: URL) throws {
        let settings = root.appendingPathComponent("external-policy-settings.json")
        let old =
            #"{"version":1,"tabWidth":4,"useTabs":true,"wrap":false,"appearance":"system","shortcuts":{},"opaque":[123456789012345678901234567890,"\uFEFFX"]}"#
        try Data(old.utf8).write(to: settings)
        let stale = SettingsStore(url: settings)
        check(stale.value.diskChangeBehavior == .ask, "historical settings start in Ask")
        try stale.updateExternalChangePolicy(from: .ask, to: .ask)
        check(try Data(contentsOf: settings) == Data(old.utf8), "selecting default Ask preserves original bytes")
        let file = root.appendingPathComponent("external-policy-cp1252.txt")
        try Data([0x80, 0x31]).write(to: file)
        let doc = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(file), from: file, as: .windows1252, display: false)
        defer { doc.close() }
        let view = try requireValue(doc.presentation, "policy fixture tab")
        let controller = SettingsController(url: settings, onApply: EditorSettingsApplication.apply)
        controller.showSettings(nil)
        let form = try requireValue(FormPanel.visible.last, "live external file policy form")
        defer { form.window.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let popup = try requireValue(
            views(form.window.contentView!).compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == "settings.externalChanges" }, "file policy popup")
        func select(_ choice: ExternalChangePolicy) throws {
            let item = try requireValue(
                popup.itemArray.first { ($0.representedObject as? String) == choice.rawValue }, "policy item")
            popup.select(item)
            check(
                NSApp.sendAction(try requireValue(popup.action, "policy action"), to: popup.target, from: popup),
                "Settings dispatches " + choice.rawValue)
        }
        check(
            popup.itemTitles == ["Ask", "Reload if unmodified", "Ignore"], "live Settings exposes three disk policies")
        let newer = old.replacingOccurrences(of: #""tabWidth":4"#, with: #""tabWidth":23"#)
        try Data(newer.utf8).write(to: settings, options: .atomic)
        try Data([0x80, 0x32]).write(to: file, options: .atomic)
        try select(.reloadIfUnmodified)
        let expected = String(newer.dropLast()) + #","externalChangePolicy":"reloadIfUnmodified"}"#
        check(
            try Data(contentsOf: settings) == Data(expected.utf8) && controller.value.tabWidth == 23,
            "changing one live setting preserves newer fields and opaque bytes")
        _ = spinUntil("unmodified external bytes reloaded live") { doc.editor.text == "€2" }
        check(
            doc.presentation === view && doc.format.encoding == .windows1252 && !doc.isDocumentEdited,
            "automatic reload keeps stable CP1252 document and presentation")
        do {
            try stale.updateExternalChangePolicy(from: .ask, to: .ignore)
            check(false, "stale same-field selection refused")
        } catch SettingsError.changedOnDisk {
            check(try Data(contentsOf: settings) == Data(expected.utf8), "stale same-field refusal preserves bytes")
        }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        doc.externalFile.readCandidate = { url, limit in
            let captured = try WorkspaceStore.captureRegularFile(url, maximumBytes: limit)
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return captured
        }
        try Data([0x80, 0x33]).write(to: file, options: .atomic)
        view.host.activate(view, focus: false)
        _ = spinUntil("automatic reload captured") { entered.wait(timeout: .now()) == .success }
        _ = doc.editor.replaceSelection("pending")
        let pending = doc.editor.text, revision = doc.editor.revision
        release.signal()
        _ = spinUntil("automatic worker rejected changed editor") {
            doc.externalFile.actionTitle == "Reload…" && doc.isDocumentEdited
        }
        try select(.ignore)
        check(
            doc.externalFile.notice == nil && doc.editor.text == pending && doc.editor.revision == revision,
            "Ignore clears the notification and preserves a new edit during an automatic read")
        let inspected = DispatchSemaphore(value: 0)
        doc.externalFile.inspect = { url, baseline, known in
            inspected.signal()
            return DocumentMonitor.inspect(url, expected: baseline, known: known)
        }
        view.host.activate(view, focus: false)
        check(
            inspected.wait(timeout: .now() + 0.05) == .timedOut && doc.externalFile.notice == nil,
            "Ignore suppresses routine active-tab inspection")
        do {
            try doc.writeSafely(to: file, ofType: TextDocument.plainTextType, for: .saveOperation)
            check(false, "Ignore still refuses to replace newer disk bytes")
        } catch DocumentActionError.diskChanged {
            check(
                try Data(contentsOf: file) == Data([0x80, 0x33]) && doc.editor.text == pending && doc.isDocumentEdited,
                "Ignore retains independent save conflict, disk bytes and unsaved edits")
        }
        try select(.reloadIfUnmodified)
        _ = spinUntil("dirty automatic policy offers a decision") { view.statusText.contains("Changed on disk") }
        check(
            doc.editor.text == pending && doc.editor.revision == revision && doc.isDocumentEdited,
            "switching policy leaves a dirty buffer awaiting an explicit decision")
        try select(.ask)
        check(SettingsStore(url: settings).value.diskChangeBehavior == .ask, "reopening resolves the saved Ask choice")
    }
}
