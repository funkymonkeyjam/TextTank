// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, TTSearchMode) {
    TTSearchModeLiteral NS_SWIFT_NAME(TTSearchMode.literal) = 0,
    TTSearchModeExtended NS_SWIFT_NAME(TTSearchMode.extended) = 1,
    TTSearchModeRegularExpression NS_SWIFT_NAME(TTSearchMode.regularExpression) = 2,
};
@interface TTSearchCancellation : NSObject
- (void)cancel;
@property(nonatomic, readonly) BOOL cancelled;
@end
/// One match: its UTF-16 range in the searched text and the expanded replacement for it.
@interface TTSearchMatch : NSObject
@property(nonatomic, readonly) NSRange range;
@property(nonatomic, readonly, copy) NSString *replacement;
- (instancetype)init NS_UNAVAILABLE;
@end
@interface TTSearchResult : NSObject
@property(nonatomic, readonly, copy) NSArray<TTSearchMatch *> *matches;
/// YES when the search stopped at maximumMatches with more matches possible.
@property(nonatomic, readonly) BOOL truncated;
- (instancetype)init NS_UNAVAILABLE;
@end
/// Pure snapshot search; never accesses editor/AppKit. Ranges are UTF-16.
@interface TTSearchEngine : NSObject
/// Searches `range` of `text`. Matches lie inside the range and are reported at their offsets in
/// `text`; whole-word tests, ^, \b, \A and lookbehind see the text around the range, and $ at
/// the range end matches only at a real line end. Regular expressions run over code points.
+ (nullable TTSearchResult *)searchText:(NSString *)text range:(NSRange)range
    query:(NSString *)query replacement:(NSString *)replacement mode:(TTSearchMode)mode
    matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline
    cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches
    timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error;
/// Navigation/strict-single-replacement variant. Only literal/extended matching enumerates
/// overlapping hits, advancing one Unicode scalar at a time; regex and all safety budgets are unchanged.
+ (nullable TTSearchResult *)searchText:(NSString *)text range:(NSRange)range
    query:(NSString *)query replacement:(NSString *)replacement mode:(TTSearchMode)mode
    matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline
    cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches
    overlappingLiterals:(BOOL)overlappingLiterals timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error;
+ (NSString *)decodeExtended:(NSString *)text;
/// Regular expressions compiled so far in this process (not served from the cache); for checks.
+ (NSUInteger)regexCompilationCount;
@end
NS_ASSUME_NONNULL_END
