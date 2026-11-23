// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A user's HTML document made ready for the preview web view.
package struct PreparedHTML: Sendable, Equatable {
    /// The document with the content security policy inserted and nothing else changed.
    package var html: String
    package var report: PreviewContentReport
}

package enum HTMLPreparation: Sendable, Equatable {
    case prepared(PreparedHTML)
    case limited(PreviewLimit)
    case cancelled
}

/// The rules that keep previewed HTML static: no scripts, no network, and local files only
/// through the preview scheme. The web view enforces the same rules again (JavaScript disabled,
/// a content rule list, a scheme handler); this type provides the parts that are pure text.
package enum StaticHTMLPolicy {
    /// The content security policy for every previewed page. Images and stylesheets load only
    /// from `scheme`; inline styles are allowed; everything else is refused.
    package static func contentSecurityPolicy(scheme: String = PreviewScheme.name) -> String {
        [
            "default-src 'none'", "img-src \(scheme):", "style-src \(scheme): 'unsafe-inline'", "font-src 'none'",
            "script-src 'none'", "frame-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'"
        ].joined(separator: "; ")
    }

    static func policyTag(scheme: String) -> String {
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy(scheme: scheme))\">"
    }

    /// Wraps body content produced by this module (rendered Markdown, the SVG image wrapper) in a
    /// complete document. `title` is escaped. `stylesheet` is CSS text placed in a `<style>`
    /// element; it comes from the bundled resource, not from the document.
    package static func wrapFragment(
        _ body: String, title: String, stylesheet: String, bodyClass: String? = nil,
        scheme: String = PreviewScheme.name
    ) -> String {
        // "</style" cannot appear in CSS that is meant to stay inside its element.
        let safeStylesheet = stylesheet.replacingOccurrences(of: "</", with: "<\\/")
        let bodyTag = bodyClass.map { "<body class=\"\(HTMLText.escaped($0))\">" } ?? "<body>"
        return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            \(policyTag(scheme: scheme))
            <title>\(HTMLText.escaped(title))</title>
            <style>
            \(safeStylesheet)
            </style>
            </head>
            \(bodyTag)
            \(body)
            </body>
            </html>

            """
    }

    /// Prepares a user's HTML document: inserts the content security policy as the first thing in
    /// `<head>` and reports what the preview will block. The document is not otherwise rewritten.
    ///
    /// When there is no `<head>`, one is added after the `<html>` start tag, or after the doctype,
    /// or at the very start. A policy placed first applies to everything after it.
    package static func prepare(
        html: String, limits: PreviewLimits = .standard, scheme: String = PreviewScheme.name,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> HTMLPreparation {
        let bytes = Array(html.utf8)
        guard bytes.count <= limits.maxSourceBytes else {
            return .limited(.sourceTooLarge(maxBytes: limits.maxSourceBytes))
        }
        var report = PreviewContentReport()
        var endOfHead: Int?
        var endOfHTMLTag: Int?
        var endOfDoctype: Int?
        var tokenizer = MarkupTokenizer(bytes, isXML: false, poll: CancellationPoll(isCancelled))
        do {
            while let token = try tokenizer.next() {
                switch token {
                case .tag(let tag):
                    MarkupScan.note(tag, in: &report)
                    guard !tag.isClosing else { continue }
                    if tag.name == "head", endOfHead == nil { endOfHead = tag.range.upperBound }
                    if tag.name == "html", endOfHTMLTag == nil { endOfHTMLTag = tag.range.upperBound }
                case .rawText(let element, let range):
                    if element == "style" {
                        MarkupScan.noteStyleSheet(String(decoding: bytes[range], as: UTF8.self), in: &report)
                    }
                case .doctype(let range):
                    if endOfDoctype == nil { endOfDoctype = range.upperBound }
                }
            }
        } catch {
            return .cancelled
        }
        let policy = policyTag(scheme: scheme)
        let insertion: (offset: Int, text: String)
        if let endOfHead {
            insertion = (endOfHead, policy)
        } else {
            insertion = (endOfHTMLTag ?? endOfDoctype ?? 0, "<head>" + policy + "</head>")
        }
        var prepared = bytes
        prepared.insert(contentsOf: Array(insertion.text.utf8), at: insertion.offset)
        return .prepared(PreparedHTML(html: String(decoding: prepared, as: UTF8.self), report: report))
    }
}

/// The one-line account of what a preview left out.
package enum PreviewSummary {
    /// Whole sentences separated by spaces, for example "1 external resource was blocked. 2
    /// scripts were not run." Returns nil when every count is zero.
    package static func text(blockedExternalResources: Int, scriptsNotRun: Int, missingLocalFiles: Int) -> String? {
        var sentences: [String] = []
        if blockedExternalResources > 0 {
            sentences.append(
                sentence(
                    blockedExternalResources,
                    one: Strings.text("preview.summary.external.one", "%@ external resource was blocked."),
                    other: Strings.text("preview.summary.external.other", "%@ external resources were blocked.")))
        }
        if scriptsNotRun > 0 {
            sentences.append(
                sentence(
                    scriptsNotRun, one: Strings.text("preview.summary.scripts.one", "%@ script was not run."),
                    other: Strings.text("preview.summary.scripts.other", "%@ scripts were not run.")))
        }
        if missingLocalFiles > 0 {
            sentences.append(
                sentence(
                    missingLocalFiles,
                    one: Strings.text("preview.summary.missing.one", "%@ local file could not be found."),
                    other: Strings.text("preview.summary.missing.other", "%@ local files could not be found.")))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// The summary for a scanned document. `missingLocalFiles` is counted by the scheme handler.
    package static func text(for report: PreviewContentReport, missingLocalFiles: Int = 0) -> String? {
        text(
            blockedExternalResources: report.externalReferences.count, scriptsNotRun: report.scriptCount,
            missingLocalFiles: missingLocalFiles)
    }

    private static func sentence(_ count: Int, one: String, other: String) -> String {
        String(format: count == 1 ? one : other, Strings.number(count))
    }
}

/// What a scan of SVG source found.
package struct SVGInspection: Sendable, Equatable {
    /// True when the first element of the document is `<svg>`.
    package var isSVG: Bool
    package var report: PreviewContentReport
}

package enum SVGScan: Sendable, Equatable {
    case inspected(SVGInspection)
    case limited(PreviewLimit)
    case cancelled
}

/// SVG is shown as an image: the web view loads it through an `<img>` element, which runs no
/// scripts and fetches nothing the image refers to. The scan here only tells the user what the
/// image contains that an image cannot do.
package enum SVGPolicy {
    /// The body class the bundled stylesheet uses to centre a single image.
    package static let bodyClass = "image-preview"

    /// Shown instead of a preview when the document's first element is not `<svg>`.
    package static var notSVGMessage: String {
        Strings.text("preview.svg.notSVG", "This document is not an SVG image.")
    }

    /// A complete page that shows the image at `imageURL`, an address in the preview scheme that
    /// serves the document's current text.
    package static func wrapper(
        imageURL: String, title: String, stylesheet: String = "", scheme: String = PreviewScheme.name
    ) -> String {
        let image = "<img src=\"\(HTMLText.escaped(imageURL))\" alt=\"\(HTMLText.escaped(title))\">"
        return StaticHTMLPolicy.wrapFragment(
            image, title: title, stylesheet: stylesheet, bodyClass: bodyClass, scheme: scheme)
    }

    package static func scan(
        _ svg: String, limits: PreviewLimits = .standard, isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> SVGScan {
        let bytes = Array(svg.utf8)
        guard bytes.count <= limits.maxSourceBytes else {
            return .limited(.sourceTooLarge(maxBytes: limits.maxSourceBytes))
        }
        var report = PreviewContentReport()
        var rootName: String?
        var tokenizer = MarkupTokenizer(bytes, isXML: true, poll: CancellationPoll(isCancelled))
        do {
            while let token = try tokenizer.next() {
                switch token {
                case .tag(let tag):
                    if rootName == nil, !tag.isClosing { rootName = tag.name }
                    MarkupScan.note(tag, in: &report)
                case .rawText(let element, let range):
                    if element == "style" {
                        MarkupScan.noteStyleSheet(String(decoding: bytes[range], as: UTF8.self), in: &report)
                    }
                case .doctype:
                    break
                }
            }
        } catch {
            return .cancelled
        }
        let isSVG = rootName == "svg" || rootName?.hasSuffix(":svg") == true
        return .inspected(SVGInspection(isSVG: isSVG, report: report))
    }
}
