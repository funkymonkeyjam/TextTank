// SPDX-License-Identifier: GPL-3.0-or-later
#import "TTEditor.h"
#import "ScintillaView.h"
#include "ILexer.h"
#include "Lexilla.h"
#include <vector>
#include <cstring>
#include <cmath>
extern "C" Scintilla::ILexer5 *TextTankCreateUserLexer();

// NSString's UTF-8 constructors consume a leading EF BB BF as an external BOM.
// Editor bytes are already decoded content, so U+FEFF must remain ordinary text.
// A temporary ASCII prefix prevents that interpretation; remove only that prefix.
// nil means the string cannot be encoded (it holds an unpaired surrogate). Callers must
// reject the edit: messaging nil would replace the target with zero bytes, a silent deletion.
// A nil string keeps its historical meaning of empty text.
static NSData * _Nullable TTUTF8(NSString * _Nullable text) {
    return text ? [text dataUsingEncoding:NSUTF8StringEncoding] : [NSData data];
}
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

// Extend the number gutter through the unused viewport without editing the document.
@interface TTEmptyLineNumbersView : NSView
@property(nonatomic,weak) ScintillaView *engine;
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
    CGFloat size = [engine message:SCI_STYLEGETSIZEFRACTIONAL wParam:STYLE_LINENUMBER] / 100.0 + [engine message:SCI_GETZOOM];
    NSFont *font = [NSFont fontWithName:[NSString stringWithUTF8String:face.data()] size:MAX(1,size)] ?: [NSFont monospacedSystemFontOfSize:MAX(1,size) weight:NSFontWeightRegular];
    NSInteger rgb = [engine message:SCI_STYLEGETFORE wParam:STYLE_LINENUMBER];
    NSColor *color = [NSColor colorWithSRGBRed:(rgb & 255)/255.0 green:((rgb >> 8)&255)/255.0 blue:((rgb >> 16)&255)/255.0 alpha:1];
    NSDictionary *attributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:color};
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
@property(nonatomic,strong) TTEmptyLineNumbersView *emptyLineNumbers;
@property(nonatomic, readwrite) NSUInteger revision;
@property(nonatomic) BOOL macroRecording;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSDictionary *> *syntaxStyles;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSDictionary *> *syntaxFonts;
@end
@implementation TTEditor
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSAssert(NSThread.isMainThread, @"Editor must be created on the main thread");
        _syntaxStyles=[NSMutableDictionary dictionary];_syntaxFonts=[NSMutableDictionary dictionary];
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
        for(int marker=SC_MARKNUM_FOLDEREND;marker<=SC_MARKNUM_FOLDEROPEN;++marker) {
            int symbol=(marker==SC_MARKNUM_FOLDER || marker==SC_MARKNUM_FOLDEREND) ? SC_MARK_BOXPLUS : (marker==SC_MARKNUM_FOLDEROPEN || marker==SC_MARKNUM_FOLDEROPENMID) ? SC_MARK_BOXMINUS : SC_MARK_VLINE;
            [_engine message:SCI_MARKERDEFINE wParam:marker lParam:symbol];
        }
        [_engine message:SCI_SETMARGINTYPEN wParam:2 lParam:SC_MARGIN_SYMBOL];
        [_engine message:SCI_SETMARGINMASKN wParam:2 lParam:SC_MASK_FOLDERS];
        [_engine message:SCI_SETMARGINWIDTHN wParam:2 lParam:16];
        [_engine message:SCI_SETMARGINSENSITIVEN wParam:2 lParam:1];
        [_engine message:SCI_SETAUTOMATICFOLD wParam:SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE];
        // Scintilla creates its scroll view at 100x10. Its initWithFrame does not
        // position the inner content. Start at zero so this real size transition also
        // invokes backend Resize, which initializes the document viewport.
        _engine.frame = self.bounds;
        NSRulerView *ruler = _engine.scrollView.verticalRulerView;
        _emptyLineNumbers = [[TTEmptyLineNumbersView alloc] initWithFrame:ruler.bounds];
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
    [_engine message:SCI_SETFOLDMARGINCOLOUR wParam:1 lParam:background];[_engine message:SCI_SETFOLDMARGINHICOLOUR wParam:1 lParam:background];
    for(int marker=SC_MARKNUM_FOLDEREND;marker<=SC_MARKNUM_FOLDEROPEN;++marker){[_engine message:SCI_MARKERSETFORE wParam:marker lParam:background];[_engine message:SCI_MARKERSETBACK wParam:marker lParam:foreground];}
    [_engine message:SCI_INDICSETSTYLE wParam:20 lParam:INDIC_ROUNDBOX];[_engine message:SCI_INDICSETFORE wParam:20 lParam:0x5BF4C7];[_engine message:SCI_INDICSETALPHA wParam:20 lParam:70];[_engine message:SCI_INDICSETOUTLINEALPHA wParam:20 lParam:160];
    [_engine message:SCI_SETCARETFORE wParam:foreground];
    [_engine message:SCI_SETSELFORE wParam:1 lParam:dark ? 0xFFFFFF : 0x101010];
    [_engine message:SCI_SETSELBACK wParam:1 lParam:dark ? 0x725038 : 0xF1D4AF];
    for (int style : {1, 2, 3}) [_engine message:SCI_STYLESETFORE wParam:style lParam:dark ? 0x9BC18E : 0x47804B];
    for (int style : {5, 11, 17}) [_engine message:SCI_STYLESETFORE wParam:style lParam:dark ? 0xDBA6C9 : 0xA04470];
    for (int style : {6, 7, 13}) [_engine message:SCI_STYLESETFORE wParam:style lParam:dark ? 0x8ACFE8 : 0x255EA0];
    NSDictionary *styles=[_syntaxStyles copy];
    for(NSNumber *index in styles) {NSDictionary *s=styles[index];[self setSyntaxStyle:index.integerValue foreground:s[@"foreground"] background:s[@"background"] bold:[s[@"bold"] boolValue] italic:[s[@"italic"] boolValue]];}
    NSDictionary *fonts=[_syntaxFonts copy];for(NSNumber *index in fonts){NSDictionary *f=fonts[index];[self setSyntaxFont:index.integerValue name:f[@"name"] size:[f[@"size"] doubleValue]];}
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
    // Unencodable text (an unpaired surrogate) leaves the document unchanged.
    NSData *data = TTUTF8(text); if (!data) return;
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
- (BOOL)readOnly { [self assertThread]; return [_engine message:SCI_GETREADONLY] != 0; }
- (void)setReadOnly:(BOOL)value { [self assertThread]; [_engine message:SCI_SETREADONLY wParam:value]; }
- (void)configureTabWidth:(NSInteger)width useTabs:(BOOL)useTabs {
    [self assertThread]; if (width < 1 || width > 32) return;
    [_engine message:SCI_SETTABWIDTH wParam:width]; [_engine message:SCI_SETUSETABS wParam:useTabs];
}
- (void)convertLineEndings:(NSString *)mode {
    [self assertThread]; if (self.readOnly) return;
    NSDictionary *modes = @{@"LF":@(SC_EOL_LF), @"CRLF":@(SC_EOL_CRLF), @"CR":@(SC_EOL_CR)};
    NSNumber *value = modes[mode]; if (!value) return;
    [_engine message:SCI_BEGINUNDOACTION]; [_engine message:SCI_CONVERTEOLS wParam:value.integerValue];
    [_engine message:SCI_SETEOLMODE wParam:value.integerValue]; [_engine message:SCI_ENDUNDOACTION];
}
- (void)setLineEndingMode:(NSString *)mode {
    [self assertThread];
    NSDictionary *modes = @{@"LF":@(SC_EOL_LF), @"CRLF":@(SC_EOL_CRLF), @"CR":@(SC_EOL_CR)};
    NSNumber *value = modes[mode]; if (!value) return;
    // Mode only: existing bytes, undo history, revision and save point are untouched.
    [_engine message:SCI_SETEOLMODE wParam:value.integerValue];
}
- (NSArray<NSDictionary<NSString *, NSNumber *> *> *)selectionRanges {
    [self assertThread]; NSMutableArray *ranges = [NSMutableArray array];
    for (sptr_t i=0; i<[_engine message:SCI_GETSELECTIONS]; ++i) {
        [ranges addObject:@{@"anchor":@([_engine message:SCI_GETSELECTIONNANCHOR wParam:i]), @"caret":@([_engine message:SCI_GETSELECTIONNCARET wParam:i])}];
    }
    return ranges;
}
- (BOOL)validSelectionRanges:(NSArray *)ranges {
    if (![ranges isKindOfClass:NSArray.class] || ranges.count == 0 || ranges.count > 10000) return NO;
    const sptr_t length = [_engine message:SCI_GETLENGTH];
    NSMutableArray *intervals = [NSMutableArray array];
    for (id range in ranges) {
        if (![range isKindOfClass:NSDictionary.class]) return NO;
        for (NSString *key in @[@"anchor",@"caret"]) {
            id value = range[key]; if (![value isKindOfClass:NSNumber.class]) return NO;
            NSInteger p=[value integerValue]; if ([value doubleValue] != (double)p || p<0 || p>length) return NO;
            if (p<length && ([_engine message:SCI_GETCHARAT wParam:p] & 0xC0)==0x80) return NO;
        }
        NSInteger a=[range[@"anchor"] integerValue], c=[range[@"caret"] integerValue];
        [intervals addObject:@[@(MIN(a,c)),@(MAX(a,c))]];
    }
    [intervals sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [a[0] compare:b[0]]; }];
    for (NSUInteger i=1;i<intervals.count;++i) {
        NSInteger previousEnd=[intervals[i-1][1] integerValue], start=[intervals[i][0] integerValue];
        if (start<previousEnd || (start==previousEnd && [intervals[i-1][0] integerValue]==start)) return NO;
    }
    return YES;
}
- (BOOL)setSelectionRanges:(NSArray<NSDictionary<NSString *,NSNumber *> *> *)ranges {
    [self assertThread]; if (![self validSelectionRanges:ranges]) return NO;
    [_engine message:SCI_SETSELECTIONMODE wParam:SC_SEL_STREAM];
    [_engine message:SCI_SETSELECTION wParam:[ranges[0][@"caret"] integerValue] lParam:[ranges[0][@"anchor"] integerValue]];
    for (NSUInteger i=1;i<ranges.count;++i) [_engine message:SCI_ADDSELECTION wParam:[ranges[i][@"caret"] integerValue] lParam:[ranges[i][@"anchor"] integerValue]];
    [_engine message:SCI_SETMAINSELECTION wParam:0]; return YES;
}
- (BOOL)replaceSelections:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision {
    [self assertThread]; NSArray *ranges=self.selectionRanges;
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
        NSDictionary *ra=ranges[a.unsignedIntegerValue], *rb=ranges[b.unsignedIntegerValue];
        return [@(MIN([rb[@"anchor"] integerValue],[rb[@"caret"] integerValue])) compare:@(MIN([ra[@"anchor"] integerValue],[ra[@"caret"] integerValue]))];
    }];
    [_engine message:SCI_BEGINUNDOACTION];
    for (NSNumber *index in indices) {
        NSDictionary *range=ranges[index.unsignedIntegerValue]; NSInteger a=[range[@"anchor"] integerValue], c=[range[@"caret"] integerValue];
        NSData *bytes=encoded[index.unsignedIntegerValue];
        [_engine message:SCI_SETTARGETRANGE wParam:MIN(a,c) lParam:MAX(a,c)];
        [_engine message:SCI_REPLACETARGET wParam:bytes.length lParam:(sptr_t)bytes.bytes];
    }
    [_engine message:SCI_ENDUNDOACTION]; return YES;
}
- (BOOL)replaceRanges:(NSArray<NSValue *> *)ranges withTexts:(NSArray<NSString *> *)texts expectedRevision:(NSUInteger)revision {
    [self assertThread];
    if (revision!=self.revision || self.readOnly || ![ranges isKindOfClass:NSArray.class] || ![texts isKindOfClass:NSArray.class] || ranges.count==0 || texts.count!=ranges.count) return NO;
    const NSUInteger length=(NSUInteger)[_engine message:SCI_GETLENGTH]; NSUInteger previousEnd=0;
    for (id value in ranges) {
        if (![value isKindOfClass:NSValue.class] || std::strcmp([value objCType], @encode(NSRange))!=0) return NO;
        const NSRange range=[value rangeValue];
        if (range.location>length || range.length>length-range.location || range.location<previousEnd) return NO;
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
    [_engine message:SCI_BEGINUNDOACTION];
    for (NSUInteger i=ranges.count;i-->0;) {
        const NSRange range=[ranges[i] rangeValue];
        [_engine message:SCI_SETTARGETRANGE wParam:range.location lParam:NSMaxRange(range)];
        [_engine message:SCI_REPLACETARGET wParam:encoded[i].length lParam:(sptr_t)encoded[i].bytes];
    }
    [_engine message:SCI_ENDUNDOACTION];
    const sptr_t caret=(sptr_t)([ranges[0] rangeValue].location+encoded[0].length);
    [_engine message:SCI_SETSEL wParam:caret lParam:caret];
    [_engine message:SCI_SCROLLCARET];
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
- (NSDictionary<NSString *,NSNumber *> *)statusInfo {
    [self assertThread];
    NSInteger caret = [_engine message:SCI_GETCURRENTPOS];
    return @{@"line":@([_engine message:SCI_LINEFROMPOSITION wParam:caret]+1),
             @"column":@([_engine message:SCI_GETCOLUMN wParam:caret]+1+[_engine message:SCI_GETSELECTIONNCARETVIRTUALSPACE wParam:[_engine message:SCI_GETMAINSELECTION]]),
             @"lines":@([_engine message:SCI_GETLINECOUNT]),
             @"tabWidth":@([_engine message:SCI_GETTABWIDTH]),
             @"useTabs":@([_engine message:SCI_GETUSETABS]),
             @"fontSize":@([_engine message:SCI_STYLEGETSIZEFRACTIONAL wParam:STYLE_DEFAULT]/100.0+[_engine message:SCI_GETZOOM]),
             @"eol":@([_engine message:SCI_GETEOLMODE])};
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
- (BOOL)replaceSelection:(NSString *)text {
    [self assertThread];
    NSData *data = TTUTF8(text); if (!data) return NO;
    const BOOL writable = !self.readOnly;
    [_engine message:SCI_BEGINUNDOACTION];
    [_engine message:SCI_TARGETFROMSELECTION];
    const sptr_t start = [_engine message:SCI_GETTARGETSTART];
    [_engine message:SCI_REPLACETARGET wParam:data.length lParam:(sptr_t)data.bytes];
    [_engine message:SCI_SETSEL wParam:start + data.length lParam:start + data.length];
    [_engine message:SCI_ENDUNDOACTION];
    return writable;
}
- (void)executeCommand:(NSString *)identifier {
    [self assertThread];
    if ([identifier isEqualToString:@"rectangularSelection"] || [identifier isEqualToString:@"streamSelection"]) {
        [_engine message:SCI_SETSELECTIONMODE wParam:[identifier isEqualToString:@"rectangularSelection"] ? SC_SEL_RECTANGLE : SC_SEL_STREAM]; return;
    }
    if ([identifier isEqualToString:@"clearAdditionalSelections"]) { [_engine message:SCI_CLEARSELECTIONS]; return; }
    if ([identifier isEqualToString:@"addNextOccurrence"] || [identifier isEqualToString:@"selectAllOccurrences"]) {
        [_engine message:[identifier isEqualToString:@"addNextOccurrence"] ? SCI_MULTIPLESELECTADDNEXT : SCI_MULTIPLESELECTADDEACH]; return;
    }
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
        @"duplicateSelection": @(SCI_SELECTIONDUPLICATE), @"deleteWordLeft": @(SCI_DELWORDLEFT), @"deleteWordRight": @(SCI_DELWORDRIGHT), @"deleteLineLeft": @(SCI_DELLINELEFT), @"deleteLineRight": @(SCI_DELLINERIGHT),
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
    [names addObject:@"user"];
    return [names sortedArrayUsingSelector:@selector(compare:)];
}
/// Installs the lexer and its defaults without lexing; every caller colourises exactly once afterwards.
- (void)installLexer:(NSString *)language {
    [_syntaxStyles removeAllObjects];[_syntaxFonts removeAllObjects];
    auto lexer = [language isEqualToString:@"user"] ? TextTankCreateUserLexer() : CreateLexer(language.UTF8String);
    if (!lexer) lexer = CreateLexer("null");
    [_engine message:SCI_SETILEXER wParam:0 lParam:(sptr_t)lexer];
    [_engine message:SCI_SETPROPERTY wParam:(uptr_t)"fold" lParam:(sptr_t)"1"];
    [_engine message:SCI_SETKEYWORDS wParam:0 lParam:(sptr_t)"if else for while return class struct import func let var true false null int void const static public private"];
    [self applyPalette];
}
- (void)setLanguage:(NSString *)language {
    [self assertThread];
    [self installLexer:language];
    [_engine message:SCI_COLOURISE wParam:0 lParam:-1];
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
    // Scintilla neither invalidates styling on a lexer swap nor repaints after a list or property
    // change, so one explicit full pass is what makes the final configuration take effect.
    [_engine message:SCI_COLOURISE wParam:0 lParam:-1];
}
- (NSAttributedString *)attributedTextForSelection:(BOOL)selection {
    [self assertThread]; [_engine message:SCI_COLOURISE wParam:0 lParam:-1];
    sptr_t start=selection ? self.selectionStart : 0,end=selection ? self.selectionEnd : [_engine message:SCI_GETLENGTH];
    NSMutableAttributedString *result=[[NSMutableAttributedString alloc] initWithString:@""];
    for (sptr_t p=start;p<end;) {
        sptr_t style=[_engine message:SCI_GETSTYLEAT wParam:p],q=p+1;
        while (q<end && [_engine message:SCI_GETSTYLEAT wParam:q]==style) ++q;
        // Style runs normally align to scalar boundaries; extend malformed style
        // boundaries to avoid splitting a UTF8 character in exported text.
        while (q<end && ([_engine message:SCI_GETCHARAT wParam:q]&0xC0)==0x80) ++q;
        std::vector<char> bytes((size_t)(q-p)+1);Sci_TextRangeFull range={{p,q},bytes.data()};
        [_engine message:SCI_GETTEXTRANGEFULL wParam:0 lParam:(sptr_t)&range];
        NSString *text=TTStringFromUTF8(bytes.data(),q-p);
        auto color=[](sptr_t c) { return [NSColor colorWithSRGBRed:(c&255)/255.0 green:((c>>8)&255)/255.0 blue:((c>>16)&255)/255.0 alpha:1]; };
        CGFloat size=[_engine message:SCI_STYLEGETSIZEFRACTIONAL wParam:style]/100.0;
        std::vector<char> face((size_t)[_engine message:SCI_STYLEGETFONT wParam:style lParam:0]+1);[_engine message:SCI_STYLEGETFONT wParam:style lParam:(sptr_t)face.data()];
        NSFont *font=[NSFont fontWithName:[NSString stringWithUTF8String:face.data()] size:size] ?: [NSFont monospacedSystemFontOfSize:MAX(1,size) weight:NSFontWeightRegular];
        NSFontTraitMask traits=0;if ([_engine message:SCI_STYLEGETBOLD wParam:style]) traits|=NSBoldFontMask;if ([_engine message:SCI_STYLEGETITALIC wParam:style]) traits|=NSItalicFontMask;
        if(traits)font=[[NSFontManager sharedFontManager] convertFont:font toHaveTrait:traits];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color([_engine message:SCI_STYLEGETFORE wParam:style]),NSBackgroundColorAttributeName:color([_engine message:SCI_STYLEGETBACK wParam:style])}]];
        p=q;
    }
    return result;
}
- (void)setSyntaxStyle:(NSInteger)index foreground:(NSColor *)foreground background:(NSColor *)background bold:(BOOL)bold italic:(BOOL)italic {
    [self assertThread]; if(index<0 || index>255)return;
    NSMutableDictionary *configuration=[@{@"foreground":foreground,@"bold":@(bold),@"italic":@(italic)} mutableCopy];if(background)configuration[@"background"]=background;_syntaxStyles[@(index)]=configuration;
    auto packed=[](NSColor *color)->sptr_t {NSColor *c=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];return ((NSInteger)lround(c.redComponent*255))|((NSInteger)lround(c.greenComponent*255)<<8)|((NSInteger)lround(c.blueComponent*255)<<16);};
    [_engine message:SCI_STYLESETFORE wParam:index lParam:packed(foreground)];
    if(background)[_engine message:SCI_STYLESETBACK wParam:index lParam:packed(background)];
    [_engine message:SCI_STYLESETBOLD wParam:index lParam:bold];[_engine message:SCI_STYLESETITALIC wParam:index lParam:italic];
}
- (void)clearSearchHighlights {
    [self assertThread];[_engine message:SCI_SETINDICATORCURRENT wParam:20];[_engine message:SCI_INDICATORCLEARRANGE wParam:0 lParam:[_engine message:SCI_GETLENGTH]];
}
- (BOOL)setSearchHighlights:(NSArray<NSValue *> *)ranges {
    [self assertThread];if(ranges.count>100000)return NO;const NSUInteger length=[_engine message:SCI_GETLENGTH];
    for(NSValue *value in ranges){if(![value isKindOfClass:NSValue.class] || strcmp(value.objCType,@encode(NSRange))!=0)return NO;NSRange r=value.rangeValue;
        if(r.location>length || r.length>length-r.location)return NO;
        for(NSUInteger p : {r.location,NSMaxRange(r)})if(p<length && ([_engine message:SCI_GETCHARAT wParam:p]&0xC0)==0x80)return NO;
    }
    [self clearSearchHighlights];[_engine message:SCI_INDICSETSTYLE wParam:20 lParam:INDIC_ROUNDBOX];[_engine message:SCI_INDICSETFORE wParam:20 lParam:0x5BF4C7];[_engine message:SCI_INDICSETALPHA wParam:20 lParam:70];[_engine message:SCI_INDICSETOUTLINEALPHA wParam:20 lParam:160];
    for(NSValue *value in ranges){NSRange r=value.rangeValue;[_engine message:SCI_INDICATORFILLRANGE wParam:r.location lParam:r.length];}return YES;
}
- (void)setSyntaxFont:(NSInteger)index name:(NSString *)name size:(double)size {
    [self assertThread];if(index<0 || index>255 || !std::isfinite(size) || size<6 || size>96 || name.length>200 || [name rangeOfString:@"\0"].location!=NSNotFound)return;
    NSFont *font=[NSFont fontWithName:name size:size];if(!font)return;
    _syntaxFonts[@(index)]=@{@"name":name,@"size":@(size)};
    [_engine message:SCI_STYLESETFONT wParam:index lParam:(sptr_t)name.UTF8String];[_engine message:SCI_STYLESETSIZEFRACTIONAL wParam:index lParam:(sptr_t)lround(size*100)];
}
- (void)showCallTip:(NSString *)text {
    [self assertThread];if([text rangeOfString:@"\0"].location!=NSNotFound)return;
    [_engine message:SCI_CALLTIPSHOW wParam:[_engine message:SCI_GETCURRENTPOS] lParam:(sptr_t)text.UTF8String];
}
- (void)showCompletions:(NSArray<NSString *> *)words {
    [self assertThread]; if(words.count==0)return;
    sptr_t caret=[_engine message:SCI_GETCURRENTPOS],start=[_engine message:SCI_WORDSTARTPOSITION wParam:caret lParam:1];
    NSMutableArray *safe=[NSMutableArray array];for(NSString *word in words) if([word rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location==NSNotFound && [word rangeOfString:@"\0"].location==NSNotFound) [safe addObject:word];
    NSString *list=[[safe sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "];
    if(list.length)[_engine message:SCI_AUTOCSHOW wParam:caret-start lParam:(sptr_t)list.UTF8String];
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
    _emptyLineNumbers.needsDisplay = YES;
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
