// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decides which local files a previewed page may load through the preview scheme.
///
/// A page may load stylesheets and images that are inside the folder of its own saved document
/// (subfolders included) and nothing else. The decision is made on the real location of the
/// file, after symbolic links are followed, so a link inside the folder cannot reach outside it.
package struct PreviewResourceResolver: Sendable {
    package enum Denial: Sendable, Equatable {
        /// The document has never been saved, so it has no folder.
        case untitledDocument
        case outsideDocumentFolder
        /// The document is directly in the top folder of the disk or in the home folder itself,
        /// so "the document's folder" would be the whole disk or everything the person owns.
        case documentFolderTooBroad
        case typeNotAllowed
        case tooLarge
        case missing
    }

    package enum Resolution: Sendable, Equatable {
        case allowed(URL, mimeType: String)
        case denied(Denial)
    }

    /// The file types a page may load, by lowercase extension. SVG is served as an image only;
    /// the content security policy refuses it anywhere a document could run.
    package static let mimeTypes: [String: String] = [
        "css": "text/css", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "bmp": "image/bmp", "ico": "image/x-icon",
        "avif": "image/avif", "heic": "image/heic"
    ]

    private let documentURL: URL?
    private let maxBytes: Int
    private let homeDirectory: URL
    private let resolveSymlinks: @Sendable (URL) -> URL
    private let fileSize: @Sendable (URL) -> Int?

    /// - Parameters:
    ///   - documentURL: the saved document's file URL, or nil for an untitled document.
    ///   - homeDirectory: the person's home folder. A document saved directly in it, or directly
    ///     in the top folder of the disk, is served no local file; one in a subfolder is.
    ///   - resolveSymlinks: returns the real location of a file. Injected so tests need no disk.
    ///   - fileSize: the size in bytes of a regular file, or nil when there is no such file.
    package init(
        documentURL: URL?, maxBytes: Int = PreviewLimits.standard.maxResourceBytes,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        resolveSymlinks: @escaping @Sendable (URL) -> URL = { $0.resolvingSymlinksInPath() },
        fileSize: @escaping @Sendable (URL) -> Int? = { PreviewResourceResolver.regularFileSize($0) }
    ) {
        self.documentURL = documentURL
        self.maxBytes = maxBytes
        self.homeDirectory = homeDirectory
        self.resolveSymlinks = resolveSymlinks
        self.fileSize = fileSize
    }

    /// Resolves the path of a requested preview URL, as written in the URL (still
    /// percent-encoded). The path is always relative to the document's folder: a leading slash
    /// does not make it absolute.
    package func resolve(requestPath: String) -> Resolution {
        guard let documentURL, documentURL.isFileURL else { return .denied(.untitledDocument) }
        guard let decoded = requestPath.removingPercentEncoding, !decoded.unicodeScalars.contains("\0") else {
            return .denied(.missing)
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return .denied(.missing) }

        let folder = documentURL.deletingLastPathComponent().standardizedFileURL
        let realFolder = resolveSymlinks(folder).standardizedFileURL
        guard !isTooBroad(folder), !isTooBroad(realFolder) else { return .denied(.documentFolderTooBroad) }
        var requested = folder
        for component in components { requested.appendPathComponent(String(component)) }
        requested = requested.standardizedFileURL
        // First as written, so that "../" is refused without touching the disk.
        guard Self.isInside(requested, folder: folder) else { return .denied(.outsideDocumentFolder) }
        guard Self.mimeTypes[requested.pathExtension.lowercased()] != nil else { return .denied(.typeNotAllowed) }

        // Then where the file really is.
        let realFile = resolveSymlinks(requested).standardizedFileURL
        guard Self.isInside(realFile, folder: realFolder) else { return .denied(.outsideDocumentFolder) }
        guard let mimeType = Self.mimeTypes[realFile.pathExtension.lowercased()] else {
            return .denied(.typeNotAllowed)
        }
        guard let size = fileSize(realFile) else { return .denied(.missing) }
        guard size <= maxBytes else { return .denied(.tooLarge) }
        return .allowed(realFile, mimeType: mimeType)
    }

    /// True for the top folder of the disk and for the home folder itself.
    private func isTooBroad(_ folder: URL) -> Bool {
        let path = Self.withoutTrailingSlash(folder.path)
        if path.isEmpty { return true }
        let home = Self.withoutTrailingSlash(homeDirectory.standardizedFileURL.path)
        let realHome = Self.withoutTrailingSlash(resolveSymlinks(homeDirectory).standardizedFileURL.path)
        return path == home || path == realHome
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : (path == "/" ? "" : path)
    }

    private static func isInside(_ file: URL, folder: URL) -> Bool {
        let folderPath = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return file.path.hasPrefix(folderPath)
    }

    /// The size of the regular file at `url`, or nil for a folder, a special file or no file.
    package static func regularFileSize(_ url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular, let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.intValue
    }
}
