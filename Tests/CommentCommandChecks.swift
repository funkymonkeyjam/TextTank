// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@main struct CommentCommandChecks {
 static func main() throws {
  var count=0
  func check(_ value:Bool,_ label:String){precondition(value,label);count+=1;print("PASS \(label)")}
  func rejects(_ label:String,_ work:()throws->Void){do{try work();fatalError("Expected rejection: \(label)")}catch{count+=1}}
  let catalog=try LanguageCatalog.decode(Data(contentsOf:URL(fileURLWithPath:"Resources/LanguageProfiles.json")))
  let python=catalog.profiles.first{$0.id=="python"}!,cpp=catalog.profiles.first{$0.id=="cpp"}!,html=catalog.profiles.first{$0.id=="html"}!
  func selection(_ a:Int,_ c:Int)->[[String:NSNumber]]{[["anchor":NSNumber(value:a),"caret":NSNumber(value:c)]]}
  let text="  café 🥑\r\n\tvalue\r\nlast"
  let end="  café 🥑\r\n\tvalue\r\n".utf8.count
  let first=try CommentCommand.toggleLine.plan(text:text,selections:selection(end,0),profile:python)
  check(first.text=="  # café 🥑\r\n\t# value\r\nlast","indent Unicode CRLF preserved; line-start endpoint excludes next line")
  check(first.selections[0]["anchor"]!.intValue>first.selections[0]["caret"]!.intValue,"reverse selection direction preserved")
  let restored=try CommentCommand.toggleLine.plan(text:first.text,selections:first.selections,profile:python)
  check(restored.text==text,"toggle roundtrip with adjusted selection")
  let mixed=try CommentCommand.toggleLine.plan(text:"# first\nsecond\n\n",selections:selection(0,15),profile:python)
  check(mixed.text=="first\n# second\n\n","reference toggle treats each line independently and skips empty lines")
  let absent=try CommentCommand.lineUncomment.plan(text:"plain",selections:selection(0,0),profile:python)
  check(absent.text=="plain","uncomment plain text is no-op")
  let block=try CommentCommand.blockComment.plan(text:"café + 🥑",selections:selection(0,"café + 🥑".utf8.count),profile:cpp)
  check(block.text=="/* café + 🥑 */","block comment wraps exact Unicode selection")
  check(try CommentCommand.blockUncomment.plan(text:block.text,selections:block.selections,profile:cpp).text=="café + 🥑","block removal immediately after wrapping uses preserved inner selection")
  let unblocked=try CommentCommand.blockUncomment.plan(text:block.text,selections:selection(0,block.text.utf8.count),profile:cpp)
  check(unblocked.text=="café + 🥑","block removal exact")
  let interior=try CommentCommand.blockUncomment.plan(text:"before /* inner */ after",selections:selection(12,12),profile:cpp)
  check(interior.text=="before inner after","caret inside enclosing block removes only delimiters")
  let xml=try CommentCommand.toggleLine.plan(text:"<node/>\n",selections:selection(0,0),profile:html)
  check(xml.text=="<!-- <node/> -->\n","line operation falls back to paired language delimiters")
  rejects("overlapping block selections reject before mutation"){_ = try CommentCommand.blockComment.plan(text:"abcdef",selections:selection(0,4)+selection(2,6),profile:cpp)}
  rejects("closing delimiter prevents invalid nested wrapping"){_ = try CommentCommand.blockComment.plan(text:"a */ b",selections:selection(0,6),profile:cpp)}
  rejects("missing block marker rejected"){_ = try CommentCommand.blockComment.plan(text:"x",selections:selection(0,1),profile:python)}
  rejects("split UTF8 rejected"){_ = try CommentCommand.toggleLine.plan(text:"🥑",selections:selection(1,2),profile:python)}
  let overlap=selection(0,1)+selection(1,2)
  check(try CommentCommand.toggleLine.plan(text:"abc\n",selections:overlap,profile:python).text=="# abc\n","shared selected line commented only once")
  // F3: a caret at the end of an unterminated last line is on that line.
  let eof=try CommentCommand.toggleLine.plan(text:"x = 1",selections:selection(5,5),profile:python)
  check(eof.text=="# x = 1" && eof.selections[0]["anchor"]!.intValue==7 && eof.selections[0]["caret"]!.intValue==7,"toggle at end of unterminated last line comments it and maps the caret")
  check(try CommentCommand.lineComment.plan(text:"x = 1",selections:selection(5,5),profile:python).text=="# x = 1","comment at end of unterminated last line")
  check(try CommentCommand.lineUncomment.plan(text:"# x = 1",selections:selection(7,7),profile:python).text=="x = 1","uncomment at end of unterminated last line")
  check(try CommentCommand.toggleLine.plan(text:"abc\n",selections:selection(4,4),profile:python).text=="abc\n","caret on empty line after final LF leaves previous line alone")
  check(try CommentCommand.toggleLine.plan(text:"abc\r\n",selections:selection(5,5),profile:python).text=="abc\r\n","caret on empty line after final CRLF leaves previous line alone")
  check(try CommentCommand.toggleLine.plan(text:"a\nb",selections:selection(1,1),profile:python).text=="# a\nb","caret at end of terminated line touches only that line")
  _ = NSApplication.shared
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false),editor=TTEditor(frame:NSRect(x:0,y:0,width:600,height:400));window.contentView=editor
  editor.text=text;editor.resetUndoHistory();editor.setSavePoint();_ = editor.setSelectionRanges(selection(end,0))
  try CommentCommand.toggleLine.apply(to:editor,profile:python)
  check(editor.text==first.text && editor.selectionAnchor>editor.selectionCaret,"native comment applies with reversed mapped selection")
  editor.executeCommand("undo");check(editor.text==text && !editor.modified,"one Undo restores exact original and save point")
  editor.readOnly=true;let originalSelection=editor.selectionRanges
  rejects("read-only comment rejects"){try CommentCommand.toggleLine.apply(to:editor,profile:python)}
  check(editor.text==text && editor.selectionRanges==originalSelection,"read-only comment preserves selection and bytes")
  editor.readOnly=false
  editor.text="x = 1";editor.resetUndoHistory();editor.setSavePoint();_ = editor.setSelectionAnchor(5,caret:5)
  try CommentCommand.toggleLine.apply(to:editor,profile:python)
  check(editor.text=="# x = 1" && editor.selectionAnchor==7 && editor.selectionCaret==7,"native toggle at end of unterminated last line")
  editor.executeCommand("undo");check(editor.text=="x = 1" && !editor.modified,"native end-of-file toggle is one Undo")
  print("PASS CommentCommandChecks: \(count) assertions")
 }
}
