// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

struct EditorSettings: Codable, Equatable {
    var version=1
    var tabWidth=4
    var useTabs=true
    var wrap=false
    var appearance="system"
    // Key equivalents use AppKit's uppercase convention for Shift.
    var shortcuts:[String:String]=[:]
    static let commands:Set<String>=["duplicateLine","deleteLine","transposeLine","upper","lower","trimTrailing","moveLineUp","moveLineDown","joinLines","bookmarkToggle","bookmarkNext","bookmarkPrevious"]
    static let reserved:Set<String>=["a","c","v","x","z","Z","s","S","n","o","w","q","p","f","F","g","G","P","m","[","]","+","-",","]
    func validate() throws {
        guard version == 1,(1...32).contains(tabWidth),["system","light","dark"].contains(appearance) else { throw SettingsError.invalid }
        var seen=Set<String>()
        var effective=["duplicateLine":"d"];effective.merge(shortcuts){_,new in new}
        for (id,key) in effective {
            guard Self.commands.contains(id),key.count == 1,key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }),!Self.reserved.contains(key),seen.insert(key).inserted else { throw SettingsError.conflict }
        }
    }
    static func decode(_ data:Data)throws->Self {
        let settings=try JSONDecoder().decode(Self.self,from:data);try settings.validate();return settings
    }
}
enum SettingsError: Error,LocalizedError {
    case invalid,conflict
    var errorDescription:String? { self == .invalid ? "Unsupported settings version or value. Existing settings have not been replaced." : "Shortcut conflicts with another action, uses a reserved key, or is not a single printable ASCII character." }
}
final class SettingsController:NSObject {
    private(set) var value=EditorSettings()
    private(set) var loadError:Error?
    let url:URL
    init(url:URL?=nil) {
        let support=ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("TextTank")
        self.url=url ?? support.appendingPathComponent("Settings.json")
        super.init()
        do { value=try EditorSettings.decode(WorkspaceStore.readRegularFile(self.url,maximumBytes:1024*1024)) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == ENOENT { }
        catch { loadError=error }
    }
    func save(_ settings:EditorSettings)throws {
        try settings.validate()
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try WorkspaceStore.writePrivate(JSONEncoder().encode(settings),to:url)
        value=settings;loadError=nil;apply()
    }
    func apply(to editor:TTEditor) { editor.configureTabWidth(value.tabWidth,useTabs:value.useTabs);editor.wrap=value.wrap }
    func apply() {
        NSApp.appearance=value.appearance == "system" ? nil : NSAppearance(named:value.appearance == "dark" ? .darkAqua : .aqua)
        for doc in NSDocumentController.shared.documents.compactMap({ $0 as? TextDocument }) {
            apply(to:doc.editor)
            for controller in doc.windowControllers.compactMap({ $0 as? EditorWindowController }) { if let clone=controller.secondary { apply(to:clone) } }
        }
        func update(_ menu:NSMenu) {
            for item in menu.items {
                if let id=item.representedObject as? String,EditorSettings.commands.contains(id) { item.keyEquivalent=value.shortcuts[id] ?? (id == "duplicateLine" ? "d" : "") }
                if let child=item.submenu { update(child) }
            }
        }
        if let menu=NSApp.mainMenu { update(menu) }
    }
    @objc func showSettings(_ sender:Any?) {
        let alert=NSAlert();alert.messageText="Editor Settings";alert.informativeText="Applies to open and new views. Shortcut keys use Command; uppercase adds Shift."
        let width=NSTextField(string:String(value.tabWidth))
        let tabs=NSButton(checkboxWithTitle:"Indent with tabs",target:nil,action:nil);tabs.state=value.useTabs ? .on : .off
        let wrap=NSButton(checkboxWithTitle:"Wrap lines",target:nil,action:nil);wrap.state=value.wrap ? .on : .off
        let appearance=NSPopUpButton();appearance.addItems(withTitles:["system","light","dark"]);appearance.selectItem(withTitle:value.appearance)
        let shortcut=NSPopUpButton();shortcut.addItems(withTitles:EditorSettings.commands.sorted())
        let key=NSTextField(string:"");key.placeholderString="Optional shortcut for selected command"
        let stack=NSStackView(views:[NSTextField(labelWithString:"Tab width (1–32)"),width,tabs,wrap,appearance,NSTextField(labelWithString:"Assign one command shortcut"),shortcut,key]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=8;stack.frame=NSRect(x:0,y:0,width:420,height:250)
        alert.accessoryView=stack;alert.addButton(withTitle:"Save");alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:"Reset Defaults")
        let result=alert.runModal();guard result != .alertSecondButtonReturn else { return }
        do {
            var updated=value
            if result == .alertThirdButtonReturn { updated=EditorSettings() }
            else {
                updated.tabWidth=Int(width.stringValue) ?? 0;updated.useTabs=tabs.state == .on;updated.wrap=wrap.state == .on;updated.appearance=appearance.titleOfSelectedItem ?? "system"
                if !key.stringValue.isEmpty,let id=shortcut.titleOfSelectedItem { updated.shortcuts[id]=key.stringValue }
            }
            try save(updated)
        } catch { NSAlert(error:error).runModal() }
    }
}
