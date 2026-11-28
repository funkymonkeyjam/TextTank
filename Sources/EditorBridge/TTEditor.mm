// SPDX-License-Identifier: GPL-3.0-or-later
#import "TTEditor.h"
#import "ScintillaView.h"
#include "ILexer.h"
#include "ILoader.h"
#include "Lexilla.h"
#include <vector>
#include <string>
#include <cstring>
#include <cmath>
extern "C" Scintilla::ILexer5 *TextTankCreateUserLexer();

@implementation TTByteRange
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (instancetype)initWithLocation:(NSInteger)location length:(NSInteger)length {
    if ((self=[super init])) { _location=location; _length=length; }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)other {
    return other==self || ([other isKindOfClass:TTByteRange.class] && _location==((TTByteRange *)other).location && _length==((TTByteRange *)other).length);
}
- (NSUInteger)hash { return (NSUInteger)_location ^ ((NSUInteger)_length << 1); }
@end
/// Reject a foreign range type, negatives and overflow before forming NSMaxRange.
static BOOL TTValidatedByteRange(id candidate, NSUInteger documentLength, NSRange *result) {
    if (![candidate isKindOfClass:TTByteRange.class]) return NO;
    TTByteRange *value=candidate;
    if (value.location<0 || value.length<0) return NO;
    const NSUInteger location=(NSUInteger)value.location, length=(NSUInteger)value.length;
    if (location>documentLength || length>documentLength-location) return NO;
    *result=NSMakeRange(location,length);
    return YES;
}

@interface TTMacroAction ()
- (instancetype)initWithKind:(TTMacroActionKind)kind text:(NSString * _Nullable)text command:(TTEditorCommandIdentifier _Nullable)command name:(NSString * _Nullable)name message:(NSUInteger)message;
@end
@implementation TTMacroAction
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (instancetype)initWithKind:(TTMacroActionKind)kind text:(NSString *)text command:(TTEditorCommandIdentifier)command name:(NSString *)name message:(NSUInteger)message {
    if ((self=[super init])) { _kind=kind; _text=[text copy]; _command=[command copy]; _name=[name copy]; _message=message; }
    return self;
}
+ (instancetype)insertText:(NSString *)text { return [[self alloc] initWithKind:TTMacroActionKindInsertText text:text command:nil name:nil message:0]; }
+ (instancetype)command:(TTEditorCommandIdentifier)command { return [[self alloc] initWithKind:TTMacroActionKindCommand text:nil command:command name:nil message:0]; }
+ (instancetype)unsupported:(NSString *)name message:(NSUInteger)message { return [[self alloc] initWithKind:TTMacroActionKindUnsupported text:nil command:nil name:name message:message]; }
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@implementation TTTextEdit
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (instancetype)initWithRange:(TTByteRange *)range text:(NSString *)text {
    if ((self=[super init])) { _range=range; _text=[text copy]; }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
@end

@implementation TTSelectionRange
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (instancetype)initWithAnchor:(NSInteger)anchor caret:(NSInteger)caret {
    if ((self=[super init])) { _anchor=anchor; _caret=caret; }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)other {
    return other==self || ([other isKindOfClass:TTSelectionRange.class] && _anchor==((TTSelectionRange *)other).anchor && _caret==((TTSelectionRange *)other).caret);
}
- (NSUInteger)hash { return (NSUInteger)_anchor ^ ((NSUInteger)_caret << 1); }
@end

@interface TTEditorStatus ()
- (instancetype)initWithLine:(NSInteger)line column:(NSInteger)column lines:(NSInteger)lines tabWidth:(NSInteger)tabWidth useTabs:(BOOL)useTabs fontSize:(double)fontSize eol:(NSInteger)eol;
@end
@implementation TTEditorStatus
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (instancetype)initWithLine:(NSInteger)line column:(NSInteger)column lines:(NSInteger)lines tabWidth:(NSInteger)tabWidth useTabs:(BOOL)useTabs fontSize:(double)fontSize eol:(NSInteger)eol {
    if ((self = [super init])) { _line=line; _column=column; _lines=lines; _tabWidth=tabWidth; _useTabs=useTabs; _fontSize=fontSize; _eol=(TTLineEndingMode)eol; }
    return self;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)other {
    if (other == self) return YES;
    if (![other isKindOfClass:TTEditorStatus.class]) return NO;
    TTEditorStatus *value=other;
    return _line==value.line && _column==value.column && _lines==value.lines && _tabWidth==value.tabWidth && _useTabs==value.useTabs && _fontSize==value.fontSize && _eol==value.eol;
}
- (NSUInteger)hash { return (NSUInteger)_line ^ ((NSUInteger)_column << 1) ^ ((NSUInteger)_lines << 2) ^ ((NSUInteger)_tabWidth << 3) ^ (NSUInteger)_useTabs ^ [@(_fontSize) hash] ^ (NSUInteger)_eol; }
@end

static const int TTBookmarkMarker = 1;
static const int TTBookmarkMask = 1 << TTBookmarkMarker;
/// The change-bar margin, beside the text, and its width: a saved bar is Scintilla's 4 px left
/// rectangle and an unsaved one fills the margin, so the two differ by width as well as colour (DS-62).
static const int TTChangeMargin = 3;
static const int TTChangeMarginWidth = 8;
/// Documents, by pointer, whose change record began with an empty Undo history. Scintilla has no
/// query for it. An entry is removed when a view stops the record or attaches a new document.
static NSMutableSet<NSNumber *> *TTTrackedDocuments() {
    static NSMutableSet<NSNumber *> *documents;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ documents = [NSMutableSet set]; });
    return documents;
}
static const int TTSearchIndicator = 20, TTFindPreviewIndicator = 25;
// The native brace overlays are per view. They never fill a shared document indicator range.
static const int TTMatchedBraceIndicator = 23, TTUnmatchedBraceIndicator = 24;
struct TTBracePair { sptr_t position, match; };
static NSColor *TTColorFromScintilla(sptr_t color) {
    return [NSColor colorWithSRGBRed:(color & 255)/255.0 green:((color >> 8)&255)/255.0 blue:((color >> 16)&255)/255.0 alpha:1];
}
static sptr_t TTScintillaFromColor(NSColor *color) {
    return ((NSInteger)lround(color.redComponent*255)) | ((NSInteger)lround(color.greenComponent*255)<<8) | ((NSInteger)lround(color.blueComponent*255)<<16);
}

// NSString's UTF-8 constructors consume a leading EF BB BF as an external BOM.
// Editor bytes are already decoded content, so U+FEFF must remain ordinary text.
// TTStringFromUTF8 restores the one scalar they strip.
// nil means the string cannot be encoded (it holds an unpaired surrogate). Callers must
// reject the edit: messaging nil would replace the target with zero bytes, a silent deletion.
// A nil string keeps its historical meaning of empty text.
static NSData * _Nullable TTUTF8(NSString * _Nullable text) {
    return text ? [text dataUsingEncoding:NSUTF8StringEncoding] : [NSData data];
}
static NSString *TTStringFromUTF8(const void *bytes, NSUInteger length) {
    if (!length) return @"";
    NSString *decoded = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    NSCAssert(decoded != nil, @"Scintilla content must remain valid UTF-8");
    if (!decoded) return @"";
    // Foundation consumed exactly one leading EF BB BF (only at offset 0); put that scalar back.
    // Every other read is this single decode, with no intermediate buffer.
    const unsigned char *lead = (const unsigned char *)bytes;
    if (length >= 3 && lead[0] == 0xEF && lead[1] == 0xBB && lead[2] == 0xBF) return [@"\uFEFF" stringByAppendingString:decoded];
    return decoded;
}

// Scintilla's document canvas can be much wider than the viewport. Exposing its
// full NSView frame makes accessibility clients aim outside the visible editor.
// Preserve native text/input behavior while describing its visible screen region.
// Scintilla records keyboard and message input only. The mouse and a drop change the caret or
// the text with no macro notification, so the state is compared around each such event and a
// difference is reported as an unrecordable action (F59).
struct TTInteractionState { NSUInteger revision; sptr_t selections, anchor, caret; };
@interface TTEditor (MacroInteraction)
- (void)performNativeMacroInput:(void (NS_NOESCAPE ^)(void))input;
- (void)performReturn:(void (NS_NOESCAPE ^)(void))nativeReturn;
- (BOOL)extendMacWordSelectionRight:(BOOL)right;
- (BOOL)canBeginPairing;
- (void)performPair:(NSString *)input closer:(char)closer commit:(void (NS_NOESCAPE ^)(void))commit;
- (TTInteractionState)interactionState;
- (void)reportMacroStep:(TTMacroAction *)step;
- (void)noteUnrecordedInteractionSince:(TTInteractionState)before;
@end
// Every editor that is recording. A split view shares the recorded document, and a drop into it
// (or the removal that ends a drag out of it) edits that document with no focus change, so the
// comparison covers each recording editor, whichever view handled the event. Main thread only.
static NSHashTable<TTEditor *> *TTRecordingEditors() {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}
// A drop can produce several before-change notifications followed by a caret move.
// Deliver its first rejection immediately, once per recording, including on a clone.
struct TTMouseRecording {
    TTEditor *editor;
    TTInteractionState before;
    bool reported;
};
struct TTMouseMacroInteraction {
    std::vector<TTMouseRecording> recordings;
    TTMouseRecording *find(TTEditor *editor) {
        for (auto &recording : recordings) if (recording.editor == editor) return &recording;
        return nullptr;
    }
    void capture(TTEditor *editor) {
        TTMouseRecording recording{editor, [editor interactionState], false};
        if (auto *existing = find(editor)) *existing = recording;
        else recordings.push_back(recording);
    }
};
static thread_local TTMouseMacroInteraction *TTActiveMouseInteraction = nullptr;
static void TTAroundUnrecordedInteraction(void (NS_NOESCAPE ^handle)(void)) {
    if (TTActiveMouseInteraction || !TTRecordingEditors().count) { handle(); return; }
    TTMouseMacroInteraction interaction;
    for (TTEditor *editor in TTRecordingEditors().allObjects) interaction.capture(editor);
    TTActiveMouseInteraction = &interaction;
    @try {
        handle();
        // Copy before calling observers, which may start another recording.
        for (size_t i = 0; i < interaction.recordings.size(); ++i) {
            const auto recording = interaction.recordings[i];
            if (!recording.reported) [recording.editor noteUnrecordedInteractionSince:recording.before];
        }
    } @finally { TTActiveMouseInteraction = nullptr; }
}
static char TTPairCloser(NSString *text) {
    if (text.length != 1) return 0;
    switch ([text characterAtIndex:0]) {
        case '(': return ')';
        case '[': return ']';
        case '{': return '}';
        case '"': return '"';
        case 0x27: return 0x27;
        default: return 0;
    }
}
// The frame recognizer can deliver the original single click to the content view after
// the workspace completed it, even after a later press. Keep only scalar event identities.
struct TTMouseEventStamp {
    NSInteger windowNumber = 0;
    NSInteger eventNumber = 0;
    NSTimeInterval timestamp = 0;
    bool covers(NSEvent *event) const {
        return windowNumber != 0 && windowNumber == event.windowNumber &&
            (event.timestamp < timestamp || (event.timestamp == timestamp && event.eventNumber == eventNumber));
    }
    void record(NSEvent *event) {
        if (!covers(event)) *this = {event.windowNumber, event.eventNumber, event.timestamp};
    }
};

struct TTFrameMousePhase {
    TTMouseEventStamp native, completed;
    bool accept(NSEvent *event, bool fallback) {
        if (event.clickCount != 1 || event.timestamp <= 0) return true;
        const bool deliver = !completed.covers(event) && !(fallback && native.covers(event));
        if (fallback) completed.record(event); else native.record(event);
        return deliver;
    }
};

@interface TTContentView : SCIContentView {
    TTFrameMousePhase _frameDown, _frameUp;
}
- (void)completeFrameDown:(NSEvent *)down up:(NSEvent *)up;
@property(nonatomic, weak) TTEditor *editor;
@property(nonatomic, copy) NSString *directPairKey;
@end
@implementation TTContentView
- (void)keyDown:(NSEvent *)event {
    TTEditor *editor = self.editor;
    if (!editor) { [self dispatchNativeKey:event]; return; }
    [editor performNativeMacroInput:^{ [self dispatchNativeKey:event]; }];
}
- (void)dispatchNativeKey:(NSEvent *)event {
    NSString *input = event.charactersIgnoringModifiers;
    const unichar key = input.length == 1 ? [input characterAtIndex:0] : 0;
    const NSEventModifierFlags shortcuts = NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl;
    TTEditor *editor = self.editor;
    const NSEventModifierFlags wordModifiers = shortcuts | NSEventModifierFlagShift;
    if ((key == NSRightArrowFunctionKey || key == NSLeftArrowFunctionKey) &&
        (event.modifierFlags & wordModifiers) == (NSEventModifierFlagOption | NSEventModifierFlagShift) &&
        !self.hasMarkedText && [editor extendMacWordSelectionRight:key == NSRightArrowFunctionKey]) return;
    if (editor && (key == '\r' || key == '\n' || key == NSEnterCharacter) &&
        !(event.modifierFlags & shortcuts) && !self.hasMarkedText) {
        [editor performReturn:^{ [super keyDown:event]; }];
    } else if (editor.autoPairEnabled && !self.hasMarkedText &&
               !(event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) &&
               TTPairCloser(event.characters) && [editor canBeginPairing]) {
        NSString *outer = _directPairKey;
        _directPairKey = event.characters;
        @try { [super keyDown:event]; } @finally { _directPairKey = outer; }
    } else {
        [super keyDown:event];
    }
}
- (void)insertText:(id)text replacementRange:(NSRange)replacement {
    TTEditor *editor = self.editor;
    if (!editor) { [self dispatchNativeText:text replacementRange:replacement]; return; }
    [editor performNativeMacroInput:^{ [self dispatchNativeText:text replacementRange:replacement]; }];
}
- (void)dispatchNativeText:(id)text replacementRange:(NSRange)replacement {
    NSString *plain = [text isKindOfClass:NSAttributedString.class] ? [text string] : text;
    if (_directPairKey && replacement.location == NSNotFound && !self.hasMarkedText &&
        [_directPairKey isEqual:plain] && self.editor) {
        [self.editor performPair:plain closer:TTPairCloser(plain) commit:^{ [super insertText:text replacementRange:replacement]; }];
    } else {
        [super insertText:text replacementRange:replacement];
    }
}
- (NSRect)accessibilityFrame {
    if (!self.window) return NSZeroRect;
    return [self.window convertRectToScreen:[self convertRect:self.visibleRect toView:nil]];
}
// A right-click in the text lands here, and the engine always answers with its own Undo, Cut,
// Copy, Paste menu, so AppKit never asks the views above for theirs. The menu assigned to the
// TTEditor that wraps this view is therefore added below the engine's items. The engine builds
// a new menu for every request; its items are kept as they are and the extra items are copies,
// because a menu item belongs to one menu. The margin keeps the engine's menu unchanged.
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSMenu *menu = [super menuForEvent:event];
    if (!menu) return nil;
    NSMenu *extra = nil;
    for (NSView *view = self.superview; view; view = view.superview) {
        if ([view isKindOfClass:TTEditor.class]) { extra = view.menu; break; }
    }
    if (!extra) return menu;
    // The extra menu fills itself in when it is about to open; ask for that now.
    id<NSMenuDelegate> delegate = extra.delegate;
    if ([delegate respondsToSelector:@selector(menuNeedsUpdate:)]) [delegate menuNeedsUpdate:extra];
    if (extra.numberOfItems == 0) return menu;
    [menu addItem:NSMenuItem.separatorItem];
    for (NSMenuItem *item in extra.itemArray) {
        NSMenuItem *copy = [item copy];
        // The engine's menu does not validate its items, so a heading must be disabled here.
        if (!copy.isSeparatorItem && !copy.action && !copy.hasSubmenu) copy.enabled = NO;
        [menu addItem:copy];
    }
    return menu;
}
// VoiceOver's "show menu" action opens the same menu as a right-click, at the caret.
- (BOOL)accessibilityPerformShowMenu {
    ScintillaView *engine = nil;
    for (NSView *view = self.superview; view; view = view.superview) {
        if ([view isKindOfClass:ScintillaView.class]) { engine = (ScintillaView *)view; break; }
    }
    if (!engine || !self.window) return NO;
    const sptr_t caret = [engine message:SCI_GETCURRENTPOS];
    // As the engine does it: the caret's point is in the scroll view's coordinates.
    NSPoint point = NSMakePoint([engine message:SCI_POINTXFROMPOSITION wParam:0 lParam:caret],
                                [engine message:SCI_POINTYFROMPOSITION wParam:0 lParam:caret] + [engine message:SCI_TEXTHEIGHT wParam:0 lParam:0]);
    NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown location:[self.superview.superview convertPoint:point toView:nil] modifierFlags:0 timestamp:0 windowNumber:self.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
    NSMenu *menu = [self menuForEvent:event];
    if (!menu) return NO;
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    return YES;
}
// Deliver each phase through Scintilla's ordinary selection and macro handling.
- (void)deliverMouseDown:(NSEvent *)event fallback:(BOOL)fallback {
    if (_frameDown.accept(event, fallback)) TTAroundUnrecordedInteraction(^{ [super mouseDown:event]; });
}
- (void)mouseDown:(NSEvent *)event { [self deliverMouseDown:event fallback:NO]; }
- (void)mouseDragged:(NSEvent *)event {
    TTAroundUnrecordedInteraction(^{ [super mouseDragged:event]; });
}
- (void)deliverMouseUp:(NSEvent *)event fallback:(BOOL)fallback {
    if (_frameUp.accept(event, fallback)) TTAroundUnrecordedInteraction(^{ [super mouseUp:event]; });
}
- (void)mouseUp:(NSEvent *)event { [self deliverMouseUp:event fallback:NO]; }
- (void)completeFrameDown:(NSEvent *)down up:(NSEvent *)up {
    [self deliverMouseDown:down fallback:YES];
    [self deliverMouseUp:up fallback:YES];
}
// A file dragged from Finder opens as a document, as it does when dropped on the Dock icon. The
// engine would accept the drop and then do nothing with it. Dragged text is still the engine's.
- (NSArray<NSURL *> *)droppedFileURLs:(id<NSDraggingInfo>)sender {
    return [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}] ?: @[];
}
// Snapshot comparison renderers refuse all incoming drops before reading their pasteboard.
// Ordinary editors retain their existing file-open and Scintilla text-drop behavior.
- (BOOL)isComparisonDestination {
    for (NSView *view=self.superview;view;view=view.superview) {
        if ([view isKindOfClass:TTEditor.class]) return ((TTEditor *)view).comparisonPresentation;
    }
    return NO;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    if ([self isComparisonDestination]) return NSDragOperationNone;
    return [self droppedFileURLs:sender].count ? NSDragOperationCopy : [super draggingEntered:sender];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    if ([self isComparisonDestination]) return NSDragOperationNone;
    return [self droppedFileURLs:sender].count ? NSDragOperationCopy : [super draggingUpdated:sender];
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if ([self isComparisonDestination]) return NO;
    NSArray<NSURL *> *files = [self droppedFileURLs:sender];
    if (files.count) {
        // After the drag session ends, so an encoding question or an error is not shown mid-drag.
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSURL *file in files) {
                [NSDocumentController.sharedDocumentController openDocumentWithContentsOfURL:file display:YES completionHandler:^(NSDocument *document, BOOL alreadyOpen, NSError *error) {
                    if (error && !([error.domain isEqualToString:NSCocoaErrorDomain] && error.code == NSUserCancelledError)) [NSApp presentError:error];
                }];
            }
        });
        return YES;
    }
    __block BOOL accepted = NO;
    TTAroundUnrecordedInteraction(^{ accepted = [super performDragOperation:sender]; });
    return accepted;
}
// A drag out that the destination asks to be removed deletes the dragged text here, after the mouse
// events have ended.
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    TTAroundUnrecordedInteraction(^{ [super draggingSession:session endedAtPoint:screenPoint operation:operation]; });
}
@end
// A native message may call back into another editor before returning. Keep the origin and
// any matching MacroRecord on this call's stack frame, never on the next or nested message.
struct TTMacroMessage {
    __unsafe_unretained ScintillaView *source;
    unsigned int message;
    __unsafe_unretained NSObject *search;
    uptr_t length;
    sptr_t data;
    bool sourceStepReported = false;
    bool targetCompared = false;
    bool targetUnchanged = false;
};
static thread_local TTMacroMessage *TTActiveMacroMessage = nullptr;
static thread_local bool TTWatchMacroMessages = false;
@interface TTScintillaView : ScintillaView
- (sptr_t)dispatchMessage:(unsigned int)message wParam:(uptr_t)wParam lParam:(sptr_t)lParam search:(NSObject *)search;
@end
@implementation TTScintillaView
+ (Class)contentViewClass { return TTContentView.class; }
- (void)insertText:(id)text {
    // ScintillaView's public insertion selector calls the backend directly.
    TTEditor *editor = ((TTContentView *)self.content).editor;
    if (!editor) { [super insertText:text]; return; }
    [editor performNativeMacroInput:^{ [super insertText:text]; }];
}
- (sptr_t)dispatchMessage:(unsigned int)message wParam:(uptr_t)wParam lParam:(sptr_t)lParam search:(NSObject *)search {
    if (!TTWatchMacroMessages) return [super message:message wParam:wParam lParam:lParam];
    TTMacroMessage frame{self, message, search, wParam, lParam};
    TTMacroMessage *outer = TTActiveMacroMessage;
    TTActiveMacroMessage = &frame;
    @try { return [super message:message wParam:wParam lParam:lParam]; }
    @finally { TTActiveMacroMessage = outer; }
}
- (sptr_t)message:(unsigned int)message wParam:(uptr_t)wParam lParam:(sptr_t)lParam {
    if (!TTWatchMacroMessages) return [super message:message wParam:wParam lParam:lParam];
    return [self dispatchMessage:message wParam:wParam lParam:lParam search:nil];
}
- (sptr_t)message:(unsigned int)message wParam:(uptr_t)wParam {
    if (!TTWatchMacroMessages) return [super message:message wParam:wParam];
    return [self dispatchMessage:message wParam:wParam lParam:0 search:nil];
}
- (sptr_t)message:(unsigned int)message {
    if (!TTWatchMacroMessages) return [super message:message];
    return [self dispatchMessage:message wParam:0 lParam:0 search:nil];
}
@end

// Extend the number gutter through the unused viewport without editing the document.
@interface TTEmptyLineNumbersView : NSView
@property(nonatomic,weak) ScintillaView *engine;
/// Font and colour of the last draw, rebuilt only when the face, size or colour changes.
@property(nonatomic,copy) NSString *attributesKey;
@property(nonatomic,strong) NSDictionary *attributes;
@end
@implementation TTEmptyLineNumbersView
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (BOOL)isAccessibilityElement { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    ScintillaView *engine = self.engine;
    if (!engine) return;
    const NSInteger width = [engine message:SCI_GETMARGINWIDTHN wParam:0];
    const NSInteger height = [engine message:SCI_TEXTHEIGHT wParam:0];
    if (width <= 0 || height <= 0) return;
    const NSInteger count = [engine message:SCI_GETLINECOUNT];
    const NSInteger displayed = [engine message:SCI_VISIBLEFROMDOCLINE wParam:count];
    const NSInteger first = [engine message:SCI_GETFIRSTVISIBLELINE];
    CGFloat y = (displayed - first) * height;
    NSInteger number = count + 1;
    if (y < 0) { NSInteger skip = (NSInteger)floor(-y / height); y += skip * height; number += skip; }
    std::vector<char> face((size_t)[engine message:SCI_STYLEGETFONT wParam:STYLE_LINENUMBER lParam:0] + 1);
    [engine message:SCI_STYLEGETFONT wParam:STYLE_LINENUMBER lParam:(sptr_t)face.data()];
    CGFloat size = MAX(1, [engine message:SCI_STYLEGETSIZEFRACTIONAL wParam:STYLE_LINENUMBER] / 100.0 + [engine message:SCI_GETZOOM]);
    NSInteger rgb = [engine message:SCI_STYLEGETFORE wParam:STYLE_LINENUMBER];
    NSString *faceName = [NSString stringWithUTF8String:face.data()] ?: @"";
    NSString *key = [NSString stringWithFormat:@"%@|%.2f|%ld", faceName, size, (long)rgb];
    if (![key isEqualToString:_attributesKey]) {
        NSFont *font = [NSFont fontWithName:faceName size:MAX(1,size)] ?: [NSFont monospacedSystemFontOfSize:MAX(1,size) weight:NSFontWeightRegular];
        NSColor *color = TTColorFromScintilla(rgb);
        _attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:color};
        _attributesKey = key;
    }
    NSDictionary *attributes = _attributes;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSIntersectionRect(self.bounds,NSMakeRect(0,0,width,self.bounds.size.height)));
    for (; y < self.bounds.size.height; y += height, ++number) {
        NSString *label = [NSString stringWithFormat:@"%ld",(long)number];
        NSSize textSize = [label sizeWithAttributes:attributes];
        [label drawAtPoint:NSMakePoint(width - textSize.width - 3,y + MAX(0,(height-textSize.height)/2)) withAttributes:attributes];
    }
    [NSGraphicsContext restoreGraphicsState];
}
@end

