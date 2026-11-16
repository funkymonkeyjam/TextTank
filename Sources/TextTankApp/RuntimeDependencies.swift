import AppKit
import TextTankCore

/// Per-document effects/timing. The zero-argument AppKit factory receives these from
/// the composition environment; a direct creator may pass its own configuration.
struct DocumentDependencies {
    var automaticRecoveryDelay: TimeInterval = 0.5
    var maximumRecoveryDelay: TimeInterval = 5
    var afterWrite: (() throws -> Void)?
    var duringWrite: (() -> Void)?
    var recoveryFailureNotice: ((TextDocument, Error) -> Bool)?
}

/// Effects whose process-owned implementations can be supplied by an isolated host.
/// Constructing the defaults does not read a pasteboard or create an EventKit store.
struct RuntimeDependencies {
    var sharedDefaultsProvider: (() -> UserDefaults)?
    var document: () -> DocumentDependencies = { DocumentDependencies() }
    var windowAnimation: NSWindow.AnimationBehavior?
    var announce: ((String, Any?) -> Void)?
    var readFindText: () -> String = {
        guard AppStorage.permitsLegacyDefaults else { return "" }
        return NSPasteboard(name: .find).string(forType: .string) ?? ""
    }
    var writeFindText: (String) -> Void = { text in
        guard AppStorage.permitsLegacyDefaults else { return }
        let board = NSPasteboard(name: .find)
        board.clearContents()
        board.setString(text, forType: .string)
    }
    var generalPasteboard: () -> NSPasteboard? = {
        AppStorage.permitsLegacyDefaults ? NSPasteboard.general : nil
    }
}

enum RuntimeEnvironment {
    /// Installed by the composition root before any document/service consumers.
    /// Nil selects production defaults; isolated hosts explicitly own their effects.
    static var dependencies: RuntimeDependencies?
    static var current: RuntimeDependencies { dependencies ?? RuntimeDependencies() }
    static var legacyDefaults: UserDefaults? {
        if let provider = current.sharedDefaultsProvider { return AppStorage.legacyDefaults(providing: provider) }
        return AppStorage.legacyDefaults()
    }
}
