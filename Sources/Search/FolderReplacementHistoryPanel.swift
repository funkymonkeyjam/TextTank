// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import TextTankCore

@MainActor final class FolderReplacementHistoryPanel: NSObject {
    let form = FormPanel(
        title: "Folder Replacement Backups", identifier: "TextTank.FolderReplacementBackups",
        size: NSSize(width: 650, height: 440))
    private let batches = NSPopUpButton(), age = NSPopUpButton()
    private let details = NSTextView(), notice = AnnouncingLabel(labelWithString: "")
    private var urls: [URL] = []
    private var reviewed: FolderReplacementBatch.Snapshot?
    private var policy: FolderReplacementHistory.Retention?
    private var generation = UUID()
    private var cleanupNotice = ""
    override init() {
        super.init()
        batches.target = self
        batches.action = #selector(selectBatch)
        age.target = self
        age.action = #selector(selectRetention)
        for (label, popup) in [("Replacement batch", batches), ("Keep backups", age)] {
            let caption = NSTextField(labelWithString: label)
            ControlPresentation.label(label, control: popup, caption: caption)
            form.add(NSStackView(views: [caption, popup]))
        }
        for value in FolderReplacementHistory.Retention.allCases {
            age.addItem(withTitle: value == .keep ? "Until I delete them" : "\(value.rawValue) days")
            age.lastItem?.tag = value.rawValue
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = details
        details.isEditable = false
        details.isSelectable = true
        details.isVerticallyResizable = true
        details.autoresizingMask = [.width]
        details.setAccessibilityLabel("Files and recovery states")
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        form.add(scroll)
        form.add(notice)
        form.button("Refresh", identifier: "folder.backups.refresh") { [weak self] in self?.refresh() }
        form.button("Delete Batch…", identifier: "folder.backups.delete") { [weak self] in self?.confirmDelete() }
        form.button("Close", identifier: "folder.backups.close", cancel: true) { [weak self] in self?.form.close() }
        form.retainPresentationOwner(self)
        form.onClose = { [weak self] in self?.generation = UUID() }
    }
    func show() {
        form.show()
        refresh()
    }
    private func refresh() {
        let stamp = UUID()
        generation = stamp
        reviewed = nil
        let selected = urls.indices.contains(batches.indexOfSelectedItem) ? urls[batches.indexOfSelectedItem] : nil
        form.setActionEnabled("folder.backups.delete", false)
        age.isEnabled = false
        batches.isEnabled = false
        details.string = ""
        notice.stringValue = "Reading private batches…"
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                (Result { try FolderReplacementBatch.listing() }, Result { try FolderReplacementHistory.retention() })
            }.value
            guard let self, self.form.acceptsActions, self.generation == stamp else { return }
            self.form.clearValidation()
            do {
                let value = try result.1.get()
                self.policy = value
                self.age.selectItem(withTag: value.rawValue)
                self.age.isEnabled = true
            } catch {
                self.policy = nil
                self.form.showValidation(error, field: self.age)
            }
            self.batches.removeAllItems()
            self.urls = []
            do {
                let rows = try result.0.get()
                self.urls = rows.map { $0.1 }
                for (date, url) in rows {
                    let shortID = url.deletingLastPathComponent().lastPathComponent.prefix(8)
                    let label =
                        date == .distantFuture
                        ? "Unreadable batch" : date.formatted(date: .abbreviated, time: .standard)
                    self.batches.addItem(withTitle: "\(label) · \(shortID)")
                }
                self.batches.isEnabled = !self.urls.isEmpty
                if let selected, let i = self.urls.firstIndex(of: selected) { self.batches.selectItem(at: i) }
                self.selectBatch()
            } catch { self.notice.stringValue = error.localizedDescription }
        }
    }
    @objc private func selectBatch() {
        reviewed = nil
        form.setActionEnabled("folder.backups.delete", false)
        details.string = ""
        guard urls.indices.contains(batches.indexOfSelectedItem) else {
            notice.stringValue = (["No private replacement backups.", cleanupNotice].filter { !$0.isEmpty }).joined(
                separator: " ")
            return
        }
        let url = urls[batches.indexOfSelectedItem], stamp = UUID()
        generation = stamp
        notice.stringValue = "Reading batch…"
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try FolderReplacementBatch.read(url) }
            }.value
            guard let self, self.generation == stamp, self.form.acceptsActions else { return }
            do {
                let snapshot = try result.get()
                self.reviewed = snapshot
                self.details.string = snapshot.entries.map { "\($0.1.rawValue)  \($0.0.path)" }.joined(separator: "\n")
                self.notice.stringValue =
                    "\(snapshot.created.formatted()) · \(Strings.count(snapshot.entries.count, .file))"
                self.form.setActionEnabled("folder.backups.delete", true)
            } catch { self.notice.stringValue = error.localizedDescription }
        }
    }
    private func confirmDelete() {
        guard form.window.attachedSheet == nil, let review = reviewed,
            urls.indices.contains(batches.indexOfSelectedItem)
        else { return }
        let url = urls[batches.indexOfSelectedItem], stamp = generation
        let alert = TTAlert()
        alert.messageText = "Delete This Recovery Batch?"
        alert.informativeText =
            "Delete the private originals for \(Strings.count(review.entries.count, .file)) from \(review.created.formatted()). This removes this batch’s Undo history. Files in the source folders stay as they are."
        alert.addButton(withTitle: "Delete Batch").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel", role: .cancel)
        alert.beginSheetModal(for: form.window) { [weak self] response in
            guard let self, self.form.acceptsActions, self.generation == stamp, response == .alertFirstButtonReturn
            else { return }
            self.form.setActionEnabled("folder.backups.delete", false)
            Task {
                let result = await Task.detached(priority: .utility) {
                    Result { try FolderReplacementHistory.delete(url, reviewed: review) }
                }.value
                guard self.form.acceptsActions else { return }
                do {
                    try result.get()
                    self.refresh()
                } catch {
                    self.form.showValidation(error)
                    self.selectBatch()
                }
            }
        }
    }
    @objc private func selectRetention() {
        guard let previous = policy, let desired = FolderReplacementHistory.Retention(rawValue: age.selectedTag()),
            previous != desired
        else { return }
        age.selectItem(withTag: previous.rawValue)
        guard desired != .keep else {
            saveRetention(desired, previous: previous)
            return
        }
        guard form.window.attachedSheet == nil else { return }
        let alert = TTAlert()
        alert.messageText = "Automatically Delete Older Backups?"
        alert.informativeText =
            "Delete completed replacement backups older than \(desired.rawValue) days now and during future cleanup. Active and interrupted batches stay available for review."
        alert.addButton(withTitle: "Apply Retention").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel", role: .cancel)
        alert.beginSheetModal(for: form.window) { [weak self] response in
            guard let self, self.form.acceptsActions, response == .alertFirstButtonReturn else { return }
            self.saveRetention(desired, previous: previous)
        }
    }
    private func saveRetention(
        _ value: FolderReplacementHistory.Retention, previous: FolderReplacementHistory.Retention
    ) {
        age.isEnabled = false
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result {
                    try FolderReplacementHistory.setRetention(value, replacing: previous)
                    return try FolderReplacementHistory.prune()
                }
            }.value
            guard let self, self.form.acceptsActions else { return }
            do {
                let summary = try result.get()
                self.cleanupNotice =
                    "Cleanup removed \(summary.removed). Batches needing review: \(summary.needsReview)."
                self.refresh()
            } catch {
                self.form.showValidation(error, field: self.age)
                self.age.isEnabled = true
            }
        }
    }
}