struct TTCommandEntry { const char *identifier; unsigned int message; bool replay; bool records; bool modifiesText; };
// Zero-message entries are handled below; aliases replay but never own a recorded message name.
static const TTCommandEntry TTCommandEntries[] = {
    {"addNextOccurrence", 0, false, false, false},
    {"backTab", SCI_BACKTAB, true, true, true},
    {"bookmarkClearAll", 0, false, false, false},
    {"bookmarkCopyLines", 0, false, false, false},
    {"bookmarkCutLines", 0, false, false, true},
    {"bookmarkDeleteLines", 0, false, false, true},
    {"bookmarkInvert", 0, false, false, false},
    {"bookmarkNext", 0, false, false, false},
    {"bookmarkPrevious", 0, false, false, false},
    {"bookmarkToggle", 0, false, false, false},
    {"cancel", SCI_CANCEL, true, true, false},
    {"charLeft", SCI_CHARLEFT, true, true, false},
    {"charLeftExtend", SCI_CHARLEFTEXTEND, true, true, false},
    {"charRight", SCI_CHARRIGHT, true, true, false},
    {"charRightExtend", SCI_CHARRIGHTEXTEND, true, true, false},
    {"clearAdditionalSelections", 0, false, false, false},
    {"copy", SCI_COPY, true, true, false},
    {"cut", SCI_CUT, true, true, true},
    {"deleteBack", SCI_DELETEBACK, true, true, true},
    {"deleteForward", SCI_CLEAR, true, true, true},
    {"deleteLine", SCI_LINEDELETE, true, true, true},
    {"deleteLineLeft", SCI_DELLINELEFT, true, true, true},
    {"deleteLineRight", SCI_DELLINERIGHT, true, true, true},
    {"deleteWordLeft", SCI_DELWORDLEFT, true, true, true},
    {"deleteWordRight", SCI_DELWORDRIGHT, true, true, true},
    {"documentEnd", SCI_DOCUMENTEND, true, true, false},
    {"documentEndExtend", SCI_DOCUMENTENDEXTEND, true, true, false},
    {"documentStart", SCI_DOCUMENTSTART, true, true, false},
    {"documentStartExtend", SCI_DOCUMENTSTARTEXTEND, true, true, false},
    {"duplicateLine", SCI_LINEDUPLICATE, true, true, true},
    {"duplicateSelection", SCI_SELECTIONDUPLICATE, true, true, true},
    {"foldAll", 0, false, false, false},
    {"foldCurrent", 0, false, false, false},
    {"foldLevel1", 0, false, false, false},
    {"foldLevel2", 0, false, false, false},
    {"foldLevel3", 0, false, false, false},
    {"foldLevel4", 0, false, false, false},
    {"foldLevel5", 0, false, false, false},
    {"foldLevel6", 0, false, false, false},
    {"foldLevel7", 0, false, false, false},
    {"foldLevel8", 0, false, false, false},
    {"gotoMatchingBrace", 0, false, false, false},
    {"home", SCI_HOME, true, true, false},
    {"homeDisplay", SCI_HOMEDISPLAY, true, true, false},
    {"homeExtend", SCI_HOMEEXTEND, true, true, false},
    {"indent", SCI_TAB, true, false, true},
    {"joinLines", 0, false, false, true},
    {"lineCopy", SCI_LINECOPY, true, true, false},
    {"lineCut", SCI_LINECUT, true, true, true},
    {"lineDown", SCI_LINEDOWN, true, true, false},
    {"lineDownExtend", SCI_LINEDOWNEXTEND, true, true, false},
    {"lineEnd", SCI_LINEEND, true, true, false},
    {"lineEndDisplay", SCI_LINEENDDISPLAY, true, true, false},
    {"lineEndExtend", SCI_LINEENDEXTEND, true, true, false},
    {"lineUp", SCI_LINEUP, true, true, false},
    {"lineUpExtend", SCI_LINEUPEXTEND, true, true, false},
    {"lower", SCI_LOWERCASE, true, true, true},
    {"moveLineDown", SCI_MOVESELECTEDLINESDOWN, true, true, true},
    {"moveLineUp", SCI_MOVESELECTEDLINESUP, true, true, true},
    {"newLine", SCI_NEWLINE, true, true, true},
    {"pageDown", SCI_PAGEDOWN, true, true, false},
    {"pageDownExtend", SCI_PAGEDOWNEXTEND, true, true, false},
    {"pageUp", SCI_PAGEUP, true, true, false},
    {"pageUpExtend", SCI_PAGEUPEXTEND, true, true, false},
    {"paraDown", SCI_PARADOWN, true, true, false},
    {"paraDownExtend", SCI_PARADOWNEXTEND, true, true, false},
    {"paraUp", SCI_PARAUP, true, true, false},
    {"paraUpExtend", SCI_PARAUPEXTEND, true, true, false},
    {"paste", SCI_PASTE, true, true, true},
    {"rectangularSelection", 0, false, false, false},
    {"redo", SCI_REDO, false, false, true},
    {"selectAll", SCI_SELECTALL, true, true, false},
    {"selectAllOccurrences", 0, false, false, false},
    {"selectMatchingBrace", 0, false, false, false},
    {"showWhitespace", 0, false, false, false},
    {"streamSelection", 0, false, false, false},
    {"tab", SCI_TAB, true, true, true},
    {"toggleEOL", 0, false, false, false},
    {"toggleLineNumbers", 0, false, false, false},
    {"toggleOvertype", 0, false, false, false},
    {"transposeLine", SCI_LINETRANSPOSE, true, true, true},
    {"trimTrailing", 0, false, false, true},
    {"undo", SCI_UNDO, false, false, true},
    {"unfoldAll", 0, false, false, false},
    {"unindent", SCI_BACKTAB, true, false, true},
    {"upper", SCI_UPPERCASE, true, true, true},
    {"vcHome", SCI_VCHOME, true, true, false},
    {"vcHomeExtend", SCI_VCHOMEEXTEND, true, true, false},
    {"wordLeft", SCI_WORDLEFT, true, true, false},
    {"wordLeftExtend", SCI_WORDLEFTEXTEND, true, true, false},
    {"wordPartLeft", SCI_WORDPARTLEFT, true, true, false},
    {"wordPartLeftExtend", SCI_WORDPARTLEFTEXTEND, true, true, false},
    {"wordPartRight", SCI_WORDPARTRIGHT, true, true, false},
    {"wordPartRightExtend", SCI_WORDPARTRIGHTEXTEND, true, true, false},
    {"wordRight", SCI_WORDRIGHT, true, true, false},
    {"wordRightExtend", SCI_WORDRIGHTEXTEND, true, true, false},
    {"zoomIn", SCI_ZOOMIN, false, false, false},
    {"zoomOut", SCI_ZOOMOUT, false, false, false},
};
static NSDictionary<NSString *, NSNumber *> *TTCommandMessages(bool replay, bool records) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (const auto &entry : TTCommandEntries) {
        if (entry.message && (!replay || entry.replay) && (!records || entry.records))
            map[[NSString stringWithUTF8String:entry.identifier]] = @(entry.message);
    }
    return [map copy];
}
static NSDictionary<NSString *, NSNumber *> *TTMacroCommands() {
    static NSDictionary *map; static dispatch_once_t once;
    dispatch_once(&once, ^{ map = TTCommandMessages(true, true); });
    return map;
}
static NSDictionary<NSString *, NSNumber *> *TTReplayCommands() {
    static NSDictionary *map; static dispatch_once_t once;
    dispatch_once(&once, ^{ map = TTCommandMessages(true, false); });
    return map;
}
static NSDictionary<NSString *, NSNumber *> *TTDispatchCommands() {
    static NSDictionary *map; static dispatch_once_t once;
    dispatch_once(&once, ^{ map = TTCommandMessages(false, false); });
    return map;
}
/// Canonical recorded name for each allowed message, built once rather than scanned per key.
/// indent/unindent are playback-only aliases; only tab/backTab belong to the recording table.
static NSDictionary<NSNumber *, NSString *> *TTMacroNamesByMessage() {
    static NSDictionary<NSNumber *, NSString *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *reverse = [NSMutableDictionary dictionary];
        for (NSString *name in [TTMacroCommands().allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSNumber *message = TTMacroCommands()[name];
            if (!reverse[message]) reverse[message] = name;
        }
        names = [reverse copy];
    });
    return names;
}
/// A name the person can recognise for an action that cannot be recorded.
static NSString *TTUnrecordableName(unsigned int message) {
    switch (message) {
        case SCI_UNDO: return @"Undo";
        case SCI_REDO: return @"Redo";
        case SCI_EDITTOGGLEOVERTYPE: return @"Switching Overtype";
        case SCI_REPLACESEL: return @"Typing in Overtype mode or into several selections";
        case SCI_AUTOCSHOW: return @"The completion list";
        case SCI_GOTOLINE: return @"Go to Line";
        case SCI_SETSELECTIONMODE: case SCI_LINEDOWNRECTEXTEND: case SCI_LINEUPRECTEXTEND: case SCI_CHARLEFTRECTEXTEND:
        case SCI_CHARRIGHTRECTEXTEND: case SCI_HOMERECTEXTEND: case SCI_VCHOMERECTEXTEND: case SCI_LINEENDRECTEXTEND:
        case SCI_PAGEUPRECTEXTEND: case SCI_PAGEDOWNRECTEXTEND: return @"Rectangular selection";
        default: return [NSString stringWithFormat:@"An editing action (Scintilla message %u)", message];
    }
}
static TTMacroAction *TTUnrecordableStep(unsigned int message) {
    return [TTMacroAction unsupported:TTUnrecordableName(message) message:message];
}

NSNotificationName const TTEditorWillRetireNotification = @"TTEditorWillRetireNotification";
NSString *const TTEditorSuccessorKey = @"TTEditorSuccessor";

NSErrorDomain const TTEditorErrorDomain = @"TextTank.Editor";
NSNotificationName const TTEditorStateDidChangeNotification = @"TTEditorStateDidChange";

