// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore
import EditorBridge

@MainActor private final class CompareChoice: NSObject {
    weak var editor: TTEditor?
    weak var document: TextDocument?
    let id: DocumentID
    init(_ editor: TTEditor, _ id: DocumentID) {
        self.editor = editor
        self.document = EditorLifetime.document(for: editor)
        self.id = id
    }
}
@MainActor final class CompareSourcePicker: NSWindowController, CompareWindowScope, NSWindowDelegate {
    weak var service: CompareService?
    var onClose: (() -> Void)?
    let kind = NSPopUpButton(), original = NSPopUpButton(), modified = NSPopUpButton()
    private let fileA = NSButton(title: "Choose Original File…", target: nil, action: nil)
    private let fileB = NSButton(title: "Choose Modified File…", target: nil, action: nil)
    private let fileLabels = [
        NSTextField(wrappingLabelWithString: "No original file selected"),
        NSTextField(wrappingLabelWithString: "No modified file selected")
    ]
    private let start = NSButton(title: "Compare", target: nil, action: nil),
        cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let status = AnnouncingLabel(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var urls: [URL?] = [nil, nil]
    private var task: Task<Void, Never>?
    private var isClosed = false, busy = false
    private var filePanel: NSOpenPanel?
    var makeFilePanel: () -> NSOpenPanel = { NSOpenPanel() }
    private var sourceTimer: Timer?
    init(service: CompareService, preferred: TTEditor?) {
        self.service = service
        let panel = ToolPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520), styleMask: [.titled, .closable, .resizable])
        super.init(window: panel)
        panel.title = "Choose Comparison Sources"
        panel.delegate = self
        panel.listedInWindowMenu = true
        panel.contentMinSize = NSSize(width: 560, height: 480)
        panel.animationBehavior = .none
        kind.addItems(withTitles: [
            "Two Tabs", "Tab and Saved File", "Tab and Clipboard", "Selection and Clipboard", "Two Files"
        ])
        kind.target = self
        kind.action = #selector(changed(_:))
        kind.setAccessibilityLabel("Comparison source pair")
        var seen = Set<DocumentID>(), choices: [CompareChoice] = []
        if let preferred, let doc = EditorLifetime.document(for: preferred), doc.isOpen {
            choices.append(CompareChoice(preferred, doc.runtimeID))
            seen.insert(doc.runtimeID)
        }
        for editor in service.allEditors() {
            guard let doc = EditorLifetime.document(for: editor), doc.isOpen, seen.insert(doc.runtimeID).inserted else {
                continue
            }
            choices.append(CompareChoice(editor, doc.runtimeID))
        }
        for (popup, name) in [(original, "Original tab"), (modified, "Modified tab")] {
            popup.setAccessibilityLabel(name)
            popup.target = self
            popup.action = #selector(changed(_:))
            for choice in choices {
                let name = EditorLifetime.document(for: choice.editor!)?.displayName ?? "Untitled"
                popup.addItem(withTitle: name)
                popup.lastItem?.representedObject = choice
            }
        }
        if modified.numberOfItems > 1 { modified.selectItem(at: 1) }
        fileA.target = self
        fileA.action = #selector(chooseFile(_:))
        fileA.tag = 0
        fileB.target = self
        fileB.action = #selector(chooseFile(_:))
        fileB.tag = 1
        fileA.setAccessibilityLabel("Choose original comparison file")
        fileB.setAccessibilityLabel("Choose modified comparison file")
        start.target = self
        start.action = #selector(begin(_:))
        start.keyEquivalent = "\r"
        start.setAccessibilityLabel("Start read-only comparison")
        cancel.target = self
        cancel.action = #selector(cancel(_:))
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityLabel("Cancel choosing comparison sources")
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        let buttons = NSStackView(views: [spinner, NSView(), cancel, start])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Compare captured text without changing either source."), kind, original,
            modified, fileA, fileLabels[0], fileB, fileLabels[1], status, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            kind.widthAnchor.constraint(equalTo: stack.widthAnchor),
            original.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modified.widthAnchor.constraint(equalTo: stack.widthAnchor),
            start.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
        WindowFrames.track(panel, as: "TextTank.CompareSources")
        update()
        sourceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isClosed == false { self?.update() } }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func selected(_ popup: NSPopUpButton, selection: Bool = false) throws -> CompareInput {
        guard let choice = popup.selectedItem?.representedObject as? CompareChoice, let doc = choice.document,
            doc.isOpen, doc.runtimeID == choice.id
        else { throw ReviewRejection.closed }
        if selection {
            guard let editor = choice.editor, EditorLifetime.document(for: editor) === doc else {
                throw CompareOpenFailure.originClosed
            }
            return .document(try CompareDocumentInput(editor, selection: true))
        }
        return .document(try CompareDocumentInput(doc.editor))
    }
    @objc private func changed(_ sender: Any?) {
        if let popup = sender as? NSPopUpButton, popup === original || popup === modified,
            let choice = popup.selectedItem?.representedObject as? CompareChoice, let doc = choice.document, doc.isOpen
        {
            // A new explicit source choice may establish a new selection-view binding.
            choice.editor = doc.activeEditor
        }
        update()
    }
    private func update() {
        let type = kind.indexOfSelectedItem
        original.isHidden = type == 4
        modified.isHidden = type != 0
        fileA.isHidden = type != 4
        fileB.isHidden = type != 4
        fileLabels.forEach { $0.isHidden = type != 4 }
        var available = true, reason = ""
        if type == 4 {
            available = urls.allSatisfy { $0 != nil }
            reason = "Choose both files to compare."
        } else if original.indexOfSelectedItem < 0 {
            available = false
            reason = "Open a document before comparing this source pair."
        } else if type == 0 {
            let a = (original.selectedItem?.representedObject as? CompareChoice)?.id,
                b = (modified.selectedItem?.representedObject as? CompareChoice)?.id
            available =
                a != nil && b != nil && a != b
                && (original.selectedItem?.representedObject as? CompareChoice)?.document?.isOpen == true
                && (modified.selectedItem?.representedObject as? CompareChoice)?.document?.isOpen == true
            reason = "Choose two different documents."
        } else if let choice = original.selectedItem?.representedObject as? CompareChoice, let editor = choice.editor {
            let doc = choice.document
            if type == 1 {
                available = doc?.isOpen == true && doc?.fileURL != nil
                reason = "Save this document before comparing it with its file on disk."
            }
            if type == 3 {
                available =
                    doc?.isOpen == true && EditorLifetime.document(for: editor) === doc && editor.selectionCount == 1
                    && editor.selectionStart != editor.selectionEnd
                    && !editor.selectionIsRectangular
                reason = "Choose one nonempty text selection; multiple and rectangular selections cannot be compared."
            }
        } else {
            available = false
            reason = "This source has closed. Choose another document."
        }
        for popup in [original, modified] where !popup.isHidden {
            if let choice = popup.selectedItem?.representedObject as? CompareChoice, let editor = choice.editor,
                editor.byteLength > 8 * 1024 * 1024
            {
                available = false
                reason = "This text exceeds the 8 MiB comparison limit."
            }
        }
        start.isEnabled = !busy && available
        kind.isEnabled = !busy
        original.isEnabled = !busy
        modified.isEnabled = !busy
        fileA.isEnabled = !busy
        fileB.isEnabled = !busy
        if !busy { status.stringValue = available ? "Both sources will be captured when you choose Compare." : reason }
    }
    @objc private func chooseFile(_ sender: NSButton) {
        guard !busy, filePanel == nil, let window else { return }
        let panel = makeFilePanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = sender.tag == 0 ? "Choose the original text file." : "Choose the modified text file."
        filePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                self.filePanel = nil
                if response == .OK, let url = panel.url {
                    self.chooseFile(url, side: sender.tag)
                }
                self.update()
            }
        }
    }
    func chooseFile(_ url: URL, side: Int) {
        guard side == 0 || side == 1, !busy else { return }
        urls[side] = url
        fileLabels[side].stringValue = url.lastPathComponent
        fileLabels[side].toolTip = url.path
        update()
    }
    @objc private func begin(_ sender: Any?) {
        update()
        guard !busy, let service, start.isEnabled else { return }
        do {
            let a: CompareInput, b: CompareInput
            switch kind.indexOfSelectedItem {
            case 0:
                a = try selected(original)
                b = try selected(modified)
            case 1:
                a = try selected(original)
                guard case .document(let input) = a, let url = try input.capture.resolve().0.fileURL else {
                    throw ReviewRejection.closed
                }
                b = .file(url)
            case 2:
                a = try selected(original)
                b = .clipboard
            case 3:
                a = try selected(original, selection: true)
                b = .clipboard
            default:
                guard let x = urls[0], let y = urls[1] else { return }
                a = .file(x)
                b = .file(y)
            }
            busy = true
            update()
            status.stringValue = "Capturing comparison sources…"
            spinner.startAnimation(nil)
            task = Task { [weak self, weak service] in
                do {
                    guard let service else { return }
                    _ = try await service.open(original: a, modified: b)
                    guard let self, !self.isClosed else { return }
                    self.window?.close()
                } catch {
                    guard let self, !self.isClosed else { return }
                    self.busy = false
                    self.spinner.stopAnimation(nil)
                    self.update()
                    self.status.stringValue = CompareService.message(error)
                }
            }
        } catch { status.stringValue = CompareService.message(error) }
    }
    @objc private func cancel(_ sender: Any?) {
        task?.cancel()
        window?.close()
    }
    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        sourceTimer?.invalidate()
        sourceTimer = nil
        task?.cancel()
        filePanel?.cancel(nil)
        filePanel = nil
        onClose?()
    }
}
