import AppKit

package enum TextTankApplication {
    @MainActor package static func run() {
        run { error in
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            // No document window exists at this startup boundary.
            app.activate(ignoringOtherApps: true)
            TTAlert.explain(
                "This copy of TextTank must quit because it cannot open its recovery folder.",
                detail: error.localizedDescription)
        }
    }
    @MainActor static func run(onRecoveryFailure: (Error) -> Void) {
        do {
            try TextDocument.recovery.claimOwnership()
        } catch {
            onRecoveryFailure(error)
            return
        }
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