// Undo groups opened through the bridge, per Scintilla document, so a group opened on one view
// of a split also holds back the change callback of the other view. Main thread only.
static NSMapTable<NSNumber *, NSNumber *> *TTOpenGroups() {
    static NSMapTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSMapTable strongToStrongObjectsMapTable]; });
    return table;
}
// Editors holding back a change callback.
static NSHashTable *TTDeferredEditors() {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

struct TTLineNumberState { sptr_t lines, rows, top, rowHeight, margin; };
@interface TTEditor () <ScintillaNotificationProtocol> {
    TTLineNumberState _lineNumberState;
    NSMutableArray<NSString *> *_historyNames;
    NSString *_pendingUndoName, *_nextUndoName, *_cachedRedoName;
    NSUInteger _namedStartRevision, _cachedRedoRevision;
    sptr_t _cachedRedoCursor, _cachedRedoActions;
    NSInteger _defaultZoomLevel;
    BOOL _followsDefaultZoom;
    BOOL _indentingReturn;
    NSIndexSet *_eligiblePairPositions;
    NSMutableIndexSet *_insertedPairPositions;
    char _pairBytes[2];
    BOOL _hasSharedDocument;
    NSMutableArray<NSNumber *> *_heldSelection;
    sptr_t _heldTop, _heldDocument;
    BOOL _heldDisplaced;
    id _accessibilityDisplayObserver;
    BOOL _braceCacheValid;
    sptr_t _braceCaret, _braceEndStyled;
    NSUInteger _braceRevision;
    NSString *_recordedReturnIndent;
    BOOL _changeBarsVisible;
    NSInteger _unsavedChangeColour, _savedChangeColour;
    NSInteger _centeredColumnCharacters;
    sptr_t _plainMarginLeft, _plainMarginRight;
    sptr_t _naturalScrollWidth, _paddedScrollWidth;
    id _textAreaObserver;
}
@property(nonatomic, strong) ScintillaView *engine;
@property(nonatomic,strong) TTEmptyLineNumbersView *emptyLineNumbers;
@property(nonatomic, readwrite) NSUInteger revision;
@property(nonatomic) BOOL macroRecording;
@property(nonatomic, strong) NSObject *pendingMacroSearch;
@property(nonatomic, copy) BOOL (^pendingWrappedViewport)(BOOL apply);
@property(nonatomic) NSInteger pendingTopDocumentLine, pendingTopSubline;
@property(nonatomic) BOOL inNativeMacroInput, retiredNativeMacroInput, nativeInputChanged, nativeInputReported;
/// While recording: sees mouse events bound for the margins, which have no subclass hook.
@property(nonatomic, strong) id macroMouseMonitor;
@property(nonatomic) BOOL marginMouseDown;
@property(nonatomic) BOOL interactionPending;
@property(nonatomic) TTInteractionState pendingInteraction;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSDictionary *> *syntaxStyles;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSDictionary *> *syntaxFonts;
@property(nonatomic, copy) NSString *baseFontName;
@property(nonatomic) double basePointSize;
/// Digit count the line-number margin was last sized for; see -updateLineNumberMargin:.
@property(nonatomic) int marginDigits;
@property(nonatomic, readwrite) NSUInteger selectionGeneration;
/// A change callback is held back until the outermost undo group ends.
@property(nonatomic) BOOL changeDeferred;
@property(nonatomic) BOOL deferredFlushScheduled;
@property(nonatomic) BOOL stateNotificationScheduled;
/// Undo groups this view has open; released in dealloc so a lost view cannot hold callbacks back.
@property(nonatomic) NSInteger ownGroups;
- (BOOL)replaceSelectionWithEncodedBytes:(NSData *)data;
- (void)deliverDeferredChange;
- (BOOL)undoGroupOpen;
@property(nonatomic) BOOL cppDefaults;
@property(nonatomic) BOOL comparisonScrollScheduled;
- (void)applyComparisonStyle;
- (void)comparisonViewportChanged;
@end
@implementation TTInitialUTF8Load {
    Scintilla::ILoader *_loader;
    NSUInteger _remainingBytes;
}
- (instancetype)initWithByteCount:(NSUInteger)bytes {
    if (!(self = [super init]) || bytes > INT32_MAX) return nil;
    // Creating a loader resets the requesting view's contraction state in Scintilla 5.6.9.
    // Use a private view so a failed/cancelled read cannot disturb a live editing view.
    _remainingBytes = bytes;
    ScintillaView *factory = [[ScintillaView alloc] initWithFrame:NSZeroRect];
    _loader = reinterpret_cast<Scintilla::ILoader *>([factory message:SCI_CREATELOADER wParam:bytes lParam:0]);
    return _loader ? self : nil;
}
- (void)dealloc { if (_loader) _loader->Release(); }
- (BOOL)appendContent:(TTDocumentUTF8 *)content {
    NSData *data = content.data;
    if (!_loader || !data || data.length > _remainingBytes) return NO;
    if (data.length && _loader->AddData(static_cast<const char *>(data.bytes), data.length) != SC_STATUS_OK) return NO;
    _remainingBytes -= data.length;
    return YES;
}
- (void *)readyDocument { return _loader && !_remainingBytes ? _loader->ConvertToDocument() : nullptr; }
- (void)finishTransfer { if (_loader) { _loader->Release(); _loader = nullptr; } }
@end

@implementation TTDocumentUTF8
- (instancetype)initWithData:(NSData *)data {
    if (!(self = [super init]) || !data) return nil;
    // Freeze mutable NSData before validating it. Cocoa copies immutable NSData by reference.
    NSData *snapshot = [data copy];
    const auto *bytes = static_cast<const uint8_t *>(snapshot.bytes);
    // Bound validation storage even for multibyte content. Foundation's decoder rejects malformed
    // sequences and accepts valid noncharacters; the original bytes go straight to Scintilla.
    for (NSUInteger start = 0; start < snapshot.length;) {
        NSUInteger end = start + MIN(snapshot.length - start, (NSUInteger)65536);
        while (end > start && end < snapshot.length && (bytes[end] & 0xc0) == 0x80) --end;
        if (end == start) return nil;
        CFStringRef decoded = CFStringCreateWithBytesNoCopy(kCFAllocatorDefault, bytes + start, end - start,
                                                           kCFStringEncodingUTF8, false, kCFAllocatorNull);
        if (!decoded) return nil;
        CFRelease(decoded);
        start = end;
    }
    _data = snapshot;
    return self;
}
@end

@implementation TTEditor
@synthesize comparisonPresentation = _comparisonPresentation;
@synthesize braceHighlightEnabled = _braceHighlightEnabled;
@synthesize currentLineHighlightEnabled = _currentLineHighlightEnabled;
@synthesize indentGuidesEnabled = _indentGuidesEnabled;
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSAssert(NSThread.isMainThread, @"Editor must be created on the main thread");
        _historyNames = [NSMutableArray array];
        _cachedRedoCursor = -1;
        _syntaxStyles=[NSMutableDictionary dictionary];_syntaxFonts=[NSMutableDictionary dictionary];
        _engine = [[TTScintillaView alloc] initWithFrame:NSZeroRect];
        ((TTContentView *)_engine.content).editor = self;
        // The engine's own blank margins beside the text, which the ordinary layout keeps.
        _plainMarginLeft = [_engine message:SCI_GETMARGINLEFT];
        _plainMarginRight = [_engine message:SCI_GETMARGINRIGHT];
        _autoIndentEnabled = YES;
        _braceHighlightEnabled = YES;
        _currentLineHighlightEnabled = YES;
        _indentGuidesEnabled = YES;
        _engine.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_engine];
        _engine.delegate = self;
        [_engine message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
        [_engine message:SCI_SETBIDIRECTIONAL wParam:SC_BIDIRECTIONAL_L2R];
        __weak TTEditor *weakEditor = self;
        _accessibilityDisplayObserver = [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakEditor applyPalette]; }];
        _followsDefaultZoom = YES;
        _baseFontName = @"Menlo";
        _basePointSize = 14;
        [self applyPalette];
        self.accessibilityDocumentName = nil;
        // The ruler otherwise announces the engine's own name for it.
        _engine.scrollView.verticalRulerView.accessibilityLabel = @"Line numbers and bookmarks";
        [_engine message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
        [self updateLineNumberMargin:YES];
        [_engine message:SCI_MARKERDEFINE wParam:TTBookmarkMarker lParam:SC_MARK_CIRCLE];
        [_engine message:SCI_SETMARGINTYPEN wParam:1 lParam:SC_MARGIN_SYMBOL];
        [_engine message:SCI_SETMARGINMASKN wParam:1 lParam:TTBookmarkMask];
        [_engine message:SCI_SETMARGINWIDTHN wParam:1 lParam:14];
        // Scintilla starts with a fixed 2000 px horizontal range whatever the text. Start with
        // none and let it grow to the widest line it has laid out, so an empty or narrow
        // document reports nothing to scroll sideways.
        [_engine message:SCI_SETSCROLLWIDTH wParam:1];
        [_engine message:SCI_SETSCROLLWIDTHTRACKING wParam:1];
        [_engine message:SCI_SETMULTIPLESELECTION wParam:1];
        [_engine message:SCI_SETADDITIONALSELECTIONTYPING wParam:1];
        [_engine message:SCI_SETMULTIPASTE wParam:SC_MULTIPASTE_EACH];
        // Undo and Redo put back the selection and scroll position of the view that made the edit.
        [_engine message:SCI_SETUNDOSELECTIONHISTORY wParam:SC_UNDO_SELECTION_HISTORY_ENABLED | SC_UNDO_SELECTION_HISTORY_SCROLL];
        [_engine message:SCI_SETTABWIDTH wParam:4];
        [_engine message:SCI_SETPROPERTY wParam:(uptr_t)"fold" lParam:(sptr_t)"1"];
        for(int marker=SC_MARKNUM_FOLDEREND;marker<=SC_MARKNUM_FOLDEROPEN;++marker) {
            int symbol=(marker==SC_MARKNUM_FOLDER || marker==SC_MARKNUM_FOLDEREND) ? SC_MARK_BOXPLUS : (marker==SC_MARKNUM_FOLDEROPEN || marker==SC_MARKNUM_FOLDEROPENMID) ? SC_MARK_BOXMINUS : SC_MARK_VLINE;
            [_engine message:SCI_MARKERDEFINE wParam:marker lParam:symbol];
        }
        [_engine message:SCI_SETMARGINTYPEN wParam:2 lParam:SC_MARGIN_SYMBOL];
        [_engine message:SCI_SETMARGINMASKN wParam:2 lParam:SC_MASK_FOLDERS];
        [_engine message:SCI_SETMARGINWIDTHN wParam:2 lParam:16];
        [_engine message:SCI_SETMARGINSENSITIVEN wParam:2 lParam:1];
        // Change bars: hidden until View > Show > Change Bars. It takes the text's own background,
        // so a bar reads as the edge of its line.
        [TTTrackedDocuments() removeObject:@([_engine message:SCI_GETDOCPOINTER])];
        [_engine message:SCI_SETMARGINTYPEN wParam:TTChangeMargin lParam:SC_MARGIN_BACK];
        [_engine message:SCI_SETMARGINMASKN wParam:TTChangeMargin lParam:SC_MASK_HISTORY];
        [_engine message:SCI_SETMARGINWIDTHN wParam:TTChangeMargin lParam:0];
        [_engine message:SCI_MARKERDEFINE wParam:SC_MARKNUM_HISTORY_MODIFIED lParam:SC_MARK_FULLRECT];
        [_engine message:SCI_MARKERDEFINE wParam:SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED lParam:SC_MARK_FULLRECT];
        [_engine message:SCI_MARKERDEFINE wParam:SC_MARKNUM_HISTORY_SAVED lParam:SC_MARK_LEFTRECT];
        [_engine message:SCI_MARKERDEFINE wParam:SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN lParam:SC_MARK_BAR];
        [self applyChangeBarColours];
        // The text area's width changes with the window, a split, the sidebar and the gutter.
        NSClipView *textArea = _engine.scrollView.contentView;
        textArea.postsFrameChangedNotifications = YES;
        _textAreaObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification object:textArea
            queue:nil usingBlock:^(NSNotification *note) {
                [weakEditor normalizeTextArea];
                [weakEditor updateCenteredColumn];
                // The gutter changed width: both sides of the boundary are drawn again. (What kept
                // the old gutter over the first characters was its unclipped drawing; see init.)
                NSClipView *area = note.object;
                area.needsDisplay = YES;
                area.documentView.needsDisplay = YES;
                [weakEditor redrawGutter];
            }];
        [_engine message:SCI_SETAUTOMATICFOLD wParam:SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];
        // Scintilla creates its scroll view at 100x10. Its initWithFrame does not
        // position the inner content. Start at zero so this real size transition also
        // invokes backend Resize, which initializes the document viewport.
        _engine.frame = self.bounds;
        NSRulerView *ruler = _engine.scrollView.verticalRulerView;
        // Views no longer clip their drawing by default. What the gutter drew while it was wider
        // would stay over the text beside it after it narrows, through any later redraw.
        ruler.clipsToBounds = YES;
        _emptyLineNumbers = [[TTEmptyLineNumbersView alloc] initWithFrame:ruler.bounds];
        _emptyLineNumbers.clipsToBounds = YES;
        _emptyLineNumbers.engine = _engine;
        _emptyLineNumbers.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [ruler addSubview:_emptyLineNumbers];
    }
    return self;
}
- (void)layout {
    [super layout];
    _engine.frame = self.bounds;
    _emptyLineNumbers.frame = _engine.scrollView.verticalRulerView.bounds;
    _emptyLineNumbers.needsDisplay = YES;
    // A taller view draws more filler numbers past the end of the document.
    if ([self lineNumberDigits] != _marginDigits) [self updateLineNumberMargin:NO];
    [self updateCenteredColumn];
}
/// Digits of the largest number the gutter can show: the filler view numbers the rows past the
/// end of the document, so that is the line count plus one screen of rows.
- (int)lineNumberDigits {
    sptr_t largest = [_engine message:SCI_GETLINECOUNT] + [_engine message:SCI_LINESONSCREEN] + 1;
    int digits = 1;
    while (largest >= 10) { largest /= 10; ++digits; }
    return digits;
}
/// Sizes the line-number margin for the largest number drawn in the current font and zoom, and
/// never below the 48 px every small document has. Width 0 is the hidden state: only `show`
/// (init and toggle-on) may leave it, so zoom or an edit never brings back a hidden gutter.
- (void)updateLineNumberMargin:(BOOL)show {
    const sptr_t current = [_engine message:SCI_GETMARGINWIDTHN wParam:0];
    if (!show && current == 0) return;
    _marginDigits = [self lineNumberDigits];
    // Some user font faces have proportional figures. Measure every figure at the actual gutter style and zoom.
    sptr_t widest = 0;
    for (char figure = '0'; figure <= '9'; ++figure) {
        const std::string sample((size_t)_marginDigits, figure);
        widest = MAX(widest, [_engine message:SCI_TEXTWIDTH wParam:STYLE_LINENUMBER lParam:(sptr_t)sample.c_str()]);
    }
    // 3 is Scintilla's own padding right of the number; 2 keeps the first digit off the edge.
    const sptr_t width = MAX((sptr_t)48, widest + 3 + 2);
    if (width != current) [_engine message:SCI_SETMARGINWIDTHN wParam:0 lParam:width];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if (_engine) [self applyPalette];
}
- (BOOL)usesDarkPalette {
    return [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
}
// Search marks (indicator 20). One colour cannot serve both appearances: citrus on the light paper
// background was about 1.05:1. The outline is drawn at full strength in a colour that is at least
// 3:1 against the editor background (olive on paper about 5.6:1, citrus on carbon about 15:1); the
// fill stays light enough for the text inside to keep its own contrast. Increase Contrast darkens
// the light outline only: a stronger fill would lower the contrast of the text it covers.
- (void)applySearchIndicatorStyle {
    const BOOL dark = [self usesDarkPalette], highContrast = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
    for (int indicator : {TTSearchIndicator, TTFindPreviewIndicator}) {
        [_engine message:SCI_INDICSETSTYLE wParam:indicator lParam:INDIC_ROUNDBOX];
        [_engine message:SCI_INDICSETFORE wParam:indicator lParam:dark ? 0x5BF4C7 : (highContrast ? 0x00402E : 0x006B4D)];
        [_engine message:SCI_INDICSETALPHA wParam:indicator lParam:70];
        [_engine message:SCI_INDICSETOUTLINEALPHA wParam:indicator lParam:255];
    }
}
- (void)applyPalette {
    const BOOL dark = [self usesDarkPalette], highContrast = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
    const sptr_t foreground = dark ? 0xF0F6F4 : 0x1F2015;
    const sptr_t background = dark ? 0x171810 : 0xF0F6F4;
    [_engine message:SCI_STYLESETFONT wParam:STYLE_DEFAULT lParam:(sptr_t)_baseFontName.UTF8String];
    [_engine message:SCI_STYLESETSIZEFRACTIONAL wParam:STYLE_DEFAULT lParam:lround(_basePointSize * 100)];
    [_engine message:SCI_STYLESETBOLD wParam:STYLE_DEFAULT lParam:0];
    [_engine message:SCI_STYLESETITALIC wParam:STYLE_DEFAULT lParam:0];
    [_engine message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:foreground];
    [_engine message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:background];
    [_engine message:SCI_STYLECLEARALL];
    [_engine message:SCI_STYLESETFORE wParam:STYLE_LINENUMBER lParam:dark ? 0xAAB8B3 : 0x59645F];
    [_engine message:SCI_STYLESETBACK wParam:STYLE_LINENUMBER lParam:dark ? 0x222A25 : 0xE3E9E5];
    [_engine message:SCI_SETFOLDMARGINCOLOUR wParam:1 lParam:background];[_engine message:SCI_SETFOLDMARGINHICOLOUR wParam:1 lParam:background];
    for(int marker=SC_MARKNUM_FOLDEREND;marker<=SC_MARKNUM_FOLDEROPEN;++marker){[_engine message:SCI_MARKERSETFORE wParam:marker lParam:background];[_engine message:SCI_MARKERSETBACK wParam:marker lParam:foreground];}
    [self applySearchIndicatorStyle];
    // Transparent outline for a pair and a squiggle for a mismatch. Native indicator drawing
    // preserves lexer glyph styles, including imported styles that use slots 34 and 35.
    [_engine message:SCI_INDICSETSTYLE wParam:TTMatchedBraceIndicator lParam:INDIC_STRAIGHTBOX];
    [_engine message:SCI_INDICSETFORE wParam:TTMatchedBraceIndicator lParam:dark ? 0xC4E29D : 0x3A5122];
    [_engine message:SCI_INDICSETALPHA wParam:TTMatchedBraceIndicator lParam:0];
    [_engine message:SCI_INDICSETOUTLINEALPHA wParam:TTMatchedBraceIndicator lParam:255];
    [_engine message:SCI_INDICSETSTYLE wParam:TTUnmatchedBraceIndicator lParam:INDIC_SQUIGGLE];
    [_engine message:SCI_INDICSETFORE wParam:TTUnmatchedBraceIndicator lParam:dark ? 0x98A3FF : 0x272F97];
    [_engine message:SCI_BRACEHIGHLIGHTINDICATOR wParam:1 lParam:TTMatchedBraceIndicator];
    [_engine message:SCI_BRACEBADLIGHTINDICATOR wParam:1 lParam:TTUnmatchedBraceIndicator];
    [self applyCurrentLineFrameWithHighContrast:highContrast];
    [self applyIndentGuides];
    if (_comparisonPresentation) [self applyComparisonStyle];
    // The bookmark dot: brand green on the light margin, citrus on the dark one, each at least 3:1.
    _bookmarkColour = dark ? 0x5BF4C7 : (highContrast ? 0x002E1C : 0x005B3A);
    [_engine message:SCI_MARKERSETBACK wParam:TTBookmarkMarker lParam:_bookmarkColour];
    [_engine message:SCI_MARKERSETFORE wParam:TTBookmarkMarker lParam:_bookmarkColour];
    [self applyChangeBarColours];
    [_engine message:SCI_SETCARETFORE wParam:foreground];
    // Selection uses the system's colours, so it follows the accent colour, the appearance and
    // Increase Contrast, and an unfocused pane shows the system's unemphasised selection.
    __block NSColor *selectionBack = nil, *selectionText = nil, *inactiveBack = nil;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        selectionBack = [NSColor.selectedTextBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        selectionText = [NSColor.selectedTextColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        inactiveBack = [NSColor.unemphasizedSelectedTextBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    [_engine message:SCI_SETSELFORE wParam:1 lParam:selectionText ? TTScintillaFromColor(selectionText) : (dark ? 0xFFFFFF : 0x101010)];
    [_engine message:SCI_SETSELBACK wParam:1 lParam:selectionBack ? TTScintillaFromColor(selectionBack) : (dark ? 0x725038 : 0xF1D4AF)];
    if (inactiveBack) [_engine message:SCI_SETELEMENTCOLOUR wParam:SC_ELEMENT_SELECTION_INACTIVE_BACK lParam:(sptr_t)(0xFF000000 | (NSUInteger)TTScintillaFromColor(inactiveBack))];
    // These style numbers mean comment, keyword and string in the cpp lexer only. Every other
    // lexer keeps the default colour until a language profile supplies its own styles.
    if (_cppDefaults) {
        for (int style : {1, 2, 3}) [_engine message:SCI_STYLESETFORE wParam:style lParam:dark ? 0x9BC18E : 0x47804B];
        for (int style : {5, 11, 17}) [_engine message:SCI_STYLESETFORE wParam:style lParam:dark ? 0xDBA6C9 : 0xA04470];
        for (int style : {6, 7, 13}) [_engine message:SCI_STYLESETFORE wParam:style lParam:dark ? 0x8ACFE8 : 0x255EA0];
    }
    NSDictionary *styles=[_syntaxStyles copy];
    for(NSNumber *index in styles) {NSDictionary *s=styles[index];[self setSyntaxStyle:index.integerValue foreground:s[@"foreground"] background:s[@"background"] bold:[s[@"bold"] boolValue] italic:[s[@"italic"] boolValue]];}
    for (NSNumber *index in _syntaxFonts) {
        NSDictionary *override = _syntaxFonts[index];
        [self applyFontToStyle:index.integerValue name:override[@"name"] size:override[@"size"]];
    }
    // STYLECLEARALL put the line-number style back on the default font.
    [self updateLineNumberMargin:NO];
    // The column is measured in the default style's font.
    [self updateCenteredColumn];
    _engine.needsDisplay = YES;
    _emptyLineNumbers.needsDisplay = YES;
}
// Change bars. Amber for a change that is not saved and green for a saved one, each at least 3:1
// against the text background they are drawn on (light 4.6:1 and 4.9:1, with Increase Contrast
// 8.4:1 and 9.2:1; dark 10.2:1 and 9.5:1). The colour is never the only cue: see TTChangeMarginWidth.
- (void)applyChangeBarColours {
    const BOOL dark = [self usesDarkPalette], highContrast = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast;
    _unsavedChangeColour = dark ? 0x54B4FF : (highContrast ? 0x00337A : 0x0A52B4);
    _savedChangeColour = dark ? 0x8CD06F : (highContrast ? 0x224D0E : 0x3A7A1F);
    for (int marker : {SC_MARKNUM_HISTORY_MODIFIED, SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED}) {
        [_engine message:SCI_MARKERSETFORE wParam:marker lParam:_unsavedChangeColour];
        [_engine message:SCI_MARKERSETBACK wParam:marker lParam:_unsavedChangeColour];
    }
    [_engine message:SCI_MARKERSETFORE wParam:SC_MARKNUM_HISTORY_SAVED lParam:_savedChangeColour];
    [_engine message:SCI_MARKERSETBACK wParam:SC_MARKNUM_HISTORY_SAVED lParam:_savedChangeColour];
    // Undone to the original text after a save: not saved, so the unsaved colour, as an outline.
    [_engine message:SCI_MARKERSETFORE wParam:SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN lParam:_unsavedChangeColour];
    [_engine message:SCI_MARKERSETBACK wParam:SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN lParam:dark ? 0x171810 : 0xF0F6F4];
}
- (NSInteger)unsavedChangeColour { return _unsavedChangeColour; }
- (NSInteger)savedChangeColour { return _savedChangeColour; }
/// Puts this view's choice on the engine. Scintilla keeps the option per view and the record per
/// document, and ignores a request to start the record while the document can undo.
- (void)applyChangeTracking {
    const BOOL shown = _changeBarsVisible && !_comparisonPresentation;
    sptr_t option = [_engine message:SCI_GETCHANGEHISTORY];
    if (_comparisonPresentation) option = SC_CHANGE_HISTORY_DISABLED;
    else if (shown) option = SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS;
    else option &= SC_CHANGE_HISTORY_ENABLED;
    NSNumber *document = @([_engine message:SCI_GETDOCPOINTER]);
    if (option == SC_CHANGE_HISTORY_DISABLED) {
        // Zero would discard a record another view of this document is showing.
        if ([_engine message:SCI_GETCHANGEHISTORY] != SC_CHANGE_HISTORY_DISABLED && !_hasSharedDocument) {
            [_engine message:SCI_SETCHANGEHISTORY wParam:option];
            [TTTrackedDocuments() removeObject:document];
        }
    } else {
        if (![_engine message:SCI_CANUNDO]) [TTTrackedDocuments() addObject:document];
        [_engine message:SCI_SETCHANGEHISTORY wParam:option];
    }
    [_engine message:SCI_SETMARGINWIDTHN wParam:TTChangeMargin lParam:shown ? TTChangeMarginWidth : 0];
    NSRulerView *ruler = _engine.scrollView.verticalRulerView;
    ruler.accessibilityLabel = shown ? @"Line numbers, bookmarks and change bars" : @"Line numbers and bookmarks";
    ruler.accessibilityHelp = shown
        ? @"A wide bar marks a line changed since the document was opened and not saved. A narrow bar marks a changed line that is saved. A hollow bar in the middle marks a line undone to its original text after a save."
        : nil;
}
- (BOOL)changeBarsVisible { [self assertThread]; return _changeBarsVisible; }
- (void)setChangeBarsVisible:(BOOL)visible {
    [self assertThread];
    if (_changeBarsVisible == visible) return;
    _changeBarsVisible = visible;
    [self applyChangeTracking];
    [self scheduleStateNotification];
}
- (BOOL)changeTrackingActive {
    [self assertThread];
    return ([_engine message:SCI_GETCHANGEHISTORY] & SC_CHANGE_HISTORY_ENABLED) != 0
        && [TTTrackedDocuments() containsObject:@([_engine message:SCI_GETDOCPOINTER])];
}
- (void)stopChangeTracking {
    [self assertThread];
    _changeBarsVisible = NO;
    [_engine message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_DISABLED];
    [TTTrackedDocuments() removeObject:@([_engine message:SCI_GETDOCPOINTER])];
    [self applyChangeTracking];
}
/// After this view's document was replaced or loaded again with an empty Undo history: the
/// record, if this view asks for one, starts from the text as it is now.
- (void)restartChangeTracking {
    const sptr_t option = [_engine message:SCI_GETCHANGEHISTORY];
    if (!(option & SC_CHANGE_HISTORY_ENABLED) || [_engine message:SCI_CANUNDO]) return;
    [_engine message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_DISABLED];
    [_engine message:SCI_SETCHANGEHISTORY wParam:option];
    [TTTrackedDocuments() addObject:@([_engine message:SCI_GETDOCPOINTER])];
}
- (NSInteger)centeredColumnCharacters { [self assertThread]; return _centeredColumnCharacters; }
- (void)setCenteredColumnCharacters:(NSInteger)characters {
    [self assertThread];
    characters = MAX(0, MIN(characters, 1000));
    if (characters == _centeredColumnCharacters) return;
    _centeredColumnCharacters = characters;
    [self updateCenteredColumn];
}
- (NSInteger)textMarginLeft { [self assertThread]; return [_engine message:SCI_GETMARGINLEFT]; }
- (NSInteger)textMarginRight { [self assertThread]; return [_engine message:SCI_GETMARGINRIGHT]; }
- (void)redrawGutter {
    _engine.scrollView.verticalRulerView.needsDisplay = YES;
    _emptyLineNumbers.needsDisplay = YES;
}
/// The engine's scroll view lays its text area out by taking the gutter's width off whatever
/// AppKit gave it. AppKit has sometimes already allowed for the gutter, and the text area is
/// then a gutter's width short at the right; at other times it has not allowed for a scroll bar
/// that is always shown, and the bar lies over the text. The text area is put where it belongs:
/// from the gutter to the pane's edge, or to the vertical scroll bar when that takes space.
- (void)normalizeTextArea {
    NSScrollView *scroll = _engine.scrollView;
    NSClipView *area = scroll.contentView;
    NSRulerView *gutter = scroll.verticalRulerView;
    if (!scroll || !area || !gutter || !scroll.rulersVisible) return;
    const CGFloat left = gutter.requiredThickness;
    CGFloat right = NSWidth(scroll.bounds);
    NSScroller *bar = scroll.verticalScroller;
    if (scroll.hasVerticalScroller && bar && !bar.hidden && scroll.scrollerStyle == NSScrollerStyleLegacy) right -= NSWidth(bar.frame);
    NSRect frame = area.frame;
    if (right <= left || (fabs(NSMinX(frame) - left) < 0.5 && fabs(NSMaxX(frame) - right) < 0.5)) return;
    frame.origin.x = left;
    frame.size.width = right - left;
    area.frame = frame;
}
- (NSInteger)textAreaWidth { [self assertThread]; return (NSInteger)floor(_engine.scrollView.contentView.bounds.size.width); }
- (NSInteger)textWidthOfColumns:(NSInteger)columns {
    [self assertThread];
    return [_engine message:SCI_TEXTWIDTH wParam:STYLE_DEFAULT lParam:(sptr_t)"0"] * MAX((NSInteger)0, columns);
}
/// Equal margins around a column of `_centeredColumnCharacters` zeros in the default style, which
/// Scintilla measures at the current zoom. With no room for both, the engine's own margins.
/// With Wrap Lines off only the left margin is applied: Scintilla's right margin narrows the
/// rectangle the caret is kept in without clipping what is drawn, so a long line would paint
/// through it while the view scrolled sideways at the column's edge with half the pane empty.
/// The text then starts at the column's left edge and runs to the pane's edge, and horizontal
/// scrolling is the ordinary layout's.
- (void)updateCenteredColumn {
    if (!_engine) return;
    sptr_t left = _plainMarginLeft, right = _plainMarginRight;
    if (_centeredColumnCharacters > 0 && !_comparisonPresentation) {
        const sptr_t available = self.textAreaWidth;
        const sptr_t column = [self textWidthOfColumns:_centeredColumnCharacters];
        const sptr_t spare = available - column;
        if (spare > left + right) {
            left = spare / 2;
            if ([_engine message:SCI_GETWRAPMODE] != SC_WRAP_NONE) right = spare - left;
        }
    }
    if ([_engine message:SCI_GETMARGINLEFT] != left) [_engine message:SCI_SETMARGINLEFT wParam:0 lParam:left];
    if ([_engine message:SCI_GETMARGINRIGHT] != right) [_engine message:SCI_SETMARGINRIGHT wParam:0 lParam:right];
    [self updateScrollRangePad];
}
/// The engine's horizontal range is the widest line it has drawn and takes no account of a left
/// margin, so with the column's margin the end of the widest line could be reached by the caret
/// and not by the scroller. With Wrap Lines off the range is kept that margin wider. The engine
/// replaces the range when it draws a line wider than it; the pad is put back after that paint.
- (void)updateScrollRangePad {
    if (!_engine) return;
    const BOOL unwrapped = [_engine message:SCI_GETWRAPMODE] == SC_WRAP_NONE && !_comparisonPresentation;
    const sptr_t pad = unwrapped ? MAX((sptr_t)0, [_engine message:SCI_GETMARGINLEFT] - _plainMarginLeft) : 0;
    const sptr_t current = [_engine message:SCI_GETSCROLLWIDTH];
    // A width other than the one set here is the engine's own.
    const sptr_t natural = (_paddedScrollWidth && current == _paddedScrollWidth) ? _naturalScrollWidth : current;
    _naturalScrollWidth = natural;
    _paddedScrollWidth = pad > 0 ? natural + pad : 0;
    if (current != natural + pad) [_engine message:SCI_SETSCROLLWIDTH wParam:(uptr_t)(natural + pad)];
}
- (void)dealloc {
    if (_accessibilityDisplayObserver) [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:_accessibilityDisplayObserver];
    if (_textAreaObserver) [NSNotificationCenter.defaultCenter removeObserver:_textAreaObserver];
    if (_ownGroups > 0) {
        NSNumber *key = @([_engine message:SCI_GETDOCPOINTER]);
        const NSInteger open = [[TTOpenGroups() objectForKey:key] integerValue] - _ownGroups;
        if (open > 0) [TTOpenGroups() setObject:@(open) forKey:key]; else [TTOpenGroups() removeObjectForKey:key];
    }
    if (_macroMouseMonitor) [NSEvent removeMonitor:_macroMouseMonitor];
    _engine.delegate = nil;
}
/// Every undo group of the bridge goes through this pair. `revision` still advances with each
/// modification step inside a group; only the change callback waits, for the outermost end or
/// the next turn of the main run loop, whichever comes first.
- (NSString *)exchangeNextUndoName:(NSString *)name {
    [self assertThread];
    NSString *previous = _nextUndoName;
    _nextUndoName = [name copy];
    return previous;
}
- (void)openUndoGroup {
    if (_nextUndoName) {
        if (!_pendingUndoName && ![self undoGroupOpen]) {
            _pendingUndoName = _nextUndoName;
            _namedStartRevision = self.revision;
        }
        _nextUndoName = nil;
    }
    NSNumber *key = @([_engine message:SCI_GETDOCPOINTER]);
    [TTOpenGroups() setObject:@([[TTOpenGroups() objectForKey:key] integerValue] + 1) forKey:key];
    _ownGroups += 1;
    [_engine message:SCI_BEGINUNDOACTION];
}
// Persist the name's small index as a Scintilla container action inside the real undo group.
static constexpr int TTNamedHistoryBase = 0x54540000;
- (void)closeUndoGroup {
    if (_ownGroups == 1 && _pendingUndoName) {
        NSString *name = _pendingUndoName;
        _pendingUndoName = nil;
        if (self.revision != _namedStartRevision && [_engine message:SCI_GETUNDOCOLLECTION]) {
            NSUInteger index = [_historyNames indexOfObject:name];
            if (index == NSNotFound) {
                index = _historyNames.count;
                [_historyNames addObject:name];
            }
            [_engine message:SCI_ADDUNDOACTION wParam:TTNamedHistoryBase + index lParam:0];
        }
    }
    [_engine message:SCI_ENDUNDOACTION];
    if (_ownGroups <= 0) return;
    _ownGroups -= 1;
    const sptr_t document = [_engine message:SCI_GETDOCPOINTER];
    NSNumber *key = @(document);
    const NSInteger open = [[TTOpenGroups() objectForKey:key] integerValue] - 1;
    if (open > 0) { [TTOpenGroups() setObject:@(open) forKey:key]; return; }
    [TTOpenGroups() removeObjectForKey:key];
    for (TTEditor *editor in TTDeferredEditors().allObjects) {
        if ([editor.engine message:SCI_GETDOCPOINTER] == document) [editor deliverDeferredChange];
    }
}
- (BOOL)undoGroupOpen { return [[TTOpenGroups() objectForKey:@([_engine message:SCI_GETDOCPOINTER])] integerValue] > 0; }
- (void)deliverDeferredChange {
    if (!_changeDeferred) return;
    _changeDeferred = NO;
    [TTDeferredEditors() removeObject:self];
    if (_onChange) _onChange();
}
- (void)deferChange {
    _changeDeferred = YES;
    [TTDeferredEditors() addObject:self];
    if (_deferredFlushScheduled) return;
    _deferredFlushScheduled = YES;
    // The callback is never lost or held for long: if neither the end of the outermost group nor
    // a last undo step delivers it first, the next turn of the main run loop does, whether or not
    // a group is still open. Synchronous grouped work never spans a turn, so it stays coalesced;
    // a group held open across turns (interactive macro playback, under a modal panel) reports
    // at most once per turn, which keeps the edited mark and recovery snapshots going.
    __weak TTEditor *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        TTEditor *editor = weakSelf; if (!editor) return;
        editor.deferredFlushScheduled = NO;
        [editor deliverDeferredChange];
    });
}
/// One change callback now, replacing any that was held back.
- (void)deliverChange {
    _changeDeferred = NO;
    [TTDeferredEditors() removeObject:self];
    if (_onChange) _onChange();
}
/// Posts TTEditorStateDidChangeNotification once per turn of the main run loop, never from
/// inside the Scintilla notification (which can arrive while the view is drawing).
- (void)scheduleStateNotification {
    if (_stateNotificationScheduled) return;
    _stateNotificationScheduled = YES;
    __weak TTEditor *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        TTEditor *editor = weakSelf; if (!editor) return;
        editor.stateNotificationScheduled = NO;
        [editor refreshBraceHighlight];
        [NSNotificationCenter.defaultCenter postNotificationName:TTEditorStateDidChangeNotification object:editor];
    });
}
/// The selection, or view state shown beside it, may have changed through the bridge. Scintilla
/// reports selection changes only when it next paints, which a hidden view never does.
- (void)noteStateChange { _selectionGeneration++; [self scheduleStateNotification]; }
/// Redraws the filler line numbers only when what they show can have changed: the line count,
/// the rows the document occupies (folding, wrapping), the scroll position, the row height (zoom,
/// font) or the margin width.
- (void)invalidateLineNumbersIfChanged {
    const sptr_t count = [_engine message:SCI_GETLINECOUNT];
    const TTLineNumberState state = {count, (sptr_t)[_engine message:SCI_VISIBLEFROMDOCLINE wParam:count], (sptr_t)[_engine message:SCI_GETFIRSTVISIBLELINE],
        (sptr_t)[_engine message:SCI_TEXTHEIGHT wParam:0], (sptr_t)[_engine message:SCI_GETMARGINWIDTHN wParam:0]};
    if (memcmp(&state, &_lineNumberState, sizeof(state)) == 0) return;
    _lineNumberState = state;
    _emptyLineNumbers.needsDisplay = YES;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return [self.window makeFirstResponder:self.engine.content]; }
