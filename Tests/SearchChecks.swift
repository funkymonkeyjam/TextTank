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
        check(SearchCore.utf16Range(NSRange(location:1,length:2),in:"🥑")==nil,"UTF8 interior rejected")
        var failed=false;do{_ = try search("text","(")}catch{failed=true};check(failed,"malformed Boost pattern rejected")
        failed=false;do{_ = try search("🥑",".")}catch{failed=true};check(failed,"regex splitting surrogate rejected before mutation")
        failed=false;do{_ = try search("🥑","(.).","$1")}catch{failed=true};check(failed,"replacement capture splitting surrogate rejected")
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
        print("PASS SearchChecks: \(checks) assertions")
    }
}
