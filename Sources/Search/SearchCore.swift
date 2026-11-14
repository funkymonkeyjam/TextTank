// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct SearchOptions: Codable, Equatable, Sendable {
    enum Mode: Int, Codable, Sendable { case normal=0, extended=1, regularExpression=2 }
    var query="",replacement=""
    var mode:Mode = .normal
    var matchCase=false,wholeWord=false,dotMatchesNewline=false,wrap=true
}
struct SearchHit {
    let range:NSRange
    let replacement:String
}
struct SearchReport {
    let hits:[SearchHit]
    let truncated:Bool
}
enum SearchCore {
    static func search(_ text:String,options:SearchOptions,cancellation:TTSearchCancellation=TTSearchCancellation(),limit:Int=100000,timeLimit:TimeInterval=2)throws->SearchReport {
        let result=try TTSearchEngine.matches(inText:text,query:options.query,replacement:options.replacement,mode:options.mode.rawValue,matchCase:options.matchCase,wholeWord:options.wholeWord,dotMatchesNewline:options.dotMatchesNewline,cancellation:cancellation,maximumMatches:limit,timeLimit:timeLimit)
        let rows=result["matches"] as? [[String:Any]] ?? []
        return SearchReport(hits:rows.map{SearchHit(range:($0["range"] as! NSValue).rangeValue,replacement:$0["replacement"] as! String)},truncated:result["truncated"] as? Bool ?? false)
    }
    static func byteRange(_ range:NSRange,in text:String)->NSRange? {
        let units=Array(text.utf16)
        func boundary(_ i:Int)->Bool { i==0 || i==units.count || !(units[i]>=0xDC00 && units[i]<=0xDFFF && units[i-1]>=0xD800 && units[i-1]<=0xDBFF) }
        guard range.location>=0,range.length>=0,range.location<=units.count,range.length<=units.count-range.location,boundary(range.location),boundary(NSMaxRange(range)),let swiftRange=Range(range,in:text) else{return nil}
        return NSRange(location:text[..<swiftRange.lowerBound].utf8.count,length:text[swiftRange].utf8.count)
    }
    /// Linear offset conversion for sorted nonoverlapping matches; avoids copying
    /// a document prefix separately for every replacement.
    static func byteRanges(_ ranges:[NSRange],in text:String)->[NSRange]? {
        var index=text.unicodeScalars.startIndex,units=0,bytes=0,output:[NSRange]=[]
        func advance(_ target:Int)->Bool {
            guard target>=units else{return false}
            while units<target,index<text.unicodeScalars.endIndex {
                let value=text.unicodeScalars[index].value,width=value>0xFFFF ? 2:1
                guard units+width<=target else{return false}
                units+=width;bytes+=value<0x80 ? 1:value<0x800 ? 2:value<0x10000 ? 3:4
                index=text.unicodeScalars.index(after:index)
            };return units==target
        }
        for range in ranges {
            guard range.location>=0,range.length>=0,range.length<=Int.max-range.location,advance(range.location) else{return nil}
            let start=bytes;guard advance(NSMaxRange(range)) else{return nil}
            output.append(NSRange(location:start,length:bytes-start))
        };return output
    }
    static func utf16Range(_ range:NSRange,in text:String)->NSRange? {
        let bytes=text.utf8
        guard range.location>=0,range.length>=0,range.location<=bytes.count,range.length<=bytes.count-range.location else{return nil}
        let start=bytes.index(bytes.startIndex,offsetBy:range.location),end=bytes.index(start,offsetBy:range.length)
        guard let a=start.samePosition(in:text),let b=end.samePosition(in:text) else{return nil}
        return NSRange(a..<b,in:text)
    }
    static func replacing(_ text:String,with hits:[SearchHit])throws->String {
        let result=NSMutableString(string:text),source=text as NSString
        func boundary(_ i:Int)->Bool { i==0 || i==source.length || !(source.character(at:i)>=0xDC00 && source.character(at:i)<=0xDFFF && source.character(at:i-1)>=0xD800 && source.character(at:i-1)<=0xDBFF) }
        var previous=source.length
        for hit in hits.reversed() {
            guard hit.range.location>=0,hit.range.length>=0,hit.range.location<=previous,hit.range.length<=previous-hit.range.location,boundary(hit.range.location),boundary(NSMaxRange(hit.range)) else {throw NSError(domain:"TextTank.Search",code:3,userInfo:[NSLocalizedDescriptionKey:"Invalid or overlapping replacement range."])}
            result.replaceCharacters(in:hit.range,with:hit.replacement);previous=hit.range.location
        }
        return result as String
    }
}
