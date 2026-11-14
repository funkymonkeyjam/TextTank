// SPDX-License-Identifier: GPL-3.0-or-later
#import "TTEditor.h"
#import "ScintillaView.h"
#include "ILexer.h"
#include "Lexilla.h"
#include <vector>
#include <cstring>

// NSString's UTF-8 constructors consume a leading EF BB BF as an external BOM.
// Editor bytes are already decoded content, so U+FEFF must remain ordinary text.
// A temporary ASCII prefix prevents that interpretation; remove only that prefix.
static NSString *TTStringFromUTF8(const void *bytes, NSUInteger length) {
    NSMutableData *prefixed = [NSMutableData dataWithCapacity:length + 1];
    const unsigned char sentinel = 'x';
    [prefixed appendBytes:&sentinel length:1];
    if (length) [prefixed appendBytes:bytes length:length];
    NSString *decoded = [[NSString alloc] initWithData:prefixed encoding:NSUTF8StringEncoding];
    NSCAssert(decoded != nil, @"Scintilla content must remain valid UTF-8");
    return decoded ? [decoded substringFromIndex:1] : @"";
}

// Scintilla's document canvas can be much wider than the viewport. Exposing its
// full NSView frame makes accessibility clients aim outside the visible editor.
// Preserve native text/input behavior while describing its visible screen region.
@interface TTContentView : SCIContentView
@end
@implementation TTContentView
- (NSRect)accessibilityFrame {
    if (!self.window) return NSZeroRect;
    return [self.window convertRectToScreen:[self convertRect:self.visibleRect toView:nil]];
}
@end
@interface TTScintillaView : ScintillaView
@end
@implementation TTScintillaView
+ (Class)contentViewClass { return TTContentView.class; }
@end

static NSDictionary<NSString *, NSNumber *> *TTMacroCommands() {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = @{
        @"cut":@(SCI_CUT), @"copy":@(SCI_COPY), @"paste":@(SCI_PASTE), @"selectAll":@(SCI_SELECTALL),
        @"duplicateLine":@(SCI_LINEDUPLICATE), @"deleteLine":@(SCI_LINEDELETE), @"transposeLine":@(SCI_LINETRANSPOSE),
        @"upper":@(SCI_UPPERCASE), @"lower":@(SCI_LOWERCASE),
        @"charLeft":@(SCI_CHARLEFT), @"charRight":@(SCI_CHARRIGHT), @"lineUp":@(SCI_LINEUP), @"lineDown":@(SCI_LINEDOWN),
        @"home":@(SCI_HOME), @"lineEnd":@(SCI_LINEEND), @"documentStart":@(SCI_DOCUMENTSTART), @"documentEnd":@(SCI_DOCUMENTEND),
        @"wordLeft":@(SCI_WORDLEFT), @"wordRight":@(SCI_WORDRIGHT),
        @"charLeftExtend":@(SCI_CHARLEFTEXTEND), @"charRightExtend":@(SCI_CHARRIGHTEXTEND), @"lineUpExtend":@(SCI_LINEUPEXTEND), @"lineDownExtend":@(SCI_LINEDOWNEXTEND),
        @"homeExtend":@(SCI_HOMEEXTEND), @"lineEndExtend":@(SCI_LINEENDEXTEND), @"documentStartExtend":@(SCI_DOCUMENTSTARTEXTEND), @"documentEndExtend":@(SCI_DOCUMENTENDEXTEND),
        @"wordLeftExtend":@(SCI_WORDLEFTEXTEND), @"wordRightExtend":@(SCI_WORDRIGHTEXTEND),
        @"deleteBack":@(SCI_DELETEBACK), @"deleteForward":@(SCI_CLEAR), @"newLine":@(SCI_NEWLINE), @"tab":@(SCI_TAB), @"backTab":@(SCI_BACKTAB)
    }; });
    return map;
}

