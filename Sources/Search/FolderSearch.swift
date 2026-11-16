// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NativeSearch
import Darwin
import CryptoKit

package struct SearchSpan: Equatable, Codable, Sendable {
    package init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    package let location: Int
    package let length: Int
}
package struct FolderSearchRequest: Sendable {
    package init(
        directory: URL, query: String, matchCase: Bool = true, mode: SearchOptions.Mode = .normal,
        wholeWord: Bool = false, dotMatchesNewline: Bool = false, recursive: Bool = true, includeHidden: Bool = false,
        extensions: Set<String> = [], filenameFilters: String = "*.*", excludingSearchedFiles: Set<String> = [],
        displayTabWidth: Int = 4, maximumFiles: Int = 10000, maximumEntries: Int = 100000,
        maximumFileBytes: Int = 32 * 1024 * 1024, maximumTotalBytes: Int = 256 * 1024 * 1024,
        maximumResults: Int = 10000, previewUTF16Length: Int = 240, listsPolicyExclusions: Bool = false
    ) {
        self.directory = directory
        self.query = query
        self.matchCase = matchCase
        self.mode = mode
        self.wholeWord = wholeWord
        self.dotMatchesNewline = dotMatchesNewline
        self.recursive = recursive
        self.includeHidden = includeHidden
        self.extensions = extensions
        self.filenameFilters = filenameFilters
        self.excludingSearchedFiles = excludingSearchedFiles
        self.displayTabWidth = displayTabWidth
        self.maximumFiles = maximumFiles
        self.maximumEntries = maximumEntries
        self.maximumFileBytes = maximumFileBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumResults = maximumResults
        self.previewUTF16Length = previewUTF16Length
        self.listsPolicyExclusions = listsPolicyExclusions
    }

    package var directory: URL
    package let query: String
    package var matchCase: Bool
    package var mode: SearchOptions.Mode
    package var wholeWord: Bool
    package var dotMatchesNewline: Bool
    package var recursive: Bool
    package var includeHidden: Bool
    /// Exact filename extensions, without dots; empty searches all regular files.
    package var extensions: Set<String>
    package var filenameFilters: String
    /// Canonical file paths already searched by another explicit root.
    package var excludingSearchedFiles: Set<String>
    /// Captured presentation setting only; never changes matching or byte/UTF-16 navigation.
    package var displayTabWidth: Int
    package var maximumFiles: Int
    package var maximumEntries: Int
    package var maximumFileBytes: Int
    package var maximumTotalBytes: Int
    package var maximumResults: Int
    package var previewUTF16Length: Int
    /// Also list every policy exclusion in `FolderSearchReport.skipped`, for checks and
    /// diagnostics. Off by default: a filtered dependency folder then costs one counter per
    /// reason, not up to `maximumEntries` list entries.
    package var listsPolicyExclusions: Bool
}
package struct FolderSearchMatch: Equatable, Sendable {
    package init(
        url: URL, line: Int, columnUTF16: Int, utf16Range: SearchSpan, utf8Range: SearchSpan, preview: String,
        previewMatchRange: SearchSpan, isMatchTruncatedInPreview: Bool, sourceSHA256: String? = nil,
        sourceRoot: URL? = nil, displayColumn: Int = 1, displayTabWidth: Int = 4
    ) {
        self.url = url
        self.line = line
        self.columnUTF16 = columnUTF16
        self.utf16Range = utf16Range
        self.utf8Range = utf8Range
        self.preview = preview
        self.previewMatchRange = previewMatchRange
        self.isMatchTruncatedInPreview = isMatchTruncatedInPreview
        self.sourceSHA256 = sourceSHA256
        self.sourceRoot = sourceRoot
        self.displayColumn = displayColumn
        self.displayTabWidth = displayTabWidth
    }

    package let url: URL
    /// One-based line and UTF-16 column, with CRLF counted as one line ending.
    package let line: Int
    package let columnUTF16: Int
    /// Offsets refer to decoded editor text, not original encoded/BOM file bytes.
    package let utf16Range: SearchSpan
    package let utf8Range: SearchSpan
    package let preview: String
    package let previewMatchRange: SearchSpan
    package let isMatchTruncatedInPreview: Bool
    package var sourceSHA256: String?
    package var sourceRoot: URL?
    package var displayColumn: Int
    package var displayTabWidth: Int
}
package enum FolderSearchSkipReason: Hashable, Sendable {
    case symbolicLink, hidden, nonRecursiveDirectory, extensionFiltered, filenameFiltered, folderFiltered,
        duplicateScope, notRegularFile, fileTooLarge
    /// A recovery copy, journal or temporary file written by folder replacement.
    case recoveryArtifact
    case invalidEncoding(String), unreadable(String)
    /// True when the entry was meant to be searched and was not, which makes coverage incomplete.
    /// Every other reason is a policy exclusion the request asked for.
    package var affectsCoverage: Bool {
        switch self {
        case .invalidEncoding, .unreadable, .fileTooLarge: return true
        default: return false
        }
    }
    /// Policy exclusions in the order they are summarised.
    static package let policyExclusions: [FolderSearchSkipReason] = [
        .filenameFiltered, .extensionFiltered, .folderFiltered, .hidden, .symbolicLink, .nonRecursiveDirectory,
        .duplicateScope, .notRegularFile, .recoveryArtifact
    ]
    /// Wording for the results window.
    package var explanation: String {
        switch self {
        case .symbolicLink: return "symbolic link"
        case .hidden: return "hidden"
        case .nonRecursiveDirectory: return "subfolder (subfolders are off)"
        case .extensionFiltered: return "extension filter"
        case .filenameFiltered: return "filename filter"
        case .folderFiltered: return "folder filter"
        case .duplicateScope: return "already searched under another folder"
        case .notRegularFile: return "not a regular file"
        case .recoveryArtifact: return "TextTank recovery copy"
        case .fileTooLarge: return "larger than the per-file limit"
        case .invalidEncoding(let detail): return "not valid text: \(detail)"
        case .unreadable(let detail): return detail
        }
    }
}
package struct FolderSearchSkipped: Equatable, Sendable {
    package init(url: URL, reason: FolderSearchSkipReason) {
        self.url = url
        self.reason = reason
    }

    package let url: URL
    package let reason: FolderSearchSkipReason
}
package enum FolderSearchLimit: String, Sendable {
    case entries, files, totalBytes, results
    package var displayName: String {
        switch self {
        case .entries: return Strings.text("folder.limit.entries", "entries visited")
        case .files: return Strings.text("folder.limit.files", "files considered")
        case .totalBytes: return Strings.text("folder.limit.bytes", "total data read")
        case .results: return Strings.text("folder.limit.results", "search results")
        }
    }
}
package struct FolderSearchReport: Sendable {
    package init(
        matches: [FolderSearchMatch] = [], skipped: [FolderSearchSkipped] = [],
        excludedCounts: [FolderSearchSkipReason: Int] = [:], entriesVisited: Int = 0, filesConsidered: Int = 0,
        filesSearched: Int = 0, bytesRead: Int = 0, searchedFiles: Set<String> = [], wasCancelled: Bool = false,
        reachedLimit: FolderSearchLimit? = nil
    ) {
        self.matches = matches
        self.skipped = skipped
        self.excludedCounts = excludedCounts
        self.entriesVisited = entriesVisited
        self.filesConsidered = filesConsidered
        self.filesSearched = filesSearched
        self.bytesRead = bytesRead
        self.searchedFiles = searchedFiles
        self.wasCancelled = wasCancelled
        self.reachedLimit = reachedLimit
    }

    package var matches: [FolderSearchMatch]
    /// Entries that should have been searched and were not. Policy exclusions are listed here
    /// only when the request sets `listsPolicyExclusions`; they are always counted below.
    package var skipped: [FolderSearchSkipped]
    /// How many entries each policy exclusion left out.
    package var excludedCounts: [FolderSearchSkipReason: Int]
    package var excludedTotal: Int { excludedCounts.values.reduce(0, +) }
    /// Entries in `skipped` that make coverage incomplete.
    package var notSearched: [FolderSearchSkipped] { skipped.filter { $0.reason.affectsCoverage } }
    mutating package func skip(_ url: URL, _ reason: FolderSearchSkipReason, listing: Bool) {
        if !reason.affectsCoverage { excludedCounts[reason, default: 0] += 1 }
        if reason.affectsCoverage || listing { skipped.append(.init(url: url, reason: reason)) }
    }
    package var entriesVisited: Int
    package var filesConsidered: Int
    package var filesSearched: Int
    package var bytesRead: Int
    package var searchedFiles: Set<String>
    package var wasCancelled: Bool
    package var reachedLimit: FolderSearchLimit?
    /// Policy exclusions are expected; unreadable/oversized files make coverage incomplete.
    package var isComplete: Bool {
        !wasCancelled && reachedLimit == nil && !skipped.contains { $0.reason.affectsCoverage }
    }
}
package struct FolderSearchProgress: Sendable {
    package init(filesSearched: Int, bytesRead: Int, matches: Int, currentURL: URL) {
        self.filesSearched = filesSearched
        self.bytesRead = bytesRead
        self.matches = matches
        self.currentURL = currentURL
    }

    package let filesSearched: Int
    package let bytesRead: Int
    package let matches: Int
    package let currentURL: URL
}
/// The engine token is an atomic flag, so it is the only cancellation state.
final package class FolderSearchCancellation: @unchecked Sendable {
    package init() {}

    package let engineToken = TTSearchCancellation()
    package func cancel() { engineToken.cancel() }
    package var isCancelled: Bool { engineToken.cancelled }
}
package enum FolderSearchError: LocalizedError {
    case invalidRequest(String)
    package var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): return reason
        }
    }
}