- (void)assertThread { NSAssert(NSThread.isMainThread, @"Editor calls require the main thread"); }
- (NSString *)text {
    [self assertThread];
    const sptr_t length = [_engine message:SCI_GETLENGTH];
    if (length <= 0) return @"";
    // Decoded straight from Scintilla's buffer, by explicit length (documents hold NUL bytes).
    // The pointer is valid only until the next message, and none is sent before the copy is done.
    return TTStringFromUTF8((const void *)[_engine message:SCI_GETRANGEPOINTER wParam:0 lParam:length], (NSUInteger)length);
}
- (BOOL)hasLineLongerThan:(NSUInteger)limit {
    [self assertThread];
    const NSUInteger length = self.byteLength;
    if (length <= limit) return NO;
    const auto *bytes = reinterpret_cast<const uint8_t *>(
        [_engine message:SCI_GETRANGEPOINTER wParam:0 lParam:length]);
    NSUInteger lineLength = 0;
    for (NSUInteger index = 0; index < length; ++index) {
        const uint8_t byte = bytes[index];
        if (byte == '\r' || byte == '\n') lineLength = 0;
        else if (++lineLength > limit) return YES;
    }
    return NO;
}
- (NSInteger)lineCount { [self assertThread]; return [_engine message:SCI_GETLINECOUNT]; }
- (NSInteger)byteLength { [self assertThread]; return [_engine message:SCI_GETLENGTH]; }
- (NSData *)utf8Data { return self.checkedUTF8Data ?: [NSData data]; }
- (NSData * _Nullable)checkedUTF8Data {
    [self assertThread];
    const sptr_t length = [_engine message:SCI_GETLENGTH];
    if (length < 0) return nil;
    if (length == 0) return [NSData data];
    // One copy into a buffer the NSData owns. SCI_GETTEXTRANGEFULL does not move Scintilla's gap,
    // so a periodic capture never makes the next keystroke pay to move it back.
    char *buffer = (char *)malloc((size_t)length + 1);
    if (!buffer) return nil;
    Sci_TextRangeFull range = {{0, length}, buffer};
    if ([_engine message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&range] != length) {
        free(buffer);
        return nil;
    }
    return [NSData dataWithBytesNoCopy:buffer length:(NSUInteger)length freeWhenDone:YES];
}
- (void)setText:(NSString *)text {
    [self assertThread];
    // Unencodable text (an unpaired surrogate) leaves the document unchanged.
    NSData *data = TTUTF8(text); if (!data) return;
    [self openUndoGroup];
    [_engine message:SCI_SETTARGETRANGE wParam:0 lParam:[_engine message:SCI_GETLENGTH]];
    [_engine message:SCI_REPLACETARGET wParam:data.length lParam:(sptr_t)data.bytes];
    [self closeUndoGroup];
}
- (NSString *)selectedText {
    [self assertThread];
    const sptr_t count = [_engine message:SCI_GETSELECTIONS];
    if (count == 1) {
        const sptr_t start = [_engine message:SCI_GETSELECTIONNSTART wParam:0], end = [_engine message:SCI_GETSELECTIONNEND wParam:0];
        if (end <= start) return @"";
        return TTStringFromUTF8((const void *)[_engine message:SCI_GETRANGEPOINTER wParam:start lParam:end - start], (NSUInteger)(end - start));
    }
    NSMutableData *joined = [NSMutableData data];
    for (sptr_t selection = 0; selection < count; ++selection) {
        sptr_t start = [_engine message:SCI_GETSELECTIONNSTART wParam:selection];
        sptr_t end = [_engine message:SCI_GETSELECTIONNEND wParam:selection];
        if (selection) [joined appendBytes:"\n" length:1];
        // Copied before the next message can invalidate the pointer.
        if (end > start) [joined appendBytes:(const void *)[_engine message:SCI_GETRANGEPOINTER wParam:start lParam:end - start] length:(NSUInteger)(end - start)];
    }
    return TTStringFromUTF8(joined.bytes, joined.length);
}
- (BOOL)readOnly { [self assertThread]; return [_engine message:SCI_GETREADONLY] != 0; }
- (void)setReadOnly:(BOOL)value { [self assertThread]; [_engine message:SCI_SETREADONLY wParam:value]; [self scheduleStateNotification]; }
- (BOOL)requireWritable:(NSError **)error {
    [self assertThread];
    if (!self.readOnly) return YES;
    if (error) *error = [NSError errorWithDomain:TTEditorErrorDomain code:TTEditorErrorReadOnly userInfo:@{
        NSLocalizedDescriptionKey:@"This document is read-only. Nothing was changed.",
        NSLocalizedRecoverySuggestionErrorKey:@"Turn off Read Only in the File menu to edit this document."}];
    return NO;
}
- (BOOL)configureTabWidth:(NSInteger)width useTabs:(BOOL)useTabs {
    [self assertThread]; if (width < 1 || width > 32) return NO;
    [_engine message:SCI_SETTABWIDTH wParam:width]; [_engine message:SCI_SETUSETABS wParam:useTabs];
    [self scheduleStateNotification];
    return YES;
}
- (BOOL)convertLineEndings:(TTLineEndingMode)mode {
    [self assertThread];
    if (self.readOnly || (mode!=TTLineEndingModeLF && mode!=TTLineEndingModeCRLF && mode!=TTLineEndingModeCR)) return NO;
    [self openUndoGroup]; [_engine message:SCI_CONVERTEOLS wParam:mode];
    [_engine message:SCI_SETEOLMODE wParam:mode]; [self closeUndoGroup];
    return YES;
}
- (BOOL)setLineEndingMode:(TTLineEndingMode)mode {
    [self assertThread];
    if (mode!=TTLineEndingModeLF && mode!=TTLineEndingModeCRLF && mode!=TTLineEndingModeCR) return NO;
    // Mode only: existing bytes, undo history, revision and save point are untouched.
    [_engine message:SCI_SETEOLMODE wParam:mode];
    [self scheduleStateNotification];
    return YES;
}
- (NSArray<TTSelectionRange *> *)selectionRanges {
    [self assertThread]; NSMutableArray *ranges = [NSMutableArray array];
    for (sptr_t i=0; i<[_engine message:SCI_GETSELECTIONS]; ++i) {
        [ranges addObject:[[TTSelectionRange alloc] initWithAnchor:[_engine message:SCI_GETSELECTIONNANCHOR wParam:i] caret:[_engine message:SCI_GETSELECTIONNCARET wParam:i]]];
    }
    return ranges;
}
- (BOOL)validSelectionRanges:(NSArray *)ranges {
    if (![ranges isKindOfClass:NSArray.class] || ranges.count == 0 || ranges.count > 10000) return NO;
    const sptr_t length = [_engine message:SCI_GETLENGTH];
    NSMutableArray *intervals = [NSMutableArray array];
    for (id value in ranges) {
        if (![value isKindOfClass:TTSelectionRange.class]) return NO;
        TTSelectionRange *range=value;
        for (NSInteger p : {range.anchor, range.caret}) {
            if (p<0 || p>length) return NO;
            if (p<length && ([_engine message:SCI_GETCHARAT wParam:p] & 0xC0)==0x80) return NO;
        }
        [intervals addObject:@[@(MIN(range.anchor,range.caret)),@(MAX(range.anchor,range.caret))]];
    }
    [intervals sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    for (NSUInteger i=1;i<intervals.count;++i) {
        NSInteger previousEnd=[intervals[i-1][1] integerValue], start=[intervals[i][0] integerValue];
        if (start<previousEnd || (start==previousEnd && [intervals[i-1][0] integerValue]==start)) return NO;
    }
    return YES;
}
/// Stream selection with sticky extend mode off. SCI_SETSELECTIONMODE is not used for this: it
/// toggles extend mode (plain arrow keys then select) whenever the type is already stream.
- (void)useStreamSelection {
    [_engine message:SCI_CHANGESELECTIONMODE wParam:SC_SEL_STREAM];
    [_engine message:SCI_SETMOVEEXTENDSSELECTION wParam:0];
}
- (BOOL)setSelectionRanges:(NSArray<TTSelectionRange *> *)ranges {
    [self assertThread]; if (![self validSelectionRanges:ranges]) return NO;
    [self useStreamSelection];
    [_engine message:SCI_SETSELECTION wParam:ranges[0].caret lParam:ranges[0].anchor];
    for (NSUInteger i=1;i<ranges.count;++i) [_engine message:SCI_ADDSELECTION wParam:ranges[i].caret lParam:ranges[i].anchor];
    [_engine message:SCI_SETMAINSELECTION wParam:0]; [self noteStateChange]; return YES;
}
- (BOOL)replaceSelections:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision {
    [self assertThread]; NSArray<TTSelectionRange *> *ranges=self.selectionRanges;
    if (revision!=self.revision || self.readOnly || ![texts isKindOfClass:NSArray.class] || texts.count!=ranges.count || ![self validSelectionRanges:ranges]) return NO;
    // Encode everything before the first edit so an unencodable text rejects the whole batch.
    NSMutableArray<NSData *> *encoded=[NSMutableArray arrayWithCapacity:texts.count];
    for (id text in texts) {
        if (![text isKindOfClass:NSString.class]) return NO;
        NSData *bytes=TTUTF8(text); if (!bytes) return NO;
        [encoded addObject:bytes];
    }
    NSMutableArray *indices=[NSMutableArray array]; for (NSUInteger i=0;i<ranges.count;++i) [indices addObject:@(i)];
    [indices sortUsingComparator:^NSComparisonResult(NSNumber *a,NSNumber *b) {
        TTSelectionRange *ra=ranges[a.unsignedIntegerValue], *rb=ranges[b.unsignedIntegerValue];
        return [@(MIN(rb.anchor,rb.caret)) compare:@(MIN(ra.anchor,ra.caret))];
    }];
    [self openUndoGroup];
    for (NSNumber *index in indices) {
        TTSelectionRange *range=ranges[index.unsignedIntegerValue]; NSInteger a=range.anchor, c=range.caret;
        NSData *bytes=encoded[index.unsignedIntegerValue];
        [_engine message:SCI_SETTARGETRANGE wParam:MIN(a,c) lParam:MAX(a,c)];
        [_engine message:SCI_REPLACETARGET wParam:bytes.length lParam:(sptr_t)bytes.bytes];
    }
    [self closeUndoGroup]; return YES;
}
- (BOOL)applyEdits:(NSArray<TTTextEdit *> *)edits expectedRevision:(NSUInteger)revision expectedLength:(NSInteger)expectedLength {
    [self assertThread];
    const sptr_t length = [_engine message:SCI_GETLENGTH];
    if (revision != self.revision || self.readOnly || length != expectedLength || ![edits isKindOfClass:NSArray.class]) return NO;
    struct Edit { sptr_t start, end; NSData *bytes; };
    std::vector<Edit> validated; validated.reserve(edits.count);
    sptr_t previousEnd = 0;
    for (id candidate in edits) {
        if (![candidate isKindOfClass:TTTextEdit.class]) return NO;
        TTTextEdit *edit=candidate;
        NSRange range;
        if (!TTValidatedByteRange(edit.range,(NSUInteger)length,&range) || range.location<(NSUInteger)previousEnd) return NO;
        for (NSUInteger position : {range.location,NSMaxRange(range)})
            if (position<(NSUInteger)length && ([_engine message:SCI_GETCHARAT wParam:position]&0xC0)==0x80) return NO;
        if (![edit.text isKindOfClass:NSString.class]) return NO;
        NSData *bytes=TTUTF8(edit.text); if (!bytes) return NO;
        validated.push_back({(sptr_t)range.location,(sptr_t)NSMaxRange(range),bytes});
        previousEnd=(sptr_t)NSMaxRange(range);
    }
    // The revision is compared once, above: it advances with every replacement below.
    [self openUndoGroup];
    for (auto edit = validated.rbegin(); edit != validated.rend(); ++edit) {
        [_engine message:SCI_SETTARGETRANGE wParam:edit->start lParam:edit->end];
        [_engine message:SCI_REPLACETARGET wParam:edit->bytes.length lParam:(sptr_t)edit->bytes.bytes];
    }
    [self closeUndoGroup];
    return YES;
}
- (BOOL)replaceDocumentText:(NSString *)text {
    return [self replaceDocumentText:text expectedRevision:self.revision];
}
- (BOOL)replaceDocumentText:(NSString *)text expectedRevision:(NSUInteger)revision {
    [self assertThread];
    if (self.revision != revision) return NO;
    NSData *data = TTUTF8(text); if (!data || self.readOnly) return NO;
    return [self replaceDocumentWithEncodedUTF8:data];
}
- (BOOL)replaceDocumentWithEncodedUTF8:(NSData *)data {
    const sptr_t oldLength = [_engine message:SCI_GETLENGTH], newLength = (sptr_t)data.length;
    // Valid until the next modification; it is not read after the replacement.
    const unsigned char *before = (const unsigned char *)[_engine message:SCI_GETCHARACTERPOINTER];
    const unsigned char *after = (const unsigned char *)data.bytes;
    const sptr_t shorter = MIN(oldLength, newLength);
    sptr_t prefix = 0, suffix = 0;
    while (prefix < shorter && before[prefix] == after[prefix]) ++prefix;
    if (prefix == oldLength && prefix == newLength) return YES;
    while (suffix < shorter - prefix && before[oldLength - suffix - 1] == after[newLength - suffix - 1]) ++suffix;
    // Cut only on character boundaries of both texts, and never between CR and LF.
    auto continuation = [](const unsigned char *bytes, sptr_t length, sptr_t at) { return at < length && (bytes[at] & 0xC0) == 0x80; };
    while (prefix > 0 && (continuation(before, oldLength, prefix) || continuation(after, newLength, prefix))) --prefix;
    while (suffix > 0 && continuation(before, oldLength, oldLength - suffix)) --suffix;
    auto lineFeed = [](const unsigned char *bytes, sptr_t length, sptr_t at) { return at < length && bytes[at] == '\n'; };
    if (prefix > 0 && before[prefix - 1] == '\r' && (lineFeed(before, oldLength, prefix) || lineFeed(after, newLength, prefix))) --prefix;
    if (suffix > 0 && before[oldLength - suffix] == '\n' &&
        ((oldLength - suffix > 0 && before[oldLength - suffix - 1] == '\r') || (newLength - suffix > 0 && after[newLength - suffix - 1] == '\r'))) --suffix;
    const sptr_t start = prefix, oldEnd = oldLength - suffix, newEnd = newLength - suffix;

    NSArray<NSNumber *> *bookmarks = self.bookmarkLines;
    const sptr_t firstLine = [_engine message:SCI_LINEFROMPOSITION wParam:start];
    const sptr_t oldLastLine = [_engine message:SCI_LINEFROMPOSITION wParam:oldEnd];
    const BOOL lastLineKept = [_engine message:SCI_POSITIONFROMLINE wParam:oldLastLine] == oldEnd;
    const sptr_t topLine = [_engine message:SCI_GETFIRSTVISIBLELINE];
    // Each selection end either follows its text (outside the span) or has nothing to follow.
    BOOL selectionInside = NO;
    const sptr_t selections = [_engine message:SCI_GETSELECTIONS], mainSelection = [_engine message:SCI_GETMAINSELECTION];
    std::vector<sptr_t> expected; expected.reserve((size_t)selections * 2);
    for (sptr_t i = 0; i < selections; ++i) {
        for (sptr_t p : {(sptr_t)[_engine message:SCI_GETSELECTIONNANCHOR wParam:i], (sptr_t)[_engine message:SCI_GETSELECTIONNCARET wParam:i]}) {
            if (p > start && p < oldEnd) selectionInside = YES;
            expected.push_back(p <= start ? p : p + (newEnd - oldEnd));
        }
    }
    const sptr_t caret = [_engine message:SCI_GETCURRENTPOS];
    const sptr_t caretLine = [_engine message:SCI_LINEFROMPOSITION wParam:caret];
    const sptr_t caretOffset = caret - [_engine message:SCI_POSITIONFROMLINE wParam:caretLine];

    [self openUndoGroup];
    [_engine message:SCI_SETTARGETRANGE wParam:start lParam:oldEnd];
    [_engine message:SCI_REPLACETARGET wParam:newEnd - start lParam:(sptr_t)(after + start)];
    [self closeUndoGroup];

    const sptr_t newLastLine = [_engine message:SCI_LINEFROMPOSITION wParam:newEnd];
    if (bookmarks.count) {
        // Scintilla folds the markers of deleted lines onto the first line of the span. Put every
        // bookmark back explicitly: untouched lines keep theirs, lines after the span follow
        // their text, and lines inside it keep their line number, clamped to the new span.
        const sptr_t shift = newLastLine - oldLastLine;
        [_engine message:SCI_MARKERDELETEALL wParam:TTBookmarkMarker];
        for (NSNumber *bookmark in bookmarks) {
            sptr_t line = bookmark.integerValue;
            if (line > oldLastLine || (line == oldLastLine && lastLineKept)) line += shift;
            else if (line > firstLine) line = line == oldLastLine ? newLastLine : MIN(line, newLastLine);
            if (!([_engine message:SCI_MARKERGET wParam:line] & TTBookmarkMask)) [_engine message:SCI_MARKERADD wParam:line lParam:TTBookmarkMarker];
        }
    }
    if (selectionInside) {
        // A selection inside the replaced span has nothing to follow; keep the caret's line and column.
        const sptr_t line = MIN(caretLine, newLastLine);
        sptr_t position = MIN([_engine message:SCI_POSITIONFROMLINE wParam:line] + caretOffset, [_engine message:SCI_GETLINEENDPOSITION wParam:line]);
        while (position > 0 && ([_engine message:SCI_GETCHARAT wParam:position] & 0xC0) == 0x80) --position;
        [_engine message:SCI_SETEMPTYSELECTION wParam:position];
    } else {
        BOOL moved = [_engine message:SCI_GETSELECTIONS] != selections;
        for (sptr_t i = 0; i < selections && !moved; ++i) {
            moved = [_engine message:SCI_GETSELECTIONNANCHOR wParam:i] != expected[(size_t)i * 2] || [_engine message:SCI_GETSELECTIONNCARET wParam:i] != expected[(size_t)i * 2 + 1];
        }
        if (moved) {
            [self useStreamSelection];
            [_engine message:SCI_SETSELECTION wParam:expected[1] lParam:expected[0]];
            for (sptr_t i = 1; i < selections; ++i) [_engine message:SCI_ADDSELECTION wParam:expected[(size_t)i * 2 + 1] lParam:expected[(size_t)i * 2]];
            [_engine message:SCI_SETMAINSELECTION wParam:mainSelection];
        }
    }
    if ([_engine message:SCI_GETFIRSTVISIBLELINE] != topLine) [_engine message:SCI_SETFIRSTVISIBLELINE wParam:topLine];
    [self noteStateChange];
    return YES;
}
- (BOOL)loadDocumentText:(NSString *)text {
    [self assertThread];
    if (self.readOnly) return NO;
    NSData *data = TTUTF8(text); if (!data || self.readOnly) return NO;
    return [self loadEncodedDocumentData:data];
}
- (BOOL)loadDocumentUTF8:(TTDocumentUTF8 *)content {
    [self assertThread];
    return content && !self.readOnly && [self loadEncodedDocumentData:content.data];
}
- (BOOL)adoptInitialUTF8Load:(TTInitialUTF8Load *)load {
    [self assertThread];
    if (self.readOnly || _hasSharedDocument || [self undoGroupOpen] || self.revision || self.byteLength || [_engine message:SCI_CANUNDO] || [_engine message:SCI_CANREDO]) return NO;
    void *document = [load readyDocument];
    if (!document) return NO;
    const sptr_t width = [_engine message:SCI_GETTABWIDTH];
    const sptr_t tabs = [_engine message:SCI_GETUSETABS];
    [_engine message:SCI_SETDOCPOINTER wParam:0 lParam:reinterpret_cast<sptr_t>(document)];
    [load finishTransfer];
    [_engine message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
    [_engine message:SCI_SETTABWIDTH wParam:width];
    [_engine message:SCI_SETUSETABS wParam:tabs];
    [_engine message:SCI_SETUNDOCOLLECTION wParam:1];
    // The loader's document is new: it has no change record, and its pointer may be a reused one.
    [TTTrackedDocuments() removeObject:@([_engine message:SCI_GETDOCPOINTER])];
    [self applyChangeTracking];
    ++_revision;
    ++_selectionGeneration;
    _braceCacheValid = NO;
    [self updateLineNumberMargin:NO];
    [self deliverChange];
    [self scheduleStateNotification];
    return YES;
}
- (BOOL)loadEncodedDocumentData:(NSData *)data {
    // No undo record is kept of a load: Scintilla would otherwise hold a second copy of the
    // replaced and the inserted bytes only for the history to be emptied straight afterwards.
    [_engine message:SCI_SETUNDOCOLLECTION wParam:0];
    const BOOL loaded = [self replaceDocumentWithEncodedUTF8:data];
    [_engine message:SCI_SETUNDOCOLLECTION wParam:1];
    [_engine message:SCI_EMPTYUNDOBUFFER];
    [self restartChangeTracking];
    [_historyNames removeAllObjects];
    _cachedRedoCursor = -1;
    return loaded;
}
- (BOOL)moveCaretToLine:(NSInteger)line {
    [self assertThread];
    if (line < 1 || line > [_engine message:SCI_GETLINECOUNT]) return NO;
    [_engine message:SCI_ENSUREVISIBLE wParam:line - 1];
    // Scintilla reports SCI_GOTOLINE for macro recording before it runs. When the caret is already
    // there the jump moves nothing, so only the scroll is done and a recording is left alone (F277).
    const sptr_t target = [_engine message:SCI_POSITIONFROMLINE wParam:line - 1];
    if ([_engine message:SCI_GETSELECTIONS] == 1 && [_engine message:SCI_GETANCHOR] == target && [_engine message:SCI_GETCURRENTPOS] == target) [_engine message:SCI_SCROLLCARET];
    else [_engine message:SCI_GOTOLINE wParam:line - 1];
    [self noteStateChange];
    return YES;
}
- (void)showLine:(NSInteger)line column:(NSInteger)column {
    [self assertThread];
    if (line < 1 || column < 1) return;
    const sptr_t row = std::min<sptr_t>(line, [_engine message:SCI_GETLINECOUNT]) - 1;
    const sptr_t offset = [_engine message:SCI_FINDCOLUMN wParam:row lParam:std::min<sptr_t>(column - 1, INT_MAX)];
    [_engine message:SCI_ENSUREVISIBLE wParam:row];
    [self setSelectionAnchor:offset caret:offset];
    [self scrollCaretIntoView];
}
- (NSInteger)previewLine:(NSInteger)line column:(NSInteger)column {
    [self assertThread];
    if (line < 1 || line > [_engine message:SCI_GETLINECOUNT]) return 0;
    // No SCI_ENSUREVISIBLE here: a preview must leave folding as it found it. A hidden line is
    // stood in for by the visible header of the fold that hides it.
    sptr_t row = line - 1;
    while (row > 0 && ![_engine message:SCI_GETLINEVISIBLE wParam:row]) {
        const sptr_t parent = [_engine message:SCI_GETFOLDPARENT wParam:row];
        row = parent >= 0 && parent < row ? parent : row - 1;
    }
    const sptr_t target = row == line - 1 && column > 1
        ? [_engine message:SCI_FINDCOLUMN wParam:row lParam:std::min<sptr_t>(column - 1, INT_MAX)]
        : [_engine message:SCI_POSITIONFROMLINE wParam:row];
    [self useStreamSelection];
    [_engine message:SCI_SETSELECTION wParam:target lParam:target];
    [_engine message:SCI_SCROLLCARET];
    [self noteStateChange];
    return row + 1;
}
- (BOOL)lineIsVisible:(NSInteger)line {
    [self assertThread];
    return line >= 1 && line <= [_engine message:SCI_GETLINECOUNT] && [_engine message:SCI_GETLINEVISIBLE wParam:line - 1] != 0;
}
// Layout: length, mode, moveExtends, main, rectangular anchor/caret and their virtual space,
// then anchor, caret and their virtual space for each selection.
- (NSArray<NSNumber *> *)selectionSnapshot {
    [self assertThread];
    NSMutableArray<NSNumber *> *state = [NSMutableArray array];
    auto add = [&](sptr_t value) { [state addObject:@((long long)value)]; };
    add([_engine message:SCI_GETLENGTH]);
    add([_engine message:SCI_GETSELECTIONMODE]);
    add([_engine message:SCI_GETMOVEEXTENDSSELECTION]);
    add([_engine message:SCI_GETMAINSELECTION]);
    add([_engine message:SCI_GETRECTANGULARSELECTIONANCHOR]);
    add([_engine message:SCI_GETRECTANGULARSELECTIONCARET]);
    add([_engine message:SCI_GETRECTANGULARSELECTIONANCHORVIRTUALSPACE]);
    add([_engine message:SCI_GETRECTANGULARSELECTIONCARETVIRTUALSPACE]);
    const sptr_t count = [_engine message:SCI_GETSELECTIONS];
    for (sptr_t index = 0; index < count; ++index) {
        add([_engine message:SCI_GETSELECTIONNANCHOR wParam:index]);
        add([_engine message:SCI_GETSELECTIONNCARET wParam:index]);
        add([_engine message:SCI_GETSELECTIONNANCHORVIRTUALSPACE wParam:index]);
        add([_engine message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:index]);
    }
    return state;
}
- (BOOL)restoreSelectionSnapshot:(NSArray<NSNumber *> *)snapshot {
    [self assertThread];
    if (![snapshot isKindOfClass:NSArray.class] || snapshot.count < 12 || (snapshot.count - 8) % 4 != 0) return NO;
    for (id value in snapshot) if (![value isKindOfClass:NSNumber.class]) return NO;
    auto at = [&](NSUInteger index) { return (sptr_t)snapshot[index].longLongValue; };
    const sptr_t length = [_engine message:SCI_GETLENGTH];
    const NSUInteger count = (snapshot.count - 8) / 4;
    if (at(0) != length || at(3) < 0 || at(3) >= (sptr_t)count) return NO;
    for (NSUInteger index = 0; index < count; ++index) {
        for (NSUInteger field = 0; field < 2; ++field) {
            const sptr_t position = at(8 + index * 4 + field);
            if (position < 0 || position > length) return NO;
        }
    }
    const sptr_t mode = at(1);
    [_engine message:SCI_CHANGESELECTIONMODE wParam:mode];
    if (mode == SC_SEL_RECTANGLE || mode == SC_SEL_THIN) {
        // Scintilla derives the ranges of a rectangular selection from its two corners.
        [_engine message:SCI_SETRECTANGULARSELECTIONANCHOR wParam:at(4)];
        [_engine message:SCI_SETRECTANGULARSELECTIONANCHORVIRTUALSPACE wParam:at(6)];
        [_engine message:SCI_SETRECTANGULARSELECTIONCARET wParam:at(5)];
        [_engine message:SCI_SETRECTANGULARSELECTIONCARETVIRTUALSPACE wParam:at(7)];
    } else {
        for (NSUInteger index = 0; index < count; ++index) {
            const NSUInteger base = 8 + index * 4;
            [_engine message:index == 0 ? SCI_SETSELECTION : SCI_ADDSELECTION wParam:at(base + 1) lParam:at(base)];
            [_engine message:SCI_SETSELECTIONNANCHORVIRTUALSPACE wParam:index lParam:at(base + 2)];
            [_engine message:SCI_SETSELECTIONNCARETVIRTUALSPACE wParam:index lParam:at(base + 3)];
        }
        [_engine message:SCI_SETMAINSELECTION wParam:at(3)];
    }
    [_engine message:SCI_SETMOVEEXTENDSSELECTION wParam:at(2)];
    [self noteStateChange];
    return YES;
}
- (void)holdPlace {
    [self assertThread];
    _heldSelection = [self.selectionSnapshot mutableCopy];
    _heldTop = [_engine message:SCI_POSITIONFROMLINE wParam:self.firstVisibleDocumentLine];
    _heldDocument = [_engine message:SCI_GETDOCPOINTER];
    _heldDisplaced = NO;
}
- (void)releaseHeldPlace { [self assertThread]; _heldSelection = nil; }
/// The rule Scintilla applies to its own selections: text put in before a position moves it
/// along, text taken out before it moves it back, and a position inside removed text lands
/// where that text began. Only that last case loses the place.
- (void)moveHeldPlaceAt:(sptr_t)start length:(sptr_t)length inserted:(BOOL)inserted {
    if ([_engine message:SCI_GETDOCPOINTER] != _heldDocument) return;
    auto moved = [&](sptr_t position) -> sptr_t {
        if (position <= start) return position;
        if (inserted) return position + length;
        if (position >= start + length) return position - length;
        _heldDisplaced = YES;
        return start;
    };
    auto move = [&](NSUInteger index) { _heldSelection[index] = @((long long)moved((sptr_t)_heldSelection[index].longLongValue)); };
    move(4); move(5);
    for (NSUInteger index = 8; index + 1 < _heldSelection.count; index += 4) { move(index); move(index + 1); }
    _heldSelection[0] = @((long long)[_engine message:SCI_GETLENGTH]);
    _heldTop = moved(_heldTop);
}
- (NSArray<NSNumber *> *)heldSelectionSnapshot {
    [self assertThread];
    return _heldSelection && [_engine message:SCI_GETDOCPOINTER] == _heldDocument ? [_heldSelection copy] : nil;
}
- (NSInteger)heldTopDocumentLine {
    [self assertThread];
    if (!_heldSelection || [_engine message:SCI_GETDOCPOINTER] != _heldDocument) return -1;
    return [_engine message:SCI_LINEFROMPOSITION wParam:std::min<sptr_t>(_heldTop, [_engine message:SCI_GETLENGTH])];
}
- (BOOL)heldPlaceDisplaced { [self assertThread]; return _heldDisplaced; }
- (BOOL)textAreaContainsWindowPoint:(NSPoint)point {
    [self assertThread];
    NSView *content = _engine.content;
    return self.window && content && NSPointInRect([content convertPoint:point fromView:nil], content.visibleRect);
}
- (void)scrollCaretIntoView { [self assertThread]; [_engine message:SCI_SCROLLCARET]; }
- (NSInteger)firstVisibleLine { [self assertThread]; return [_engine message:SCI_GETFIRSTVISIBLELINE]; }
- (NSInteger)firstVisibleDocumentLine {
    [self assertThread]; return [_engine message:SCI_DOCLINEFROMVISIBLE wParam:self.firstVisibleLine];
}
- (NSInteger)firstVisibleSubline {
    [self assertThread];
    return MAX(0, self.firstVisibleLine - [_engine message:SCI_VISIBLEFROMDOCLINE wParam:self.firstVisibleDocumentLine]);
}
- (NSInteger)sessionTopDocumentLine {
    return _pendingWrappedViewport && _pendingWrappedViewport(NO) ? _pendingTopDocumentLine : self.firstVisibleDocumentLine;
}
- (NSInteger)sessionTopSubline {
    return _pendingWrappedViewport && _pendingWrappedViewport(NO) ? _pendingTopSubline : self.firstVisibleSubline;
}
// Use measured line heights only. SCI_SCROLLVERTICAL installs an independent
// deferred engine scroll that could override a newer caret at first paint.
- (void)scrollToMeasuredDocumentLine:(sptr_t)line subline:(sptr_t)subline {
    const sptr_t first = [_engine message:SCI_VISIBLEFROMDOCLINE wParam:line];
    const sptr_t next = [_engine message:SCI_VISIBLEFROMDOCLINE wParam:line + 1];
    const sptr_t withinLine = MIN(subline, MAX(0, next - first - 1));
    [_engine message:SCI_SETFIRSTVISIBLELINE wParam:first + withinLine];
}
- (void)scrollToDocumentLine:(NSInteger)line subline:(NSInteger)subline {
    [self assertThread];
    const sptr_t last = MAX(0, [_engine message:SCI_GETLINECOUNT] - 1);
    const sptr_t docLine = MAX(0, MIN(line, last));
    const sptr_t offset = MAX(0, MIN(subline, INT_MAX));
    _pendingWrappedViewport = nil;
    [self scrollToMeasuredDocumentLine:docLine subline:offset];
    // The first visible paint measures wrapped sublines at the restored width.
    // Reapply an unresolved anchor once, only while the same view state still
    // owns the request. There is no delayed timer or document-wide reflow.
    if (self.wrap && (self.firstVisibleDocumentLine != docLine || self.firstVisibleSubline != offset)) {
        const auto revision = self.revision;
        const auto identity = [_engine message:SCI_GETDOCPOINTER];
        const auto anchor = self.selectionAnchor, caret = self.selectionCaret;
        const auto beforeLine = self.firstVisibleDocumentLine, beforeSub = self.firstVisibleSubline;
        __weak TTEditor *weakSelf = self;
        _pendingTopDocumentLine = docLine;
        _pendingTopSubline = offset;
        _pendingWrappedViewport = ^BOOL(BOOL apply) {
            TTEditor *pane = weakSelf;
            if (!pane || [pane.engine message:SCI_GETDOCPOINTER] != identity || !pane.wrap ||
                pane.revision != revision || pane.selectionAnchor != anchor ||
                pane.selectionCaret != caret || pane.firstVisibleDocumentLine != beforeLine ||
                pane.firstVisibleSubline != beforeSub) return NO;
            if (apply) [pane scrollToMeasuredDocumentLine:docLine subline:offset];
            return YES;
        };
    }
}
- (NSInteger)characterByteAtWindowPoint:(NSPoint)point inTextView:(NSView *)view {
    [self assertThread];
    if (!self.window || view != _engine.content) return NSNotFound;
    const NSPoint local = [_engine.scrollView convertPoint:point fromView:nil];
    if (!NSPointInRect(local, _engine.scrollView.bounds)) return NSNotFound;
    const sptr_t byte = [_engine message:SCI_CHARPOSITIONFROMPOINTCLOSE
                                  wParam:(uptr_t)local.x lParam:(sptr_t)local.y];
    if (byte < 0 || byte >= [_engine message:SCI_GETLENGTH]) return NSNotFound;
    const sptr_t ch = [_engine message:SCI_GETCHARAT wParam:byte];
    return ch == '\r' || ch == '\n' ? NSNotFound : byte;
}
- (void)completeFrameClickWithDown:(NSEvent *)down up:(NSEvent *)up inTextView:(NSView *)view {
    [self assertThread];
    if (view == _engine.content && [view isKindOfClass:TTContentView.class] &&
        self.window && down.window == self.window && up.window == self.window) {
        [(TTContentView *)view completeFrameDown:down up:up];
    }
}
- (NSInteger)horizontalScrollOffset { [self assertThread]; return [_engine message:SCI_GETXOFFSET]; }
- (void)setHorizontalScrollOffset:(NSInteger)offset {
    [self assertThread];
    if (self.wrap || offset <= 0) { [_engine message:SCI_SETXOFFSET wParam:0]; return; }
    // The range tracks lines as they are painted, and a restored offset can arrive before the
    // first paint. Measure the lines on screen so the range already covers them; the engine
    // then limits the offset to what those lines can scroll.
    sptr_t widest = [_engine message:SCI_GETSCROLLWIDTH];
    if (!_comparisonPresentation && offset > widest - (sptr_t)_engine.scrollView.contentView.bounds.size.width) {
        const sptr_t count = [_engine message:SCI_GETLINECOUNT];
        const sptr_t top = [_engine message:SCI_DOCLINEFROMVISIBLE wParam:[_engine message:SCI_GETFIRSTVISIBLELINE]];
        const sptr_t last = MIN(count - 1, top + [_engine message:SCI_LINESONSCREEN]);
        for (sptr_t line = top; line <= last; ++line) {
            if (![_engine message:SCI_GETLINEVISIBLE wParam:line]) continue;
            const sptr_t start = [_engine message:SCI_POSITIONFROMLINE wParam:line];
            const sptr_t end = [_engine message:SCI_GETLINEENDPOSITION wParam:line];
            widest = MAX(widest, [_engine message:SCI_POINTXFROMPOSITION wParam:0 lParam:end] - [_engine message:SCI_POINTXFROMPOSITION wParam:0 lParam:start]);
        }
        if (widest > [_engine message:SCI_GETSCROLLWIDTH]) [_engine message:SCI_SETSCROLLWIDTH wParam:(uptr_t)widest];
    }
    [_engine message:SCI_SETXOFFSET wParam:(uptr_t)MIN(offset, (NSInteger)INT_MAX)];
}
- (void)restoreClosedTabViewWithAnchor:(NSInteger)anchor caret:(NSInteger)caret firstVisibleLine:(NSInteger)line {
    [self assertThread];
    _pendingWrappedViewport = nil;
    const NSInteger length=[_engine message:SCI_GETLENGTH];
    auto boundary=[&](NSInteger value) {
        value=MAX(0,MIN(length,value));
        while(value>0 && value<length && ([_engine message:SCI_GETCHARAT wParam:(uptr_t)value] & 0xc0)==0x80) --value;
        return value;
    };
    [_engine message:SCI_SETSEL wParam:(uptr_t)boundary(anchor) lParam:(sptr_t)boundary(caret)];
    // Scintilla clamps to its actual display-row extent, including sublines of
    // the final physical line. Querying every line's wrap count is unnecessary.
    [_engine message:SCI_SETFIRSTVISIBLELINE wParam:(uptr_t)MAX(0, MIN(line, INT_MAX))];
    [self noteStateChange];
}
- (BOOL)replaceRanges:(NSArray<TTByteRange *> *)ranges withTexts:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision {
    return [self replaceRanges:ranges withTexts:texts expectedRevision:revision search:nil];
}
- (BOOL)replaceSearchRanges:(NSArray<TTByteRange *> *)ranges withTexts:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision {
    return [self replaceRanges:ranges withTexts:texts expectedRevision:revision search:TTWatchMacroMessages ? [NSObject new] : nil];
}
- (BOOL)replaceRanges:(NSArray<TTByteRange *> *)ranges withTexts:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision search:(NSObject *)search {
    [self assertThread];
    if (revision!=self.revision || self.readOnly || ![ranges isKindOfClass:NSArray.class] || ![texts isKindOfClass:NSArray.class] || ranges.count==0 || texts.count!=ranges.count) return NO;
    const NSUInteger length=(NSUInteger)[_engine message:SCI_GETLENGTH]; NSUInteger previousEnd=0;
    for (id value in ranges) {
        NSRange range;
        if (!TTValidatedByteRange(value,length,&range) || range.location<previousEnd) return NO;
        for (NSUInteger position : {range.location, NSMaxRange(range)}) {
            if (position<length && ([_engine message:SCI_GETCHARAT wParam:position] & 0xC0)==0x80) return NO;
        }
        previousEnd=NSMaxRange(range);
    }
    // Encode everything before the first edit so an unencodable text rejects the whole batch.
    NSMutableArray<NSData *> *encoded=[NSMutableArray arrayWithCapacity:texts.count];
    for (id text in texts) {
        if (![text isKindOfClass:NSString.class]) return NO;
        NSData *bytes=TTUTF8(text); if (!bytes) return NO;
        [encoded addObject:bytes];
    }
    // Last range first, so the offsets of the ranges still to be replaced stay valid.
    [self openUndoGroup];
    for (NSUInteger i=ranges.count;i-->0;) {
        const NSRange range=NSMakeRange((NSUInteger)ranges[i].location,(NSUInteger)ranges[i].length);
        [_engine message:SCI_SETTARGETRANGE wParam:range.location lParam:NSMaxRange(range)];
        [(TTScintillaView *)_engine dispatchMessage:SCI_REPLACETARGET wParam:encoded[i].length lParam:(sptr_t)encoded[i].bytes search:search];
    }
    const sptr_t caret=(sptr_t)((NSUInteger)ranges[0].location+encoded[0].length);
    [_engine message:SCI_SETSEL wParam:caret lParam:caret];
    [_engine message:SCI_SCROLLCARET];
    [self closeUndoGroup];
    return YES;
}
- (NSInteger)selectionCount { [self assertThread]; return [_engine message:SCI_GETSELECTIONS]; }
- (NSInteger)selectionStart { [self assertThread]; return [_engine message:SCI_GETSELECTIONSTART]; }
- (NSInteger)selectionEnd { [self assertThread]; return [_engine message:SCI_GETSELECTIONEND]; }
- (NSInteger)selectionAnchor { [self assertThread]; return [_engine message:SCI_GETANCHOR]; }
- (NSInteger)selectedCharacterCount {
    [self assertThread];
    NSInteger total=0, count=[_engine message:SCI_GETSELECTIONS];
    for (NSInteger i=0;i<count;++i) {
        NSInteger start=[_engine message:SCI_GETSELECTIONNSTART wParam:i];
        NSInteger end=[_engine message:SCI_GETSELECTIONNEND wParam:i];
        total += [_engine message:SCI_COUNTCHARACTERS wParam:start lParam:end];
    }
    return total;
}
- (TTEditorStatus *)statusInfo {
    [self assertThread];
    NSInteger caret = [_engine message:SCI_GETCURRENTPOS];
    return [[TTEditorStatus alloc] initWithLine:[_engine message:SCI_LINEFROMPOSITION wParam:caret]+1
        column:[_engine message:SCI_GETCOLUMN wParam:caret]+1+[_engine message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:[_engine message:SCI_GETMAINSELECTION]]
        lines:[_engine message:SCI_GETLINECOUNT] tabWidth:[_engine message:SCI_GETTABWIDTH]
        useTabs:[_engine message:SCI_GETUSETABS] fontSize:MAX(1, [_engine message:SCI_STYLEGETSIZEFRACTIONAL wParam:STYLE_DEFAULT]/100.0+[_engine message:SCI_GETZOOM])
        eol:[_engine message:SCI_GETEOLMODE]];
}

// Move through long runs that cannot contain an interior word boundary without
// passing the whole run to TextKit. Leave one character of context at either end.
static sptr_t TTSkipWordRun(ScintillaView *engine, sptr_t cursor, sptr_t size, bool forward) {
    const auto category = [](char c) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) return 1;
        if (c >= '0' && c <= '9') return 3;
        if (c == ' ' || c == '\t') return 2;
        return 0;
    };
    const sptr_t original = cursor;
    int run = 0;
    char bytes[4097];
    while (forward ? cursor < size : cursor > 0) {
        const sptr_t length = std::min<sptr_t>(sizeof(bytes)-1, forward ? size-cursor : cursor);
        const sptr_t start = forward ? cursor : cursor-length;
        Sci_TextRangeFull range = {{start, start+length}, bytes};
        if ([engine message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&range] != length) break;
        if (!run) run = category(bytes[forward ? 0 : length-1]);
        if (!run) break;
        sptr_t n = 0;
        while (n < length && category(bytes[forward ? n : length-1-n]) == run) ++n;
        cursor += forward ? n : -n;
        if (n != length) break;
    }
    return original == cursor ? cursor : cursor + (forward ? -1 : 1);
}

