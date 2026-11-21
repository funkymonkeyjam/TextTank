// SPDX-License-Identifier: GPL-3.0-or-later
#import "TTSearchEngine.h"
#include <atomic>
#include <chrono>
#include <locale>
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
+ (TTSearchResult *)searchText:(NSString *)text range:(NSRange)scope query:(NSString *)query replacement:(NSString *)replacement mode:(TTSearchMode)mode matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error {
    return [self searchText:text range:scope query:query replacement:replacement mode:mode matchCase:matchCase wholeWord:wholeWord dotMatchesNewline:dotMatchesNewline cancellation:cancellation maximumMatches:maximumMatches overlappingLiterals:NO timeLimit:timeLimit error:error];
}
+ (TTSearchResult *)searchText:(NSString *)text range:(NSRange)scope query:(NSString *)query replacement:(NSString *)replacement mode:(TTSearchMode)mode matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches overlappingLiterals:(BOOL)overlappingLiterals timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error {
    @try { try {
        if(mode<0||mode>2)throw std::runtime_error("Unknown search mode.");
        if(query.length==0)throw std::runtime_error("Enter a nonempty search expression.");
        if(query.length>65536)throw std::runtime_error("The search expression is longer than the 64 Ki UTF-16 limit.");
        if(text.length>maximumUnits)throw std::runtime_error("The document is larger than the 64 Mi UTF-16 search limit.");
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
            const SearchRegex regex=compiledRegex(pattern,matchCase);
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
    } catch(const std::exception&e){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:e.what()]?:@"Search failed safely."}];return nil;}
    catch(...){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Search failed safely."}];return nil;}}
    @catch(NSException *e){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:2 userInfo:@{NSLocalizedDescriptionKey:e.reason?:@"Search failed safely."}];return nil;}
}
@end
