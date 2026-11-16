import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// File > Open Recent, filled from the system's recent-documents list each time it opens.
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        // Two files with the same name are told apart by their folder.
        let names = Dictionary(grouping: urls, by: \.lastPathComponent)
        for url in urls {
            let duplicate = (names[url.lastPathComponent]?.count ?? 0) > 1
            let item = NSMenuItem(
                title: url.lastPathComponent
                    + (duplicate ? " — \(url.deletingLastPathComponent().lastPathComponent)" : ""),
                action: #selector(open(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(
            title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = NSDocumentController.shared
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }
    /// No item here has a key equivalent, so a key press never needs the list rebuilt.
    func menuHasKeyEquivalent(
        _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool { false }
    @objc func open(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error, (error as NSError).code != NSUserCancelledError { NSApp.presentError(error) }
        }
    }
}
