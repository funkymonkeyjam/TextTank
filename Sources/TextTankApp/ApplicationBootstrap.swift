import AppKit
import TextTankCore

package enum TextTankApplication {
    @MainActor package static func run() {
        if CommandLine.arguments.dropFirst().first == "--smoke-test" {
            guard CommandLine.arguments.count == 3 else {
                smokeFailure("Expected --smoke-test FILE.")
            }
            let file = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
            let support: URL
            do { support = try AppStorage.makeTemporarySupportDirectory() }
            catch { smokeFailure(error.localizedDescription) }
            defer { try? FileManager.default.removeItem(at: support) }
            run(smokeFile: file) { error in smokeFailure(error.localizedDescription, cleanup: support) }
            return
        }
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
    static func smokeFailure(_ message: String, cleanup: URL? = nil) -> Never {
        if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
        FileHandle.standardError.write(Data(("TextTank bundle smoke failed: " + message + "\n").utf8))
        exit(EXIT_FAILURE)
    }
    @MainActor static func run(smokeFile: URL? = nil, onRecoveryFailure: (Error) -> Void) {
        do {
            try TextDocument.recovery.claimOwnership()
        } catch {
            onRecoveryFailure(error)
            return
        }
        // The first document controller created becomes the shared one, so this comes first.
        let documents = TextDocumentController()
        let app = NSApplication.shared
        app.setActivationPolicy(smokeFile == nil ? .regular : .prohibited)
        documents.recordsRecentDocuments = smokeFile == nil
        let delegate = AppDelegate()
        delegate.smokeFile = smokeFile
        app.delegate = delegate
        delegate.installEditorServices()
        if NSDocumentController.shared !== documents {
            NSLog("TextTank: the document controller was created early; encoding choice on open is unavailable")
        }
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

extension TextTankApplication {
    /// Explicit Shortcuts file input follows the same bounded local-text open path as the URL and tt tool.
    @MainActor package static func openSuppliedTextFile(_ url: URL) throws {
        guard url.isFileURL else { throw TextOpenRequest.invalidURL }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        _ = try TextOpenRequest(path: url.path, line: nil).open()
    }
}
