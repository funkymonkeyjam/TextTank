@testable import TextTankCore
// SPDX-License-Identifier: GPL-3.0-or-later
// Audit package 6: document open, save and recovery correctness. These sections run inside
// document-checks after the sections in DocumentChecks.swift and share its support directory
// and document controller. Nothing here presents a panel: every chooser is an injected closure.
import AppKit
@testable import TextTankRuntime
import EditorBridge
import NativeSearch

extension DocumentChecks {
    @MainActor static func openSaveRecovery(root: URL, documents: TextDocumentController, section: SectionRunner) {
        let files = FileManager.default
        let area = root.appendingPathComponent("package-6", isDirectory: true)
        /// A clean document loaded from `bytes` at `url`, as the open path leaves it.
        @MainActor func loaded(_ url: URL, _ bytes: Data) throws -> TextDocument {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? url.checkResourceIsReachable()) != true { try bytes.write(to: url) }
            let document = TextDocument()
            document.fileURL = url
            document.fileType = "Plain Text"
            try document.read(from: bytes, ofType: "Plain Text")
            return document
        }
        func isSymbolicLink(_ url: URL) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
        }
        @MainActor func edit(_ document: TextDocument, _ text: String) {
            document.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "selectAll"))
            document.editor.replaceSelection(text)
        }

        section("size-scaled automatic recovery", #line) {
            let mib = 1024 * 1024
            let scales: [(Int, Double?)] = [
                (0, 1), (8 * mib, 1), (8 * mib + 1, 2), (32 * mib, 2),
                (32 * mib + 1, 4), (64 * mib, 4), (128 * mib, 4), (128 * mib + 1, 8), (256 * mib, 8),
                (256 * mib + 1, nil)
            ]
            check(
                scales.allSatisfy { TextDocument.automaticRecoveryScale(byteCount: $0.0) == $0.1 },
                "actual UTF-8 byte boundaries retain small timings and pause only above 256 MiB")
            let writer = RecoveryWriter(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let valid = DispatchSemaphore(value: 0), invalid = DispatchSemaphore(value: 0),
                wrote = DispatchSemaphore(value: 0)
            writer.submit {
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
            }
            guard entered.wait(timeout: .now() + 2) == .success else { throw CocoaError(.fileWriteUnknown) }
            writer.submitPrepared({ { wrote.signal() } }, didPrepare: { valid.signal() }, completion: { _ in })
            writer.submitPrepared(
                { throw EditorCaptureError.invalidUTF8 }, didPrepare: { invalid.signal() }, completion: { _ in })
            guard valid.wait(timeout: .now() + 2) == .success, invalid.wait(timeout: .now() + 2) == .success else {
                release.signal()
                throw CocoaError(.fileWriteUnknown)
            }
            let waiter = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                waiter.signal()
                writer.waitForPendingWrites()
                completed.signal()
            }
            _ = waiter.wait(timeout: .now() + 2)
            check(completed.wait(timeout: .now()) == .timedOut, "oversized flush waits for its eligible predecessor")
            release.signal()
            check(
                completed.wait(timeout: .now() + 2) == .success && wrote.wait(timeout: .now()) == .success,
                "an invalid newer capture cannot displace the last valid queued draft at the cutoff")
        }

        section("bundled command-line request contents and receipt", #line) {
            let sender = try TTInvocation(create: true)
            let recipient = try TTInvocation(id: sender.id, create: false)
            try sender.publish(.request) { try $0.write(contentsOf: JSONEncoder().encode(TTRequest.input(wait: true))) }
            let content = Data("first\r\n雪".utf8)
            try sender.publish(.input) { try $0.write(contentsOf: content) }
            check(try recipient.claim() && !recipient.claim(), "one receiver claims the request once")
            let bytes = try requireValue(try recipient.read(.processing), "receiver can inspect claimed request")
            guard case .input(let wait) = try JSONDecoder().decode(TTRequest.self, from: bytes) else {
                throw TTToolError("The request changed during handoff.")
            }
            check(
                try wait && recipient.consumeInput() == content && recipient.read(.input) == nil,
                "UTF-8 input survives handoff and private input is retired after capture")
            try recipient.report(.closed)
            let reply = try requireValue(try sender.read(.reply), "client receives document close")
            let receipt = try JSONDecoder().decode(TTReply.self, from: reply)
            check(
                receipt.pid == ProcessInfo.processInfo.processIdentifier && receipt.state == .closed,
                "completion carries the responding process identity and closed state")
        }
        section("macOS Services selected text", #line) {
            let originalProvider = NSApp.servicesProvider
            defer { NSApp.servicesProvider = originalProvider }
            let delegate = AppDelegate()
            delegate.installTextServices()
            let provider = try requireValue(
                NSApp.servicesProvider as? TextServices, "native Services provider installed")
            let board = NSPasteboard(name: .init("org.texttank.tests.service." + UUID().uuidString))
            defer { board.releaseGlobally() }
            let selected = "first\r\n雪\n"
            _ = board.setString(selected, forType: .string)
            var failure: NSString?
            let before = documents.documents.count
            provider.newTextTankDocument(board, userData: nil, error: &failure)
            let doc = try requireValue(documents.documents.last as? TextDocument, "Services routes into TextDocument")
            defer { doc.close() }
            check(
                failure == nil && documents.documents.count == before + 1 && doc.fileURL == nil
                    && doc.editor.checkedUTF8Data == Data(selected.utf8) && board.string(forType: .string) == selected,
                "selection opens as an independent untitled document")
            let libraryURL = AppStorage.url(.automations)
            let old = try? Data(contentsOf: libraryURL)
            defer {
                if let old {
                    try? old.write(to: libraryURL, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: libraryURL)
                }
            }
            let good = AutomationDefinition(
                id: UUID(), name: "Duplicate removal", input: .selection, steps: [.init(kind: .deduplicateLines)],
                output: .editor)
            var bad = good
            bad.id = UUID()
            bad.name = "External"
            bad.output = .reminders
            let lib = try AutomationLibrary(workflows: [good, bad]).encoded()
            try lib.write(to: libraryURL, options: .atomic)
            let run = TextServices(
                newDocument: { _ in check(false, "transform opened a document") },
                choose: { options in
                    check(options.map(\.id) == [good.id], "chooser offers only supplied-text automations")
                    return options.first
                })
            _ = board.setString("a\na\nb", forType: .string)
            run.runTextTankAutomation(board, userData: nil, error: &failure)
            check(
                try failure == nil && board.string(forType: .string) == "a\nb"
                    && documents.documents.count == before + 1 && Data(contentsOf: libraryURL) == lib,
                "Services returns transformed selection through only the supplied pasteboard")
            let cancel = TextServices(newDocument: { _ in }, choose: { _ in nil })
            let gen = board.changeCount
            cancel.runTextTankAutomation(board, userData: nil, error: &failure)
            check(failure == nil && board.changeCount == gen, "cancel preserves invocation pasteboard")
            let mutation = TextServices(
                newDocument: { _ in },
                choose: { options in
                    _ = board.setString("newer selection", forType: .string)
                    return options.first
                })
            mutation.runTextTankAutomation(board, userData: nil, error: &failure)
            check(
                failure != nil && board.string(forType: .string) == "newer selection",
                "stale service refuses to replace the changed selection")
        }

        section("explicit local text URL", #line) {
            let folder = area.appendingPathComponent("explicit-url", isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try checkTextURL(in: folder, delegate: AppDelegate())
        }
        section("invalid editor bytes preserve saved files and recovery", #line) {
            let source = area.appendingPathComponent("checked-capture.txt"), disk = Data("saved file".utf8)
            let doc = try loaded(source, disk)
            defer { doc.close() }
            doc.dependencies.automaticRecoveryDelay = 0.02
            doc.dependencies.recoveryFailureNotice = { _, _ in false }
            let good = "\u{feff}draft\0\r\n😀"
            doc.editor.text = good
            doc.flushRecovery()
            let snapshotURL = TextDocument.recovery.fileURL(for: doc.recoveryID)
            let previous = try Data(contentsOf: snapshotURL)
            check(
                try TextDocument.recovery.load(id: doc.recoveryID).text == good,
                "valid recovery preserves content BOM and NUL")

            // Bypass normal UTF-8-producing input only in this owned fixture (SCI_APPENDTEXT).
            var bad: UInt8 = 0xff
            _ = withUnsafePointer(to: &bad) { sci(doc.editor, 2282, 1, Int(bitPattern: $0)) }
            let damaged = Data(good.utf8) + Data([0xff])
            check(doc.editor.checkedUTF8Data == damaged, "invalid byte reaches the real owned document")
            rejects("save refuses invalid editor bytes", expecting: EditorCaptureError.invalidUTF8) {
                try doc.writeSafely(to: source, ofType: "Plain Text", for: .saveOperation)
            }
            rejects("data representation refuses invalid editor bytes", expecting: EditorCaptureError.invalidUTF8) {
                _ = try doc.data(ofType: "Plain Text")
            }
            rejects("print refuses invalid editor bytes", expecting: EditorCaptureError.invalidUTF8) {
                _ = try doc.printOperation(withSettings: [:])
            }
            let originalFormat = doc.format
            rejects("format conversion refuses invalid editor bytes", expecting: EditorCaptureError.invalidUTF8) {
                try doc.convertEncoding(to: "utf16BE")
            }
            spinUntil("recovery timer delivers the checked capture error") {
                doc.lastRecoveryError as? EditorCaptureError == .invalidUTF8
            }
            check(
                try Data(contentsOf: snapshotURL) == previous,
                "failed automatic capture preserves the prior JSON exactly")
            doc.flushRecovery()
            check(
                try Data(contentsOf: snapshotURL) == previous
                    && doc.lastRecoveryError as? EditorCaptureError == .invalidUTF8,
                "failed synchronous capture preserves the prior JSON exactly")
            check(
                try Data(contentsOf: source) == disk && doc.editor.modified && doc.editor.checkedUTF8Data == damaged
                    && doc.format == originalFormat,
                "refusal preserves the file, damaged buffer, format and dirty state")
            doc.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(doc.editor.checkedUTF8Data == Data(good.utf8), "undo removes just the injected byte")
            doc.flushRecovery()
            check(
                try TextDocument.recovery.load(id: doc.recoveryID).text == good && doc.lastRecoveryError == nil,
                "repaired editor clears the failure and writes a readable v1 snapshot")
            let printed = try doc.printOperation(withSettings: [:]).view as? NSTextView
            check(printed?.string == good, "printing preserves a content BOM, NUL and Unicode")
            try doc.writeSafely(to: source, ofType: "Plain Text", for: .saveOperation)
            check(
                try Data(contentsOf: source) == Data(good.utf8) && !doc.editor.modified,
                "normal save resumes and sets the checkpoint on exact submitted bytes")
        }

        section("F316 actual document completion transport ownership", #line) {
            let shared = NSDocumentController.shared
            let url = area.appendingPathComponent("completion-owned.txt")
            var directCalls = 0
            let direct = TextDocumentController.OpenDelivery(documents, url: url, display: false) {
                document, alreadyOpen, error in
                directCalls += 1
                check(
                    Thread.isMainThread && document == nil && alreadyOpen && error == nil,
                    "F316 live-owner completion preserves its arguments and direct main turn")
            }
            direct.receive(nil, true, nil)
            check(directCalls == 1, "F316 actual production completion transport invokes main input synchronously once")
            for absentOwner in [false, true] {
                let owner: TextDocumentController? = absentOwner ? nil : documents
                var callbacks = 0, onMain = false, receivedAlreadyOpen = false
                var receivedCode: Int?
                let delivery = TextDocumentController.OpenDelivery(owner, url: url, display: false) {
                    document, alreadyOpen, error in
                    callbacks += 1
                    onMain = Thread.isMainThread && document == nil
                    receivedAlreadyOpen = alreadyOpen
                    receivedCode = (error as NSError?)?.code
                }
                check(
                    NSDocumentController.shared === documents,
                    "F316 live and nil-owner completion setup keeps the existing document-controller singleton")
                let posted = DispatchSemaphore(value: 0)
                let worker = Thread {
                    delivery.receive(nil, true, CocoaError(.fileReadUnknown))
                    posted.signal()
                }
                worker.start()
                try require(
                    posted.wait(timeout: .now() + 5) == .success,
                    "F316 framework-style worker completion returns without waiting for main")
                check(callbacks == 0, "F316 worker completion does not invoke caller UI captures inline")
                spinUntil(timeout: 1, "F316 completion reaches its owned main turn") { callbacks == 1 }
                check(
                    onMain && receivedAlreadyOpen && receivedCode == CocoaError.fileReadUnknown.rawValue,
                    "F316 live and nil-owner deliveries preserve callback arguments on main")
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                check(
                    callbacks == 1 && NSDocumentController.shared === shared,
                    "F316 production delivery completes exactly once without replacing the shared document controller")
            }
        }

        // F127
        section("legacy encodings open by explicit choice", #line) {
            check(NSDocumentController.shared === documents, "the shared document controller is TextTank's own")
            let latinBytes = Data([0x63, 0x61, 0x66, 0xE9]), latinURL = area.appendingPathComponent("latin1.txt")
            try files.createDirectory(at: area, withIntermediateDirectories: true)
            try latinBytes.write(to: latinURL)
            let before = NSDocumentController.shared.documents.count
            var automatic: Error?
            let plain = TextDocument()
            do { try plain.read(from: latinURL, ofType: "Plain Text") } catch { automatic = error }
            plain.close()
            check(
                automatic.flatMap(EncodingChoice.codecError(in:)) == .invalidBytes(.utf8),
                "opening a Latin-1 file through the default path still rejects with the codec error")
            let latin = try TextDocument.open(latinURL, as: .latin1, display: false)
            check(
                latin.editor.text == "café" && latin.format == FileFormat(encoding: .latin1, bom: false)
                    && !latin.isDocumentEdited && latin.fileURL == latinURL,
                "explicit Latin-1 open decodes the text and records the format without a BOM")
            check(try latin.diskState() == .unchanged, "explicitly opened legacy file has an exact disk baseline")
            edit(latin, "changed")
            latin.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo"))
            check(
                try latin.data(ofType: "Plain Text") == latinBytes,
                "edit and undo leave the legacy file's bytes exact")
            try latin.writeSafely(to: latinURL, ofType: "Plain Text", for: .saveOperation)
            check(
                try Data(contentsOf: latinURL) == latinBytes && latin.diskState() == .unchanged,
                "a no-op save writes the original legacy bytes back")
            latin.close()
            let undefinedURL = area.appendingPathComponent("undefined-1252.txt")
            try Data([0x81]).write(to: undefinedURL)
            rejects(
                "a wrong explicit choice surfaces the codec error", expecting: FileCodecError.invalidBytes(.windows1252)
            ) { _ = try TextDocument.open(undefinedURL, as: .windows1252, display: false) }
            check(NSDocumentController.shared.documents.count == before, "a failed explicit open creates no document")

            // Matching survives AppKit wrapping the thrown error.
            let wrapped = NSError(
                domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                userInfo: [
                    NSUnderlyingErrorKey: NSError(
                        domain: "outer", code: 1,
                        userInfo: [NSUnderlyingErrorKey: FileCodecError.unsupportedUTF32 as NSError])
                ])
            check(
                EncodingChoice.codecError(in: FileCodecError.invalidBytes(.utf8)) == .invalidBytes(.utf8)
                    && EncodingChoice.codecError(in: wrapped) == .unsupportedUTF32,
                "a decode failure is recognised directly and inside wrapped errors")
            check(
                EncodingChoice.codecError(in: FileCodecError.unrepresentable(.latin1)) == nil
                    && EncodingChoice.codecError(in: CocoaError(.fileNoSuchFile)) == nil
                    && EncodingChoice.codecError(in: POSIXError(.ELOOP)) == nil,
                "errors that are not a decode failure are never answered with an encoding choice")
            let afterUTF8 = EncodingChoice.popUp(after: FileCodecError.invalidBytes(.utf8))
            check(
                afterUTF8.itemTitles == ["UTF-16 LE", "UTF-16 BE", "Windows-1252", "ISO-8859-1"]
                    && EncodingChoice.selection(of: afterUTF8) == .windows1252
                    && afterUTF8.accessibilityLabel()?.isEmpty == false,
                "the chooser omits the encoding that failed, preselects Windows-1252 and is labelled")
            let afterUTF32 = EncodingChoice.popUp(after: FileCodecError.unsupportedUTF32)
            check(
                afterUTF32.numberOfItems == FileEncoding.allCases.count
                    && EncodingChoice.selection(of: afterUTF32) == .utf16LE,
                "an apparent UTF-32 signature offers every encoding with UTF-16 LE preselected")
            afterUTF8.selectItem(withTitle: "ISO-8859-1")
            check(EncodingChoice.selection(of: afterUTF8) == .latin1, "the chooser returns the selected encoding")
            check(
                EncodingChoice.selection(of: EncodingChoice.popUp(after: FileCodecError.invalidBytes(.windows1252)))
                    == .latin1, "after Windows-1252 fails the chooser preselects ISO-8859-1")

            // The interactive route of File > Open, Recent and Finder, with the chooser injected.
            let mixedURL = area.appendingPathComponent("mixed-high-bytes.txt")
            try Data([0x63, 0x81, 0xE9]).write(to: mixedURL)
            var asked: [FileCodecError?] = []
            var answers: [FileEncoding?] = [.windows1252, .latin1]
            let standardChooser = documents.chooseEncoding
            defer { documents.chooseEncoding = standardChooser }
            documents.chooseEncoding = { url, error in
                asked.append(EncodingChoice.codecError(in: error))
                return url == mixedURL || url == latinURL ? answers.removeFirst() : nil
            }
            let chosen = try requireValue(
                try documents.openChoosingEncoding(
                    mixedURL, after: FileCodecError.invalidBytes(.utf8), display: false),
                "the second encoding choice opens the file")
            check(
                asked == [.invalidBytes(.utf8), .invalidBytes(.windows1252)],
                "a failed choice asks again with the new codec error")
            check(
                chosen.editor.text == "c\u{81}é" && chosen.format.encoding == .latin1 && !chosen.isDocumentEdited
                    && NSDocumentController.shared.document(for: mixedURL) === chosen,
                "the chosen encoding opens one clean registered document")
            check(
                try chosen.data(ofType: "Plain Text") == Data([0x63, 0x81, 0xE9]),
                "no byte of the legacy file was substituted")
            chosen.close()
            answers = [nil]
            asked = []
            check(
                try documents.openChoosingEncoding(latinURL, after: wrapped, display: false) == nil
                    && asked.count == 1 && NSDocumentController.shared.documents.count == before,
                "Cancel in the encoding chooser creates no document")
            asked = []
            rejects("an open failure that is not a decode failure is passed through without asking") {
                _ = try documents.openChoosingEncoding(
                    latinURL, after: CocoaError(.fileReadNoPermission), display: false)
            }
            check(asked.isEmpty, "the chooser is not shown for an unrelated open failure")

            // What File > Open does with the answer of the stock open. AppKit hands the read
            // error back wrapped, with the codec error under NSUnderlyingErrorKey.
            let fromAppKit = NSError(
                domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                userInfo: [NSUnderlyingErrorKey: FileCodecError.invalidBytes(.utf8)])
            var answered: (NSDocument?, Bool, Error?)?
            answers = [.latin1]
            asked = []
            documents.finishOpen(latinURL, display: false, presenting: false, nil, false, fromAppKit) {
                answered = ($0, $1, $2)
            }
            check(
                asked.isEmpty && answered?.0 == nil && (answered?.2 as NSError?) === fromAppKit
                    && NSDocumentController.shared.documents.count == before,
                "an open that is not displayed passes the decode error on and never asks")
            answered = nil
            documents.finishOpen(latinURL, display: true, presenting: false, nil, false, fromAppKit) {
                answered = ($0, $1, $2)
            }
            let viaOpen = try requireValue(
                answered?.0 as? TextDocument, "a displayed open answers a wrapped decode error with the chooser")
            check(
                asked == [.invalidBytes(.utf8)] && viaOpen.editor.text == "café" && viaOpen.format.encoding == .latin1
                    && answered?.2 == nil && NSDocumentController.shared.document(for: latinURL) === viaOpen,
                "the displayed open completes with the document opened in the chosen encoding")
            answered = nil
            asked = []
            documents.finishOpen(latinURL, display: true, presenting: false, viaOpen, true, nil) {
                answered = ($0, $1, $2)
            }
            check(
                asked.isEmpty && answered?.0 === viaOpen && answered?.1 == true && answered?.2 == nil,
                "a successful open is passed through untouched")
            edit(viaOpen, "private draft")
            _ = viaOpen.editor.setSelectionAnchor(0, caret: 7)
            rejects("failed reinterpretation retains the prior decoder") {
                try viaOpen.reload(using: .utf8, discard: true)
            }
            check(
                viaOpen.editor.selectedText == "private" && viaOpen.isDocumentEdited
                    && viaOpen.format.encoding == .latin1,
                "failed reinterpretation keeps the dirty selection and its previously selected encoding")
            try viaOpen.revert(toContentsOf: latinURL, ofType: TextDocument.plainTextType)
            check(
                viaOpen.editor.text == "café" && viaOpen.format.encoding == .latin1 && !viaOpen.isDocumentEdited,
                "Revert preserves the legacy encoding selected through the actual open completion")
            viaOpen.close()
            answers = [nil]
            asked = []
            answered = nil
            documents.finishOpen(latinURL, display: true, presenting: false, nil, false, fromAppKit) {
                answered = ($0, $1, $2)
            }
            check(
                asked.count == 1 && answered?.0 == nil && (answered?.2 as? CocoaError)?.code == .userCancelled
                    && NSDocumentController.shared.documents.count == before,
                "Cancel in a displayed open completes as cancelled, with no document and nothing to present")
            answered = nil
            let denied = CocoaError(.fileReadNoPermission)
            documents.finishOpen(latinURL, display: true, presenting: false, nil, false, denied) {
                answered = ($0, $1, $2)
            }
            check(
                asked.count == 1 && answered?.0 == nil && (answered?.2 as? CocoaError)?.code == .fileReadNoPermission,
                "a displayed open passes an unrelated failure on without asking")

            // BOM-less UTF-16 with non-ASCII content.
            let wideFormat = FileFormat(encoding: .utf16LE, bom: false),
                wideBytes = try FileCodec.encode("héllo wörld", format: wideFormat),
                wideURL = area.appendingPathComponent("bomless-utf16.txt")
            try wideBytes.write(to: wideURL)
            rejects("BOM-less UTF-16 is not guessed") { _ = try FileCodec.decode(wideBytes) }
            documents.chooseEncoding = { _, _ in .utf16LE }
            let wide = try requireValue(
                try documents.openChoosingEncoding(wideURL, after: FileCodecError.invalidBytes(.utf8), display: false),
                "BOM-less UTF-16 opens by explicit choice")
            check(
                wide.editor.text == "héllo wörld" && wide.format == wideFormat && !wide.isDocumentEdited,
                "BOM-less UTF-16 opens with its text and stays BOM-less")
            edit(wide, "private draft")
            try wide.revert(toContentsOf: wideURL, ofType: TextDocument.plainTextType)
            check(
                wide.editor.text == "héllo wörld" && wide.format == wideFormat && !wide.isDocumentEdited,
                "Revert keeps the chosen BOM-less UTF-16 interpretation and clears the discarded draft")
            edit(wide, "héllo")
            try wide.writeSafely(to: wideURL, ofType: "Plain Text", for: .saveOperation)
            check(
                try Data(contentsOf: wideURL) == (try FileCodec.encode("héllo", format: wideFormat)),
                "a BOM-less UTF-16 file opened by choice saves back without a BOM")
            wide.close()

            let autoURL = area.appendingPathComponent("monitored-auto-encoding.txt")
            try Data("plain".utf8).write(to: autoURL)
            let autoDocument = try DocumentFactory.openCaptured(
                WorkspaceStore.captureRegularFile(autoURL), from: autoURL, display: false)
            let autoMonitor = DocumentMonitor()
            try autoMonitor.start(autoDocument)
            try autoMonitor.reload(expectedRevision: autoDocument.editor.revision)
            autoMonitor.stop()
            let marked = FileFormat(encoding: .utf16BE, bom: true)
            try FileCodec.encode("new representation", format: marked).write(to: autoURL)
            try autoDocument.revert(toContentsOf: autoURL, ofType: TextDocument.plainTextType)
            check(
                autoDocument.format == marked && autoDocument.editor.text == "new representation",
                "monitor reload of an automatically decoded document keeps Revert's encoding detection")
            autoDocument.close()

            // The workspace browser: only row activation asks; open(_:) itself never does.
            let browser = WorkspaceBrowserController(
                storeURL: area.appendingPathComponent("browser-state.json"), recordsSystemRecent: false)
            var browserAsked = 0
            browser.chooseEncoding = { _, _ in
                browserAsked += 1
                return nil
            }
            rejects("the browser's non-interactive open still rejects a legacy file") { _ = try browser.open(latinURL) }
            check(browserAsked == 0, "the browser's non-interactive open never asks for an encoding")
            check(
                try browser.openOfferingEncoding(latinURL) == nil && browserAsked == 1
                    && NSDocumentController.shared.documents.count == before,
                "Cancel from a browser row creates no document")
            browser.chooseEncoding = { _, _ in .windows1252 }
            let fromBrowser = try requireValue(
                try browser.openOfferingEncoding(latinURL), "a browser row opens a legacy file by explicit choice")
            check(
                try fromBrowser.editor.text == "café" && fromBrowser.format.encoding == .windows1252
                    && !fromBrowser.isDocumentEdited && fromBrowser.diskState() == .unchanged,
                "the browser's explicit choice decodes the bytes it read and keeps the baseline")
            fromBrowser.close()
            let browserLink = area.appendingPathComponent("browser-link.txt")
            try files.createSymbolicLink(at: browserLink, withDestinationURL: latinURL)
            browserAsked = 0
            browser.chooseEncoding = { _, _ in
                browserAsked += 1
                return .latin1
            }
            rejects("a symlinked browser entry is still refused, not offered an encoding") {
                _ = try browser.openOfferingEncoding(browserLink)
            }
            check(
                browserAsked == 0 && NSDocumentController.shared.documents.count == before,
                "the refused symlink asked nothing and opened nothing")
            browser.window?.close()
        }

        // F192
        section("documents reached through symbolic links", #line) {
            let home = area.appendingPathComponent("links", isDirectory: true)
            let real = home.appendingPathComponent("real", isDirectory: true)
            try files.createDirectory(at: real, withIntermediateDirectories: true)
            let alias = home.appendingPathComponent("alias", isDirectory: true)
            try files.createSymbolicLink(at: alias, withDestinationURL: real)
            // The pitfall the audit names: /tmp and /var are themselves links to /private.
            check(
                TextDocument.canonicalDiskURL(URL(fileURLWithPath: "/tmp/texttank-not-created.txt")).path
                    == "/private/tmp/texttank-not-created.txt",
                "a name that does not exist yet resolves through its folder, keeping /private")
            check(
                TextDocument.canonicalDiskURL(alias.appendingPathComponent("absent.txt")).path
                    == TextDocument.canonicalDiskURL(real).path + "/absent.txt"
                    && TextDocument.canonicalDiskURL(real).path.hasPrefix("/private/"),
                "the resolved location is the real folder under /private")

            let target = real.appendingPathComponent("target.txt"), leaf = home.appendingPathComponent("leaf.txt")
            try Data("through a link\n".utf8).write(to: target)
            try files.createSymbolicLink(at: leaf, withDestinationURL: target)
            let inside = alias.appendingPathComponent("inside.txt")
            try Data("inside a linked folder\n".utf8).write(to: real.appendingPathComponent("inside.txt"))
            // The framework can set fileURL from its own queue. Canonical metadata must be
            // immediately visible without draining main, while the existing recovery increment
            // remains queued for main. This fixture owns both aliases and never calls the editor
            // from the worker.
            let setterDocument = TextDocument()
            let setterBase = setterDocument.recoveryBase
            let setterDone = DispatchSemaphore(value: 0)
            let setterThread = Thread {
                setterDocument.fileURL = leaf
                setterDone.signal()
            }
            setterThread.start()
            try require(
                setterDone.wait(timeout: .now() + 5) == .success,
                "F316 owned off-main fileURL setter completes without main coordination")
            check(
                setterDocument.fileURL == leaf && setterDocument.diskURL == TextDocument.canonicalDiskURL(target),
                "F316 off-main fileURL setter publishes its canonical location synchronously")
            check(
                setterDocument.recoveryBase == setterBase,
                "F316 off-main setter preserves queued recovery metadata timing")
            spinUntil(timeout: 1, "F316 owned setter recovery metadata reaches main") {
                setterDocument.recoveryBase == setterBase + 1
            }
            check(
                setterDocument.recoveryBase == setterBase + 1,
                "F316 off-main setter increments recovery metadata on its original main-queue turn")
            setterDocument.close()
            for (label, url, actual) in [
                ("symlink leaf", leaf, target),
                ("symlinked parent folder", inside, real.appendingPathComponent("inside.txt"))
            ] {
                let bytes = try Data(contentsOf: actual)
                let document = try loaded(url, bytes)
                check(
                    document.fileURL == url && document.diskURL?.path == TextDocument.canonicalDiskURL(actual).path,
                    "\(label): the document keeps the opened path and resolves its real location once")
                check(try document.diskState() == .unchanged, "\(label): external-change check reads the real file")
                check(
                    DocumentMonitor.inspect(url, expected: document.originalDiskFingerprint).status != .unchanged
                        && DocumentMonitor.inspect(document.diskURL!, expected: document.originalDiskFingerprint)
                            .status == .unchanged,
                    "\(label): monitoring the resolved location reports unchanged")
                edit(document, "saved \(label)\n")
                // NSDocument reads fileURL from its file-presenter queue. Only the thread doing
                // the write may see the resolved destination; any other keeps the opened path.
                let seenElsewhere = FileURLObservation()
                var seenByWriter: URL?
                document.dependencies.duringWrite = {
                    seenByWriter = document.fileURL
                    let done = DispatchSemaphore(value: 0)
                    let other = Thread {
                        seenElsewhere.set(document.fileURL)
                        done.signal()
                    }
                    other.start()
                    _ = done.wait(timeout: .now() + 5)
                }
                try document.writeSafely(to: url, ofType: "Plain Text", for: .saveOperation)
                document.dependencies.duringWrite = nil
                check(
                    seenByWriter == document.diskURL && seenElsewhere.value == url && document.fileURL == url,
                    "\(label): only the writing thread sees the resolved location during an in-place Save")
                check(
                    try Data(contentsOf: actual) == Data("saved \(label)\n".utf8) && !document.isDocumentEdited
                        && document.diskState() == .unchanged, "\(label): Save writes the real file in place")
                check(
                    isSymbolicLink(url) == (url == leaf) && isSymbolicLink(alias) && !isSymbolicLink(actual),
                    "\(label): the link is still a link after Save")
                try Data("changed elsewhere\n".utf8).write(to: actual)
                check(try document.diskState() == .changed, "\(label): an external change is still detected")
                rejects(
                    "\(label): a changed file is still not overwritten", message: "The file changed outside TextTank"
                ) { try document.writeSafely(to: url, ofType: "Plain Text", for: .saveOperation) }
                try document.reload(using: .utf8, discard: true)
                check(
                    document.editor.text == "changed elsewhere\n" && !document.isDocumentEdited,
                    "\(label): Reload with Encoding reads the real file")
                document.close()
            }

            // Save As to a new name inside a linked folder, then an ordinary Save.
            let fresh = TextDocument()
            fresh.fileType = "Plain Text"
            fresh.editor.text = "first save"
            let freshURL = alias.appendingPathComponent("new-name.txt")
            try fresh.writeSafely(to: freshURL, ofType: "Plain Text", for: .saveAsOperation)
            fresh.fileURL = freshURL
            edit(fresh, "second save")
            try fresh.writeSafely(to: freshURL, ofType: "Plain Text", for: .saveOperation)
            check(
                try Data(contentsOf: real.appendingPathComponent("new-name.txt")) == Data("second save".utf8)
                    && fresh.diskState() == .unchanged && !fresh.isDocumentEdited,
                "Save As into a linked folder is followed by a working Save")
            fresh.close()

            // A link swapped in after open is refused, never followed.
            let swapped = real.appendingPathComponent("swapped.txt"),
                elsewhere = real.appendingPathComponent("other.txt")
            let victim = try loaded(swapped, Data("mine".utf8))
            try Data("someone else's".utf8).write(to: elsewhere)
            try files.removeItem(at: swapped)
            try files.createSymbolicLink(at: swapped, withDestinationURL: elsewhere)
            edit(victim, "must not land in the other file")
            rejects("Save refuses a file replaced by a symbolic link after open", message: "is now a symbolic link") {
                try victim.writeSafely(to: swapped, ofType: "Plain Text", for: .saveOperation)
            }
            rejects("Save As onto the same swapped path is refused as well", message: "is now a symbolic link") {
                try victim.writeSafely(to: swapped, ofType: "Plain Text", for: .saveAsOperation)
            }
            rejects("the external-change check names the swapped link", message: swapped.lastPathComponent) {
                _ = try victim.diskState()
            }
            check(
                try Data(contentsOf: elsewhere) == Data("someone else's".utf8) && isSymbolicLink(swapped)
                    && victim.isDocumentEdited && victim.editor.text == "must not land in the other file",
                "the link's target is untouched and the edits are kept")
            let aside = real.appendingPathComponent("kept-aside.txt")
            try victim.writeSafely(to: aside, ofType: "Plain Text", for: .saveAsOperation)
            check(
                try Data(contentsOf: aside) == Data("must not land in the other file".utf8),
                "Save As to another name still works after the refusal")
            victim.close()
            // The folder itself swapped for a link.
            let folder = home.appendingPathComponent("folder", isDirectory: true)
            let moved = try loaded(folder.appendingPathComponent("note.txt"), Data("note".utf8))
            try files.moveItem(at: folder, to: home.appendingPathComponent("folder-moved", isDirectory: true))
            try files.createSymbolicLink(at: folder, withDestinationURL: home.appendingPathComponent("folder-moved"))
            edit(moved, "edited")
            rejects(
                "Save refuses when the document's folder was replaced by a link", message: "its folder was replaced"
            ) {
                try moved.writeSafely(to: moved.fileURL!, ofType: "Plain Text", for: .saveOperation)
            }
            check(
                try Data(contentsOf: home.appendingPathComponent("folder-moved/note.txt")) == Data("note".utf8),
                "the file behind the replaced folder is untouched")
            moved.close()
        }

        // F6
        section("saving back to a missing or changed file", #line) {
            let folder = area.appendingPathComponent("missing", isDirectory: true)
            let goneURL = folder.appendingPathComponent("deleted.txt")
            let gone = try loaded(goneURL, Data("before".utf8))
            try files.removeItem(at: goneURL)
            check(try gone.diskState() == .missing, "fixture: the document's file was deleted externally")
            edit(gone, "written again")
            try gone.writeSafely(to: goneURL, ofType: "Plain Text", for: .saveOperation)
            check(
                try Data(contentsOf: goneURL) == Data("written again".utf8),
                "Save recreates a file that was deleted externally with the exact bytes")
            check(
                try gone.diskState() == .unchanged && !gone.isDocumentEdited && !gone.editor.modified,
                "after recreating the file the document is clean with a current baseline")
            gone.close()

            let changedURL = folder.appendingPathComponent("changed.txt")
            let changed = try loaded(changedURL, Data("before".utf8))
            edit(changed, "mine")
            try Data("external".utf8).write(to: changedURL)
            rejects(
                "plain Save still refuses to overwrite a changed file", message: "The file changed outside TextTank"
            ) {
                try changed.writeSafely(to: changedURL, ofType: "Plain Text", for: .saveOperation)
            }
            rejects(
                "Save Copy onto the document's own changed file is still refused",
                message: "The file changed outside TextTank"
            ) { try changed.writeSafely(to: changedURL, ofType: "Plain Text", for: .saveToOperation) }
            check(
                try Data(contentsOf: changedURL) == Data("external".utf8) && changed.isDocumentEdited,
                "the refused saves leave the external bytes and the edits in place")
            try changed.writeSafely(to: changedURL, ofType: "Plain Text", for: .saveAsOperation)
            check(
                try Data(contentsOf: changedURL) == Data("mine".utf8) && changed.diskState() == .unchanged
                    && !changed.isDocumentEdited,
                "Save As onto the document's own changed file is the deliberate overwrite")
            edit(changed, "mine again")
            try changed.writeSafely(to: changedURL, ofType: "Plain Text", for: .saveOperation)
            check(try Data(contentsOf: changedURL) == Data("mine again".utf8), "the Save after that overwrite succeeds")
            changed.close()

            let blockedURL = folder.appendingPathComponent("became-folder.txt")
            let blocked = try loaded(blockedURL, Data("file".utf8))
            try files.removeItem(at: blockedURL)
            try files.createDirectory(at: blockedURL, withIntermediateDirectories: false)
            edit(blocked, "edits")
            rejects("Save refuses a path that has become a folder") {
                try blocked.writeSafely(to: blockedURL, ofType: "Plain Text", for: .saveOperation)
            }
            var isDirectory: ObjCBool = false
            check(
                files.fileExists(atPath: blockedURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    && blocked.isDocumentEdited, "the folder is left alone and the edits are kept")
            blocked.close()
        }

        // F10
        section("Save Copy name and same-file target", #line) {
            let folder = area.appendingPathComponent("copies", isDirectory: true)
            let source = try loaded(folder.appendingPathComponent("main.swift"), Data("let a = 1\n".utf8))
            let makefile = try loaded(folder.appendingPathComponent("Makefile"), Data("all:\n".utf8))
            let untitled = TextDocument()
            check(
                source.suggestedCopyName == "main-copy.swift" && makefile.suggestedCopyName == "Makefile-copy"
                    && untitled.suggestedCopyName == "Untitled-copy.txt",
                "Save Copy suggests the source's own extension, none for an extensionless name, .txt when untitled")
            makefile.close()
            untitled.close()
            @MainActor func copyOutcome(_ document: TextDocument, to url: URL) -> Error? {
                var outcome: Error??
                document.writeCopy(to: url) { outcome = .some($0) }
                spinUntil("Save Copy to \(url.lastPathComponent) to finish") { outcome != nil }
                return outcome ?? nil
            }
            edit(source, "let a = 2\n")
            let other = folder.appendingPathComponent("elsewhere.swift")
            check(copyOutcome(source, to: other) == nil, "Save Copy to another file succeeds")
            check(try Data(contentsOf: other) == Data("let a = 2\n".utf8), "Save Copy writes exact bytes to the copy")
            check(source.isDocumentEdited && source.editor.modified, "Save Copy to another file keeps the source dirty")
            check(
                try Data(contentsOf: source.fileURL!) == Data("let a = 1\n".utf8) && source.diskState() == .unchanged,
                "Save Copy to another file leaves the source file and its baseline alone")
            check(copyOutcome(source, to: source.fileURL!) == nil, "Save Copy onto the document's own file succeeds")
            check(
                try Data(contentsOf: source.fileURL!) == Data("let a = 2\n".utf8),
                "Save Copy onto the document's own file writes the buffer")
            check(
                try source.diskState() == .unchanged && !source.isDocumentEdited && !source.editor.modified,
                "Save Copy onto the document's own file is a Save: clean, with a current baseline")
            edit(source, "let a = 3\n")
            try source.writeSafely(to: source.fileURL!, ofType: "Plain Text", for: .saveOperation)
            check(
                try Data(contentsOf: source.fileURL!) == Data("let a = 3\n".utf8),
                "the next Save after a same-file Save Copy reports no external change")
            // The same file named through a linked folder is still the document's own file.
            let alias = area.appendingPathComponent("copies-alias", isDirectory: true)
            try files.createSymbolicLink(at: alias, withDestinationURL: folder)
            edit(source, "let a = 4\n")
            check(
                try copyOutcome(source, to: alias.appendingPathComponent("main.swift")) == nil
                    && !source.isDocumentEdited && source.diskState() == .unchanged,
                "Save Copy onto another spelling of the document's own path is also a Save")
            edit(source, "let a = 5\n")
            try Data("external".utf8).write(to: source.fileURL!)
            let refusal = copyOutcome(source, to: source.fileURL!)
            check(
                refusal?.localizedDescription.contains("The file changed outside TextTank") == true,
                "Save Copy onto the document's own changed file is refused")
            check(
                try Data(contentsOf: source.fileURL!) == Data("external".utf8) && source.isDocumentEdited,
                "the refused same-file copy keeps the external bytes and the edits")
            source.close()
        }

        // F133
        section("recovery prompt and recovered documents show their origin", #line) {
            let folder = area.appendingPathComponent("recovered", isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let original = folder.appendingPathComponent("shopping list.txt"), originalBytes = Data("on disk".utf8)
            try originalBytes.write(to: original)
            let stamp = Date(timeIntervalSince1970: 1_763_000_000), stampText = SnapshotLabel.savedAt(stamp)
            var named = RecoverySnapshot(
                id: UUID(), text: "draft text", format: FileFormat(), originalURL: original.absoluteString, revision: 3)
            named.savedAt = stamp
            var nameless = RecoverySnapshot(
                id: UUID(), text: "never saved", format: FileFormat(), originalURL: nil, revision: 1)
            nameless.savedAt = stamp
            let prompt = AppDelegate.recoveryPromptText([named, nameless])
            check(
                prompt.contains("Found 2 recovery snapshots") && prompt.contains("original files are not changed"),
                "the recovery prompt still states the count and that originals are untouched")
            check(
                prompt.contains("shopping list.txt in \(folder.path), saved \(stampText)"),
                "the recovery prompt names each draft's original file, folder and time")
            check(
                prompt.contains("Untitled, saved \(stampText)"),
                "the recovery prompt lists an untitled draft with its time")
            let many = AppDelegate.recoveryPromptText(Array(repeating: named, count: 15), limit: 12)
            check(
                many.components(separatedBy: "\n").filter { $0.hasPrefix("• ") }.count == 12
                    && many.hasSuffix("…and 3 more"), "a long recovery list is capped with a count of the rest")
            check(
                AppDelegate.recoveryPromptText([named]).contains("Found 1 recovery snapshot."),
                "one snapshot is described in the singular")

            let recovered = try TextDocument.openRecovered(named)
            let status = (recovered.windowControllers[0] as! EditorWindowController).status
            check(
                recovered.fileURL == nil && recovered.isDocumentEdited
                    && recovered.displayName == "Recovered shopping list.txt",
                "a recovered document is unsaved and titled after the file it is a draft of")
            check(
                status.stringValue.contains("Recovered draft of shopping list.txt")
                    && status.stringValue.contains("saved \(stampText)") && status.textColor == .secondaryLabelColor,
                "the status line of a recovered document says what it came from and when")
            edit(recovered, "draft text, edited")
            recovered.flushRecovery()
            check(
                status.stringValue.contains("Recovered draft of shopping list.txt")
                    && recovered.lastRecoveryError == nil,
                "the origin stays in the status line while the draft is edited")
            check(
                try Data(contentsOf: original) == originalBytes,
                "recovery shows the origin without touching the original file")
            let keptURL = folder.appendingPathComponent("kept.txt")
            try recovered.writeSafely(to: keptURL, ofType: "Plain Text", for: .saveAsOperation)
            recovered.fileURL = keptURL
            recovered.flushRecovery()
            check(
                recovered.recoveredOrigin == nil && recovered.displayName == files.displayName(atPath: keptURL.path)
                    && !status.stringValue.contains("Recovered draft"),
                "once saved under its own name the document is no longer labelled as a recovered draft")
            check(
                try Data(contentsOf: original) == originalBytes,
                "saving the recovered draft elsewhere leaves the original file alone")
            recovered.close()
            let anonymous = try TextDocument.openRecovered(nameless)
            check(
                (anonymous.windowControllers[0] as! EditorWindowController).status.stringValue.contains(
                    "Recovered untitled draft · saved \(stampText)") && anonymous.fileURL == nil,
                "an untitled recovered draft says so, with its time")
            anonymous.close()
        }

        // G363
        section("session snapshot prompt, extension and routing", #line) {
            let stamp = Date(timeIntervalSince1970: 1_763_000_000)
            func entry(_ name: String?, dirty: Bool) -> SessionDocument {
                SessionDocument(
                    id: UUID(), originalURL: name.map { area.appendingPathComponent($0) }, text: "x",
                    format: FileFormat(), isDirty: dirty, selection: SessionSelection(anchorByte: 0, caretByte: 0))
            }
            var session = WorkspaceSession(
                id: UUID(), name: "Prompt", documents: [entry("absent.txt", dirty: true), entry(nil, dirty: false)])
            session.savedAt = stamp
            let text = WorkspaceController.restorePromptText(session, session.inspectReferencedFiles())
            check(
                text.contains("Saved \(SnapshotLabel.savedAt(stamp))")
                    && text.contains("open as new unsaved documents"),
                "the session restore prompt shows when the snapshot was saved")
            check(
                text.contains("absent.txt: \(SessionFileStatus.missing.description) · had unsaved edits")
                    && text.contains("Untitled: \(SessionFileStatus.untitled.description) · no unsaved edits"),
                "the session restore prompt shows each document's captured dirty state")
            // One extension, declared to the system and proposed by the save panel.
            let plist = try requireValue(
                NSDictionary(contentsOf: TestPaths.resources.appendingPathComponent("Info.plist")) as? [String: Any],
                "fixture: Info.plist is readable")
            let exported = (plist["UTExportedTypeDeclarations"] as? [[String: Any]]) ?? []
            let tags =
                exported.first { $0["UTTypeIdentifier"] as? String == "app.texttank.session" }?[
                    "UTTypeTagSpecification"]
                as? [String: Any]
            check(
                WorkspaceStore.sessionFileExtension == "texttanksession"
                    && tags?["public.filename-extension"] as? [String] == [WorkspaceStore.sessionFileExtension],
                "the session extension the app proposes is the one Info.plist exports")
            check(
                ((plist["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []).contains {
                    ($0["LSItemContentTypes"] as? [String]) == ["app.texttank.session"]
                }, "Info.plist declares a document type for session snapshots")
            // File > Open or Finder on a snapshot goes to the restore prompt, not an editable JSON document.
            let sessionURL = area.appendingPathComponent("routed." + WorkspaceStore.sessionFileExtension)
            try files.createDirectory(at: area, withIntermediateDirectories: true)
            try WorkspaceStore.save(session, to: sessionURL)
            var routed: [URL] = []
            let standardRoute = documents.openSessionFile
            defer { documents.openSessionFile = standardRoute }
            documents.openSessionFile = { routed.append($0) }
            var completion: (NSDocument?, Bool, Error?)?
            documents.openDocument(withContentsOf: sessionURL, display: true) { completion = ($0, $1, $2) }
            check(
                routed == [sessionURL] && NSDocumentController.shared.documents.isEmpty,
                "opening a session snapshot is routed to the restore prompt and opens no text document")
            check(
                completion != nil && completion?.0 == nil && (completion?.2 as? CocoaError)?.code == .userCancelled,
                "the routed open completes without a document and without an error to present")
            // The workspace browser's interactive open takes the same route.
            let browser = WorkspaceBrowserController(
                storeURL: area.appendingPathComponent("browser-session-state.json"), recordsSystemRecent: false)
            routed = []
            check(
                try browser.openOfferingEncoding(sessionURL) == nil && routed == [sessionURL]
                    && NSDocumentController.shared.documents.isEmpty,
                "a session snapshot activated in the workspace browser is routed to the restore prompt")
            browser.window?.close()
            // Reading never depends on the extension.
            let renamed = area.appendingPathComponent("older-snapshot.json")
            try WorkspaceStore.save(session, to: renamed)
            check(try WorkspaceStore.load(from: renamed) == session, "a snapshot saved under any name still loads")
        }
    }
    @MainActor static func checkTextURL(in root: URL, delegate: AppDelegate) throws {
        let name = "space # +&% and 雪.txt", file = root.appendingPathComponent(name)
        let disk = Data("first\r\n甲\t🍋é\r\nlast".utf8)
        try disk.write(to: file)
        func address(_ url: URL, _ line: String?, _ column: String?) -> String {
            var request = URLComponents()
            request.scheme = "texttank"
            request.host = "open"
            request.queryItems = [.init(name: "path", value: url.path)]
            if let line { request.queryItems?.append(.init(name: "line", value: line)) }
            if let column { request.queryItems?.append(.init(name: "column", value: column)) }
            return request.string!
        }
        func event(_ url: String) -> NSAppleEventDescriptor {
            let input = NSAppleEventDescriptor(
                eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            input.setParam(NSAppleEventDescriptor(string: url), forKeyword: keyDirectObject)
            return input
        }
        let docs = NSDocumentController.shared
        let count = docs.documents.count
        let raw = address(file, "2", "6")
        let reply = NSAppleEventDescriptor.list()
        delegate.handleOpenTextURL(event(raw), reply: reply)
        let doc = try requireValue(
            docs.document(for: file) as? TextDocument, "URL opens exactly the encoded local path")
        defer { doc.close() }
        doc.editor.configureTabWidth(4, useTabs: false)
        let again = try TextOpenRequest(raw).open()
        check(
            again === doc && docs.documents.count == count + 1 && !doc.isDocumentEdited
                && doc.editor.statusInfo.line == 2 && doc.editor.statusInfo.column == 6,
            "one-based line and tab-expanded column reuse the same native document")
        let end = try TextOpenRequest(address(file, "1000", "99999")).open()
        check(end === doc && doc.editor.selectionCaret == disk.count, "coordinates past EOF clamp to last line end")
        doc.editor.replaceSelection(" unsaved")
        let changed = doc.editor.checkedUTF8Data
        _ = try TextOpenRequest(address(file, "1", "1")).open()
        check(
            try doc.editor.checkedUTF8Data == changed && doc.isDocumentEdited && doc.editor.selectionCaret == 0
                && Data(contentsOf: file) == disk,
            "reopening navigates without reloading or saving an existing dirty original")
        let retained = docs.documents.count
        for invalid in [
            "texttank://run?path=/owned", "texttank://open?path=relative", "texttank://open?path=/a&path=/b",
            "texttank://open?path=//server/share", "texttank://open?path=/a&command=no",
            "texttank://open?path=/a&line=-1", "texttank://open?path=/a&column=0", "texttank://open?path=/a#x",
            "texttank://user@open?path=/a", "texttank://open?path=%00", "https://open?path=/a"
        ] {
            rejects("invalid open request is refused") { _ = try TextOpenRequest(invalid) }
        }
        let bin = root.appendingPathComponent("binary.txt")
        try Data([0, 1, 2, 3]).write(to: bin)
        let alias = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        for invalid in [root, bin, alias, root.appendingPathComponent("missing.txt")] {
            rejects("nonregular, missing or binary URL cannot register a document") {
                _ = try TextOpenRequest(address(invalid, nil, nil)).open()
            }
        }
        check(
            docs.documents.count == retained && doc.editor.checkedUTF8Data == changed,
            "rejections preserve the document registry and dirty text")
        let valid16 = root.appendingPathComponent("utf16.txt")
        try FileCodec.encode("wide雪", format: FileFormat(encoding: .utf16LE, bom: true)).write(to: valid16)
        let utf16 = try TextOpenRequest(address(valid16, nil, nil)).open()
        defer { utf16.close() }
        check(utf16.editor.text == "wide雪", "BOM-marked UTF-16 remains eligible text")
    }

}

/// Only the worker's opened URL crosses this test's file-presenter wait. No UI or callback
/// enters the lock; all mutable state is private and displaced values release after unlock.
private final class FileURLObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    func set(_ next: URL?) {
        lock.lock()
        let displaced = stored
        stored = next
        lock.unlock()
        withExtendedLifetime(displaced) {}
    }
    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
