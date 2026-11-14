// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
/// Main-thread-only view. All positions remain inside the UTF-8 Scintilla model.
@interface TTEditor : NSView
@property(nonatomic, copy) NSString *text;
@property(nonatomic, readonly) NSString *selectedText;
@property(nonatomic, readonly) BOOL modified;
@property(nonatomic, readonly) NSUInteger revision;
/// Byte positions of the primary selection; selectionCount includes additional selections.
@property(nonatomic, readonly) NSInteger selectionCount;
@property(nonatomic, readonly) NSInteger selectionStart;
@property(nonatomic, readonly) NSInteger selectionEnd;
@property(nonatomic, copy, nullable) void (^onChange)(void);
@property(nonatomic, copy, nullable) void (^onFocus)(void);
+ (NSArray<NSString *> *)availableLanguages;
@property(nonatomic) BOOL wrap;
- (void)shareDocumentWith:(TTEditor *)other;
- (void)executeCommand:(NSString *)identifier;
- (void)replaceSelection:(NSString *)text;
- (void)setSavePoint;
- (void)resetUndoHistory;
- (void)setLanguage:(NSString *)language;
- (BOOL)find:(NSString *)text matchCase:(BOOL)matchCase backwards:(BOOL)backwards;
@end
NS_ASSUME_NONNULL_END
