import AppKit
import TextTankCore

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
        let freshProfile = isNewProfile(at: AppStorage.supportDirectory)
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
        delegate.firstLaunchProfile = freshProfile
        app.delegate = delegate
        delegate.installEditorServices()
        if NSDocumentController.shared !== documents {
            NSLog("TextTank: the document controller was created early; encoding choice on open is unavailable")
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }

    static func isNewProfile(at directory: URL) -> Bool {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
        } catch let error as CocoaError {
            return error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        } catch { return false }
    }
}
