import Foundation
import Darwin

/// Shared by the bundled client and the application. A process-addressed local wake-up contains only the
/// invocation UUID. All message names are fixed leaves under an owner-only transient directory.
enum TTRequest: Codable {
    case open(path: String, line: Int?, wait: Bool)
    case input(wait: Bool)
    case difference(first: String, second: String)
}
struct TTReply: Codable {
    enum State: String, Codable { case opened, closed, failed }
    let state: State
    let pid: Int32
    let message: String?
}
struct TTToolError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
final class TTInvocation: @unchecked Sendable {
    static let wakeName = Notification.Name("app.texttank.editor.commandLineRequest")
    enum Item: String { case request, processing, input, reply }
    let id: UUID
    private let root: URL
    private let directory: Int32
    private let created: Bool
    private static func folder(_ id: UUID) throws -> URL {
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard count > 1 else { throw TTToolError("The current user’s temporary directory is unavailable.") }
        var bytes = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &bytes, count) == count else {
            throw TTToolError("The temporary directory changed.")
        }
        return URL(fileURLWithPath: String(cString: bytes), isDirectory: true)
            .appendingPathComponent("texttank-tt-" + id.uuidString, isDirectory: true)
    }
    init(id: UUID = UUID(), create: Bool) throws {
        self.id = id
        root = try Self.folder(id)
        created = create
        if create && mkdir(root.path, 0o700) != 0 { throw Self.failure("create private request directory") }
        let fd = open(root.path, O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw Self.failure("open private request directory") }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & 0o777 == 0o700 else {
            close(fd)
            throw TTToolError("The command-line request directory is not private to this user.")
        }
        directory = fd
    }
    deinit {
        if created {
            for item in [Item.request, .processing, .reply, .input] { unlinkat(directory, item.rawValue, 0) }
            _ = rmdir(root.path)
        }
        close(directory)
    }
    private static func failure(_ verb: String) -> TTToolError {
        let code = errno
        return TTToolError("Could not " + verb + " (" + String(cString: strerror(code)) + ").")
    }
    func claim() throws -> Bool {
        if renameat(directory, Item.request.rawValue, directory, Item.processing.rawValue) == 0 { return true }
        if errno == ENOENT { return false }
        throw Self.failure("claim the command-line request")
    }
    func read(_ item: Item, limit: Int = 65536) throws -> Data? {
        let fd = openat(directory, item.rawValue, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.failure("read command-line data")
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == geteuid(),
            st.st_mode & 0o777 == 0o600, st.st_size >= 0, st.st_size <= limit
        else { throw TTToolError("Unexpected command-line data file.") }
        var result = Data()
        while let chunk = try file.read(upToCount: 65536), !chunk.isEmpty {
            guard chunk.count <= limit - result.count else {
                throw TTToolError("The command-line request is too large.")
            }
            result.append(chunk)
        }
        return result
    }
    func consumeInput() throws -> Data? {
        guard let data = try read(.input, limit: Int.max) else { return nil }
        guard unlinkat(directory, Item.input.rawValue, 0) == 0 else {
            throw Self.failure("remove private standard input")
        }
        return data
    }
    func publish(_ item: Item, _ write: (FileHandle) throws -> Void) throws {
        let pending = UUID().uuidString
        let fd = openat(directory, pending, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("stage command-line data") }
        defer { unlinkat(directory, pending, 0) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try write(file)
        try file.close()
        guard renameat(directory, pending, directory, item.rawValue) == 0 else {
            throw Self.failure("publish command-line data")
        }
    }
    func report(_ state: TTReply.State, _ message: String? = nil) throws {
        let data = try JSONEncoder().encode(TTReply(state: state, pid: getpid(), message: message))
        try publish(.reply) { try $0.write(contentsOf: data) }
    }
}