// UAX #9 P2/P3. A clipped fragment may start in an embedded run whose
// direction differs from its paragraph. Resolve the first strong character
// outside directional isolates without materializing a long line.
static bool TTWordParagraphRTL(ScintillaView *engine, sptr_t start, sptr_t end) {
    static NSRegularExpression *strongOrIsolate;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        strongOrIsolate = [NSRegularExpression regularExpressionWithPattern:
            @"([\\p{bc=R}\\p{bc=AL}])|[\\p{bc=L}\\u2066-\\u2069]" options:0 error:nil];
    });
    __block NSInteger isolates = 0;
    while (start < end) { @autoreleasepool {
        sptr_t next = std::min<sptr_t>(start+4096, end);
        while (next < end && ([engine message:SCI_GETCHARAT wParam:next] & 0xc0) == 0x80) --next;
        char bytes[4097];
        Sci_TextRangeFull slice = {{start, next}, bytes};
        if ([engine message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&slice] != next-start) break;
        NSString *text = TTStringFromUTF8(bytes, next-start);
        __block BOOL rtl = NO, found = NO;
        [strongOrIsolate enumerateMatchesInString:text options:0 range:NSMakeRange(0,text.length)
            usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
                const unichar c = [text characterAtIndex:match.range.location];
                if (c >= 0x2066 && c <= 0x2068) ++isolates;
                else if (c == 0x2069) isolates = MAX(0, isolates-1);
                else if (!isolates) {
                    rtl = [match rangeAtIndex:1].location != NSNotFound;
                    found = YES; *stop = YES;
                }
            }];
        if (found) return rtl;
        start = next;
    } }
    return false;
}

