// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class UtilityController: NSObject {
    let activeEditor: () -> TTEditor?
    /// Called immediately before a utility changes the document, and at no other time: asking
    /// for the editor, a cancelled dialog, a failed guard and an export leave a macro recording alone.
    var onUnrecordableEdit: () -> Void = {}
    init(activeEditor: @escaping () -> TTEditor?) { self.activeEditor = activeEditor }
    func makeMenu() -> NSMenu {
        precondition(Thread.isMainThread)
        let menu = NSMenu(title: "Text Utilities")
        for utility in TextUtility.allCases {
            let item = NSMenuItem(title: utility.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = utility.rawValue
            menu.addItem(item)
        }
        let hex = NSMenuItem(title: "UTF-8 to Hex with Options…", action: #selector(hexOptions(_:)), keyEquivalent: "")
        hex.target = self
        menu.addItem(hex)
        let conversion = NSMenuItem(
            title: "Number Conversion…", action: #selector(convertNumber(_:)), keyEquivalent: "")
        conversion.target = self
        menu.addItem(conversion)
        menu.addItem(.separator())
        for format in ["html", "rtf"] {
            for destination in ["clipboard", "file"] {
                let label = destination == "clipboard" ? "Copy" : "Export"
                let item = NSMenuItem(
                    title: "\(label) Styled Text as \(format.uppercased())" + (destination == "file" ? "…" : ""),
                    action: #selector(exportStyled(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["format": format, "destination": destination]
                menu.addItem(item)
            }
        }
        return menu
    }
    @objc private func run(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let utility = TextUtility(rawValue: raw) else { return }
        do { try apply(utility) } catch { NSAlert(error: error).runModal() }
    }
    /// The editor a utility may change, or the first precondition that fails, in a fixed order
    /// that names the cause the person can least see first: no document, read-only (the shared
    /// requireWritable error), several selections, then an empty selection.
    func editableEditor(requireNonEmpty: Bool) throws -> TTEditor {
        guard let editor = activeEditor(), editor.window != nil else { throw UtilityFailure.noDocument }
        try editor.requireWritable()
        guard editor.selectionCount == 1 else { throw UtilityFailure.multipleSelections }
        guard !requireNonEmpty || editor.selectionStart != editor.selectionEnd else {
            throw UtilityFailure.selectionRequired
        }
        return editor
    }
    /// Recheck after a dialog: `editor` must still be the captured editor in the captured state.
    /// Reports what actually changed rather than asking for a selection.
    static func recheck(
        _ editor: TTEditor?, captured: TTEditor?, revision: UInt?, selection: [[String: NSNumber]]?
    ) throws -> TTEditor {
        guard let editor, editor.window != nil else { throw UtilityFailure.noDocument }
        try editor.requireWritable()
        guard editor === captured, editor.revision == revision, editor.selectionRanges == selection else {
            throw UtilityFailure.documentChanged
        }
        guard editor.selectionCount == 1 else { throw UtilityFailure.multipleSelections }
        return editor
    }
    @objc private func hexOptions(_ sender: Any?) {
        let editor: TTEditor
        do { editor = try editableEditor(requireNonEmpty: true) } catch {
            NSAlert(error: error).runModal()
            return
        }
        let revision = editor.revision
        let selection = editor.selectionRanges
        let input = editor.selectedText
        let alert = TTAlert()
        alert.messageText = "Hex Encoding Options"
        let spaces = NSButton(checkboxWithTitle: "Spaces between bytes", target: nil, action: nil)
        let uppercase = NSButton(checkboxWithTitle: "Uppercase hexadecimal", target: nil, action: nil)
        uppercase.state = .on
        let width = NSTextField(string: "16")
        let eol = NSPopUpButton()
        eol.addItems(withTitles: ["LF", "CRLF", "CR"])
        let stack = NSStackView(views: [
            spaces, uppercase, NSTextField(labelWithString: "Bytes per line (0 = no wrapping)"), width, eol
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 160)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try Self.recheck(editor, captured: editor, revision: revision, selection: selection)
            let output = try HexEncodingOptions(
                insertSpaces: spaces.state == .on, uppercase: uppercase.state == .on,
                bytesPerLine: Int(width.stringValue) ?? -1, lineEnding: ["\n", "\r\n", "\r"][eol.indexOfSelectedItem]
            ).encode(input)
            onUnrecordableEdit()
            editor.beginUndoGroup()
            editor.replaceSelection(output)
            editor.endUndoGroup()
        } catch { NSAlert(error: error).runModal() }
    }
    @objc private func convertNumber(_ sender: Any?) {
        let alert = TTAlert()
        alert.messageText = "Number Conversion"
        alert.informativeText = "Convert an unsigned 32-bit number. Conversion does not change your document."
        let captured = activeEditor()
        let revision = captured?.revision
        let selection = captured?.selectionRanges
        let input = NSTextField(string: captured?.selectedText ?? "")
        let from = NSPopUpButton()
        let to = NSPopUpButton()
        for field in [from, to] {
            field.addItems(withTitles: ["Binary (2)", "Octal (8)", "Decimal (10)", "Hexadecimal (16)"])
        }
        from.selectItem(at: 2)
        to.selectItem(at: 3)
        let stack = NSStackView(views: [
            input, NSTextField(labelWithString: "From"), from, NSTextField(labelWithString: "To"), to
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 350, height: 160)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let bases = [2, 8, 10, 16]
            let output = try RadixConversion.convert(
                input.stringValue, from: bases[from.indexOfSelectedItem], to: bases[to.indexOfSelectedItem])
            let result = TTAlert()
            result.messageText = "Converted Number"
            result.informativeText = output
            result.addButton(withTitle: "Copy")
            result.addButton(withTitle: "Cancel")
            result.addButton(withTitle: "Insert into Editor")
            let action = result.runModal()
            if action == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
            } else if action == .alertThirdButtonReturn {
                // An empty single selection is allowed here: the result is inserted at the caret.
                let editor = try Self.recheck(
                    activeEditor(), captured: captured, revision: revision, selection: selection)
                onUnrecordableEdit()
                editor.beginUndoGroup()
                editor.replaceSelection(output)
                editor.endUndoGroup()
            }
        } catch { NSAlert(error: error).runModal() }
    }
    /// Snapshot only: Scintilla remains authoritative. An ordinary nonempty
    /// selection is exported; no selection exports the complete document.
    func exportData(format: String) throws -> (Data, String) {
        precondition(Thread.isMainThread)
        guard let editor = activeEditor(), editor.window != nil else { throw UtilityFailure.noDocument }
        guard editor.selectionCount == 1 else { throw UtilityFailure.multipleSelections }
        let selected = editor.selectionStart != editor.selectionEnd
        let bytes = selected ? editor.selectionEnd - editor.selectionStart : editor.byteLength
        guard bytes <= 16 * 1024 * 1024 else { throw UtilityFailure.tooLarge }
        let snapshot = editor.attributedText(forSelection: selected)
        guard format == "html" || format == "rtf" else { throw UtilityFailure.malformed("export format") }
        let type: NSAttributedString.DocumentType = format == "html" ? .html : .rtf
        let data = try snapshot.data(
            from: NSRange(location: 0, length: snapshot.length),
            documentAttributes: [.documentType: type, .characterEncoding: String.Encoding.utf8.rawValue])
        return (data, snapshot.string)
    }
    @objc private func exportStyled(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? [String: String], let format = choice["format"] else { return }
        do {
            let (data, plain) = try exportData(format: format)
            if choice["destination"] == "clipboard" {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(data, forType: format == "html" ? .html : .rtf)
                pasteboard.setString(plain, forType: .string)
            } else {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "TextTank-export." + format
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
            }
        } catch { NSAlert(error: error).runModal() }
    }
    func apply(_ utility: TextUtility) throws {
        precondition(Thread.isMainThread)
        let editor = try editableEditor(requireNonEmpty: true)
        let transformed = try utility.apply(editor.selectedText)
        onUnrecordableEdit()
        editor.beginUndoGroup()
        defer { editor.endUndoGroup() }
        editor.replaceSelection(transformed)
    }
}
