// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

/// The read-only preview of one tab: a slim message row above one presenter.
///
/// The pane owns the three presenters and makes each on first use: a web view for Markdown,
/// HTML and SVG, a table for delimited text, an outline for JSON. It shows whatever
/// `PreviewContent` it is given and keeps showing it until it is given the next, so the last
/// good rendering stays in place while a new one is being made. It holds no document state.
@MainActor final class PreviewPane: NSView {
    /// Below this width the Go to Error button goes under the sentence instead of beside it, so
    /// that the sentence keeps the width of the pane (DS-67).
    static let stackedMessageWidth: CGFloat = 320

    /// Announced when it changes (DS-72): what the preview left out, or what is wrong.
    let messageLabel = AnnouncingLabel(wrappingLabelWithString: "")
    let goToErrorButton = NSButton(title: "", target: nil, action: nil)
    /// The sentence shown in place of content: an empty document, a limit, "not an SVG image".
    let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let messageRow = NSStackView()
    private let separator = NSBox()
    private let contentHost = NSView()

    private(set) var webPresenter: PreviewWebPresenter?
    private(set) var tablePresenter: PreviewTablePresenter?
    private(set) var outlinePresenter: PreviewOutlinePresenter?

    /// Selects the place of a JSON error in the source.
    var onGoToError: ((JSONSyntaxError) -> Void)?
    /// Undo or Redo was chosen while the preview had the keyboard focus; it applies to the document.
    var onDocumentCommand: ((String) -> Void)?
    /// What was showing was lost (the web content process ended) and must be rendered again.
    var onContentLost: (() -> Void)?

    /// Where Tab goes from the table, the tree or the page: the tab's source editor.
    weak var keyViewAfterPreview: NSView? {
        didSet { connectKeyViews() }
    }

    private func connectKeyViews() {
        for view in [tablePresenter?.tableView, outlinePresenter?.outlineView, webPresenter?.focusView] {
            view?.nextKeyView = keyViewAfterPreview
        }
    }

    private var syntaxError: JSONSyntaxError?
    private weak var presented: NSView?
    private var accessibilityName = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.isSelectable = true
        messageLabel.identifier = .init("preview.message")
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        goToErrorButton.title = Strings.text("preview.json.goToError", "Go to Error")
        goToErrorButton.bezelStyle = .rounded
        goToErrorButton.controlSize = .small
        goToErrorButton.target = self
        goToErrorButton.action = #selector(goToError(_:))
        goToErrorButton.identifier = .init("preview.goToError")
        goToErrorButton.setAccessibilityLabel(
            Strings.text("preview.json.goToError.label", "Go to the JSON error in the source"))
        goToErrorButton.setContentHuggingPriority(.required, for: .horizontal)
        goToErrorButton.isHidden = true

        messageRow.orientation = .horizontal
        messageRow.alignment = .firstBaseline
        messageRow.spacing = 8
        messageRow.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        messageRow.addArrangedSubview(messageLabel)
        messageRow.addArrangedSubview(goToErrorButton)
        messageRow.isHidden = true
        separator.boxType = .separator
        separator.isHidden = true

        explanationLabel.alignment = .center
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.isSelectable = true
        explanationLabel.identifier = .init("preview.explanation")
        explanationLabel.isHidden = true

