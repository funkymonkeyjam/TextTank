// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TextTankCore

/// Everything one render needs, captured on the main actor and handed to a background task.
/// `source` is the document's unsaved text at `revision`; nothing here refers to a view.
struct PreviewRequest: Sendable {
    var kind: PreviewKind
    var source: Data
    var revision: UInt
    /// The document's display name, used as the page title and the image description.
    var title: String
    /// The text of the bundled stylesheet for rendered Markdown and the image page.
    var stylesheet: String
}

/// A static page for the web presenter, with everything it is served from memory.
struct PreviewPage: Sendable, Equatable {
    /// The path the page is served at. It contains a fresh random token for every render, so a
    /// page from an earlier render cannot address the current one. It ends with a slash: local
    /// files the page refers to are requested below it.
    var pagePath: String
    var html: Data
    /// For SVG: the path and bytes of the image the page shows through `<img>`.
    var imagePath: String?
    var image: Data?
    /// What the source asks for that the preview does not do.
    var report: PreviewContentReport
    /// For rendered Markdown: the source lines of each top-level block, which is each child of
    /// the page's body. Nil for HTML and SVG, which are not followed (docs/preview-model.md).
    var scrollMap: PreviewScrollMap?
    var selectionSource: Data?
}

/// What a preview pane shows after one render.
enum PreviewContent: Sendable, Equatable {
    /// A sentence instead of content: an empty document, a limit, or "not an SVG image".
    case message(String)
    case page(PreviewPage)
    case table(DelimitedTable)
    /// `error` is set when the text is not valid JSON; `tree` then holds what was read before it.
    case tree(JSONTree, error: JSONSyntaxError?, limit: PreviewLimit?)
}

/// Sentences the presentation layer adds to the ones the preview core provides.
enum PreviewMessages {
    static var emptyDocument: String {
        Strings.text("preview.empty", "This document is empty. Type in Source to see its preview here.")
    }
    static var notReady: String {
        Strings.text(
            "preview.web.notReady",
            "The preview is not ready yet. Nothing has been loaded. It appears when its safety rules are in place.")
    }
    static var unavailable: String {
        Strings.text(
            "preview.web.unavailable",
            "The preview cannot be shown because its safety rules could not be prepared. Nothing was loaded. Quit TextTank and open it again to try once more."
        )
    }
    /// The web content process ended twice while it showed the same text.
    static var stoppedRepeatedly: String {
        Strings.text(
            "preview.web.stoppedRepeatedly",
            "The preview stopped twice while showing this document, so it is not shown. The document is not changed. Edit the document to try the preview again."
        )
    }
    static var noLongerPreviewable: String {
        Strings.text(
            "preview.status.notPreviewable",
            "This kind of document has no preview. The tab shows Source again.")
    }
    static func accessibilityLabel(documentName: String) -> String {
        String(format: Strings.text("preview.accessibility.label", "Preview of %@"), documentName)
    }
    /// Local files a page asked for that the preview refused: outside the document's folder,
    /// not a stylesheet or image, or too large.
    static func refusedLocalFiles(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let format =
            count == 1
            ? Strings.text(
                "preview.summary.refused.one",
                "%@ local file was not loaded. Only stylesheets and images in the document's folder are loaded.")
            : Strings.text(
                "preview.summary.refused.other",
                "%@ local files were not loaded. Only stylesheets and images in the document's folder are loaded.")
        return String(format: format, Strings.number(count))
    }
    /// Local files a page asked for while its document has no folder of its own.
    static func broadFolderLocalFiles(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let format =
            count == 1
            ? Strings.text(
                "preview.summary.broadFolder.one",
                "%@ local file was not loaded because this document is saved directly in your home folder or at the top of the disk. Save the document in a folder of its own to load it."
            )
            : Strings.text(
                "preview.summary.broadFolder.other",
                "%@ local files were not loaded because this document is saved directly in your home folder or at the top of the disk. Save the document in a folder of its own to load them."
            )
        return String(format: format, Strings.number(count))
    }
    static func moreQuotingProblems(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let format =
            count == 1
            ? Strings.text("preview.table.moreProblems.one", "%@ more row has a quoting problem.")
            : Strings.text("preview.table.moreProblems.other", "%@ more rows have quoting problems.")
        return String(format: format, Strings.number(count))
    }
    /// Whole sentences joined by spaces, or nil when there is nothing to say.
    static func joined(_ sentences: [String?]) -> String? {
        let present = sentences.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " ")
    }
}

