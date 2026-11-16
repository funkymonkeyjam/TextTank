// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The existing advanced JSON editors share a working-copy editor, not storage or execution.
/// Controllers retain their own recovery, busy state, persistence and post-save effects.
enum JSONLibraryEditor {
    struct FilePanels {
        var importURL: () -> URL?
        var exportURL: (String) -> URL?
        static var standard: Self {
            Self(
                importURL: {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    return panel.runModal() == .OK ? panel.url : nil
                },
                exportURL: { name in
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = name
                    return panel.runModal() == .OK ? panel.url : nil
                })
        }
    }
    struct Reference {
        let text: String
        let accessibilityLabel: String
        let height: CGFloat
    }
    struct Configuration {
        let title: String
        let information: String
        let accessibilityLabel: String
        let exportName: String
        let identifier: String
        let size: NSSize
        var reference: Reference?
        var extraTitle: String?
        var extraIdentifier: String?
        var saveTitle = "Save"
    }
    private enum Action { case save, cancel, importFile, exportFile, extra }

    /// File choices are injectable per invocation. A cancelled choice never changes the draft,
    /// and imported or example values only reach storage through the explicit Save closure.
    @discardableResult static func edit<Library: VersionedLibrary>(
        _ initial: Library, configuration: Configuration, panels: FilePanels = .standard,
        parent: NSWindow? = nil, current: (() throws -> Library)? = nil,
        read: @escaping (URL) throws -> Data, extraAction: ((Library) throws -> Library)? = nil,
        save: @escaping (Library) throws -> Void
    ) throws -> FormPanel {
        let baseline = try SavedConfiguration.bytes(initial)
        let initialText = String(decoding: try initial.encoded(), as: UTF8.self)
        let form = FormPanel(
            title: configuration.title, identifier: configuration.identifier,
            size: NSSize(
                width: configuration.size.width + 40,
                height: configuration.size.height + (configuration.reference?.height ?? 0) + 180))
        form.window.contentMinSize = NSSize(width: 600, height: 400)
        form.note(configuration.information)
        let text = makeTextView(size: configuration.size)
        text.editor.setAccessibilityLabel(configuration.accessibilityLabel)
        text.editor.identifier = NSUserInterfaceItemIdentifier(configuration.identifier + ".text")
        text.editor.string = initialText
        if let reference = configuration.reference {
            let help = makeTextView(size: NSSize(width: configuration.size.width, height: reference.height))
            help.editor.isEditable = false
            help.editor.string = reference.text
            help.editor.setAccessibilityLabel(reference.accessibilityLabel)
            form.add(help.scroll)
            help.scroll.heightAnchor.constraint(equalToConstant: reference.height).isActive = true
        }
        form.add(text.scroll)
        text.scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        func perform(_ action: Action) {
            do {
                switch action {
                case .cancel: form.close()
                case .importFile:
                    guard let url = panels.importURL() else { return }
                    let imported = try Library.decode(read(url))
                    text.editor.string = String(decoding: try imported.encoded(), as: UTF8.self)
                    form.clearValidation()
                case .exportFile:
                    let proposed = try Library.decode(Data(text.editor.string.utf8))
                    let data = try proposed.encoded()
                    guard let url = panels.exportURL(configuration.exportName) else { return }
                    try data.write(to: url, options: .atomic)
                    form.clearValidation()
                case .extra:
                    guard let extraAction else { return }
                    let proposed = try extraAction(Library.decode(Data(text.editor.string.utf8)))
                    text.editor.string = String(decoding: try proposed.encoded(), as: UTF8.self)
                    form.clearValidation()
                case .save:
                    guard form.commitEditing() else { return }
                    let proposed = try Library.decode(Data(text.editor.string.utf8))
                    if let current { try SavedConfiguration.requireUnchanged(try current(), since: baseline) }
                    try save(proposed)
                    form.close()
                }
            } catch { form.showValidation(error, field: text.editor) }
        }
        form.button(configuration.saveTitle, identifier: configuration.identifier + ".save") { perform(.save) }
            .keyEquivalent = "\r"
        form.button("Cancel", identifier: configuration.identifier + ".cancel", cancel: true) { perform(.cancel) }
        form.button("Import…", identifier: configuration.identifier + ".import") { perform(.importFile) }
        form.button("Export…", identifier: configuration.identifier + ".export") { perform(.exportFile) }
        if let title = configuration.extraTitle, let identifier = configuration.extraIdentifier, extraAction != nil {
            form.button(title, identifier: identifier) { perform(.extra) }
        }
        form.window.initialFirstResponder = text.editor
        form.show(parent: parent)
        return form
    }

    static func makeTextView(size: NSSize) -> (scroll: NSScrollView, editor: NSTextView) {
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.autoresizingMask = [.width]
        editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        return (scroll, editor)
    }
}
