// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CryptoKit
import Darwin
import EditorBridge
import MachO
@testable import TextTankCore
@testable import TextTankRuntime

/// This process runs the product bootstrap and its normal AppKit event loop. The child cannot take desktop focus.
@objc(RecoveryCrashFixtureApplication) final class RecoveryFixtureApplication: NSApplication {
    override func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        super.setActivationPolicy(.prohibited)
    }
}

@MainActor final class RecoveryCrashDriver {
    let mode: String
    let folder: URL
    let token: String
    var asked = false
    var opened: TextDocument?
    var opening = false
    var started = false
    var receiptSent = false
    init(_ mode: String, _ folder: URL, _ token: String) {
        self.mode = mode
        self.folder = folder
        self.token = token
    }
    var file: URL { folder.appendingPathComponent("original.txt") }
    var support: URL { folder.appendingPathComponent("support") }
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
    func receipt(_ phase: String, _ extra: [String: Any] = [:]) {
        var value = extra
        value["pid"] = getpid()
        value["executable"] = CommandLine.arguments[0]
        value["token"] = token
        value["root"] = AppStorage.supportDirectory.resolvingSymlinksInPath().path
        value["phase"] = phase
        value["uptime"] = ProcessInfo.processInfo.systemUptime
        value["prohibited"] = NSApp.activationPolicy() == .prohibited && !NSApp.isActive
        let images = (0..<_dyld_image_count()).compactMap { i -> String? in
            guard let p = _dyld_get_image_name(i) else { return nil }
            let path = String(cString: p)
            return ["EditorBridge", "Scintilla", "NativeSearch", "TextTankRuntime", "TextTankCore"].contains(
                URL(fileURLWithPath: path).lastPathComponent) ? path : nil
        }
        value["images"] = images
        do {
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try bytes.write(to: folder.appendingPathComponent(mode + "-" + phase + ".json"), options: .atomic)
        } catch { fail("fixture receipt write failed") }
    }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func start() {
        guard let delegate = NSApp.delegate as? AppDelegate,
            let controller = NSDocumentController.shared as? TextDocumentController,
            NSApp.activationPolicy() == .prohibited, !NSApp.isActive,
            AppStorage.supportDirectory.resolvingSymlinksInPath().path == support.resolvingSymlinksInPath().path
        else { fail("unexpected activation, document controller or support root") }
        controller.recordsRecentDocuments = false
        started = true
        receipt("ready")
        // The app normally receives this lifecycle callback when its first editor is brought
        // forward. Deliver it locally because the test child is prohibited from taking focus.
        delegate.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification, object: NSApp))
    }
    func tick() {
        guard started, !receiptSent else { return }
        if let modal = NSApp.modalWindow, let contents = modal.contentView {
            let buttons = descendants(contents).compactMap { $0 as? NSButton }
            guard buttons.contains(where: { $0.title == "Discard…" }), !asked,
                let decision = buttons.first(where: { $0.title == (mode == "recover" ? "Recover" : "Later") }),
                mode == "recover" || mode == "later"
            else { fail("unexpected startup alert: " + buttons.map(\.title).joined(separator: ", ")) }
            asked = true
            receipt("review", ["button": decision.title])
            decision.performClick(nil)
            return
        }
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }
        switch mode {
        case "early", "edit":
            if let doc = opened {
                guard doc.currentSaveStateStatus.contains("recovery copy kept") else { return }
                receiptSent = true
                receipt(
                    "published",
                    [
                        "id": doc.recoveryID.uuidString, "dirty": doc.isDocumentEdited,
                        "digest": digest(doc.editor.checkedUTF8Data)
                    ])
                return
            }
            guard !opening && !documents.isEmpty else { return }
            opening = true
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { object, _, error in
                MainActor.assumeIsolated {
                    guard let doc = object as? TextDocument, error == nil, doc.fileURL == self.file,
                        let view = doc.presentation,
                        let input = self.descendants(view.primaryEditor).compactMap({ $0 as? NSTextInputClient }).first,
                        doc.editor.setSelectionAnchor(doc.editor.byteLength, caret: doc.editor.byteLength)
                    else {
                        self.fail("ordinary file open failed: " + (error?.localizedDescription ?? "editor unavailable"))
                    }
                    input.insertText("  Δ🧪\u{0000}tail", replacementRange: NSRange(location: NSNotFound, length: 0))
                    guard doc.isDocumentEdited else { self.fail("native input did not dirty the document") }
                    if self.mode == "early" {
                        self.receipt(
                            "unpublished",
                            [
                                "id": doc.recoveryID.uuidString, "dirty": doc.isDocumentEdited,
                                "digest": self.digest(doc.editor.checkedUTF8Data)
                            ])
                        // This test-only child is stopped inside the editing callback. Its main-thread recovery
                        // timer cannot fire while the parent verifies the absence of a snapshot and kills it.
                        DispatchSemaphore(value: 0).wait()
                    }
                    self.opened = doc
                    self.receipt(
                        "edited", ["digest": self.digest(doc.editor.checkedUTF8Data), "id": doc.recoveryID.uuidString])
                }
            }
        case "empty", "later":
            if asked == (mode == "later") && !documents.isEmpty {
                guard documents.allSatisfy({ $0.recoveredOrigin == nil && !$0.isDocumentEdited }) else {
                    fail("Later opened a dirty recovered buffer")
                }
                receiptSent = true
                receipt(mode == "later" ? "kept" : "empty", ["reviewed": asked])
                NSApp.terminate(nil)
            }
        case "recover":
            guard asked, let recovered = documents.first(where: { $0.recoveredOrigin != nil }) else { return }
            let expected = try? Data(contentsOf: file)
            guard let original = expected, recovered.fileURL == nil, recovered.isDocumentEdited,
                recovered.displayName == "Recovered " + file.lastPathComponent,
                recovered.editor.checkedUTF8Data == original + Data("  Δ🧪\u{0000}tail".utf8)
            else { fail("restored draft, identity or original file mismatch") }
            receiptSent = true
            receipt(
                "restored",
                [
                    "digest": digest(recovered.editor.checkedUTF8Data), "dirty": true, "untitled": true,
                    "id": recovered.recoveryID.uuidString
                ])
            // This document belongs solely to this fixture and has already passed byte verification.
            recovered.close()
            NSApp.terminate(nil)
        default: fail("unknown mode")
        }
    }
    func digest(_ data: Data?) -> String {
        guard let data else { fail("native byte capture failed") }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@main enum RecoveryCrashAppChecks {
    @MainActor static func main() {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["TEXTTANK_CRASH_CHECK_PHASE"],
            ["early", "empty", "edit", "later", "recover"].contains(phase),
            let folder = environment["TEXTTANK_CRASH_CHECK_DIRECTORY"],
            let token = environment["TEXTTANK_CRASH_CHECK_TOKEN"],
            UUID(uuidString: token) != nil
        else { exit(2) }
        let driver = RecoveryCrashDriver(phase, URL(fileURLWithPath: folder, isDirectory: true), token)
        let root = driver.folder.resolvingSymlinksInPath()
        let ownedSupport = driver.support.resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // Fail before the production bootstrap can claim a recovery lease or scan any storage.
        guard let suppliedSupport = environment["TEXTTANK_SUPPORT_DIRECTORY"],
            root.deletingLastPathComponent().path == temporary.path,
            root.lastPathComponent.hasPrefix("TextTank-crash-"),
            URL(fileURLWithPath: suppliedSupport).resolvingSymlinksInPath().path == ownedSupport.path,
            executable.deletingLastPathComponent().path == root.path,
            executable.lastPathComponent == "TextTankCrashFixture-" + token,
            (try? String(contentsOf: root.appendingPathComponent("owner-token"), encoding: .utf8)) == token,
            !AppStorage.permitsLegacyDefaults,
            AppStorage.supportDirectory.resolvingSymlinksInPath().path == ownedSupport.path
        else { driver.fail("private process, nonce or isolated recovery root missing") }
        let app = RecoveryFixtureApplication.shared
        _ = app.setActivationPolicy(.prohibited)
        guard app is RecoveryFixtureApplication, app.activationPolicy() == .prohibited else {
            driver.fail(
                "private application class or activation policy unavailable: " + NSStringFromClass(type(of: app))
                    + " policy " + String(app.activationPolicy().rawValue))
        }
        LanguageController.bundledCatalogURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TEXTTANK_REPO_ROOT"]!
        ).appendingPathComponent("Resources/LanguageProfiles.json")
        let observation = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: nil
        ) { _ in
            DispatchQueue.main.async { driver.start() }
        }
        let timer = Timer(timeInterval: 0.025, repeats: true) { _ in MainActor.assumeIsolated { driver.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        TextTankApplication.run()
        withExtendedLifetime((driver, observation, timer)) {}
    }
}
