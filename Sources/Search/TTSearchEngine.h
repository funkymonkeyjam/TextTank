// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, TTSearchMode) {
    TTSearchModeLiteral NS_SWIFT_NAME(TTSearchMode.literal) = 0,
    TTSearchModeExtended NS_SWIFT_NAME(TTSearchMode.extended) = 1,
    TTSearchModeRegularExpression NS_SWIFT_NAME(TTSearchMode.regularExpression) = 2,
};
/// Thread-safe cancellation: the sole mutable field is std::atomic<bool>; init publishes
/// its initial value before use, and cancel/read only perform atomic operations.
NS_SWIFT_SENDABLE
@interface TTSearchCancellation : NSObject
- (void)cancel;
@property(nonatomic, readonly) BOOL cancelled;
@end
/// One match: its UTF-16 range in the searched text and the expanded replacement for it.
__attribute__((objc_subclassing_restricted))
@interface TTSearchMatch : NSObject
@property(nonatomic, readonly) NSRange range;
@property(nonatomic, readonly, copy) NSString *replacement;
- (instancetype)init NS_UNAVAILABLE;
@end
__attribute__((objc_subclassing_restricted))
@interface TTSearchResult : NSObject
@property(nonatomic, readonly, copy) NSArray<TTSearchMatch *> *matches;
/// YES when the search stopped at maximumMatches with more matches possible.
@property(nonatomic, readonly) BOOL truncated;
- (instancetype)init NS_UNAVAILABLE;
@end
/// Pure snapshot search; never accesses editor/AppKit. Ranges are UTF-16.
@interface TTSearchEngine : NSObject
/// Distinguishes a deadline from ordinary search errors without interpreting display text.
+ (BOOL)isTimeLimitError:(NSError *)error NS_SWIFT_NAME(timedOut(_:));
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
/// YES when the error reports a regular expression that could not be compiled, as opposed to a
/// search that failed for another reason. Callers mark the Find field for this one (DS-45).
+ (BOOL)isInvalidPatternError:(NSError *)error NS_SWIFT_NAME(invalidPattern(_:));
/// The longest text, in UTF-16 units, that searchText: accepts (64 Mi).
+ (NSUInteger)maximumTextUnits;
/// The UTF-16 length `data` has once decoded as UTF-8: one pass, no decoding and no buffer.
+ (NSUInteger)utf16LengthOfUTF8:(NSData *)data NS_SWIFT_NAME(utf16Length(ofUTF8:));
/// Literal and extended search over a document's UTF-8 bytes, for text above maximumTextUnits.
/// The bytes are read in windows of about `chunkBytes`; a window overlaps the next by the
/// longest possible match, and a match belongs to the window its first byte is in, so a match
/// that straddles two windows is reported exactly once. Working memory follows `chunkBytes`,
/// not the document. Ranges in the result are UTF-8 BYTE ranges in `data`, not UTF-16 ranges.
/// Matching is the same as searchText: literal comparison, Unicode case folding without
/// `matchCase`, and whole-word tests that see the bytes around `byteRange`. `backwards` reports
/// matches from the end of the range towards its start. A regular expression is refused.
/// With `stopAtLimit` the search returns as soon as it holds `maximumMatches` matches, without
/// looking for one more: `truncated` is then NO and says nothing about further matches. Cancel
/// and the deadline are looked at after every mebibyte of comparison work, inside a window too.
/// `progress` is called on the calling thread after each window with the bytes covered so far.
+ (nullable TTSearchResult *)searchUTF8:(NSData *)data range:(NSRange)byteRange
    query:(NSString *)query replacement:(NSString *)replacement mode:(TTSearchMode)mode
    matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord backwards:(BOOL)backwards
    overlapping:(BOOL)overlapping maximumMatches:(NSInteger)maximumMatches
    stopAtLimit:(BOOL)stopAtLimit chunkBytes:(NSUInteger)chunkBytes cancellation:(TTSearchCancellation *)cancellation
    timeLimit:(NSTimeInterval)timeLimit
    progress:(nullable void (NS_NOESCAPE ^)(NSUInteger coveredBytes))progress error:(NSError **)error;
/// Regular expressions compiled so far in this process (not served from the cache); for checks.
+ (NSUInteger)regexCompilationCount;
@end
NS_ASSUME_NONNULL_END
