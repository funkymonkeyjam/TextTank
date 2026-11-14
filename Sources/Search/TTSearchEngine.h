// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface TTSearchCancellation : NSObject
- (void)cancel;
@property(nonatomic, readonly) BOOL cancelled;
@end
/// Pure snapshot search; never accesses editor/AppKit. Ranges are UTF-16.
@interface TTSearchEngine : NSObject
+ (nullable NSDictionary<NSString *, id> *)matchesInText:(NSString *)text
    query:(NSString *)query replacement:(NSString *)replacement mode:(NSInteger)mode
    matchCase:(BOOL)matchCase wholeWord:(BOOL)wholeWord dotMatchesNewline:(BOOL)dotMatchesNewline
    cancellation:(TTSearchCancellation *)cancellation maximumMatches:(NSInteger)maximumMatches
    timeLimit:(NSTimeInterval)timeLimit error:(NSError **)error;
+ (NSString *)decodeExtended:(NSString *)text;
@end
NS_ASSUME_NONNULL_END
