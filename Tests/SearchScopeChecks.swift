import Foundation
@main struct SearchScopeChecks {
    static func main() async {
        await Checks.run("SearchScopeChecks") {
            let all = try FolderSearchFilters("")
            check(
                all.acceptsFile("README") && all.acceptsFile("file.txt"),
                "blank filters include extensionless and dotted files")
            let selected = try FolderSearchFilters("*.txt *.SWIFT !*Tests*; !secret*")
            check(
                selected.acceptsFile("Main.swift") && selected.acceptsFile("readme.TXT")
                    && !selected.acceptsFile("MainTests.swift") && !selected.acceptsFile("secret.txt")
                    && !selected.acceptsFile("image.png"), "case-insensitive includes and precedence of excludes")
            let only = try FolderSearchFilters("!*.log")
            check(
                only.acceptsFile("README") && !only.acceptsFile("debug.LOG"),
                "exclude-only filters implicitly include all files")
            let dirs = try FolderSearchFilters("*.* !\\tests !+\\build*")
            check(
                dirs.excludesFolder("tests", depth: 1) && !dirs.excludesFolder("tests", depth: 2)
                    && dirs.excludesFolder("build64", depth: 4), "root-only and recursive directory exclusions")
            check(
                try FolderSearchFilters("\"my file?.txt\"").acceptsFile("my file1.txt"),
                "quoted filename with question wildcard")
            check(
                FolderSearchFilters.matches("abXYZcd", "a*?cd") && !FolderSearchFilters.matches("acd", "a?cd"),
                "wildcard suffix and required character")
            for malformed in ["!", "!\\", "a/b", "\"unclosed"] {
                var refused = false
                do { _ = try FolderSearchFilters(malformed) } catch { refused = true }
                check(refused, "malformed filter rejected: \(malformed)")
            }
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TextTankScope-" + UUID().uuidString)
            let root = base.appendingPathComponent("one"), other = base.appendingPathComponent("two")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            for file in [
                "top.txt", "README", "ignore.log", "tests/skip.txt", "src/nested.txt", "src/tests/keep.txt",
                "build/skip.txt", "src/build/skip.txt"
            ] {
                let url = root.appendingPathComponent(file)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("needle".utf8).write(to: url)
            }
            try Data("needle".utf8).write(to: other.appendingPathComponent("extra.txt"))
            var request = FolderSearchRequest(directory: root, query: "needle")
            request.filenameFilters = "*.* !*.log !\\tests !+\\build"
            let found = try await FolderSearch.search(request)
            check(
                Set(found.matches.map { $0.url.lastPathComponent }) == ["top.txt", "README", "nested.txt", "keep.txt"],
                "filter categories control actual traversal")
            check(
                found.skipped.contains { $0.reason == .folderFiltered }
                    && found.skipped.contains { $0.reason == .filenameFiltered },
                "filter exclusions reported explicitly")
            check(found.isComplete, "intentional filters retain complete-search status")
            let multiple = try await FolderSearch.searchAcross(
                request, directories: [other, root, root, root.appendingPathComponent("src")])
            check(
                multiple.matches.count == 5 && Set(multiple.matches.map { $0.url }).count == 5,
                "workspace roots union deduplicates overlapping files")
            check(
                multiple.matches.allSatisfy { $0.sourceRoot != nil },
                "matches retain opened root identity for safe replacement")
            let explicitChild = try await FolderSearch.searchAcross(
                request, directories: [root, root.appendingPathComponent("tests")])
            check(
                explicitChild.matches.count == 5
                    && explicitChild.matches.contains { $0.url.lastPathComponent == "skip.txt" },
                "explicit child survives parent root-only folder exclusion")
            let childRelative = try await FolderSearch.searchAcross(
                request, directories: [root, root.appendingPathComponent("src")])
            check(
                childRelative.matches.count == 4 && childRelative.filesSearched == 4,
                "root-relative filters union without duplicate file reads")
            let hiddenRoot = root.appendingPathComponent(".hidden")
            try FileManager.default.createDirectory(at: hiddenRoot, withIntermediateDirectories: true)
            try Data("needle".utf8).write(to: hiddenRoot.appendingPathComponent("hidden-child.txt"))
            let explicitHidden = try await FolderSearch.searchAcross(request, directories: [root, hiddenRoot])
            check(
                explicitHidden.matches.count == 5
                    && explicitHidden.matches.contains { $0.url.lastPathComponent == "hidden-child.txt" },
                "explicit hidden root survives parent hidden exclusion")
            request.maximumResults = 2
            let limited = try await FolderSearch.searchAcross(request, directories: [root, other])
            check(
                limited.matches.count == 2 && limited.reachedLimit == .results,
                "workspace result budget shared across roots")
            request.maximumResults = 100
            request.recursive = false
            let flat = try await FolderSearch.searchAcross(
                request, directories: [root, root.appendingPathComponent("src")])
            check(flat.matches.count == 3, "nonrecursive roots preserve explicitly chosen child scope")
            let unavailable = try await FolderSearch.searchAcross(
                request, directories: [other, base.appendingPathComponent("missing")])
            check(
                unavailable.matches.count == 1 && !unavailable.isComplete
                    && unavailable.skipped.contains {
                        if case .unreadable = $0.reason { return true }
                        return false
                    }, "unavailable workspace root explicit while independent root searched")
            let suite = "TextTankSearchSettings-" + UUID().uuidString
            let isolated = UserDefaults(suiteName: suite)!
            defer { isolated.removePersistentDomain(forName: suite) }
            var settings = FolderSearchSettings()
            settings.folder = root
            settings.workspaceScope = true
            settings.filters = "*.txt !+\\build"
            settings.extensions = "txt"
            settings.includeHidden = true
            settings.recursive = false
            settings.options.query = "(needle)"
            settings.options.replacement = "$1!"
            settings.options.mode = .regularExpression
            settings.options.wholeWord = true
            try settings.save(isolated)
            check(
                try FolderSearchSettings.load(isolated) == settings,
                "versioned settings roundtrip every control without starting search")
            let corrupted = Data("invalid".utf8)
            isolated.set(corrupted, forKey: "TextTank.FolderSearch.v1")
            var refused = false
            do { _ = try FolderSearchSettings.load(isolated) } catch { refused = true }
            check(
                refused && isolated.data(forKey: "TextTank.FolderSearch.v1") == corrupted,
                "invalid settings rejected and original data untouched")
            Checks.summary { "PASS SearchScopeChecks: \(Checks.count) assertions" }
        }
    }
}
