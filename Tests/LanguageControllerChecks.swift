// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@main struct LanguageControllerChecks {
 static func main() {
  Checks.run("LanguageControllerChecks") {
  let isolatedSupport=try IsolatedSupportDirectory("LanguageChecks")
  defer{isolatedSupport.restore()}
  _ = NSApplication.shared
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false),editor=TTEditor(frame:NSRect(x:0,y:0,width:600,height:400));window.contentView=editor
  var selected="python"
  let controller=LanguageController(editorProvider:{editor},languageProvider:{selected},setLanguage:{selected=$0})
  let catalog=try requireValue(controller.catalog,"fixture: language catalog loaded")
  let text="# café\nclass Example:\n    def work(self):\n        return 1\n"
  editor.text=text;editor.resetUndoHistory();editor.setSavePoint();let revision=editor.revision
  check(controller.apply(identifier:"python",to:editor),"Python profile applies to live Lexilla editor")
  check(editor.text==text && editor.revision==revision && !editor.modified,"language configuration preserves bytes Undo dirty state")
  let attributed=editor.attributedText(forSelection:false)
  check(attributed.string==text,"styled export preserves exact source")
  let symbols=try LanguageFunctions.symbols(text:text,profile:catalog.profiles.first{$0.id=="python"}!)
  check(LanguageFunctionController.navigate(symbols[1],text:text,revision:revision,editor:editor) && editor.selectedText=="work","function navigation selects exact UTF8 symbol after Unicode prefix")
  editor.text="changed";let selection=editor.selectionCaret
  check(!LanguageFunctionController.navigate(symbols[1],text:text,revision:revision,editor:editor) && editor.selectionCaret==selection,"stale function list cannot move selection")
  let source="if return class 123 \"text\" // comment\n";editor.text=source;editor.resetUndoHistory();editor.setSavePoint()
  var supported=0,missing:[String]=[]
  for profile in catalog.profiles {
   if controller.apply(identifier:profile.id,to:editor) {supported+=1;check(editor.text==source && !editor.modified,"profile \(profile.id) configures without editing")}
   else {missing.append(profile.id)}
  }
  var custom=catalog;custom.profiles[0].title="My plain language"
  try controller.persist(custom)
  let restored=LanguageController(editorProvider:{editor},languageProvider:{selected},setLanguage:{selected=$0})
  check(restored.catalog==custom,"custom profile persistence and reload exact")
  let menu=controller.menu();let pythonItem=menu.items.first{($0.representedObject as? String)=="python"}!
  check(NSApp.sendAction(pythonItem.action!,to:pythonItem.target,from:pythonItem) && selected=="python","real language menu action updates chosen profile")
  let udl=UserDefinedLanguage(name:"Synthetic Test",extensions:"sample",version:"2.1",global:["caseIgnored":"yes","forcePureLC":"0","decimalSeparator":"0"],prefix:[:],keywords:["Keywords1":"hello world","Comments":"00// 01 02 03/* 04*/","Delimiters":"00\" 01\\ 02\" 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23"],styles:[.init(name:"DEFAULT",attributes:["fgColor":"000000","fontStyle":"0"]),.init(name:"KEYWORDS1",attributes:["fgColor":"0000FF","fontStyle":"1"]),.init(name:"COMMENTS",attributes:["fgColor":"008000","fontStyle":"2"]),.init(name:"DELIMITERS1",attributes:["fgColor":"A05000","fontStyle":"2"])])
  let user=try udl.profile();custom.profiles.append(user);try controller.persist(custom)
  editor.text="HELLO ordinary /* comment */ \"string\"";editor.resetUndoHistory();editor.setSavePoint()
  check(controller.apply(identifier:user.id,to:editor),"ported LexUser factory applies imported UDL")
  let styled=editor.attributedText(forSelection:false)
  let keywordFont=styled.attribute(.font,at:0,effectiveRange:nil) as! NSFont, ordinaryFont=styled.attribute(.font,at:6,effectiveRange:nil) as! NSFont
  check(NSFontManager.shared.traits(of:keywordFont).contains(.boldFontMask) && !NSFontManager.shared.traits(of:ordinaryFont).contains(.boldFontMask),"actual LexUser keyword case-insensitive style differs from ordinary text")
  let commentRange=(editor.text as NSString).range(of:"comment"),stringRange=(editor.text as NSString).range(of:"string")
  let commentFont=styled.attribute(.font,at:commentRange.location,effectiveRange:nil) as! NSFont,stringFont=styled.attribute(.font,at:stringRange.location,effectiveRange:nil) as! NSFont
  check(NSFontManager.shared.traits(of:commentFont).contains(.italicFontMask),"actual LexUser block comment style")
  check(NSFontManager.shared.traits(of:stringFont).contains(.italicFontMask),"actual LexUser delimiter style")
  check(!editor.modified,"UDL lexing never marks document dirty")
  let index=custom.profiles.firstIndex{$0.id==user.id}!, styleIndex=custom.profiles[index].styles.firstIndex{$0.name=="KEYWORDS1"}!
  let chosenFont=NSFont.userFixedPitchFont(ofSize:19.25)!.fontName
  custom.profiles[index].styles[styleIndex].fontName=chosenFont;custom.profiles[index].styles[styleIndex].fontSize=19.25;custom.profiles[index].styles[styleIndex].useCustomColor=true;custom.profiles[index].styles[styleIndex].foreground="123456"
  try controller.persist(custom);let beforeStyleRevision=editor.revision;_ = controller.apply(identifier:user.id,to:editor)
  func styleMatches()->Bool {
   let output=editor.attributedText(forSelection:false),font=output.attribute(.font,at:0,effectiveRange:nil) as! NSFont,color=(output.attribute(.foregroundColor,at:0,effectiveRange:nil) as! NSColor).usingColorSpace(.sRGB)!
   return abs(font.pointSize-19.25)<0.01 && abs(color.redComponent-Double(0x12)/255)<0.005 && abs(color.greenComponent-Double(0x34)/255)<0.005 && abs(color.blueComponent-Double(0x56)/255)<0.005
  }
  check(styleMatches(),"actual lexer export honors configured font size and RGB")
  editor.appearance=NSAppearance(named:.darkAqua);editor.viewDidChangeEffectiveAppearance()
  check(styleMatches(),"custom font and RGB survive appearance change")
  check(editor.revision==beforeStyleRevision && !editor.modified,"font and color changes never edit document")
  let settingsWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:180),styleMask:[.titled],backing:.buffered,defer:false)
  let fontField=NSTextField(string:chosenFont),sizeField=NSTextField(string:"12");fontField.frame=NSRect(x:20,y:100,width:300,height:24);sizeField.frame=NSRect(x:20,y:50,width:300,height:24);settingsWindow.contentView?.addSubview(fontField);settingsWindow.contentView?.addSubview(sizeField)
  settingsWindow.makeFirstResponder(sizeField);(settingsWindow.firstResponder as? NSTextView)?.string="21.5"
  let read=try LanguageController.readStyle(custom.profiles[index].styles[styleIndex],font:fontField,size:sizeField,color:.red,custom:true,bold:false,italic:false,window:settingsWindow)
  check(read.fontName==chosenFont && read.fontSize==21.5 && read.foreground=="FF0000","focused shared size field commits independently of font name")
  let styledRestored=LanguageController(editorProvider:{editor},languageProvider:{user.id},setLanguage:{_ in})
  check(styledRestored.catalog==custom,"font and color preferences persist exactly")
  // F220: applying a profile lexes the document once, with the final lists and properties.
  typealias ScintillaMessage=@convention(c)(AnyObject,Selector,UInt32,UInt,Int)->Int
  let lexWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false),lexEditor=TTEditor(frame:NSRect(x:0,y:0,width:600,height:400));lexWindow.contentView=lexEditor
  let native=lexEditor.subviews.first!,messageSelector=NSSelectorFromString("message:wParam:lParam:")
  let send=unsafeBitCast(native.method(for:messageSelector),to:ScintillaMessage.self)
  func sci(_ message:UInt32,_ w:UInt=0,_ l:Int=0)->Int{send(native,messageSelector,message,w,l)}
  let SCI_GETLENGTH:UInt32=2006,SCI_GETSTYLEAT:UInt32=2010,SCI_GETENDSTYLED:UInt32=2028,SCI_COLOURISE:UInt32=4003
  func timed(_ work:()->Void)->Double{let start=ProcessInfo.processInfo.systemUptime;work();return ProcessInfo.processInfo.systemUptime-start}
  let lexLine="alignas alignof value = 42; // note\n",lexSource=String(repeating:lexLine,count:2*1024*1024/lexLine.utf8.count)
  lexEditor.text=lexSource;lexEditor.resetUndoHistory();lexEditor.setSavePoint();let lexRevision=lexEditor.revision
  lexEditor.setLanguage("cpp")
  let before=(0..<3).map{_ in timed{_ = sci(SCI_COLOURISE,0,-1)}}.min()!
  var applied=false;let applyTime=timed{applied=controller.apply(identifier:"cpp",to:lexEditor)}
  check(applied && lexEditor.text==lexSource && lexEditor.revision==lexRevision && !lexEditor.modified,"C++ profile applies to a 2 MiB buffer without editing it")
  check(sci(SCI_GETLENGTH)==lexSource.utf8.count && sci(SCI_GETENDSTYLED)==lexSource.utf8.count,"document is fully styled when apply returns")
  let lastLine=lexSource.utf8.count-lexLine.utf8.count
  check(sci(SCI_GETSTYLEAT,0)==16 && sci(SCI_GETSTYLEAT,8)==5 && sci(SCI_GETSTYLEAT,UInt(lastLine))==16 && sci(SCI_GETSTYLEAT,UInt(lastLine+8))==5,"apply styles with the profile's final keyword lists from first line to last")
  let sample=min(lexSource.utf8.count,200_000),appliedStyles=(0..<sample).map{sci(SCI_GETSTYLEAT,UInt($0))}
  let after=(0..<3).map{_ in timed{_ = sci(SCI_COLOURISE,0,-1)}}.min()!
  check((0..<sample).map{sci(SCI_GETSTYLEAT,UInt($0))}==appliedStyles,"styles after apply equal a fresh full pass with the final configuration")
  let onePass=max(before,after)
  check(applyTime<3*onePass,"applying a profile costs about one lexing pass (apply \(String(format:"%.3f",applyTime)) s, one pass \(String(format:"%.3f",onePass)) s)")
  check(controller.apply(identifier:"python",to:lexEditor) && sci(SCI_GETSTYLEAT,0)==11 && sci(SCI_GETSTYLEAT,UInt(lastLine+8))==11 && sci(SCI_GETENDSTYLED)==lexSource.utf8.count && lexEditor.revision==lexRevision,"switching profile replaces the previous lexer's styles across the whole document")
  // F248: the number of profiles that load is asserted, not only printed. A Lexilla upgrade
  // that gains or loses a lexer fails here on purpose; update the literal in the same change.
  let expectedMissing:Set<String>=["objc","searchResult"]
  if !check(Set(missing)==expectedMissing && missing.count==expectedMissing.count,"exactly the known profiles have no linked lexer") { print("NOTE missing profiles: \(missing)") }
  check(supported==catalog.profiles.count-expectedMissing.count && catalog.profiles.count==96,"every other catalog profile applies (\(supported) of \(catalog.profiles.count))")
  func message(_ target:TTEditor,_ number:UInt32,_ w:UInt=0,_ l:Int=0)->Int {
   let view=target.subviews.first!
   return unsafeBitCast(view.method(for:messageSelector),to:ScintillaMessage.self)(view,messageSelector,number,w,l)
  }
  func styles(_ target:TTEditor)->[Int] { (0..<target.text.utf8.count).map{message(target,SCI_GETSTYLEAT,UInt($0))} }
  var hosts:[NSWindow]=[]
  func hostedEditor()->TTEditor {
   let host=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false),made=TTEditor(frame:NSRect(x:0,y:0,width:600,height:400))
   host.contentView=made;hosts.append(host);return made
  }
  // A keyword of each high-use language is styled differently from a plain identifier, so a
  // lexer that silently became the null lexer, or lost its keyword list, is caught.
  let families=hostedEditor()
  for (id,keyword) in [("cpp","return"),("python","return"),("javascript","return"),("java","if"),("swift","class"),("rust","as"),("sql","abs"),("bash","alias"),("json","true")] {
   families.text="\(keyword) zzzplain\n"
   let applied=controller.apply(identifier:id,to:families)
   let keywordStyle=message(families,SCI_GETSTYLEAT,0),plainStyle=message(families,SCI_GETSTYLEAT,UInt(keyword.utf8.count+1))
   if !check(applied && keywordStyle != plainStyle && keywordStyle != 0,"\(id): a keyword is styled apart from a plain identifier") { print("NOTE \(id) keyword style \(keywordStyle), plain style \(plainStyle)") }
  }
  // G330: the TextTank-authored parts of the user-defined-language lexer. Expected styles
  // are Notepad++'s UDL 2.1 behaviour: style 4 is KEYWORDS1, 13 FOLDER IN CODE1, 1 COMMENTS.
  let SCI_GETFOLDLEVEL:UInt32=2223,foldHeader=0x2000,foldBase=0x400,keyword1=4
  func userProfile(_ name:String,keywords:[String:String],prefix:[String:String]=[:])throws->LanguageProfile {
   let language=UserDefinedLanguage(name:name,extensions:"sample",version:"2.1",global:["caseIgnored":"no","forcePureLC":"0","decimalSeparator":"0"],prefix:prefix,keywords:keywords,styles:[.init(name:"DEFAULT",attributes:["fgColor":"000000","fontStyle":"0"]),.init(name:"KEYWORDS1",attributes:["fgColor":"0000FF","fontStyle":"1"])])
   let made=try language.profile();var next=try requireValue(controller.catalog,"fixture: catalog")
   next.profiles.removeAll{$0.id==made.id};next.profiles.append(made);try controller.persist(next);return made
  }
  let prefixed=try userProfile("Pin prefix",keywords:["Keywords1":"pre"],prefix:["Keywords1":"yes"]),exact=try userProfile("Pin exact",keywords:["Keywords1":"pre"])
  let udlEditor=hostedEditor();udlEditor.text="prefix pre other"
  check(controller.apply(identifier:prefixed.id,to:udlEditor) && styles(udlEditor)[0..<6].allSatisfy{$0==keyword1} && styles(udlEditor)[7..<10].allSatisfy{$0==keyword1} && styles(udlEditor)[11] != keyword1,"prefix-mode keyword styles every word that starts with it")
  check(controller.apply(identifier:exact.id,to:udlEditor) && styles(udlEditor)[0] != keyword1 && styles(udlEditor)[7..<10].allSatisfy{$0==keyword1},"without prefix mode a keyword matches only the whole word")
  let multipart=try userProfile("Pin multi-part",keywords:["Keywords1":"'else if'"])
  udlEditor.text="else if x else y"
  let multipartApplied=controller.apply(identifier:multipart.id,to:udlEditor),multipartStyles=styles(udlEditor)
  if !check(multipartApplied && multipartStyles[0..<7].allSatisfy{$0==keyword1} && multipartStyles[10..<14].allSatisfy{$0 != keyword1},"a quoted multi-part keyword matches only the whole sequence, including its space") { print("NOTE multi-part styles \(multipartStyles)") }
  let folding=try userProfile("Pin folding",keywords:["Folders in code1, open":"begin","Folders in code1, close":"end"])
  udlEditor.text="begin\n  body\nend\nplain\n"
  let foldApplied=controller.apply(identifier:folding.id,to:udlEditor)
  let levels=(0..<4).map{message(udlEditor,SCI_GETFOLDLEVEL,UInt($0))}
  if !check(foldApplied && levels[0] & foldHeader != 0 && levels[0] & 0xFFF == foldBase && levels[1] & 0xFFF == foldBase+1 && levels[1] & foldHeader == 0 && levels[3] & 0xFFF == foldBase && levels[3] & foldHeader == 0 && styles(udlEditor)[0]==13,"fold open and close keywords make a fold header and a nested body") { print("NOTE fold levels \(levels.map{String($0,radix:16)}) style \(styles(udlEditor)[0])") }
  // An edit followed by an incremental restyle gives the same styles as lexing the result afresh.
  let incremental=try userProfile("Pin incremental",keywords:["Keywords1":"hello","Comments":"00// 01 02 03/* 04*/","Folders in code1, open":"begin","Folders in code1, close":"end"])
  let live=hostedEditor(),fresh=hostedEditor()
  live.text="hello one\nbegin /* open\nstill comment */ hello\nend hello // tail\nhello last\n"
  check(controller.apply(identifier:incremental.id,to:live) && message(live,SCI_GETENDSTYLED)==live.text.utf8.count,"fixture: multi-line UDL document is fully styled")
  for (offset,insertion) in [(10,"hello "),(31,"/* reopened\n"),(0,"// "),(3,"\n")] {
   _ = live.setSelectionAnchor(offset,caret:offset);live.replaceSelection(insertion)
   _ = message(live,SCI_COLOURISE,UInt(message(live,SCI_GETENDSTYLED)),-1)
   fresh.text=live.text;_ = controller.apply(identifier:incremental.id,to:fresh)
   let liveLevels=(0..<7).map{message(live,SCI_GETFOLDLEVEL,UInt($0))},freshLevels=(0..<7).map{message(fresh,SCI_GETFOLDLEVEL,UInt($0))}
   if !check(styles(live)==styles(fresh) && liveLevels==freshLevels && styles(live).contains(keyword1) && styles(live).contains(1),"incremental restyle after inserting \(insertion.debugDescription) at \(offset) equals a full relex") { print("NOTE live \(styles(live))\nNOTE fresh \(styles(fresh))") }
  }
  // Two documents with different UDLs, lexed alternately, keep their own keyword lists. The
  // fixtures end with a line break on purpose: a keyword that is the very last word of a
  // document with no final line break is left unstyled today, and whether Notepad++ does the
  // same has not been checked, so that case is neither pinned nor called a defect here.
  let alpha=try userProfile("Pin alpha",keywords:["Keywords1":"alpha"]),beta=try userProfile("Pin beta",keywords:["Keywords1":"beta"])
  let editorA=hostedEditor(),editorB=hostedEditor();editorA.text="alpha beta\n";editorB.text="alpha beta\n"
  check(controller.apply(identifier:alpha.id,to:editorA) && controller.apply(identifier:beta.id,to:editorB),"fixture: two UDL lexers coexist")
  var separate=true
  for _ in 0..<3 {
   _ = message(editorA,SCI_COLOURISE,0,-1);_ = message(editorB,SCI_COLOURISE,0,-1)
   separate=separate && styles(editorA)[0]==keyword1 && styles(editorA)[6] != keyword1 && styles(editorB)[0] != keyword1 && styles(editorB)[6]==keyword1
  }
  check(separate,"two coexisting user lexers keep separate keyword lists when lexed alternately")
  let alphaChanged=try userProfile("Pin alpha",keywords:["Keywords1":"beta gamma"])
  check(alphaChanged.id==alpha.id && controller.apply(identifier:alpha.id,to:editorA) && styles(editorA)[0] != keyword1 && styles(editorA)[6]==keyword1,"a changed keyword list restyles a live user lexer")
  _ = message(editorB,SCI_COLOURISE,0,-1)
  check(styles(editorB)[0] != keyword1 && styles(editorB)[6]==keyword1 && editorA.text=="alpha beta\n","changing one user lexer's keywords leaves the other lexer and the text alone")
  editorA.setLanguage("null");_ = message(editorB,SCI_COLOURISE,0,-1)
  check(styles(editorB)[6]==keyword1,"releasing one user lexer leaves the other's keyword cache intact")
  withExtendedLifetime(hosts) {}
  print("LEXER CONFIGURATION: \(supported) available; missing \(missing). This proves loading and text integrity, not every lexical semantic.")
  Checks.summary { "PASS LanguageControllerChecks: \(Checks.count) native assertions" }
  }
 }
}