/// Turns a request into content by calling the preview core. A pure function of the request:
/// it reads no file, opens no connection and touches no view, so it runs on any thread.
enum PreviewRenderer {
    /// Returns nil when the calling task was cancelled. Call from `Task.detached`: the core polls
    /// `Task.isCancelled` of the task it runs in.
    static func render(_ request: PreviewRequest) -> PreviewContent? {
        if isBlank(request.source) { return .message(PreviewMessages.emptyDocument) }
        switch request.kind {
        case .markdown: return markdown(request)
        case .html: return html(request)
        case .svg: return svg(request)
        case .delimited(let delimiter): return delimited(request, delimiter: delimiter)
        case .json: return json(request)
        }
    }

    /// The delay between the last edit and the render it causes: 0.2 s for a small document,
    /// growing in proportion to its size up to 1 s at the source limit, so that a large document
    /// is not parsed again for every short pause in typing.
    static func debounceInterval(byteCount: Int, limits: PreviewLimits = .standard) -> TimeInterval {
        let share = min(1, max(0, Double(byteCount) / Double(max(1, limits.maxSourceBytes))))
        return 0.2 + 0.8 * share
    }

    private static func isBlank(_ source: Data) -> Bool {
        !source.contains { !PreviewRenderer.whitespace.contains($0) }
    }
    private static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0x0C]

    private static func pagePath() -> String { "/" + UUID().uuidString.lowercased() + "/" }

    private static func markdown(_ request: PreviewRequest) -> PreviewContent? {
        let (rendering, scrollMap) = MarkdownRenderer.renderWithScrollMap(request.source)
        switch rendering {
        case .cancelled: return nil
        case .limited(let limit): return .message(limit.message)
        case .rendered(let fragment):
            // The fragment holds only tags the renderer wrote. It is scanned for the report alone
            // (remote images); the prepared copy is not used.
            var report = PreviewContentReport()
            switch StaticHTMLPolicy.prepare(html: fragment) {
            case .cancelled: return nil
            case .limited: break
            case .prepared(let prepared): report = prepared.report
            }
            let page = StaticHTMLPolicy.wrapFragment(fragment, title: request.title, stylesheet: request.stylesheet)
            return .page(
                PreviewPage(
                    pagePath: pagePath(), html: Data(page.utf8), report: report, scrollMap: scrollMap,
                    selectionSource: request.source))
        }
    }

    private static func html(_ request: PreviewRequest) -> PreviewContent? {
        switch StaticHTMLPolicy.prepare(html: String(decoding: request.source, as: UTF8.self)) {
        case .cancelled: return nil
        case .limited(let limit): return .message(limit.message)
        case .prepared(let prepared):
            return .page(
                PreviewPage(
                    pagePath: pagePath(), html: Data(prepared.html.utf8), report: prepared.report,
                    selectionSource: request.source))
        }
    }

    private static func svg(_ request: PreviewRequest) -> PreviewContent? {
        switch SVGPolicy.scan(String(decoding: request.source, as: UTF8.self)) {
        case .cancelled: return nil
        case .limited(let limit): return .message(limit.message)
        case .inspected(let inspection):
            guard inspection.isSVG else { return .message(SVGPolicy.notSVGMessage) }
            let path = pagePath()
            // The image has its own token and no folder, so no local file can stand in for it.
            let imagePath = "/" + UUID().uuidString.lowercased() + ".svg"
            let page = SVGPolicy.wrapper(
                imageURL: imagePath, title: request.title, stylesheet: request.stylesheet)
            return .page(
                PreviewPage(
                    pagePath: path, html: Data(page.utf8), imagePath: imagePath, image: request.source,
                    report: inspection.report))
        }
    }

    private static func delimited(_ request: PreviewRequest, delimiter: Character) -> PreviewContent? {
        switch DelimitedTable.parse(request.source, delimiter: delimiter) {
        case .cancelled: return nil
        case .limited(let limit): return .message(limit.message)
        case .parsed(let table): return .table(table)
        }
    }

    private static func json(_ request: PreviewRequest) -> PreviewContent? {
        switch JSONTree.parse(request.source) {
        case .cancelled: return nil
        case .empty: return .message(PreviewMessages.emptyDocument)
        case .parsed(let tree): return .tree(tree, error: nil, limit: nil)
        case .invalid(let partial, let error): return .tree(partial, error: error, limit: nil)
        case .limited(let partial, let limit):
            if partial.root == nil { return .message(limit.message) }
            return .tree(partial, error: nil, limit: limit)
        }
    }
}

