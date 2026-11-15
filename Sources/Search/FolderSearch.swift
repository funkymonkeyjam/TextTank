// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import CryptoKit

struct SearchSpan: Equatable, Codable, Sendable {
    let location: Int
    let length: Int
}
struct FolderSearchRequest: Sendable {
    var directory: URL
    let query: String
    var matchCase = true
    var mode: SearchOptions.Mode = .normal
    var wholeWord = false
    var dotMatchesNewline = false
    var recursive = true
    var includeHidden = false
    /// Exact filename extensions, without dots; empty searches all regular files.
    var extensions: Set<String> = []
    var filenameFilters = "*.*"
    /// Canonical file paths already searched by another explicit root.
    var excludingSearchedFiles: Set<String> = []
    var maximumFiles = 10000
    var maximumEntries = 100000
    var maximumFileBytes = 32 * 1024 * 1024
    var maximumTotalBytes = 256 * 1024 * 1024
    var maximumResults = 10000
    var previewUTF16Length = 240
}
struct FolderSearchMatch: Equatable, Sendable {
    let url: URL
    /// One-based line and UTF-16 column, with CRLF counted as one line ending.
    let line: Int
    let columnUTF16: Int
    /// Offsets refer to decoded editor text, not original encoded/BOM file bytes.
    let utf16Range: SearchSpan
    let utf8Range: SearchSpan
    let preview: String
    let previewMatchRange: SearchSpan
    let isMatchTruncatedInPreview: Bool
    var sourceSHA256: String? = nil
    var sourceRoot: URL? = nil
}
enum FolderSearchSkipReason: Equatable, Sendable {
    case symbolicLink, hidden, nonRecursiveDirectory, extensionFiltered, filenameFiltered, folderFiltered,
        duplicateScope, notRegularFile, fileTooLarge
    case invalidEncoding(String), unreadable(String)
}
struct FolderSearchSkipped: Equatable, Sendable {
    let url: URL
    let reason: FolderSearchSkipReason
}
enum FolderSearchLimit: String, Sendable { case entries, files, totalBytes, results }
struct FolderSearchReport: Sendable {
    var matches: [FolderSearchMatch] = []
    var skipped: [FolderSearchSkipped] = []
    var entriesVisited = 0
    var filesConsidered = 0
    var filesSearched = 0
    var bytesRead = 0
    var searchedFiles: Set<String> = []
    var wasCancelled = false
    var reachedLimit: FolderSearchLimit?
    /// Policy exclusions are expected; unreadable/oversized files make coverage incomplete.
    var isComplete: Bool {
        !wasCancelled && reachedLimit == nil
            && !skipped.contains { item in
                switch item.reason {
                case .invalidEncoding, .unreadable, .fileTooLarge: return true
                default: return false
                }
            }
    }
}
struct FolderSearchProgress: Sendable {
    let filesSearched: Int
    let bytesRead: Int
    let matches: Int
    let currentURL: URL
}
final class FolderSearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let engineToken = TTSearchCancellation()
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        engineToken.cancel()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
enum FolderSearchError: LocalizedError {
    case invalidRequest(String)
    var errorDescription: String? {
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
enum FolderSearch {
    static func search(
        _ request: FolderSearchRequest, cancellation: FolderSearchCancellation = FolderSearchCancellation(),
        progress: (@Sendable (FolderSearchProgress) -> Void)? = nil
    ) async throws -> FolderSearchReport {
        if Task.isCancelled { cancellation.cancel() }
        let work = Task.detached(priority: .userInitiated) {
            try run(request, cancellation: cancellation, progress: progress)
        }
        return try await withTaskCancellationHandler(
            operation: { try await work.value }, onCancel: { cancellation.cancel() })
    }
    /// Saved folder roots share one global work/result budget. Overlapping roots
    /// retain union semantics even when parent filters/hidden policies skip children.
    static func searchAcross(
        _ template: FolderSearchRequest, directories: [URL],
        cancellation: FolderSearchCancellation = FolderSearchCancellation(),
        progress: (@Sendable (FolderSearchProgress) -> Void)? = nil
    ) async throws -> FolderSearchReport {
        guard !directories.isEmpty, directories.count <= 100 else {
            throw FolderSearchError.invalidRequest("Choose between one and 100 workspace folders.")
        }
        try validate(template)
        _ = try FolderSearchFilters(template.filenameFilters)
        var report = FolderSearchReport(), roots: [URL] = []
        for directory in directories {
            if cancellation.isCancelled || Task.isCancelled {
                report.wasCancelled = true
                return report
            }
            guard directory.isFileURL, !directory.path.contains("\0"),
                (directory.host ?? "").isEmpty || directory.host == "localhost"
            else { throw FolderSearchError.invalidRequest("Workspace search roots must be local directories.") }
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else {
                report.skipped.append(
                    .init(url: directory, reason: .unreadable("Workspace root is unavailable or is a symbolic link.")))
                continue
            }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let result = fcntl(fd, F_GETPATH, &path)
            close(fd)
            guard result == 0 else {
                report.skipped.append(
                    .init(url: directory, reason: .unreadable("Workspace root could not be resolved.")))
                continue
            }
            let canonical = URL(fileURLWithPath: String(cString: path), isDirectory: true)
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
                let part = try await search(
                    request, cancellation: cancellation,
                    progress: { p in
                        progress?(
                            .init(
                                filesSearched: baseline.filesSearched + p.filesSearched,
                                bytesRead: baseline.bytesRead + p.bytesRead,
                                matches: baseline.matches.count + p.matches, currentURL: p.currentURL))
                    })
                report.matches += part.matches
                report.skipped += part.skipped
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
    private static func validate(_ request: FolderSearchRequest) throws {
        guard request.directory.isFileURL,
            (request.directory.host ?? "").isEmpty || request.directory.host == "localhost",
            !request.directory.path.contains("\0"), !request.query.isEmpty
        else { throw FolderSearchError.invalidRequest("Choose a local directory and nonempty search expression.") }
        guard request.maximumFiles > 0, request.maximumEntries > 0, request.maximumFileBytes > 0,
            request.maximumTotalBytes > 0, request.maximumResults > 0, (16...8192).contains(request.previewUTF16Length)
        else {
            throw FolderSearchError.invalidRequest(
                "Search limits must be positive and preview length must be 16–8192 UTF-16 units.")
        }
        _ = try FolderSearchFilters(request.filenameFilters)
        guard
            request.extensions.allSatisfy({
                !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") && !$0.contains(".")
            })
        else {
            throw FolderSearchError.invalidRequest(
                "Extension filters must be exact extensions without dots or path separators.")
        }
    }
    private static func run(
        _ request: FolderSearchRequest, cancellation: FolderSearchCancellation,
        progress: (@Sendable (FolderSearchProgress) -> Void)?
    ) throws -> FolderSearchReport {
        try validate(request)
        let filters = try FolderSearchFilters(request.filenameFilters)
        let rootFD = open(request.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(rootFD) }
        // Normalize platform aliases only after rejecting a symlink root itself.
        var canonicalPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(rootFD, F_GETPATH, &canonicalPath) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let root = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
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
                report.skipped.append(.init(url: url, reason: .unreadable(error.localizedDescription)))
                continue
            }
            if values.isSymbolicLink == true {
                report.skipped.append(.init(url: url, reason: .symbolicLink))
                continue
            }
            if !request.includeHidden && (values.isHidden == true || url.lastPathComponent.hasPrefix(".")) {
                if values.isDirectory == true { iterator.skipDescendants() }
                report.skipped.append(.init(url: url, reason: .hidden))
                continue
            }
            if values.isDirectory == true {
                let depth = url.pathComponents.count - root.pathComponents.count
                if filters.excludesFolder(url.lastPathComponent, depth: depth) {
                    iterator.skipDescendants()
                    report.skipped.append(.init(url: url, reason: .folderFiltered))
                    continue
                }
                if !request.recursive {
                    iterator.skipDescendants()
                    report.skipped.append(.init(url: url, reason: .nonRecursiveDirectory))
                }
                continue
            }
            guard values.isRegularFile == true else {
                report.skipped.append(.init(url: url, reason: .notRegularFile))
                continue
            }
            if !filters.acceptsFile(url.lastPathComponent) {
                report.skipped.append(.init(url: url, reason: .filenameFiltered))
                continue
            }
            if !extensionFilter.isEmpty && !extensionFilter.contains(url.pathExtension.lowercased()) {
                report.skipped.append(.init(url: url, reason: .extensionFiltered))
                continue
            }
            if request.excludingSearchedFiles.contains(url.path) {
                report.skipped.append(.init(url: url, reason: .duplicateScope))
                continue
            }
            if report.filesConsidered >= request.maximumFiles {
                report.reachedLimit = .files
                break
            }
            report.filesConsidered += 1
            if (values.fileSize ?? 0) > request.maximumFileBytes {
                report.skipped.append(.init(url: url, reason: .fileTooLarge))
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
                report.skipped.append(.init(url: url, reason: .fileTooLarge))
                continue
            } catch {
                report.skipped.append(.init(url: url, reason: .unreadable(error.localizedDescription)))
                continue
            }
            let decoded: DecodedFile
            do { decoded = try FileCodec.decode(bytes) } catch {
                report.skipped.append(.init(url: url, reason: .invalidEncoding(error.localizedDescription)))
                continue
            }
            if cancellation.isCancelled {
                report.wasCancelled = true
                break
            }
            report.filesSearched += 1
            report.searchedFiles.insert(url.path)
            let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let text = decoded.text as NSString
            var cursor = UTFPositionCursor(decoded.text)
            var options = SearchOptions()
            options.query = request.query
            options.mode = request.mode
            options.matchCase = request.matchCase
            options.wholeWord = request.wholeWord
            options.dotMatchesNewline = request.dotMatchesNewline
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
                report.skipped.append(.init(url: url, reason: .unreadable("Search: " + error.localizedDescription)))
                continue
            }
            for hit in hits.hits {
                if cancellation.isCancelled {
                    report.wasCancelled = true
                    break searchLoop
                }
                let match = hit.range
                guard cursor.advance(to: match.location, cancellation: cancellation) else {
                    if cancellation.isCancelled {
                        report.wasCancelled = true
                        break searchLoop
                    }
                    throw FolderSearchError.invalidRequest("Matching produced an invalid Unicode range.")
                }
                let startByte = cursor.byteOffset, line = cursor.line, column = cursor.columnUTF16
                guard cursor.advance(to: NSMaxRange(match), cancellation: cancellation) else {
                    if cancellation.isCancelled {
                        report.wasCancelled = true
                        break searchLoop
                    }
                    throw FolderSearchError.invalidRequest("Matching split a Unicode character.")
                }
                let snippet = preview(text, match: match, maximum: request.previewUTF16Length)
                report.matches.append(
                    .init(
                        url: url, line: line, columnUTF16: column,
                        utf16Range: .init(location: match.location, length: match.length),
                        utf8Range: .init(location: startByte, length: cursor.byteOffset - startByte),
                        preview: snippet.text, previewMatchRange: snippet.range,
                        isMatchTruncatedInPreview: snippet.truncated, sourceSHA256: fingerprint, sourceRoot: root))
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
        guard url.path.hasPrefix(prefix) else { throw ReadFailure.invalidRelativePath }
        let components = String(url.path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != ".." && $0 != "." && !$0.contains("\0") }) else {
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
    /// Monotonic matches permit streaming scalar conversion: no full UTF-16-to-byte
    /// table and no repeated whole-buffer prefix copies for each result.
    private struct UTFPositionCursor {
        let text: String
        var index: String.UnicodeScalarView.Index
        var utf16Offset = 0
        var byteOffset = 0
        var line = 1
        var columnUTF16 = 1
        init(_ text: String) {
            self.text = text
            index = text.unicodeScalars.startIndex
        }
        mutating func advance(to target: Int, cancellation: FolderSearchCancellation) -> Bool {
            var count = 0
            guard target >= utf16Offset else { return false }
            while utf16Offset < target && index < text.unicodeScalars.endIndex {
                if count % 4096 == 0 && cancellation.isCancelled { return false }
                count += 1
                let scalar = text.unicodeScalars[index], value = scalar.value
                let width = value > 0xFFFF ? 2 : 1
                if utf16Offset + width > target { return false }
                let next = text.unicodeScalars.index(after: index)
                utf16Offset += width
                byteOffset += value < 0x80 ? 1 : (value < 0x800 ? 2 : (value < 0x10000 ? 3 : 4))
                if value == 10
                    || (value == 13 && (next == text.unicodeScalars.endIndex || text.unicodeScalars[next].value != 10))
                {
                    line += 1
                    columnUTF16 = 1
                } else {
                    columnUTF16 += width
                }
                index = next
            }
            return utf16Offset == target
        }
    }
}
