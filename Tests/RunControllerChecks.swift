import AppKit
@main struct RunControllerChecks {
 @MainActor static func main()throws{
  _=NSApplication.shared;var count=0
  func check(_ value:Bool,_ label:String){guard value else{fatalError(label)};count+=1;print("PASS "+label)}
  let support=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let oldSupport=ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"]
  setenv("TEXTTANK_SUPPORT_DIRECTORY",support.path,1);defer{if let oldSupport{setenv("TEXTTANK_SUPPORT_DIRECTORY",oldSupport,1)}else{unsetenv("TEXTTANK_SUPPORT_DIRECTORY")};try? FileManager.default.removeItem(at:support)}
  let document=TextDocument();document.makeWindowControllers();document.editor.text="original";document.editor.resetUndoHistory()
  let controller=RunController(),sample=ConfiguredRun.uppercaseSample
  try controller.persist([sample])
  let originalConfiguration=try Data(contentsOf:controller.storage)
  let oversized=ConfiguredRun(name:"Too large",executable:"/usr/bin/printf",arguments:[String(repeating:"x",count:600000),String(repeating:"y",count:600000)])
  var refused=false;do{try controller.persist([oversized])}catch{refused=true}
  let preservedConfiguration=try Data(contentsOf:controller.storage)
  check(refused && preservedConfiguration==originalConfiguration,"oversized save preserves exact existing file")
  check(controller.makeMenu().items.contains{($0.representedObject as? String)==sample.id.uuidString},"rejected save preserves active command identity")
  let restarted=RunController()
  check(restarted.makeMenu().items.contains{($0.representedObject as? String)==sample.id.uuidString},"saved library restarts with original command identity")
  var boundary=ConfiguredRun(name:"Boundary",executable:"/usr/bin/printf",arguments:[""])
  let overhead=try ConfiguredRun.encodeLibrary([boundary]).count
  boundary.arguments=[String(repeating:"x",count:ConfiguredRun.maximumLibraryBytes-overhead)]
  try controller.persist([boundary])
  let boundaryRestart=RunController()
  check(boundaryRestart.makeMenu().items.contains{($0.representedObject as? String)==boundary.id.uuidString},"exact 1 MiB saved file remains readable after restart")
  try controller.persist([sample])
  let result=RunResult(stdout:Data("FIRST".utf8),stderr:Data(),status:0,cancelled:false,truncated:false)
  func button()->NSButton{NSApp.windows.flatMap{($0.contentView as? NSStackView)?.views ?? []}.compactMap{$0 as? NSButton}.last{$0.title=="Apply Extension Result"}!}
  controller.show(.success(result),command:sample,target:document.editor,revision:document.editor.revision,selection:false,anchor:0,caret:0)
  let old=button()
  controller.show(.success(RunResult(stdout:Data("SECOND".utf8),stderr:Data(),status:0,cancelled:false,truncated:false)),command:sample,target:document.editor,revision:document.editor.revision,selection:false,anchor:0,caret:0)
  let current=button();controller.apply(old)
  check(document.editor.text=="original" && !old.isEnabled,"old preview cannot apply a newer result")
  controller.apply(current);check(document.editor.text=="SECOND","current preview applies explicit matching result")
  document.editor.executeCommand("undo");check(document.editor.text=="original","extension apply one Undo")
  let special="\u{FEFF}identity\0tail"
  controller.show(.success(RunResult(stdout:Data(special.utf8),stderr:Data(),status:0,cancelled:false,truncated:false)),command:sample,target:document.editor,revision:document.editor.revision,selection:false,anchor:0,caret:0)
  controller.apply(button());check(document.editor.text.utf8.elementsEqual(special.utf8),"extension output preserves leading FEFF and embedded NUL")
  controller.show(.success(result),command:sample,target:document.editor,revision:document.editor.revision,selection:false,anchor:0,caret:0)
  let stale=button();document.editor.text="new edit";controller.apply(stale)
  check(document.editor.text=="new edit","stale extension result preserves newer edits")
  controller.show(.success(result),command:sample,target:document.editor,revision:document.editor.revision,selection:false,anchor:0,caret:0)
  let closed=button();document.close();controller.apply(closed)
  check(document.editor.text=="new edit","detached editor cannot receive extension result")
  print("PASS RunControllerChecks: \(count) assertions")
 }
}
