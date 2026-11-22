import AppKit
@main enum TTMain {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--help"] {
                print(TTTool.usage)
                return
            }
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let request = try TTTool.parse(args, cwd: cwd)
            try await TTTool.execute(request, stdin: .standardInput) {
                let app = try await TTTool.launch(TTTool.application())
                return (app.processIdentifier, { !app.isTerminated })
            }
        } catch {
            FileHandle.standardError.write(Data(("tt: " + error.localizedDescription + "\n").utf8))
            exit(EXIT_FAILURE)
        }
    }
}
