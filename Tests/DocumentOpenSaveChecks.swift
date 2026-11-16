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
            edit(wide, "héllo")
            try wide.writeSafely(to: wideURL, ofType: "Plain Text", for: .saveOperation)
            check(
                try Data(contentsOf: wideURL) == (try FileCodec.encode("héllo", format: wideFormat)),
                "a BOM-less UTF-16 file opened by choice saves back without a BOM")
            wide.close()

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
                var seenElsewhere: URL?, seenByWriter: URL?
                document.dependencies.duringWrite = {
                    seenByWriter = document.fileURL
                    let done = DispatchSemaphore(value: 0)
                    let other = Thread {
                        seenElsewhere = document.fileURL
                        done.signal()
                    }
                    other.start()
                    _ = done.wait(timeout: .now() + 5)
                }
                try document.writeSafely(to: url, ofType: "Plain Text", for: .saveOperation)
                document.dependencies.duringWrite = nil
                check(
                    seenByWriter == document.diskURL && seenElsewhere == url && document.fileURL == url,
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
}
