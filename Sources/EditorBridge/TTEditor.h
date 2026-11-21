// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
/// Posted by -retireInFavorOf: on the main thread. The object is the view about to leave its
/// window; userInfo[TTEditorSuccessorKey] is the remaining view of the same document.
extern NSNotificationName const TTEditorWillRetireNotification;
extern NSString *const TTEditorSuccessorKey;

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
/// Stable symbolic identifiers remain raw strings on disk; Swift callers carry a distinct type.
/// Foreign/unknown identifiers are still validated before engine dispatch.
typedef NSString *TTEditorCommandIdentifier NS_TYPED_EXTENSIBLE_ENUM;
/// Values match Scintilla's insertion-ending codes; they are not file-format strings.
typedef NS_ENUM(NSInteger, TTLineEndingMode) {
    TTLineEndingModeCRLF NS_SWIFT_NAME(TTLineEndingMode.crlf) = 0,
    TTLineEndingModeCR NS_SWIFT_NAME(TTLineEndingMode.cr) = 1,
    TTLineEndingModeLF NS_SWIFT_NAME(TTLineEndingMode.lf) = 2,
};
typedef NS_ENUM(NSInteger, TTMacroActionKind) {
    TTMacroActionKindInsertText NS_SWIFT_NAME(TTMacroActionKind.insertText),
    TTMacroActionKindCommand NS_SWIFT_NAME(TTMacroActionKind.command),
    TTMacroActionKindUnsupported NS_SWIFT_NAME(TTMacroActionKind.unsupported),
};
/// A native recording/playback value. Unsupported messages are diagnostics, never dispatch inputs.
__attribute__((objc_subclassing_restricted))
@interface TTMacroAction : NSObject <NSCopying>
@property(nonatomic, readonly) TTMacroActionKind kind;
@property(nonatomic, readonly, copy, nullable) NSString *text;
@property(nonatomic, readonly, copy, nullable) TTEditorCommandIdentifier command;
@property(nonatomic, readonly, copy, nullable) NSString *name;
@property(nonatomic, readonly) NSUInteger message;
+ (instancetype)insertText:(NSString *)text NS_SWIFT_NAME(insertText(_:));
+ (instancetype)command:(TTEditorCommandIdentifier)command NS_SWIFT_NAME(command(_:));
+ (instancetype)unsupported:(NSString *)name message:(NSUInteger)message NS_SWIFT_NAME(unsupported(_:message:));
- (instancetype)init NS_UNAVAILABLE;
@end
/// A UTF-8 byte span, distinct from Foundation NSRange values used for UTF-16 search.
/// Construction does not assert document bounds; the editor validates the complete batch.
__attribute__((objc_subclassing_restricted))
@interface TTByteRange : NSObject <NSCopying>
@property(nonatomic, readonly) NSInteger location;
@property(nonatomic, readonly) NSInteger length;
- (instancetype)initWithLocation:(NSInteger)location length:(NSInteger)length;
- (instancetype)init NS_UNAVAILABLE;
@end
/// One immutable replacement of a byte span; the entire edit list is validated before mutation.
__attribute__((objc_subclassing_restricted))
@interface TTTextEdit : NSObject <NSCopying>
@property(nonatomic, readonly, strong) TTByteRange *range;
@property(nonatomic, readonly, copy) NSString *text;
- (instancetype)initWithRange:(TTByteRange *)range text:(NSString *)text;
- (instancetype)init NS_UNAVAILABLE;
@end
/// Immutable UTF-8 byte positions. Bounds and scalar alignment are checked by TTEditor,
/// before any selection is changed; negative/out-of-document values remain rejectable inputs.
__attribute__((objc_subclassing_restricted))
@interface TTSelectionRange : NSObject <NSCopying>
@property(nonatomic, readonly) NSInteger anchor;
@property(nonatomic, readonly) NSInteger caret;
- (instancetype)initWithAnchor:(NSInteger)anchor caret:(NSInteger)caret;
- (instancetype)init NS_UNAVAILABLE;
@end
/// Immutable metadata copied from one main-thread engine observation. No view is retained.
__attribute__((objc_subclassing_restricted))
@interface TTEditorStatus : NSObject <NSCopying>
@property(nonatomic, readonly) NSInteger line;
@property(nonatomic, readonly) NSInteger column;
@property(nonatomic, readonly) NSInteger lines;
@property(nonatomic, readonly) NSInteger tabWidth;
@property(nonatomic, readonly) BOOL useTabs;
@property(nonatomic, readonly) double fontSize;
@property(nonatomic, readonly) TTLineEndingMode eol;
- (instancetype)init NS_UNAVAILABLE;
@end
/// Immutable, strictly validated UTF-8 content. A leading U+FEFF and embedded NUL remain data.
__attribute__((objc_subclassing_restricted))
@interface TTDocumentUTF8 : NSObject
@property(nonatomic, readonly, copy) NSData *data;
- (nullable instancetype)initWithData:(NSData *)data NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// An unmounted Scintilla document, discarded on any failed or cancelled initial read.
__attribute__((objc_subclassing_restricted))
@interface TTInitialUTF8Load : NSObject
- (nullable instancetype)initWithByteCount:(NSUInteger)bytes;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)appendContent:(TTDocumentUTF8 *)bytes;
@end
/// Main-thread-only view. All positions remain inside the UTF-8 Scintilla model.
///
/// A split view is two TTEditor views on one Scintilla document (shareDocumentWith:). State
/// lives at one of two levels, and setting document state through either view sets it for both:
/// - Document: text, readOnly, tab width and tabs-or-spaces (configureTabWidth:useTabs:), the
///   line-ending mode, the lexer with its keyword lists and properties (setLanguage:),
///   bookmarks, search highlights, the undo history and the save point (modified).
/// - View: automatic indentation on Return, live brace feedback, current-line framing, indentation guides, wrap, zoom, selection and scroll position, syntax styles and fonts (setSyntaxStyle:,
///   setSyntaxFont:), margins, whitespace and line-ending visibility, and overtype.
/// revision is counted per view, but views of one document always report the same value.
@interface TTEditor : NSView
/// Reading makes one copy, decoded straight from the engine's buffer. Do not read it only for
/// its size (byteLength) or for a background scan of the bytes (utf8Data).
@property(nonatomic, copy) NSString *text;
/// Tests physical line content in bytes, excluding CR and LF, without copying the text.
- (BOOL)hasLineLongerThan:(NSUInteger)limit;
/// Length of the document in UTF-8 bytes, without copying it.
@property(nonatomic, readonly) NSInteger byteLength;
@property(nonatomic, readonly) NSInteger lineCount;
/// The document's exact UTF-8 bytes as one immutable copy, safe to hand to a background queue.
@property(nonatomic, readonly) NSData *utf8Data;
/// Immutable editor bytes for persistence and printing. Nil means the full range could not be copied.
/// An empty document succeeds with zero bytes. Callers validate the UTF-8 content separately.
@property(nonatomic, readonly, nullable) NSData *checkedUTF8Data;
@property(nonatomic, readonly) NSString *selectedText;
@property(nonatomic, readonly) BOOL modified;
@property(nonatomic, readonly) NSUInteger revision;
/// Byte positions of the primary selection; selectionCount includes additional selections.
@property(nonatomic, readonly) NSInteger selectionCount;
@property(nonatomic, readonly) NSArray<TTSelectionRange *> *selectionRanges;
/// Changes whenever any selection of this view may have changed: on every text modification, on
/// every bridge call that can move a selection, and when Scintilla reports a selection update.
/// A cache key only; it can change without the selection having changed.
@property(nonatomic, readonly) NSUInteger selectionGeneration;
- (BOOL)setSelectionRanges:(NSArray<TTSelectionRange *> *)ranges;
- (BOOL)replaceSelections:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision;
/// Applies typed byte-range replacements (ascending, each start at or after the
/// previous end) as one undo step without touching the rest of the document, so markers, folds
/// and the viewport outside the ranges survive. Everything is validated first: revision,
/// writability, document length, bounds, UTF-8 boundaries, order and encodability. Returns NO
/// with nothing changed otherwise. Does not move the selection explicitly or scroll.
- (BOOL)applyEdits:(NSArray<TTTextEdit *> *)edits expectedRevision:(NSUInteger)revision expectedLength:(NSInteger)length NS_SWIFT_NAME(applyEdits(_:expectedRevision:expectedLength:));
/// Replaces the content of a live document with one minimal-span edit (common prefix and suffix
/// are kept), preserving bookmarks, the caret line and the first visible line. Identical text
/// changes nothing, including revision. NO when read-only or unencodable. setText: remains the
/// unconditional replace for fresh loads.
- (BOOL)replaceDocumentText:(NSString *)text;
/// Reject stale results before even a no-op replacement. Main-thread atomic guard.
- (BOOL)replaceDocumentText:(NSString *)text expectedRevision:(NSUInteger)revision;
/// replaceDocumentText: for open, reload and restore: nothing is recorded for Undo, the undo
/// history is emptied and the result is the save point. NO, changing nothing, when read-only
/// or unencodable.
- (BOOL)loadDocumentText:(NSString *)text;
/// The checked bytes are borrowed only for the synchronous native load.
- (BOOL)loadDocumentUTF8:(TTDocumentUTF8 *)content NS_SWIFT_NAME(loadDocumentUTF8(_:));
/// Adopt a completed load only into the original pristine editor. No existing buffer is replaced.
- (BOOL)adoptInitialUTF8Load:(TTInitialUTF8Load *)load;
/// Replaces ascending, non-overlapping byte ranges (TTByteRange values) under one undo action,
/// without driving the selection per range. Revision, read-only state, bounds, UTF-8
/// lead-byte alignment and encodability are all checked before the first edit; NO changes
/// nothing. Afterwards there is one caret, just after the first replacement, scrolled into view.
- (BOOL)replaceRanges:(NSArray<TTByteRange *> *)ranges withTexts:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision NS_SWIFT_NAME(replaceRanges(_:withTexts:expectedRevision:));
@property(nonatomic) BOOL readOnly;
/// The one read-only guard: every command that edits text calls it before anything else,
/// including before any dialog, so the reason is always the same and always stated first.
/// NO with a TTEditorErrorReadOnly error when the document is read-only.
- (BOOL)requireWritable:(NSError **)error;
/// Called when Scintilla refuses an edit because the document is read-only (typing, a key
/// command, Undo). Bridge methods that return NO for a read-only document do not call it.
@property(nonatomic, copy, nullable) void (^onReadOnlyAttempt)(void);
/// NO, changing nothing, when the document is read-only or the mode is not a supported TTLineEndingMode.
- (BOOL)convertLineEndings:(TTLineEndingMode)mode;
/// Sets only the ending inserted by later edits (LF, CRLF or CR). Never rewrites existing
/// bytes and creates no undo step; convertLineEndings: is the only converting operation.
- (BOOL)setLineEndingMode:(TTLineEndingMode)mode;
/// NO for an unsupported width; a valid request keeps the existing document-scope policy.
- (BOOL)configureTabWidth:(NSInteger)width useTabs:(BOOL)useTabs;