// AppKit word selection ignores intervening punctuation and uses the system's
// Unicode word segmentation and writing direction. Only the local text used for
// that decision is copied. Scintilla continues to own the anchor, bytes and Undo.
static sptr_t TTMacWordDestination(ScintillaView *engine, sptr_t caret, bool right) {
    const sptr_t size = [engine message:SCI_GETLENGTH];
    if (!size) return caret;
    NSTextContentStorage *storage = [NSTextContentStorage new];
    NSTextLayoutManager *layout = [NSTextLayoutManager new];
    [storage addTextLayoutManager:layout];
    layout.textContainer = [[NSTextContainer alloc] initWithSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
    auto direction = right ? NSTextSelectionNavigationDirectionRight : NSTextSelectionNavigationDirectionLeft;
    sptr_t cursor = caret;
    constexpr sptr_t radius = 1024;
    while (true) { @autoreleasepool {
        sptr_t start = std::max<sptr_t>(0, cursor-radius);
        sptr_t end = std::min<sptr_t>(size, cursor+radius);
        while (start && ([engine message:SCI_GETCHARAT wParam:start] & 0xc0) == 0x80) --start;
        while (end < size && ([engine message:SCI_GETCHARAT wParam:end] & 0xc0) == 0x80) ++end;
        NSMutableParagraphStyle *paragraph = nil;
        if (cursor == caret && start > 0) {
            const sptr_t line = [engine message:SCI_LINEFROMPOSITION wParam:caret];
            const sptr_t lineStart = [engine message:SCI_POSITIONFROMLINE wParam:line];
            if (lineStart < start) {
                const bool rtl = TTWordParagraphRTL(engine, lineStart, [engine message:SCI_GETLINEENDPOSITION wParam:line]);
                paragraph = [[NSMutableParagraphStyle alloc] init];
                paragraph.baseWritingDirection = rtl ? NSWritingDirectionRightToLeft : NSWritingDirectionLeftToRight;
            }
        }
        char bytes[2*radius+7];
        Sci_TextRangeFull slice = {{start, end}, bytes};
        if ([engine message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&slice] != end-start) return caret;
        NSString *text = TTStringFromUTF8(bytes, end-start);
        if (paragraph) {
            NSMutableAttributedString *fragment = [[NSMutableAttributedString alloc] initWithString:text];
            [fragment addAttribute:NSParagraphStyleAttributeName value:paragraph
                range:[text paragraphRangeForRange:NSMakeRange(0, 0)]];
            storage.attributedString = fragment;
        } else {
            storage.attributedString = [[NSAttributedString alloc] initWithString:text];
        }
        id<NSTextLocation> first = storage.documentRange.location;
        const NSInteger offset = [engine message:SCI_COUNTCODEUNITS wParam:start lParam:cursor];
        id<NSTextLocation> here = [storage locationFromLocation:first withOffset:offset];
        if (!here) return caret;
        NSTextSelection *selection = [[NSTextSelection alloc] initWithLocation:here affinity:NSTextSelectionAffinityDownstream];
        NSTextSelection *next = [layout.textSelectionNavigation destinationSelectionForTextSelection:selection
            direction:direction destination:NSTextSelectionNavigationDestinationWord extending:YES confined:NO];
        NSTextRange *extended = next.textRanges.firstObject;
        id<NSTextLocation> result = [extended.location compare:here] == NSOrderedSame ? extended.endLocation : extended.location;
        if (!result) return cursor;
        const NSInteger nextOffset = [storage offsetFromLocation:first toLocation:result];
        const sptr_t target = [engine message:SCI_POSITIONRELATIVECODEUNITS wParam:start lParam:nextOffset];
        if (target < start || target > end) return caret;
        const bool forward = target > cursor;
        if (target == cursor || (forward ? end == size || target < end-32 : start == 0 || target > start+32))
            return target;
        // A clipped word or separator may continue outside this neighborhood.
        // Reconsider its last portion with more context, in the resolved direction.
        sptr_t inside = forward ? end-64 : start+64;
        while (([engine message:SCI_GETCHARAT wParam:inside] & 0xc0) == 0x80) --inside;
        cursor = TTSkipWordRun(engine, inside, size, forward);
        direction = forward ? NSTextSelectionNavigationDirectionForward : NSTextSelectionNavigationDirectionBackward;
    } }
}

- (BOOL)extendMacWordSelectionRight:(BOOL)right {
    if ([_engine message:SCI_GETSELECTIONMODE] != SC_SEL_STREAM || self.selectionCount != 1 ||
        [_engine message:SCI_AUTOCACTIVE]) return NO;
    const NSInteger caret = self.selectionCaret;
    const NSInteger next = TTMacWordDestination(_engine, caret, right);
    if (next != caret && [self setSelectionAnchor:self.selectionAnchor caret:next] && _macroRecording) {
        [self reportMacroStep:[TTMacroAction unsupported:@"Mac word selection" message:0]];
    }
    return YES;
}

- (NSInteger)selectionCaret { [self assertThread]; return [_engine message:SCI_GETCURRENTPOS]; }
- (BOOL)setSelectionAnchor:(NSInteger)anchor caret:(NSInteger)caret {
    [self assertThread];
    const sptr_t length = [_engine message:SCI_GETLENGTH];
    for (NSInteger position : {anchor, caret}) {
        if (position < 0 || position > length) return NO;
        if (position < length && ([_engine message:SCI_GETCHARAT wParam:position] & 0xC0) == 0x80) return NO;
    }
    [_engine message:SCI_SETSEL wParam:anchor lParam:caret];
    [_engine message:SCI_SCROLLCARET];
    [self noteStateChange];
    return YES;
}
- (NSArray<NSNumber *> *)bookmarkLines {
    [self assertThread];
    NSMutableArray<NSNumber *> *lines = [NSMutableArray array];
    sptr_t line = [_engine message:SCI_MARKERNEXT wParam:0 lParam:TTBookmarkMask];
    while (line >= 0) {
        [lines addObject:@(line)];
        line = [_engine message:SCI_MARKERNEXT wParam:line+1 lParam:TTBookmarkMask];
    }
    return lines;
}
- (NSInteger)bookmarkCount {
    [self assertThread];
    NSInteger count = 0;
    for (sptr_t line = [_engine message:SCI_MARKERNEXT wParam:0 lParam:TTBookmarkMask]; line >= 0; line = [_engine message:SCI_MARKERNEXT wParam:line+1 lParam:TTBookmarkMask]) ++count;
    return count;
}
- (BOOL)setBookmarks:(NSArray<NSNumber *> *)lines {
    [self assertThread];
    if (![lines isKindOfClass:NSArray.class]) return NO;
    const sptr_t count = [_engine message:SCI_GETLINECOUNT];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (id value in lines) {
        if (![value isKindOfClass:NSNumber.class]) return NO;
        NSInteger line = [value integerValue];
        if (line < 0 || line >= count || [value doubleValue] != (double)line || [seen containsObject:@(line)]) return NO;
        [seen addObject:@(line)];
    }
    [_engine message:SCI_MARKERDELETEALL wParam:TTBookmarkMarker];
    for (NSNumber *line in seen) [_engine message:SCI_MARKERADD wParam:line.integerValue lParam:TTBookmarkMarker];
    [self scheduleStateNotification];
    return YES;
}
- (BOOL)modified { [self assertThread]; return [_engine message:SCI_GETMODIFY] != 0; }
- (void)setSavePoint { [self assertThread]; [_engine message:SCI_SETSAVEPOINT]; }
- (void)resetUndoHistory {
    [self assertThread];
    [_engine message:SCI_EMPTYUNDOBUFFER];
    [_historyNames removeAllObjects];
    _cachedRedoCursor = -1;
}
- (NSString *)accessibilityDocumentName { return _engine.content.accessibilityLabel; }
- (void)setAccessibilityDocumentName:(NSString *)name {
    [self assertThread];
    _engine.content.accessibilityLabel = name.length ? name : @"Document";
    _engine.content.accessibilityRoleDescription = @"text editor";
}
- (BOOL)wrap { [self assertThread]; return [_engine message:SCI_GETWRAPMODE] != SC_WRAP_NONE; }
- (void)setWrap:(BOOL)wrap {
    [self assertThread]; _pendingWrappedViewport = nil; [_engine message:SCI_SETWRAPMODE wParam:wrap ? SC_WRAP_WORD : SC_WRAP_NONE];
    // The centred column has a right margin only while lines wrap at it.
    [self updateCenteredColumn];
    // Rows are re-wrapped lazily, so the row count compared by -invalidateLineNumbersIfChanged may not have moved yet.
    _emptyLineNumbers.needsDisplay = YES;
    [self scheduleStateNotification];
}
- (void)shareDocumentWith:(TTEditor *)other {
    [self assertThread];
    // SCI_SETDOCPOINTER acquires the new document before releasing the old one.
    // Each attached Scintilla view owns a reference, so either view may close first.
    _hasSharedDocument = YES;
    other->_hasSharedDocument = YES;
    [_engine message:SCI_SETDOCPOINTER wParam:0 lParam:[other.engine message:SCI_GETDOCPOINTER]];
    self.revision = other.revision;
    _historyNames = other->_historyNames;
    _cachedRedoCursor = -1;
    _braceCacheValid = NO;
    [self noteStateChange];
    // The line count changed with no modification notification.
    [self updateLineNumberMargin:NO];
    [self applyChangeTracking];
}
- (BOOL)sharesDocumentWith:(TTEditor *)other {
    [self assertThread];
    return other != nil && [_engine message:SCI_GETDOCPOINTER] == [other.engine message:SCI_GETDOCPOINTER];
}
- (void)adoptSyntaxStylesFrom:(TTEditor *)other {
    [self assertThread]; if (!other || other == self) return;
    // The stored NSColor objects are copied as they are: dynamic colours must keep resolving
    // against this view's own appearance in applyPalette. applyPalette starts from
    // SCI_STYLECLEARALL, so a style the other view no longer defines is dropped here too.
    _syntaxStyles = [[NSMutableDictionary alloc] initWithDictionary:other.syntaxStyles copyItems:YES];
    _syntaxFonts = [[NSMutableDictionary alloc] initWithDictionary:other.syntaxFonts copyItems:YES];
    // Whether the bare cpp palette applies follows the document's lexer, which was installed
    // through the other view; a stale flag here would paint cpp colours under another language.
    _cppDefaults = other.cppDefaults;
    [self applyPalette];
}
- (void)adoptViewStateFrom:(TTEditor *)other {
    [self assertThread]; if (!other || other == self) return;
    _baseFontName = other.baseFontName;
    _basePointSize = other.basePointSize;
    [self adoptSyntaxStylesFrom:other];
    self.autoIndentEnabled = other.autoIndentEnabled;
    self.autoPairEnabled = other.autoPairEnabled;
    self.braceHighlightEnabled = other.braceHighlightEnabled;
    self.currentLineHighlightEnabled = other.currentLineHighlightEnabled;
    self.indentGuidesEnabled = other.indentGuidesEnabled;
    _defaultZoomLevel = other->_defaultZoomLevel;
    [_engine message:SCI_SETZOOM wParam:(uptr_t)[other.engine message:SCI_GETZOOM]];
    _followsDefaultZoom = other->_followsDefaultZoom;
    [_engine message:SCI_SETWRAPMODE wParam:(uptr_t)[other.engine message:SCI_GETWRAPMODE]];
    [_engine message:SCI_SETVIEWWS wParam:(uptr_t)[other.engine message:SCI_GETVIEWWS]];
    [_engine message:SCI_SETVIEWEOL wParam:(uptr_t)[other.engine message:SCI_GETVIEWEOL]];
    for (int margin = 0; margin < 3; ++margin) [_engine message:SCI_SETMARGINWIDTHN wParam:margin lParam:[other.engine message:SCI_GETMARGINWIDTHN wParam:margin]];
    // A view that hid its bars keeps the record going; so does its copy.
    _changeBarsVisible = other->_changeBarsVisible;
    if (!_comparisonPresentation && ([other.engine message:SCI_GETCHANGEHISTORY] & SC_CHANGE_HISTORY_ENABLED) && [self sharesDocumentWith:other])
        [_engine message:SCI_SETCHANGEHISTORY wParam:SC_CHANGE_HISTORY_ENABLED];
    [self applyChangeTracking];
    self.centeredColumnCharacters = other.centeredColumnCharacters;
    // The wrap mode was copied above without the setter.
    [self updateCenteredColumn];
}
- (void)retireInFavorOf:(TTEditor *)successor {
    [self assertThread];
    if (!successor || successor == self || ![self sharesDocumentWith:successor]) return;
    [NSNotificationCenter.defaultCenter postNotificationName:TTEditorWillRetireNotification object:self userInfo:@{TTEditorSuccessorKey: successor}];
}
- (BOOL)replaceSelection:(NSString *)text {
    [self assertThread];
    NSData *data = TTUTF8(text); if (data == nil || self.readOnly) return NO;
    return [self replaceSelectionWithEncodedBytes:data];
}
- (BOOL)replaceSelectionWithEncodedBytes:(NSData *)data {
    [self openUndoGroup];
    [_engine message:SCI_TARGETFROMSELECTION];
    const sptr_t start = [_engine message:SCI_GETTARGETSTART];
    [_engine message:SCI_REPLACETARGET wParam:data.length lParam:(sptr_t)data.bytes];
    [_engine message:SCI_SETSEL wParam:start + data.length lParam:start + data.length];
    [self closeUndoGroup];
    return YES;
}
+ (BOOL)commandModifiesText:(TTEditorCommandIdentifier)identifier {
    if (![identifier isKindOfClass:NSString.class]) return NO;
    static NSSet<NSString *> *editing; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *identifiers = [NSMutableSet set];
        for (const auto &entry : TTCommandEntries)
            if (entry.modifiesText) [identifiers addObject:[NSString stringWithUTF8String:entry.identifier]];
        editing = [identifiers copy];
    });
    return [editing containsObject:identifier];
}
- (BOOL)commandIsChecked:(TTEditorCommandIdentifier)identifier {
    [self assertThread];
    if (![identifier isKindOfClass:NSString.class]) return NO;
    if ([identifier isEqualToString:@"showWhitespace"]) return self.whitespaceVisible;
    if ([identifier isEqualToString:@"toggleEOL"]) return self.lineEndingsVisible;
    if ([identifier isEqualToString:@"toggleLineNumbers"]) return self.lineNumbersVisible;
    if ([identifier isEqualToString:@"toggleOvertype"]) return [_engine message:SCI_GETOVERTYPE] != 0;
    if ([identifier isEqualToString:@"rectangularSelection"]) return [_engine message:SCI_GETSELECTIONMODE] == SC_SEL_RECTANGLE;
    if ([identifier isEqualToString:@"streamSelection"]) return [_engine message:SCI_GETSELECTIONMODE] == SC_SEL_STREAM;
    if ([identifier isEqualToString:@"bookmarkToggle"]) {
        const sptr_t line = [_engine message:SCI_LINEFROMPOSITION wParam:[_engine message:SCI_GETCURRENTPOS]];
        return ([_engine message:SCI_MARKERGET wParam:line] & TTBookmarkMask) != 0;
    }
    return NO;
}
- (BOOL)executeCommand:(TTEditorCommandIdentifier)identifier {
    [self assertThread];
    return [self executeCommand:identifier usingPasteboard:nil];
}
- (BOOL)executeCommand:(TTEditorCommandIdentifier)identifier usingPasteboard:(NSPasteboard *)pasteboard {
    [self assertThread];
    if (![self runCommand:identifier usingPasteboard:pasteboard]) return NO;
    // Folding, the margin toggle and selection commands raise no synchronous notification.
    [self invalidateLineNumbersIfChanged];
    [self noteStateChange];
    return YES;
}
// The pinned Scintilla matcher ignores maxReStyle and may scan to EOF. For a live cue,
// call it only if the boundary is close or a partner is proved within this byte budget.
// Native text is UTF-8; ASCII delimiters never occur inside a multibyte character.
- (BOOL)canResolveLiveBraceAt:(sptr_t)position brace:(char)brace opposite:(char)opposite forward:(BOOL)forward {
    constexpr sptr_t budget = 4096;
    const sptr_t available = forward ? [_engine message:SCI_GETLENGTH] - position - 1 : position;
    if (available <= budget) return YES;
    const sptr_t start = forward ? position + 1 : position - budget;
    const sptr_t end = start + budget;
    // GETSTYLEDTEXTFULL returns interleaved bytes and unsigned style indices plus two NULs.
    // Match Document::BraceMatch's exact style rule, including its strict endStyled boundary.
    char cells[2 * budget + 2];
    Sci_TextRangeFull range = {{start,end},cells};
    if ([_engine message:SCI_GETSTYLEDTEXTFULL wParam:0 lParam:(sptr_t)&range] != 2 * budget) return NO;
    const sptr_t style = [_engine message:SCI_GETSTYLEINDEXAT wParam:position];
    const sptr_t endStyled = [_engine message:SCI_GETENDSTYLED];
    int depth = 1;
    for (sptr_t i = 0; i < budget; ++i) {
        const sptr_t offset = forward ? i : budget - 1 - i;
        const char byte = cells[2 * offset];
        if (byte != brace && byte != opposite) continue;
        if (start + offset <= endStyled && (unsigned char)cells[2 * offset + 1] != style) continue;
        depth += byte == brace ? 1 : -1;
        if (!depth) return YES;
    }
    return NO;
}
// The current brace takes precedence; when definitely unmatched, try the preceding byte.
// If the live search is indeterminate, clear the cue. Explicit Go and Select always resolve fully.
- (TTBracePair)bracePairAtCaret:(sptr_t)caret live:(BOOL)live {
    TTBracePair result = {-1, -1};
    constexpr char delimiters[] = "()[]{}<>";
    for (const sptr_t position : {caret, caret - 1}) {
        if (position < 0) continue;
        const int byte = (int)[_engine message:SCI_GETCHARAT wParam:position];
        const char *found = byte > 0 ? std::strchr(delimiters, byte) : nullptr;
        if (!found) continue;
        const auto index = found - delimiters;
        if (live && ![self canResolveLiveBraceAt:position brace:*found opposite:delimiters[index ^ 1] forward:(index % 2 == 0)]) {
            return {-1, -1};
        }
        const sptr_t match = [_engine message:SCI_BRACEMATCH wParam:position lParam:0];
        if (match >= 0) return {position, match};
        if (result.position < 0) result.position = position;
    }
    return result;
}
- (void)refreshBraceHighlight {
    if (!_braceHighlightEnabled || _comparisonPresentation) return;
    const sptr_t caret = [_engine message:SCI_GETCURRENTPOS];
    const sptr_t endStyled = [_engine message:SCI_GETENDSTYLED];
    if (_braceCacheValid && _braceRevision == _revision && _braceCaret == caret && _braceEndStyled == endStyled) return;
    _braceCacheValid = YES;
    _braceRevision = _revision;
    _braceEndStyled = endStyled;
    _braceCaret = caret;
    const TTBracePair pair = [self bracePairAtCaret:caret live:YES];
    if (pair.position >= 0 && pair.match < 0) {
        [_engine message:SCI_BRACEBADLIGHT wParam:pair.position];
    } else {
        [_engine message:SCI_BRACEHIGHLIGHT wParam:pair.position lParam:pair.match];
    }
}
- (void)setBraceHighlightEnabled:(BOOL)enabled {
    [self assertThread];
    if (_braceHighlightEnabled == enabled) return;
    _braceHighlightEnabled = enabled;
    _braceCacheValid = NO;
    if (!enabled) [_engine message:SCI_BRACEHIGHLIGHT wParam:(uptr_t)-1 lParam:-1];
    else [self scheduleStateNotification];
}
- (void)applyCurrentLineFrameWithHighContrast:(BOOL)high {
    if (!_currentLineHighlightEnabled || _comparisonPresentation) {
        [_engine message:SCI_RESETELEMENTCOLOUR wParam:SC_ELEMENT_CARET_LINE_BACK];
        return;
    }
    const BOOL dark = [self usesDarkPalette];
    const sptr_t colour = dark ? (high ? 0xBCDFC5 : 0xA9C7B1) : (high ? 0x344D39 : 0x576B5C);
    [_engine message:SCI_SETCARETLINEFRAME wParam:high ? 2 : 1];
    [_engine message:SCI_SETELEMENTCOLOUR wParam:SC_ELEMENT_CARET_LINE_BACK lParam:0xFF000000 | colour];
}
- (void)setCurrentLineHighlightEnabled:(BOOL)enabled {
    [self assertThread]; if (_currentLineHighlightEnabled == enabled) return;
    _currentLineHighlightEnabled = enabled;
    [self applyCurrentLineFrameWithHighContrast:NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast];
}
- (void)applyIndentGuides {
    // The native dotted guides take their ink from style 37. Imported lexers may also
    // use that style for real text, so keep its configured foreground and background.
    [_engine message:SCI_SETINDENTATIONGUIDES wParam:(_indentGuidesEnabled && !_comparisonPresentation) ? SC_IV_LOOKBOTH : SC_IV_NONE];
}
- (void)setIndentGuidesEnabled:(BOOL)enabled {
    [self assertThread]; if (_indentGuidesEnabled == enabled) return;
    _indentGuidesEnabled = enabled;
    [self applyIndentGuides];
}
- (BOOL)hasBookmarks { [self assertThread]; return [_engine message:SCI_MARKERNEXT wParam:0 lParam:TTBookmarkMask] >= 0; }

