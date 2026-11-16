import AppKit

@MainActor enum Audit29ServiceChecks {
    static func run() throws {
        let previousServices = EditorServices.current, previousDelegate = NSApp.delegate
        defer {
            EditorServices.current = previousServices
            NSApp.delegate = previousDelegate
        }
        NSApp.delegate = nil
        EditorServices.current = nil
        let settings = SettingsController(
            url: AppStorage.supportDirectory.appendingPathComponent("audit29-settings.json"))
        var value = settings.value
        value.tabWidth = 7
        try settings.save(value)
        var reads = 0
        var services = EditorServices()
        services.settingsProvider = {
            reads += 1
            return settings
        }
        EditorServices.current = services
        check(reads == 0, "F276 installing and reading services leaves feature providers lazy")
        _ = EditorServices.current
        check(reads == 0, "F276 environment lookup does not eagerly resolve a feature")
        let document = TextDocument()
        document.makeWindowControllers()
        defer { document.close() }
        check(
            document.editor.statusInfo.tabWidth == 7,
            "F276 document windows use installed settings even when the application delegate is nil")
        check(reads > 0, "F276 the window resolves its settings provider at the existing apply boundary")
        let controller = try requireValue(
            document.windowControllers.first as? EditorWindowController,
            "F276 fixture: document window controller")
        controller.findField.stringValue = "missing provider"
        controller.findNext(nil)
        check(
            !controller.inlineSearchPending,
            "F276 an absent search provider remains a no-op rather than leaving an inline action busy")
        let shared = NSDocumentController.shared
        let composition = AppDelegate()
        composition.installEditorServices()
        check(
            NSDocumentController.shared === shared && NSApp.delegate == nil,
            "F276 installing features preserves the document controller and does not replace NSApplication.delegate")
        check(
            EditorServices.current?.settings === composition.settings,
            "F276 the installed settings provider preserves actual controller identity")
        EditorServices.current?.noteActiveController(controller)
        check(
            composition.currentDocumentController === controller,
            "F276 explicit focus notification preserves the composition root current document")
        var available = true
        services.isAvailable = { available }
        EditorServices.current = services
        let priorReads = reads
        available = false
        check(
            EditorServices.current == nil && reads == priorReads,
            "F276 unavailable service owners resolve nil without touching feature providers")
        let plain = TextDocument()
        plain.makeWindowControllers()
        defer { plain.close() }
        check(
            plain.editor.statusInfo.tabWidth == 4 && plain.editor.menu == nil,
            "F276 nil services keep unconfigured document windows usable without implicit feature resolution")

    }
}
