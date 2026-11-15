// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import "../Search/TTSearchEngine.h"
NS_ASSUME_NONNULL_BEGIN
extern NSErrorDomain const TTEditorErrorDomain;
typedef NS_ERROR_ENUM(TTEditorErrorDomain, TTEditorError) {
    /// The document is read-only; see -requireWritable:.
    TTEditorErrorReadOnly = 1,
};
/// Posted on the main thread, at most once per turn of the run loop and never from inside a
/// Scintilla callback, after the text, save point, selection, zoom, focus or a bridge-set view
/// property of the editor (the notification's object) may have changed. Any number of observers
/// may listen. It says "look again", not what changed; Scintilla reports selection changes when
/// it paints, so a periodic refresh is still needed for state no event covers.
extern NSNotificationName const TTEditorStateDidChangeNotification;
/// Main-thread-only view. All positions remain inside the UTF-8 Scintilla model.
@interface TTEditor : NSView
/// Reading makes one copy, decoded straight from the engine's buffer. Do not read it only for
/// its size (byteLength) or for a background scan of the bytes (utf8Data).
@property(nonatomic, copy) NSString *text;
/// Length of the document in UTF-8 bytes, without copying it.
@property(nonatomic, readonly) NSInteger byteLength;
/// The document's exact UTF-8 bytes as one immutable copy, safe to hand to a background queue.
@property(nonatomic, readonly) NSData *utf8Data;
@property(nonatomic, readonly) NSString *selectedText;
@property(nonatomic, readonly) BOOL modified;
@property(nonatomic, readonly) NSUInteger revision;
/// Byte positions of the primary selection; selectionCount includes additional selections.
@property(nonatomic, readonly) NSInteger selectionCount;
@property(nonatomic, readonly) NSArray<NSDictionary<NSString *, NSNumber *> *> *selectionRanges;
/// Changes whenever any selection of this view may have changed: on every text modification, on
/// every bridge call that can move a selection, and when Scintilla reports a selection update.
/// A cache key only; it can change without the selection having changed.
@property(nonatomic, readonly) NSUInteger selectionGeneration;
- (BOOL)setSelectionRanges:(NSArray<NSDictionary<NSString *, NSNumber *> *> *)ranges;
- (BOOL)replaceSelections:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision;
/// Applies byte-range replacements ({"start","end","text"}, ascending, each start at or after the
/// previous end) as one undo step without touching the rest of the document, so markers, folds
/// and the viewport outside the ranges survive. Everything is validated first: revision,
/// writability, document length, bounds, UTF-8 boundaries, order and encodability. Returns NO
/// with nothing changed otherwise. Does not move the selection explicitly or scroll.
- (BOOL)applyEdits:(NSArray<NSDictionary<NSString *, id> *> *)edits expectedRevision:(NSUInteger)revision expectedLength:(NSInteger)length;
/// Replaces the content of a live document with one minimal-span edit (common prefix and suffix
/// are kept), preserving bookmarks, the caret line and the first visible line. Identical text
/// changes nothing, including revision. NO when read-only or unencodable. setText: remains the
/// unconditional replace for fresh loads.
- (BOOL)replaceDocumentText:(NSString *)text;
/// replaceDocumentText: for open, reload and restore: nothing is recorded for Undo, the undo
/// history is emptied and the result is the save point. NO, changing nothing, when read-only
/// or unencodable.
- (BOOL)loadDocumentText:(NSString *)text;
@property(nonatomic) BOOL readOnly;
/// The one read-only guard: every command that edits text calls it before anything else,
/// including before any dialog, so the reason is always the same and always stated first.
/// NO with a TTEditorErrorReadOnly error when the document is read-only.
- (BOOL)requireWritable:(NSError **)error;
/// Called when Scintilla refuses an edit because the document is read-only (typing, a key
/// command, Undo). Bridge methods that return NO for a read-only document do not call it.
@property(nonatomic, copy, nullable) void (^onReadOnlyAttempt)(void);
/// NO, changing nothing, when the document is read-only or the mode is not LF, CRLF or CR.
- (BOOL)convertLineEndings:(NSString *)mode;
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
/// Moves the caret to the start of a one-based line in the engine's own line model, unfolding
/// it if hidden, and scrolls it into view. NO, changing nothing, when the line does not exist.
- (BOOL)goToLine:(NSInteger)line NS_SWIFT_NAME(goToLine(_:));
- (void)scrollCaretIntoView;
/// Zero-based display line at the top of this view.
@property(nonatomic, readonly) NSInteger firstVisibleLine;
@property(nonatomic, readonly) NSArray<NSNumber *> *bookmarkLines;
/// bookmarkLines.count without building the array.
@property(nonatomic, readonly) NSInteger bookmarkCount;
/// Validates all line numbers before replacing marker-1 bookmarks; never changes text.
- (BOOL)setBookmarks:(NSArray<NSNumber *> *)lines;
/// Called after the text or the save-point state changed. `revision` advances with every
/// modification step, but this is called once per outermost undo group (beginUndoGroup, and every
/// grouped bridge operation, on any view of the document) and once per multi-step Undo or Redo.
/// Outside a group it is called before the edit returns.
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
/// YES for executeCommand: identifiers that edit text, which callers guard with requireWritable:.
+ (BOOL)commandModifiesText:(NSString *)identifier;
/// Returns NO, changing nothing (selection included), when the text cannot be encoded as
/// UTF-8 (an unpaired surrogate) or the document is read-only.
- (BOOL)replaceSelection:(NSString *)text;
- (void)setSavePoint;
- (void)resetUndoHistory;
- (void)setLanguage:(NSString *)language;
/// Installs the lexer, replaces all 32 keyword lists and sets the properties, then lexes the
/// document once. Lists outside 0...31 and values containing NUL are skipped.
- (void)setLanguage:(NSString *)language keywordLists:(NSDictionary<NSNumber *, NSString *> *)keywordLists properties:(NSDictionary<NSString *, NSString *> *)properties;
/// Styled text of the whole document, or of the main selection only when `selection` is YES;
/// additional selections are not included.
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
