import TextTankCore
import EditorBridge
import NativeSearch
import AppKit

/// The composition root installs these providers after the document-controller singleton exists.
/// Reading the environment never constructs a feature controller until that provider is used.
@MainActor struct EditorServices {
    private static var installed: EditorServices?
    static var current: EditorServices? {
        get {
            guard let installed, installed.isAvailable() else { return nil }
            return installed
        }
        set { installed = newValue }
    }
    var activePresentationProvider: () -> EditorWindowController? = { nil }
    var activePresentation: EditorWindowController? { activePresentationProvider() }
    var workspaceHostProvider: () -> WorkspaceWindowController? = { nil }
    var workspaceHost: WorkspaceWindowController? { workspaceHostProvider() }
    var isAvailable: () -> Bool = { true }
    var settingsProvider: () -> SettingsController? = { nil }
    var languagesProvider: () -> LanguageController? = { nil }
    var macrosProvider: () -> MacroController? = { nil }
    var automationsProvider: () -> AutomationController? = { nil }
    var searchProvider: () -> SearchController? = { nil }
    var newDocument: (Any?) -> Void = { _ in }
    var noteActiveController: (EditorWindowController) -> Void = { _ in }
    var openSessionFile: (URL) -> Void = { _ in }
    var settings: SettingsController? { settingsProvider() }
    var languages: LanguageController? { languagesProvider() }
    var macros: MacroController? { macrosProvider() }
    var automations: AutomationController? { automationsProvider() }
    var searchController: SearchController? { searchProvider() }
}

extension Notification.Name {
    static let textTankDocumentsDidChange = Notification.Name("TextTankDocumentsDidChange")
}
