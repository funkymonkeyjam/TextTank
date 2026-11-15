// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@main struct LanguageControllerChecks {
 static func main()throws {
  let old=ProcessInfo.processInfo.environment["TEXTTANK_SUPPORT_DIRECTORY"],root=FileManager.default.temporaryDirectory.appendingPathComponent("LanguageChecks-"+UUID().uuidString)
  setenv("TEXTTANK_SUPPORT_DIRECTORY",root.path,1);defer{if let old{setenv("TEXTTANK_SUPPORT_DIRECTORY",old,1)}else{unsetenv("TEXTTANK_SUPPORT_DIRECTORY")};try? FileManager.default.removeItem(at:root)}
  _ = NSApplication.shared
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false),editor=TTEditor(frame:NSRect(x:0,y:0,width:600,height:400));window.contentView=editor
  var selected="python"
  let controller=LanguageController(editorProvider:{editor},languageProvider:{selected},setLanguage:{selected=$0})
  let catalog=controller.catalog!;var checks=0
  func check(_ condition:Bool,_ label:String){precondition(condition,label);checks+=1;print("PASS \(label)")}
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
  print("LEXER CONFIGURATION: \(supported) available; missing \(missing). This proves loading and text integrity, not every lexical semantic.")
  print("PASS LanguageControllerChecks: \(checks) native assertions")
 }
}