- (BOOL)processBookmarkedLines:(NSString *)identifier pasteboard:(NSPasteboard *)board {
    const bool copies = ![identifier isEqualToString:@"bookmarkDeleteLines"];
    const bool removes = ![identifier isEqualToString:@"bookmarkCopyLines"];
    if ((removes && self.readOnly) || (copies && !board)) return NO;
    // A physical line owns its own terminator. The final unterminated line owns only its bytes.
    const sptr_t count = [_engine message:SCI_GETLINECOUNT], length = [_engine message:SCI_GETLENGTH];
    std::vector<Sci_CharacterRangeFull> spans;
    size_t total = 0;
    for (sptr_t line = [_engine message:SCI_MARKERNEXT wParam:0 lParam:TTBookmarkMask]; line >= 0;
         line = [_engine message:SCI_MARKERNEXT wParam:line + 1 lParam:TTBookmarkMask]) {
        const sptr_t start = [_engine message:SCI_POSITIONFROMLINE wParam:line];
        const sptr_t end = line + 1 < count ? [_engine message:SCI_POSITIONFROMLINE wParam:line + 1] : length;
        if (start < 0 || end < start || end > length) return NO;
        if (start == end) continue;
        if (!spans.empty() && spans.back().cpMax == start) spans.back().cpMax = end;
        else spans.push_back({start,end});
        total += (size_t)(end - start);
    }
    if (spans.empty()) return YES;
    const NSUInteger revision = self.revision;
    NSArray<NSNumber *> *cutMarks = copies && removes ? self.bookmarkLines : nil;
    if (copies) {
        NSMutableData *data = [NSMutableData dataWithLength:total + 1];
        char *write = (char *)data.mutableBytes;
        for (const auto &span : spans) {
            Sci_TextRangeFull part = {span,write};
            const sptr_t n = span.cpMax - span.cpMin;
            if ([_engine message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&part] != n) return NO;
            write += n;
        }
        data.length = total;
        // The .string pasteboard flavor is UTF-8. Validate without re-encoding: Foundation's
        // external string decoder can consume a legitimate leading U+FEFF from document content.
        if (![[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]) return NO;
        [board clearContents];
        if (![board setData:data forType:NSPasteboardTypeString]) return NO;
    }
    if (removes) {
        if (self.readOnly || self.revision != revision || (cutMarks && ![cutMarks isEqual:self.bookmarkLines])) return NO;
        [self openUndoGroup];
        // Remove these marks first. Scintilla otherwise transfers a removed line's markers to a neighbor.
        for (auto it = spans.rbegin(); it != spans.rend(); ++it) {
            const sptr_t start = [_engine message:SCI_LINEFROMPOSITION wParam:it->cpMin];
            const sptr_t last = [_engine message:SCI_LINEFROMPOSITION wParam:it->cpMax - 1];
            for (sptr_t line = start; line <= last; ++line)
                [_engine message:SCI_MARKERDELETE wParam:line lParam:TTBookmarkMarker];
            [_engine message:SCI_DELETERANGE wParam:it->cpMin lParam:it->cpMax - it->cpMin];
        }
        [self closeUndoGroup];
    }
    return YES;
}

- (BOOL)runCommand:(NSString *)identifier usingPasteboard:(NSPasteboard *)pasteboard {
    if (![identifier isKindOfClass:NSString.class]) return NO;
    // Rectangular Selection is the keyboard column mode: its sticky extend mode lets plain arrow
    // keys grow the rectangle, and choosing it again switches that off.
    if ([identifier isEqualToString:@"rectangularSelection"]) { [_engine message:SCI_SETSELECTIONMODE wParam:SC_SEL_RECTANGLE]; return YES; }
    if ([identifier isEqualToString:@"streamSelection"]) { [self useStreamSelection]; return YES; }
    if ([identifier isEqualToString:@"clearAdditionalSelections"]) {
        // SCI_CLEARSELECTIONS leaves one empty selection at position 0, but it is what resets the
        // rectangular and extend modes, so clear first and then put the main range back.
        // SCI_SETSELECTION neither scrolls nor touches those modes.
        const sptr_t main = [_engine message:SCI_GETMAINSELECTION];
        const sptr_t anchor = [_engine message:SCI_GETSELECTIONNANCHOR wParam:main], caret = [_engine message:SCI_GETSELECTIONNCARET wParam:main];
        [_engine message:SCI_CLEARSELECTIONS];
        [_engine message:SCI_SETSELECTION wParam:caret lParam:anchor];
        return YES;
    }
    if ([identifier isEqualToString:@"addNextOccurrence"] || [identifier isEqualToString:@"selectAllOccurrences"]) {
        [_engine message:[identifier isEqualToString:@"addNextOccurrence"] ? SCI_MULTIPLESELECTADDNEXT : SCI_MULTIPLESELECTADDEACH]; return YES;
    }
    if ([identifier isEqualToString:@"foldCurrent"]) {
        const sptr_t caret = [_engine message:SCI_GETCURRENTPOS];
        sptr_t line = [_engine message:SCI_LINEFROMPOSITION wParam:caret];
        [_engine message:SCI_COLOURISE wParam:0 lParam:[_engine message:SCI_POSITIONFROMLINE wParam:line + 1]];
        if (!([_engine message:SCI_GETFOLDLEVEL wParam:line] & SC_FOLDLEVELHEADERFLAG)) {
            line = [_engine message:SCI_GETFOLDPARENT wParam:line];
        }
        if (line >= 0) [_engine message:SCI_FOLDLINE wParam:line lParam:SC_FOLDACTION_CONTRACT];
        return YES;
    }
    if ([identifier hasPrefix:@"foldLevel"] && identifier.length == 10) {
        const NSInteger depth = [identifier characterAtIndex:9] - '0';
        if (depth < 1 || depth > 8) return NO;
        // Nesting is the parent chain. Indentation lexers can advance several numeric levels per header.
        [_engine message:SCI_COLOURISE wParam:0 lParam:-1];
        const sptr_t count = [_engine message:SCI_GETLINECOUNT];
        sptr_t lastChild[8];
        NSInteger parents = 0;
        for (sptr_t line = 0; line < count; ++line) {
            while (parents > 0 && line > lastChild[parents - 1]) --parents;
            if (!([_engine message:SCI_GETFOLDLEVEL wParam:line] & SC_FOLDLEVELHEADERFLAG)) continue;
            const sptr_t end = [_engine message:SCI_GETLASTCHILD wParam:line lParam:-1];
            if (parents + 1 == depth) {
                [_engine message:SCI_FOLDLINE wParam:line lParam:SC_FOLDACTION_CONTRACT];
                line = end;
            } else {
                lastChild[parents++] = end;
            }
        }
        return YES;
    }
    if ([identifier isEqualToString:@"foldAll"] || [identifier isEqualToString:@"unfoldAll"]) {
        [_engine message:SCI_COLOURISE wParam:0 lParam:-1];
        [_engine message:SCI_FOLDALL wParam:[identifier isEqualToString:@"foldAll"] ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND];
        return YES;
    }
    if ([identifier isEqualToString:@"showWhitespace"]) { self.whitespaceVisible = !self.whitespaceVisible; return YES; }
    if ([identifier isEqualToString:@"toggleEOL"]) { self.lineEndingsVisible = !self.lineEndingsVisible; return YES; }
    if ([identifier isEqualToString:@"toggleLineNumbers"]) { self.lineNumbersVisible = !self.lineNumbersVisible; return YES; }
    if ([identifier isEqualToString:@"toggleOvertype"]) {
        [_engine message:SCI_SETOVERTYPE wParam:![_engine message:SCI_GETOVERTYPE]]; return YES;
    }
    if ([identifier isEqualToString:@"joinLines"]) {
        [_engine message:SCI_TARGETFROMSELECTION];
        [_engine message:SCI_LINESJOIN]; return YES;
    }
    if ([identifier isEqualToString:@"trimTrailing"]) {
        [self openUndoGroup];
        for (sptr_t line = [_engine message:SCI_GETLINECOUNT]; line-- > 0;) {
            sptr_t start = [_engine message:SCI_POSITIONFROMLINE wParam:line];
            sptr_t end = [_engine message:SCI_GETLINEENDPOSITION wParam:line];
            sptr_t trim = end;
            while (trim > start) {
                sptr_t ch = [_engine message:SCI_GETCHARAT wParam:trim-1];
                if (ch != ' ' && ch != '\t') break;
                --trim;
            }
            if (trim != end) {
                [_engine message:SCI_SETTARGETRANGE wParam:trim lParam:end];
                [_engine message:SCI_REPLACETARGET wParam:0 lParam:(sptr_t)""];
            }
        }
        [self closeUndoGroup]; return YES;
    }
    if ([identifier isEqualToString:@"gotoMatchingBrace"] || [identifier isEqualToString:@"selectMatchingBrace"]) {
        const TTBracePair pair = [self bracePairAtCaret:[_engine message:SCI_GETCURRENTPOS] live:NO];
        if (pair.match >= 0) {
            if ([identifier isEqualToString:@"selectMatchingBrace"]) [_engine message:SCI_SETSEL wParam:MIN(pair.position,pair.match) lParam:MAX(pair.position,pair.match)+1];
            else [_engine message:SCI_GOTOPOS wParam:pair.match];
            [_engine message:SCI_SCROLLCARET];
        }
        return YES;
    }
    if ([identifier hasPrefix:@"bookmark"]) {
        if ([identifier isEqualToString:@"bookmarkClearAll"]) {
            [_engine message:SCI_MARKERDELETEALL wParam:TTBookmarkMarker];
            return YES;
        }
        if ([identifier isEqualToString:@"bookmarkInvert"]) {
            const sptr_t count = [_engine message:SCI_GETLINECOUNT];
            for (sptr_t line = 0; line < count; ++line) {
                const bool marked = [_engine message:SCI_MARKERGET wParam:line] & TTBookmarkMask;
                [_engine message:marked ? SCI_MARKERDELETE : SCI_MARKERADD wParam:line lParam:TTBookmarkMarker];
            }
            return YES;
        }
        if ([identifier isEqualToString:@"bookmarkCutLines"] || [identifier isEqualToString:@"bookmarkCopyLines"] ||
            [identifier isEqualToString:@"bookmarkDeleteLines"]) {
            return [self processBookmarkedLines:identifier pasteboard:pasteboard];
        }
        if (![@[@"bookmarkToggle", @"bookmarkNext", @"bookmarkPrevious"] containsObject:identifier]) return NO;
        sptr_t line = [_engine message:SCI_LINEFROMPOSITION wParam:[_engine message:SCI_GETCURRENTPOS]];
        if ([identifier isEqualToString:@"bookmarkToggle"]) {
            [_engine message:([_engine message:SCI_MARKERGET wParam:line] & TTBookmarkMask) ? SCI_MARKERDELETE : SCI_MARKERADD wParam:line lParam:TTBookmarkMarker];
        } else if ([identifier isEqualToString:@"bookmarkNext"] || [identifier isEqualToString:@"bookmarkPrevious"]) {
            BOOL next = [identifier isEqualToString:@"bookmarkNext"];
            sptr_t found = (!next && line == 0) ? -1 : [_engine message:next ? SCI_MARKERNEXT : SCI_MARKERPREVIOUS wParam:next ? line+1 : line-1 lParam:TTBookmarkMask];
            if (found < 0) found = [_engine message:next ? SCI_MARKERNEXT : SCI_MARKERPREVIOUS wParam:next ? 0 : [_engine message:SCI_GETLINECOUNT]-1 lParam:TTBookmarkMask];
            if (found >= 0) { [_engine message:SCI_ENSUREVISIBLE wParam:found]; [_engine message:SCI_GOTOLINE wParam:found]; }
        }
        return YES;
    }
    NSNumber *message = TTDispatchCommands()[identifier];
    if (message == nil) return NO;
    if (message.unsignedIntValue == SCI_NEWLINE) {
        [self performReturn:^{ [self.engine message:SCI_NEWLINE]; }];
    } else {
        [_engine message:message.unsignedIntValue];
    }
    return YES;
}
+ (NSArray<TTEditorCommandIdentifier> *)supportedCommandIdentifiers {
    NSMutableArray *identifiers = [NSMutableArray array];
    for (const auto &entry : TTCommandEntries) [identifiers addObject:[NSString stringWithUTF8String:entry.identifier]];
    return [identifiers sortedArrayUsingSelector:@selector(compare:)];
}
+ (NSArray<TTEditorCommandIdentifier> *)macroCommandNames { return [TTMacroCommands().allKeys sortedArrayUsingSelector:@selector(compare:)]; }
+ (NSDictionary<TTEditorCommandIdentifier, NSNumber *> *)macroCommandMessages { return TTMacroCommands(); }
- (TTInteractionState)interactionState {
    return {_revision, [_engine message:SCI_GETSELECTIONS], [_engine message:SCI_GETANCHOR], [_engine message:SCI_GETCURRENTPOS]};
}
- (void)reportUnrecordedMouseInteraction {
    if (TTActiveMouseInteraction) {
        if (auto *recording = TTActiveMouseInteraction->find(self)) {
            if (recording->reported) return;
            recording->reported = true;
        }
    }
    [self reportMacroStep:[TTMacroAction unsupported:@"A mouse click, mouse selection or drag and drop" message:0]];
}
- (void)noteUnrecordedInteractionSince:(TTInteractionState)before {
    if (!_macroRecording || !_onMacroStep) return;
    const TTInteractionState now = [self interactionState];
    if (now.revision == before.revision && now.selections == before.selections && now.anchor == before.anchor && now.caret == before.caret) return;
    [self reportUnrecordedMouseInteraction];
}
/// The handler may clear itself while it runs (a discard does), so it is held for the call.
- (void)reportMacroStep:(TTMacroAction *)step {
    void (^handler)(TTMacroAction *) = _onMacroStep;
    // Stop/restart can run in onChange before Scintilla reports the literal for this key.
    if (_inNativeMacroInput && _retiredNativeMacroInput && !TTActiveMacroMessage &&
        step.kind != TTMacroActionKindUnsupported) return;
    if (_pendingMacroSearch && step.kind != TTMacroActionKindUnsupported) {
        step = [TTMacroAction unsupported:@"An editing action interleaved with an unfinished search replacement" message:SCI_REPLACETARGET];
    }
    if (handler) handler(step);
}
- (void)settlePendingInteraction {
    if (!_interactionPending) return;
    _interactionPending = NO;
    [self noteUnrecordedInteractionSince:_pendingInteraction];
}
/// A margin click selects lines through SCIMarginView, which the bridge cannot subclass. The
/// event is seen here before it is dispatched; the comparison runs once it has been handled.
- (void)observeMarginMouseEvent:(NSEvent *)event {
    if (!_macroRecording || !self.window || event.window != self.window) return;
    if (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown) {
        NSView *hit = [_engine hitTest:[self convertPoint:event.locationInWindow fromView:nil]];
        NSView *content = _engine.content;
        _marginMouseDown = hit != nil && hit != content && ![hit isDescendantOf:content];
    }
    if (!_marginMouseDown) return;
    [self settlePendingInteraction];
    _pendingInteraction = [self interactionState];
    _interactionPending = YES;
    __weak TTEditor *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf settlePendingInteraction]; });
}
- (void)startRecording {
    [self assertThread]; _macroRecording = YES; _interactionPending = NO; _marginMouseDown = NO;
    if (TTActiveMouseInteraction) TTActiveMouseInteraction->capture(self);
    [TTRecordingEditors() addObject:self];
    TTWatchMacroMessages = true;
    if (!_macroMouseMonitor) {
        __weak TTEditor *weakSelf = self;
        _macroMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown handler:^NSEvent *(NSEvent *event) {
            [weakSelf observeMarginMouseEvent:event];
            return event;
        }];
    }
    [_engine message:SCI_STARTRECORD];
}
- (void)stopRecording {
    [self assertThread];
    // A margin click still waiting for its comparison is settled before the recording can be saved.
    [self settlePendingInteraction];
    if (TTActiveMouseInteraction) {
        auto *recording = TTActiveMouseInteraction->find(self);
        if (recording && !recording->reported) [self noteUnrecordedInteractionSince:recording->before];
    }
    if (_inNativeMacroInput) _retiredNativeMacroInput = YES;
    if (_inNativeMacroInput && _nativeInputChanged && !_nativeInputReported) {
        _nativeInputChanged = NO;
        [self reportMacroStep:[TTMacroAction unsupported:@"Unfinished native input without its recorded step" message:0]];
    }
    if (_pendingMacroSearch) {
        _pendingMacroSearch = nil;
        [self reportMacroStep:[TTMacroAction unsupported:@"A search replacement without its recorded step" message:SCI_REPLACETARGET]];
    }
    _macroRecording = NO;
    [TTRecordingEditors() removeObject:self];
    TTWatchMacroMessages = TTRecordingEditors().count != 0;
    if (_macroMouseMonitor) { [NSEvent removeMonitor:_macroMouseMonitor]; _macroMouseMonitor = nil; }
    [_engine message:SCI_STOPRECORD];
}
- (void)beginUndoGroupNamed:(NSString *)name {
    [self assertThread];
    if (![self undoGroupOpen]) {
        _pendingUndoName = [name copy];
        _namedStartRevision = self.revision;
    }
    [self openUndoGroup];
}
- (NSString *)historyNameForRedo:(BOOL)redo {
    [self assertThread];
    const sptr_t current = [_engine message:SCI_GETUNDOCURRENT], actions = [_engine message:SCI_GETUNDOACTIONS];
    if ((redo && current >= actions) || (!redo && current <= 0)) return nil;
    if (redo && current == _cachedRedoCursor && actions == _cachedRedoActions && self.revision == _cachedRedoRevision)
        return _cachedRedoName;
    sptr_t end = redo ? current : current - 1;
    // Scintilla's serialized action type uses bit 0x100 for 'coalesces with next'.
    // This follows UndoHistory::StartRedo, including the open final action.
    static constexpr int coalescesWithNext = 0x100, containerType = 2;
    if (redo) {
        while (end + 1 < actions && ([_engine message:SCI_GETUNDOACTIONTYPE wParam:end] & coalescesWithNext)) end++;
    }
    const NSInteger type = [_engine message:SCI_GETUNDOACTIONTYPE wParam:end] & ~coalescesWithNext;
    NSString *name = nil;
    if (type == containerType) {
        const NSInteger index = [_engine message:SCI_GETUNDOACTIONPOSITION wParam:end] - TTNamedHistoryBase;
        if (index >= 0 && static_cast<NSUInteger>(index) < _historyNames.count) name = _historyNames[index];
    }
    if (redo) {
        _cachedRedoCursor = current;
        _cachedRedoActions = actions;
        _cachedRedoRevision = self.revision;
        _cachedRedoName = name;
    }
    return name;
}
- (void)beginUndoGroup { [self assertThread]; [self openUndoGroup]; }
- (void)endUndoGroup { [self assertThread]; [self closeUndoGroup]; }
- (BOOL)executeMacroStep:(TTMacroAction *)step {
    [self assertThread];
    if (![step isKindOfClass:TTMacroAction.class]) return NO;
    switch (step.kind) {
        case TTMacroActionKindInsertText: {
            if (![step.text isKindOfClass:NSString.class] || self.selectionCount!=1 || self.readOnly) return NO;
            NSData *bytes=TTUTF8(step.text); if (bytes==nil) return NO;
            [self noteStateChange];
            return [self replaceSelectionWithEncodedBytes:bytes];
        }
        case TTMacroActionKindCommand: {
            if (![step.command isKindOfClass:NSString.class]) return NO;
            // Only fixed symbolic commands dispatch. Diagnostic messages and imported numbers do not.
            NSNumber *message=TTReplayCommands()[step.command];
            if (message==nil) return NO;
            [_engine message:message.unsignedIntValue]; [self noteStateChange]; return YES;
        }
        case TTMacroActionKindUnsupported: return NO;
    }
    return NO;
}
+ (NSArray<NSString *> *)availableLanguages {
    // The linked lexers never change while the app runs, and this is asked on every language switch.
    static NSArray<NSString *> *languages;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (int index = 0; index < GetLexerCount(); ++index) {
            char name[128] = {};
            GetLexerName(index, name, sizeof(name));
            NSString *value = [NSString stringWithUTF8String:name];
            if (value) [names addObject:value];
        }
        [names addObject:@"user"];
        languages = [names sortedArrayUsingSelector:@selector(compare:)];
    });
    return languages;
}
/// Install the lexer and defaults before styling the visible range with its completed configuration.
- (void)installLexer:(NSString *)language {
    _braceCacheValid = NO;
    [self scheduleStateNotification];
    [_syntaxStyles removeAllObjects];[_syntaxFonts removeAllObjects];
    auto lexer = [language isEqualToString:@"user"] ? TextTankCreateUserLexer() : CreateLexer(language.UTF8String);
    if (!lexer) lexer = CreateLexer("null");
    [_engine message:SCI_SETILEXER wParam:0 lParam:(sptr_t)lexer];
    // The null lexer assumes every style byte is already 0 and only marks the document as styled,
    // so the previous language's styles and fold levels have to be cleared for it.
    if ([language isEqualToString:@"null"]) [_engine message:SCI_CLEARDOCUMENTSTYLE];
    [_engine message:SCI_SETPROPERTY wParam:(uptr_t)"fold" lParam:(sptr_t)"1"];
    // A bare cpp lexer, with no language profile, keeps a small C-like keyword list and palette.
    _cppDefaults = [language isEqualToString:@"cpp"];
    if (_cppDefaults) [_engine message:SCI_SETKEYWORDS wParam:0 lParam:(sptr_t)"if else for while return class struct import func let var true false null int void const static public private"];
    [self applyPalette];
}
- (void)styleVisibleDocumentPrefix {
    const sptr_t length = [_engine message:SCI_GETLENGTH];
    const sptr_t first = [_engine message:SCI_GETFIRSTVISIBLELINE];
    const sptr_t visible = MAX(1, [_engine message:SCI_LINESONSCREEN]);
    const sptr_t nextLine = [_engine message:SCI_DOCLINEFROMVISIBLE wParam:first + visible + 1];
    const sptr_t lineCount = [_engine message:SCI_GETLINECOUNT];
    const sptr_t end = nextLine < 0 || nextLine >= lineCount - 1 ? length
        : [_engine message:SCI_POSITIONFROMLINE wParam:nextLine];
    [_engine message:SCI_COLOURISE wParam:0 lParam:end];
}
- (void)setLanguage:(NSString *)language {
    [self assertThread];
    [self installLexer:language];
    [self styleVisibleDocumentPrefix];
}
- (void)setLanguage:(NSString *)language keywordLists:(NSDictionary<NSNumber *, NSString *> *)keywordLists properties:(NSDictionary<NSString *, NSString *> *)properties {
    [self assertThread];
    [self installLexer:language];
    // Clear lists left by the defaults before loading explicit source data.
    for (NSInteger index=0;index<32;++index) [_engine message:SCI_SETKEYWORDS wParam:index lParam:(sptr_t)""];
    [keywordLists enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSString *words, BOOL *stop) {
        NSInteger index=key.integerValue;
        if (index<0 || index>31 || [words rangeOfString:@"\0"].location!=NSNotFound) return;
        [self->_engine message:SCI_SETKEYWORDS wParam:index lParam:(sptr_t)words.UTF8String];
    }];
    [properties enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        if ([name rangeOfString:@"\0"].location!=NSNotFound || [value rangeOfString:@"\0"].location!=NSNotFound) return;
        [self->_engine message:SCI_SETPROPERTY wParam:(uptr_t)name.UTF8String lParam:(sptr_t)value.UTF8String];
    }];
    // Invalidate the prior lexer from byte zero; subsequent paints request additional styling.
    [self styleVisibleDocumentPrefix];
}
- (NSAttributedString *)attributedTextForSelection:(BOOL)selection {
    [self assertThread]; [_engine message:SCI_COLOURISE wParam:0 lParam:-1];
    const sptr_t start=selection ? self.selectionStart : 0,end=selection ? self.selectionEnd : [_engine message:SCI_GETLENGTH];
    NSMutableAttributedString *result=[[NSMutableAttributedString alloc] initWithString:@""];
    if (end<=start) return result;
    const size_t length=(size_t)(end-start);
    // One fetch of every byte with its style (two bytes per cell, then two terminating NULs),
    // separated in place: text packed at the front of `cells`, styles in their own buffer.
    std::vector<char> cells(2*length+2);
    Sci_TextRangeFull range={{start,end},cells.data()};
    [_engine message:SCI_GETSTYLEDTEXTFULL wParam:0 lParam:(sptr_t)&range];
    std::vector<unsigned char> styles(length);
    for (size_t i=0;i<length;++i) { styles[i]=(unsigned char)cells[2*i+1]; cells[i]=cells[2*i]; }
    // The font and colours of a style are resolved once per call, not once per run.
    NSDictionary *attributes[256]={};
    [result beginEditing];
    for (size_t p=0;p<length;) {
        const unsigned char style=styles[p];size_t q=p+1;
        while (q<length && styles[q]==style) ++q;
        // Style runs normally align to scalar boundaries; extend malformed style
        // boundaries to avoid splitting a UTF8 character in exported text.
        while (q<length && (cells[q]&0xC0)==0x80) ++q;
        if (!attributes[style]) {
            CGFloat size=[_engine message:SCI_STYLEGETSIZEFRACTIONAL wParam:style]/100.0;
            std::vector<char> face((size_t)[_engine message:SCI_STYLEGETFONT wParam:style lParam:0]+1);[_engine message:SCI_STYLEGETFONT wParam:style lParam:(sptr_t)face.data()];
            NSString *faceName=[NSString stringWithUTF8String:face.data()];
            NSFont *font=(faceName ? [NSFont fontWithName:faceName size:size] : nil) ?: [NSFont monospacedSystemFontOfSize:MAX(1,size) weight:NSFontWeightRegular];
            NSFontTraitMask traits=0;if ([_engine message:SCI_STYLEGETBOLD wParam:style]) traits|=NSBoldFontMask;if ([_engine message:SCI_STYLEGETITALIC wParam:style]) traits|=NSItalicFontMask;
            if(traits)font=[[NSFontManager sharedFontManager] convertFont:font toHaveTrait:traits];
            attributes[style]=@{NSFontAttributeName:font,NSForegroundColorAttributeName:TTColorFromScintilla([_engine message:SCI_STYLEGETFORE wParam:style]),NSBackgroundColorAttributeName:TTColorFromScintilla([_engine message:SCI_STYLEGETBACK wParam:style])};
        }
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:TTStringFromUTF8(cells.data()+p,q-p) attributes:attributes[style]]];
        p=q;
    }
    [result endEditing];
    return result;
}
- (BOOL)setSyntaxStyle:(NSInteger)index foreground:(NSColor *)foreground background:(NSColor *)background bold:(BOOL)bold italic:(BOOL)italic {
    [self assertThread]; if(index<0 || index>255 || ![foreground isKindOfClass:NSColor.class] || (background!=nil && ![background isKindOfClass:NSColor.class]))return NO;
    NSMutableDictionary *configuration=[@{@"foreground":foreground,@"bold":@(bold),@"italic":@(italic)} mutableCopy];if(background)configuration[@"background"]=background;_syntaxStyles[@(index)]=configuration;
    // A dynamic colour is resolved for this view's appearance, the one applyPalette chose the base
    // palette from, not for whatever appearance happens to be current on the thread. The dynamic
    // colour itself stays in _syntaxStyles so the next appearance change resolves it again.
    __block NSColor *front=nil,*back=nil;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        front=[foreground colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        back=[background colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    // A colour with no RGB form (a pattern, say) leaves the style's colour alone instead of turning it black.
    if(front)[_engine message:SCI_STYLESETFORE wParam:index lParam:TTScintillaFromColor(front)];
    if(back)[_engine message:SCI_STYLESETBACK wParam:index lParam:TTScintillaFromColor(back)];
    [_engine message:SCI_STYLESETBOLD wParam:index lParam:bold];[_engine message:SCI_STYLESETITALIC wParam:index lParam:italic];
    // The filler line numbers are drawn in this style's colour and no notification follows.
    if (index == STYLE_LINENUMBER) _emptyLineNumbers.needsDisplay = YES;
    return YES;
}
// Comparison helpers are deliberately grouped. They never share or replace a source document.
- (BOOL)selectionIsRectangular {
    [self assertThread]; const sptr_t mode=[_engine message:SCI_GETSELECTIONMODE];
    return mode==SC_SEL_RECTANGLE || mode==SC_SEL_THIN;
}
- (void)applyComparisonStyle {
    const BOOL dark=[self usesDarkPalette];
    const sptr_t cue=dark ? 0x5BF4C7 : 0x005B3A;
    for (int indicator : {21,22}) {
        [_engine message:SCI_INDICSETSTYLE wParam:indicator lParam:indicator==21 ? INDIC_FULLBOX : INDIC_ROUNDBOX];
        [_engine message:SCI_INDICSETFORE wParam:indicator lParam:cue];
        [_engine message:SCI_INDICSETALPHA wParam:indicator lParam:indicator==21 ? 18 : 52];
        [_engine message:SCI_INDICSETOUTLINEALPHA wParam:indicator lParam:255];
    }
    const int symbols[]={'+','-','~'};
    for(int i=0;i<3;++i) {
        [_engine message:SCI_MARKERDEFINE wParam:2+i lParam:SC_MARK_CHARACTER+symbols[i]];
        [_engine message:SCI_MARKERSETFORE wParam:2+i lParam:cue];
        [_engine message:SCI_MARKERSETBACK wParam:2+i lParam:dark ? 0x222A25 : 0xE3E9E5];
    }
    [_engine message:SCI_SETMARGINMASKN wParam:1 lParam:TTBookmarkMask|(1<<2)|(1<<3)|(1<<4)];
    [_engine message:SCI_SETMARGINWIDTHN wParam:1 lParam:20];
    [_engine message:SCI_ANNOTATIONSETVISIBLE wParam:ANNOTATION_STANDARD];
}
- (void)setComparisonPresentation:(BOOL)value {
    [self assertThread]; _comparisonPresentation=value;
    _braceCacheValid = NO;
    if (value) [_engine message:SCI_BRACEHIGHLIGHT wParam:(uptr_t)-1 lParam:-1];
    else [self scheduleStateNotification];
    [self applyCurrentLineFrameWithHighContrast:NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast];
    [self applyIndentGuides];
    _emptyLineNumbers.hidden=value;
    // The two comparison panes scroll sideways together, so they keep one fixed range.
    [_engine message:SCI_SETSCROLLWIDTHTRACKING wParam:!value];
    [_engine message:SCI_SETSCROLLWIDTH wParam:value ? 2000 : 1];
    [_engine message:SCI_SETVSCROLLBAR wParam:!value];
    [_engine message:SCI_SETENDATLASTLINE wParam:!value];
    if(value) [self applyComparisonStyle];
    [self applyChangeTracking];
    [self updateCenteredColumn];
}
- (BOOL)comparisonPresentation { return _comparisonPresentation; }
- (NSInteger)comparisonTopDisplayLine { [self assertThread]; return [_engine message:SCI_GETFIRSTVISIBLELINE]; }
- (void)setComparisonTopDisplayLine:(NSInteger)line {
    [self assertThread]; if(!_comparisonPresentation || line<0)return;
    [_engine message:SCI_SETFIRSTVISIBLELINE wParam:MIN(line,MAX(0,self.comparisonDisplayRows-1))];
}
- (NSInteger)comparisonHorizontalOffset { [self assertThread]; return [_engine message:SCI_GETXOFFSET]; }
- (void)setComparisonHorizontalOffset:(NSInteger)offset {
    [self assertThread]; if(_comparisonPresentation && offset>=0) [_engine message:SCI_SETXOFFSET wParam:offset];
}
- (NSInteger)comparisonDisplayRows {
    [self assertThread]; const sptr_t last=MAX(0,[_engine message:SCI_GETLINECOUNT]-1);
    return MAX(1,[_engine message:SCI_VISIBLEFROMDOCLINE wParam:last]+[_engine message:SCI_WRAPCOUNT wParam:last]+[_engine message:SCI_ANNOTATIONGETLINES wParam:last]);
}
- (NSFont *)comparisonFont {
    [self assertThread];
    const sptr_t length=[_engine message:SCI_STYLEGETFONT wParam:0 lParam:0];
    NSString *name=@"Menlo";
    if(length>0 && length<=200) {
        std::vector<char> bytes((size_t)length+1,0);
        [_engine message:SCI_STYLEGETFONT wParam:0 lParam:(sptr_t)bytes.data()];
        name=[[NSString alloc] initWithBytes:bytes.data() length:(NSUInteger)length encoding:NSUTF8StringEncoding] ?: name;
    }
    const double size=MAX(6,MIN(96,[_engine message:SCI_STYLEGETSIZEFRACTIONAL wParam:0]/100.0+[_engine message:SCI_GETZOOM]));
    return [NSFont fontWithName:name size:size] ?: [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
}
- (void)setComparisonFont:(NSFont *)font {
    [self assertThread];if(!_comparisonPresentation || ![font isKindOfClass:NSFont.class] || !std::isfinite(font.pointSize) || font.pointSize<6 || font.pointSize>96)return;
    for(int style : {0,STYLE_DEFAULT,STYLE_LINENUMBER})[self setSyntaxFont:style name:font.fontName size:font.pointSize];
    [_engine message:SCI_SETZOOM wParam:0];[self comparisonViewportChanged];
}
- (NSInteger)comparisonLineHeight { [self assertThread]; return MAX(1,[_engine message:SCI_TEXTHEIGHT wParam:0]); }
- (NSInteger)comparisonDocumentLineForDisplayLine:(NSInteger)line {
    [self assertThread]; if(line<0 || line>=self.comparisonDisplayRows)return -1;
    return [_engine message:SCI_DOCLINEFROMVISIBLE wParam:line];
}
- (NSInteger)comparisonDisplayLineForDocumentLine:(NSInteger)line {
    [self assertThread]; if(line<0 || line>=[_engine message:SCI_GETLINECOUNT])return -1;
    return [_engine message:SCI_VISIBLEFROMDOCLINE wParam:line];
}
- (NSInteger)comparisonWrapCountForLine:(NSInteger)line {
    [self assertThread]; if(line<0 || line>=[_engine message:SCI_GETLINECOUNT])return 0;
    return [_engine message:SCI_WRAPCOUNT wParam:line];
}
- (NSInteger)comparisonYForByte:(NSInteger)position {
    [self assertThread]; if(position<0 || position>self.byteLength)return NSIntegerMin;
    return [_engine message:SCI_POINTYFROMPOSITION wParam:0 lParam:position];
}
- (void)clearComparisonPresentation {
    [self assertThread];
    for (int indicator : {21,22}) {
        [_engine message:SCI_SETINDICATORCURRENT wParam:indicator];
        [_engine message:SCI_INDICATORCLEARRANGE wParam:0 lParam:self.byteLength];
    }
    for(int marker : {2,3,4})[_engine message:SCI_MARKERDELETEALL wParam:marker];
    [_engine message:SCI_ANNOTATIONCLEARALL];
    [_engine message:SCI_SHOWLINES wParam:0 lParam:MAX(0,[_engine message:SCI_GETLINECOUNT]-1)];
}
- (BOOL)addComparisonHighlights:(NSArray<TTByteRange *> *)lines inlineRanges:(NSArray<TTByteRange *> *)spans kind:(NSInteger)kind {
    [self assertThread]; if(!_comparisonPresentation || kind<0 || kind>2 || ![lines isKindOfClass:NSArray.class] || ![spans isKindOfClass:NSArray.class] || lines.count>512 || spans.count>512)return NO;
    const NSUInteger length=self.byteLength;
    for(NSArray *batch in @[lines,spans])for(id value in batch) {
        NSRange range; if(!TTValidatedByteRange(value,length,&range))return NO;
        for(NSUInteger p : {range.location,NSMaxRange(range)})
            if(p<length && ([_engine message:SCI_GETCHARAT wParam:p]&0xc0)==0x80)return NO;
    }
    for(TTByteRange *range in lines) {
        [_engine message:SCI_SETINDICATORCURRENT wParam:21];
        [_engine message:SCI_INDICATORFILLRANGE wParam:range.location lParam:range.length];
        const sptr_t line=[_engine message:SCI_LINEFROMPOSITION wParam:range.location];
        [_engine message:SCI_MARKERADD wParam:line lParam:kind+2];
    }
    for(TTByteRange *range in spans) {
        [_engine message:SCI_SETINDICATORCURRENT wParam:22];
        [_engine message:SCI_INDICATORFILLRANGE wParam:range.location lParam:range.length];
    }
    return YES;
}
- (BOOL)setComparisonGapAfterLine:(NSInteger)line rows:(NSInteger)rows {
    [self assertThread]; if(!_comparisonPresentation || line<0 || line>=[_engine message:SCI_GETLINECOUNT] || rows<0 || rows>32760)return NO;
    if(rows==0) { [_engine message:SCI_ANNOTATIONSETTEXT wParam:line lParam:0]; return YES; }
    const std::string text((size_t)rows-1,'\n');
    [_engine message:SCI_ANNOTATIONSETTEXT wParam:line lParam:(sptr_t)text.c_str()];
    return YES;
}
- (BOOL)setComparisonHiddenLines:(NSIndexSet *)lines {
    [self assertThread]; if(!_comparisonPresentation || ![lines isKindOfClass:NSIndexSet.class])return NO;
    const NSUInteger count=[_engine message:SCI_GETLINECOUNT];
    if(lines.count && (lines.firstIndex==0 || lines.lastIndex>=count))return NO;
    [_engine message:SCI_SHOWLINES wParam:0 lParam:count-1];
    [lines enumerateRangesUsingBlock:^(NSRange range,BOOL *stop){
        [self.engine message:SCI_HIDELINES wParam:range.location lParam:NSMaxRange(range)-1];
    }];
    return YES;
}
- (void)setComparisonWhitespaceVisible:(BOOL)visible {
    [self assertThread]; if(!_comparisonPresentation)return;
    [_engine message:SCI_SETVIEWWS wParam:visible ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE];
    [_engine message:SCI_SETVIEWEOL wParam:visible];
}
- (void)comparisonViewportChanged {
    if(!_comparisonPresentation || !_onComparisonViewportChange || _comparisonScrollScheduled)return;
    _comparisonScrollScheduled=YES; __weak TTEditor *weakSelf=self;
    dispatch_async(dispatch_get_main_queue(),^{
        TTEditor *editor=weakSelf; if(!editor)return;
        editor.comparisonScrollScheduled=NO;
        if(editor.comparisonPresentation && editor.onComparisonViewportChange)editor.onComparisonViewportChange();
    });
}

- (void)clearSearchHighlights {
    [self assertThread];[_engine message:SCI_SETINDICATORCURRENT wParam:TTSearchIndicator];[_engine message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[_engine message:SCI_GETLENGTH]];
}
- (BOOL)setSearchHighlights:(NSArray<TTByteRange *> *)ranges {
    return [self setHighlightRanges:ranges indicator:TTSearchIndicator];
}
- (NSUInteger)findPreviewLineLengthAtByte:(NSUInteger)position {
    [self assertThread];
    const sptr_t line = [_engine message:SCI_LINEFROMPOSITION wParam:position];
    return [_engine message:SCI_LINELENGTH wParam:line];
}
- (NSUInteger)findPreviewLongestVisibleLine {
    [self assertThread];
    const sptr_t first = [_engine message:SCI_GETFIRSTVISIBLELINE];
    const sptr_t last = first + [_engine message:SCI_LINESONSCREEN];
    NSUInteger longest = 0;
    for (sptr_t display = first; display <= last; ++display) {
        const sptr_t line = [_engine message:SCI_DOCLINEFROMVISIBLE wParam:display];
        longest = MAX(longest, (NSUInteger)[_engine message:SCI_LINELENGTH wParam:line]);
    }
    return longest;
}
- (BOOL)setFindPreviewHighlights:(NSArray<TTByteRange *> *)ranges {
    return [self setHighlightRanges:ranges indicator:TTFindPreviewIndicator];
}
- (BOOL)setHighlightRanges:(NSArray<TTByteRange *> *)ranges indicator:(int)indicator {
    [self assertThread];
    if (![ranges isKindOfClass:NSArray.class] || ranges.count>100000) return NO;
    const NSUInteger length=[_engine message:SCI_GETLENGTH];
    for (id value in ranges) {
        NSRange range;
        if (!TTValidatedByteRange(value,length,&range)) return NO;
        for (NSUInteger p : {range.location,NSMaxRange(range)})
            if(p<length && ([_engine message:SCI_GETCHARAT wParam:p]&0xC0)==0x80) return NO;
    }
    [_engine message:SCI_SETINDICATORCURRENT wParam:indicator];
    [_engine message:SCI_INDICATORCLEARRANGE wParam:0 lParam:length];
    if (indicator == TTSearchIndicator) [self applySearchIndicatorStyle];
    for (TTByteRange *range in ranges)
        [_engine message:SCI_INDICATORFILLRANGE wParam:range.location lParam:range.length];
    return YES;
}
- (BOOL)setBaseFontName:(NSString *)name size:(double)size {
    [self assertThread];
    if (!std::isfinite(size) || size < 6 || size > 72 || ![name isKindOfClass:NSString.class] ||
        !name.length || name.length > 200 || [name rangeOfString:@"\0"].location != NSNotFound ||
        ![NSFont fontWithName:name size:size]) return NO;
    const double points = lround(size * 100) / 100.0;
    if ([_baseFontName isEqualToString:name] && _basePointSize == points) return YES;
    _baseFontName = [name copy];
    _basePointSize = points;
    [self applyPalette];
    _emptyLineNumbers.needsDisplay = YES;
    [self scheduleStateNotification];
    return YES;
}
- (NSInteger)zoomLevel { [self assertThread]; return [_engine message:SCI_GETZOOM]; }
- (void)setZoomLevel:(NSInteger)level {
    [self assertThread];
    if (level >= -10 && level <= 60 && level != self.zoomLevel) [_engine message:SCI_SETZOOM wParam:level];
}
- (void)applyDefaultZoomLevel:(NSInteger)level {
    [self assertThread];
    if (level < -10 || level > 60) return;
    _defaultZoomLevel = level;
    if (_followsDefaultZoom) self.zoomLevel = level;
}
- (void)resetZoomLevel {
    [self assertThread];
    _followsDefaultZoom = YES;
    self.zoomLevel = _defaultZoomLevel;
}
- (BOOL)followsDefaultZoom { [self assertThread]; return _followsDefaultZoom; }
- (BOOL)lineNumbersVisible { [self assertThread]; return [_engine message:SCI_GETMARGINWIDTHN wParam:0] != 0; }
- (void)setLineNumbersVisible:(BOOL)visible {
    [self assertThread];
    if (visible == self.lineNumbersVisible) return;
    if (visible) [self updateLineNumberMargin:YES];
    else [_engine message:SCI_SETMARGINWIDTHN wParam:0 lParam:0];
    // The margin change raises no synchronous notification.
    [self invalidateLineNumbersIfChanged];
    [self scheduleStateNotification];
}
- (BOOL)whitespaceVisible { [self assertThread]; return [_engine message:SCI_GETVIEWWS] != SCWS_INVISIBLE; }
- (void)setWhitespaceVisible:(BOOL)visible {
    [self assertThread];
    if (visible == self.whitespaceVisible) return;
    [_engine message:SCI_SETVIEWWS wParam:visible ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE];
    [self scheduleStateNotification];
}
- (BOOL)lineEndingsVisible { [self assertThread]; return [_engine message:SCI_GETVIEWEOL] != 0; }
- (void)setLineEndingsVisible:(BOOL)visible {
    [self assertThread];
    if (visible == self.lineEndingsVisible) return;
    [_engine message:SCI_SETVIEWEOL wParam:visible];
    [self scheduleStateNotification];
}
- (void)applyFontToStyle:(NSInteger)index name:(NSString *)name size:(NSNumber *)size {
    NSString *face = name ?: _baseFontName;
    double points = size ? size.doubleValue : _basePointSize;
    [_engine message:SCI_STYLESETFONT wParam:index lParam:(sptr_t)face.UTF8String];
    [_engine message:SCI_STYLESETSIZEFRACTIONAL wParam:index lParam:lround(points * 100)];
}
- (BOOL)setSyntaxFont:(NSInteger)index name:(NSString *)name size:(double)size {
    [self assertThread];
    if (![name isKindOfClass:NSString.class] || !name.length) return NO;
    return [self setSyntaxFont:index faceOverride:name sizeOverride:@(size)];
}
- (BOOL)setSyntaxFont:(NSInteger)index faceOverride:(NSString *)name sizeOverride:(NSNumber *)size {
    [self assertThread];
    if (index < 0 || index > 255) return NO;
    if (size && (![size isKindOfClass:NSNumber.class] || !std::isfinite(size.doubleValue) ||
                 size.doubleValue < 6 || size.doubleValue > 96)) return NO;
    if (name && (![name isKindOfClass:NSString.class] || !name.length || name.length > 200 ||
                 [name rangeOfString:@"\0"].location != NSNotFound ||
                 ![NSFont fontWithName:name size:_basePointSize])) return NO;
    NSMutableDictionary *override = [NSMutableDictionary dictionary];
    if (name) override[@"name"] = name;
    if (size) override[@"size"] = size;
    if (override.count) _syntaxFonts[@(index)] = override;
    else [_syntaxFonts removeObjectForKey:@(index)];
    [self applyFontToStyle:index name:name size:size];
    if (index == STYLE_LINENUMBER || index == STYLE_DEFAULT) {
        [self updateLineNumberMargin:NO];
        _emptyLineNumbers.needsDisplay = YES;
    }
    return YES;
}
- (BOOL)showCallTip:(NSString *)text {
    [self assertThread];
    if(![text isKindOfClass:NSString.class] || [text rangeOfString:@"\0"].location!=NSNotFound)return NO;
    const char *utf8=text.UTF8String; if(utf8==nullptr)return NO;
    [_engine message:SCI_CALLTIPSHOW wParam:[_engine message:SCI_GETCURRENTPOS] lParam:(sptr_t)utf8];
    return YES;
}
- (BOOL)showCompletions:(NSArray<NSString *> *)words {
    [self assertThread]; if(![words isKindOfClass:NSArray.class] || words.count==0)return NO;
    sptr_t caret=[_engine message:SCI_GETCURRENTPOS],start=[_engine message:SCI_WORDSTARTPOSITION wParam:caret lParam:1];
    NSMutableArray *safe=[NSMutableArray array];
    for(id word in words)
        if([word isKindOfClass:NSString.class] && [word rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location==NSNotFound && [word rangeOfString:@"\0"].location==NSNotFound && [word UTF8String]!=nullptr)
            [safe addObject:word];
    NSString *list=[[safe sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "];
    if(!list.length)return NO;
    // G371: once the list is open Scintilla records Tab, Return and the arrow keys as caret
    // commands although they drive the list, and accepting an entry edits with no notification.
    if (_macroRecording && _onMacroStep) [self reportMacroStep:TTUnrecordableStep(SCI_AUTOCSHOW)];
    [_engine message:SCI_AUTOCSHOW wParam:caret-start lParam:(sptr_t)list.UTF8String];
    return YES;
}
- (BOOL)find:(NSString *)text matchCase:(BOOL)matchCase backwards:(BOOL)backwards {
    [self assertThread];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return NO;
    [_engine message:SCI_SETSEARCHFLAGS wParam:matchCase ? SCFIND_MATCHCASE : 0];
    sptr_t length = [_engine message:SCI_GETLENGTH];
    sptr_t position = [_engine message:backwards ? SCI_GETSELECTIONSTART : SCI_GETSELECTIONEND];
    [_engine message:SCI_SETTARGETRANGE wParam:position lParam:backwards ? 0 : length];
    sptr_t found = [_engine message:SCI_SEARCHINTARGET wParam:data.length lParam:(sptr_t)data.bytes];
    if (found < 0) {
        [_engine message:SCI_SETTARGETRANGE wParam:backwards ? length : 0 lParam:position];
        found = [_engine message:SCI_SEARCHINTARGET wParam:data.length lParam:(sptr_t)data.bytes];
    }
    if (found < 0) return NO;
    [_engine message:SCI_SETSEL wParam:[_engine message:SCI_GETTARGETSTART] lParam:[_engine message:SCI_GETTARGETEND]];
    [_engine message:SCI_SCROLLCARET];
    [self noteStateChange];
    return YES;
}
- (BOOL)canBeginPairing { return _autoPairEnabled && ![_engine message:SCI_AUTOCACTIVE]; }
// Scintilla inserts at each caret from right to left. Its insert-check and actual insertion
// notifications use the original positions; the engine tracks all final selections.
- (BOOL)canPairAt:(sptr_t)position length:(sptr_t)length quote:(BOOL)quote {
    if (position < length) {
        const unsigned char next = (unsigned char)[_engine message:SCI_GETCHARAT wParam:position];
        if (next < 0x80) {
            if (next != ' ' && !(next >= 9 && next <= 13)) return NO;
        } else {
            const sptr_t end = [_engine message:SCI_POSITIONAFTER wParam:position];
            if (end <= position || end-position > 4) return NO;
            char bytes[4];
            for (sptr_t i = position; i < end; ++i) bytes[i-position] = [_engine message:SCI_GETCHARAT wParam:i];
            NSString *character = [[NSString alloc] initWithBytes:bytes length:end-position encoding:NSUTF8StringEncoding];
            if (!character || [character rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound) return NO;
        }
    }
    if (quote) {
        sptr_t count = 0;
        while (count < position && count < 128 && [_engine message:SCI_GETCHARAT wParam:position-count-1] == '\\') ++count;
        if (count == 128 && count < position && [_engine message:SCI_GETCHARAT wParam:position-count-1] == '\\') return NO;
        if (count & 1) return NO;
    }
    return YES;
}
- (void)performPair:(NSString *)input closer:(char)closer commit:(void (NS_NOESCAPE ^)(void))commit {
    if (!closer || !_autoPairEnabled || _eligiblePairPositions || self.readOnly || [_engine message:SCI_AUTOCACTIVE] ||
        [_engine message:SCI_GETOVERTYPE] || [_engine message:SCI_GETSELECTIONMODE] != SC_SEL_STREAM ||
        ![_engine message:SCI_GETSELECTIONEMPTY]) { commit(); return; }
    const sptr_t count = [_engine message:SCI_GETSELECTIONS], length = [_engine message:SCI_GETLENGTH];
    if (count > 1 && ![_engine message:SCI_GETADDITIONALSELECTIONTYPING]) { commit(); return; }
    NSMutableIndexSet *eligible = [NSMutableIndexSet indexSet];
    std::vector<sptr_t> original;
    for (sptr_t i = 0; i < count; ++i) {
        const sptr_t position = [_engine message:SCI_GETSELECTIONNCARET wParam:i];
        original.push_back(position);
        if ([_engine message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:i] ||
            [_engine message:SCI_GETSELECTIONNANCHORVIRTUALSPACE wParam:i]) { commit(); return; }
        if ([self canPairAt:position length:length quote:closer == '"' || closer == 0x27]) [eligible addIndex:position];
    }
    if (!eligible.count) { commit(); return; }
    _eligiblePairPositions = eligible;
    _insertedPairPositions = [NSMutableIndexSet indexSet];
    _pairBytes[0] = (char)[input characterAtIndex:0];
    _pairBytes[1] = closer;
    [self openUndoGroup];
    @try {
        commit();
        if (count != [_engine message:SCI_GETSELECTIONS]) return;
        for (sptr_t i = 0; i < count; ++i) {
            if (![_insertedPairPositions containsIndex:original[i]]) continue;
            const sptr_t between = [_engine message:SCI_GETSELECTIONNCARET wParam:i]-1;
            [_engine message:SCI_SETSELECTIONNCARET wParam:i lParam:between];
            [_engine message:SCI_SETSELECTIONNANCHOR wParam:i lParam:between];
        }
        if (_macroRecording && count == 1 && _insertedPairPositions.count) {
            [self reportMacroStep:[TTMacroAction insertText:[[NSString alloc] initWithBytes:&closer length:1 encoding:NSASCIIStringEncoding]]];
            [self reportMacroStep:[TTMacroAction command:@"charLeft"]];
        }
    } @finally {
        _eligiblePairPositions = nil;
        _insertedPairPositions = nil;
        [self closeUndoGroup];
    }
}
// NewLine inserts once per caret. Changing that insertion keeps the engine in charge of selection
// replacement, EOL mode, caret movement and Undo. Paste and macro playback never enter this scope.
- (void)performReturn:(void (NS_NOESCAPE ^)(void))nativeReturn {
    if (!_autoIndentEnabled || _indentingReturn || self.readOnly || [_engine message:SCI_AUTOCACTIVE]) {
        nativeReturn();
        return;
    }
    [self openUndoGroup];
    _indentingReturn = YES;
    @try {
        nativeReturn();
        // Scintilla records the original EOL, one byte at a time, after all carets have moved.
        if (_recordedReturnIndent && _macroRecording) {
            [self reportMacroStep:[TTMacroAction insertText:_recordedReturnIndent]];
        }
    } @finally {
        _indentingReturn = NO;
        _recordedReturnIndent = nil;
        [self closeUndoGroup];
    }
}
- (void)inheritIndentAtInsertion:(const SCNotification *)change {
    const char *eol = change->text;
    if (!eol || !((change->length == 1 && (eol[0] == '\r' || eol[0] == '\n')) ||
                  (change->length == 2 && eol[0] == '\r' && eol[1] == '\n'))) return;
    const sptr_t position = change->position;
    const sptr_t line = [_engine message:SCI_LINEFROMPOSITION wParam:position];
    const sptr_t start = [_engine message:SCI_POSITIONFROMLINE wParam:line];
    // If Return splits the indentation, the original suffix already follows the new caret.
    if (start >= position) return;
    // Short contiguous reads also avoid moving the document's gap across a long, unindented line.
    NSMutableData *insertion = nil;
    for (sptr_t cursor = start; cursor < position;) {
        const sptr_t count = MIN(position - cursor, 256);
        const char *bytes = (const char *)[_engine message:SCI_GETRANGEPOINTER wParam:cursor lParam:count];
        sptr_t indent = 0;
        while (indent < count && (bytes[indent] == ' ' || bytes[indent] == '\t')) ++indent;
        if (indent) {
            if (!insertion) insertion = [NSMutableData dataWithBytes:eol length:change->length];
            [insertion appendBytes:bytes length:indent];
        }
        if (indent < count) break;
        cursor += count;
    }
    if (!insertion) return;
    if (_macroRecording && self.selectionCount == 1 && ![_engine message:SCI_GETOVERTYPE]) {
        const char *bytes = (const char *)insertion.bytes + change->length;
        _recordedReturnIndent = [[NSString alloc] initWithBytes:bytes length:insertion.length-change->length
                                                      encoding:NSASCIIStringEncoding];
    }
    [_engine message:SCI_CHANGEINSERTION wParam:insertion.length lParam:(sptr_t)insertion.bytes];
}
- (void)performNativeMacroInput:(void (NS_NOESCAPE ^)(void))input {
    // Cocoa's text system can call the backend directly. Wait for Scintilla's matching
    // literal notification, which follows the bytes, before accepting this input transaction.
    if (!_macroRecording || _inNativeMacroInput) { input(); return; }
    _inNativeMacroInput = YES;
    _retiredNativeMacroInput = NO;
    _nativeInputChanged = _nativeInputReported = NO;
    @try { input(); }
    @finally {
        _inNativeMacroInput = NO;
        if (_macroRecording && !_retiredNativeMacroInput && _nativeInputChanged && !_nativeInputReported)
            [self reportMacroStep:[TTMacroAction unsupported:@"Native input without a recorded macro step" message:0]];
    }
}
- (BOOL)confirmRecordedSearchReplacement {
    [self assertThread];
    if (!_pendingMacroSearch) return NO;
    _pendingMacroSearch = nil;
    return YES;
}
// Identical targets can notify Delete followed by Insert. Compare explicit UTF-8 ranges in
// fixed-size pages before the first change, without relocating Scintilla's gap or allocating.
- (BOOL)macroTargetIsUnchanged:(TTMacroMessage &)frame {
    if (frame.targetCompared) return frame.targetUnchanged;
    frame.targetCompared = true;
    if (frame.message != SCI_REPLACETARGET || !frame.data) return NO;
    const sptr_t begin = [frame.source message:SCI_GETTARGETSTART], end = [frame.source message:SCI_GETTARGETEND];
    if (begin < 0 || end < begin || (uptr_t)(end - begin) != frame.length) return NO;
    char chunk[4097];
    for (sptr_t pos = begin; pos < end;) {
        const sptr_t next = pos + std::min<sptr_t>(end - pos, sizeof(chunk) - 1);
        Sci_TextRangeFull range = {{pos, next}, chunk};
        if ([frame.source message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&range] != next - pos ||
            std::memcmp(chunk, (const char *)frame.data + (pos - begin), (size_t)(next - pos))) return NO;
        pos = next;
    }
    frame.targetUnchanged = true;
    return YES;
}
- (void)notification:(SCNotification *)notification {
    const unsigned int code = notification->nmhdr.code;
    if (code == SCN_PAINTED && _pendingWrappedViewport) {
        BOOL (^apply)(BOOL) = _pendingWrappedViewport;
        _pendingWrappedViewport = nil;
        apply(YES);
    }
    const int type = notification->modificationType;
    TTMacroMessage *frame = TTActiveMacroMessage;
    if (_macroRecording && _onMacroStep && !frame && code == SCN_MODIFIED &&
        (type & (SC_MOD_BEFOREINSERT | SC_MOD_BEFOREDELETE)) && !(type & (SC_PERFORMED_UNDO | SC_PERFORMED_REDO))) {
        if (_inNativeMacroInput && _retiredNativeMacroInput)
            [self reportMacroStep:[TTMacroAction unsupported:@"Native input crossed the start of this recording" message:0]];
        else if (_inNativeMacroInput) _nativeInputChanged = YES;
        else if (TTActiveMouseInteraction) [self reportUnrecordedMouseInteraction];
        else [self reportMacroStep:[TTMacroAction unsupported:@"A native editing operation without a recorded macro step" message:0]];
    }
    if (_macroRecording && _onMacroStep && frame && code == SCN_MODIFIED &&
        (type & (SC_MOD_BEFOREINSERT | SC_MOD_BEFOREDELETE)) && !(frame->source == _engine && frame->sourceStepReported)) {
        // A clone gets its own notification for this same native document. Its source cannot
        // supply steps to this view's recorder. The underlying exposure is per document.
        if (frame->source == _engine && frame->search &&
            (!_pendingMacroSearch || _pendingMacroSearch == frame->search)) {
            _pendingMacroSearch = frame->search;
        } else if (frame->source == _engine && frame->message == SCI_NEWLINE) {
            // Scintilla reports its literal EOL(s) after insertion, followed by the inherited indent.
        } else if ([self macroTargetIsUnchanged:*frame]) {
            // A same-byte target replacement is a textual no-op.
        } else {
            [self reportMacroStep:[TTMacroAction unsupported:@"An editing operation without a recorded macro step" message:frame->message]];
        }
    }
    if (_braceCacheValid && _braceHighlightEnabled && !_comparisonPresentation &&
        code == SCN_MODIFIED && (type & (SC_MOD_CHANGESTYLE | SC_MOD_LEXERSTATE))) {
        _braceCacheValid = NO;
        [self scheduleStateNotification];
    }
    if (_eligiblePairPositions && code == SCN_MODIFIED &&
        [_eligiblePairPositions containsIndex:notification->position] && notification->text) {
        if ((type & SC_MOD_INSERTCHECK) && notification->length == 1 && notification->text[0] == _pairBytes[0]) {
            [_engine message:SCI_CHANGEINSERTION wParam:2 lParam:(sptr_t)_pairBytes];
        } else if ((type & SC_MOD_INSERTTEXT) && notification->length == 2 && !memcmp(notification->text, _pairBytes, 2)) {
            [_insertedPairPositions addIndex:notification->position];
        }
    }
    if (_indentingReturn && code == SCN_MODIFIED && (type & SC_MOD_INSERTCHECK)) {
        [self inheritIndentAtInsertion:notification];
    }
    // Scintilla notifies after every paint, which includes every caret blink. The filler line
    // numbers are compared, not redrawn, and for a modification only when its lines changed.
    if (code == SCN_PAINTED || code == SCN_UPDATEUI || code == SCN_ZOOM ||
        (code == SCN_MODIFIED && (notification->linesAdded != 0 || (type & SC_MOD_CHANGEFOLD)))) [self invalidateLineNumbersIfChanged];
    if (code == SCN_PAINTED && _paddedScrollWidth) [self updateScrollRangePad];
    // Native responder Undo/Redo bypasses the application command dispatcher and
    // Scintilla does not emit MacroRecord for these operations. Never save a macro
    // that silently omits their changes.
    if (_macroRecording && _onMacroStep && code == SCN_MODIFIED &&
        (type & (SC_PERFORMED_UNDO | SC_PERFORMED_REDO))) {
        [self reportMacroStep:TTUnrecordableStep(type & SC_PERFORMED_UNDO ? SCI_UNDO : SCI_REDO)];
    }
    // Scrolling by a line edits nothing and moves no caret; like zoom it is neither recorded nor a
    // reason to discard.
    const BOOL viewOnly = code == SCN_MACRORECORD && (notification->message == SCI_LINESCROLLUP || notification->message == SCI_LINESCROLLDOWN ||
        notification->message == SCI_SCROLLTOSTART || notification->message == SCI_SCROLLTOEND || notification->message == SCI_VERTICALCENTRECARET);
    if (code == SCN_MACRORECORD && _onMacroStep && !viewOnly) {
        TTMacroAction *step = nil;
        // G371: a typed character is replayed as an insertion, which is not what Overtype did.
        if (notification->message == SCI_REPLACESEL && [_engine message:SCI_GETOVERTYPE]) {
        } else if (notification->message == SCI_REPLACESEL && notification->lParam && self.selectionCount == 1) {
            const char *utf8 = (const char *)notification->lParam;
            NSString *text = TTStringFromUTF8(utf8, std::strlen(utf8));
            if (text.length) step = [TTMacroAction insertText:text];
        } else {
            NSString *name = TTMacroNamesByMessage()[@(notification->message)];
            if (name) step = [TTMacroAction command:name];
        }
        if (_inNativeMacroInput && !frame) _nativeInputReported = YES;
        if (step && frame && frame->source == _engine && frame->message == (unsigned int)notification->message)
            frame->sourceStepReported = YES;
        [self reportMacroStep:step ?: TTUnrecordableStep(notification->message)];
    }
    if (code == SCN_FOCUSIN) { if (_onFocus) _onFocus(); [self scheduleStateNotification]; }
    if (code == SCN_MODIFYATTEMPTRO && _onReadOnlyAttempt) _onReadOnlyAttempt();
    // Keep the line-number margin wide enough: zoom rescales its font, and added or removed lines
    // change the digit count. A margin width is view state, so setting it here edits nothing.
    // The filler numbers are drawn at the zoomed size, which the compared values need not show.
    if (code == SCN_ZOOM) { _followsDefaultZoom = self.zoomLevel == _defaultZoomLevel; [self updateLineNumberMargin:NO]; [self updateCenteredColumn]; _emptyLineNumbers.needsDisplay = YES; [self scheduleStateNotification]; }
    else if (code == SCN_MODIFIED && notification->linesAdded != 0 && [self lineNumberDigits] != _marginDigits) [self updateLineNumberMargin:NO];
    if (code == SCN_ZOOM || (code == SCN_UPDATEUI && (notification->updated & (SC_UPDATE_V_SCROLL | SC_UPDATE_H_SCROLL)))) [self comparisonViewportChanged];
    if (code == SCN_UPDATEUI) {
        if (notification->updated & SC_UPDATE_SELECTION) _selectionGeneration++;
        if (notification->updated & (SC_UPDATE_SELECTION | SC_UPDATE_CONTENT)) [self scheduleStateNotification];
    }
    if (_heldSelection && code == SCN_MODIFIED && (type & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
        [self moveHeldPlaceAt:notification->position length:notification->length inserted:(type & SC_MOD_INSERTTEXT) != 0];
    }
    if (code == SCN_MODIFIED && (type & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
        // Every stale-result guard compares `revision`, so it advances with each step. The
        // callback is delivered once per outermost undo group and once per multi-step Undo or Redo.
        _revision++;
        _selectionGeneration++;
        const BOOL earlierUndoStep = (type & SC_MULTISTEPUNDOREDO) && !(type & SC_LASTSTEPINUNDOREDO);
        if (earlierUndoStep || [self undoGroupOpen]) [self deferChange]; else [self deliverChange];
        [self scheduleStateNotification];
    } else if (code == SCN_SAVEPOINTLEFT || code == SCN_SAVEPOINTREACHED) {
        if ([self undoGroupOpen]) [self deferChange]; else [self deliverChange];
        [self scheduleStateNotification];
    } else if (code == SCN_MODIFIED && (type & SC_LASTSTEPINUNDOREDO) && _changeDeferred && ![self undoGroupOpen]) {
        [self deliverDeferredChange];
    }
}
@end
