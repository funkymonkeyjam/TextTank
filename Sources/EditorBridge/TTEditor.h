// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "../Search/TTSearchEngine.h"
NS_ASSUME_NONNULL_BEGIN
/// Main-thread-only view. All positions remain inside the UTF-8 Scintilla model.
@interface TTEditor : NSView
@property(nonatomic, copy) NSString *text;
@property(nonatomic, readonly) NSString *selectedText;
@property(nonatomic, readonly) BOOL modified;
@property(nonatomic, readonly) NSUInteger revision;
/// Byte positions of the primary selection; selectionCount includes additional selections.
@property(nonatomic, readonly) NSInteger selectionCount;
@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, NSNumber *> *> *selectionRanges;
- (BOOL)setSelectionRanges:(NSArray<NSDictionary<NSString *, NSNumber *> *> *)ranges;
- (BOOL)replaceSelections:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision;
@property(nonatomic) BOOL readOnly;
- (void)convertLineEndings:(NSString *)mode;
/// Sets only the ending inserted by later edits (LF, CRLF or CR). Never rewrites existing
/// bytes and creates no undo step; convertLineEndings: is the only converting operation.
- (void)setLineEndingMode:(NSString *)mode;
- (void)configureTabWidth:(NSInteger)width useTabs:(BOOL)useTabs;

@property(nonatomic, readonly) NSInteger selectionStart;
@property(nonatomic, readonly) NSInteger selectionEnd;
@property(nonatomic, readonly) NSInteger selectionAnchor;
@property(nonatomic, readonly) NSInteger selectionCaret;
/// View metadata; line/column are one-based, column expands tabs.
@property(nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *statusInfo;
/// Unicode scalar count across actual selections, without clipboard separators.
@property(nonatomic, readonly) NSInteger selectedCharacterCount;
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
/// Returns NO, changing nothing, when the text cannot be encoded as UTF-8 (an unpaired
/// surrogate); also NO when the document is read-only.
- (BOOL)replaceSelection:(NSString *)text;
- (void)setSavePoint;
- (void)resetUndoHistory;
- (void)setLanguage:(NSString *)language;
- (void)setKeywordList:(NSInteger)index words:(NSString *)words;
- (void)setLexerProperty:(NSString *)name value:(NSString *)value;
- (NSAttributedString *)attributedTextForSelection:(BOOL)selection;
- (void)showCompletions:(NSArray<NSString *> *)words;
- (void)setSyntaxStyle:(NSInteger)index foreground:(NSColor *)foreground background:(nullable NSColor *)background bold:(BOOL)bold italic:(BOOL)italic;
- (void)showCallTip:(NSString *)text;
- (void)setSyntaxFont:(NSInteger)index name:(NSString *)name size:(double)size;
- (BOOL)setSearchHighlights:(NSArray<NSValue *> *)ranges;
- (void)clearSearchHighlights;

- (BOOL)find:(NSString *)text matchCase:(BOOL)matchCase backwards:(BOOL)backwards;
@end
NS_ASSUME_NONNULL_END