/// Source locations for WebKit text do not survive Markdown rendering or HTML parsing. Check
/// candidate byte boundaries by rendering marked source offscreen. Only a mark at the original
/// DOM node and UTF-16 offset can move the editor. The displayed page is never modified.
struct PreviewSelectionProbe: Sendable {
    struct Endpoint: Codable, Sendable {
        var block: Int
        var before: String
        var after: String
    }

    var html: String
    var positions: [Int]

    static func make(_ endpoint: Endpoint, page: PreviewPage, marker: String) -> Self? {
        guard let source = page.selectionSource else { return nil }
        let scope: Range<Int>
        if let blocks = page.scrollMap?.blocks {
            guard blocks.indices.contains(endpoint.block), let bytes = blocks[endpoint.block].sourceBytes
            else { return nil }
            scope = bytes
        } else {
            scope = source.startIndex..<source.endIndex
        }
        // Markdown bounds are per block. Never give WebKit a large synchronous second parse.
        guard scope.count <= 512 * 1024, !Task.isCancelled else { return nil }
        let left = Data(endpoint.before.utf8), right = Data(endpoint.after.utf8)
        var candidates = Set<Int>()
        func find(_ needle: Data, offset: Int) {
            guard !needle.isEmpty else { return }
            var remaining = scope, found: [Int] = []
            while let hit = source.range(of: needle, in: remaining) {
                found.append(hit.lowerBound + offset)
                guard found.count <= 128 else { return }
                remaining = hit.lowerBound + 1..<scope.upperBound
            }
            candidates.formUnion(found)
        }
        find(left + right, offset: left.count)
        if candidates.isEmpty {
            find(left, offset: left.count)
            find(right, offset: 0)
            // Entities, escapes and normalized line endings can break both longer contexts.
            for n in [8, 1] where candidates.isEmpty {
                let suffix = String(String.UnicodeScalarView(endpoint.before.unicodeScalars.suffix(n)))
                let prefix = String(String.UnicodeScalarView(endpoint.after.unicodeScalars.prefix(n)))
                find(Data(suffix.utf8), offset: suffix.utf8.count)
                find(Data(prefix.utf8), offset: 0)
            }
        }
        // A visible character can stand for a whole reference (&amp; or &#x1f642;).
        // The marker proof below decides whether either end actually produced the selection.
        if let ampersand = source[scope].firstIndex(of: 38) {
            var references: [Int] = []
            var i = ampersand
            while i < scope.upperBound {
                if source[i] == 38 {
                    var j = i + 1
                    while j < min(scope.upperBound, i + 34) {
                        let b = source[j]
                        if b == 59 {
                            // A mark inside an entity would turn it into different visible text.
                            for position in (i + 1)...j { candidates.remove(position) }
                            references.append(contentsOf: [i, j + 1])
                            break
                        }
                        guard (48...57).contains(b) || (65...90).contains(b) || (97...122).contains(b) || b == 35 else {
                            break
                        }
                        j += 1
                    }
                    if references.count > 128 { references.removeLast(2) }
                }
                i += 1
            }
            candidates.formUnion(references)
        }
        guard !candidates.isEmpty, candidates.count <= 512, !Task.isCancelled else { return nil }
        let positions =
            page.scrollMap == nil
            ? StaticHTMLPolicy.textBoundaries(candidates.sorted(), in: source) : candidates.sorted()
        guard !positions.isEmpty else { return nil }
        var marked = Data(), start = scope.lowerBound
        for (index, position) in positions.enumerated() {
            marked.append(source[start..<position])
            marked.append(contentsOf: (marker + String(index) + "Z").utf8)
            start = position
        }
        marked.append(source[start..<scope.upperBound])
        if let map = page.scrollMap {
            guard case .rendered(let fragment) = MarkdownRenderer.renderSelectionBlock(marked, using: map),
                fragment.utf8.count <= 512 * 1024
            else { return nil }
            return Self(html: fragment, positions: positions)
        }
        return Self(html: String(decoding: marked, as: UTF8.self), positions: positions)
    }
}
