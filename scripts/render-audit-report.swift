import AppKit
import CoreText
let args=CommandLine.arguments
let input=try String(contentsOfFile:args[1],encoding:.utf8)
let output=URL(fileURLWithPath:args[2])
let text=NSMutableAttributedString(string:"")
for raw in input.components(separatedBy:"\n") {
    if raw.isEmpty {continue}
    let heading=raw.hasPrefix("#")
    let level=raw.prefix(while:{$0 == "#"}).count
    var line=raw
    if heading {line=String(raw.dropFirst(level)).trimmingCharacters(in:.whitespaces)}
    line=line.replacingOccurrences(of:"**",with:"").replacingOccurrences(of:"`",with:"")
    line=line.replacingOccurrences(of:"\\[([^]]+)\\]\\(([^)]+)\\)",with:"$1 ($2)",options:.regularExpression)
    let para=NSMutableParagraphStyle();para.lineSpacing=2.5;para.paragraphSpacing=heading ? 8:6
    let size:CGFloat=heading ? (level == 1 ? 23:level == 2 ? 16:12.5):9.5
    let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:size,weight:heading ? .semibold:.regular),.foregroundColor:heading ? NSColor(calibratedRed:0.08,green:0.18,blue:0.17,alpha:1):NSColor.black,.paragraphStyle:para]
    text.append(NSAttributedString(string:line+"\n",attributes:attrs))
}
var media=CGRect(x:0,y:0,width:612,height:792)
let consumer=CGDataConsumer(url:output as CFURL)!
let context=CGContext(consumer:consumer,mediaBox:&media,nil)!
let setter=CTFramesetterCreateWithAttributedString(text)
var offset=0,page=1
while offset<text.length {
    context.beginPDFPage(nil)
    let path=CGPath(rect:CGRect(x:45,y:52,width:522,height:694),transform:nil)
    let frame=CTFramesetterCreateFrame(setter,CFRange(location:offset,length:0),path,nil)
    CTFrameDraw(frame,context)
    let range=CTFrameGetVisibleStringRange(frame)
    if range.length == 0 {fatalError("No layout progress")}
    let footer=NSAttributedString(string:"TextTank independent audit | 15 Nov 2026 | bcee103 | Page \(page)",attributes:[.font:NSFont.systemFont(ofSize:8),.foregroundColor:NSColor.gray])
    context.textPosition=CGPoint(x:45,y:27);CTLineDraw(CTLineCreateWithAttributedString(footer),context)
    context.endPDFPage();offset+=range.length;page+=1
}
context.closePDF();print("Rendered \(page-1) pages")
