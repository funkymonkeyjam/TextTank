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
@property(nonatomic, readonly) NSInteger selectionAnchor;
@property(nonatomic, readonly) NSInteger selectionCaret;
/// Restores one ordinary selection. Rejects out-of-bounds or split UTF-8 code points.
- (BOOL)setSelectionAnchor:(NSInteger)anchor caret:(NSInteger)caret;
@property(nonatomic, readonly) NSArray<NSNumber *> *bookmarkLines;
/// Validates all line numbers before replacing marker-1 bookmarks; never changes text.
- (BOOL)setBookmarks:(NSArray<NSNumber *> *)lines;
@property(nonatomic, copy, nullable) void (^onChange)(void);
@property(nonatomic, copy, nullable) void (^onFocus)(void);
+ (NSArray<NSString *> *)availableLanguages;
@property(nonatomic, copy, nullable) void (^onMacroStep)(NSDictionary<NSString *, id> *step);
- (void)startRecording;
- (void)stopRecording;
- (BOOL)executeMacroStep:(NSDictionary<NSString *, id> *)step;
- (void)beginUndoGroup;
- (void)endUndoGroup;
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