        let column = NSStackView(views: [messageRow, separator, contentHost])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        for view in [column, explanationLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(column)
        contentHost.addSubview(explanationLabel)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            separator.widthAnchor.constraint(equalTo: column.widthAnchor),
            contentHost.widthAnchor.constraint(equalTo: column.widthAnchor),
            explanationLabel.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            explanationLabel.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 24),
            explanationLabel.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -24)
        ])
        contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// True when the message row puts the button under the sentence: there is a button and the
    /// pane is narrower than `stackedMessageWidth`.
    static func stacksMessage(width: CGFloat, hasButton: Bool) -> Bool {
        hasButton && width < stackedMessageWidth
    }

    /// Beside each other the button has a fixed width and the sentence is squeezed to what is
    /// left, which at the narrowest pane is nothing. Under that width the two are stacked and
    /// the sentence may use more lines.
    private func arrangeMessageRow() {
        let stacked = Self.stacksMessage(width: bounds.width, hasButton: !goToErrorButton.isHidden)
        let orientation: NSUserInterfaceLayoutOrientation = stacked ? .vertical : .horizontal
        // Set only on a change: each of these asks for another layout pass.
        guard messageRow.orientation != orientation else {
            if stacked, messageLabel.preferredMaxLayoutWidth != messageWidthWhenStacked {
                messageLabel.preferredMaxLayoutWidth = messageWidthWhenStacked
            }
            return
        }
        messageRow.orientation = orientation
        messageRow.alignment = stacked ? .leading : .firstBaseline
        messageLabel.maximumNumberOfLines = stacked ? 6 : 3
        messageLabel.preferredMaxLayoutWidth = stacked ? messageWidthWhenStacked : 0
    }

    private var messageWidthWhenStacked: CGFloat {
        max(0, bounds.width - messageRow.edgeInsets.left - messageRow.edgeInsets.right)
    }

    override func layout() {
        arrangeMessageRow()
        super.layout()
    }

    // MARK: Showing content

    /// Shows one render's content. `documentURL` is where the document is saved, or nil; a page
    /// may load stylesheets and images from that folder only.
    func show(_ content: PreviewContent, documentURL: URL?) {
        syntaxError = nil
        switch content {
        case .message(let sentence):
            let isNew = explanation != sentence
            present(nil)
            explanationLabel.stringValue = sentence
            explanationLabel.isHidden = false
            // The sentence is the whole content of the pane, so it is announced like a message.
            if isNew { Announce.say(sentence, from: window) }
        case .page(let page):
            let presenter = webPresenter ?? makeWebPresenter()
            present(presenter.view)
            presenter.show(page, documentURL: documentURL)
        case .table(let table):
            let presenter = tablePresenter ?? makeTablePresenter()
            present(presenter.scrollView)
            presenter.show(table)
            setMessage(PreviewTablePresenter.summary(of: table))
        case .tree(let tree, let error, let limit):
            let presenter = outlinePresenter ?? makeOutlinePresenter()
            present(presenter.scrollView)
            presenter.show(tree)
            syntaxError = error
            setMessage(PreviewOutlinePresenter.summary(error: error, limit: limit))
        }
        goToErrorButton.isHidden = syntaxError == nil
        needsLayout = true
        passFocusToPresenter()
    }

    /// While the pane showed only a sentence it held the keyboard itself. Once a presenter is
    /// showing, the keyboard belongs to it, so that arrow keys scroll and select.
    private func passFocusToPresenter() {
        connectKeyViews()
        guard let window, window.firstResponder === self, focusView !== self else { return }
        window.makeFirstResponder(focusView)
    }

    /// Makes `view` the one presenter that is visible, or none.
    private func present(_ view: NSView?) {
        explanationLabel.isHidden = true
        // A message belongs to the presenter that was showing; another presenter starts without one.
        if presented !== view { setMessage(nil) }
        presented = view
        for candidate in [webPresenter?.view, tablePresenter?.scrollView, outlinePresenter?.scrollView] {
            candidate?.isHidden = candidate !== view
        }
    }

    private func host(_ view: NSView) {
        view.frame = contentHost.bounds
        view.autoresizingMask = [.width, .height]
        contentHost.addSubview(view, positioned: .below, relativeTo: explanationLabel)
    }

    private func makeWebPresenter() -> PreviewWebPresenter {
        let presenter = PreviewWebPresenter()
        presenter.setAccessibilityName(accessibilityName)
        presenter.onSummaryChanged = { [weak self, weak presenter] summary in
            guard let self, let presenter, presenter.view.isHidden == false else { return }
            self.setMessage(summary)
        }
        presenter.onUnavailable = { [weak self, weak presenter] sentence in
            guard let self, let presenter, presenter.view.isHidden == false else { return }
            let isNew = sentence != nil && self.explanation != sentence
            self.explanationLabel.stringValue = sentence ?? ""
            self.explanationLabel.isHidden = sentence == nil
            // Like `.message`: the sentence stands in place of the page, so it is announced (DS-72).
            if isNew, let sentence { Announce.say(sentence, from: self.window) }
        }
        presenter.onContentLost = { [weak self] in self?.onContentLost?() }
        presenter.onWebViewCreated = { [weak self] in self?.passFocusToPresenter() }
        host(presenter.view)
        webPresenter = presenter
        return presenter
    }

    private func makeTablePresenter() -> PreviewTablePresenter {
        let presenter = PreviewTablePresenter()
        presenter.tableView.setAccessibilityLabel(accessibilityName)
        host(presenter.scrollView)
        tablePresenter = presenter
        return presenter
    }

    private func makeOutlinePresenter() -> PreviewOutlinePresenter {
        let presenter = PreviewOutlinePresenter()
        presenter.outlineView.setAccessibilityLabel(accessibilityName)
        host(presenter.scrollView)
        outlinePresenter = presenter
        return presenter
    }

    /// The message row is hidden when there is nothing to say (DS-10).
    private func setMessage(_ sentence: String?) {
        let text = sentence ?? ""
        if messageLabel.stringValue != text { messageLabel.stringValue = text }
        messageLabel.toolTip = text.isEmpty ? nil : text
        messageRow.isHidden = text.isEmpty
        separator.isHidden = text.isEmpty
    }

    /// The message row's text, or nil when the row is hidden.
    var message: String? { messageRow.isHidden ? nil : messageLabel.stringValue }
    /// The sentence shown instead of content, or nil when content is shown.
    var explanation: String? { explanationLabel.isHidden ? nil : explanationLabel.stringValue }

    // MARK: Names, focus and commands

    /// "Preview of notes.md": the pane and each presenter are named after the document (DS-70, DS-71).
    func setDocumentName(_ name: String) {
        let label = PreviewMessages.accessibilityLabel(documentName: name)
        guard label != accessibilityName else { return }
        accessibilityName = label
        setAccessibilityLabel(label)
        webPresenter?.setAccessibilityName(label)
        tablePresenter?.tableView.setAccessibilityLabel(label)
        outlinePresenter?.outlineView.setAccessibilityLabel(label)
    }

    /// The view that takes the keyboard focus: the visible presenter, or the pane itself while it
    /// shows only a sentence, so that commands still reach the tab.
    var focusView: NSView {
        if let web = webPresenter, !web.view.isHidden, let view = web.focusView { return view }
        if let table = tablePresenter, !table.scrollView.isHidden { return table.tableView }
        if let outline = outlinePresenter, !outline.scrollView.isHidden { return outline.outlineView }
        return self
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func goToError(_ sender: Any?) {
        if let syntaxError { onGoToError?(syntaxError) }
    }

    @objc func undo(_ sender: Any?) { onDocumentCommand?("undo") }
    @objc func redo(_ sender: Any?) { onDocumentCommand?("redo") }

    /// Stops all work and releases the presenters, the web view among them.
    func tearDown() {
        webPresenter?.tearDown()
        webPresenter = nil
        tablePresenter = nil
        outlinePresenter = nil
        contentHost.subviews.filter { $0 !== explanationLabel }.forEach { $0.removeFromSuperview() }
        onGoToError = nil
        onDocumentCommand = nil
        onContentLost = nil
    }
}
