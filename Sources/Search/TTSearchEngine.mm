// SPDX-License-Identifier: GPL-3.0-or-later
#import "TTSearchEngine.h"
#include <atomic>
#include <chrono>
#include <string>
#include <stdexcept>
#define BOOST_REGEX_STANDALONE
#include <boost/regex.hpp>

@implementation TTSearchCancellation { std::atomic<bool> _cancelled; }
- (instancetype)init { if ((self=[super init])) _cancelled=false; return self; }
- (void)cancel { _cancelled=true; }
- (BOOL)cancelled { return _cancelled.load(); }
@end
namespace {
struct Budget {
    TTSearchCancellation *cancellation;
    std::chrono::steady_clock::time_point deadline;
    mutable size_t operations=0;
    void check() const {
        if ((++operations & 1023)==0) {
            if (cancellation.cancelled) throw std::runtime_error("Search cancelled; no replacement was applied.");
            if (std::chrono::steady_clock::now()>deadline) throw std::runtime_error("Search exceeded its time budget; narrow the scope or simplify the pattern.");
        }
    }
};
/// UTF-16 code units match the reference Windows wchar_t iterator, even on macOS.
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
std::wstring units(NSString *s) {std::wstring out;out.reserve(s.length);for(NSUInteger i=0;i<s.length;i++)out.push_back([s characterAtIndex:i]);return out;}
bool validUnits(const std::wstring&s){for(size_t i=0;i<s.size();i++){auto c=s[i];if(c>=0xD800&&c<=0xDBFF){if(i+1==s.size()||s[i+1]<0xDC00||s[i+1]>0xDFFF)return false;++i;}else if(c>=0xDC00&&c<=0xDFFF)return false;else if(c>0xFFFF)return false;}return true;}
NSString *stringUnits(const std::wstring&s){if(!validUnits(s))throw std::runtime_error("The replacement produces an incomplete Unicode surrogate pair; no edits were applied.");std::vector<unichar> out;out.reserve(s.size());for(auto c:s)out.push_back((unichar)c);return [[NSString alloc]initWithCharacters:out.data() length:out.size()];}
bool boundary(NSString *s,NSUInteger i){return i==0||i==s.length||!([s characterAtIndex:i]>=0xDC00&&[s characterAtIndex:i]<=0xDFFF&&[s characterAtIndex:i-1]>=0xD800&&[s characterAtIndex:i-1]<=0xDBFF);}
bool word(wchar_t c){return c=='_'||[[NSCharacterSet alphanumericCharacterSet]characterIsMember:(unichar)c];}
}
@implementation TTSearchEngine
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
+ (NSDictionary *)matchesInText:(NSString *)text query:(NSString *)query replacement:(NSString *)replacement mode:(NSInteger)mode matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error {
    @try { try {
        if(mode<0||mode>2||query.length==0||query.length>65536||text.length>64*1024*1024||replacement.length>1024*1024||maximumMatches<1||maximumMatches>100000||timeLimit<=0||timeLimit>30)throw std::runtime_error("Invalid search input or safety limit (64 Mi UTF-16 document, 64 Ki pattern, 1 Mi replacement, 100,000 results).");
        if(cancellation.cancelled)throw std::runtime_error("Search cancelled; no replacement was applied.");
        NSString *needle=mode==1?[self decodeExtended:query]:query;
        NSString *replacementText=mode==1?[self decodeExtended:replacement]:replacement;
        if(needle.length==0)throw std::runtime_error("Enter a nonempty search expression.");
        Budget budget{cancellation,std::chrono::steady_clock::now()+std::chrono::milliseconds((long long)(timeLimit*1000))};
        NSMutableArray *matches=[NSMutableArray array];bool truncated=false;size_t outputSize=0;
        if(mode==2) {
            auto input=units(text),pattern=units(needle),format=units(replacementText);
            boost::wregex regex(pattern,boost::regex::ECMAScript|(matchCase?0:boost::regex::icase));
            auto flags=dotMatchesNewline?boost::match_default:boost::match_not_dot_newline;
            CheckedIterator first{input.data(),&budget},last{input.data()+input.size(),&budget};
            boost::regex_iterator<CheckedIterator,wchar_t> it(first,last,regex,flags),end;
            for(;it!=end;++it){
                budget.check();const auto &m=*it;NSUInteger location=m[0].first.position-input.data(),length=m.length();
                if(!boundary(text,location)||!boundary(text,location+length))throw std::runtime_error("The expression matches part of a Unicode surrogate pair; use an expression that preserves the full character.");
                if(wholeWord&&((location>0&&word(input[location-1]))||(location+length<input.size()&&word(input[location+length]))))continue;
                if(matches.count>=(NSUInteger)maximumMatches){truncated=true;break;}
                auto expanded=m.format(format,boost::format_all);outputSize+=expanded.size();if(outputSize>64*1024*1024)throw std::runtime_error("Replacement expansion exceeded the 64 Mi UTF-16 safety limit.");
                [matches addObject:@{@"range":[NSValue valueWithRange:NSMakeRange(location,length)],@"replacement":stringUnits(expanded)}];
            }
        }else {
            NSRange remainder=NSMakeRange(0,text.length);NSStringCompareOptions options=NSLiteralSearch|(matchCase?0:NSCaseInsensitiveSearch);
            while(remainder.location<=text.length){
                if(cancellation.cancelled)throw std::runtime_error("Search cancelled; no replacement was applied.");
                if(std::chrono::steady_clock::now()>budget.deadline)throw std::runtime_error("Search exceeded its time budget; narrow the scope.");
                NSRange r=[text rangeOfString:needle options:options range:remainder];if(r.location==NSNotFound)break;
                bool accept=!wholeWord||((r.location==0||!word([text characterAtIndex:r.location-1]))&&(NSMaxRange(r)==text.length||!word([text characterAtIndex:NSMaxRange(r)])));
                if(accept){if(matches.count>=(NSUInteger)maximumMatches){truncated=true;break;}outputSize+=replacementText.length;if(outputSize>64*1024*1024)throw std::runtime_error("Replacement expansion exceeded the safety limit.");[matches addObject:@{@"range":[NSValue valueWithRange:r],@"replacement":replacementText}];}
                remainder=NSMakeRange(NSMaxRange(r),text.length-NSMaxRange(r));
            }
        }
        return @{@"matches":matches,@"truncated":@(truncated)};
    }catch(const std::exception&e){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:e.what()]}];return nil;}}
    @catch(NSException *e){if(error)*error=[NSError errorWithDomain:@"TextTank.Search" code:2 userInfo:@{NSLocalizedDescriptionKey:e.reason?:@"Search failed safely."}];return nil;}
}
@end
