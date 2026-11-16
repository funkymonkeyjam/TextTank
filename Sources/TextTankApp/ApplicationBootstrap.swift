import AppKit

package enum TextTankApplication {
    @MainActor package static func run() {
        // The first document controller created becomes the shared one, so this comes first.
        let documents = TextDocumentController()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        delegate.installEditorServices()
        if NSDocumentController.shared !== documents {
            NSLog("TextTank: the document controller was created early; encoding choice on open is unavailable")
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
