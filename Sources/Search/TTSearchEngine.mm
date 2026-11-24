// SPDX-License-Identifier: GPL-3.0-or-later
#import "TTSearchEngine.h"
#include <atomic>
#include <chrono>
#include <locale>
#include <memory>
#include <cstring>
#include <algorithm>
#include <mutex>
#include <string>
#include <stdexcept>
#include <vector>
#define BOOST_REGEX_STANDALONE
// Standalone Boost.Regex does not include Boost.Config, so nothing else defines this. Without it
// the traits cache and the matcher's memory-block cache are unlocked, and two searches on
// different threads (a folder search and the Find window, say) corrupt them.
#define BOOST_HAS_THREADS
#include <boost/regex.hpp>

@implementation TTSearchCancellation { std::atomic<bool> _cancelled; }
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (instancetype)init { if ((self=[super init])) _cancelled=false; return self; }
- (void)cancel { _cancelled=true; }
- (BOOL)cancelled { return _cancelled.load(); }
@end
@implementation TTSearchMatch
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (instancetype)initWithRange:(NSRange)range replacement:(NSString *)replacement { if ((self=[super init])) { _range=range; _replacement=[replacement copy]; } return self; }
@end
@implementation TTSearchResult
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (instancetype)initWithMatches:(NSArray<TTSearchMatch *> *)matches truncated:(BOOL)truncated { if ((self=[super init])) { _matches=[matches copy]; _truncated=truncated; } return self; }
@end
namespace {
struct SearchTimeLimit : std::runtime_error { using std::runtime_error::runtime_error; };
struct InvalidPattern : std::runtime_error { using std::runtime_error::runtime_error; };
struct Budget {
    TTSearchCancellation *cancellation;
    std::chrono::steady_clock::time_point deadline;
    mutable size_t operations=0;
    void check() const {
        if ((++operations & 1023)==0) {
            if (cancellation.cancelled) throw std::runtime_error("Search cancelled; no replacement was applied.");
            if (std::chrono::steady_clock::now()>deadline) throw SearchTimeLimit("Search exceeded its time budget; narrow the scope or simplify the pattern.");
        }
    }
};
/// The regex runs over Unicode code points (wchar_t is 32 bits on macOS), so one character is one
/// element for `.`, classes and quantifiers and a match can never split a surrogate pair. This
/// departs on purpose from the reference Windows iterator, which walks UTF-16 code units. Reported
/// ranges are converted back to UTF-16.
struct CheckedIterator {
    using iterator_category=std::bidirectional_iterator_tag;
    using value_type=wchar_t; using difference_type=ptrdiff_t;
    using pointer=const wchar_t*; using reference=const wchar_t&;
    const wchar_t *position=nullptr; Budget *budget=nullptr;
    reference operator*() const {budget->check();return *position;}
    CheckedIterator& operator++(){budget->check();++position;return *this;}
    CheckedIterator& operator--(){budget->check();--position;return *this;}
    CheckedIterator operator++(int){auto old=*this;++*this;return old;}
    CheckedIterator operator--(int){auto old=*this;--*this;return old;}
    bool operator==(const CheckedIterator&o)const{return position==o.position;}
    bool operator!=(const CheckedIterator&o)const{return position!=o.position;}
};
const NSUInteger maximumUnits=64*1024*1024;
bool high(unsigned c){return c>=0xD800&&c<=0xDBFF;}
bool low(unsigned c){return c>=0xDC00&&c<=0xDFFF;}
/// Appends the code points of `range` with one bulk copy per chunk. An unpaired surrogate is kept
/// as its own value, so malformed text is still searchable. `range` must not split a pair.
void appendCodePoints(std::wstring &out,NSString *s,NSRange range){
    const NSUInteger chunkSize=65536,end=NSMaxRange(range);
    std::vector<unichar> chunk(std::min(range.length,chunkSize));
    out.reserve(out.size()+range.length);
    for(NSUInteger i=range.location;i<end;){
        NSUInteger n=std::min(end-i,chunkSize);
        [s getCharacters:chunk.data() range:NSMakeRange(i,n)];
        if(n>1&&high(chunk[n-1])&&i+n<end)--n; // decode a pair that straddles two chunks in the next one
        for(NSUInteger k=0;k<n;k++){
            unichar c=chunk[k];
            if(high(c)&&k+1<n&&low(chunk[k+1])){out.push_back((wchar_t)(0x10000+((c-0xD800)<<10)+(chunk[k+1]-0xDC00)));++k;}
            else out.push_back(c);
        }
        i+=n;
    }
}
std::wstring codePoints(NSString *s){std::wstring out;appendCodePoints(out,s,NSMakeRange(0,s.length));return out;}
bool validUnits(const unichar *s,size_t count){for(size_t i=0;i<count;i++){if(high(s[i])){if(i+1==count||!low(s[i+1]))return false;++i;}else if(low(s[i]))return false;}return true;}
bool validUnits(NSString *s){std::vector<unichar> units(s.length);[s getCharacters:units.data() range:NSMakeRange(0,s.length)];return validUnits(units.data(),units.size());}
/// Encodes code points as UTF-16. Output that would hold half a surrogate pair is refused, so no
/// half character is ever written.
NSString *stringUnits(const std::wstring&s){
    std::vector<unichar> out;out.reserve(s.size());
    for(auto value:s){
        auto c=(uint32_t)value;
        if(c>0x10FFFF)throw std::runtime_error("The replacement produces a value outside Unicode; no edits were applied.");
        if(c>0xFFFF){out.push_back((unichar)(0xD800+((c-0x10000)>>10)));out.push_back((unichar)(0xDC00+((c-0x10000)&0x3FF)));}
        else out.push_back((unichar)c);
    }
    if(!validUnits(out.data(),out.size()))throw std::runtime_error("The replacement produces an incomplete Unicode surrogate pair; no edits were applied.");
    return [[NSString alloc]initWithCharacters:out.data() length:out.size()];
}
size_t unitCount(const std::wstring&s){size_t count=s.size();for(auto c:s)if((uint32_t)c>0xFFFF)++count;return count;}
bool boundary(NSString *s,NSUInteger i){return i==0||i==s.length||!(low([s characterAtIndex:i])&&high([s characterAtIndex:i-1]));}
bool word(unichar c){return c=='_'||[[NSCharacterSet alphanumericCharacterSet]characterIsMember:c];}
bool word(unichar highUnit,unichar lowUnit){return [[NSCharacterSet alphanumericCharacterSet]longCharacterIsMember:0x10000+((UTF32Char)(highUnit-0xD800)<<10)+(lowUnit-0xDC00)];}
/// Whether the character ending at `i` is a word character. Only a low surrogate preceded by a
/// high one is combined, so a unit inside a match is never joined with one outside it.
bool wordBefore(NSString *s,NSUInteger i){
    if(i==0)return false;
    unichar c=[s characterAtIndex:i-1];
    if(low(c)&&i>=2&&high([s characterAtIndex:i-2]))return word([s characterAtIndex:i-2],c);
    return word(c);
}
/// Whether the character starting at `i` is a word character.
bool wordAfter(NSString *s,NSUInteger i){
    if(i>=s.length)return false;
    unichar c=[s characterAtIndex:i];
    if(high(c)&&i+1<s.length&&low([s characterAtIndex:i+1]))return word(c,[s characterAtIndex:i+1]);
    return word(c);
}
/// Per-regex UTF-8 locale: case folding and \w, \b, \s follow Unicode without touching the
/// process-wide locale, which Scintilla and number formatting depend on.
const std::locale &unicodeLocale(){
    static const std::locale locale=[]{try{return std::locale("en_US.UTF-8");}catch(...){return std::locale::classic();}}();
    return locale;
}
/// \d and [[:digit:]] stay 0-9 as before the Unicode locale: a class asking for digits without
/// letters takes only ASCII digits. \w and [[:alnum:]] ask for letters too and stay Unicode-wide,
/// in step with the Whole word test.
struct SearchTraits:boost::regex_traits<wchar_t>{
    bool isctype(wchar_t c,char_class_type mask)const{
        const char_class_type digit=std::ctype_base::digit,alpha=std::ctype_base::alpha;
        if((mask&digit)&&!(mask&alpha))return (c>=L'0'&&c<=L'9')||((mask&~digit)&&boost::regex_traits<wchar_t>::isctype(c,mask&~digit));
        return boost::regex_traits<wchar_t>::isctype(c,mask);
    }
};
using SearchRegex=boost::basic_regex<wchar_t,SearchTraits>;
std::atomic<NSUInteger> compilations{0};
/// One-entry cache, so a folder search compiles its pattern once and not once per file. A compiled
/// boost regex is immutable shared state; every search works on its own copy of the handle.
SearchRegex compiledRegex(const std::wstring &pattern,bool matchCase){
    static std::mutex mutex;static bool cached=false,cachedCase=false;static std::wstring cachedPattern;static SearchRegex cachedRegex;
    {std::lock_guard<std::mutex> lock(mutex);if(cached&&cachedCase==matchCase&&cachedPattern==pattern)return cachedRegex;}
    SearchRegex regex;regex.imbue(unicodeLocale());
    regex.assign(pattern,boost::regex::ECMAScript|(matchCase?0:boost::regex::icase));
    ++compilations;
    std::lock_guard<std::mutex> lock(mutex);cached=true;cachedCase=matchCase;cachedPattern=pattern;cachedRegex=regex;
    return regex;
}

/// UTF-8 helpers for the chunked search. Positions handed to them are scalar boundaries.
bool continuationByte(uint8_t b){return (b&0xC0)==0x80;}
/// The scalar that starts at `i`, and its length in bytes. Malformed input counts as one byte.
uint32_t scalarAt(const uint8_t *p,size_t n,size_t i,size_t *length){
    const uint8_t b=p[i];
    const size_t need=b<0x80?1:(b>>5)==6?2:(b>>4)==14?3:(b>>3)==30?4:0;
    *length=1;
    if(need==0||i+need>n)return 0xFFFD;
    if(need==1)return b;
    uint32_t c=need==2?(b&0x1F):need==3?(b&0x0F):(b&0x07);
    for(size_t k=1;k<need;k++){if(!continuationByte(p[i+k]))return 0xFFFD;c=(c<<6)|(p[i+k]&0x3F);}
    *length=need;return c;
}
/// Where the scalar that ends at `i` starts; `i` is greater than `floor`.
size_t scalarStartBefore(const uint8_t *p,size_t floor,size_t i){
    size_t s=i-1;for(int k=0;k<3&&s>floor&&continuationByte(p[s]);k++)--s;return s;
}
bool wordScalar(uint32_t c){return c=='_'||[[NSCharacterSet alphanumericCharacterSet]longCharacterIsMember:c];}
bool wordBeforeByte(const uint8_t *p,size_t n,size_t i){
    if(i==0)return false;
    size_t length=0;return wordScalar(scalarAt(p,n,scalarStartBefore(p,0,i),&length));
}
bool wordAfterByte(const uint8_t *p,size_t n,size_t i){
    if(i>=n)return false;
    size_t length=0;return wordScalar(scalarAt(p,n,i,&length));
}
/// One decoded window of the document, for matching that needs Unicode case folding. It maps
/// between UTF-16 offsets in the window and byte offsets in the document with a cursor that
/// moves either way, so each window is walked once however many matches it holds.
struct FoldedWindow {
    NSString *string=nil;size_t byteStart=0;std::vector<unichar> units;bool ascii=true;
    size_t unit=0,byte=0;
    FoldedWindow(const uint8_t *p,size_t start,size_t end):byteStart(start){
        string=[[NSString alloc]initWithBytesNoCopy:(void *)(p+start) length:end-start encoding:NSUTF8StringEncoding freeWhenDone:NO];
        if(!string)throw std::runtime_error("This document holds bytes that are not valid UTF-8, so it can only be searched with Match case on. Turn on Match case and search again.");
        ascii=string.length==end-start;
        if(!ascii){units.resize(string.length);[string getCharacters:units.data() range:NSMakeRange(0,string.length)];}
        byte=start;
    }
    static size_t width(unichar c){return c<0x80?1:c<0x800?2:3;}
    /// The byte offset in the document of UTF-16 offset `target` in the window.
    size_t byteAt(size_t target){
        if(ascii)return byteStart+target;
        while(unit<target){if(high(units[unit])&&unit+1<units.size()&&low(units[unit+1])){if(unit+2>target)break;byte+=4;unit+=2;}else{byte+=width(units[unit]);++unit;}}
        while(unit>target){if(low(units[unit-1])&&unit>=2&&high(units[unit-2])){if(unit-2<target)break;byte-=4;unit-=2;}else{byte-=width(units[unit-1]);--unit;}}
        return byte;
    }
    /// The UTF-16 offset in the window of byte offset `target` in the document.
    size_t unitAt(size_t target){
        if(ascii)return target-byteStart;
        while(byte<target&&unit<units.size()){if(high(units[unit])&&unit+1<units.size()&&low(units[unit+1])){byte+=4;unit+=2;}else{byte+=width(units[unit]);++unit;}}
        while(byte>target&&unit>0){if(low(units[unit-1])&&unit>=2&&high(units[unit-2])){byte-=4;unit-=2;}else{byte-=width(units[unit-1]);--unit;}}
        return unit;
    }
};
const NSUInteger defaultChunkBytes=4*1024*1024;
}
@implementation TTSearchEngine
+ (BOOL)isTimeLimitError:(NSError *)error {
    return [error.domain isEqualToString:@"TextTank.Search"] && [error.userInfo[@"TextTankSearchTimeLimit"] boolValue];
}
+ (NSString *)decodeExtended:(NSString *)text {
    NSMutableString *out=[NSMutableString string];
    for(NSUInteger i=0;i<text.length;i++) {
        unichar c=[text characterAtIndex:i];
        if(c!='\\'||i+1==text.length){[out appendFormat:@"%C",c];continue;}
        c=[text characterAtIndex:++i];
        switch(c){case 'r':c='\r';break;case 'n':c='\n';break;case 't':c='\t';break;case '0':c=0;break;case '\\':break;
        default:{int count=0,base=0;switch(c){case 'b':count=8;base=2;break;case 'o':count=3;base=8;break;case 'd':count=3;base=10;break;case 'x':count=2;base=16;break;case 'u':count=4;base=16;break;}
            bool ok=count>0&&i+count<text.length;int value=0;
            for(int j=1;ok&&j<=count;j++){unichar d=[text characterAtIndex:i+j];int v=d>='0'&&d<='9'?d-'0':d>='A'&&d<='F'?d-'A'+10:d>='a'&&d<='f'?d-'a'+10:-1;if(v<0||v>=base)ok=false;else value=value*base+v;}
            if(ok){c=(unichar)value;i+=count;}else [out appendString:@"\\"];
        }}[out appendFormat:@"%C",c];
    }return out;
}
+ (NSUInteger)regexCompilationCount { return compilations.load(); }
+ (BOOL)isInvalidPatternError:(NSError *)error {
    return [error.domain isEqualToString:@"TextTank.Search"] && [error.userInfo[@"TextTankSearchInvalidPattern"] boolValue];
}
+ (NSUInteger)maximumTextUnits { return maximumUnits; }
+ (NSUInteger)utf16LengthOfUTF8:(NSData *)data {
    const uint8_t *p=(const uint8_t *)data.bytes;const size_t n=data.length;size_t units=0;
    // Every byte that starts a scalar is one unit; a four-byte scalar is a surrogate pair.
    // Eight bytes at a time: a continuation byte has its top bit set and the next one clear, and
    // the lead byte of a four-byte scalar has its top four bits set.
    const uint64_t top=0x8080808080808080ULL;size_t i=0;
    for(;i+8<=n;i+=8){
        uint64_t w;memcpy(&w,p+i,8);
        const uint64_t continuation=(w&top)&~((w<<1)&top),four=w&(w<<1)&(w<<2)&(w<<3)&top;
        units+=8-(size_t)__builtin_popcountll(continuation)+(size_t)__builtin_popcountll(four);
    }
    for(;i<n;i++){units+=(p[i]&0xC0)!=0x80;units+=p[i]>=0xF0;}
    return units;
}
+ (TTSearchResult *)searchUTF8:(NSData *)data range:(NSRange)scope query:(NSString *)query replacement:(NSString *)replacement mode:(TTSearchMode)mode matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord backwards:(BOOL)backwards overlapping:(BOOL)overlapping maximumMatches:(NSInteger)maximumMatches stopAtLimit:(BOOL)stopAtLimit chunkBytes:(NSUInteger)chunkBytes cancellation:(TTSearchCancellation *)cancellation timeLimit:(NSTimeInterval)timeLimit progress:(void (NS_NOESCAPE ^)(NSUInteger))progress error:(NSError **)error {
    @try { try {
        const uint8_t *p=(const uint8_t *)data.bytes;const size_t n=data.length;
        if(mode==TTSearchModeRegularExpression)throw std::runtime_error("A regular expression cannot search a document this large. Select part of the document and search the selection, or change the search mode to Normal.");
        if(mode<0||mode>2)throw std::runtime_error("Unknown search mode.");
        if(query.length==0)throw std::runtime_error("Enter a nonempty search expression.");
        if(query.length>65536)throw std::runtime_error("The search expression is longer than the 64 Ki UTF-16 limit.");
        if(replacement.length>1024*1024)throw std::runtime_error("The replacement is longer than the 1 Mi UTF-16 limit.");
        if(maximumMatches<1||maximumMatches>100000)throw std::runtime_error("The result limit must be between 1 and 100,000.");
        if(!(timeLimit>0&&timeLimit<=600))throw std::runtime_error("The large-document search time limit must be more than 0 and at most 600 seconds.");
        if(chunkBytes==0)chunkBytes=defaultChunkBytes;
        if(chunkBytes<16||chunkBytes>256*1024*1024)throw std::runtime_error("The search window must be between 16 bytes and 256 MiB.");
        const size_t first=scope.location,rangeEnd=first+scope.length;
        if(scope.location>n||scope.length>n-scope.location||(first<n&&continuationByte(p[first]))||(rangeEnd<n&&continuationByte(p[rangeEnd])))throw std::runtime_error("The search range is outside the text or splits a character.");
        if(cancellation.cancelled)throw std::runtime_error("Search cancelled; no replacement was applied.");
        NSString *needle=mode==TTSearchModeExtended?[self decodeExtended:query]:query;
        NSString *replacementText=mode==TTSearchModeExtended?[self decodeExtended:replacement]:replacement;
        if(needle.length==0)throw std::runtime_error("Enter a nonempty search expression.");
        if(!validUnits(needle))throw std::runtime_error("The search text contains an incomplete Unicode surrogate pair; write both \\u halves or the full character.");
        if(!validUnits(replacementText))throw std::runtime_error("The replacement contains an incomplete Unicode surrogate pair; no edits were applied.");
        NSData *needleData=[needle dataUsingEncoding:NSUTF8StringEncoding];
        if(!needleData)throw std::runtime_error("The search text cannot be written as UTF-8.");
        const uint8_t *needleBytes=(const uint8_t *)needleData.bytes;const size_t needleLength=needleData.length;
        // The most bytes one match can cover. Case folding can match one character of the search
        // text against up to three characters of the document ("\uFB03" against "FFI", U+0390 against
        // its three-scalar decomposition), each of at most four bytes, so twelve bytes per UTF-16
        // unit of the search text is a safe ceiling. The window overlap is this long.
        const size_t longest=matchCase?needleLength:12*needle.length+16;
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds((long long)(timeLimit*1000));
        auto checkBudget=[&]{
            if(cancellation.cancelled)throw std::runtime_error("Search cancelled; no replacement was applied.");
            if(std::chrono::steady_clock::now()>deadline)throw SearchTimeLimit("Search exceeded its time budget; narrow the scope.");
        };
        const NSStringCompareOptions folded=NSLiteralSearch|NSCaseInsensitiveSearch;
        NSMutableArray<TTSearchMatch *> *matches=[NSMutableArray array];bool truncated=false;size_t outputSize=0;
        // Returns false when the result limit stops the search.
        auto consider=[&](size_t start,size_t length,bool *accepted){
            *accepted=!wholeWord||(!wordBeforeByte(p,n,start)&&!wordAfterByte(p,n,start+length));
            if(!*accepted)return true;
            if(matches.count>=(NSUInteger)maximumMatches){truncated=true;return false;}
            outputSize+=replacementText.length;
            if(outputSize>maximumUnits)throw std::runtime_error("Replacement expansion exceeded the 64 Mi UTF-16 safety limit.");
            [matches addObject:[[TTSearchMatch alloc]initWithRange:NSMakeRange(start,length) replacement:replacementText]];
            // Navigation wants the nearest match and nothing after it: stop here, so that no
            // further window is read and a later deadline cannot discard the match in hand.
            return !(stopAtLimit&&matches.count>=(NSUInteger)maximumMatches);
        };
        // Work is bounded between two looks at Cancel and the deadline, inside a window too: a
        // long search text with a repetitive start can cost its whole length at every position.
        const size_t workStep=1024*1024;size_t work=0;
        auto spend=[&](size_t amount){work+=amount;if(work>=workStep){work=0;checkBudget();}};
        // First exact match that starts at or after `from` and ends by `limit`.
        auto exactForward=[&](size_t from,size_t limit,size_t *start){
            if(limit<from||limit-from<needleLength)return false;
            const size_t last=limit-needleLength;
            for(size_t i=from;i<=last;){
                const void *q=memchr(p+i,needleBytes[0],last-i+1);
                if(!q){spend(last-i+1);return false;}
                const size_t at=(const uint8_t *)q-p;size_t k=1;
                while(k<needleLength&&p[at+k]==needleBytes[k])++k;
                spend(at-i+k);
                if(k==needleLength){*start=at;return true;}
                i=at+1;
            }
            return false;
        };
        // Last exact match that starts at or after `floor` and ends by `to`.
        auto exactBackward=[&](size_t floor,size_t to,size_t *start){
            if(to<floor||to-floor<needleLength)return false;
            for(size_t i=to-needleLength+1;i-->floor;){
                size_t k=0;
                if(p[i]==needleBytes[0]){k=1;while(k<needleLength&&p[i+k]==needleBytes[k])++k;}
                spend(k+1);
                if(k==needleLength){*start=i;return true;}
            }
            return false;
        };
        // Folded matching is searched a slice of the window at a time, sized so that one call
        // costs about the same however long the search text is. A slice reads past its end by
        // the longest match, so the first match found is the first match there is.
        const size_t reachUnits=3*needle.length+2;
        const size_t slice=std::max<size_t>(8,(4*chunkBytes)/needle.length);
        // When the search text is long for the window, that overlap would dominate a slice and
        // one call could again cost the square of the search text's length. Then every position
        // is tried on its own with an anchored comparison, which costs at most the search
        // text's length and is counted as work. A position is skipped without a comparison only
        // when both its character and the search text's first are ASCII and differ beyond case.
        const bool byPosition=slice<4*needle.length;
        const unichar firstUnit=[needle characterAtIndex:0];
        auto lower=[](unichar c){return (unichar)(c>='A'&&c<='Z'?c+32:c);};
        auto mayStart=[&](FoldedWindow &w,size_t unit){
            const unichar c=w.ascii?(unichar)p[w.byteStart+unit]:w.units[unit];
            if(low(c))return false;
            return !(c<0x80&&firstUnit<0x80)||lower(c)==lower(firstUnit);
        };
        // The match that starts exactly at `unit` and ends by `endUnit`, if there is one.
        auto matchAt=[&](FoldedWindow &w,size_t unit,size_t endUnit,size_t *start,size_t *length){
            if(!mayStart(w,unit)){spend(1);return false;}
            spend(needle.length);
            NSRange r=[w.string rangeOfString:needle options:folded|NSAnchoredSearch range:NSMakeRange(unit,std::min(reachUnits,endUnit-unit))];
            if(r.location==NSNotFound)return false;
            *start=w.byteAt(r.location);*length=w.byteAt(NSMaxRange(r))-*start;return true;
        };
        auto foldedForward=[&](FoldedWindow &w,size_t from,size_t *start,size_t *length){
            const size_t total=w.string.length;
            if(byPosition){
                for(size_t unit=w.unitAt(from);unit<total;unit++)if(matchAt(w,unit,total,start,length))return true;
                return false;
            }
            for(size_t unit=w.unitAt(from);unit<total;unit+=slice){
                const size_t end=total-unit>slice+reachUnits?unit+slice+reachUnits:total;
                NSRange r=[w.string rangeOfString:needle options:folded range:NSMakeRange(unit,end-unit)];
                if(r.location!=NSNotFound){*start=w.byteAt(r.location);*length=w.byteAt(NSMaxRange(r))-*start;return true;}
                if(end>=total)return false;
                checkBudget();
            }
            return false;
        };
        auto foldedBackward=[&](FoldedWindow &w,size_t floor,size_t to,size_t *start,size_t *length){
            const size_t lowUnit=w.unitAt(floor),highUnit=w.unitAt(to);
            if(byPosition){
                for(size_t unit=highUnit;unit-->lowUnit;)if(matchAt(w,unit,highUnit,start,length))return true;
                return false;
            }
            for(size_t startHigh=highUnit;;){
                const size_t a=startHigh-lowUnit>slice?startHigh-slice:lowUnit;
                const size_t b=highUnit-startHigh>reachUnits?startHigh+reachUnits:highUnit;
                NSRange r=[w.string rangeOfString:needle options:folded|NSBackwardsSearch range:NSMakeRange(a,b-a)];
                if(r.location!=NSNotFound){*start=w.byteAt(r.location);*length=w.byteAt(NSMaxRange(r))-*start;return true;}
                if(a<=lowUnit)return false;
                startHigh=a;
                checkBudget();
            }
        };
        auto alignDown=[&](size_t i,size_t floor){while(i>floor&&i<n&&continuationByte(p[i]))--i;return i;};
        auto alignUp=[&](size_t i,size_t ceiling){while(i<ceiling&&continuationByte(p[i]))++i;return i;};
        bool stopped=false;
        if(!backwards){
            // `position` is where the next candidate may start. A window takes the matches that
            // start before `coreEnd` and reads far enough past it to hold the longest of them.
            for(size_t position=first;!stopped;){@autoreleasepool{
                checkBudget();
                const size_t coreEnd=rangeEnd-position>chunkBytes?std::max(alignDown(position+chunkBytes,position),position+1):rangeEnd;
                const size_t windowEnd=rangeEnd-coreEnd>longest?alignUp(coreEnd+longest,rangeEnd):rangeEnd;
                std::unique_ptr<FoldedWindow> window;if(!matchCase)window.reset(new FoldedWindow(p,position,windowEnd));
                size_t from=position,inWindow=0;
                while(from<coreEnd){
                    if((++inWindow&255)==0)checkBudget();
                    size_t start=0,length=0;
                    if(matchCase){
                        if(!exactForward(from,windowEnd,&start))break;
                        length=needleLength;
                    }else if(!foldedForward(*window,from,&start,&length))break;
                    if(start>=coreEnd)break; // it belongs to the next window, which finds it again
                    bool accepted=false;
                    if(!consider(start,length,&accepted)){stopped=true;break;}
                    size_t step=0;scalarAt(p,n,start,&step);
                    from=accepted&&!overlapping?start+length:start+step;
                }
                position=std::max(coreEnd,from);
                if(progress)progress(std::min(position,rangeEnd)-first);
                if(coreEnd>=rangeEnd)stopped=true;
            }}
        }else{
            // Mirror image. `ceiling` is where a match must end by; `high` is where the windows
            // already searched begin. Every match that starts at or after `high` and ends by
            // `ceiling` has been taken, so a window never reports one twice.
            for(size_t high=rangeEnd,ceiling=rangeEnd;!stopped;){@autoreleasepool{
                checkBudget();
                const size_t coreStart=high-first>chunkBytes?alignDown(high-chunkBytes,first):first;
                const size_t reach=rangeEnd-high>longest?alignUp(high+longest,rangeEnd):rangeEnd;
                const size_t windowEnd=std::min(reach,ceiling);
                std::unique_ptr<FoldedWindow> window;if(!matchCase&&windowEnd>coreStart)window.reset(new FoldedWindow(p,coreStart,windowEnd));
                size_t to=windowEnd,inWindow=0;
                while(to>coreStart){
                    if((++inWindow&255)==0)checkBudget();
                    size_t start=0,length=0;bool found=false;
                    if(matchCase){found=exactBackward(coreStart,to,&start);length=needleLength;}
                    else found=foldedBackward(*window,coreStart,to,&start,&length);
                    if(!found)break;
                    bool accepted=false;
                    if(!consider(start,length,&accepted)){stopped=true;break;}
                    to=accepted&&!overlapping?start:scalarStartBefore(p,coreStart,start+length);
                    ceiling=to;
                }
                if(progress)progress(rangeEnd-coreStart);
                if(coreStart<=first)stopped=true;
                high=coreStart;
            }}
        }
        return [[TTSearchResult alloc]initWithMatches:matches truncated:truncated];
    } catch(const SearchTimeLimit &e) {
        if (error) *error = [NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()], @"TextTankSearchTimeLimit": @YES
        }];
        return nil;
    } catch(const std::exception&e){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:e.what()]?:@"Search failed safely."}];return nil;}
    catch(...){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Search failed safely."}];return nil;}}
    @catch(NSException *e){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:2 userInfo:@{NSLocalizedDescriptionKey:e.reason?:@"Search failed safely."}];return nil;}
}
+ (TTSearchResult *)searchText:(NSString *)text range:(NSRange)scope query:(NSString *)query replacement:(NSString *)replacement mode:(TTSearchMode)mode matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error {
    return [self searchText:text range:scope query:query replacement:replacement mode:mode matchCase:matchCase wholeWord:wholeWord dotMatchesNewline:dotMatchesNewline cancellation:cancellation maximumMatches:maximumMatches overlappingLiterals:NO timeLimit:timeLimit error:error];
}
+ (TTSearchResult *)searchText:(NSString *)text range:(NSRange)scope query:(NSString *)query replacement:(NSString *)replacement mode:(TTSearchMode)mode matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches overlappingLiterals:(BOOL)overlappingLiterals timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error {
    @try { try {
        if(mode<0||mode>2)throw std::runtime_error("Unknown search mode.");
        if(query.length==0)throw std::runtime_error("Enter a nonempty search expression.");
        if(query.length>65536)throw std::runtime_error("The search expression is longer than the 64 Ki UTF-16 limit.");
        if(text.length>maximumUnits)throw std::runtime_error("This document is too large to search. The limit is 64 Mi UTF-16 units.");
        if(replacement.length>1024*1024)throw std::runtime_error("The replacement is longer than the 1 Mi UTF-16 limit.");
        if(maximumMatches<1||maximumMatches>100000)throw std::runtime_error("The result limit must be between 1 and 100,000.");
        if(!(timeLimit>0&&timeLimit<=30))throw std::runtime_error("The search time limit must be more than 0 and at most 30 seconds.");
        if(scope.location>text.length||scope.length>text.length-scope.location||!boundary(text,scope.location)||!boundary(text,NSMaxRange(scope)))throw std::runtime_error("The search range is outside the text or splits a Unicode surrogate pair.");
        if(cancellation.cancelled)throw std::runtime_error("Search cancelled; no replacement was applied.");
        NSString *needle=mode==1?[self decodeExtended:query]:query;
        NSString *replacementText=mode==1?[self decodeExtended:replacement]:replacement;
        if(needle.length==0)throw std::runtime_error("Enter a nonempty search expression.");
        // Literal and extended text is used as-is, so an unpaired surrogate (for example a lone
        // \\uD83D escape) would delete matches in the editor or be written as U+FFFD by folder
        // replace. Validate the whole decoded strings: a pair written as two escapes stays valid.
        // Regex patterns and formats are not literal text; that path validates its own output.
        if(mode!=2&&!validUnits(needle))throw std::runtime_error("The search text contains an incomplete Unicode surrogate pair; write both \\u halves or the full character.");
        if(mode!=2&&!validUnits(replacementText))throw std::runtime_error("The replacement contains an incomplete Unicode surrogate pair; no edits were applied.");
        Budget budget{cancellation,std::chrono::steady_clock::now()+std::chrono::milliseconds((long long)(timeLimit*1000))};
        NSMutableArray<TTSearchMatch *> *matches=[NSMutableArray array];bool truncated=false;size_t outputSize=0;
        const NSUInteger scopeEnd=NSMaxRange(scope);
        if(mode==2) {
            // The text before the range is decoded too and handed to Boost as `base`, so ^, \b, \A
            // and lookbehind at the start of the range see the real document. Boost cannot look
            // past `last`: lookahead, \b and \z at the end of the range stay range-relative, and a
            // match is cut off there. Only $ is corrected, below.
            std::wstring input;appendCodePoints(input,text,NSMakeRange(0,scope.location));
            const size_t firstPoint=input.size();appendCodePoints(input,text,scope);
            auto pattern=codePoints(needle),format=codePoints(replacementText);
            // Only compilation is an invalid pattern; a failure while matching is reported as it was.
            const SearchRegex regex=[&]{try{return compiledRegex(pattern,matchCase);}catch(const boost::regex_error &e){throw InvalidPattern(e.what());}}();
            auto flags=dotMatchesNewline?boost::match_default:boost::match_not_dot_newline;
            if(scopeEnd<text.length){
                // $ may match at the end of the range only where a line really ends there.
                unichar next=[text characterAtIndex:scopeEnd];
                bool separator=next=='\n'||next=='\r'||next=='\f'||next==0x2028||next==0x2029||next==0x85;
                if(!separator||(next=='\n'&&scopeEnd>0&&[text characterAtIndex:scopeEnd-1]=='\r'))flags|=boost::match_not_eol;
            }
            const wchar_t *data=input.data();
            CheckedIterator base{data,&budget},start{data+firstPoint,&budget},last{data+input.size(),&budget};
            boost::match_results<CheckedIterator> m;
            // Matches arrive in ascending order, so one running cursor converts code-point indexes
            // to UTF-16 offsets in a single pass with no offset table.
            size_t cursorPoint=firstPoint;NSUInteger cursorUnit=scope.location;
            auto unitAt=[&](size_t point){
                if(point<cursorPoint||point>input.size())throw std::runtime_error("Search produced an out-of-order match; no replacement was applied.");
                for(;cursorPoint<point;++cursorPoint)cursorUnit+=(uint32_t)input[cursorPoint]>0xFFFF?2:1;
                return cursorUnit;
            };
            // Same progression as boost::regex_iterator, which has no way to take `base`: continue
            // from the end of the last match and refuse a second empty match at that position.
            for(bool previousEmpty=false;;){
                if(!boost::regex_search(start,last,m,regex,previousEmpty?flags|boost::regex_constants::match_not_initial_null:flags,base))break;
                budget.check();
                const size_t firstMatched=m[0].first.position-data,lastMatched=m[0].second.position-data;
                start=m[0].second;previousEmpty=firstMatched==lastMatched;
                const NSUInteger location=unitAt(firstMatched),length=unitAt(lastMatched)-location;
                // Unreachable over code points; kept so a half character can never be reported.
                if(!boundary(text,location)||!boundary(text,location+length))throw std::runtime_error("The expression matches part of a Unicode surrogate pair; use an expression that preserves the full character.");
                if(wholeWord&&(wordBefore(text,location)||wordAfter(text,location+length)))continue;
                if(matches.count>=(NSUInteger)maximumMatches){truncated=true;break;}
                auto expanded=m.format(format,boost::format_all);outputSize+=unitCount(expanded);if(outputSize>maximumUnits)throw std::runtime_error("Replacement expansion exceeded the 64 Mi UTF-16 safety limit.");
                [matches addObject:[[TTSearchMatch alloc]initWithRange:NSMakeRange(location,length) replacement:stringUnits(expanded)]];
            }
        }else {
            NSRange remainder=scope;NSStringCompareOptions options=NSLiteralSearch|(matchCase?0:NSCaseInsensitiveSearch);
            while(remainder.location<=scopeEnd){
                if(cancellation.cancelled)throw std::runtime_error("Search cancelled; no replacement was applied.");
                if(std::chrono::steady_clock::now()>budget.deadline)throw SearchTimeLimit("Search exceeded its time budget; narrow the scope.");
                NSRange r=[text rangeOfString:needle options:options range:remainder];if(r.location==NSNotFound)break;
                bool accept=!wholeWord||(!wordBefore(text,r.location)&&!wordAfter(text,NSMaxRange(r)));
                if(accept){if(matches.count>=(NSUInteger)maximumMatches){truncated=true;break;}outputSize+=replacementText.length;if(outputSize>maximumUnits)throw std::runtime_error("Replacement expansion exceeded the 64 Mi UTF-16 safety limit.");[matches addObject:[[TTSearchMatch alloc]initWithRange:r replacement:replacementText]];}
                // Find All/Replace All skip accepted hits whole. Navigation and strict single
                // Replace need overlapping candidates; rejected whole-word candidates can overlap
                // too. Step one scalar from the start, never into a surrogate pair.
                NSUInteger next=accept&&!overlappingLiterals?NSMaxRange(r):r.location+1;
                while(next<scopeEnd&&!boundary(text,next))++next;
                remainder=NSMakeRange(next,scopeEnd-next);
            }
        }
        return [[TTSearchResult alloc]initWithMatches:matches truncated:truncated];
    } catch(const SearchTimeLimit &e) {
        if (error) *error = [NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()], @"TextTankSearchTimeLimit": @YES
        }];
        return nil;
    } catch(const InvalidPattern &e) {
        if (error) *error = [NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()]?:@"The regular expression is not valid.", @"TextTankSearchInvalidPattern": @YES
        }];
        return nil;
    } catch(const std::exception&e){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:e.what()]?:@"Search failed safely."}];return nil;}
    catch(...){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Search failed safely."}];return nil;}}
    @catch(NSException *e){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:2 userInfo:@{NSLocalizedDescriptionKey:e.reason?:@"Search failed safely."}];return nil;}
}
@end
