// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum CommentCommand:String,CaseIterable {
    case toggleLine,lineComment,lineUncomment,blockComment,blockUncomment
    var title:String {switch self{case .toggleLine:return "Toggle Line Comment";case .lineComment:return "Comment Selected Lines";case .lineUncomment:return "Uncomment Selected Lines";case .blockComment:return "Block Comment";case .blockUncomment:return "Remove Block Comment"}}
    struct Edit:Hashable {var start:Int,end:Int,text:String}
    struct Plan {let text:String,selections:[[String:NSNumber]]}
    func plan(text:String,selections:[[String:NSNumber]],profile:LanguageProfile)throws->Plan {
        guard text.utf8.count<=16*1024*1024 else{throw LanguageError.invalid("Comment commands currently accept documents up to 16 MiB.")}
        guard let markers=profile.comments else{throw LanguageError.invalid("This language has no configured comment delimiters.")}
        let bytes=Array(text.utf8)
        func boundary(_ offset:Int)->Bool{offset>=0 && offset<=bytes.count && (offset==bytes.count || bytes[offset]&0xc0 != 0x80)}
        var ranges:[(Int,Int)]=[]
        for selection in selections {guard let a=selection["anchor"]?.intValue,let c=selection["caret"]?.intValue,boundary(a),boundary(c) else{throw LanguageError.invalid("Invalid Unicode selection boundary.")};ranges.append((min(a,c),max(a,c)))}
        guard !ranges.isEmpty else{throw LanguageError.invalid("No editor selection.")}
        var edits:[Edit]=[]
        if self == .blockComment || self == .blockUncomment {
            let ordered=ranges.sorted{$0.0<$1.0}
            for index in 1..<max(1,ordered.count) {guard ordered[index].0>=ordered[index-1].1 else{throw LanguageError.invalid("Overlapping block selections were not changed.")}}
            guard let open=markers.blockOpen,!open.isEmpty,let close=markers.blockClose,!close.isEmpty else{throw LanguageError.invalid("This language has no block-comment delimiters.")}
            let left=Array(open.utf8),right=Array(close.utf8)
            for (start,end) in ranges {
                if self == .blockComment {
                    guard start<end else{throw LanguageError.invalid("Select text to wrap in a block comment.")}
                    let selected=String(decoding:bytes[start..<end],as:UTF8.self)
                    guard !selected.contains(close) else{throw LanguageError.invalid("Selection already contains a closing comment delimiter; nothing was changed.")}
                    edits.append(Edit(start:start,end:start,text:open+" "));edits.append(Edit(start:end,end:end,text:" "+close))
                } else {
                    var a=start,b=end
                    if !(end-start>=left.count+right.count && Array(bytes[start..<min(start+left.count,end)])==left && Array(bytes[max(start,end-right.count)..<end])==right) {
                        // Include an immediately enclosing block; never infer an unrelated earlier block.
                        let prefix=String(decoding:bytes[..<start],as:UTF8.self),suffix=String(decoding:bytes[end...],as:UTF8.self)
                        guard let opening=prefix.range(of:open,options:.backwards),let closing=suffix.range(of:close) else{throw LanguageError.invalid("No enclosing block comment found.")}
                        a=prefix[..<opening.lowerBound].utf8.count;b=end+suffix[..<closing.upperBound].utf8.count
                        let interior=String(decoding:bytes[(a+left.count)..<(b-right.count)],as:UTF8.self)
                        guard !interior.contains(close),!interior.contains(open) else{throw LanguageError.invalid("Ambiguous nested comment boundaries; select the complete comment explicitly.")}
                    }
                    var openingEnd=a+left.count,closingStart=b-right.count
                    if openingEnd<closingStart,bytes[openingEnd]==32{openingEnd+=1}
                    if closingStart>openingEnd,bytes[closingStart-1]==32{closingStart-=1}
                    edits.append(Edit(start:a,end:openingEnd,text:""));edits.append(Edit(start:closingStart,end:b,text:""))
                }
            }
        } else {
            var lines:[(start:Int,end:Int,next:Int)]=[],start=0,index=0
            while index<bytes.count {
                if bytes[index]==10 || bytes[index]==13 {let end=index;index += bytes[index]==13 && index+1<bytes.count && bytes[index+1]==10 ? 2:1;lines.append((start,end,index));start=index}else{index+=1}
            }
            lines.append((start,bytes.count,bytes.count))
            for line in lines {
                guard ranges.contains(where:{a,b in a==b ? a>=line.start && (a<line.next || line.start==bytes.count):a<line.next && b>line.start}) else{continue}
                var indent=line.start
                while indent<line.end && (bytes[indent]==32 || bytes[indent]==9){indent+=1}
                if indent==line.end && profile.id != "baanc"{continue}
                if profile.id=="fortran77" || profile.id=="baanc"{indent=line.start}
                if let marker=markers.line,!marker.isEmpty {
                    let length=marker.utf8.count
                    let hasMarker=indent+length<=line.end && String(decoding:bytes[indent..<indent+length],as:UTF8.self).lowercased()==marker.lowercased()
                    if hasMarker && self != .lineComment {let end=indent+length+(indent+length<line.end && bytes[indent+length]==32 && profile.id != "baanc" ? 1:0);edits.append(Edit(start:indent,end:end,text:""))}
                    else if self != .lineUncomment {edits.append(Edit(start:indent,end:indent,text:marker+(profile.id=="baanc" ? "":" ")))}
                } else if let open=markers.blockOpen,!open.isEmpty,let close=markers.blockClose,!close.isEmpty {
                    let content=String(decoding:bytes[indent..<line.end],as:UTF8.self)
                    if content.hasPrefix(open),content.hasSuffix(close),content.utf8.count>=open.utf8.count+close.utf8.count,self != .lineComment {
                        var a=indent+open.utf8.count,b=line.end-close.utf8.count
                        if a<b,bytes[a]==32{a+=1};if b>a,bytes[b-1]==32{b-=1}
                        edits.append(Edit(start:indent,end:a,text:""));edits.append(Edit(start:b,end:line.end,text:""))
                    }else if self != .lineUncomment {guard !content.contains(close) else{throw LanguageError.invalid("A selected line contains a closing delimiter; nothing was changed.")};edits.append(Edit(start:indent,end:indent,text:open+" "));edits.append(Edit(start:line.end,end:line.end,text:" "+close))}
                }else{throw LanguageError.invalid("This language has no usable comment delimiters.")}
            }
        }
        edits=Array(Set(edits)).sorted{$0.start==$1.start ? $0.end<$1.end:$0.start<$1.start}
        var priorEnd=0,priorStart:Int?
        for edit in edits {guard edit.start>=priorEnd,priorStart != edit.start else{throw LanguageError.invalid("Overlapping comment edits were not applied.")};priorEnd=edit.end;priorStart=edit.start}
        var result=Data(bytes)
        for edit in edits.reversed(){result.replaceSubrange(edit.start..<edit.end,with:edit.text.utf8)}
        func mapped(_ position:Int)->Int {
            var delta=0
            for edit in edits {
                if position<edit.start{break}
                if position<=edit.end{
                    if self == .blockComment,edit.start==edit.end,edit.text==" "+(markers.blockClose ?? ""){return edit.start+delta}
                    return edit.start+delta+edit.text.utf8.count
                }
                delta+=edit.text.utf8.count-(edit.end-edit.start)
            };return position+delta
        }
        let restored=selections.map{["anchor":NSNumber(value:mapped($0["anchor"]!.intValue)),"caret":NSNumber(value:mapped($0["caret"]!.intValue))]}
        return Plan(text:String(decoding:result,as:UTF8.self),selections:restored)
    }
    func apply(to editor:TTEditor,profile:LanguageProfile)throws {
        guard editor.window != nil,!editor.readOnly else{throw LanguageError.invalid("The comment command requires a writable open document.")}
        let original=editor.text,revision=editor.revision,selections=editor.selectionRanges
        let proposed=try plan(text:original,selections:selections,profile:profile)
        guard proposed.text != original else{return}
        guard editor.revision==revision,editor.selectionRanges==selections else{throw LanguageError.invalid("The document changed; comments were not applied.")}
        editor.beginUndoGroup();defer{editor.endUndoGroup()}
        guard editor.setSelectionAnchor(0,caret:original.utf8.count) else{throw LanguageError.invalid("Could not select the document.")}
        editor.replaceSelection(proposed.text)
        _ = editor.setSelectionRanges(proposed.selections)
    }
}
