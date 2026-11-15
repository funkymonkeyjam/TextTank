import Foundation
@main struct SearchChecks {
    static func main() throws {
        var checks=0
        func check(_ value:Bool,_ label:String){precondition(value,label);checks+=1;print("PASS \(label)")}
        func search(_ text:String,_ query:String,_ replacement:String="",mode:SearchOptions.Mode = .regularExpression,caseSensitive:Bool=true,whole:Bool=false,dot:Bool=false)throws->SearchReport {
            var o=SearchOptions();o.query=query;o.replacement=replacement;o.mode=mode;o.matchCase=caseSensitive;o.wholeWord=whole;o.dotMatchesNewline=dot;return try SearchCore.search(text,options:o)
        }
        let literal=try search("a.b aXb a.b","a.b","X",mode:.normal)
        check(literal.hits.count==2,"normal mode is literal")
        check(try SearchCore.replacing("a.b aXb a.b",with:literal.hits)=="X aXb X","literal replace all exact")
        let extended=try search("x\r\ny\tz\0","\\r\\n","\\x41\\d066\\o103\\b01000100\\u0045",mode:.extended)
        check(try SearchCore.replacing("x\r\ny\tz\0",with:extended.hits)=="xABCDEy\tz\0","extended numeric replacement forms")
        check(TTSearchEngine.decodeExtended("\\q\\xQ0\\u123\\")=="\\q\\xQ0\\u123\\","unknown and malformed extended escapes remain literal")
        check(TTSearchEngine.decodeExtended("\\0")=="\0","extended NUL preserved")
        check(try search("a\0b","\\0",mode:.extended).hits.first?.range==NSRange(location:1,length:1),"NUL search is length aware")
        let capture=try search("one=12 two=34","(?<key>[a-z]+)=(\\d+)","$+{key}:$2")
        check(try SearchCore.replacing("one=12 two=34",with:capture.hits)=="one:12 two:34","Boost named and numbered replacement captures")
        check(try search("abc123","abc\\K\\d+").hits.first?.range==NSRange(location:3,length:3),"Boost reset-match operator")
        check(try search("ab ac","(?<=a)b").hits.count==1,"Boost lookbehind")
        check(try search("a\nb","a.b").hits.isEmpty,"dot excludes newline by default")
        check(try search("a\nb","a.b",dot:true).hits.count==1,"dot newline option")
        check(try search("cat scatter Cat cat_","cat",mode:.normal,caseSensitive:false,whole:true).hits.count==2,"whole word and case options")
        let empty=try search("ab","(?=.)|$","_")
        check(empty.hits.map{$0.range.location}==[0,1,2],"zero length matches progress and include end")
        check(try SearchCore.replacing("ab",with:empty.hits)=="_a_b_","zero length replacement order")
        check(try search("🥑 café","café").hits.first?.range==NSRange(location:3,length:4),"UTF16 range after astral Unicode")
        check(SearchCore.byteRange(NSRange(location:3,length:4),in:"🥑 café")==NSRange(location:5,length:5),"UTF16 to UTF8 exact")
        check(SearchCore.byteRanges([NSRange(location:0,length:2),NSRange(location:3,length:4)],in:"🥑 café")==[NSRange(location:0,length:4),NSRange(location:5,length:5)],"linear multiple Unicode offsets")
        check(SearchCore.utf16Range(NSRange(location:5,length:5),in:"🥑 café")==NSRange(location:3,length:4),"UTF8 to UTF16 exact")
        check(SearchCore.byteRange(NSRange(location:1,length:1),in:"🥑")==nil,"surrogate split rejected")
        // F34: byte conversion is scalar-granular, not grapheme-granular, and total.
        check(SearchCore.byteRange(NSRange(location:0,length:2),in:"a\r\nb")==NSRange(location:0,length:2),"byte range may end between CR and LF")
        check(SearchCore.byteRange(NSRange(location:0,length:1),in:"e\u{301}x")==NSRange(location:0,length:1),"byte range may end before a combining mark")
        check(SearchCore.byteRange(NSRange(location:4,length:0),in:"abc")==nil && SearchCore.byteRange(NSRange(location:2,length:2),in:"abc")==nil,"out-of-range byte conversion rejected")
        check(SearchCore.byteRange(NSRange(location:-1,length:1),in:"abc")==nil && SearchCore.byteRange(NSRange(location:1,length:-1),in:"abc")==nil,"negative byte conversion rejected")
        check(SearchCore.byteRange(NSRange(location:3,length:0),in:"abc")==NSRange(location:3,length:0) && SearchCore.byteRange(NSRange(location:0,length:0),in:"")==NSRange(location:0,length:0),"empty range at end converts")
        let cafes=try search("🥑 café café","café","X",mode:.normal)
        let second=SearchCore.hits(cafes.hits,selectedBy:NSRange(location:11,length:5),in:"🥑 café café")
        check(cafes.hits.count==2 && second.count==1 && second[0].range==NSRange(location:8,length:4),"byte selection after astral and non-ASCII prefix picks exactly that hit")
        let crHits=try search("a\r\nb a\r\nb","a\\r","X",mode:.extended)
        let crPicked=SearchCore.hits(crHits.hits,selectedBy:NSRange(location:5,length:2),in:"a\r\nb a\r\nb")
        check(crHits.hits.count==2 && crPicked.count==1 && crPicked[0].range==NSRange(location:5,length:2),"selection ending between CR and LF picks that hit")
        check(SearchCore.hits(cafes.hits,selectedBy:NSRange(location:11,length:4),in:"🥑 café café").isEmpty && SearchCore.hits(cafes.hits,selectedBy:NSRange(location:11,length:0),in:"🥑 café café").isEmpty && SearchCore.hits(cafes.hits,selectedBy:NSRange(location:0,length:4),in:"🥑 café café").isEmpty,"partial, caret-only and non-hit selections pick nothing")
        check(SearchCore.hits([],selectedBy:NSRange(location:0,length:0),in:"abc").isEmpty && SearchCore.hits([SearchHit(range:NSRange(location:1,length:1),replacement:"")],selectedBy:NSRange(location:0,length:4),in:"🥑").isEmpty,"no hits or an unmappable hit pick nothing")
        let manyLine="é needle 0123456789 0123456789 0123456\n",manyText=String(repeating:manyLine,count:50000)
        let manyHits=(0..<50000).map{SearchHit(range:NSRange(location:$0*manyLine.utf16.count+2,length:6),replacement:"X")}
        let manyStart=Date(),manyPicked=SearchCore.hits(manyHits,selectedBy:NSRange(location:49999*manyLine.utf8.count+3,length:6),in:manyText)
        check(manyPicked.count==1 && manyPicked[0].range.location==49999*manyLine.utf16.count+2 && Date().timeIntervalSince(manyStart)<5,"50000 hits in a 2 MB document matched against the selection in one linear pass")
        check(SearchCore.utf16Range(NSRange(location:1,length:2),in:"🥑")==nil,"UTF8 interior rejected")
        var failed=false;do{_ = try search("text","(")}catch{failed=true};check(failed,"malformed Boost pattern rejected")
        failed=false;do{_ = try search("🥑",".")}catch{failed=true};check(failed,"regex splitting surrogate rejected before mutation")
        failed=false;do{_ = try search("🥑","(.).","$1")}catch{failed=true};check(failed,"replacement capture splitting surrogate rejected")
        // F20/G343: extended escapes must not inject unpaired surrogates into matches or replacements.
        for (text,query,replacement,label) in [("x😀y","\\uD83D","","lone high-surrogate query"),("x😀y","\\uDE00","","lone low-surrogate query"),("a","a","\\uD83D","lone high-surrogate replacement"),("a","a","\\uDE00","lone low-surrogate replacement"),("a","a","\\uDE00\\uD83D","reversed surrogate replacement")] {
            failed=false;var message="";do{_ = try search(text,query,replacement,mode:.extended)}catch{failed=true;message=error.localizedDescription}
            check(failed && message.contains("surrogate"),"extended \(label) rejected with an explanation")
        }
        check(try search("x😀y","\\uD83D\\uDE00",mode:.extended).hits.map(\.range)==[NSRange(location:1,length:2)],"extended surrogate pair written as two escapes matches the whole character")
        let paired=try search("x😀y","x","\\uD83D\\uDE00",mode:.extended)
        check(try SearchCore.replacing("x😀y",with:paired.hits)=="😀😀y","extended surrogate pair replacement stays valid")
        var options=SearchOptions();options.query="a";options.mode = .regularExpression
        let limited=try SearchCore.search("aaa",options:options,limit:2)
        check(limited.truncated && limited.hits.count==2,"result cap explicit")
        let cancelled=TTSearchCancellation();cancelled.cancel();failed=false
        do{_ = try SearchCore.search("aaa",options:options,cancellation:cancelled)}catch{failed=true};check(failed,"pre-cancelled search rejected")
        options.query="(a+)+$";let start=Date();failed=false
        do{_ = try SearchCore.search(String(repeating:"a",count:100)+"!",options:options,timeLimit:0.05)}catch{failed=true}
        check(failed && Date().timeIntervalSince(start)<1,"pathological Boost pattern bounded under one second")
        let token=TTSearchCancellation();DispatchQueue.global().asyncAfter(deadline:.now()+0.02){token.cancel()};let cancelStart=Date();failed=false
        do{_ = try SearchCore.search(String(repeating:"a",count:200)+"!",options:options,cancellation:token,timeLimit:5)}catch{failed=true}
        check(failed && Date().timeIntervalSince(cancelStart)<1,"active Boost search cancellation bounded")
        failed=false;do{_ = try SearchCore.replacing("abcd",with:[SearchHit(range:NSRange(location:0,length:3),replacement:"X"),SearchHit(range:NSRange(location:2,length:1),replacement:"Y")])}catch{failed=true};check(failed,"overlap rejected before edits")
        options.query=String(repeating:"(",count:10000)+"a"+String(repeating:")",count:10000);failed=false;let compileStart=Date()
        do{_ = try SearchCore.search("a",options:options,timeLimit:0.1)}catch{failed=true}
        check(failed && Date().timeIntervalSince(compileStart)<1,"deeply nested pattern compilation rejects safely")
        check(try SearchCore.bookmarkLines(in:"a\r\nb\rc\n🥑",locations:[0,1,2,3,4,5,6,7,9],cancellation:TTSearchCancellation()) == [0,1,2,3],"bookmark CRLF CR LF Unicode offsets linear")
        check(try SearchCore.bookmarkLines(in:"abc",locations:[],cancellation:TTSearchCancellation()).isEmpty,"empty bookmarks")
        failed=false;do{_ = try SearchCore.bookmarkLines(in:"abc",locations:[0],cancellation:cancelled)}catch{failed=true};check(failed,"bookmark pre-cancellation")
        failed=false;do{_ = try SearchCore.bookmarkLines(in:"abc",locations:[2,1],cancellation:TTSearchCancellation())}catch{failed=true};check(failed,"bookmark reversed offsets reject")
        let denseStart=Date();check(try SearchCore.bookmarkLines(in:String(repeating:"x\n",count:100000),locations:Array(stride(from:0,to:200000,by:2)),cancellation:TTSearchCancellation()).count==100000 && Date().timeIntervalSince(denseStart)<2,"dense bookmark offsets bounded linear pass")
        print("PASS SearchChecks: \(checks) assertions")
    }
}
