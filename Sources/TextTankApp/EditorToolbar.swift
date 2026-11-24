import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// The same selectors and responder-chain targets used by the menu bar.
enum EditorToolbarCommand: String, CaseIterable {
    case new = "TextTank.New", open = "TextTank.Open", save = "TextTank.Save"
    case find = "TextTank.Find", split = "TextTank.Split"
    var identifier: NSToolbarItem.Identifier { .init(rawValue) }
    var title: String {
        switch self {
        case .new: return Strings.text("toolbar.new", "New")
        case .open: return Strings.text("toolbar.open", "Open…")
        case .save: return Strings.text("toolbar.save", "Save")
        case .find: return Strings.text("toolbar.find", "Find…")
        case .split: return Strings.text("toolbar.split", "Split Tab View")
        }
    }
    var action: Selector {
        switch self {
        case .new: return #selector(AppDelegate.newDocument(_:))
        case .open: return #selector(NSDocumentController.openDocument(_:))
        case .save: return #selector(NSDocument.save(_:))
        case .find: return #selector(EditorWindowController.showFind(_:))
        case .split: return #selector(EditorWindowController.clone(_:))
        }
    }
    var symbol: String {
        switch self {
        case .new: return "doc.badge.plus"
        case .open: return "folder"
        case .save: return "square.and.arrow.down"
        case .find: return "magnifyingglass"
        case .split: return "rectangle.split.2x1"
        }
    }
    var scope: String {
        switch self {
        case .new: return Strings.text("toolbar.new.help", "Create a new document.")
        case .open: return Strings.text("toolbar.open.help", "Choose a document to open.")
        case .save: return Strings.text("toolbar.save.help", "Save the current document.")
        case .find: return Strings.text("toolbar.find.help", "Find text in the current document.")
        case .split:
            return Strings.text(
                "toolbar.split.help", "Split this tab into two views of the same document, or return to one view.")
        }
    }
    @MainActor func makeItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.paletteLabel = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: scope)
        item.toolTip = scope
        item.action = action
        // A nil target preserves the menu's standard responder-chain resolution.
        let overflow = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.menuFormRepresentation = overflow
        return item
    }
}

/// The toolbar's Editor Layout item (owner decision DS-D12): a standard menu toolbar item that
/// lists the editor group layouts. Its menu is the one View > Editor Groups > Editor Group Layout
/// shows, built by the same command owner, so the two never disagree (DS-20). The menu bar keeps
/// every group command: a person may remove this item from the toolbar.
@MainActor enum EditorLayoutToolbarItem {
    static let identifier = NSToolbarItem.Identifier("TextTank.EditorLayout")
    static var title: String { Strings.text("toolbar.layout", "Editor Layout") }
    static var scope: String {
        Strings.text(
            "toolbar.layout.help",
            "Choose how many editor groups the window shows: one, two columns, two rows or a grid of four.")
    }
    static func make(commands: GroupCommandController) -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.paletteLabel = title
        item.image = NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: scope)
        item.toolTip = scope
        item.showsIndicator = true
        item.menu = commands.layoutMenu()
        return item
    }
}