@property(nonatomic, readonly) NSInteger selectionStart;
@property(nonatomic, readonly) NSInteger selectionEnd;
@property(nonatomic, readonly) NSInteger selectionAnchor;
@property(nonatomic, readonly) NSInteger selectionCaret;
/// View metadata; line/column are one-based, column expands tabs.
@property(nonatomic, readonly) TTEditorStatus *statusInfo;
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
/// Restores view metadata only, clamping offsets to UTF-8 boundaries and visible lines.
- (void)restoreClosedTabViewWithAnchor:(NSInteger)anchor caret:(NSInteger)caret firstVisibleLine:(NSInteger)firstVisibleLine NS_SWIFT_NAME(restoreClosedTabView(anchor:caret:firstVisibleLine:));
@property(nonatomic, readonly) NSArray<NSNumber *> *bookmarkLines;
/// bookmarkLines.count without building the array.
@property(nonatomic, readonly) NSInteger bookmarkCount;
@property(nonatomic, readonly) BOOL hasBookmarks;
/// Validates all line numbers before replacing marker-1 bookmarks; never changes text.
- (BOOL)setBookmarks:(NSArray<NSNumber *> *)lines;
/// Called after the text or the save-point state changed. `revision` advances with every
/// modification step, but this is called once per outermost undo group (beginUndoGroup, and every
/// grouped bridge operation, on any view of the document) and once per multi-step Undo or Redo.
/// Outside a group it is called before the edit returns.
@property(nonatomic, copy, nullable) void (^onChange)(void);
@property(nonatomic, copy, nullable) void (^onFocus)(void);
+ (NSArray<NSString *> *)availableLanguages;
/// Called while recording with one typed action per recordable insertion or command.
/// Anything that changed the text or the selection and cannot be replayed arrives with
/// TTMacroActionKindUnsupported and a diagnostic name (a mouse click or drop, typing in Overtype, a
/// completion list, native Undo, an unmapped Scintilla message); the recording must be discarded.
@property(nonatomic, copy, nullable) void (^onMacroStep)(TTMacroAction *step);
/// The symbolic command names a recorded step may carry; the only names playback dispatches.
+ (NSArray<TTEditorCommandIdentifier> *)macroCommandNames;
/// Immutable canonical recording map; playback-only aliases are deliberately excluded.
+ (NSDictionary<TTEditorCommandIdentifier, NSNumber *> *)macroCommandMessages;
- (void)startRecording;
- (void)stopRecording;
- (BOOL)executeMacroStep:(TTMacroAction *)step;
- (void)beginUndoGroup;
/// The outermost named group appends a native container token only after a real edit.
- (void)beginUndoGroupNamed:(NSString *)name NS_SWIFT_NAME(beginUndoGroup(named:));
/// Overrides the next group actually opened by a validated synchronous bridge operation.
/// Returns the previous override so callers can restore a nesting scope.
- (nullable NSString *)exchangeNextUndoName:(nullable NSString *)name;
- (nullable NSString *)historyNameForRedo:(BOOL)redo NS_SWIFT_NAME(historyName(redo:));
- (void)endUndoGroup;
/// Inherit the current line’s leading tabs and spaces on interactive Return. Defaults to YES.
@property(nonatomic) BOOL autoIndentEnabled;
/// Pair a typed delimiter beside whitespace or end of line. Defaults off.
@property(nonatomic) BOOL autoPairEnabled;
/// Show native brace feedback at the primary caret of this view. Defaults to YES.
@property(nonatomic) BOOL braceHighlightEnabled;
/// Frame the caret line in the focused editing view. Read-only documents can also show the frame.
@property(nonatomic) BOOL currentLineHighlightEnabled;
/// Show Scintilla's indentation guides, including continuation across a blank line.
@property(nonatomic) BOOL indentGuidesEnabled;
@property(nonatomic) BOOL wrap;
/// The bookmark dot's colour for the current appearance, as 0xBBGGRR. The engine has no query for it.
@property(nonatomic, readonly) NSInteger bookmarkColour;
/// What VoiceOver calls this text area: the document's name (and pane, in a split view) instead
/// of the engine's own name. Nil restores a generic "Document".
@property(nonatomic, copy, nullable) NSString *accessibilityDocumentName;
- (void)shareDocumentWith:(TTEditor *)other;
/// YES when both views show the same Scintilla document. A view shares with itself.
- (BOOL)sharesDocumentWith:(nullable TTEditor *)other;
/// View scope only: replaces this view's syntax styles and fonts with the other view's and
/// redraws. Never touches the lexer, keyword lists, properties, text, undo or the revision.
- (void)adoptSyntaxStylesFrom:(TTEditor *)other;
/// View scope only: adoptSyntaxStylesFrom: plus automatic indentation, live brace feedback, current-line framing, indentation guides, zoom, wrap, whitespace and line-ending
/// visibility and margin widths. Selection and scroll position are not copied.
- (void)adoptViewStateFrom:(TTEditor *)other;
/// Announces that this view is leaving its window while `successor` keeps showing the same
/// document, so holders of results that do not depend on this view's selection can retarget
/// them. Posts nothing unless the two views share a document.
- (void)retireInFavorOf:(TTEditor *)successor;
/// NO for an unknown identifier, without changing text, selection or notifications.
- (BOOL)executeCommand:(TTEditorCommandIdentifier)identifier;
/// Cut/Copy Bookmarked Lines publish to the caller's clipboard; an unavailable board must never cut text.
- (BOOL)executeCommand:(TTEditorCommandIdentifier)identifier usingPasteboard:(nullable NSPasteboard *)pasteboard;
+ (NSArray<TTEditorCommandIdentifier> *)supportedCommandIdentifiers;
/// YES for executeCommand: identifiers that edit text, which callers guard with requireWritable:.
+ (BOOL)commandModifiesText:(TTEditorCommandIdentifier)identifier;
/// The actual focused-view state of a known toggle; NO for non-toggle/unknown identifiers.
- (BOOL)commandIsChecked:(TTEditorCommandIdentifier)identifier;
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
/// Filters invalid words as before. YES when a nonempty filtered list was requested.
- (BOOL)showCompletions:(NSArray<NSString *> *)words;
/// NO for an invalid index/foreign colour; valid non-RGB colours retain the existing fallback.
- (BOOL)setSyntaxStyle:(NSInteger)index foreground:(NSColor *)foreground background:(nullable NSColor *)background bold:(BOOL)bold italic:(BOOL)italic;
/// NO for NUL-containing or unencodable text.
- (BOOL)showCallTip:(NSString *)text;
/// NO for invalid bounds, an unavailable font or an invalid name; existing state is kept.
- (BOOL)setSyntaxFont:(NSInteger)index name:(NSString *)name size:(double)size;
/// Global base metrics are per-view. Explicit profile face and size override each dimension separately.
- (BOOL)setBaseFontName:(NSString *)name size:(double)size;
@property(nonatomic) NSInteger zoomLevel;
/// Inherit subsequent default changes until the user zooms this view independently.
- (void)applyDefaultZoomLevel:(NSInteger)level;
- (BOOL)setSyntaxFont:(NSInteger)index faceOverride:(nullable NSString *)name sizeOverride:(nullable NSNumber *)size;
/// Comparison-only presentation primitives; callers use independent snapshot renderers.
/// No method below edits text, Undo, savepoint or selections. Indicator21/22 and marker2/3/4
/// are distinct from search20/bookmark1. Main-thread only; all batches prevalidate.
@property(nonatomic) BOOL comparisonPresentation;
@property(nonatomic, readonly) BOOL selectionIsRectangular;
@property(nonatomic, copy, nullable) void (^onComparisonViewportChange)(void);
@property(nonatomic) NSInteger comparisonTopDisplayLine;
@property(nonatomic) NSInteger comparisonHorizontalOffset;
@property(nonatomic, readonly) NSInteger comparisonDisplayRows;
@property(nonatomic, readonly) NSInteger comparisonLineHeight;
/// Read the view's actual font including zoom; setting is allowed only in comparison mode
/// and keeps both renderers on one scale without touching their text or selections.
@property(nonatomic, strong) NSFont *comparisonFont;
- (NSInteger)comparisonDocumentLineForDisplayLine:(NSInteger)line;
- (NSInteger)comparisonDisplayLineForDocumentLine:(NSInteger)line;
- (NSInteger)comparisonWrapCountForLine:(NSInteger)line;
- (NSInteger)comparisonYForByte:(NSInteger)position;
/// kind0 inserted(+),1 deleted(-),2 modified(~). Each batch <=512ranges per layer.
- (BOOL)addComparisonHighlights:(NSArray<TTByteRange *> *)lines inlineRanges:(NSArray<TTByteRange *> *)spans kind:(NSInteger)kind;
- (void)clearComparisonPresentation;
/// Annotation rows are virtual space only. Zero clears, maximum32760 (native signed-short count).
- (BOOL)setComparisonGapAfterLine:(NSInteger)line rows:(NSInteger)rows;
/// Source line zero stays visible (native engine rule). Empty clears all hiding.
- (BOOL)setComparisonHiddenLines:(NSIndexSet *)lines;
- (void)setComparisonWhitespaceVisible:(BOOL)visible;

- (BOOL)setSearchHighlights:(NSArray<TTByteRange *> *)ranges;
- (void)clearSearchHighlights;
/// Physical line length, without layout or text copying.
- (NSUInteger)findPreviewLineLengthAtByte:(NSUInteger)position;
/// Maximum physical line length currently intersecting this viewport, using line metadata only.
@property(nonatomic, readonly) NSUInteger findPreviewLongestVisibleLine;
/// Temporary Find-bar marks are separate from the advanced Find window's persistent highlights.
- (BOOL)setFindPreviewHighlights:(NSArray<TTByteRange *> *)ranges;

/// Native Scintilla primitive retained for native control/performance checks. Product Find uses SearchController.
- (BOOL)find:(NSString *)text matchCase:(BOOL)matchCase backwards:(BOOL)backwards;
@end
NS_ASSUME_NONNULL_END
