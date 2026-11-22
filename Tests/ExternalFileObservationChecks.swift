import AppKit
import Darwin
import EditorBridge
@testable import TextTankCore
@testable import TextTankRuntime

@MainActor enum ExternalFileObservationChecks {
    static func run(in root: URL) throws {
        try contentCheckBinding(in: root)
        let file = root.appendingPathComponent("observe-cp1252.txt")
        let original = Data([0x80, 0x31])
        try original.write(to: file)
        let doc = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(file), from: file, as: .windows1252, display: false)
        defer { doc.close() }
        let first = try requireValue(doc.presentation, "external file presentation")
        let window = try requireValue(first.hostWindow, "external file parent")
        let delegate = AppDelegate()
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func action() throws -> NSButton {
            try requireValue(
                views(first.presentationRoot).compactMap { $0 as? NSButton }.first {
                    $0.identifier?.rawValue == "status.reloadExternalFile" && !$0.isHidden
                }, "accessible external disk action")
        }
        func activateApp() {
            let previous = NSApp.delegate
            NSApp.delegate = delegate
            defer { NSApp.delegate = previous }
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        }
        func activateTab() { first.host.activate(first, focus: false) }
        func waitForNotice(_ message: String) {
            _ = spinUntil(timeout: 1, message) { doc.externalFile.notice?.contains(message) == true }
        }
        let revision = doc.editor.revision
        _ = doc.editor.setSelectionAnchor(3, caret: 0)
        let started = ProcessInfo.processInfo.systemUptime
        try Data([0x80, 0x32]).write(to: file, options: .atomic)
        activateApp()
        waitForNotice("Changed on disk")
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("EXTERNAL NOTICE seconds \(elapsed)")
        check(
            elapsed < 1 && first.statusText.contains("Changed on disk"),
            "application activation shows changed disk bytes in under one second")
        check(
            doc.editor.text == "€1" && doc.editor.revision == revision && !doc.isDocumentEdited
                && doc.editor.selectionAnchor == 3 && doc.editor.selectionCaret == 0,
            "clean Ask preserves text, revision, selection and save state")
        let tab = first.host.tabStrip
        check(
            views(tab).compactMap { $0 as? NSButton }.contains {
                $0.accessibilityLabel()?.contains("Changed on disk") == true
            }, "tab accessibility announces the disk change")
        let reload = try action()
        check(
            reload.title == "Reload…" && reload.accessibilityLabel() == "Reload changed file from disk",
            "notice supplies a native accessible Reload action")
        reload.performClick(nil)
        _ = spinUntil("explicit CP1252 reload") { doc.editor.text == "€2" && doc.externalFile.notice == nil }
        check(
            doc.format.encoding == .windows1252 && !doc.isDocumentEdited && doc.presentation === first,
            "reload keeps document, presentation and explicit decoder")
        let originalURL = doc.fileURL
        let tabID = try requireValue(first.tabID, "observed tab identity")
        check(first.host.setEditorLayout(.twoColumns), "second editor group for shared notice")
        let cloneID = try requireValue(first.host.openView(tabID, in: .second), "second group presentation")
        let clone = try requireValue(first.host.presentation(for: cloneID), "group clone for changed document")
        _ = doc.editor.replaceSelection("pending")
        let dirtyText = doc.editor.text, dirtyRevision = doc.editor.revision
        try Data([0x80, 0x33]).write(to: file, options: .atomic)
        activateTab()
        waitForNotice("Changed on disk")
        check(
            doc.isDocumentEdited && doc.editor.text == dirtyText && doc.editor.revision == dirtyRevision,
            "tab activation preserves dirty edits and revision")
        check(
            clone.primaryEditor.sharesDocument(with: doc.editor) && clone.statusText.contains("Changed on disk")
                && clone.primaryEditor.text == dirtyText,
            "group clone shares the notice and preserves dirty editor bytes")
        doc.flushRecovery()
        let recoveryURL = TextDocument.recovery.fileURL(for: doc.recoveryID)
        let recoveryBytes = try Data(contentsOf: recoveryURL)
        try Data("{corrupt".utf8).write(to: recoveryURL)
        doc.flushRecovery()
        try FileManager.default.removeItem(at: file)
        activateTab()
        waitForNotice("missing")
        check(
            doc.lastRecoveryError != nil && first.statusText.hasPrefix("⚠︎ Recovery copy not written")
                && clone.statusText.hasPrefix("⚠︎ Recovery copy not written"),
            "disk notice cannot displace an outstanding recovery error in either presentation")
        try recoveryBytes.write(to: recoveryURL)
        doc.flushRecovery()
        try Data([0x80, 0x33]).write(to: file, options: .atomic)
        activateTab()
        waitForNotice("Changed on disk")
        check(
            doc.lastRecoveryError == nil && first.statusText.contains("Changed on disk"),
            "successful recovery restores the standing disk notice")
        try action().performClick(nil)
        let sheet = try requireValue(window.attachedSheet, "dirty reload confirmation sheet")
        let keep = try requireValue(
            views(sheet.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Keep Editing" },
            "keep edits button")
        keep.performClick(nil)
        _ = spinUntil("cancel reload") { window.attachedSheet == nil }
        let diskAfterCancel = try Data(contentsOf: file)
        check(
            try Data(contentsOf: recoveryURL) == recoveryBytes, "Keep Editing preserves the exact pending recovery file"
        )
        check(
            doc.editor.text == dirtyText && doc.isDocumentEdited && doc.fileURL == originalURL
                && diskAfterCancel == Data([0x80, 0x33]),
            "cancel preserves dirty document and external file bytes")
        try action().performClick(nil)
        let confirmed = try requireValue(window.attachedSheet, "second dirty reload sheet")
        let discard = try requireValue(
            views(confirmed.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Discard and Reload" },
            "explicit discard button")
        discard.performClick(nil)
        _ = spinUntil("explicit discard and reload") { doc.editor.text == "€3" && !doc.isDocumentEdited }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        doc.externalFile.readCandidate = { url, limit in
            let data = try WorkspaceStore.captureRegularFile(url, maximumBytes: limit)
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return data
        }
        try Data([0x80, 0x34]).write(to: file, options: .atomic)
        activateTab()
        waitForNotice("Changed on disk")
        try action().performClick(nil)
        _ = spinUntil("reload worker captured offered bytes") { entered.wait(timeout: .now()) == .success }
        let refreshed = DispatchSemaphore(value: 0)
        doc.externalFile.inspect = { url, baseline, known in
            let result = DocumentMonitor.inspect(url, expected: baseline, known: known)
            refreshed.signal()
            return result
        }
        _ = doc.editor.replaceSelection("late edit")
        let lateText = doc.editor.text
        release.signal()
        _ = spinUntil("post-edit fresh inspection after rejected captured reload") {
            refreshed.wait(timeout: .now()) == .success
        }
        check(
            doc.editor.text == lateText && doc.isDocumentEdited,
            "an edit between disk capture and main delivery rejects the old reload")
        check(
            doc.editor.executeCommand(TTEditorCommandIdentifier(rawValue: "undo")) && doc.editor.text == "€3",
            "actual Undo still restores pre-edit text after a rejected reload")
        let originalRead = doc.externalFile.readCandidate
        doc.externalFile.readCandidate = { url, limit in try WorkspaceStore.captureRegularFile(url, maximumBytes: limit)
        }
        activateTab()
        _ = spinUntil("clean refresh after undo") { refreshed.wait(timeout: .now()) == .success }
        // A second atomic replacement after display must be presented again; the old action cannot consume it.
        try Data([0x80, 0x35]).write(to: file, options: .atomic)
        try action().performClick(nil)
        _ = spinUntil("second replacement rejected and reinspected") { refreshed.wait(timeout: .now()) == .success }
        check(
            doc.editor.text == "€3" && !doc.isDocumentEdited,
            "a second external write invalidates the previous Reload action")
        doc.externalFile.readCandidate = originalRead
        let secret = root.appendingPathComponent("other-file.txt")
        try Data("never-follow-this-path".utf8).write(to: secret)
        try FileManager.default.removeItem(at: file)
        activateTab()
        waitForNotice("missing")
        check(
            doc.externalFile.actionTitle == nil && doc.editor.text == "€3",
            "missing file retains editor bytes with no destructive action")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        activateTab()
        waitForNotice("Could not verify")
        check(
            doc.externalFile.actionTitle == nil && doc.editor.text == "€3",
            "a substituted symlink reveals no target contents and offers no reload")

        try FileManager.default.removeItem(at: file)
        try Data([0x80, 0x36]).write(to: file)
        guard chmod(file.path, 0) == 0 else { throw POSIXError(.EACCES) }
        let denied = DocumentMonitor.inspect(file, expected: doc.originalDiskFingerprint)
        _ = chmod(file.path, 0o600)
        if case .unavailable = denied.status {
            check(denied.digest == nil && !denied.readFile, "permission failure does not expose a digest or read bytes")
        } else {
            check(false, "inaccessible file has a distinct unavailable result")
        }

        let utf16 = root.appendingPathComponent("observed-utf16.txt")
        let format = FileFormat(encoding: .utf16LE, bom: false)
        try FileCodec.encode("same", format: format).write(to: utf16)
        let fixed = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(utf16), from: utf16, as: .utf16LE, display: false)
        defer { fixed.close() }
        let fixedView = try requireValue(fixed.presentation, "explicit BOM-less UTF-16 view")
        fixed.editor.readOnly = true
        try FileCodec.encode("next", format: format).write(to: utf16, options: .atomic)
        fixedView.host.activate(fixedView, focus: false)
        _ = spinUntil("read-only UTF-16 change") { fixed.externalFile.actionTitle == "Reload…" }
        let fixedButton = try requireValue(
            views(fixedView.presentationRoot).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "status.reloadExternalFile" && !$0.isHidden
            }, "read-only UTF-16 Reload button")
        fixedButton.performClick(nil)
        _ = spinUntil("read-only explicit reload") { fixed.editor.text == "next" }
        check(
            fixed.editor.readOnly && fixed.format == format && !fixed.isDocumentEdited,
            "BOM-less UTF-16 reload preserves encoding, missing BOM and read-only state")
        try Data([0x61]).write(to: utf16, options: .atomic)
        fixedView.host.activate(fixedView, focus: false)
        _ = spinUntil("invalid UTF-16 notice") { fixed.externalFile.actionTitle == "Reload…" }
        fixedButton.performClick(nil)
        _ = spinUntil("decoding failure explained") { fixedView.statusText.contains("Reload could not be completed") }
        check(
            fixed.editor.text == "next" && fixed.editor.readOnly && !fixed.isDocumentEdited,
            "invalid external bytes cannot replace the editor")
        let gatedURL = root.appendingPathComponent("observed-generation.txt")
        try Data("old".utf8).write(to: gatedURL)
        let gated = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(gatedURL), from: gatedURL, display: false)
        defer { gated.close() }
        let armed = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0),
            next = DispatchSemaphore(value: 0)
        gated.externalFile.inspect = { url, base, known in
            let sample = DocumentMonitor.inspect(url, expected: base, known: known)
            armed.signal()
            _ = resume.wait(timeout: .now() + 5)
            return sample
        }
        try Data("old changed".utf8).write(to: gatedURL, options: .atomic)
        gated.externalFile.check(prioritized: true)
        _ = spinUntil("stale source observed by blocked worker") { armed.wait(timeout: .now()) == .success }
        let other = root.appendingPathComponent("observed-new-name.txt")
        try Data("new binding".utf8).write(to: other)
        gated.fileURL = other
        let captured = try WorkspaceStore.captureRegularFile(other)
        try gated.read(
            captured: captured.data, sample: captured.sample, from: other, ofType: TextDocument.plainTextType)
        gated.externalFile.inspect = { url, base, known in
            let sample = DocumentMonitor.inspect(url, expected: base, known: known)
            next.signal()
            return sample
        }
        for _ in 0..<5 { gated.externalFile.check(prioritized: true) }
        resume.signal()
        _ = spinUntil("pending events trigger a renewed inspection of the rebound file") {
            next.wait(timeout: .now()) == .success
        }
        check(
            gated.externalFile.notice == nil && gated.editor.text == "new binding" && gated.fileURL == other,
            "stale prior pathname and generation cannot publish against the new document baseline")
        try FileManager.default.removeItem(at: other)
        gated.externalFile.check()
        _ = spinUntil("fresh observation on rebound path") { gated.externalFile.notice == "File missing on disk" }
        gated.close()
        check(gated.externalFile.notice == nil && !gated.isOpen, "closing the document retires its shared notice")

        let big = root.appendingPathComponent("observed-large.txt")
        try Data().write(to: big)
        let size = off_t(DocumentMonitor.maximumBytes) + 1
        check(truncate(big.path, size) == 0, "owned oversized regular file")
        let earlier = try WorkspaceStore.sample(
            ofRegularFileAt: big, maximumBytes: Int.max, now: WorkspaceStore.currentSecond() + 60)
        let warm = DocumentMonitor.inspect(big, expected: earlier.digest, known: earlier)
        check(warm.status == .unchanged && !warm.readFile, "settled 33,554,433-byte signature bypasses content reads")
        check(truncate(big.path, size + 1) == 0, "real oversized metadata update")
        let changed = DocumentMonitor.inspect(big, expected: earlier.digest, known: earlier)
        if case .unavailable(let reason) = changed.status {
            check(
                reason.contains("metadata changed") && !changed.readFile && changed.digest == nil,
                "oversized metadata change remains unverified and reads no content")
        } else {
            check(false, "oversized metadata change remains unverified and reads no content")
        }
        let smallURL = root.appendingPathComponent("large-after-open.txt")
        try Data("small".utf8).write(to: smallURL)
        let growing = try DocumentFactory.openCaptured(
            WorkspaceStore.captureRegularFile(smallURL), from: smallURL, display: false)
        defer { growing.close() }
        let growingView = try requireValue(growing.presentation, "initially small document")
        check(truncate(smallURL.path, size) == 0, "external writer extends the open file above the content scan limit")
        growingView.host.activate(growingView, focus: false)
        _ = spinUntil(timeout: 1, "oversized file offers an explicit content check") {
            growing.externalFile.actionTitle == "Check Contents…"
        }
        let review = try requireValue(
            views(growingView.presentationRoot).compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "status.reloadExternalFile" && !$0.isHidden
            }, "oversized file contents action")
        check(
            review.title == "Check Contents…" && growing.editor.text == "small",
            "unverified large file is distinct from a confirmed byte change")
        review.performClick(nil)
        _ = spinUntil("explicit oversized content digest") { growing.externalFile.notice == "Changed on disk" }
        check(
            review.title == "Reload…" && growing.editor.text == "small" && !growing.isDocumentEdited,
            "explicit oversized inspection streams bytes and preserves the editor until a separate Reload")

    }
    private static func contentCheckBinding(in root: URL) throws {
        @MainActor func flatten(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(flatten) }
        @MainActor func create(_ label: String) throws -> (URL, TextDocument, EditorWindowController) {
            let u = root.appendingPathComponent(label + ".txt")
            try Data("old".utf8).write(to: u)
            let d = try DocumentFactory.openCaptured(WorkspaceStore.captureRegularFile(u), from: u, display: false)
            let p = try requireValue(d.presentation, "owned workspace")
            return (u, d, p)
        }
        let big = off_t(DocumentMonitor.maximumBytes) + 1
        for mode in ["same", "rebound", "replacement"] {
            let rebind = mode == "rebound"
            let (old, d, p) = try create("source-" + mode)
            defer { d.close() }
            try require(truncate(old.path, big) == 0, "extend source above passive limit")
            p.host.activate(p, focus: false)
            _ = spinUntil("initial bounded notice") { d.externalFile.actionTitle == "Check Contents…" }
            let button = try requireValue(
                flatten(p.presentationRoot).compactMap { $0 as? NSButton }.first {
                    $0.identifier?.rawValue == "status.reloadExternalFile" && !$0.isHidden
                }, "visible content check")
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            d.externalFile.inspect = { u, b, k in
                let r = DocumentMonitor.inspect(u, expected: b, known: k)
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                return r
            }
            p.host.activate(p, focus: false)
            _ = spinUntil("real passive operation in flight") { started.wait(timeout: .now()) == .success }
            button.performClick(nil)
            if rebind {
                let fresh = root.appendingPathComponent("replacement.txt")
                try Data("new".utf8).write(to: fresh)
                d.fileURL = fresh
                let c = try WorkspaceStore.captureRegularFile(fresh)
                try d.read(captured: c.data, sample: c.sample, from: fresh, ofType: TextDocument.plainTextType)
                try require(truncate(fresh.path, big + 1) == 0, "new pathname now exceeds passive limit")
                d.externalFile.inspect = { DocumentMonitor.inspect($0, expected: $1, known: $2) }
            }
            if mode == "replacement" {
                let newFile = root.appendingPathComponent("same-name-new-inode.txt")
                let originalIdentity = try WorkspaceStore.signature(ofRegularFileAt: old, maximumBytes: Int.max)
                try Data("other".utf8).write(to: newFile)
                try require(truncate(newFile.path, big + 1) == 0, "second inode grows beyond passive limit")
                try require(
                    rename(newFile.path, old.path) == 0, "substitute a different large inode under the same name")
                var beganContentRead = false
                do {
                    _ = try WorkspaceStore.sample(
                        ofRegularFileAt: old, maximumBytes: Int.max, matching: originalIdentity
                    ) {
                        beganContentRead = true
                        return false
                    }
                    check(false, "replaced descriptor must reject superseded content permission")
                } catch WorkspaceError.invalid {
                    check(!beganContentRead, "identity mismatch at the open descriptor rejects before streaming bytes")
                }
                d.externalFile.inspect = { DocumentMonitor.inspect($0, expected: $1, known: $2) }
            }
            release.signal()
            _ = spinUntil("release queued explicit check") {
                guard !d.externalFile.checking else { return false }
                if rebind { return d.externalFile.notice != nil }
                if mode == "replacement" { return d.externalFile.notice?.contains("32 MiB") == true }
                return d.externalFile.actionTitle == "Reload…"
            }
            print(
                "Queued content check", mode, "status", d.externalFile.notice ?? "nil", "action",
                d.externalFile.actionTitle ?? "nil", "editorBytes", d.editor.text)
            if rebind {
                check(
                    d.externalFile.actionTitle == "Check Contents…" && d.editor.text == "new",
                    "a queued explicit content check cannot authorize a different oversized file")
            } else if mode == "replacement" {
                check(
                    d.externalFile.actionTitle == "Check Contents…" && d.editor.text == "old",
                    "same-path replacement needs its own content-check choice")
            } else {
                check(
                    d.externalFile.actionTitle == "Reload…" && d.editor.text == "old",
                    "the explicit check survives coalescing on its original path")
            }
        }
    }
}