/// AppKit autosave is production-only: it writes standard defaults directly. An explicit owned
/// defaults domain can exercise the same arrangement round trip without reading the owner's domain.
@MainActor enum EditorToolbarPreferences {
    static var isolatedDefaults: UserDefaults?
    static let key = "TextTank.ToolbarArrangement.v1"
    static var nativeAutosaveAllowed: Bool {
        isolatedDefaults == nil && Bundle.main.bundleIdentifier != nil && AppStorage.permitsLegacyDefaults
    }
    static func identifier(for automations: AutomationController?) -> NSToolbar.Identifier {
        .init(
            nativeAutosaveAllowed
                ? "TextTankToolbar"
                : "TextTank.IsolatedToolbar." + (automations?.toolbarFamilyIdentifier ?? UUID().uuidString))
    }
    struct Arrangement: Codable, Equatable {
        var version = 1
        var identifiers: [String]
        var displayMode: UInt
        var visible: Bool
        @MainActor static func capture(_ toolbar: NSToolbar) -> Arrangement {
            Arrangement(
                identifiers: toolbar.items.map { $0.itemIdentifier.rawValue },
                displayMode: toolbar.displayMode.rawValue, visible: toolbar.isVisible)
        }
    }
    /// Set once the Editor Layout item has been offered in this person's toolbar.
    static let layoutItemOfferedKey = "TextTank.ToolbarLayoutItemOffered.v1"
    /// DS-D12 moved the layout choice from its own row into the toolbar. A toolbar arranged
    /// before then has no such item, so it is added once, after the standard commands. It is
    /// offered a single time: a person who then removes it keeps it removed, and View > Editor
    /// Groups still has every layout. `defaults` is nil for an isolated host, which is left alone.
    static func offerLayoutItemOnce(in toolbar: NSToolbar, defaults: UserDefaults?) {
        guard let defaults, !defaults.bool(forKey: layoutItemOfferedKey) else { return }
        defaults.set(true, forKey: layoutItemOfferedKey)
        guard !toolbar.items.contains(where: { $0.itemIdentifier == EditorLayoutToolbarItem.identifier }) else {
            return
        }
        let last = toolbar.items.lastIndex { EditorToolbarCommand(rawValue: $0.itemIdentifier.rawValue) != nil }
        toolbar.insertItem(
            withItemIdentifier: EditorLayoutToolbarItem.identifier, at: last.map { $0 + 1 } ?? toolbar.items.count)
    }
    static func load() -> Arrangement? {
        guard let data = isolatedDefaults?.data(forKey: key), data.count <= SizePolicy.standard.toolbarArrangement,
            let state = try? JSONDecoder().decode(Arrangement.self, from: data), state.version == 1,
            state.identifiers.count <= 256, NSToolbar.DisplayMode(rawValue: state.displayMode) != nil
        else { return nil }
        return state
    }
    static func save(_ toolbar: NSToolbar) {
        guard let defaults = isolatedDefaults,
            let data = try? JSONEncoder().encode(Arrangement.capture(toolbar)), data.count <= SizePolicy.standard.toolbarArrangement
        else { return }
        defaults.set(data, forKey: key)
    }
}

/// Standard toolbar items expose native button cells in the unignored accessibility tree.
/// Give those real elements a scoped name, retaining their system drawing, action and role.
@MainActor enum EditorToolbarAccessibility {
    static func apply(to window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        let descriptions = Set(toolbar.items.compactMap(\.toolTip))
        func value(_ native: NSObject, _ selector: String) -> Any? {
            let action = NSSelectorFromString(selector)
            return native.responds(to: action) ? native.perform(action)?.takeUnretainedValue() : nil
        }
        func walk(_ element: Any, inToolbar: Bool = false, depth: Int = 0) {
            guard depth < 12, let native = element as? NSObject else { return }
            let role = value(native, "accessibilityRole") as? String ?? ""
            let isToolbar = inToolbar || role == NSAccessibility.Role.toolbar.rawValue
            let setter = NSSelectorFromString("setAccessibilityLabel:")
            if isToolbar, let help = value(native, "accessibilityHelp") as? String, descriptions.contains(help),
                [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.menuButton.rawValue].contains(role),
                native.responds(to: setter)
            {
                native.perform(setter, with: help)
            }
            for child in value(native, "accessibilityChildren") as? [Any] ?? [] {
                walk(child, inToolbar: isToolbar, depth: depth + 1)
            }
        }
        // The toolbar is a direct native window accessibility child. Do not traverse the
        // document text, tab strip or status controls while updating toolbar metadata.
        for child in window.accessibilityChildren() ?? [] {
            guard let native = child as? NSObject,
                value(native, "accessibilityRole") as? String == NSAccessibility.Role.toolbar.rawValue
            else { continue }
            walk(child, inToolbar: true)
        }
    }
}
