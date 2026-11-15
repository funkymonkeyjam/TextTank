// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
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
    query:(NSString *)query replacement:(NSString *)replacement mode:(NSInteger)mode
    matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline
    cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches
    timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error;
/// The whole text, as a dictionary: "matches" is an array of {"range": NSValue, "replacement":
/// NSString} and "truncated" an NSNumber. Kept as a thin wrapper over searchText:range:.
+ (nullable NSDictionary<NSString *, id> *)matchesInText:(NSString *)text
    query:(NSString *)query replacement:(NSString *)replacement mode:(NSInteger)mode
    matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline
    cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches
    timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error;
+ (NSString *)decodeExtended:(NSString *)text;
/// Regular expressions compiled so far in this process (not served from the cache); for checks.
+ (NSUInteger)regexCompilationCount;
@end
NS_ASSUME_NONNULL_END