@interface TTEditor () <ScintillaNotificationProtocol>
@property(nonatomic, strong) ScintillaView *engine;
@property(nonatomic, readwrite) NSUInteger revision;
@property(nonatomic) BOOL macroRecording;
@end
@implementation TTEditor
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSAssert(NSThread.isMainThread, @"Editor must be created on the main thread");
        _engine = [[TTScintillaView alloc] initWithFrame:NSZeroRect];
        _engine.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_engine];
        _engine.delegate = self;
        [_engine message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
        [_engine setFontName:@"Menlo" size:14 bold:NO italic:NO];
        [self applyPalette];
        [_engine message:SCI_SETMARGINTYPEN wParam:0 lParam:SC_MARGIN_NUMBER];
        [_engine message:SCI_SETMARGINWIDTHN wParam:0 lParam:48];
        [_engine message:SCI_MARKERDEFINE wParam:1 lParam:SC_MARK_CIRCLE];
        [_engine message:SCI_MARKERSETBACK wParam:1 lParam:0x005B3A];
        [_engine message:SCI_SETMARGINTYPEN wParam:1 lParam:SC_MARGIN_SYMBOL];
        [_engine message:SCI_SETMARGINMASKN wParam:1 lParam:(1 << 1)];
        [_engine message:SCI_SETMARGINWIDTHN wParam:1 lParam:14];
        [_engine message:SCI_SETMULTIPLESELECTION wParam:1];
        [_engine message:SCI_SETADDITIONALSELECTIONTYPING wParam:1];
        [_engine message:SCI_SETMULTIPASTE wParam:SC_MULTIPASTE_EACH];
        [_engine message:SCI_SETTABWIDTH wParam:4];
        [_engine message:SCI_SETPROPERTY wParam:(uptr_t)"fold" lParam:(sptr_t)"1"];
        [_engine message:SCI_SETMARGINTYPEN wParam:2 lParam:SC_MARGIN_SYMBOL];
        [_engine message:SCI_SETMARGINMASKN wParam:2 lParam:SC_MASK_FOLDERS];
        [_engine message:SCI_SETMARGINWIDTHN wParam:2 lParam:16];
        [_engine message:SCI_SETMARGINSENSITIVEN wParam:2 lParam:1];
        [_engine message:SCI_SETAUTOMATICFOLD wParam:SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];
        // Scintilla creates its scroll view at 100x10. Its initWithFrame does not
        // position the inner content. Start at zero so this real size transition also
        // invokes backend Resize, which initializes the document viewport.
        _engine.frame = self.bounds;
    }
    return self;
}
- (void)layout {
    [super layout];
    _engine.frame = self.bounds;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    if (_engine) [self applyPalette];
}
- (void)applyPalette {
    BOOL dark = [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    const sptr_t foreground = dark ? 0xF0F6F4 : 0x1F2015;
    const sptr_t background = dark ? 0x171810 : 0xF0F6F4;
    [_engine message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:foreground];
    [_engine message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:background];
    [_engine message:SCI_STYLECLEARALL];
    [_engine message:SCI_STYLESETFORE wParam:STYLE_LINENUMBER lParam:dark ? 0xAAB8B3 : 0x59645F];
    [_engine message:SCI_STYLESETBACK wParam:STYLE_LINENUMBER lParam:dark ? 0x222A25 : 0xE3E9E5];
    [_engine message:SCI_SETCARETFORE wParam:foreground];
    [_engine message:SCI_SETSELFORE wParam:1 lParam:dark ? 0xFFFFFF : 0x101010];
    [_engine message:SCI_SETSELBACK wParam:1 lParam:dark ? 0x725038 : 0xF1D4AF];
    for (int style : {1, 2, 3}) [_engine message:SCI_STYLESETFORE wParam:style lParam:dark ? 0x9BC18E : 0x47804B];
    for (int style : {5, 11, 17}) [_engine message:SCI_STYLESETFORE wParam:style lParam:dark ? 0xDBA6C9 : 0xA04470];
    for (int style : {6, 7, 13}) [_engine message:SCI_STYLESETFORE wParam:style lParam:dark ? 0x8ACFE8 : 0x255EA0];
    _engine.needsDisplay = YES;
}
- (void)dealloc { _engine.delegate = nil; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return [self.window makeFirstResponder:self.engine.content]; }
- (void)assertThread { NSAssert(NSThread.isMainThread, @"Editor calls require the main thread"); }
- (NSString *)text {
    [self assertThread];
    const sptr_t length = [_engine message:SCI_GETLENGTH];
    std::vector<char> bytes((size_t)length + 1);
    [_engine message:SCI_GETTEXT wParam:bytes.size() lParam:(sptr_t)bytes.data()];
    return TTStringFromUTF8(bytes.data(), (NSUInteger)length);
}
- (void)setText:(NSString *)text {
    [self assertThread];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [_engine message:SCI_BEGINUNDOACTION];
    [_engine message:SCI_SETTARGETRANGE wParam:0 lParam:[_engine message:SCI_GETLENGTH]];
    [_engine message:SCI_REPLACETARGET wParam:data.length lParam:(sptr_t)data.bytes];
    [_engine message:SCI_ENDUNDOACTION];
}
- (NSString *)selectedText {
    [self assertThread];
    NSMutableData *joined = [NSMutableData data];
    const sptr_t count = [_engine message:SCI_GETSELECTIONS];
    for (sptr_t selection = 0; selection < count; ++selection) {
        sptr_t start = [_engine message:SCI_GETSELECTIONNSTART wParam:selection];
        sptr_t end = [_engine message:SCI_GETSELECTIONNEND wParam:selection];
        std::vector<char> bytes((size_t)(end-start) + 1);
        Sci_TextRangeFull range = {{start, end}, bytes.data()};
        [_engine message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&range];
        if (selection) [joined appendBytes:"\n" length:1];
        [joined appendBytes:bytes.data() length:(NSUInteger)(end-start)];
    }
    return TTStringFromUTF8(joined.bytes, joined.length);
}
- (NSInteger)selectionCount { [self assertThread]; return [_engine message:SCI_GETSELECTIONS]; }
- (NSInteger)selectionStart { [self assertThread]; return [_engine message:SCI_GETSELECTIONSTART]; }
- (NSInteger)selectionEnd { [self assertThread]; return [_engine message:SCI_GETSELECTIONEND]; }
- (NSInteger)selectionAnchor { [self assertThread]; return [_engine message:SCI_GETANCHOR]; }
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
    return YES;
}
- (NSArray<NSNumber *> *)bookmarkLines {
    [self assertThread];
    NSMutableArray<NSNumber *> *lines = [NSMutableArray array];
    sptr_t line = [_engine message:SCI_MARKERNEXT wParam:0 lParam:(1 << 1)];
    while (line >= 0) {
        [lines addObject:@(line)];
        line = [_engine message:SCI_MARKERNEXT wParam:line+1 lParam:(1 << 1)];
    }
    return lines;
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
    [_engine message:SCI_MARKERDELETEALL wParam:1];
    for (NSNumber *line in seen) [_engine message:SCI_MARKERADD wParam:line.integerValue lParam:1];
    return YES;
}
- (BOOL)modified { [self assertThread]; return [_engine message:SCI_GETMODIFY] != 0; }
- (void)setSavePoint { [self assertThread]; [_engine message:SCI_SETSAVEPOINT]; }
- (void)resetUndoHistory { [self assertThread]; [_engine message:SCI_EMPTYUNDOBUFFER]; }
- (BOOL)wrap { [self assertThread]; return [_engine message:SCI_GETWRAPMODE] != SC_WRAP_NONE; }
- (void)setWrap:(BOOL)wrap { [self assertThread]; [_engine message:SCI_SETWRAPMODE wParam:wrap ? SC_WRAP_WORD : SC_WRAP_NONE]; }
- (void)shareDocumentWith:(TTEditor *)other {
    [self assertThread];
    // SCI_SETDOCPOINTER acquires the new document before releasing the old one.
    // Each attached Scintilla view owns a reference, so either view may close first.
    [_engine message:SCI_SETDOCPOINTER wParam:0 lParam:[other.engine message:SCI_GETDOCPOINTER]];
    self.revision = other.revision;
}
- (void)replaceSelection:(NSString *)text {
    [self assertThread];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [_engine message:SCI_BEGINUNDOACTION];
    [_engine message:SCI_TARGETFROMSELECTION];
    const sptr_t start = [_engine message:SCI_GETTARGETSTART];
    [_engine message:SCI_REPLACETARGET wParam:data.length lParam:(sptr_t)data.bytes];
    [_engine message:SCI_SETSEL wParam:start + data.length lParam:start + data.length];
    [_engine message:SCI_ENDUNDOACTION];
}
- (void)executeCommand:(NSString *)identifier {
    [self assertThread];
    if ([identifier isEqualToString:@"foldAll"] || [identifier isEqualToString:@"unfoldAll"]) {
        [_engine message:SCI_COLOURISE wParam:0 lParam:-1];
        [_engine message:SCI_FOLDALL wParam:[identifier isEqualToString:@"foldAll"] ? SC_FOLDACTION_CONTRACT : SC_FOLDACTION_EXPAND];
        return;
    }
    if ([identifier isEqualToString:@"showWhitespace"]) {
        [_engine message:SCI_SETVIEWWS wParam:[_engine message:SCI_GETVIEWWS] ? SCWS_INVISIBLE : SCWS_VISIBLEALWAYS]; return;
    }
    if ([identifier isEqualToString:@"toggleEOL"]) {
        [_engine message:SCI_SETVIEWEOL wParam:![_engine message:SCI_GETVIEWEOL]]; return;
    }
    if ([identifier isEqualToString:@"toggleLineNumbers"]) {
        [_engine message:SCI_SETMARGINWIDTHN wParam:0 lParam:[_engine message:SCI_GETMARGINWIDTHN wParam:0] ? 0 : 48]; return;
    }
    if ([identifier isEqualToString:@"toggleOvertype"]) {
        [_engine message:SCI_SETOVERTYPE wParam:![_engine message:SCI_GETOVERTYPE]]; return;
    }
    if ([identifier isEqualToString:@"joinLines"]) {
        [_engine message:SCI_TARGETFROMSELECTION];
        [_engine message:SCI_LINESJOIN]; return;
    }
    if ([identifier isEqualToString:@"trimTrailing"]) {
        [_engine message:SCI_BEGINUNDOACTION];
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
        [_engine message:SCI_ENDUNDOACTION]; return;
    }
    if ([identifier isEqualToString:@"gotoMatchingBrace"] || [identifier isEqualToString:@"selectMatchingBrace"]) {
        sptr_t position = [_engine message:SCI_GETCURRENTPOS];
        sptr_t match = [_engine message:SCI_BRACEMATCH wParam:position lParam:0];
        if (match < 0 && position > 0) { --position; match = [_engine message:SCI_BRACEMATCH wParam:position lParam:0]; }
        if (match >= 0) {
            if ([identifier isEqualToString:@"selectMatchingBrace"]) [_engine message:SCI_SETSEL wParam:MIN(position,match) lParam:MAX(position,match)+1];
            else [_engine message:SCI_GOTOPOS wParam:match];
            [_engine message:SCI_SCROLLCARET];
        }
        return;
    }
    if ([identifier hasPrefix:@"bookmark"]) {
        sptr_t line = [_engine message:SCI_LINEFROMPOSITION wParam:[_engine message:SCI_GETCURRENTPOS]];
        if ([identifier isEqualToString:@"bookmarkToggle"]) {
            [_engine message:([_engine message:SCI_MARKERGET wParam:line] & (1 << 1)) ? SCI_MARKERDELETE : SCI_MARKERADD wParam:line lParam:1];
        } else if ([identifier isEqualToString:@"bookmarkNext"] || [identifier isEqualToString:@"bookmarkPrevious"]) {
            BOOL next = [identifier isEqualToString:@"bookmarkNext"];
            sptr_t found = (!next && line == 0) ? -1 : [_engine message:next ? SCI_MARKERNEXT : SCI_MARKERPREVIOUS wParam:next ? line+1 : line-1 lParam:(1 << 1)];
            if (found < 0) found = [_engine message:next ? SCI_MARKERNEXT : SCI_MARKERPREVIOUS wParam:next ? 0 : [_engine message:SCI_GETLINECOUNT]-1 lParam:(1 << 1)];
            if (found >= 0) { [_engine message:SCI_ENSUREVISIBLE wParam:found]; [_engine message:SCI_GOTOLINE wParam:found]; }
        }
        return;
    }
    static NSDictionary<NSString *, NSNumber *> *commands;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ commands = @{
        @"undo": @(SCI_UNDO), @"redo": @(SCI_REDO), @"cut": @(SCI_CUT),
        @"copy": @(SCI_COPY), @"paste": @(SCI_PASTE), @"selectAll": @(SCI_SELECTALL),
        @"duplicateLine": @(SCI_LINEDUPLICATE), @"deleteLine": @(SCI_LINEDELETE),
        @"transposeLine": @(SCI_LINETRANSPOSE), @"indent": @(SCI_TAB),
        @"unindent": @(SCI_BACKTAB), @"upper": @(SCI_UPPERCASE), @"lower": @(SCI_LOWERCASE),
        @"zoomIn": @(SCI_ZOOMIN), @"zoomOut": @(SCI_ZOOMOUT),
        @"moveLineUp": @(SCI_MOVESELECTEDLINESUP), @"moveLineDown": @(SCI_MOVESELECTEDLINESDOWN)}; });
    NSNumber *message = commands[identifier] ?: TTMacroCommands()[identifier];
    if (message) [_engine message:message.unsignedIntValue];
}
- (void)startRecording { [self assertThread]; _macroRecording = YES; [_engine message:SCI_STARTRECORD]; }
- (void)stopRecording { [self assertThread]; _macroRecording = NO; [_engine message:SCI_STOPRECORD]; }
- (void)beginUndoGroup { [self assertThread]; [_engine message:SCI_BEGINUNDOACTION]; }
- (void)endUndoGroup { [self assertThread]; [_engine message:SCI_ENDUNDOACTION]; }
- (BOOL)executeMacroStep:(NSDictionary<NSString *, id> *)step {
    [self assertThread];
    if (![step isKindOfClass:NSDictionary.class]) return NO;
    id kind = step[@"kind"];
    if (![kind isKindOfClass:NSString.class]) return NO;
    if ([kind isEqualToString:@"insertText"]) {
        id text = step[@"text"];
        if (![text isKindOfClass:NSString.class] || self.selectionCount != 1) return NO;
        [self replaceSelection:text]; return YES;
    }
    if ([kind isEqualToString:@"command"]) {
        id command = step[@"command"];
        if (![command isKindOfClass:NSString.class]) return NO;
        // Only symbolic editing commands can reach Scintilla; no imported message
        // number, pointer, executable, or arbitrary parameter is ever dispatched.
        NSNumber *message = TTMacroCommands()[command];
        if (!message && [command isEqualToString:@"indent"]) message = @(SCI_TAB);
        if (!message && [command isEqualToString:@"unindent"]) message = @(SCI_BACKTAB);
        if (!message) return NO;
        [_engine message:message.unsignedIntValue]; return YES;
    }
    return NO;
}
+ (NSArray<NSString *> *)availableLanguages {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int index = 0; index < GetLexerCount(); ++index) {
        char name[128] = {};
        GetLexerName(index, name, sizeof(name));
        NSString *value = [NSString stringWithUTF8String:name];
        if (value) [names addObject:value];
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}
- (void)setLanguage:(NSString *)language {
    [self assertThread];
    auto lexer = CreateLexer(language.UTF8String);
    if (!lexer) lexer = CreateLexer("null");
    [_engine message:SCI_SETILEXER wParam:0 lParam:(sptr_t)lexer];
    [_engine message:SCI_SETPROPERTY wParam:(uptr_t)"fold" lParam:(sptr_t)"1"];
    [_engine message:SCI_SETKEYWORDS wParam:0 lParam:(sptr_t)"if else for while return class struct import func let var true false null int void const static public private"];
    [self applyPalette];
    [_engine message:SCI_COLOURISE wParam:0 lParam:-1];
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
    return YES;
}
- (void)notification:(SCNotification *)notification {
    // Native responder Undo/Redo bypasses the application command dispatcher and
    // Scintilla does not emit MacroRecord for these operations. Never save a macro
    // that silently omits their changes.
    if (_macroRecording && _onMacroStep && notification->nmhdr.code == SCN_MODIFIED &&
        (notification->modificationType & (SC_PERFORMED_UNDO | SC_PERFORMED_REDO))) {
        _onMacroStep(@{@"kind":@"unsupported", @"message":@(notification->modificationType & SC_PERFORMED_UNDO ? SCI_UNDO : SCI_REDO)});
    }
    if (notification->nmhdr.code == SCN_MACRORECORD && _onMacroStep) {
        NSDictionary *step = nil;
        if (notification->message == SCI_REPLACESEL && notification->lParam && self.selectionCount == 1) {
            const char *utf8 = (const char *)notification->lParam;
            NSString *text = TTStringFromUTF8(utf8, std::strlen(utf8));
            if (text.length) step = @{@"kind":@"insertText", @"text":text};
        } else {
            for (NSString *name in TTMacroCommands()) {
                if (TTMacroCommands()[name].unsignedIntValue == notification->message) {
                    step = @{@"kind":@"command", @"command":name}; break;
                }
            }
        }
        _onMacroStep(step ?: @{@"kind":@"unsupported", @"message":@(notification->message)});
    }
    if (notification->nmhdr.code == SCN_FOCUSIN && _onFocus) _onFocus();
    if (notification->nmhdr.code == SCN_MODIFIED &&
        (notification->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
        _revision++;
        if (_onChange) _onChange();
    } else if (notification->nmhdr.code == SCN_SAVEPOINTLEFT || notification->nmhdr.code == SCN_SAVEPOINTREACHED) {
        if (_onChange) _onChange();
    }
}
@end
