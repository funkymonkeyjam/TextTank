import AppKit
import Darwin

enum TTTool {
    static let usage = "Usage: tt [--wait] [--] file[:line] | tt [--wait] - | tt --diff file1 file2"
    static func parse(_ args: [String], cwd: URL) throws -> TTRequest {
        var rest = args, wait = false
        if rest.first == "--wait" {
            wait = true
            rest.removeFirst()
        }
        func path(_ raw: String) throws -> String {
            guard !raw.isEmpty, !raw.contains("\0") else { throw TTToolError(usage) }
            return URL(fileURLWithPath: raw, relativeTo: cwd).standardizedFileURL.path
        }
        if rest.first == "--diff" {
            guard !wait, rest.count == 3 else { throw TTToolError(usage) }
            return try .difference(first: path(rest[1]), second: path(rest[2]))
        }
        let literal = rest.first == "--"
        if literal { rest.removeFirst() }
        guard rest.count == 1, let arg = rest.first else { throw TTToolError(usage) }
        if !literal && arg == "-" { return .input(wait: wait) }
        guard literal || !arg.hasPrefix("-") else { throw TTToolError(usage) }
        let whole = try path(arg)
        if !FileManager.default.fileExists(atPath: whole), let separator = arg.lastIndex(of: ":") {
            let suffix = arg[arg.index(after: separator)...]
            if !suffix.isEmpty && suffix.utf8.allSatisfy({ (48...57).contains($0) }) {
                guard let line = Int(suffix), line > 0 else { throw TTToolError("Line must be a positive number.") }
                return try .open(path: path(String(arg[..<separator])), line: line, wait: wait)
            }
        }
        return .open(path: whole, line: nil, wait: wait)
    }
    /// The normal executable locates its enclosing application by its resolved executable, whether
    /// it was invoked directly or through the install command's symlink.
    static func application() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else {
            throw TTToolError("The bundled tt could not locate TextTank.")
        }
        let helper = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", let id = Bundle(url: app)?.bundleIdentifier, id == "app.texttank.editor"
        else {
            throw TTToolError("Run the tt inside TextTank.app or install it from the TextTank menu.")
        }
        return app
    }
    @MainActor static func launch(_ target: URL, activate: Bool = true) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        return try await NSWorkspace.shared.openApplication(at: target, configuration: config)
    }
    @MainActor static func execute(
        _ request: TTRequest, stdin: FileHandle,
        send: () async throws -> (pid: Int32, alive: () -> Bool)
    ) async throws {
        let mailbox = try TTInvocation(create: true)
        let wait: Bool
        switch request {
        case .open(_, _, let value): wait = value
        case .difference: wait = false
        case .input(let value):
            wait = value
            try mailbox.publish(.input) { output in
                while let data = try stdin.read(upToCount: 65536), !data.isEmpty { try output.write(contentsOf: data) }
            }
        }
        let encoded = try JSONEncoder().encode(request)
        try mailbox.publish(.request) { try $0.write(contentsOf: encoded) }
        let process = try await send()
        let started = ProcessInfo.processInfo.systemUptime
        var acknowledged = false
        var nextWake = started
        while true {
            let running = process.alive()
            let now = ProcessInfo.processInfo.systemUptime
            if running && !acknowledged && now >= nextWake {
                DistributedNotificationCenter.default().postNotificationName(
                    TTInvocation.wakeName,
                    object: String(process.pid), userInfo: ["request": mailbox.id.uuidString], deliverImmediately: true)
                nextWake = now + 1
            }
            if let data = try mailbox.read(.reply) {
                let reply = try JSONDecoder().decode(TTReply.self, from: data)
                guard reply.pid == process.pid else {
                    throw TTToolError("The reply came from a different TextTank process.")
                }
                switch reply.state {
                case .failed: throw TTToolError(reply.message ?? "TextTank could not complete the request.")
                case .closed: return
                case .opened:
                    if !wait { return }
                    acknowledged = true
                }
            }
            guard running else { throw TTToolError("TextTank quit before confirming this request.") }
            if !acknowledged && ProcessInfo.processInfo.systemUptime - started > 60 {
                throw TTToolError("TextTank did not acknowledge the request within 60 seconds.")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
