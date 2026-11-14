// SPDX-License-Identifier: GPL-3.0-or-later
#import "TTEditor.h"
#import "ScintillaView.h"
#include "ILexer.h"
#include "Lexilla.h"
#include <vector>

@interface TTEditor () <ScintillaNotificationProtocol>
@property(nonatomic, strong) ScintillaView *engine;
@property(nonatomic, readwrite) NSUInteger revision;
@end
@implementation TTEditor
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSAssert(NSThread.isMainThread, @"Editor must be created on the main thread");
        _engine = [[ScintillaView alloc] initWithFrame:self.bounds];
        _engine.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_engine];
        _engine.delegate = self;
        [_engine message:SCI_SETCODEPAGE wParam:SC_CP_UTF8];
        [_engine setFontName:@"Menlo" size:14 bold:NO italic:NO];
        [_engine message:SCI_STYLESETFORE wParam:STYLE_DEFAULT lParam:0x1F2015];
        [_engine message:SCI_STYLESETBACK wParam:STYLE_DEFAULT lParam:0xF0F6F4];
        [_engine message:SCI_STYLECLEARALL];
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
    }
    return self;
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
    return [[NSString alloc] initWithBytes:bytes.data() length:(NSUInteger)length encoding:NSUTF8StringEncoding] ?: @"";
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
    return [[NSString alloc] initWithData:joined encoding:NSUTF8StringEncoding] ?: @"";
}
- (NSInteger)selectionCount { [self assertThread]; return [_engine message:SCI_GETSELECTIONS]; }
- (NSInteger)selectionStart { [self assertThread]; return [_engine message:SCI_GETSELECTIONSTART]; }
- (NSInteger)selectionEnd { [self assertThread]; return [_engine message:SCI_GETSELECTIONEND]; }
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
    NSNumber *message = commands[identifier];
    if (message) [_engine message:message.unsignedIntValue];
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
    for (int style : {1, 2, 3}) [_engine message:SCI_STYLESETFORE wParam:style lParam:0x47804B];
    for (int style : {5, 11, 17}) [_engine message:SCI_STYLESETFORE wParam:style lParam:0xA04470];
    for (int style : {6, 7, 13}) [_engine message:SCI_STYLESETFORE wParam:style lParam:0x255EA0];
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
