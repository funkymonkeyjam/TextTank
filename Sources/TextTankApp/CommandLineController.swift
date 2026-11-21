import AppKit
import Darwin
import TextTankCore

@MainActor final class CommandLineController: NSObject {
    private let comparison: () -> CompareService?
    private var waiting: [ObjectIdentifier: [TTInvocation]] = [:]
    init(comparison: @escaping () -> CompareService?) {
        self.comparison = comparison
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentChanged(_:)),
            name: .textTankDocumentsDidChange, object: nil)
    }
    @objc private func documentChanged(_ notification: Notification) {
        guard let doc = notification.object as? TextDocument, doc.isClosed else { return }
        for mailbox in waiting.removeValue(forKey: ObjectIdentifier(doc)) ?? [] {
            try? mailbox.report(.closed)
        }
    }
    func accept(_ id: UUID) async {
        var accepted: TTInvocation?
        do {
            let box = try TTInvocation(id: id, create: false)
            guard try box.claim() else { return }
            accepted = box
            guard let data = try box.read(.processing) else {
                throw TTToolError("The command-line request disappeared.")
            }
            let request = try JSONDecoder().decode(TTRequest.self, from: data)
            let doc: TextDocument, wait: Bool
            switch request {
            case .open(let path, let line, let shouldWait):
                doc = try TextOpenRequest(path: path, line: line).open()
                wait = shouldWait
            case .input(let shouldWait):
                let text = try await Task.detached(priority: .userInitiated) {
                    try box.consumeInput()?.withUnsafeBytes(FileCodec.decodeUTF8Content)
                }.value
                guard let text else {
                    throw TTToolError("Standard input must contain valid UTF-8 text.")
                }
                doc = DocumentFactory.makeUntitled(populate: { document in _ = document.editor.replaceSelection(text) })
                wait = shouldWait
            case .difference(let first, let second):
                guard let service = comparison() else { throw TTToolError("Comparison is unavailable.") }
                let a = try TextOpenRequest(path: first, line: nil), b = try TextOpenRequest(path: second, line: nil)
                let original = try TextOpenRequest.localFile(a.file), modified = try TextOpenRequest.localFile(b.file)
                _ = try await service.open(original: .file(original), modified: .file(modified))
                try box.report(.opened)
                return
            }
            if wait && doc.isOpen {
                try box.report(.opened)
                waiting[ObjectIdentifier(doc), default: []].append(box)
            } else {
                try box.report(wait ? .closed : .opened)
            }
        } catch { try? accepted?.report(.failed, error.localizedDescription) }
    }
    static func install(helper: URL, in folder: URL) throws -> URL {
        var st = stat()
        guard helper.isFileURL, FileManager.default.isExecutableFile(atPath: helper.path),
            folder.isFileURL, lstat(folder.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == geteuid()
        else { throw TTToolError("Choose a folder you own and an installed TextTank app containing tt.") }
        let dst = folder.appendingPathComponent("tt")
        if symlink(helper.path, dst.path) == 0 { return dst }
        if errno == EEXIST, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: dst.path),
            URL(fileURLWithPath: target, relativeTo: folder).standardizedFileURL == helper.standardizedFileURL
        {
            return dst
        }
        throw TTToolError("Could not install tt in that folder. Existing files and links are preserved.")
    }
}