/// Read-only normal, extended and Boost snapshot search. Disk replacement and glob
/// syntax are separate capabilities; no automatic legacy-encoding guessing.
/// Foundation case-insensitive literal matching is explicitly a Mac behavior here.
/// Cancellation is cooperative between bounded reads and during scalar mapping;
/// FileCodec decode and Foundation literal matching finish their current operation
/// first. A default-limit 32 MiB decode can delay cancellation by about two seconds.
/// Progress executes on the background worker; UI consumers must dispatch to MainActor.
package enum FolderSearch {
    static package func search(
        _ request: FolderSearchRequest, cancellation: FolderSearchCancellation = FolderSearchCancellation(),
        progress: (@Sendable (FolderSearchProgress) -> Void)? = nil
    ) async throws -> FolderSearchReport {
        if Task.isCancelled { cancellation.cancel() }
        let work = Task.detached(priority: .userInitiated) {
            try run(request, filters: try validate(request), cancellation: cancellation, progress: progress)
        }
        return try await withTaskCancellationHandler(
            operation: { try await work.value }, onCancel: { cancellation.cancel() })
    }
    /// One root of a request that `validate` has already accepted.
    private static func searchValidated(
        _ request: FolderSearchRequest, filters: FolderSearchFilters, cancellation: FolderSearchCancellation,
        progress: (@Sendable (FolderSearchProgress) -> Void)?
    ) async throws -> FolderSearchReport {
        let work = Task.detached(priority: .userInitiated) {
            try run(request, filters: filters, cancellation: cancellation, progress: progress)
        }
        return try await withTaskCancellationHandler(
            operation: { try await work.value }, onCancel: { cancellation.cancel() })
    }
    /// Saved folder roots share one global work/result budget. Overlapping roots
    /// retain union semantics even when parent filters/hidden policies skip children.
    static package func searchAcross(
        _ template: FolderSearchRequest, directories: [URL],
        cancellation: FolderSearchCancellation = FolderSearchCancellation(),
        progress: (@Sendable (FolderSearchProgress) -> Void)? = nil
    ) async throws -> FolderSearchReport {
        guard !directories.isEmpty, directories.count <= 100 else {
            throw FolderSearchError.invalidRequest("Choose between one and 100 workspace folders.")
        }
        // Filters are parsed and the expression is compiled once for all roots, off the caller's
        // thread. An error here is the whole search's error, not one unreadable root each.
        let filters = try await Task.detached(priority: .userInitiated) { try validate(template) }.value
        var report = FolderSearchReport(), roots: [URL] = []
        for directory in directories {
            if cancellation.isCancelled || Task.isCancelled {
                report.wasCancelled = true
                return report
            }
            guard directory.isFileURL, !directory.path.contains("\0"),
                (directory.host ?? "").isEmpty || directory.host == "localhost"
            else { throw FolderSearchError.invalidRequest("Workspace search roots must be local directories.") }
            let canonical: URL
            do {
                let opened = try openCanonicalDirectory(directory)
                close(opened.fd)
                canonical = URL(fileURLWithPath: opened.path, isDirectory: true)
            } catch CanonicalDirectoryFailure.unresolved {
                report.skipped.append(
                    .init(url: directory, reason: .unreadable("Workspace root could not be resolved.")))
                continue
            } catch {
                report.skipped.append(
                    .init(url: directory, reason: .unreadable("Workspace root is unavailable or is a symbolic link.")))
                continue
            }
            if !roots.contains(canonical) { roots.append(canonical) }
        }
        roots.sort { $0.path.count == $1.path.count ? $0.path < $1.path : $0.path.count < $1.path.count }
        // Every explicit root has its own root-relative folder filters. Do not
        // collapse child roots: even an unfiltered parent may skip a hidden root.
        for root in roots {
            if cancellation.isCancelled || Task.isCancelled {
                report.wasCancelled = true
                break
            }
            var request = template
            request.directory = root
            request.excludingSearchedFiles.formUnion(report.searchedFiles)
            request.maximumFiles = template.maximumFiles - report.filesConsidered
            request.maximumEntries = template.maximumEntries - report.entriesVisited
            request.maximumTotalBytes = template.maximumTotalBytes - report.bytesRead
            request.maximumResults = template.maximumResults - report.matches.count
            if request.maximumFiles <= 0 {
                report.reachedLimit = .files
                break
            }
            if request.maximumEntries <= 0 {
                report.reachedLimit = .entries
                break
            }
            if request.maximumTotalBytes <= 0 {
                report.reachedLimit = .totalBytes
                break
            }
            if request.maximumResults <= 0 {
                report.reachedLimit = .results
                break
            }
            let baseline = report
            do {
                let part = try await searchValidated(
                    request, filters: filters, cancellation: cancellation,
                    progress: { p in
                        progress?(
                            .init(
                                filesSearched: baseline.filesSearched + p.filesSearched,
                                bytesRead: baseline.bytesRead + p.bytesRead,
                                matches: baseline.matches.count + p.matches, currentURL: p.currentURL))
                    })
                report.matches += part.matches
                report.skipped += part.skipped
                report.excludedCounts.merge(part.excludedCounts, uniquingKeysWith: +)
                report.entriesVisited += part.entriesVisited
                report.filesConsidered += part.filesConsidered
                report.filesSearched += part.filesSearched
                report.bytesRead += part.bytesRead
                report.searchedFiles.formUnion(part.searchedFiles)
                report.wasCancelled = part.wasCancelled
                report.reachedLimit = part.reachedLimit
                if report.wasCancelled || report.reachedLimit != nil { break }
            } catch { report.skipped.append(.init(url: root, reason: .unreadable(error.localizedDescription))) }
        }
        report.matches.sort {
            $0.url.path == $1.url.path ? $0.utf16Range.location < $1.utf16Range.location : $0.url.path < $1.url.path
        }
        return report
    }
    /// Why a search root could not be opened and resolved.
    package enum CanonicalDirectoryFailure: Error {
        case unavailable(POSIXErrorCode), unresolved(POSIXErrorCode)
        package var posix: POSIXError {
            switch self {
            case .unavailable(let code), .unresolved(let code): return POSIXError(code)
            }
        }
    }
    /// Opens a directory, refusing a symbolic link as the directory itself, and asks the kernel
    /// for its canonical path. The caller closes the descriptor. Search, workspace search and
    /// replacement all anchor their descriptor walks to this one result.
    static package func openCanonicalDirectory(_ directory: URL) throws -> (fd: Int32, path: String) {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CanonicalDirectoryFailure.unavailable(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw CanonicalDirectoryFailure.unresolved(code)
        }
        return (fd, String(cString: path))
    }
    /// The components of `path` below `prefix` (which ends in "/"), compared and split as UTF-8
    /// bytes, which is what the kernel resolves. Characters must not be used here: a combining
    /// mark at the start of a name fuses with the "/" before it. Nil when the path is not below
    /// the prefix or a component is empty of meaning (".", "..") or holds NUL.
    static package func relativeComponents(of path: String, under prefix: String) -> [String]? {
        guard prefix.utf8.last == 0x2F, path.utf8.starts(with: prefix.utf8) else { return nil }
        let components = path.utf8.dropFirst(prefix.utf8.count).split(separator: 0x2F).map {
            String(decoding: $0, as: UTF8.self)
        }
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            return nil
        }
        return components
    }
    /// Names folder replacement gives its own files. They are never search results or
    /// replacement targets, whatever the hidden-file setting.
    static package let recoveryArtifactPrefixes = [".texttank-backup-", ".texttank-replacement-", ".texttank-report-"]
    static package func isRecoveryArtifact(_ name: String) -> Bool {
        recoveryArtifactPrefixes.contains { name.utf8.starts(with: $0.utf8) }
    }
    static package func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func searchOptions(_ request: FolderSearchRequest) -> SearchOptions {
        var options = SearchOptions()
        options.query = request.query
        options.mode = request.mode
        options.matchCase = request.matchCase
        options.wholeWord = request.wholeWord
        options.dotMatchesNewline = request.dotMatchesNewline
        return options
    }
    /// Line, column and UTF-8 span of each match, in one forward pass. Nil when `stop` answers
    /// true or a range is out of order, outside the text or splits a character; the caller then
    /// skips this one file. Ranges must be ascending, as the engine reports them.
    static package func located(_ ranges: [NSRange], in text: String, tabWidth: Int = 4, stop: () -> Bool) -> [(
        line: Int, columnUTF16: Int, utf8Range: SearchSpan, displayColumn: Int
    )]? {
        var cursor = SearchCore.UTFCursor(text, tracksLines: true, tabWidth: tabWidth)
        var output: [(line: Int, columnUTF16: Int, utf8Range: SearchSpan, displayColumn: Int)] = []
        output.reserveCapacity(ranges.count)
        for range in ranges {
            guard range.location >= 0, range.length >= 0, range.length <= Int.max - range.location,
                cursor.advance(to: range.location, stop: stop)
            else { return nil }
            let startByte = cursor.byteOffset, line = cursor.line, column = cursor.columnUTF16,
                displayColumn = cursor.displayColumn
            guard cursor.advance(to: NSMaxRange(range), stop: stop) else { return nil }
            output.append(
                (line, column, .init(location: startByte, length: cursor.byteOffset - startByte), displayColumn))
        }
        return output
    }
    /// Validates the request and returns its parsed filters. The expression is compiled here, on
    /// empty text, so one that cannot compile is a single error before any file is read.
    @discardableResult private static func validate(_ request: FolderSearchRequest) throws -> FolderSearchFilters {
        guard request.directory.isFileURL,
            (request.directory.host ?? "").isEmpty || request.directory.host == "localhost",
            !request.directory.path.contains("\0"), !request.query.isEmpty
        else { throw FolderSearchError.invalidRequest("Choose a local directory and nonempty search expression.") }
        guard request.maximumFiles > 0, request.maximumEntries > 0, request.maximumFileBytes > 0,
            request.maximumTotalBytes > 0, request.maximumResults > 0, (1...32).contains(request.displayTabWidth),
            (16...8192).contains(request.previewUTF16Length)
        else {
            throw FolderSearchError.invalidRequest(
                "Search limits must be positive and preview length must be 16–8192 UTF-16 units.")
        }
        let filters = try FolderSearchFilters(request.filenameFilters)
        guard
            request.extensions.allSatisfy({
                !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") && !$0.contains(".")
            })
        else {
            throw FolderSearchError.invalidRequest(
                "Extension filters must be exact extensions without dots or path separators.")
        }
        // A fresh token: the caller's may already be cancelled, and a cancelled search reports
        // cancellation, not an invalid request.
        do {
            _ = try SearchCore.search(
                "", options: searchOptions(request), cancellation: TTSearchCancellation(), limit: 1)
        } catch { throw FolderSearchError.invalidRequest(error.localizedDescription) }
        return filters
    }
    private static func run(
        _ request: FolderSearchRequest, filters: FolderSearchFilters, cancellation: FolderSearchCancellation,
        progress: (@Sendable (FolderSearchProgress) -> Void)?
    ) throws -> FolderSearchReport {
        // Normalize platform aliases only after rejecting a symlink root itself.
        let rootFD: Int32, root: URL
        do {
            let opened = try openCanonicalDirectory(request.directory)
            rootFD = opened.fd
            root = URL(fileURLWithPath: opened.path, isDirectory: true)
        } catch let failure as CanonicalDirectoryFailure { throw failure.posix }
        defer { close(rootFD) }
        let listing = request.listsPolicyExclusions, options = searchOptions(request)
        var report = FolderSearchReport()
        if cancellation.isCancelled {
            report.wasCancelled = true
            return report
        }
        var enumerationErrors: [FolderSearchSkipped] = []
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .isHiddenKey, .fileSizeKey
        ]
        guard
            let iterator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys), options: [],
                errorHandler: { url, error in
                    enumerationErrors.append(
                        FolderSearchSkipped(url: url, reason: .unreadable(error.localizedDescription)))
                    return !cancellation.isCancelled
                })
        else { throw FolderSearchError.invalidRequest("The selected directory could not be enumerated.") }
        let extensionFilter = Set(request.extensions.map { $0.lowercased() })
        searchLoop: while let url = iterator.nextObject() as? URL {
            if cancellation.isCancelled {
                report.wasCancelled = true
                break
            }
            if report.entriesVisited >= request.maximumEntries {
                report.reachedLimit = .entries
                break
            }
            report.entriesVisited += 1
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: keys) } catch {
                report.skip(url, .unreadable(error.localizedDescription), listing: listing)
                continue
            }
            if values.isSymbolicLink == true {
                report.skip(url, .symbolicLink, listing: listing)
                continue
            }
            if values.isDirectory != true && isRecoveryArtifact(url.lastPathComponent) {
                report.skip(url, .recoveryArtifact, listing: listing)
                continue
            }
            if !request.includeHidden && (values.isHidden == true || url.lastPathComponent.hasPrefix(".")) {
                if values.isDirectory == true { iterator.skipDescendants() }
                report.skip(url, .hidden, listing: listing)
                continue
            }
            if values.isDirectory == true {
                let depth = url.pathComponents.count - root.pathComponents.count
                if filters.excludesFolder(url.lastPathComponent, depth: depth) {
                    iterator.skipDescendants()
                    report.skip(url, .folderFiltered, listing: listing)
                    continue
                }
                if !request.recursive {
                    iterator.skipDescendants()
                    report.skip(url, .nonRecursiveDirectory, listing: listing)
                }
                continue
            }
            guard values.isRegularFile == true else {
                report.skip(url, .notRegularFile, listing: listing)
                continue
            }
            if !filters.acceptsFile(url.lastPathComponent) {
                report.skip(url, .filenameFiltered, listing: listing)
                continue
            }
            if !extensionFilter.isEmpty && !extensionFilter.contains(url.pathExtension.lowercased()) {
                report.skip(url, .extensionFiltered, listing: listing)
                continue
            }
            if request.excludingSearchedFiles.contains(url.path) {
                report.skip(url, .duplicateScope, listing: listing)
                continue
            }
            if report.filesConsidered >= request.maximumFiles {
                report.reachedLimit = .files
                break
            }
            report.filesConsidered += 1
            if (values.fileSize ?? 0) > request.maximumFileBytes {
                report.skip(url, .fileTooLarge, listing: listing)
                continue
            }
            let remaining = request.maximumTotalBytes - report.bytesRead
            if remaining <= 0 || (values.fileSize ?? 0) > remaining {
                report.reachedLimit = .totalBytes
                break
            }
            let bytes: Data
            do {
                bytes = try readFile(
                    url, root: root, rootFD: rootFD, maximumBytes: min(request.maximumFileBytes, remaining),
                    cancellation: cancellation, onBytes: { report.bytesRead += $0 })
            } catch ReadFailure.cancelled {
                report.wasCancelled = true
                break
            } catch ReadFailure.tooLarge {
                if remaining < request.maximumFileBytes {
                    report.reachedLimit = .totalBytes
                    break
                }
                report.skip(url, .fileTooLarge, listing: listing)
                continue
            } catch {
                report.skip(url, .unreadable(error.localizedDescription), listing: listing)
                continue
            }
            let decoded: DecodedFile
            do { decoded = try FileCodec.decode(bytes) } catch {
                report.skip(url, .invalidEncoding(error.localizedDescription), listing: listing)
                continue
            }
            if cancellation.isCancelled {
                report.wasCancelled = true
                break
            }
            report.filesSearched += 1
            report.searchedFiles.insert(url.path)
            let fingerprint = sha256Hex(bytes)
            let text = decoded.text as NSString
            let hits: SearchReport
            do {
                hits = try SearchCore.search(
                    decoded.text, options: options, cancellation: cancellation.engineToken,
                    limit: min(100000, request.maximumResults - report.matches.count))
            } catch {
                if cancellation.isCancelled {
                    report.wasCancelled = true
                    break
                }
                report.skip(url, .unreadable("Search: " + error.localizedDescription), listing: listing)
                continue
            }
            // One bad range fails this file only, as a failed search of it does, and before any
            // of its matches is listed. The engine never reports one; this keeps it that way.
            guard
                let positions = located(
                    hits.hits.map(\.range), in: decoded.text, tabWidth: request.displayTabWidth,
                    stop: { cancellation.isCancelled })
            else {
                if cancellation.isCancelled {
                    report.wasCancelled = true
                    break searchLoop
                }
                report.skip(
                    url, .unreadable("Search: matching produced a range that is not on character boundaries."),
                    listing: listing)
                continue
            }
            for (hit, position) in zip(hits.hits, positions) {
                if cancellation.isCancelled {
                    report.wasCancelled = true
                    break searchLoop
                }
                let match = hit.range
                let snippet = preview(text, match: match, maximum: request.previewUTF16Length)
                report.matches.append(
                    .init(
                        url: url, line: position.line, columnUTF16: position.columnUTF16,
                        utf16Range: .init(location: match.location, length: match.length),
                        utf8Range: position.utf8Range, preview: snippet.text, previewMatchRange: snippet.range,
                        isMatchTruncatedInPreview: snippet.truncated, sourceSHA256: fingerprint, sourceRoot: root,
                        displayColumn: position.displayColumn, displayTabWidth: request.displayTabWidth))
                if report.matches.count >= request.maximumResults {
                    report.reachedLimit = .results
                    break searchLoop
                }
            }
            progress?(
                .init(
                    filesSearched: report.filesSearched, bytesRead: report.bytesRead, matches: report.matches.count,
                    currentURL: url))
        }
        if cancellation.isCancelled { report.wasCancelled = true }
        report.skipped.append(contentsOf: enumerationErrors)
        report.matches.sort {
            $0.url.path == $1.url.path ? $0.utf16Range.location < $1.utf16Range.location : $0.url.path < $1.url.path
        }
        return report
    }
    private enum ReadFailure: LocalizedError {
        case cancelled, tooLarge, notRegular, invalidRelativePath, changed
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Search cancelled."
            case .tooLarge: return "File exceeds the configured read limit."
            case .notRegular: return "The entry is not a regular file."
            case .invalidRelativePath: return "The entry is outside the selected directory."
            case .changed: return "File changed while being read; retry to search its new contents."
            }
        }
    }
    /// Open each relative directory component with O_NOFOLLOW, anchored to the chosen
    /// root descriptor. A renamed/symlink-swapped descendant cannot escape the scope.
    private static func readFile(
        _ url: URL, root: URL, rootFD: Int32, maximumBytes: Int, cancellation: FolderSearchCancellation,
        onBytes: (Int) -> Void
    ) throws -> Data {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let components = relativeComponents(of: url.path, under: prefix) else {
            throw ReadFailure.invalidRelativePath
        }
        var directoryFD = dup(rootFD)
        guard directoryFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directoryFD) }
        for component in components.dropLast() {
            let next = openat(directoryFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(directoryFD)
            directoryFD = next
        }
        let fd = openat(directoryFD, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ReadFailure.notRegular }
        guard info.st_size >= 0, info.st_size <= maximumBytes else { throw ReadFailure.tooLarge }
        var result = Data()
        while result.count < Int(info.st_size) {
            if cancellation.isCancelled { throw ReadFailure.cancelled }
            let chunk = try handle.read(upToCount: min(64 * 1024, Int(info.st_size) - result.count)) ?? Data()
            if chunk.isEmpty { throw ReadFailure.changed }
            result.append(chunk)
            onBytes(chunk.count)
        }
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec
        else { throw ReadFailure.changed }
        return result
    }
    private static func preview(_ text: NSString, match: NSRange, maximum: Int) -> (
        text: String, range: SearchSpan, truncated: Bool
    ) {
        var start = max(0, match.location - min(80, maximum / 3))
        if start > 0 && (0xDC00...0xDFFF).contains(text.character(at: start)) { start -= 1 }
        var end = min(text.length, start + maximum)
        if end < text.length && end > start && (0xDC00...0xDFFF).contains(text.character(at: end)) { end -= 1 }
        let matchedEnd = min(end, NSMaxRange(match))
        return (
            text.substring(with: NSRange(location: start, length: end - start)),
            .init(location: match.location - start, length: max(0, matchedEnd - match.location)),
            NSMaxRange(match) > end
        )
    }
}
