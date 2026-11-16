// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The existing advanced JSON editors share a draft loop, not storage or execution.
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
    }
    private enum Action { case save, cancel, importFile, exportFile, extra }

    /// File choices are injectable per invocation. A cancelled choice never changes the draft,
    /// and imported or example values only reach storage through the explicit Save closure.
    static func edit<Library: VersionedLibrary>(
        _ initial: Library, configuration: Configuration, panels: FilePanels = .standard,
        read: (URL) throws -> Data, extraAction: ((Library) throws -> Library)? = nil,
        save: (Library) throws -> Void
    ) throws {
        let alert = TTAlert()
        alert.messageText = configuration.title
        alert.informativeText = configuration.information
        var actions: [Action] = [.save, .cancel, .importFile, .exportFile]
        for (title, suffix, role) in [
            ("Save", "save", TTAlert.ButtonRole.action), ("Cancel", "cancel", .cancel),
            ("Import…", "import", .action), ("Export…", "export", .action)
        ] {
            alert.addButton(withTitle: title, role: role).identifier = NSUserInterfaceItemIdentifier(
                configuration.identifier + "." + suffix)
        }
        if let title = configuration.extraTitle, let identifier = configuration.extraIdentifier,
            extraAction != nil
        {
            alert.addButton(withTitle: title).identifier = NSUserInterfaceItemIdentifier(identifier)
            actions.append(.extra)
        }
        let text = makeTextView(size: configuration.size)
        text.editor.setAccessibilityLabel(configuration.accessibilityLabel)
        text.editor.identifier = NSUserInterfaceItemIdentifier(configuration.identifier + ".text")
        text.editor.string = String(decoding: try initial.encoded(), as: UTF8.self)
        if let reference = configuration.reference {
            let help = makeTextView(size: NSSize(width: configuration.size.width, height: reference.height))
            help.editor.isEditable = false
            help.editor.string = reference.text
            help.editor.setAccessibilityLabel(reference.accessibilityLabel)
            let body = NSStackView(views: [help.scroll, text.scroll])
            body.orientation = .vertical
            body.alignment = .leading
            body.spacing = 8
            body.frame = NSRect(
                origin: .zero,
                size: NSSize(width: configuration.size.width, height: configuration.size.height + reference.height + 8))
            NSLayoutConstraint.activate([
                help.scroll.heightAnchor.constraint(equalToConstant: reference.height),
                text.scroll.heightAnchor.constraint(equalToConstant: configuration.size.height),
                help.scroll.widthAnchor.constraint(equalTo: body.widthAnchor),
                text.scroll.widthAnchor.constraint(equalTo: body.widthAnchor)
            ])
            alert.accessoryView = body
        } else {
            alert.accessoryView = text.scroll
        }
        alert.window.initialFirstResponder = text.editor
        while let action = alert.choice(actions), action != .cancel {
            do {
                switch action {
                case .cancel: return
                case .importFile:
                    guard let url = panels.importURL() else { continue }
                    let imported = try Library.decode(read(url))
                    text.editor.string = String(decoding: try imported.encoded(), as: UTF8.self)
                    alert.clearValidation()
                case .exportFile:
                    let proposed = try Library.decode(Data(text.editor.string.utf8))
                    let data = try proposed.encoded()
                    guard let url = panels.exportURL(configuration.exportName) else { continue }
                    try data.write(to: url, options: .atomic)
                    alert.clearValidation()
                case .extra:
                    guard let extraAction else { continue }
                    let proposed = try extraAction(Library.decode(Data(text.editor.string.utf8)))
                    text.editor.string = String(decoding: try proposed.encoded(), as: UTF8.self)
                    alert.clearValidation()
                case .save:
                    let proposed = try Library.decode(Data(text.editor.string.utf8))
                    try save(proposed)
                    return
                }
            } catch {
                // Preserve real NSError recovery when one exists, while ordinary validation
                // stays beside the draft instead of opening a nested error-management loop.
                if (error as NSError).recoveryAttempter != nil {
                    TTAlert.present(error)
                } else {
                    alert.showValidation(error, field: text.editor)
                }
            }
        }
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
