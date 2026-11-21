import TextTankCore
import EditorBridge
import NativeSearch
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor final class UtilityController: NSObject {
    private let editorProvider: () -> TTEditor?
    var activeEditor: () -> TTEditor? { editorProvider }
    /// Called immediately before a utility changes the document, and at no other time: asking
    /// for the editor, a cancelled dialog, a failed guard and an export leave a macro recording alone.
    var onUnrecordableEdit: () -> Void = {}
    init(activeEditor: @escaping () -> TTEditor?) { self.editorProvider = activeEditor }
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
        do { try apply(utility) } catch { TTAlert.present(error) }
    }
    /// The editor a utility may change, or the first precondition that fails, in a fixed order
    /// that names the cause the person can least see first: no document, read-only (the shared
    /// requireWritable error), several selections, then an empty selection.
    func editableEditor(requireNonEmpty: Bool) throws -> TTEditor {
        guard let editor = editorProvider(), EditorLifetime.isOpen(editor) else { throw UtilityFailure.noDocument }
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
        _ editor: TTEditor?, captured: TTEditor?, revision: UInt?, selection: [TTSelectionRange]?
    ) throws -> TTEditor {
        guard let editor, EditorLifetime.isOpen(editor) else { throw UtilityFailure.noDocument }
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
            TTAlert.present(error)
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
        NumericInput.configure(width)
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
        alert.addButton(withTitle: "Cancel", role: .cancel)
        width.setAccessibilityLabel("Hexadecimal bytes per line")
        eol.setAccessibilityLabel("Hexadecimal line endings")
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                _ = try Self.recheck(editor, captured: editor, revision: revision, selection: selection)
                guard let bytesPerLine = NumericInput.integer(width),
                    (0...65536).contains(bytesPerLine)
                else {
                    throw UtilityFailure.malformed("bytes per line; enter a whole number from 0 to 65536")
                }
                let output = try HexEncodingOptions(
                    insertSpaces: spaces.state == .on, uppercase: uppercase.state == .on,
                    bytesPerLine: bytesPerLine, lineEnding: ["\n", "\r\n", "\r"][eol.indexOfSelectedItem]
                ).encode(input)
                onUnrecordableEdit()
                editor.beginUndoGroup()
                editor.replaceSelection(output)
                editor.endUndoGroup()
                return
            } catch {
                if case UtilityFailure.malformed = error {
                    alert.showValidation(error, field: width)
                } else {
                    alert.showValidation(error)
                }
            }
        }
    }
    static let numberConversionNote =
        "Convert an unsigned 32-bit number. Your document changes only if you then choose Insert into Editor."
    @objc private func convertNumber(_ sender: Any?) {
        let alert = TTAlert()
        alert.messageText = "Number Conversion"
        alert.informativeText = Self.numberConversionNote
        let captured = editorProvider()
        let revision = captured?.revision
        let selection = captured?.selectionRanges
        let input = NSTextField(
            string: (captured?.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        let from = NSPopUpButton()
        let to = NSPopUpButton()
        for field in [from, to] {
            field.addItems(withTitles: ["Binary (2)", "Octal (8)", "Decimal (10)", "Hexadecimal (16)"])
        }
        input.setAccessibilityLabel("Number to convert")
        from.setAccessibilityLabel("Source number base")
        to.setAccessibilityLabel("Destination number base")
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
        alert.addButton(withTitle: "Cancel", role: .cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let bases = [2, 8, 10, 16]
            let output = try RadixConversion.convert(
                input.stringValue, from: bases[from.indexOfSelectedItem], to: bases[to.indexOfSelectedItem])
            let result = TTAlert()
            result.messageText = "Converted Number"
            result.informativeText = output
            result.addButton(withTitle: "Copy")
            result.addButton(withTitle: "Done", role: .cancel)
            result.addButton(withTitle: "Insert into Editor")
            let action = result.runModal()
            if action == .alertFirstButtonReturn {
                try copyConvertedNumber(output)
            } else if action == .alertThirdButtonReturn {
                // An empty single selection is allowed here: the result is inserted at the caret.
                let editor = try Self.recheck(
                    editorProvider(), captured: captured, revision: revision, selection: selection)
                onUnrecordableEdit()
                editor.beginUndoGroup()
                editor.replaceSelection(output)
                editor.endUndoGroup()
            }
        } catch { TTAlert.present(error) }
    }
    /// Snapshot only: Scintilla remains authoritative. An ordinary nonempty
    /// selection is exported; no selection exports the complete document.
    func exportData(format: String) throws -> (Data, String) {
        precondition(Thread.isMainThread)
        guard let editor = editorProvider(), EditorLifetime.isOpen(editor) else { throw UtilityFailure.noDocument }
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
    private func clipboardForExplicitAction() throws -> NSPasteboard {
        guard let board = RuntimeEnvironment.current.generalPasteboard() else {
            throw CocoaError(
                .featureUnsupported,
                userInfo: [
                    NSLocalizedDescriptionKey: "Clipboard access is unavailable in this isolated session."
                ])
        }
        return board
    }
    func copyConvertedNumber(_ output: String) throws {
        let board = try clipboardForExplicitAction()
        board.clearContents()
        board.setString(output, forType: .string)
    }
    func copyStyledToClipboard(format: String) throws {
        let (data, plain) = try exportData(format: format)
        let board = try clipboardForExplicitAction()
        board.clearContents()
        board.setData(data, forType: format == "html" ? .html : .rtf)
        board.setString(plain, forType: .string)
    }
    @objc private func exportStyled(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? [String: String], let format = choice["format"] else { return }
        do {
            if choice["destination"] == "clipboard" {
                try copyStyledToClipboard(format: format)
            } else {
                let (data, _) = try exportData(format: format)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "TextTank-export." + format
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
            }
        } catch { TTAlert.present(error) }
    }
    func apply(_ utility: TextUtility) throws {
        precondition(Thread.isMainThread)
        if utility == .inspectUnicode || utility == .validateJSON {
            guard let editor = editorProvider(), EditorLifetime.isOpen(editor), let parent = editor.window else {
                throw UtilityFailure.noDocument
            }
            guard editor.selectionCount == 1 else { throw UtilityFailure.multipleSelections }
            guard editor.selectionStart != editor.selectionEnd else { throw UtilityFailure.selectionRequired }
            guard editor.selectionEnd - editor.selectionStart <= 16 * 1024 * 1024 else { throw UtilityFailure.tooLarge }
            let report = TTAlert()
            report.messageText = utility.title
            let result = try utility.apply(editor.selectedText)
            if utility == .inspectUnicode {
                let scroll = NSTextView.scrollableTextView()
                scroll.frame = NSRect(x: 0, y: 0, width: 480, height: 230)
                if let text = scroll.documentView as? NSTextView {
                    text.string = result
                    text.isEditable = false
                    text.setAccessibilityLabel("Unicode scalars and UTF-8 offsets")
                }
                report.accessoryView = scroll
            } else {
                report.informativeText = result
            }
            report.addButton(withTitle: "Done")
            report.beginSheetModal(for: parent)
            return
        }
        let editor = try editableEditor(requireNonEmpty: true)
        guard editor.selectionEnd - editor.selectionStart <= 16 * 1024 * 1024 else { throw UtilityFailure.tooLarge }
        let input = editor.selectedText
        let transformed = try utility.apply(input)
        if utility == .formatJSON && transformed.utf8.elementsEqual(input.utf8) { return }
        let capture = BulkChangeCapture(editor, name: utility.title)
        onUnrecordableEdit()
        editor.beginUndoGroup()
        editor.replaceSelection(transformed)
        editor.endUndoGroup()
        capture?.finish()
    }
}
